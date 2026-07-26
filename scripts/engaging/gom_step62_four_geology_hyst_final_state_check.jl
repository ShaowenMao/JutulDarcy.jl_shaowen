using JutulDarcy
import Jutul

length(ARGS) == 2 || error(
    "Usage: gom_step62_four_geology_hyst_final_state_check.jl " *
    "RESTART_DIR SUMMARY_PATH"
)
restart_dir, summary_path = ARGS

const EXPECTED_CELLS = 2_165_082
const EXPECTED_REPORT_STEPS = 210

indices = Jutul.valid_restart_indices(restart_dir)
indices == collect(1:EXPECTED_REPORT_STEPS) || error(
    "Expected restart steps 1:$EXPECTED_REPORT_STEPS, got $indices."
)

reports = Any[]
for step in indices
    _, report = Jutul.read_restart(
        restart_dir,
        step;
        read_state = false,
        read_report = true
    )
    isnothing(report) || push!(reports, report)
end
length(reports) == EXPECTED_REPORT_STEPS || error(
    "Expected $EXPECTED_REPORT_STEPS reports, got $(length(reports))."
)
stats = Jutul.report_stats(reports)
failed_ministeps = sum(
    count(ministep -> !ministep[:success], report[:ministeps])
    for report in reports
)
successful_ministeps = sum(
    count(ministep -> ministep[:success], report[:ministeps])
    for report in reports
)

state, _ = Jutul.read_restart(
    restart_dir,
    EXPECTED_REPORT_STEPS;
    read_state = true,
    read_report = false
)
reservoir = state[:Reservoir]
pressure = vec(reservoir[:Pressure])
saturation = reservoir[:Saturations]
rs = vec(reservoir[:Rs])
max_saturation = reservoir[:MaxSaturations]

@assert length(pressure) == EXPECTED_CELLS
@assert size(saturation) == (2, EXPECTED_CELLS)
@assert length(rs) == EXPECTED_CELLS
@assert size(max_saturation) == size(saturation)
@assert all(isfinite, pressure)
@assert all(>(0.0), pressure)
@assert all(isfinite, saturation)
@assert all(value -> -1.0e-8 <= value <= 1.0 + 1.0e-8, saturation)
@assert maximum(abs.(vec(sum(saturation; dims = 1)) .- 1.0)) <= 1.0e-8
@assert all(isfinite, rs)
@assert all(>=(0.0), rs)
@assert all(isfinite, max_saturation)
@assert all(value -> -1.0e-8 <= value <= 1.0 + 1.0e-8, max_saturation)

gas_scanning_cells = count(
    max_saturation[2, :] .> saturation[2, :] .+ 1.0e-8
)
gas_scanning_cells > 0 ||
    error("Final hysteresis state has no gas scanning cells.")
gas_current_above_stored_cells = count(
    saturation[2, :] .> max_saturation[2, :] .+ 1.0e-8
)

mkpath(dirname(summary_path))
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "grid=step62")
    println(io, "resolution_slices=87")
    println(io, "report_steps=$EXPECTED_REPORT_STEPS")
    println(io, "cells=$(length(pressure))")
    println(io, "nonlinear_iterations=$(stats.newtons)")
    println(io, "linear_iterations=$(stats.linear_iterations)")
    println(io, "successful_ministeps=$successful_ministeps")
    println(io, "failed_ministeps=$failed_ministeps")
    println(io, "wasted_nonlinear_iterations=$(stats.wasted.newtons)")
    println(io, "wasted_linear_iterations=$(stats.wasted.linear_iterations)")
    println(io, "pressure_min_Pa=$(minimum(pressure))")
    println(io, "pressure_max_Pa=$(maximum(pressure))")
    println(io, "gas_saturation_min=$(minimum(saturation[2, :]))")
    println(io, "gas_saturation_max=$(maximum(saturation[2, :]))")
    println(io, "maximum_historical_gas_saturation=$(maximum(max_saturation[2, :]))")
    println(io, "gas_scanning_cells=$gas_scanning_cells")
    println(io, "gas_current_above_stored_cells=$gas_current_above_stored_cells")
    println(io, "maximum_saturation_sum_error=$(maximum(abs.(vec(sum(saturation; dims = 1)) .- 1.0)))")
    println(io, "rs_min=$(minimum(rs))")
    println(io, "rs_max=$(maximum(rs))")
end

println(
    "STEP62_FOUR_GEOLOGY_HYST_FINAL_STATE_PASS summary=$summary_path"
)
