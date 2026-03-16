using Revise  # Good to keep this at the very top
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

# =========================================================
# Thread settings
# =========================================================
# Julia runtime threads are determined when Julia starts,
# e.g. by JULIA_NUM_THREADS. Threads.nthreads() reports how
# many Julia threads are actually available in this process.
#
# CASE_JULIA_THREADS is the number passed into simulate_mrst_case.
# Usually it should be <= Threads.nthreads().
#
# HYPRE_THREADS controls the HYPRE internal thread count.
julia_threads = get_env_int("CASE_JULIA_THREADS", Threads.nthreads())
hypre_threads = get_env_int("HYPRE_THREADS", 1)

HYPRE.Init(nthreads = hypre_threads)

println("Julia threads available = ", Threads.nthreads())
println("Julia threads passed to simulate_mrst_case = ", julia_threads)
println("HYPRE threads = ", HYPRE.NumThreads())

# =========================================================
# Case selection
# =========================================================
# Options:
#   GOM_SMALL
#   GOM_MEDIUM
#   GOM_LARGE
#   FLUIDFLOWER
#
# Default is GOM_MEDIUM for convenience.
case_name = uppercase(get_env_str("CASE_NAME", "GOM_SMALL"))

# =========================================================
# Default paths and settings for each case
# These defaults are convenient for your local Windows machine.
# On HPC, override them using environment variables.
# =========================================================
matfile_default = ""
restart_default = ""
vtu_default = ""
max_nonlinear_iterations_default = 10
max_timestep_cuts_default = 8
info_level_default = 1
report_level_default = 1
enable_diffusion_default = false
liquid_diffusion_default = 0.0
gas_diffusion_default = 0.0

# Control flags
restart = get_env_bool("RESTART_RUN", true)

# VTU control
write_incon_vtu = get_env_bool("WRITE_INCON_VTU", false)
write_state_vtu = get_env_bool("WRITE_STATE_VTU", false)
vtu_prefix = get_env_str("VTU_PREFIX", "test")
vtu_vars = [:Pressure, :Saturations, :Rs]

if case_name == "GOM_SMALL"
    matfile_default = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_3_slices.mat"
    restart_default = raw"G:/Shaowen/restart_gom_small"
    vtu_default = raw"G:/Shaowen/visual_gom_small"

    report_gas_masses = true
    report_co2_concentration = false
    vtu_prefix = "GoM"
    vtu_vars = [:Pressure, :Saturations, :Rs]

elseif case_name == "GOM_MEDIUM"
    matfile_default = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_43_slices.mat"
    restart_default = raw"G:/Shaowen/restart_gom_medium"
    vtu_default = raw"G:/Shaowen/visual_gom_medium"

    report_gas_masses = true
    report_co2_concentration = false
    vtu_prefix = "GoM"
    vtu_vars = [:Pressure, :Saturations, :Rs]

elseif case_name == "GOM_LARGE"
    matfile_default = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case.mat"
    restart_default = raw"G:/Shaowen/restart_gom_large"
    vtu_default = raw"G:/Shaowen/visual_gom_large"

    report_gas_masses = true
    report_co2_concentration = false
    vtu_prefix = "GoM"
    vtu_vars = [:Pressure, :Saturations, :Rs]

elseif case_name == "FLUIDFLOWER"
    matfile_default = raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/fluidflower_4mm.mat"
    restart_default = raw"G:/Shaowen/restart_output_fluidflower_4mm_diffusion"
    vtu_default = raw"G:/Shaowen/visualization_fluidflower_4mm_diffusion"

    report_gas_masses = true
    report_co2_concentration = true
    max_timestep_cuts_default = 25
    enable_diffusion_default = true
    liquid_diffusion_default = 1.0e-9
    gas_diffusion_default = 0.0
    vtu_prefix = "fluidflower"
    vtu_vars = [:Pressure, :Saturations, :Rs, :Concentration]

else
    error("Unknown CASE_NAME = $case_name. Valid options: GOM_SMALL, GOM_MEDIUM, GOM_LARGE, FLUIDFLOWER")
end

# =========================================================
# Final paths
# These can be overridden from the shell on HPC or desktop
# =========================================================
matfile_path = get_env_str("MATFILE_PATH", matfile_default)
restart_output_path = get_env_str("RESTART_OUTPUT_PATH", restart_default)
vtu_path = get_env_str("VTU_PATH", vtu_default)
max_nonlinear_iterations = get_env_int("MAX_NONLINEAR_ITERATIONS", max_nonlinear_iterations_default)
max_timestep_cuts = get_env_int("MAX_TIMESTEP_CUTS", max_timestep_cuts_default)
info_level = get_env_int("INFO_LEVEL", info_level_default)
report_level = get_env_int("REPORT_LEVEL", report_level_default)
enable_diffusion = get_env_bool("ENABLE_DIFFUSION", enable_diffusion_default)
liquid_diffusion_coeff = get_env_float("LIQUID_DIFFUSION_COEFF", liquid_diffusion_default)
gas_diffusion_coeff = get_env_float("GAS_DIFFUSION_COEFF", gas_diffusion_default)
diffusion = enable_diffusion ? (liquid_diffusion_coeff, gas_diffusion_coeff) : nothing

println("Case name = ", case_name)
println("matfile_path = ", matfile_path)
println("restart_output_path = ", restart_output_path)
println("vtu_path = ", vtu_path)
println("restart = ", restart)
println("write_incon_vtu = ", write_incon_vtu)
println("write_state_vtu = ", write_state_vtu)
println("max_nonlinear_iterations = ", max_nonlinear_iterations)
println("max_timestep_cuts = ", max_timestep_cuts)
println("info_level = ", info_level)
println("report_level = ", report_level)
println("enable_diffusion = ", enable_diffusion)
if enable_diffusion
    println("liquid_diffusion_coeff = ", liquid_diffusion_coeff)
    println("gas_diffusion_coeff = ", gas_diffusion_coeff)
end

# =========================================================
# Run simulation
# =========================================================
simulate_mrst_case(
    matfile_path;
    output_path = restart_output_path,
    restart = restart,
    write_vtu = write_state_vtu,
    vtu_outdir = vtu_path,
    vtu_prefix = vtu_prefix,
    vtu_vars = vtu_vars,  # Only write these reservoir state variables.
    report_gas_masses = report_gas_masses,
    report_co2_concentration = report_co2_concentration,
    write_initial_step0 = write_incon_vtu,
    nthreads = julia_threads,
    max_nonlinear_iterations = max_nonlinear_iterations,
    max_timestep_cuts = max_timestep_cuts,
    info_level = info_level,
    report_level = report_level,
    diffusion = diffusion
)
