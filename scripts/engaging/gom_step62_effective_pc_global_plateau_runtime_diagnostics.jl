length(ARGS) == 4 || error(
    "Usage: gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl " *
    "SUMMARY_DIR OUTPUT_PATH EXPECTED_STEPS PREFLIGHT_SUMMARY"
)
summary_dir, output_path, expected_steps_text, preflight_path = ARGS
expected_steps = parse(Int, expected_steps_text)

function parse_tsv(path)
    isfile(path) && filesize(path) > 0 ||
        error("Missing diagnostic input: $path")
    lines = readlines(path)
    length(lines) >= 2 || error("$path contains no data rows.")
    header = String.(split(lines[1], '\t'; keepempty = true))
    length(unique(header)) == length(header) ||
        error("$path contains duplicate columns.")
    rows = Dict{String, String}[]
    for (offset, line) in enumerate(lines[2:end])
        line_number = offset + 1
        values = String.(split(line, '\t'; keepempty = true))
        length(values) == length(header) ||
            error("$path line $line_number has the wrong field count.")
        push!(rows, Dict(header .=> values))
    end
    return rows
end

function parse_key_values(path)
    isfile(path) && filesize(path) > 0 ||
        error("Missing diagnostic contract: $path")
    values = Dict{String, String}()
    for (line_number, line) in enumerate(readlines(path))
        parts = split(line, '='; limit = 2)
        length(parts) == 2 ||
            error("$path line $line_number is not key=value.")
        haskey(values, parts[1]) &&
            error("$path contains duplicate key $(parts[1]).")
        values[String(parts[1])] = String(parts[2])
    end
    return values
end

report_rows = parse_tsv(joinpath(summary_dir, "report_steps.tsv"))
length(report_rows) == expected_steps ||
    error("Expected $expected_steps report rows, got $(length(report_rows)).")
all(parse(Int, row["step"]) == index
    for (index, row) in enumerate(report_rows)) ||
    error("Production report steps are not contiguous.")

total_ministeps = sum(parse(Int, row["ministeps"]) for row in report_rows)
failed_ministeps =
    sum(parse(Int, row["failed_ministeps"]) for row in report_rows)
newton_iterations =
    sum(parse(Int, row["newton_iterations"]) for row in report_rows)
linear_iterations =
    sum(parse(Int, row["linear_iterations"]) for row in report_rows)
wasted_newton_iterations = sum(
    parse(Int, row["wasted_newton_iterations"]) for row in report_rows
)
wasted_linear_iterations = sum(
    parse(Int, row["wasted_linear_iterations"]) for row in report_rows
)
report_seconds = parse.(Float64, getindex.(report_rows, "time_seconds"))
report_dt = diff(vcat(0.0, report_seconds))
all(>(0.0), report_dt) || error("Report-step durations are not positive.")

region_rows = parse_tsv(
    joinpath(summary_dir, "regional_co2_inventory_steps.tsv")
)
length(region_rows) == expected_steps*69 ||
    error("Unexpected regional QoI row count.")
host_ids = Set(["storage_lm2", "stratigraphy_sand", "mm_um", "younger"])
host_rows = filter(row -> row["region_id"] in host_ids, region_rows)
nonpredict_rows = filter(
    row -> row["region_id"] == "fault_nonpredict_all",
    region_rows
)
length(host_rows) == expected_steps*length(host_ids) ||
    error("Host-sand QoI rows are incomplete.")
length(nonpredict_rows) == expected_steps ||
    error("Non-PREDICT-fault QoI rows are incomplete.")
host_max_sg = maximum(
    parse(Float64, row["gas_saturation_max"]) for row in host_rows
)
nonpredict_max_sg = maximum(
    parse(Float64, row["gas_saturation_max"]) for row in nonpredict_rows
)
host_final_max_sg = maximum(
    parse(Float64, row["gas_saturation_max"])
    for row in host_rows if parse(Int, row["step"]) == expected_steps
)
nonpredict_final_max_sg = only([
    parse(Float64, row["gas_saturation_max"])
    for row in nonpredict_rows if parse(Int, row["step"]) == expected_steps
])

preflight = parse_key_values(preflight_path)
preflight["status"] == "pass" ||
    error("Preflight Pc table contract did not pass.")
max_pc_slope = parse(
    Float64,
    preflight["pc_max_piecewise_slope_pa_per_sg"]
)
isfinite(max_pc_slope) && max_pc_slope >= 0 ||
    error("Preflight maximum piecewise Pc slope is invalid.")

mkpath(dirname(output_path))
open(output_path, "w") do io
    println(io, "status=pass")
    println(io, "report_steps=$expected_steps")
    println(io, "total_ministeps=$total_ministeps")
    println(io, "newton_iterations=$newton_iterations")
    println(io, "linear_iterations=$linear_iterations")
    println(io, "rejected_or_cut_ministeps=$failed_ministeps")
    println(io, "wasted_newton_iterations=$wasted_newton_iterations")
    println(io, "wasted_linear_iterations=$wasted_linear_iterations")
    println(io, "smallest_report_timestep_seconds=$(minimum(report_dt))")
    println(io, "smallest_accepted_ministep_seconds=unavailable")
    println(
        io,
        "smallest_accepted_ministep_reason=" *
        "production_output_v1_does_not_retain_ministep_dt"
    )
    println(io, "host_regions_max_gas_saturation=$host_max_sg")
    println(io, "host_regions_final_max_gas_saturation=$host_final_max_sg")
    println(io, "nonpredict_fault_max_gas_saturation=$nonpredict_max_sg")
    println(
        io,
        "nonpredict_fault_final_max_gas_saturation=$nonpredict_final_max_sg"
    )
    println(io, "pc_cap_onset_interval_cell_counts=unavailable")
    println(
        io,
        "pc_cap_onset_interval_cell_counts_reason=" *
        "production_output_v1_does_not_retain_cellwise_saturation"
    )
    println(io, "pc_max_piecewise_slope_pa_per_sg=$max_pc_slope")
end

println(
    "STEP62_EFFECTIVE_PC_RUNTIME_DIAGNOSTICS_PASS " *
    "steps=$expected_steps output=$output_path"
)
