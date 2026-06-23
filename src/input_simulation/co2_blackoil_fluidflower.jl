include(joinpath(@__DIR__, "co2_case_driver_common.jl"))

function run_co2_blackoil_fluidflower(; kwarg...)
    return run_co2_case(; case_name = "FLUIDFLOWER", kwarg...)
end

function export_co2_blackoil_fluidflower_vtu(; kwarg...)
    return export_co2_case_vtu(; case_name = "FLUIDFLOWER", kwarg...)
end

function run_co2_blackoil_fluidflower_from_env()
    return run_co2_case_from_env(
        default_case_name = "FLUIDFLOWER",
        force_case_name = "FLUIDFLOWER"
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_co2_blackoil_fluidflower_from_env()
end
