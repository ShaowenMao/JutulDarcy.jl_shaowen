function co2_env_enabled(name::String, default::Bool)
    val = lowercase(get(ENV, name, string(default)))
    return val in ("1", "true", "yes", "y")
end

function co2_maybe_load_revise()
    # Useful for local VSCode work, but keep batch/HPC runs free of Revise.
    enable_revise = co2_env_enabled("ENABLE_REVISE", Sys.iswindows() && isinteractive())
    if enable_revise
        try
            @eval using Revise
        catch err
            @warn "Revise could not be loaded. Continuing without it." exception = (err, catch_backtrace())
        end
    end
    return nothing
end

co2_maybe_load_revise()
using JutulDarcy
using HYPRE

co2_get_env_str(name::String, default::String) = get(ENV, name, default)

function co2_get_env_optional_str(name::String)
    val = strip(get(ENV, name, ""))
    return isempty(val) ? nothing : val
end

function co2_get_env_int(name::String, default::Int)
    return parse(Int, get(ENV, name, string(default)))
end

function co2_get_env_optional_int(name::String)
    val = strip(get(ENV, name, ""))
    return isempty(val) ? nothing : parse(Int, val)
end

function co2_get_env_float(name::String, default::Real)
    return parse(Float64, get(ENV, name, string(default)))
end

function co2_get_env_optional_float(name::String)
    val = strip(get(ENV, name, ""))
    return isempty(val) ? nothing : parse(Float64, val)
end

function co2_get_env_float_list(name::String, default)
    raw = strip(get(ENV, name, join(default, ",")))
    isempty(raw) && return Float64[]
    return parse.(Float64, strip.(split(raw, ",")))
end

function co2_get_env_bool(name::String, default::Bool)
    val = lowercase(get(ENV, name, string(default)))
    return val in ("1", "true", "yes", "y")
end

function co2_get_env_optional_bool(name::String)
    val = strip(lowercase(get(ENV, name, "")))
    isempty(val) && return nothing
    val in ("1", "true", "yes", "y") && return true
    val in ("0", "false", "no", "n") && return false
    error("Invalid boolean value for $name=$val. Valid values: true/false, yes/no, 1/0")
end

const CO2_CPR_UPDATE_INTERVALS = (:iteration, :ministep, :step, :once)

function co2_parse_cpr_update_interval(value, name::AbstractString)
    interval = Symbol(lowercase(strip(String(value))))
    interval in CO2_CPR_UPDATE_INTERVALS || error(
        "$name=$value is invalid. Valid values: $(join(CO2_CPR_UPDATE_INTERVALS, ", "))"
    )
    return interval
end

function co2_cpr_linear_solver_arg(opts)
    arg = Dict{Symbol, Any}(
        :update_interval => opts.cpr_update_interval,
        :update_interval_partial => opts.cpr_update_interval_partial
    )
    if !isnothing(opts.cpr_partial_update)
        arg[:partial_update] = opts.cpr_partial_update
    end
    return arg
end

function co2_get_transmissibility_policy(default::Bool)
    ignore_mrst_t = co2_get_env_optional_bool("IGNORE_MRST_T")
    if !isnothing(ignore_mrst_t)
        return !ignore_mrst_t
    end
    return co2_get_env_bool("USE_MRST_TRANSMISSIBILITY", default)
end

function co2_case_defaults(case_name::AbstractString)
    case_name = uppercase(case_name)
    base = (
        report_gas_masses = true,
        report_co2_concentration = false,
        vtu_prefix = "GoM",
        vtu_vars = [:Pressure, :Saturations, :Rs],
        max_nonlinear_iterations = 10,
        max_timestep_cuts = 8,
        info_level = 1,
        report_level = 1,
        nonlinear_relaxation = false,
        target_its = 8.0,
        target_ds = Inf,
        timestep_max_increase = 10.0,
        dr_max = Inf,
        cpr_update_interval = :iteration,
        cpr_update_interval_partial = :iteration,
        cpr_partial_update = nothing,
        in_memory_reports = 10,
        well_volume_fraction = 1.0e-3,
        disable_hysteresis = false,
        hysteresis_s_min = nothing,
        use_mrst_transmissibility = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable",
        enable_diffusion = false,
        liquid_diffusion_coeff = 0.0,
        gas_diffusion_coeff = 0.0
    )

    if case_name == "GOM_SMALL"
        return merge(base, (
            matfile_path = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_3_slices.mat",
            restart_output_path = raw"G:/Shaowen/restart_gom_small",
            vtu_path = raw"G:/Shaowen/visual_gom_small"
        ))
    elseif case_name == "GOM_MEDIUM"
        return merge(base, (
            matfile_path = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_43_slices.mat",
            restart_output_path = raw"G:/Shaowen/restart_gom_medium",
            vtu_path = raw"G:/Shaowen/visual_gom_medium"
        ))
    elseif case_name == "GOM_LARGE"
        return merge(base, (
            matfile_path = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case.mat",
            restart_output_path = raw"G:/Shaowen/restart_gom_large",
            vtu_path = raw"G:/Shaowen/visual_gom_large"
        ))
    elseif case_name == "FLUIDFLOWER"
        return merge(base, (
            matfile_path = raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/fluidflower_4mm.mat",
            restart_output_path = raw"G:/Shaowen/restart_output_fluidflower_4mm_diffusion",
            vtu_path = raw"G:/Shaowen/visualization_fluidflower_4mm_diffusion",
            report_co2_concentration = true,
            max_timestep_cuts = 25,
            enable_diffusion = true,
            liquid_diffusion_coeff = 1.0e-9,
            gas_diffusion_coeff = 0.0,
            vtu_prefix = "fluidflower",
            vtu_vars = [:Pressure, :Saturations, :Rs, :Concentration]
        ))
    else
        error("Unknown CASE_NAME = $case_name. Valid options: GOM_SMALL, GOM_MEDIUM, GOM_LARGE, FLUIDFLOWER")
    end
end

function co2_case_options(;
        case_name::AbstractString,
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        common_matfile_path = nothing,
        specific_matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
        restart_step = nothing,
        stop_after_report_step = nothing,
        write_incon_vtu::Bool = false,
        write_state_vtu::Bool = false,
        vtu_prefix = nothing,
        vtu_vars = nothing,
        report_gas_masses = nothing,
        report_co2_concentration = nothing,
        max_nonlinear_iterations = nothing,
        max_timestep_cuts = nothing,
        info_level = nothing,
        report_level = nothing,
        load_all_states_after_sim::Bool = true,
        load_all_reports_after_sim::Bool = true,
        nonlinear_relaxation = nothing,
        target_its = nothing,
        target_ds = nothing,
        timestep_max_increase = nothing,
        dr_max = nothing,
        cpr_update_interval = nothing,
        cpr_update_interval_partial = nothing,
        cpr_partial_update = nothing,
        in_memory_reports = nothing,
        production_output_mode::Bool = false,
        production_summary_dir = nothing,
        production_retain_years = [50.0, 1000.0],
        production_rolling_checkpoints::Int = 2,
        production_case_key::AbstractString = "",
        production_campaign_manifest_sha256::AbstractString = "",
        production_require_hysteresis_history = nothing,
        production_qoi_mode = "off",
        well_volume_fraction = nothing,
        disable_hysteresis = nothing,
        hysteresis_s_min = nothing,
        use_mrst_transmissibility = nothing,
        fault_saturation_domain_mode = nothing,
        fault_pc_entry_treatment = nothing,
        fault_pc_entry_sg_max = nothing,
        explicit_fault_hysteresis_mode = nothing,
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    case_name = uppercase(case_name)
    defaults = co2_case_defaults(case_name)

    matfile_path = something(matfile_path, defaults.matfile_path)
    if xor(isnothing(common_matfile_path), isnothing(specific_matfile_path))
        error("COMMON_MATFILE_PATH and SPECIFIC_MATFILE_PATH must be provided together for split input.")
    end
    restart_output_path = something(restart_output_path, defaults.restart_output_path)
    vtu_path = something(vtu_path, defaults.vtu_path)
    vtu_prefix = something(vtu_prefix, defaults.vtu_prefix)
    vtu_vars = isnothing(vtu_vars) ? defaults.vtu_vars : vtu_vars
    report_gas_masses = something(report_gas_masses, defaults.report_gas_masses)
    report_co2_concentration = something(report_co2_concentration, defaults.report_co2_concentration)
    max_nonlinear_iterations = something(max_nonlinear_iterations, defaults.max_nonlinear_iterations)
    max_timestep_cuts = something(max_timestep_cuts, defaults.max_timestep_cuts)
    info_level = something(info_level, defaults.info_level)
    report_level = something(report_level, defaults.report_level)
    nonlinear_relaxation = something(nonlinear_relaxation, defaults.nonlinear_relaxation)
    target_its = something(target_its, defaults.target_its)
    target_ds = something(target_ds, defaults.target_ds)
    timestep_max_increase = something(timestep_max_increase, defaults.timestep_max_increase)
    dr_max = something(dr_max, defaults.dr_max)
    cpr_update_interval = co2_parse_cpr_update_interval(
        something(cpr_update_interval, defaults.cpr_update_interval),
        "CPR_UPDATE_INTERVAL"
    )
    cpr_update_interval_partial = co2_parse_cpr_update_interval(
        something(cpr_update_interval_partial, defaults.cpr_update_interval_partial),
        "CPR_UPDATE_INTERVAL_PARTIAL"
    )
    cpr_partial_update = isnothing(cpr_partial_update) ?
        defaults.cpr_partial_update : cpr_partial_update
    if !isnothing(cpr_partial_update) && !(cpr_partial_update isa Bool)
        error("CPR_PARTIAL_UPDATE must be true, false, or omitted for automatic selection.")
    end
    in_memory_reports = something(in_memory_reports, defaults.in_memory_reports)
    production_retain_years = Float64.(production_retain_years)
    production_campaign_manifest_sha256 =
        lowercase(String(production_campaign_manifest_sha256))
    production_qoi_mode =
        JutulDarcy.production_qoi_normalize_mode(production_qoi_mode)
    well_volume_fraction = something(well_volume_fraction, defaults.well_volume_fraction)
    disable_hysteresis = something(disable_hysteresis, defaults.disable_hysteresis)
    hysteresis_s_min = isnothing(hysteresis_s_min) ? defaults.hysteresis_s_min : hysteresis_s_min
    use_mrst_transmissibility = something(use_mrst_transmissibility, defaults.use_mrst_transmissibility)
    fault_saturation_domain_mode = something(fault_saturation_domain_mode, defaults.fault_saturation_domain_mode)
    fault_pc_entry_treatment = something(fault_pc_entry_treatment, defaults.fault_pc_entry_treatment)
    fault_pc_entry_sg_max = something(fault_pc_entry_sg_max, defaults.fault_pc_entry_sg_max)
    explicit_fault_hysteresis_mode = something(explicit_fault_hysteresis_mode, defaults.explicit_fault_hysteresis_mode)
    enable_diffusion = something(enable_diffusion, defaults.enable_diffusion)
    liquid_diffusion_coeff = something(liquid_diffusion_coeff, defaults.liquid_diffusion_coeff)
    gas_diffusion_coeff = something(gas_diffusion_coeff, defaults.gas_diffusion_coeff)
    diffusion = enable_diffusion ? (liquid_diffusion_coeff, gas_diffusion_coeff) : nothing

    if !isnothing(restart_step)
        restart_step >= 2 || error("RESTART_STEP must be at least 2 so a previous saved state exists.")
    end
    if !isnothing(stop_after_report_step)
        stop_after_report_step >= 1 || error("STOP_AFTER_REPORT_STEP must be positive.")
        if !isnothing(restart_step) && restart_step > stop_after_report_step
            error("RESTART_STEP=$restart_step is after STOP_AFTER_REPORT_STEP=$stop_after_report_step.")
        end
    end
    target_its > 0 || error("TARGET_ITS must be positive.")
    target_ds > 0 || error("TARGET_DS must be positive or Inf.")
    timestep_max_increase >= 1 || error("TIMESTEP_MAX_INCREASE must be at least 1.")
    dr_max > 0 || error("DR_MAX must be positive or Inf.")
    in_memory_reports >= 1 || error("IN_MEMORY_REPORTS must be at least 1.")
    if production_output_mode
        in_memory_reports == 1 ||
            error("PRODUCTION_OUTPUT_MODE requires IN_MEMORY_REPORTS=1.")
        load_all_states_after_sim &&
            error(
                "PRODUCTION_OUTPUT_MODE requires " *
                "LOAD_STATES_AFTER_SIM=false."
            )
        load_all_reports_after_sim &&
            error(
                "PRODUCTION_OUTPUT_MODE requires " *
                "LOAD_REPORTS_AFTER_SIM=false."
            )
        production_rolling_checkpoints >= 2 ||
            error(
                "PRODUCTION_ROLLING_CHECKPOINTS must be at least 2."
            )
        isempty(production_retain_years) &&
            error("PRODUCTION_RETAIN_YEARS may not be empty.")
        all(>=(0.0), production_retain_years) ||
            error("PRODUCTION_RETAIN_YEARS must be non-negative.")
        if !isempty(production_campaign_manifest_sha256)
            occursin(
                r"^[0-9a-f]{64}$",
                production_campaign_manifest_sha256
            ) || error(
                "PRODUCTION_CAMPAIGN_MANIFEST_SHA256 must be 64 " *
                "lowercase hexadecimal characters."
            )
        end
    elseif production_qoi_mode != "off"
        error(
            "PRODUCTION_QOI_MODE=$production_qoi_mode requires " *
            "PRODUCTION_OUTPUT_MODE=true."
        )
    end
    isfinite(well_volume_fraction) && well_volume_fraction > 0 ||
        error("WELL_VOLUME_FRACTION must be finite and positive.")

    return (
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        common_matfile_path = common_matfile_path,
        specific_matfile_path = specific_matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
        restart_step = restart_step,
        stop_after_report_step = stop_after_report_step,
        write_incon_vtu = write_incon_vtu,
        write_state_vtu = write_state_vtu,
        vtu_prefix = vtu_prefix,
        vtu_vars = vtu_vars,
        report_gas_masses = report_gas_masses,
        report_co2_concentration = report_co2_concentration,
        max_nonlinear_iterations = max_nonlinear_iterations,
        max_timestep_cuts = max_timestep_cuts,
        info_level = info_level,
        report_level = report_level,
        load_all_states_after_sim = load_all_states_after_sim,
        load_all_reports_after_sim = load_all_reports_after_sim,
        nonlinear_relaxation = nonlinear_relaxation,
        target_its = target_its,
        target_ds = target_ds,
        timestep_max_increase = timestep_max_increase,
        dr_max = dr_max,
        cpr_update_interval = cpr_update_interval,
        cpr_update_interval_partial = cpr_update_interval_partial,
        cpr_partial_update = cpr_partial_update,
        in_memory_reports = in_memory_reports,
        production_output_mode = production_output_mode,
        production_summary_dir = production_summary_dir,
        production_retain_years = production_retain_years,
        production_rolling_checkpoints = production_rolling_checkpoints,
        production_case_key = String(production_case_key),
        production_campaign_manifest_sha256 =
            production_campaign_manifest_sha256,
        production_require_hysteresis_history =
            production_require_hysteresis_history,
        production_qoi_mode = production_qoi_mode,
        well_volume_fraction = well_volume_fraction,
        disable_hysteresis = disable_hysteresis,
        hysteresis_s_min = hysteresis_s_min,
        use_mrst_transmissibility = use_mrst_transmissibility,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode,
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff,
        diffusion = diffusion
    )
end

function co2_print_case_options(opts; stage::AbstractString)
    println("Run stage = ", stage)
    println("Case name = ", opts.case_name)
    println("matfile_path = ", opts.matfile_path)
    if !isnothing(opts.common_matfile_path)
        println("split common_matfile_path = ", opts.common_matfile_path)
        println("split specific_matfile_path = ", opts.specific_matfile_path)
    end
    println("restart_output_path = ", opts.restart_output_path)
    println("vtu_path = ", opts.vtu_path)
    println("write_incon_vtu = ", opts.write_incon_vtu)
    println("write_state_vtu = ", opts.write_state_vtu)
    println("vtu_prefix = ", opts.vtu_prefix)
    println("max_nonlinear_iterations = ", opts.max_nonlinear_iterations)
    println("max_timestep_cuts = ", opts.max_timestep_cuts)
    println("info_level = ", opts.info_level)
    println("report_level = ", opts.report_level)
    println("disable_hysteresis = ", opts.disable_hysteresis)
    println("hysteresis_s_min = ", opts.hysteresis_s_min)
    println("use_mrst_transmissibility = ", opts.use_mrst_transmissibility)
    println("fault_saturation_domain_mode = ", opts.fault_saturation_domain_mode)
    println("fault_pc_entry_treatment = ", opts.fault_pc_entry_treatment)
    println("fault_pc_entry_sg_max = ", opts.fault_pc_entry_sg_max)
    println("explicit_fault_hysteresis_mode = ", opts.explicit_fault_hysteresis_mode)
    println("enable_diffusion = ", opts.enable_diffusion)
    if stage == "simulate"
        println("Julia threads available = ", Threads.nthreads())
        println("Julia threads passed to simulate_mrst_case = ", opts.julia_threads)
        println("restart = ", opts.restart)
        println("restart_step = ", opts.restart_step)
        println("stop_after_report_step = ", opts.stop_after_report_step)
        println("nonlinear_relaxation = ", opts.nonlinear_relaxation)
        println("target_its = ", opts.target_its)
        println("target_ds = ", opts.target_ds)
        println("timestep_max_increase = ", opts.timestep_max_increase)
        println("dr_max = ", opts.dr_max)
        println("cpr_update_interval = ", opts.cpr_update_interval)
        println("cpr_update_interval_partial = ", opts.cpr_update_interval_partial)
        effective_partial_update = isnothing(opts.cpr_partial_update) ?
            opts.cpr_update_interval == :once : opts.cpr_partial_update
        automatic = isnothing(opts.cpr_partial_update) ? " (automatic)" : ""
        println("cpr_partial_update = ", effective_partial_update, automatic)
        println("in_memory_reports = ", opts.in_memory_reports)
        println("production_output_mode = ", opts.production_output_mode)
        println("production_qoi_mode = ", opts.production_qoi_mode)
        if opts.production_output_mode
            println(
                "production_summary_dir = ",
                opts.production_summary_dir
            )
            println(
                "production_retain_years = ",
                join(opts.production_retain_years, ",")
            )
            println(
                "production_rolling_checkpoints = ",
                opts.production_rolling_checkpoints
            )
            println("production_case_key = ", opts.production_case_key)
            println(
                "production_campaign_manifest_sha256 = ",
                opts.production_campaign_manifest_sha256
            )
        end
        println("well_volume_fraction = ", opts.well_volume_fraction)
        println("report_gas_masses = ", opts.report_gas_masses)
        println("report_co2_concentration = ", opts.report_co2_concentration)
        println("load_all_states_after_sim = ", opts.load_all_states_after_sim)
        println("load_all_reports_after_sim = ", opts.load_all_reports_after_sim)
    end
    if opts.enable_diffusion
        println("liquid_diffusion_coeff = ", opts.liquid_diffusion_coeff)
        println("gas_diffusion_coeff = ", opts.gas_diffusion_coeff)
    end
end

function run_co2_case(;
        case_name::AbstractString,
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        common_matfile_path = nothing,
        specific_matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
        restart_step = nothing,
        stop_after_report_step = nothing,
        write_incon_vtu::Bool = false,
        write_state_vtu::Bool = false,
        vtu_prefix = nothing,
        vtu_vars = nothing,
        report_gas_masses = nothing,
        report_co2_concentration = nothing,
        max_nonlinear_iterations = nothing,
        max_timestep_cuts = nothing,
        info_level = nothing,
        report_level = nothing,
        load_all_states_after_sim::Bool = true,
        load_all_reports_after_sim::Bool = true,
        nonlinear_relaxation = nothing,
        target_its = nothing,
        target_ds = nothing,
        timestep_max_increase = nothing,
        dr_max = nothing,
        cpr_update_interval = nothing,
        cpr_update_interval_partial = nothing,
        cpr_partial_update = nothing,
        in_memory_reports = nothing,
        production_output_mode::Bool = false,
        production_summary_dir = nothing,
        production_retain_years = [50.0, 1000.0],
        production_rolling_checkpoints::Int = 2,
        production_case_key::AbstractString = "",
        production_campaign_manifest_sha256::AbstractString = "",
        production_require_hysteresis_history = nothing,
        production_qoi_mode = "off",
        well_volume_fraction = nothing,
        disable_hysteresis = nothing,
        hysteresis_s_min = nothing,
        use_mrst_transmissibility = nothing,
        fault_saturation_domain_mode = nothing,
        fault_pc_entry_treatment = nothing,
        fault_pc_entry_sg_max = nothing,
        explicit_fault_hysteresis_mode = nothing,
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    opts = co2_case_options(;
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        common_matfile_path = common_matfile_path,
        specific_matfile_path = specific_matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
        restart_step = restart_step,
        stop_after_report_step = stop_after_report_step,
        write_incon_vtu = write_incon_vtu,
        write_state_vtu = write_state_vtu,
        vtu_prefix = vtu_prefix,
        vtu_vars = vtu_vars,
        report_gas_masses = report_gas_masses,
        report_co2_concentration = report_co2_concentration,
        max_nonlinear_iterations = max_nonlinear_iterations,
        max_timestep_cuts = max_timestep_cuts,
        info_level = info_level,
        report_level = report_level,
        load_all_states_after_sim = load_all_states_after_sim,
        load_all_reports_after_sim = load_all_reports_after_sim,
        nonlinear_relaxation = nonlinear_relaxation,
        target_its = target_its,
        target_ds = target_ds,
        timestep_max_increase = timestep_max_increase,
        dr_max = dr_max,
        cpr_update_interval = cpr_update_interval,
        cpr_update_interval_partial = cpr_update_interval_partial,
        cpr_partial_update = cpr_partial_update,
        in_memory_reports = in_memory_reports,
        production_output_mode = production_output_mode,
        production_summary_dir = production_summary_dir,
        production_retain_years = production_retain_years,
        production_rolling_checkpoints = production_rolling_checkpoints,
        production_case_key = production_case_key,
        production_campaign_manifest_sha256 =
            production_campaign_manifest_sha256,
        production_require_hysteresis_history =
            production_require_hysteresis_history,
        production_qoi_mode = production_qoi_mode,
        well_volume_fraction = well_volume_fraction,
        disable_hysteresis = disable_hysteresis,
        hysteresis_s_min = hysteresis_s_min,
        use_mrst_transmissibility = use_mrst_transmissibility,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode,
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff
    )

    HYPRE.Init(nthreads = opts.hypre_threads)
    println("HYPRE threads = ", HYPRE.NumThreads())
    co2_print_case_options(opts; stage = "simulate")

    return JutulDarcy.simulate_mrst_case(
        opts.matfile_path;
        common_mrst_path = opts.common_matfile_path,
        specific_mrst_path = opts.specific_matfile_path,
        output_path = opts.restart_output_path,
        restart = isnothing(opts.restart_step) ? opts.restart : opts.restart_step,
        stop_after_report_step = opts.stop_after_report_step,
        write_vtu = opts.write_state_vtu,
        vtu_outdir = opts.vtu_path,
        vtu_prefix = opts.vtu_prefix,
        vtu_vars = opts.vtu_vars,
        report_gas_masses = opts.report_gas_masses,
        report_co2_concentration = opts.report_co2_concentration,
        write_initial_step0 = opts.write_incon_vtu,
        nthreads = opts.julia_threads,
        max_nonlinear_iterations = opts.max_nonlinear_iterations,
        max_timestep_cuts = opts.max_timestep_cuts,
        info_level = opts.info_level,
        report_level = opts.report_level,
        load_all_states_after_sim = opts.load_all_states_after_sim,
        load_all_reports_after_sim = opts.load_all_reports_after_sim,
        nonlinear_relaxation = opts.nonlinear_relaxation,
        target_its = opts.target_its,
        target_ds = opts.target_ds,
        timestep_max_increase = opts.timestep_max_increase,
        dr_max = opts.dr_max,
        linear_solver_arg = co2_cpr_linear_solver_arg(opts),
        in_memory_reports = opts.in_memory_reports,
        production_output_mode = opts.production_output_mode,
        production_summary_dir = opts.production_summary_dir,
        production_retain_years = opts.production_retain_years,
        production_rolling_checkpoints =
            opts.production_rolling_checkpoints,
        production_case_key = opts.production_case_key,
        production_campaign_manifest_sha256 =
            opts.production_campaign_manifest_sha256,
        production_require_hysteresis_history =
            opts.production_require_hysteresis_history,
        production_qoi_mode = opts.production_qoi_mode,
        well_volume_fraction = opts.well_volume_fraction,
        disable_hysteresis = opts.disable_hysteresis,
        hysteresis_s_min = opts.hysteresis_s_min,
        use_mrst_transmissibility = opts.use_mrst_transmissibility,
        fault_saturation_domain_mode = opts.fault_saturation_domain_mode,
        fault_pc_entry_treatment = opts.fault_pc_entry_treatment,
        fault_pc_entry_sg_max = opts.fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = opts.explicit_fault_hysteresis_mode,
        diffusion = opts.diffusion
    )
end

function export_co2_case_vtu(;
        case_name::AbstractString,
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        common_matfile_path = nothing,
        specific_matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
        restart_step = nothing,
        stop_after_report_step = nothing,
        write_incon_vtu::Bool = false,
        write_state_vtu::Bool = true,
        vtu_prefix = nothing,
        vtu_vars = nothing,
        report_gas_masses = nothing,
        report_co2_concentration = nothing,
        max_nonlinear_iterations = nothing,
        max_timestep_cuts = nothing,
        info_level = nothing,
        report_level = nothing,
        load_all_states_after_sim::Bool = true,
        load_all_reports_after_sim::Bool = true,
        nonlinear_relaxation = nothing,
        target_its = nothing,
        target_ds = nothing,
        timestep_max_increase = nothing,
        dr_max = nothing,
        cpr_update_interval = nothing,
        cpr_update_interval_partial = nothing,
        cpr_partial_update = nothing,
        in_memory_reports = nothing,
        well_volume_fraction = nothing,
        disable_hysteresis = nothing,
        hysteresis_s_min = nothing,
        use_mrst_transmissibility = nothing,
        fault_saturation_domain_mode = nothing,
        fault_pc_entry_treatment = nothing,
        fault_pc_entry_sg_max = nothing,
        explicit_fault_hysteresis_mode = nothing,
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    opts = co2_case_options(;
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        common_matfile_path = common_matfile_path,
        specific_matfile_path = specific_matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
        restart_step = restart_step,
        stop_after_report_step = stop_after_report_step,
        write_incon_vtu = write_incon_vtu,
        write_state_vtu = write_state_vtu,
        vtu_prefix = vtu_prefix,
        vtu_vars = vtu_vars,
        report_gas_masses = report_gas_masses,
        report_co2_concentration = report_co2_concentration,
        max_nonlinear_iterations = max_nonlinear_iterations,
        max_timestep_cuts = max_timestep_cuts,
        info_level = info_level,
        report_level = report_level,
        load_all_states_after_sim = load_all_states_after_sim,
        load_all_reports_after_sim = load_all_reports_after_sim,
        nonlinear_relaxation = nonlinear_relaxation,
        target_its = target_its,
        target_ds = target_ds,
        timestep_max_increase = timestep_max_increase,
        dr_max = dr_max,
        cpr_update_interval = cpr_update_interval,
        cpr_update_interval_partial = cpr_update_interval_partial,
        cpr_partial_update = cpr_partial_update,
        in_memory_reports = in_memory_reports,
        well_volume_fraction = well_volume_fraction,
        disable_hysteresis = disable_hysteresis,
        hysteresis_s_min = hysteresis_s_min,
        use_mrst_transmissibility = use_mrst_transmissibility,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode,
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff
    )

    co2_print_case_options(opts; stage = "vtu")

    if !(opts.write_incon_vtu || opts.write_state_vtu)
        @warn "Both write_incon_vtu and write_state_vtu are false. Nothing will be exported."
        return nothing
    end

    return JutulDarcy.export_mrst_case_vtu_from_output(
        opts.matfile_path,
        opts.restart_output_path;
        common_mrst_path = opts.common_matfile_path,
        specific_mrst_path = opts.specific_matfile_path,
        write_initial_step0 = opts.write_incon_vtu,
        write_state_vtu = opts.write_state_vtu,
        vtu_outdir = opts.vtu_path,
        vtu_prefix = opts.vtu_prefix,
        vtu_vars = opts.vtu_vars,
        report_co2_concentration = opts.report_co2_concentration,
        well_volume_fraction = opts.well_volume_fraction,
        disable_hysteresis = opts.disable_hysteresis,
        hysteresis_s_min = opts.hysteresis_s_min,
        use_mrst_transmissibility = opts.use_mrst_transmissibility,
        fault_saturation_domain_mode = opts.fault_saturation_domain_mode,
        fault_pc_entry_treatment = opts.fault_pc_entry_treatment,
        fault_pc_entry_sg_max = opts.fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = opts.explicit_fault_hysteresis_mode,
        diffusion = opts.diffusion
    )
end

function co2_case_from_env(default_case_name::AbstractString; allowed_case_names = nothing, force_case_name = nothing)
    case_name = if isnothing(force_case_name)
        uppercase(co2_get_env_str("CASE_NAME", default_case_name))
    else
        forced = uppercase(force_case_name)
        if haskey(ENV, "CASE_NAME") && uppercase(ENV["CASE_NAME"]) != forced
            @warn "Ignoring CASE_NAME=$(ENV["CASE_NAME"]) because this driver always runs $forced."
        end
        forced
    end

    if !isnothing(allowed_case_names) && !(case_name in allowed_case_names)
        error("Unknown CASE_NAME = $case_name. Valid options: $(join(allowed_case_names, ", "))")
    end
    return case_name
end

function run_co2_case_from_env(; default_case_name::AbstractString, allowed_case_names = nothing, force_case_name = nothing)
    case_name = co2_case_from_env(default_case_name;
        allowed_case_names = allowed_case_names,
        force_case_name = force_case_name
    )
    defaults = co2_case_defaults(case_name)
    run_mode = lowercase(co2_get_env_str("RUN_MODE", "simulate"))
    # Simulation-only runs default to keeping state history on disk so large
    # cases can be postprocessed later without reloading every timestep here.
    load_states_default = !(run_mode in ("simulate", "both"))

    common_kwarg = (
        case_name = case_name,
        julia_threads = co2_get_env_int("CASE_JULIA_THREADS", Threads.nthreads()),
        hypre_threads = co2_get_env_int("HYPRE_THREADS", 1),
        matfile_path = co2_get_env_str("MATFILE_PATH", defaults.matfile_path),
        common_matfile_path = co2_get_env_optional_str("COMMON_MATFILE_PATH"),
        specific_matfile_path = co2_get_env_optional_str("SPECIFIC_MATFILE_PATH"),
        restart_output_path = co2_get_env_str("RESTART_OUTPUT_PATH", defaults.restart_output_path),
        vtu_path = co2_get_env_str("VTU_PATH", defaults.vtu_path),
        restart = co2_get_env_bool("RESTART_RUN", true),
        restart_step = co2_get_env_optional_int("RESTART_STEP"),
        stop_after_report_step = co2_get_env_optional_int("STOP_AFTER_REPORT_STEP"),
        write_incon_vtu = co2_get_env_bool("WRITE_INCON_VTU", false),
        write_state_vtu = co2_get_env_bool("WRITE_STATE_VTU", false),
        vtu_prefix = co2_get_env_str("VTU_PREFIX", defaults.vtu_prefix),
        report_gas_masses = defaults.report_gas_masses,
        report_co2_concentration = defaults.report_co2_concentration,
        max_nonlinear_iterations = co2_get_env_int("MAX_NONLINEAR_ITERATIONS", defaults.max_nonlinear_iterations),
        max_timestep_cuts = co2_get_env_int("MAX_TIMESTEP_CUTS", defaults.max_timestep_cuts),
        info_level = co2_get_env_int("INFO_LEVEL", defaults.info_level),
        report_level = co2_get_env_int("REPORT_LEVEL", defaults.report_level),
        load_all_states_after_sim = co2_get_env_bool("LOAD_STATES_AFTER_SIM", load_states_default),
        load_all_reports_after_sim = co2_get_env_bool("LOAD_REPORTS_AFTER_SIM", true),
        nonlinear_relaxation = co2_get_env_bool("NONLINEAR_RELAXATION", defaults.nonlinear_relaxation),
        target_its = co2_get_env_float("TARGET_ITS", defaults.target_its),
        target_ds = co2_get_env_float("TARGET_DS", defaults.target_ds),
        timestep_max_increase = co2_get_env_float("TIMESTEP_MAX_INCREASE", defaults.timestep_max_increase),
        dr_max = co2_get_env_float("DR_MAX", defaults.dr_max),
        cpr_update_interval = co2_get_env_str("CPR_UPDATE_INTERVAL", String(defaults.cpr_update_interval)),
        cpr_update_interval_partial = co2_get_env_str(
            "CPR_UPDATE_INTERVAL_PARTIAL",
            String(defaults.cpr_update_interval_partial)
        ),
        cpr_partial_update = co2_get_env_optional_bool("CPR_PARTIAL_UPDATE"),
        in_memory_reports = co2_get_env_int("IN_MEMORY_REPORTS", defaults.in_memory_reports),
        well_volume_fraction = co2_get_env_float(
            "WELL_VOLUME_FRACTION",
            defaults.well_volume_fraction
        ),
        disable_hysteresis = co2_get_env_bool("DISABLE_HYSTERESIS", defaults.disable_hysteresis),
        hysteresis_s_min = co2_get_env_optional_float("HYSTERESIS_S_MIN"),
        use_mrst_transmissibility = co2_get_transmissibility_policy(defaults.use_mrst_transmissibility),
        fault_saturation_domain_mode = co2_get_env_str("FAULT_SATURATION_DOMAIN_MODE", defaults.fault_saturation_domain_mode),
        fault_pc_entry_treatment = co2_get_env_str("FAULT_PC_ENTRY_TREATMENT", defaults.fault_pc_entry_treatment),
        fault_pc_entry_sg_max = co2_get_env_float("FAULT_PC_ENTRY_SG_MAX", defaults.fault_pc_entry_sg_max),
        explicit_fault_hysteresis_mode = co2_get_env_str("EXPLICIT_FAULT_HYSTERESIS_MODE", defaults.explicit_fault_hysteresis_mode),
        enable_diffusion = co2_get_env_bool("ENABLE_DIFFUSION", defaults.enable_diffusion),
        liquid_diffusion_coeff = co2_get_env_float("LIQUID_DIFFUSION_COEFF", defaults.liquid_diffusion_coeff),
        gas_diffusion_coeff = co2_get_env_float("GAS_DIFFUSION_COEFF", defaults.gas_diffusion_coeff)
    )

    production_kwarg = (
        production_output_mode =
            co2_get_env_bool("PRODUCTION_OUTPUT_MODE", false),
        production_summary_dir =
            co2_get_env_optional_str("PRODUCTION_SUMMARY_DIR"),
        production_retain_years =
            co2_get_env_float_list("PRODUCTION_RETAIN_YEARS", [50.0, 1000.0]),
        production_rolling_checkpoints =
            co2_get_env_int("PRODUCTION_ROLLING_CHECKPOINTS", 2),
        production_case_key = co2_get_env_str(
            "PRODUCTION_CASE_KEY",
            co2_get_env_str("CASE_TAG", "")
        ),
        production_campaign_manifest_sha256 = co2_get_env_str(
            "PRODUCTION_CAMPAIGN_MANIFEST_SHA256",
            ""
        ),
        production_require_hysteresis_history =
            co2_get_env_optional_bool(
                "PRODUCTION_REQUIRE_HYSTERESIS_HISTORY"
            ),
        production_qoi_mode =
            co2_get_env_str("PRODUCTION_QOI_MODE", "off")
    )
    simulate_kwarg = merge(common_kwarg, production_kwarg)

    if run_mode in ("simulate", "sim")
        return run_co2_case(; simulate_kwarg...)
    elseif run_mode in ("vtu", "postprocess", "export")
        return export_co2_case_vtu(; common_kwarg...)
    elseif run_mode == "both"
        simulate_only_kwarg = merge(simulate_kwarg, (
            write_incon_vtu = false,
            write_state_vtu = false
        ))
        run_co2_case(; simulate_only_kwarg...)
        return export_co2_case_vtu(; common_kwarg...)
    else
        error("Unknown RUN_MODE = $run_mode. Valid options: simulate, vtu, both")
    end
end
