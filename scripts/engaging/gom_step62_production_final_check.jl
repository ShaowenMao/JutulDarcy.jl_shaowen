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
const EXPECTED_RESTARTS = [78, 210]

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

restart_indices = Jutul.valid_restart_indices(restart_dir)
restart_indices == EXPECTED_RESTARTS || error(
    "Expected retained restart steps $EXPECTED_RESTARTS, got $restart_indices."
)
for step in EXPECTED_RESTARTS
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
previous_time = -Inf
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
    previous_time = time_seconds
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

config, _ = read_named_row(joinpath(summary_dir, "production_config.tsv"))
config["case_key"] == expected_case_key ||
    error("Production configuration has the wrong case key.")
config["schedule_steps"] == string(EXPECTED_STEPS) ||
    error("Production configuration has the wrong schedule length.")
config["retain_steps"] == "78,210" ||
    error("Production configuration has the wrong retained steps.")
config["retain_years"] == "50.0,1000.0" ||
    error("Production configuration has the wrong retained years.")
config["rolling_checkpoints"] == "2" ||
    error("Production configuration has the wrong rolling-checkpoint count.")

completion, _ = read_named_row(
    joinpath(summary_dir, "PRODUCTION_OUTPUT_COMPLETE.tsv")
)
completion["status"] == "complete" ||
    error("Production output completion marker does not say complete.")
completion["case_key"] == expected_case_key ||
    error("Production output completion marker has the wrong case key.")
completion["schedule_steps"] == string(EXPECTED_STEPS) ||
    error("Production output completion marker has the wrong schedule length.")
completion["retained_restart_steps"] == "78,210" ||
    error("Production output completion marker has the wrong retained steps.")

injection_end = validate_state(78)
final_state = validate_state(210)
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
    println(io, "retained_restart_steps=$(join(EXPECTED_RESTARTS, ','))")
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
    println(io, "production_output_mode=true")
end

println(
    "STEP62_PRODUCTION_FINAL_CHECK_PASS " *
    "case=$expected_case_key summary=$output_path"
)
