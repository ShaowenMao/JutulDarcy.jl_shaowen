driver_path = joinpath(
    pkgdir(JutulDarcy),
    "src",
    "input_simulation",
    "co2_case_driver_common.jl"
)
include(driver_path)

off_options = co2_case_options(case_name = "GOM_SMALL")
@test off_options.production_qoi_mode == "off"
@test off_options.production_retain_years == [25.0, 50.0, 100.0, 1000.0]

required_options = co2_case_options(
    case_name = "GOM_SMALL",
    production_output_mode = true,
    production_summary_dir = mktempdir(),
    production_qoi_mode = " REQUIRED ",
    in_memory_reports = 1,
    load_all_states_after_sim = false,
    load_all_reports_after_sim = false
)
@test required_options.production_qoi_mode == "required"

@test_throws ErrorException co2_case_options(
    case_name = "GOM_SMALL",
    production_qoi_mode = "invalid"
)
@test_throws ErrorException co2_case_options(
    case_name = "GOM_SMALL",
    production_qoi_mode = "required"
)
