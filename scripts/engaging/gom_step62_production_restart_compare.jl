using JutulDarcy
import Jutul

function main(args)
length(args) == 4 || error(
    "Usage: gom_step62_production_restart_compare.jl " *
    "RESUMED_RESTART CONTROL_RESTART STEP OUTPUT"
)
resumed_dir, control_dir, step_text, output_path = args
step = parse(Int, step_text)

resumed, _ = Jutul.read_restart(
    resumed_dir, step; read_state = true, read_report = false
)
control, _ = Jutul.read_restart(
    control_dir, step; read_state = true, read_report = false
)
resumed_reservoir = resumed[:Reservoir]
control_reservoir = control[:Reservoir]

fields = (
    :Pressure,
    :Saturations,
    :Rs,
    :MaxSaturations,
    :FluidVolume,
    :PhaseMassDensities,
    :ShrinkageFactors
)
maximum_absolute_difference = 0.0
maximum_relative_difference = 0.0
for field in fields
    haskey(resumed_reservoir, field) ||
        error("Resumed state lacks $field.")
    haskey(control_reservoir, field) ||
        error("Control state lacks $field.")
    resumed_values = resumed_reservoir[field]
    control_values = control_reservoir[field]
    size(resumed_values) == size(control_values) ||
        error("$field shape differs between resumed and control states.")
    difference = abs.(resumed_values .- control_values)
    field_absolute = isempty(difference) ? 0.0 : maximum(difference)
    scale = max.(
        abs.(resumed_values),
        abs.(control_values),
        eps(Float64)
    )
    field_relative = isempty(difference) ?
        0.0 : maximum(difference ./ scale)
    maximum_absolute_difference =
        max(maximum_absolute_difference, field_absolute)
    maximum_relative_difference =
        max(maximum_relative_difference, field_relative)
    all(isapprox.(
        resumed_values,
        control_values;
        rtol = 1.0e-12,
        atol = 0.0
    )) || error(
        "$field differs after interruption/restart: " *
        "max_abs=$field_absolute max_rel=$field_relative"
    )
end

mkpath(dirname(output_path))
open(output_path, "w") do io
    println(io, "status=pass")
    println(io, "step=$step")
    println(io, "fields=$(join(fields, ','))")
    println(io, "rtol=1e-12")
    println(io, "atol=0")
    println(io, "maximum_absolute_difference=$maximum_absolute_difference")
    println(io, "maximum_relative_difference=$maximum_relative_difference")
end
println("PRODUCTION_RESTART_EQUIVALENCE_PASS output=$output_path")
return nothing
end

main(ARGS)
