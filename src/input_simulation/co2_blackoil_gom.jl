include(joinpath(@__DIR__, "co2_case_driver_common.jl"))

const GOM_CASE_NAMES = ("GOM_SMALL", "GOM_MEDIUM", "GOM_LARGE")

function gom_case_name(case_name::AbstractString)
    case_name = uppercase(case_name)
    if !(case_name in GOM_CASE_NAMES)
        error("Unknown GoM CASE_NAME = $case_name. Valid options: $(join(GOM_CASE_NAMES, ", "))")
    end
    return case_name
end

function run_co2_blackoil_gom(; case_name::AbstractString = co2_get_env_str("CASE_NAME", "GOM_SMALL"), kwarg...)
    return run_co2_case(; case_name = gom_case_name(case_name), kwarg...)
end

function export_co2_blackoil_gom_vtu(; case_name::AbstractString = co2_get_env_str("CASE_NAME", "GOM_SMALL"), kwarg...)
    return export_co2_case_vtu(; case_name = gom_case_name(case_name), kwarg...)
end

function run_co2_blackoil_gom_from_env()
    return run_co2_case_from_env(
        default_case_name = "GOM_SMALL",
        allowed_case_names = GOM_CASE_NAMES
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_co2_blackoil_gom_from_env()
end
