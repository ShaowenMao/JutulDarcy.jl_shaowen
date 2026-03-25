function env_enabled(name::String, default::Bool)
    val = lowercase(get(ENV, name, string(default)))
    return val in ("1", "true", "yes", "y")
end

function maybe_load_revise()
    # Default to Revise for interactive desktop use, but keep it off for batch/HPC runs.
    enable_revise = env_enabled("ENABLE_REVISE", Sys.iswindows() && isinteractive())
    if enable_revise
        try
            @eval using Revise
        catch err
            @warn "Revise could not be loaded. Continuing without it." exception = (err, catch_backtrace())
        end
    end
    return nothing
end

maybe_load_revise()
using JutulDarcy
using MAT
using HYPRE

# =========================================================
# Helper functions for environment-variable-driven settings
# =========================================================
get_env_str(name::String, default::String) = get(ENV, name, default)

function get_env_int(name::String, default::Int)
    return parse(Int, get(ENV, name, string(default)))
end

function get_env_float(name::String, default::Real)
    return parse(Float64, get(ENV, name, string(default)))
end

function get_env_bool(name::String, default::Bool)
    val = lowercase(get(ENV, name, string(default)))
    return val in ("1", "true", "yes", "y")
end

function co2_blackoil_case_defaults(case_name::AbstractString)
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

function co2_blackoil_options(;
        case_name::AbstractString = "GOM_SMALL",
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
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
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    case_name = uppercase(case_name)
    defaults = co2_blackoil_case_defaults(case_name)

    matfile_path = something(matfile_path, defaults.matfile_path)
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
    enable_diffusion = something(enable_diffusion, defaults.enable_diffusion)
    liquid_diffusion_coeff = something(liquid_diffusion_coeff, defaults.liquid_diffusion_coeff)
    gas_diffusion_coeff = something(gas_diffusion_coeff, defaults.gas_diffusion_coeff)
    diffusion = enable_diffusion ? (liquid_diffusion_coeff, gas_diffusion_coeff) : nothing

    return (
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
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
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff,
        diffusion = diffusion
    )
end

function print_co2_blackoil_options(opts; stage::AbstractString)
    println("Run stage = ", stage)
    println("Case name = ", opts.case_name)
    println("matfile_path = ", opts.matfile_path)
    println("restart_output_path = ", opts.restart_output_path)
    println("vtu_path = ", opts.vtu_path)
    println("write_incon_vtu = ", opts.write_incon_vtu)
    println("write_state_vtu = ", opts.write_state_vtu)
    println("vtu_prefix = ", opts.vtu_prefix)
    println("max_nonlinear_iterations = ", opts.max_nonlinear_iterations)
    println("max_timestep_cuts = ", opts.max_timestep_cuts)
    println("info_level = ", opts.info_level)
    println("report_level = ", opts.report_level)
    println("enable_diffusion = ", opts.enable_diffusion)
    if stage == "simulate"
        println("Julia threads available = ", Threads.nthreads())
        println("Julia threads passed to simulate_mrst_case = ", opts.julia_threads)
        println("restart = ", opts.restart)
        println("report_gas_masses = ", opts.report_gas_masses)
        println("report_co2_concentration = ", opts.report_co2_concentration)
        println("load_all_states_after_sim = ", opts.load_all_states_after_sim)
    end
    if opts.enable_diffusion
        println("liquid_diffusion_coeff = ", opts.liquid_diffusion_coeff)
        println("gas_diffusion_coeff = ", opts.gas_diffusion_coeff)
    end
end

function run_co2_blackoil(;
        case_name::AbstractString = "GOM_SMALL",
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
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
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    opts = co2_blackoil_options(;
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
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
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff
    )

    HYPRE.Init(nthreads = opts.hypre_threads)
    println("HYPRE threads = ", HYPRE.NumThreads())
    print_co2_blackoil_options(opts; stage = "simulate")

    return JutulDarcy.simulate_mrst_case(
        opts.matfile_path;
        output_path = opts.restart_output_path,
        restart = opts.restart,
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
        diffusion = opts.diffusion
    )
end

function export_co2_blackoil_vtu(;
        case_name::AbstractString = "GOM_SMALL",
        julia_threads::Int = Threads.nthreads(),
        hypre_threads::Int = 1,
        matfile_path = nothing,
        restart_output_path = nothing,
        vtu_path = nothing,
        restart::Bool = true,
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
        enable_diffusion = nothing,
        liquid_diffusion_coeff = nothing,
        gas_diffusion_coeff = nothing
    )
    opts = co2_blackoil_options(;
        case_name = case_name,
        julia_threads = julia_threads,
        hypre_threads = hypre_threads,
        matfile_path = matfile_path,
        restart_output_path = restart_output_path,
        vtu_path = vtu_path,
        restart = restart,
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
        enable_diffusion = enable_diffusion,
        liquid_diffusion_coeff = liquid_diffusion_coeff,
        gas_diffusion_coeff = gas_diffusion_coeff
    )

    print_co2_blackoil_options(opts; stage = "vtu")

    if !(opts.write_incon_vtu || opts.write_state_vtu)
        @warn "Both write_incon_vtu and write_state_vtu are false. Nothing will be exported."
        return nothing
    end

    return JutulDarcy.export_mrst_case_vtu_from_output(
        opts.matfile_path,
        opts.restart_output_path;
        write_initial_step0 = opts.write_incon_vtu,
        write_state_vtu = opts.write_state_vtu,
        vtu_outdir = opts.vtu_path,
        vtu_prefix = opts.vtu_prefix,
        vtu_vars = opts.vtu_vars,
        report_co2_concentration = opts.report_co2_concentration,
        diffusion = opts.diffusion
    )
end

function run_co2_blackoil_from_env()
    case_name = uppercase(get_env_str("CASE_NAME", "GOM_SMALL"))
    defaults = co2_blackoil_case_defaults(case_name)
    run_mode = lowercase(get_env_str("RUN_MODE", "simulate"))
    # Simulation-only runs default to keeping state history on disk so large
    # cases can be postprocessed later without reloading every timestep here.
    load_states_default = !(run_mode in ("simulate", "both"))

    common_kwarg = (
        case_name = case_name,
        julia_threads = get_env_int("CASE_JULIA_THREADS", Threads.nthreads()),
        hypre_threads = get_env_int("HYPRE_THREADS", 1),
        matfile_path = get_env_str("MATFILE_PATH", defaults.matfile_path),
        restart_output_path = get_env_str("RESTART_OUTPUT_PATH", defaults.restart_output_path),
        vtu_path = get_env_str("VTU_PATH", defaults.vtu_path),
        restart = get_env_bool("RESTART_RUN", true),
        write_incon_vtu = get_env_bool("WRITE_INCON_VTU", false),
        write_state_vtu = get_env_bool("WRITE_STATE_VTU", false),
        vtu_prefix = get_env_str("VTU_PREFIX", defaults.vtu_prefix),
        report_gas_masses = defaults.report_gas_masses,
        report_co2_concentration = defaults.report_co2_concentration,
        max_nonlinear_iterations = get_env_int("MAX_NONLINEAR_ITERATIONS", defaults.max_nonlinear_iterations),
        max_timestep_cuts = get_env_int("MAX_TIMESTEP_CUTS", defaults.max_timestep_cuts),
        info_level = get_env_int("INFO_LEVEL", defaults.info_level),
        report_level = get_env_int("REPORT_LEVEL", defaults.report_level),
        load_all_states_after_sim = get_env_bool("LOAD_STATES_AFTER_SIM", load_states_default),
        enable_diffusion = get_env_bool("ENABLE_DIFFUSION", defaults.enable_diffusion),
        liquid_diffusion_coeff = get_env_float("LIQUID_DIFFUSION_COEFF", defaults.liquid_diffusion_coeff),
        gas_diffusion_coeff = get_env_float("GAS_DIFFUSION_COEFF", defaults.gas_diffusion_coeff)
    )

    if run_mode in ("simulate", "sim")
        return run_co2_blackoil(; common_kwarg...)
    elseif run_mode in ("vtu", "postprocess", "export")
        return export_co2_blackoil_vtu(; common_kwarg...)
    elseif run_mode == "both"
        simulate_kwarg = merge(common_kwarg, (
            write_incon_vtu = false,
            write_state_vtu = false
        ))
        run_co2_blackoil(; simulate_kwarg...)
        return export_co2_blackoil_vtu(; common_kwarg...)
    else
        error("Unknown RUN_MODE = $run_mode. Valid options: simulate, vtu, both")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_co2_blackoil_from_env()
end
