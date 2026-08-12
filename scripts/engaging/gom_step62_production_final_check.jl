using JutulDarcy
import Jutul

length(ARGS) == 5 || error(
    "Usage: gom_step62_production_final_check.jl " *
    "RESTART_DIR SUMMARY_DIR OUTPUT_PATH CASE_KEY MANIFEST_SHA256"
)
restart_dir, summary_dir, output_path, expected_case_key,
    expected_manifest_sha256 = ARGS

const EXPECTED_CELLS = 2_165_082
const EXPECTED_STEPS = 210
const LEGACY_RESTARTS = [78, 210]
const CURRENT_RESTARTS = [51, 78, 110, 210]
const QOI_MOBILITY_METHOD_V2 =
    "cell_local_active_krg_zero_mobility_endpoint_killough_v1"

function read_named_row(path)
    lines = readlines(path)
    length(lines) == 2 || error("$path must contain exactly two lines.")
    names = split(lines[1], '\t'; keepempty = true)
    values = split(lines[2], '\t'; keepempty = true)
    length(names) == length(values) ||
        error("$path has mismatched header and value counts.")
    length(unique(names)) == length(names) ||
        error("$path has duplicate column names.")
    return Dict(names .=> values), lines
end

function read_table(path)
    lines = readlines(path)
    length(lines) >= 2 || error("$path must contain a header and data.")
    names = split(lines[1], '\t'; keepempty = true)
    length(unique(names)) == length(names) ||
        error("$path has duplicate column names.")
    rows = Dict{String, String}[]
    for (offset, line) in enumerate(lines[2:end])
        values = split(line, '\t'; keepempty = true)
        length(values) == length(names) || error(
            "$path line $(offset + 1) has mismatched header and value counts."
        )
        push!(rows, Dict(String.(names) .=> String.(values)))
    end
    return names, rows
end

function require_close(observed, expected, label; rtol = 1.0e-10, atol = 1.0e-3)
    isapprox(observed, expected; rtol = rtol, atol = atol) || error(
        "$label does not close: observed=$observed expected=$expected."
    )
end

function parse_csv_values(::Type{T}, value, label) where T
    parts = split(value, ','; keepempty = true)
    all(part -> !isempty(strip(part)), parts) ||
        error("$label contains an empty value: $value")
    try
        return parse.(T, strip.(parts))
    catch exception
        error("Could not parse $label '$value': $(sprint(showerror, exception))")
    end
end

function validate_schema4_output(config, rows, expected_case_key)
    haskey(config, "qoi_schema4_version") || return nothing
    schema = parse(Int, config["qoi_schema4_version"])
    schema == JutulDarcy.PRODUCTION_QOI_SCHEMA4_VERSION || error(
        "Unsupported schema-4 extension version $schema."
    )
    config["qoi_schema4_mode"] == "required" || error(
        "Production schema 4 must run in required mode."
    )

    root = joinpath(summary_dir, "qoi_schema4")
    isdir(root) || error("Schema-4 output directory does not exist: $root")
    required_manifests = (
        "schema4_definition.tsv",
        "case_uq_manifest.tsv",
        "realization_manifest.tsv",
        "fault_group_manifest.tsv",
        "cumulative_interface_manifest.tsv"
    )
    for name in required_manifests
        isfile(joinpath(root, name)) || error(
            "Schema-4 output is missing $name."
        )
    end

    definition, _ = read_named_row(joinpath(root, "schema4_definition.tsv"))
    parse(Int, definition["schema_version"]) == schema || error(
        "Schema-4 definition has the wrong schema version."
    )
    definition["case_key"] == expected_case_key || error(
        "Schema-4 definition has the wrong case key."
    )
    parse(Int, definition["window_count"]) == 6 || error(
        "Schema-4 definition does not contain six windows."
    )
    parse(Int, definition["slice_count"]) == 87 || error(
        "Schema-4 definition does not contain 87 slices."
    )
    mapping_sha256 = config["qoi_schema4_mapping_sha256"]
    definition["mapping_sha256"] == mapping_sha256 || error(
        "Schema-4 definition/configuration mapping hashes differ."
    )

    provenance_path = joinpath(root, "case_uq_manifest.tsv")
    realization_path = joinpath(root, "realization_manifest.tsv")
    JutulDarcy.production_qoi_file_sha256(provenance_path) ==
        config["qoi_schema4_provenance_manifest_sha256"] || error(
        "Schema-4 provenance manifest hash differs from configuration."
    )
    JutulDarcy.production_qoi_file_sha256(realization_path) ==
        config["qoi_schema4_realization_manifest_sha256"] || error(
        "Schema-4 realization manifest hash differs from configuration."
    )

    _, realizations = read_table(realization_path)
    length(realizations) == 6*87 || error(
        "Schema-4 realization manifest must contain 522 rows."
    )
    realization_keys = Set{Tuple{Int, Int}}()
    for realization in realizations
        window = parse(Int, realization["window"])
        slice = parse(Int, realization["slice"])
        1 <= window <= 6 && 1 <= slice <= 87 || error(
            "Schema-4 realization manifest has an invalid window/slice."
        )
        push!(realization_keys, (window, slice))
        parse(Int, realization["selected_realization_index"]) > 0 || error(
            "Schema-4 realization manifest has a nonpositive realization index."
        )
        parse(Int64, realization["exact_replay_seed"])
    end
    length(realization_keys) == 6*87 || error(
        "Schema-4 realization manifest has duplicate window/slice rows."
    )

    _, fault_groups = read_table(joinpath(root, "fault_group_manifest.tsv"))
    length(fault_groups) == 6*87 || error(
        "Schema-4 fault-group manifest must contain 522 rows."
    )
    _, interfaces = read_table(
        joinpath(root, "cumulative_interface_manifest.tsv")
    )
    length(interfaces) == 4 || error(
        "Schema-4 cumulative interface manifest must contain four interfaces."
    )

    completion, _ = read_named_row(
        joinpath(root, "QOI_SCHEMA4_COMPLETE.tsv")
    )
    completion["status"] == "complete" || error(
        "Schema-4 completion marker does not say complete."
    )
    parse(Int, completion["schema_version"]) == schema || error(
        "Schema-4 completion marker has the wrong schema."
    )
    completion["case_key"] == expected_case_key || error(
        "Schema-4 completion marker has the wrong case key."
    )
    parse(Int, completion["schedule_steps"]) == EXPECTED_STEPS || error(
        "Schema-4 completion marker has the wrong schedule length."
    )
    completion["mapping_sha256"] == mapping_sha256 || error(
        "Schema-4 completion marker has the wrong mapping hash."
    )
    completion["storage_budget_passed"] == "true" || error(
        "Schema-4 completion marker does not pass its storage budget."
    )
    parse(Int, completion["payload_bytes_before_completion_marker"]) <=
        parse(Int, completion["storage_budget_bytes"]) || error(
        "Schema-4 completion payload exceeds its storage budget."
    )

    _, scalar_rows = read_table(joinpath(root, "qoi_schema4_steps.tsv"))
    _, spatial_index = read_table(joinpath(root, "spatial_history_index.tsv"))
    length(scalar_rows) == EXPECTED_STEPS || error(
        "Schema-4 scalar history does not contain 210 report rows."
    )
    length(spatial_index) == EXPECTED_STEPS || error(
        "Schema-4 spatial index does not contain 210 report rows."
    )
    expected_bytes = parse(Int, config["qoi_schema4_spatial_bytes_per_step"])
    expected_bytes == JutulDarcy.production_qoi_schema4_expected_binary_bytes() ||
        error("Schema-4 configured spatial-record byte count is invalid.")

    cumulative_fields = (
        "cumulative_injected_co2_kg",
        "cumulative_produced_co2_kg",
        "cumulative_boundary_out_co2_kg",
        "cumulative_boundary_in_co2_kg"
    )
    previous_cumulative = fill(-Inf, length(cumulative_fields))
    previous_ministeps = -1
    interface_ids = Tuple(interface["interface_id"] for interface in interfaces)
    previous_interface = Dict{String, Float64}()
    total_spatial_bytes = 0
    root_real = realpath(root)
    for step in 1:EXPECTED_STEPS
        row = scalar_rows[step]
        index = spatial_index[step]
        parse(Int, row["schema_version"]) == schema || error(
            "Schema-4 scalar row $step has the wrong schema."
        )
        parse(Int, row["step"]) == step || error(
            "Schema-4 scalar row $step has the wrong step index."
        )
        parse(Int, index["step"]) == step || error(
            "Schema-4 spatial index row $step has the wrong step index."
        )
        row["case_key"] == expected_case_key || error(
            "Schema-4 scalar row $step has the wrong case key."
        )
        row["mapping_sha256"] == mapping_sha256 || error(
            "Schema-4 scalar row $step has the wrong mapping hash."
        )
        require_close(
            parse(Float64, row["time_seconds"]),
            parse(Float64, rows[step]["time_seconds"]),
            "Schema-4/report time at step $step";
            rtol = 0.0,
            atol = 1.0e-8
        )
        require_close(
            parse(Float64, index["time_seconds"]),
            parse(Float64, row["time_seconds"]),
            "Schema-4 scalar/spatial time at step $step";
            rtol = 0.0,
            atol = 1.0e-8
        )

        relative = index["relative_path"]
        spatial_path = normpath(joinpath(root, relative))
        isfile(spatial_path) || error(
            "Schema-4 spatial record $step does not exist."
        )
        resolved_spatial = realpath(spatial_path)
        relative_to_root = relpath(resolved_spatial, root_real)
        relative_parts = splitpath(relative_to_root)
        (!isabspath(relative_to_root) &&
            !isempty(relative_parts) && first(relative_parts) != "..") ||
            error("Schema-4 spatial record $step escapes its output directory.")
        bytes = filesize(spatial_path)
        bytes == expected_bytes || error(
            "Schema-4 spatial record $step has $bytes bytes, expected $expected_bytes."
        )
        parse(Int, index["bytes"]) == bytes || error(
            "Schema-4 spatial index has the wrong byte count at step $step."
        )
        digest = JutulDarcy.production_qoi_file_sha256(spatial_path)
        index["sha256"] == digest || error(
            "Schema-4 spatial index has the wrong hash at step $step."
        )
        row["spatial_binary_sha256"] == digest || error(
            "Schema-4 scalar row has the wrong spatial hash at step $step."
        )
        parsed = JutulDarcy.production_qoi_schema4_read_binary(spatial_path)
        parsed.step == step || error(
            "Schema-4 spatial record contains the wrong step at $step."
        )
        size(parsed.fault) == (6*87, 7) || error(
            "Schema-4 fault history has the wrong dimensions at step $step."
        )
        size(parsed.leakage) == (2, 87, 3) || error(
            "Schema-4 leakage history has the wrong dimensions at step $step."
        )
        total_spatial_bytes += bytes

        for (field_index, field) in enumerate(cumulative_fields)
            value = parse(Float64, row[field])
            isfinite(value) && value >= previous_cumulative[field_index] ||
                error("Schema-4 cumulative $field decreases at step $step.")
            previous_cumulative[field_index] = value
        end
        accepted = parse(Int, row["accepted_ministep_count"])
        accepted >= previous_ministeps || error(
            "Schema-4 accepted-ministep count decreases at step $step."
        )
        previous_ministeps = accepted
        for field in (
                "actual_co2_rate_kg_s",
                "domain_co2_mass_kg",
                "expected_domain_co2_mass_kg",
                "mass_balance_residual_kg",
                "mass_balance_relative_residual",
                "ministep_accounting_seconds",
                "spatial_evaluation_seconds"
            )
            value = parse(Float64, row[field])
            isfinite(value) || error(
                "Schema-4 scalar $field is non-finite at step $step."
            )
        end
        for interface_id in interface_ids
            for component in ("free", "dissolved", "total")
                prefix = "cumulative_$(interface_id)_$(component)"
                forward = parse(Float64, row[prefix * "_forward_kg"])
                reverse = parse(Float64, row[prefix * "_reverse_kg"])
                net = parse(Float64, row[prefix * "_net_kg"])
                forward >= get(previous_interface, prefix * "_forward", -Inf) ||
                    error("Schema-4 interface forward mass decreases at step $step.")
                reverse >= get(previous_interface, prefix * "_reverse", -Inf) ||
                    error("Schema-4 interface reverse mass decreases at step $step.")
                require_close(
                    net,
                    forward - reverse,
                    "Schema-4 interface net mass at step $step";
                    rtol = 1.0e-12,
                    atol = 1.0e-6
                )
                previous_interface[prefix * "_forward"] = forward
                previous_interface[prefix * "_reverse"] = reverse
            end
        end
    end
    parse(Int, completion["total_spatial_bytes"]) == total_spatial_bytes ||
        error("Schema-4 completion marker has the wrong spatial byte total.")
    return (
        schema = schema,
        spatial_bytes = total_spatial_bytes,
        accepted_ministeps = previous_ministeps,
        accounting_seconds = parse(
            Float64,
            scalar_rows[end]["ministep_accounting_seconds"]
        )
    )
end

function validate_state(step)
    state, _ = Jutul.read_restart(
        restart_dir,
        step;
        read_state = true,
        read_report = false
    )
    reservoir = state[:Reservoir]
    pressure = vec(reservoir[:Pressure])
    saturation = reservoir[:Saturations]
    rs = vec(reservoir[:Rs])
    max_saturation = reservoir[:MaxSaturations]

    length(pressure) == EXPECTED_CELLS ||
        error("Checkpoint $step has the wrong pressure length.")
    size(saturation) == (2, EXPECTED_CELLS) ||
        error("Checkpoint $step has the wrong saturation shape.")
    length(rs) == EXPECTED_CELLS ||
        error("Checkpoint $step has the wrong Rs length.")
    size(max_saturation) == size(saturation) ||
        error("Checkpoint $step has the wrong MaxSaturations shape.")
    all(isfinite, pressure) || error("Checkpoint $step pressure is not finite.")
    all(>(0.0), pressure) || error("Checkpoint $step pressure is not positive.")
    all(isfinite, saturation) ||
        error("Checkpoint $step saturation is not finite.")
    all(value -> -1.0e-8 <= value <= 1.0 + 1.0e-8, saturation) ||
        error("Checkpoint $step saturation is outside physical bounds.")
    saturation_error =
        maximum(abs.(vec(sum(saturation; dims = 1)) .- 1.0))
    saturation_error <= 1.0e-8 ||
        error("Checkpoint $step phase saturations do not sum to one.")
    all(isfinite, rs) || error("Checkpoint $step Rs is not finite.")
    all(>=(0.0), rs) || error("Checkpoint $step Rs is negative.")
    all(isfinite, max_saturation) ||
        error("Checkpoint $step MaxSaturations is not finite.")
    all(
        value -> -1.0e-8 <= value <= 1.0 + 1.0e-8,
        max_saturation
    ) || error("Checkpoint $step MaxSaturations is outside physical bounds.")

    scanning_cells = count(
        max_saturation[2, :] .> saturation[2, :] .+ 1.0e-12
    )
    return (
        pressure_min = minimum(pressure),
        pressure_max = maximum(pressure),
        gas_saturation_min = minimum(saturation[2, :]),
        gas_saturation_max = maximum(saturation[2, :]),
        maximum_historical_gas_saturation =
            maximum(max_saturation[2, :]),
        scanning_cells = scanning_cells,
        saturation_sum_error = saturation_error,
        rs_min = minimum(rs),
        rs_max = maximum(rs)
    )
end

isdir(restart_dir) || error("Restart directory does not exist: $restart_dir")
isdir(summary_dir) || error("Summary directory does not exist: $summary_dir")

config, _ = read_named_row(joinpath(summary_dir, "production_config.tsv"))
config["case_key"] == expected_case_key ||
    error("Production configuration has the wrong case key.")
config["schedule_steps"] == string(EXPECTED_STEPS) ||
    error("Production configuration has the wrong schedule length.")
config["rolling_checkpoints"] == "2" ||
    error("Production configuration has the wrong rolling-checkpoint count.")

expected_restarts = parse_csv_values(
    Int,
    config["retain_steps"],
    "production retain_steps"
)
expected_retain_years = parse_csv_values(
    Float64,
    config["retain_years"],
    "production retain_years"
)
length(expected_restarts) == length(expected_retain_years) ||
    error("Production retained step/year counts do not match.")
expected_restarts == sort(unique(expected_restarts)) ||
    error("Production retained steps must be sorted and unique.")
all(step -> 1 <= step <= EXPECTED_STEPS, expected_restarts) ||
    error("Production retained steps are outside the schedule.")
all(year -> isfinite(year) && year >= 0.0, expected_retain_years) ||
    error("Production retained years must be finite and non-negative.")
(
    expected_restarts == LEGACY_RESTARTS ||
    expected_restarts == CURRENT_RESTARTS
) || error(
    "Unsupported Step62 retention profile $expected_restarts; expected " *
    "$LEGACY_RESTARTS (legacy recovery) or $CURRENT_RESTARTS (current)."
)

restart_indices = Jutul.valid_restart_indices(restart_dir)
restart_indices == expected_restarts || error(
    "Expected retained restart steps $expected_restarts, got $restart_indices."
)
for step in expected_restarts
    path = joinpath(restart_dir, "jutul_$step.jld2")
    isfile(path) && filesize(path) > 0 ||
        error("Retained restart checkpoint is missing or empty: $path")
end

row_dir = joinpath(summary_dir, "rows")
row_paths = [
    joinpath(row_dir, "step_$(lpad(step, 6, '0')).tsv")
    for step in 1:EXPECTED_STEPS
]
all(isfile, row_paths) ||
    error("One or more of the 210 production summary rows are missing.")
length(filter(
    name -> occursin(r"^step_\d{6}\.tsv$", name),
    readdir(row_dir)
)) == EXPECTED_STEPS ||
    error("Production summary row directory does not contain exactly 210 rows.")

consolidated_path = joinpath(summary_dir, "report_steps.tsv")
consolidated_lines = readlines(consolidated_path)
length(consolidated_lines) == EXPECTED_STEPS + 1 ||
    error("Consolidated report_steps.tsv must have 211 lines.")

rows = Vector{Dict{SubString{String}, SubString{String}}}()
global previous_time = -Inf
for step in 1:EXPECTED_STEPS
    row, lines = read_named_row(row_paths[step])
    parse(Int, row["schema_version"]) == 1 ||
        error("Summary row $step has the wrong schema.")
    parse(Int, row["step"]) == step ||
        error("Summary row $step records the wrong report step.")
    row["case_key"] == expected_case_key ||
        error("Summary row $step has the wrong case key.")
    lowercase(row["campaign_manifest_sha256"]) ==
        lowercase(expected_manifest_sha256) ||
        error("Summary row $step has the wrong campaign manifest digest.")
    time_seconds = parse(Float64, row["time_seconds"])
    isfinite(time_seconds) && time_seconds > previous_time ||
        error("Summary time is invalid or non-increasing at step $step.")
    global previous_time = time_seconds
    for name in (
            "pressure_min_pa",
            "pressure_max_pa",
            "report_solve_seconds",
            "gas_saturation_min",
            "gas_saturation_max",
            "saturation_sum_error_max",
            "historical_gas_saturation_max",
            "free_co2_mass_kg",
            "dissolved_co2_mass_kg",
            "total_co2_mass_kg"
        )
        isfinite(parse(Float64, row[name])) ||
            error("Summary row $step has a non-finite $name.")
    end
    parse(Float64, row["pressure_min_pa"]) > 0 ||
        error("Summary row $step has non-positive pressure.")
    parse(Float64, row["saturation_sum_error_max"]) <= 1.0e-6 ||
        error("Summary row $step has excessive saturation-sum error.")
    consolidated_lines[1] == lines[1] ||
        error("Consolidated summary header differs from row $step.")
    consolidated_lines[step + 1] == lines[2] ||
        error("Consolidated summary value differs at row $step.")
    push!(rows, row)
end

isapprox(
    parse(Float64, rows[78]["time_years"]),
    50.0;
    rtol = 0,
    atol = 1.0e-10
) || error("Step 78 is not the 50-year injection-end state.")
isapprox(
    parse(Float64, rows[210]["time_years"]),
    1000.0;
    rtol = 0,
    atol = 1.0e-10
) || error("Step 210 is not the 1000-year final state.")

for (step, target_year) in zip(expected_restarts, expected_retain_years)
    isapprox(
        parse(Float64, rows[step]["time_years"]),
        target_year;
        rtol = 0,
        atol = 1.0e-10
    ) || error(
        "Retained step $step does not match configured year $target_year."
    )
end

completion, _ = read_named_row(
    joinpath(summary_dir, "PRODUCTION_OUTPUT_COMPLETE.tsv")
)
completion["status"] == "complete" ||
    error("Production output completion marker does not say complete.")
completion["case_key"] == expected_case_key ||
    error("Production output completion marker has the wrong case key.")
completion["schedule_steps"] == string(EXPECTED_STEPS) ||
    error("Production output completion marker has the wrong schedule length.")
completion["retained_restart_steps"] == join(expected_restarts, ',') ||
    error("Production output completion marker has the wrong retained steps.")

qoi_schema = haskey(config, "qoi_schema_version") ?
    parse(Int, config["qoi_schema_version"]) : 0
if qoi_schema > 0
    qoi_schema in 1:JutulDarcy.PRODUCTION_QOI_SCHEMA_VERSION || error(
        "Unsupported QoI output schema $qoi_schema."
    )
    expected_qoi_mobility_method = qoi_schema == 2 ?
        QOI_MOBILITY_METHOD_V2 : JutulDarcy.PRODUCTION_QOI_MOBILITY_METHOD
    qoi_completion, _ = read_named_row(
        joinpath(summary_dir, "QOI_OUTPUT_COMPLETE.tsv")
    )
    qoi_completion["status"] == "complete" ||
        error("QoI completion marker does not say complete.")
    parse(Int, qoi_completion["schema_version"]) == qoi_schema ||
        error("QoI completion marker has the wrong schema.")
    qoi_completion["case_key"] == expected_case_key ||
        error("QoI completion marker has the wrong case key.")
    qoi_completion["schedule_steps"] == string(EXPECTED_STEPS) ||
        error("QoI completion marker has the wrong schedule length.")

    _, global_qoi = read_table(
        joinpath(summary_dir, "leakage_global_steps.tsv")
    )
    length(global_qoi) == EXPECTED_STEPS || error(
        "QoI global table has $(length(global_qoi)) rows, expected " *
        "$EXPECTED_STEPS."
    )
    for step in 1:EXPECTED_STEPS
        qoi = global_qoi[step]
        parse(Int, qoi["schema_version"]) == qoi_schema ||
            error("Global QoI row $step has the wrong schema.")
        parse(Int, qoi["step"]) == step ||
            error("Global QoI row $step has the wrong step.")
        qoi["case_key"] == expected_case_key ||
            error("Global QoI row $step has the wrong case key.")
        qoi_seconds = parse(Float64, qoi["qoi_evaluation_seconds"])
        isfinite(qoi_seconds) && qoi_seconds >= 0.0 ||
            error("Global QoI row $step has invalid evaluation time.")
        require_close(
            parse(Float64, qoi["time_seconds"]),
            parse(Float64, rows[step]["time_seconds"]),
            "Global QoI time at step $step";
            rtol = 0.0,
            atol = 1.0e-8
        )
        require_close(
            parse(Float64, qoi["domain_total_co2_mass_kg"]),
            parse(Float64, rows[step]["total_co2_mass_kg"]),
            "Global QoI/report CO2 mass at step $step"
        )
        if qoi_schema >= 2
            qoi["mobility_partition_method"] ==
                expected_qoi_mobility_method || error(
                "Global QoI row $step has the wrong mobility method."
            )
            free = parse(Float64, qoi["domain_free_co2_mass_kg"])
            mobile = parse(
                Float64,
                qoi["domain_mobile_free_co2_mass_kg"]
            )
            immobile = parse(
                Float64,
                qoi["domain_immobile_free_co2_mass_kg"]
            )
            drainage_critical = parse(
                Float64,
                qoi[
                    "domain_drainage_critical_immobile_free_co2_mass_kg"
                ]
            )
            residual = parse(
                Float64,
                qoi["domain_residual_trapped_co2_mass_kg"]
            )
            hysteresis_incremental = qoi_schema >= 3 ? parse(
                Float64,
                qoi["domain_hysteresis_incremental_trapped_co2_mass_kg"]
            ) : residual
            dissolved = parse(
                Float64,
                qoi["domain_dissolved_co2_mass_kg"]
            )
            total = parse(Float64, qoi["domain_total_co2_mass_kg"])
            all(
                value -> isfinite(value) && value >= -1.0e-6,
                (free, mobile, immobile, drainage_critical,
                    residual, hysteresis_incremental, dissolved, total)
            ) || error("Global QoI row $step has an invalid component mass.")
            require_close(free, mobile + immobile,
                "Global free-phase partition at step $step")
            require_close(immobile, drainage_critical + residual,
                "Global immobile partition at step $step")
            require_close(total, free + dissolved,
                "Global dissolved/free partition at step $step")
            if qoi_schema >= 3
                hysteresis_incremental <= residual +
                    max(
                        1.0e-6,
                        1.0e-10*max(residual, hysteresis_incremental)
                    ) || error(
                    "Global incremental hysteresis-trapped mass exceeds " *
                    "total residual-trapped mass at step $step."
                )
            end
            parse(
                Float64,
                qoi["domain_residual_trapped_gas_pore_volume_m3"]
            ) >= -1.0e-12 || error(
                "Global residual-trapped pore volume is negative at step $step."
            )
            active_count = parse(
                Int,
                qoi["domain_hysteresis_active_cell_count"]
            )
            scanning_count = parse(
                Int,
                qoi["domain_hysteresis_scanning_cell_count"]
            )
            residual_count = parse(
                Int,
                qoi["domain_residual_trapped_cell_count"]
            )
            0 <= scanning_count <= active_count <= EXPECTED_CELLS || error(
                "Global hysteresis branch counts are invalid at step $step."
            )
            0 <= residual_count <= active_count || error(
                "Global residual-trapped cell count is invalid at step $step."
            )
            if qoi_schema >= 3
                incremental_count = parse(
                    Int,
                    qoi["domain_hysteresis_incremental_trapped_cell_count"]
                )
                0 <= incremental_count <= residual_count || error(
                    "Global incremental hysteresis-trapped cell count is " *
                    "invalid at step $step."
                )
            end
        end
    end

    if qoi_schema >= 2
        config["qoi_mobility_partition_method"] ==
            expected_qoi_mobility_method || error(
            "Production configuration has the wrong QoI mobility method."
        )
        qoi_completion["mobility_partition_method"] ==
            expected_qoi_mobility_method || error(
            "QoI completion marker has the wrong mobility method."
        )
        _, region_manifest = read_table(
            joinpath(summary_dir, "qoi_region_manifest.tsv")
        )
        _, regional_qoi = read_table(
            joinpath(summary_dir, "regional_co2_inventory_steps.tsv")
        )
        nregions = length(region_manifest)
        length(regional_qoi) == EXPECTED_STEPS*nregions || error(
            "QoI regional table has $(length(regional_qoi)) rows, expected " *
            "$(EXPECTED_STEPS*nregions)."
        )
        for step in 1:EXPECTED_STEPS
            selected = filter(
                row -> parse(Int, row["step"]) == step,
                regional_qoi
            )
            length(selected) == nregions || error(
                "QoI step $step has $(length(selected)) regional rows, " *
                "expected $nregions."
            )
            by_id = Dict(row["region_id"] => row for row in selected)
            length(by_id) == nregions ||
                error("QoI step $step has duplicate regional rows.")
            domain = by_id["domain_all"]
            atomic = filter(row -> row["region_role"] == "atomic", selected)
            for row in selected
                id = row["region_id"]
                free = parse(Float64, row["free_co2_mass_kg"])
                mobile = parse(Float64, row["mobile_free_co2_mass_kg"])
                immobile = parse(Float64, row["immobile_free_co2_mass_kg"])
                drainage_critical = parse(
                    Float64,
                    row["drainage_critical_immobile_free_co2_mass_kg"]
                )
                residual = parse(Float64, row["residual_trapped_co2_mass_kg"])
                hysteresis_incremental = qoi_schema >= 3 ? parse(
                    Float64,
                    row["hysteresis_incremental_trapped_co2_mass_kg"]
                ) : residual
                dissolved = parse(Float64, row["dissolved_co2_mass_kg"])
                total = parse(Float64, row["total_co2_mass_kg"])
                require_close(free, mobile + immobile,
                    "Regional free-phase partition for $id at step $step")
                require_close(immobile, drainage_critical + residual,
                    "Regional immobile partition for $id at step $step")
                require_close(total, free + dissolved,
                    "Regional dissolved/free partition for $id at step $step")
                if qoi_schema >= 3
                    hysteresis_incremental <= residual +
                        max(
                            1.0e-6,
                            1.0e-10*max(residual, hysteresis_incremental)
                        ) || error(
                        "Regional incremental hysteresis-trapped mass " *
                        "exceeds total residual-trapped mass for $id at " *
                        "step $step."
                    )
                end

                gas_pv = parse(Float64, row["gas_filled_pore_volume_m3"])
                mobile_pv = parse(
                    Float64,
                    row["mobile_free_gas_pore_volume_m3"]
                )
                immobile_pv = parse(
                    Float64,
                    row["immobile_free_gas_pore_volume_m3"]
                )
                critical_pv = parse(
                    Float64,
                    row["drainage_critical_immobile_gas_pore_volume_m3"]
                )
                residual_pv = parse(
                    Float64,
                    row["residual_trapped_gas_pore_volume_m3"]
                )
                hysteresis_incremental_pv = qoi_schema >= 3 ? parse(
                    Float64,
                    row["hysteresis_incremental_trapped_gas_pore_volume_m3"]
                ) : residual_pv
                require_close(gas_pv, mobile_pv + immobile_pv,
                    "Regional gas-volume partition for $id at step $step")
                require_close(immobile_pv, critical_pv + residual_pv,
                    "Regional immobile-volume partition for $id at step $step")
                if qoi_schema >= 3
                    hysteresis_incremental_pv <= residual_pv +
                        max(
                            1.0e-6,
                            1.0e-10*max(
                                residual_pv,
                                hysteresis_incremental_pv
                            )
                        ) || error(
                        "Regional incremental hysteresis-trapped gas volume " *
                        "exceeds total residual-trapped gas volume for $id " *
                        "at step $step."
                    )
                end

                pore_volume = parse(Float64, row["pore_volume_m3"])
                occupied = [
                    parse(Float64, row["pore_volume_sg_ge_1e_4_m3"]),
                    parse(Float64, row["pore_volume_sg_ge_1e_3_m3"]),
                    parse(Float64, row["pore_volume_sg_ge_1e_2_m3"])
                ]
                0.0 <= occupied[3] <= occupied[2] <= occupied[1] <=
                    pore_volume + max(1.0e-6, 1.0e-12*pore_volume) || error(
                    "Regional occupied pore volumes are invalid for $id " *
                    "at step $step."
                )
                critical_mean = parse(
                    Float64,
                    row["active_gas_critical_saturation_pv_weighted_mean"]
                )
                critical_max = parse(
                    Float64,
                    row["active_gas_critical_saturation_max"]
                )
                0.0 <= critical_mean <= critical_max <= 1.0 || error(
                    "Regional active critical saturation is invalid for " *
                    "$id at step $step."
                )
                for (mass, prefix) in (
                        (free, "free_co2"),
                        (dissolved, "dissolved_co2")
                    )
                    for axis in ("x", "y", "z")
                        centroid = parse(
                            Float64,
                            row["$(prefix)_centroid_$(axis)_m"]
                        )
                        spread = parse(
                            Float64,
                            row["$(prefix)_spread_$(axis)_m"]
                        )
                        if mass > 1.0e-12
                            isfinite(centroid) && isfinite(spread) &&
                                spread >= 0.0 || error(
                                "Regional $prefix moments are invalid for " *
                                "$id at step $step."
                            )
                        end
                    end
                end
            end

            for field in (
                    "free_co2_mass_kg",
                    "mobile_free_co2_mass_kg",
                    "immobile_free_co2_mass_kg",
                    "drainage_critical_immobile_free_co2_mass_kg",
                    "residual_trapped_co2_mass_kg",
                    "dissolved_co2_mass_kg",
                    "total_co2_mass_kg"
                )
                atomic_sum = sum(parse(Float64, row[field]) for row in atomic)
                require_close(
                    atomic_sum,
                    parse(Float64, domain[field]),
                    "Atomic/domain $field at step $step"
                )
            end
            if qoi_schema >= 3
                field = "hysteresis_incremental_trapped_co2_mass_kg"
                atomic_sum = sum(parse(Float64, row[field]) for row in atomic)
                require_close(
                    atomic_sum,
                    parse(Float64, domain[field]),
                    "Atomic/domain $field at step $step"
                )
            end
            global_row = global_qoi[step]
            for (regional_field, global_field) in (
                    ("free_co2_mass_kg", "domain_free_co2_mass_kg"),
                    (
                        "mobile_free_co2_mass_kg",
                        "domain_mobile_free_co2_mass_kg"
                    ),
                    (
                        "immobile_free_co2_mass_kg",
                        "domain_immobile_free_co2_mass_kg"
                    ),
                    (
                        "drainage_critical_immobile_free_co2_mass_kg",
                        "domain_drainage_critical_immobile_free_co2_mass_kg"
                    ),
                    (
                        "residual_trapped_co2_mass_kg",
                        "domain_residual_trapped_co2_mass_kg"
                    ),
                    ("dissolved_co2_mass_kg", "domain_dissolved_co2_mass_kg"),
                    ("total_co2_mass_kg", "domain_total_co2_mass_kg")
                )
                require_close(
                    parse(Float64, domain[regional_field]),
                    parse(Float64, global_row[global_field]),
                    "Regional/global $regional_field at step $step"
                )
            end
            if qoi_schema >= 3
                require_close(
                    parse(
                        Float64,
                        domain["hysteresis_incremental_trapped_co2_mass_kg"]
                    ),
                    parse(
                        Float64,
                        global_row[
                            "domain_hysteresis_incremental_trapped_co2_mass_kg"
                        ]
                    ),
                    "Regional/global incremental hysteresis-trapped mass " *
                    "at step $step"
                )
            end
        end
    end
end

schema4_summary = validate_schema4_output(config, rows, expected_case_key)

retained_states = Dict(step => validate_state(step) for step in expected_restarts)
injection_end = retained_states[78]
final_state = retained_states[210]
final_state.scanning_cells > 0 ||
    error("Final hysteresis state has no gas scanning cells.")
parse(Int, rows[210]["hysteresis_scanning_cells"]) ==
    final_state.scanning_cells ||
    error("Final summary scanning-cell count differs from retained state.")

total_newtons = sum(parse(Int, row["newton_iterations"]) for row in rows)
total_linear_iterations =
    sum(parse(Int, row["linear_iterations"]) for row in rows)
total_ministeps = sum(parse(Int, row["ministeps"]) for row in rows)
failed_ministeps =
    sum(parse(Int, row["failed_ministeps"]) for row in rows)
total_solve_seconds =
    sum(parse(Float64, row["report_solve_seconds"]) for row in rows)

mkpath(dirname(output_path))
open(output_path, "w") do io
    println(io, "status=pass")
    println(io, "case_key=$expected_case_key")
    println(io, "campaign_manifest_sha256=$(lowercase(expected_manifest_sha256))")
    println(io, "grid=step62")
    println(io, "resolution_slices=87")
    println(io, "cells=$EXPECTED_CELLS")
    println(io, "report_steps=$EXPECTED_STEPS")
    println(io, "summary_rows=$EXPECTED_STEPS")
    println(io, "retained_restart_steps=$(join(expected_restarts, ','))")
    println(io, "retained_restart_years=$(join(expected_retain_years, ','))")
    println(io, "injection_end_step=78")
    println(io, "injection_end_years=50")
    println(io, "final_step=210")
    println(io, "final_years=1000")
    println(io, "nonlinear_iterations=$total_newtons")
    println(io, "linear_iterations=$total_linear_iterations")
    println(io, "ministeps=$total_ministeps")
    println(io, "failed_ministeps=$failed_ministeps")
    println(io, "total_report_solve_seconds=$total_solve_seconds")
    println(io, "injection_end_pressure_min_Pa=$(injection_end.pressure_min)")
    println(io, "injection_end_pressure_max_Pa=$(injection_end.pressure_max)")
    println(io, "final_pressure_min_Pa=$(final_state.pressure_min)")
    println(io, "final_pressure_max_Pa=$(final_state.pressure_max)")
    println(io, "final_gas_saturation_min=$(final_state.gas_saturation_min)")
    println(io, "final_gas_saturation_max=$(final_state.gas_saturation_max)")
    println(
        io,
        "final_maximum_historical_gas_saturation=" *
        string(final_state.maximum_historical_gas_saturation)
    )
    println(io, "final_gas_scanning_cells=$(final_state.scanning_cells)")
    println(io, "final_rs_min=$(final_state.rs_min)")
    println(io, "final_rs_max=$(final_state.rs_max)")
    println(io, "qoi_output_schema=$qoi_schema")
    if qoi_schema >= 2
        println(
            io,
            "qoi_mobility_partition_method=" *
            expected_qoi_mobility_method
        )
        println(io, "qoi_mass_partition_validated=true")
        println(io, "qoi_atomic_partition_validated=true")
    end
    if !isnothing(schema4_summary)
        println(io, "qoi_schema4_version=$(schema4_summary.schema)")
        println(io, "qoi_schema4_validated=true")
        println(io, "qoi_schema4_spatial_bytes=$(schema4_summary.spatial_bytes)")
        println(
            io,
            "qoi_schema4_accepted_ministeps=" *
            string(schema4_summary.accepted_ministeps)
        )
        println(
            io,
            "qoi_schema4_accounting_seconds=" *
            string(schema4_summary.accounting_seconds)
        )
    end
    println(io, "production_output_mode=true")
end

println(
    "STEP62_PRODUCTION_FINAL_CHECK_PASS " *
    "case=$expected_case_key summary=$output_path"
)
