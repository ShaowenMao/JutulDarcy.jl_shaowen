using Printf

const PRODUCTION_OUTPUT_SCHEMA_VERSION = 1
const MRST_YEAR_SECONDS = 365.2425*24*60*60
const PRODUCTION_RESTART_PATTERN = r"^jutul_(\d+)\.jld2$"
const PRODUCTION_ROW_PATTERN = r"^step_(\d{6})\.tsv$"

"""
Configuration wrapper used only by the production-output workflow.

All ordinary configuration access is delegated to the original Jutul
configuration. The concrete wrapper type gives us a safe, package-owned
dispatch point that runs after Jutul has closed each restart file.
"""
struct ProductionOutputConfig{C, P} <: AbstractDict{Symbol, Any}
    inner::C
    policy::P
end

Base.length(config::ProductionOutputConfig) = length(config.inner)
Base.iterate(config::ProductionOutputConfig, state...) =
    iterate(config.inner, state...)
Base.getindex(config::ProductionOutputConfig, key) = config.inner[key]
Base.setindex!(config::ProductionOutputConfig, value, key) =
    (config.inner[key] = value)
Base.haskey(config::ProductionOutputConfig, key) = haskey(config.inner, key)
Base.keys(config::ProductionOutputConfig) = keys(config.inner)

mutable struct ProductionOutputPolicy
    output_path::String
    summary_dir::String
    row_dir::String
    retention_dir::String
    cumulative_seconds::Vector{Float64}
    final_schedule_step::Int
    retain_steps::Set{Int}
    retain_years::Vector{Float64}
    rolling_checkpoints::Int
    case_key::String
    campaign_manifest_sha256::String
    require_hysteresis_history::Bool
    current_step::Int
    pending_row
    original_output_function
    uses_output_function::Bool
end

production_row_path(policy::ProductionOutputPolicy, step::Integer) =
    joinpath(policy.row_dir, @sprintf("step_%06d.tsv", step))

production_retention_path(policy::ProductionOutputPolicy, step::Integer) =
    joinpath(policy.retention_dir, @sprintf("step_%06d.tsv", step))

production_restart_path(policy::ProductionOutputPolicy, step::Integer) =
    joinpath(policy.output_path, "jutul_$step.jld2")

function production_fsync(io)
    flush(io)
    result = if Sys.iswindows()
        ccall(:_commit, Cint, (Cint,), Base.fd(io))
    else
        ccall(:fsync, Cint, (Cint,), Base.fd(io))
    end
    result == 0 || error("Could not fsync production-output file.")
    return nothing
end

function production_atomic_write(writer::Function, path::AbstractString)
    parent = dirname(path)
    mkpath(parent)
    temporary = joinpath(
        parent,
        "." * basename(path) * ".tmp.$(getpid()).$(Threads.threadid())"
    )
    try
        open(temporary, "w") do io
            writer(io)
            production_fsync(io)
        end
        mv(temporary, path; force = true)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return path
end

function production_format_value(value)
    if value isa AbstractFloat
        return repr(Float64(value))
    elseif value isa Integer
        return string(value)
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value === nothing || ismissing(value)
        return ""
    else
        text = string(value)
        occursin('\t', text) &&
            error("Production-output values may not contain tab characters.")
        occursin('\n', text) &&
            error("Production-output values may not contain newlines.")
        return text
    end
end

function production_write_named_row(path::AbstractString, row::NamedTuple)
    production_atomic_write(path) do io
        println(io, join(string.(keys(row)), '\t'))
        println(io, join(production_format_value.(values(row)), '\t'))
    end
    return path
end

function production_read_named_row(path::AbstractString)
    lines = readlines(path)
    length(lines) == 2 ||
        error("Expected exactly two lines in production-output row $path.")
    header = split(lines[1], '\t'; keepempty = true)
    values = split(lines[2], '\t'; keepempty = true)
    length(header) == length(values) ||
        error("Header/value count mismatch in production-output row $path.")
    return Dict(header .=> values)
end

function production_scan_indices(directory::AbstractString, pattern::Regex)
    isdir(directory) || return Int[]
    indices = Int[]
    for name in readdir(directory)
        match_result = match(pattern, name)
        isnothing(match_result) && continue
        push!(indices, parse(Int, only(match_result.captures)))
    end
    sort!(unique!(indices))
    return indices
end

production_restart_indices(policy::ProductionOutputPolicy) =
    production_scan_indices(policy.output_path, PRODUCTION_RESTART_PATTERN)

production_summary_indices(policy::ProductionOutputPolicy) =
    production_scan_indices(policy.row_dir, PRODUCTION_ROW_PATTERN)

function production_array_stats(values)
    array = vec(values)
    isempty(array) && return (NaN, NaN, NaN, NaN, NaN)
    minimum_value = Inf
    maximum_value = -Inf
    value_sum = 0.0
    value_sumsq = 0.0
    for raw_value in array
        value = Float64(raw_value)
        isfinite(value) ||
            error("Production-output state contains non-finite values.")
        minimum_value = min(minimum_value, value)
        maximum_value = max(maximum_value, value)
        value_sum += value
        value_sumsq += abs2(value)
    end
    return (
        minimum_value,
        maximum_value,
        value_sum/length(array),
        value_sum,
        value_sumsq
    )
end

function production_get_reservoir_state(state)
    if haskey(state, :Reservoir)
        return state[:Reservoir]
    end
    return state
end

function production_report_stats(report)
    stats = Jutul.report_stats([report])
    ministeps = get(report, :ministeps, Any[])
    failed = count(ministep -> !get(ministep, :success, false), ministeps)
    return (
        ministeps = stats.ministeps,
        failed_ministeps = failed,
        newtons = stats.newtons,
        linear_iterations = stats.linear_iterations,
        wasted_newtons = stats.wasted.newtons,
        wasted_linear_iterations = stats.wasted.linear_iterations,
        solve_seconds = Float64(get(report, :total_time, NaN))
    )
end

function production_co2_masses(reservoir)
    required = (
        :FluidVolume,
        :Saturations,
        :PhaseMassDensities,
        :Rs,
        :ShrinkageFactors
    )
    all(key -> haskey(reservoir, key), required) ||
        return (NaN, NaN, NaN)

    fluid_volume = vec(reservoir[:FluidVolume])
    saturations = reservoir[:Saturations]
    densities = reservoir[:PhaseMassDensities]
    shrinkage = reservoir[:ShrinkageFactors]
    size(saturations, 1) >= 2 || return (NaN, NaN, NaN)
    size(densities, 1) >= 2 || return (NaN, NaN, NaN)
    size(shrinkage, 1) >= 2 || return (NaN, NaN, NaN)

    sw = vec(saturations[1, :])
    sg = vec(saturations[2, :])
    rs = vec(reservoir[:Rs])
    bo = vec(shrinkage[1, :])
    bg = vec(shrinkage[2, :])
    gas_density = vec(densities[2, :])
    n = length(sw)
    all(values -> length(values) == n,
        (sg, rs, bo, bg, gas_density, fluid_volume)) ||
        error("Inconsistent state-array lengths in production CO2 mass summary.")
    all(values -> all(isfinite, values),
        (sw, sg, rs, bo, bg, gas_density, fluid_volume)) ||
        error("Non-finite state value in production CO2 mass summary.")
    all(value -> !iszero(value), bg) ||
        error("Zero gas shrinkage factor in production CO2 mass summary.")

    free_mass = 0.0
    dissolved_mass = 0.0
    @inbounds for index in 1:n
        free_mass +=
            sg[index]*fluid_volume[index]*gas_density[index]
        dissolved_mass +=
            sw[index]*fluid_volume[index]*rs[index]*bo[index]*
            gas_density[index]/bg[index]
    end
    return (free_mass, dissolved_mass, free_mass + dissolved_mass)
end

function production_make_summary(
        policy::ProductionOutputPolicy,
        step::Integer,
        state,
        report;
        restart_bytes::Integer = 0
    )
    1 <= step <= length(policy.cumulative_seconds) ||
        error("Production-output step $step is outside the schedule.")
    reservoir = production_get_reservoir_state(state)
    haskey(reservoir, :Pressure) ||
        error("Production-output state has no Pressure.")
    haskey(reservoir, :Saturations) ||
        error("Production-output state has no Saturations.")

    pressure = reservoir[:Pressure]
    saturations = reservoir[:Saturations]
    ndims(saturations) == 2 && size(saturations, 1) >= 2 ||
        error("Expected phase-by-cell Saturations in production-output state.")
    gas_saturation = view(saturations, 2, :)

    p_min, p_max, p_mean, p_sum, p_sumsq =
        production_array_stats(pressure)
    sg_min, sg_max, sg_mean, sg_sum, sg_sumsq =
        production_array_stats(gas_saturation)
    saturation_sum_error = maximum(
        value -> abs(Float64(value) - 1.0),
        vec(sum(saturations; dims = 1))
    )

    if haskey(reservoir, :Rs)
        rs_min, rs_max, rs_mean, rs_sum, rs_sumsq =
            production_array_stats(reservoir[:Rs])
    else
        rs_min = rs_max = rs_mean = rs_sum = rs_sumsq = NaN
    end

    if haskey(reservoir, :MaxSaturations)
        max_saturations = reservoir[:MaxSaturations]
        size(max_saturations) == size(saturations) ||
            error("MaxSaturations shape does not match Saturations.")
        max_gas_saturation = view(max_saturations, 2, :)
        maxsg_min, maxsg_max, maxsg_mean, maxsg_sum, maxsg_sumsq =
            production_array_stats(max_gas_saturation)
        scanning_cells = count(
            pair -> pair[1] > pair[2] + 1.0e-12,
            zip(max_gas_saturation, gas_saturation)
        )
    elseif policy.require_hysteresis_history
        error("Hysteresis production output requires MaxSaturations.")
    else
        maxsg_min = maxsg_max = maxsg_mean = maxsg_sum = maxsg_sumsq = NaN
        scanning_cells = 0
    end

    free_mass, dissolved_mass, total_mass =
        production_co2_masses(reservoir)
    report_stats = production_report_stats(report)
    seconds = policy.cumulative_seconds[step]

    return (
        schema_version = PRODUCTION_OUTPUT_SCHEMA_VERSION,
        case_key = policy.case_key,
        campaign_manifest_sha256 = policy.campaign_manifest_sha256,
        step = Int(step),
        time_seconds = seconds,
        time_years = seconds/MRST_YEAR_SECONDS,
        report_solve_seconds = report_stats.solve_seconds,
        ministeps = report_stats.ministeps,
        failed_ministeps = report_stats.failed_ministeps,
        newton_iterations = report_stats.newtons,
        linear_iterations = report_stats.linear_iterations,
        wasted_newton_iterations = report_stats.wasted_newtons,
        wasted_linear_iterations = report_stats.wasted_linear_iterations,
        pressure_min_pa = p_min,
        pressure_max_pa = p_max,
        pressure_mean_pa = p_mean,
        pressure_sum_pa = p_sum,
        pressure_sumsq_pa2 = p_sumsq,
        gas_saturation_min = sg_min,
        gas_saturation_max = sg_max,
        gas_saturation_mean = sg_mean,
        gas_saturation_sum = sg_sum,
        gas_saturation_sumsq = sg_sumsq,
        saturation_sum_error_max = saturation_sum_error,
        rs_min = rs_min,
        rs_max = rs_max,
        rs_mean = rs_mean,
        rs_sum = rs_sum,
        rs_sumsq = rs_sumsq,
        historical_gas_saturation_min = maxsg_min,
        historical_gas_saturation_max = maxsg_max,
        historical_gas_saturation_mean = maxsg_mean,
        historical_gas_saturation_sum = maxsg_sum,
        historical_gas_saturation_sumsq = maxsg_sumsq,
        hysteresis_scanning_cells = scanning_cells,
        free_co2_mass_kg = free_mass,
        dissolved_co2_mass_kg = dissolved_mass,
        total_co2_mass_kg = total_mass,
        restart_file = "jutul_$step.jld2",
        restart_bytes = Int(restart_bytes),
        written_utc = string(Dates.now(Dates.UTC))
    )
end

function production_validate_state(
        policy::ProductionOutputPolicy,
        step::Integer,
        state,
        report
    )
    row = production_make_summary(policy, step, state, report)
    isfinite(row.pressure_min_pa) && row.pressure_min_pa > 0 ||
        error("Checkpoint $step has non-finite or non-positive pressure.")
    reservoir = production_get_reservoir_state(state)
    saturations = reservoir[:Saturations]
    all(
        value -> isfinite(value) && -1.0e-8 <= value <= 1.0 + 1.0e-8,
        saturations
    ) || error("Checkpoint $step has an invalid phase saturation.")
    -1.0e-8 <= row.gas_saturation_min <= 1.0 + 1.0e-8 ||
        error("Checkpoint $step has invalid gas saturation minimum.")
    -1.0e-8 <= row.gas_saturation_max <= 1.0 + 1.0e-8 ||
        error("Checkpoint $step has invalid gas saturation maximum.")
    row.saturation_sum_error_max <= 1.0e-6 ||
        error("Checkpoint $step has excessive saturation-sum error.")
    if haskey(reservoir, :Rs)
        isfinite(row.rs_min) && row.rs_min >= -1.0e-12 ||
            error("Checkpoint $step has invalid dissolved-gas ratio.")
    end
    if haskey(reservoir, :MaxSaturations)
        all(
            value -> isfinite(value) &&
                -1.0e-8 <= value <= 1.0 + 1.0e-8,
            reservoir[:MaxSaturations]
        ) || error("Checkpoint $step has an invalid historical saturation.")
    end
    all(
        value -> isfinite(value) && value >= -1.0e-8,
        (
            row.free_co2_mass_kg,
            row.dissolved_co2_mass_kg,
            row.total_co2_mass_kg
        )
    ) || error("Checkpoint $step has invalid CO2 mass totals.")
    return row
end

function production_validate_restart(
        policy::ProductionOutputPolicy,
        step::Integer
    )
    path = production_restart_path(policy, step)
    isfile(path) || error("Missing restart checkpoint $path.")
    filesize(path) > 0 || error("Restart checkpoint $path is empty.")
    state, report = Jutul.read_restart(policy.output_path, step)
    row = production_validate_state(policy, step, state, report)
    return merge(row, (restart_bytes = filesize(path),))
end

function production_compare_summary_state(
        memory_row::NamedTuple,
        disk_row::NamedTuple,
        step::Integer
    )
    fields = (
        :pressure_min_pa,
        :pressure_max_pa,
        :pressure_sum_pa,
        :pressure_sumsq_pa2,
        :gas_saturation_min,
        :gas_saturation_max,
        :gas_saturation_sum,
        :gas_saturation_sumsq,
        :rs_min,
        :rs_max,
        :rs_sum,
        :rs_sumsq,
        :historical_gas_saturation_min,
        :historical_gas_saturation_max,
        :historical_gas_saturation_sum,
        :historical_gas_saturation_sumsq,
        :free_co2_mass_kg,
        :dissolved_co2_mass_kg,
        :total_co2_mass_kg
    )
    for field in fields
        isequal(memory_row[field], disk_row[field]) ||
            error(
                "Persisted checkpoint $step does not reproduce summary " *
                "field $field."
            )
    end
    return nothing
end

function production_quarantine!(
        policy::ProductionOutputPolicy,
        path::AbstractString,
        reason::AbstractString
    )
    timestamp = Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS")
    quarantine_dir = joinpath(policy.summary_dir, "quarantine")
    mkpath(quarantine_dir)
    quarantined = joinpath(
        quarantine_dir,
        basename(path) * ".corrupt.$timestamp"
    )
    mv(path, quarantined; force = false)
    production_atomic_write(quarantined * ".txt") do io
        println(io, "reason=", reason)
        println(io, "quarantined_utc=", Dates.now(Dates.UTC))
    end
    return quarantined
end

function production_config_values(policy::ProductionOutputPolicy)
    return (
        schema_version = PRODUCTION_OUTPUT_SCHEMA_VERSION,
        case_key = policy.case_key,
        campaign_manifest_sha256 = policy.campaign_manifest_sha256,
        schedule_steps = policy.final_schedule_step,
        retain_steps = join(sort!(collect(policy.retain_steps)), ","),
        retain_years = join(policy.retain_years, ","),
        rolling_checkpoints = policy.rolling_checkpoints,
        year_seconds = MRST_YEAR_SECONDS
    )
end

function production_check_or_write_config!(policy::ProductionOutputPolicy)
    path = joinpath(policy.summary_dir, "production_config.tsv")
    expected = production_config_values(policy)
    if isfile(path)
        observed = production_read_named_row(path)
        for (key, value) in pairs(expected)
            observed[string(key)] == production_format_value(value) ||
                error(
                    "Production-output configuration mismatch for $key: " *
                    "found $(observed[string(key)]), expected " *
                    production_format_value(value)
                )
        end
    else
        production_write_named_row(path, expected)
    end
    return path
end

function production_validate_summary_prefix!(
        policy::ProductionOutputPolicy,
        through_step::Integer
    )
    through_step <= 0 && return nothing
    observed = Set(production_summary_indices(policy))
    missing_steps = [step for step in 1:through_step if !(step in observed)]
    isempty(missing_steps) ||
        error(
            "Production summary is missing steps " *
            join(missing_steps[1:min(end, 20)], ",")
        )
    for step in 1:through_step
        row = production_read_named_row(production_row_path(policy, step))
        parse(Int, row["step"]) == step ||
            error("Production summary row $step contains the wrong step.")
        parse(Int, row["schema_version"]) == PRODUCTION_OUTPUT_SCHEMA_VERSION ||
            error("Production summary row $step has an unsupported schema.")
    end
    return nothing
end

function production_summary_matches(
        observed::AbstractDict,
        expected::NamedTuple
    )
    for (key, expected_value) in pairs(expected)
        key == :written_utc && continue
        observed_key = string(key)
        haskey(observed, observed_key) || return false
        observed[observed_key] == production_format_value(expected_value) ||
            return false
    end
    return true
end

function production_reconcile_restart!(
        policy::ProductionOutputPolicy,
        restart
    )
    restart_indices = production_restart_indices(policy)
    summary_indices = production_summary_indices(policy)
    fresh = restart === false || restart === 0 || restart === 1 ||
        isnothing(restart)

    if fresh
        isempty(restart_indices) ||
            error("Fresh production run found existing restart checkpoints.")
        isempty(summary_indices) ||
            error("Fresh production run found existing summary rows.")
        return false
    end

    requested_previous = if restart isa Integer && !(restart isa Bool)
        restart - 1
    else
        isempty(restart_indices) ? 0 : maximum(restart_indices)
    end
    requested_previous >= 0 || error("Invalid production restart value $restart.")

    candidate = requested_previous
    validated_row = nothing
    while candidate > 0
        path = production_restart_path(policy, candidate)
        if !isfile(path)
            if restart isa Integer && !(restart isa Bool)
                error("Requested restart checkpoint $candidate does not exist.")
            end
            lower = filter(<(candidate), restart_indices)
            candidate = isempty(lower) ? 0 : maximum(lower)
            continue
        end
        try
            validated_row = production_validate_restart(policy, candidate)
            break
        catch error_value
            if restart isa Integer && !(restart isa Bool)
                rethrow()
            end
            production_quarantine!(
                policy,
                path,
                sprint(showerror, error_value)
            )
            row_path = production_row_path(policy, candidate)
            isfile(row_path) &&
                production_quarantine!(
                    policy,
                    row_path,
                    "Checkpoint $candidate failed validation."
                )
            lower = filter(<(candidate), restart_indices)
            candidate = isempty(lower) ? 0 : maximum(lower)
        end
    end

    if candidate == 0
        isempty(summary_indices) ||
            error("No valid restart exists, but production summary rows are present.")
        return false
    end

    row_path = production_row_path(policy, candidate)
    if isfile(row_path)
        observed_row = production_read_named_row(row_path)
        if !production_summary_matches(observed_row, validated_row)
            production_quarantine!(
                policy,
                row_path,
                "Summary did not match validated checkpoint $candidate."
            )
            production_write_named_row(row_path, validated_row)
        end
    else
        production_write_named_row(row_path, validated_row)
    end
    production_validate_summary_prefix!(policy, candidate)

    for step in production_restart_indices(policy)
        if step > candidate
            production_quarantine!(
                policy,
                production_restart_path(policy, step),
                "Checkpoint is newer than the selected valid restart $candidate."
            )
        end
    end
    return candidate + 1
end

function production_capture_output!(
        policy::ProductionOutputPolicy,
        state,
        report
    )
    transformed = if ismissing(policy.original_output_function)
        state
    else
        policy.original_output_function(state, report)
    end
    policy.pending_row = production_make_summary(
        policy,
        policy.current_step,
        transformed,
        report
    )
    return transformed
end

function production_delete_obsolete_restarts!(
        policy::ProductionOutputPolicy,
        step::Integer
    )
    keep = Set(filter(<=(step), policy.retain_steps))
    if step == policy.final_schedule_step
        push!(keep, step)
    else
        first_rolling = max(1, step - policy.rolling_checkpoints + 1)
        union!(keep, first_rolling:step)
    end

    deleted = Int[]
    for candidate in production_restart_indices(policy)
        if candidate <= step && !(candidate in keep)
            path = production_restart_path(policy, candidate)
            realpath(dirname(path)) == realpath(policy.output_path) ||
                error("Refusing to remove restart outside production output path.")
            rm(path)
            push!(deleted, candidate)
        end
    end
    return sort!(collect(keep)), deleted
end

function production_write_retention_row!(
        policy::ProductionOutputPolicy,
        step::Integer,
        kept,
        deleted
    )
    row = (
        schema_version = PRODUCTION_OUTPUT_SCHEMA_VERSION,
        step = Int(step),
        kept_restart_steps = join(kept, ","),
        deleted_restart_steps = join(deleted, ","),
        written_utc = string(Dates.now(Dates.UTC))
    )
    production_write_named_row(production_retention_path(policy, step), row)
    return row
end

function production_consolidate_summary!(
        policy::ProductionOutputPolicy;
        require_complete::Bool = false
    )
    indices = production_summary_indices(policy)
    isempty(indices) && return nothing
    latest = maximum(indices)
    expected_latest = require_complete ? policy.final_schedule_step : latest
    production_validate_summary_prefix!(policy, expected_latest)
    if require_complete
        latest == policy.final_schedule_step ||
            error(
                "Production summary has $latest steps, expected " *
                "$(policy.final_schedule_step)."
            )
    end

    destination = joinpath(policy.summary_dir, "report_steps.tsv")
    production_atomic_write(destination) do io
        first_lines = readlines(production_row_path(policy, 1))
        println(io, first_lines[1])
        println(io, first_lines[2])
        for step in 2:expected_latest
            lines = readlines(production_row_path(policy, step))
            lines[1] == first_lines[1] ||
                error("Summary header changed at report step $step.")
            println(io, lines[2])
        end
    end

    if require_complete
        completion = (
            schema_version = PRODUCTION_OUTPUT_SCHEMA_VERSION,
            status = "complete",
            case_key = policy.case_key,
            campaign_manifest_sha256 = policy.campaign_manifest_sha256,
            schedule_steps = policy.final_schedule_step,
            retained_restart_steps =
                join(production_restart_indices(policy), ","),
            completed_utc = string(Dates.now(Dates.UTC))
        )
        production_write_named_row(
            joinpath(policy.summary_dir, "PRODUCTION_OUTPUT_COMPLETE.tsv"),
            completion
        )
    end
    return destination
end

function production_report_step!(
        policy::ProductionOutputPolicy,
        step::Integer,
        state = nothing,
        report = nothing
    )
    path = production_restart_path(policy, step)
    isfile(path) || error("Jutul did not create expected checkpoint $path.")
    filesize(path) > 0 || error("Jutul created an empty checkpoint $path.")

    row = policy.pending_row
    if isnothing(row)
        isnothing(state) &&
            error("No captured production summary exists for step $step.")
        row = production_make_summary(policy, step, state, report)
    end
    if step in policy.retain_steps || step == policy.final_schedule_step
        disk_row = production_validate_restart(policy, step)
        production_compare_summary_state(row, disk_row, step)
    end
    row = merge(row, (restart_bytes = filesize(path),))
    production_write_named_row(production_row_path(policy, step), row)
    kept, deleted = production_delete_obsolete_restarts!(policy, step)
    production_write_retention_row!(policy, step, kept, deleted)
    policy.pending_row = nothing

    if step == policy.final_schedule_step
        production_consolidate_summary!(policy; require_complete = true)
    end
    return row
end

function Jutul.store_output!(
        states,
        reports,
        step,
        sim,
        config::ProductionOutputConfig,
        report;
        substates = missing
    )
    policy = config.policy
    policy.current_step = step
    policy.pending_row = nothing

    fallback_state = nothing
    fallback_report = nothing
    if !policy.uses_output_function
        fallback_state = Jutul.get_output_state(sim)
        !ismissing(substates) && (fallback_state[:substates] = substates)
        fallback_report =
            Jutul.get_output_report(sim, report, config.inner[:report_level])
        policy.pending_row = production_make_summary(
            policy,
            step,
            fallback_state,
            fallback_report
        )
    end

    # Delegate the scientific state/report write unchanged to Jutul. This
    # call returns only after the restart file has been closed.
    Jutul.store_output!(
        states,
        reports,
        step,
        sim,
        config.inner,
        report;
        substates = substates
    )
    production_report_step!(
        policy,
        step,
        fallback_state,
        fallback_report
    )
    return nothing
end

function setup_production_output(
        config,
        output_path::AbstractString,
        schedule_dt,
        restart;
        summary_dir = nothing,
        retain_years = [50.0, 1000.0],
        rolling_checkpoints::Integer = 2,
        case_key::AbstractString = "",
        campaign_manifest_sha256::AbstractString = "",
        require_hysteresis_history::Bool = true
    )
    config[:in_memory_reports] == 1 ||
        error("Production-output mode requires IN_MEMORY_REPORTS=1.")
    rolling_checkpoints >= 2 ||
        error("Production-output mode requires at least two rolling checkpoints.")
    isdir(output_path) ||
        error("Production output path does not exist: $output_path")

    cumulative_seconds = cumsum(Float64.(schedule_dt))
    isempty(cumulative_seconds) ||
        all(diff(cumulative_seconds) .> 0) ||
        error("Production schedule times must be strictly increasing.")
    retain_years = Float64.(retain_years)
    retain_steps = Set{Int}()
    for target_year in retain_years
        target_year >= 0 ||
            error("Retained production-output years must be non-negative.")
        matches = findall(
            time -> isapprox(
                time/MRST_YEAR_SECONDS,
                target_year;
                atol = 1.0e-10,
                rtol = 0
            ),
            cumulative_seconds
        )
        length(matches) == 1 ||
            error(
                "Retained year $target_year is not one exact, unique " *
                "report boundary."
            )
        push!(retain_steps, only(matches))
    end

    summary_dir = isnothing(summary_dir) ?
        joinpath(output_path, "production_output") : String(summary_dir)
    row_dir = joinpath(summary_dir, "rows")
    retention_dir = joinpath(summary_dir, "retention")
    mkpath(row_dir)
    mkpath(retention_dir)

    has_output_function = haskey(config, :output_function)
    original_output_function =
        has_output_function ? config[:output_function] : missing
    policy = ProductionOutputPolicy(
        realpath(output_path),
        abspath(summary_dir),
        abspath(row_dir),
        abspath(retention_dir),
        cumulative_seconds,
        length(cumulative_seconds),
        retain_steps,
        retain_years,
        Int(rolling_checkpoints),
        String(case_key),
        lowercase(String(campaign_manifest_sha256)),
        require_hysteresis_history,
        0,
        nothing,
        original_output_function,
        has_output_function
    )
    production_check_or_write_config!(policy)
    restart = production_reconcile_restart!(policy, restart)

    if has_output_function
        config[:output_function] =
            (state, report) -> production_capture_output!(policy, state, report)
    end
    return ProductionOutputConfig(config, policy), restart
end
