using JutulDarcy
import Jutul

function read_named_row(path)
    lines = readlines(path)
    length(lines) == 2 || error("$path must contain exactly two lines.")
    header = split(lines[1], '\t'; keepempty = true)
    values = split(lines[2], '\t'; keepempty = true)
    length(header) == length(values) || error(
        "$path has different header/value counts."
    )
    return Dict(header .=> values)
end

function compare_schema4(resumed_dir, control_dir, step)
    resumed_root = joinpath(resumed_dir, "production_output", "qoi_schema4")
    control_root = joinpath(control_dir, "production_output", "qoi_schema4")
    resumed_present = isdir(resumed_root)
    control_present = isdir(control_root)
    resumed_present == control_present || error(
        "Schema-4 output exists for only one restart-equivalence run."
    )
    resumed_present || return false

    filename = "step_$(lpad(step, 6, '0'))"
    resumed_binary = joinpath(resumed_root, "spatial_rows", filename * ".bin")
    control_binary = joinpath(control_root, "spatial_rows", filename * ".bin")
    isfile(resumed_binary) && isfile(control_binary) || error(
        "A schema-4 spatial record is missing at step $step."
    )
    read(resumed_binary) == read(control_binary) || error(
        "Schema-4 spatial histories differ after interruption/restart."
    )

    resumed_row = read_named_row(
        joinpath(resumed_root, "rows", filename * ".tsv")
    )
    control_row = read_named_row(
        joinpath(control_root, "rows", filename * ".tsv")
    )
    keys(resumed_row) == keys(control_row) || error(
        "Schema-4 scalar columns differ after interruption/restart."
    )
    timing_fields = Set((
        "ministep_accounting_seconds",
        "spatial_evaluation_seconds"
    ))
    for key in keys(resumed_row)
        resumed_value = resumed_row[key]
        control_value = control_row[key]
        if key in timing_fields
            resumed_time = parse(Float64, resumed_value)
            control_time = parse(Float64, control_value)
            all(value -> isfinite(value) && value >= 0.0,
                (resumed_time, control_time)) || error(
                "Schema-4 timing field $key is invalid."
            )
            continue
        end
        resumed_value == control_value && continue
        resumed_number = tryparse(Float64, resumed_value)
        control_number = tryparse(Float64, control_value)
        !isnothing(resumed_number) && !isnothing(control_number) &&
            isapprox(
                resumed_number,
                control_number;
                rtol = 1.0e-12,
                atol = 1.0e-8
            ) || error(
            "Schema-4 scalar $key differs after interruption/restart: " *
            "$resumed_value versus $control_value."
        )
    end
    return true
end

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

schema4_compared = compare_schema4(resumed_dir, control_dir, step)

mkpath(dirname(output_path))
open(output_path, "w") do io
    println(io, "status=pass")
    println(io, "step=$step")
    println(io, "fields=$(join(fields, ','))")
    println(io, "rtol=1e-12")
    println(io, "atol=0")
    println(io, "maximum_absolute_difference=$maximum_absolute_difference")
    println(io, "maximum_relative_difference=$maximum_relative_difference")
    println(io, "schema4_compared=$schema4_compared")
end
println("PRODUCTION_RESTART_EQUIVALENCE_PASS output=$output_path")
return nothing
end

main(ARGS)
