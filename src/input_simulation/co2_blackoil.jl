using Revise  # Good to keep this at the very top
using JutulDarcy
using MAT
using HYPRE

HYPRE.Init(nthreads = 4)  

println("Julia threads = ", Threads.nthreads())
println("HYPRE threads = ", HYPRE.NumThreads())

# local laptop path and GRS3 server path are different. Make sure to change it. 

# --------------------------------
# GoM case -- GRS3 server
# --------------------------------
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_45_slices_new.mat" #raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "C:/Users/shaowen/restart_output_45slices_new"
# vtu_path            = "G:/Shaowen/visualization_45slices_new" 

# matfile_path        = raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_87_slices_laptop.mat" #raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "C:/Users/shaowen/restart_output_87_newcode_oldmatfile_laptop"
# vtu_path            = "G:/Shaowen/restart_output_87_newcode_oldmatfile_laptop" 

# large case -- still need to run one without hysteresis
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_87_slices_modifycentroids.mat" #raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "C:/Users/shaowen/restart_output_87_modifycentroids"
# vtu_path            = "G:/Shaowen/restart_output_87_modifycentroids" 

# large case -- still need to run one without hysteresis
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case.mat" #raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "G:/Shaowen/restart_lluis_field_case_nohys"
# vtu_path            = "G:/Shaowen/visual_lluis_field_case_nohys"

# large case -- no hysteresis -- HYPRE
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case.mat" #raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "G:/Shaowen/restart_lluis_field_case_nohys_HYPRE_8julia_1hypre"
# vtu_path            = "G:/Shaowen/visual_lluis_field_case_nohys_HYPRE_8julia_1hypre"

# medium case -- no hysteresis
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_43_slices.mat"#raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "C:/Users/shaowen/restart_output_43_nohys"
# vtu_path            = "G:/Shaowen/restart_output_43_nohys" 

# medium case -- no hysteresis -- HYPRE
matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_43_slices.mat"#raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
restart_output_path = "G:/Shaowen/restart_output_43_nohys_HYPRE_8julia_4hypre"
vtu_path            = "G:/Shaowen/visual_output_43_nohys_HYPRE_8julia_4hypre" 

# small case -- no hysteresis
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_3_slices.mat"#raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "G:/Shaowen/restart_gom_3_nohys_smoothed_aggregation_tighttol_agg" #"C:/Users/shaowen/restart_output_3_nohys"
# vtu_path            = "G:/Shaowen/visual_gom_3_nohys_smoothed_aggregation_tighttol_agg"  #"G:/Shaowen/restart_output_3_nohys" 

# small case -- no hysteresis -- HYPRE
# matfile_path        = raw"C:/Users/shaowen/mrst_jutul/lluis_field_case_3_slices.mat"#raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case_45_slices.mat"
# restart_output_path = "G:/Shaowen/restart_gom_3_nohys_HYPRE_8julia_8hypre" #"C:/Users/shaowen/restart_output_3_nohys"
# vtu_path            = "G:/Shaowen/visual_gom_3_nohys_HYPRE_8julia_8hypre"  #"G:/Shaowen/restart_output_3_nohys" 


# Control flag
restart = true                    # Look in restart_output_path for already-saved results and continue from the last successfully saved step, instead of starting from step 1 again

# Post-analysis flag
report_gas_masses        = true   # Compute the percentage of dissolved gas and free gas
report_co2_concentration = false  # For FluidFlower case validation (dissolved co2 mass / brine volume)

# vtu control 
write_incon_vtu = false 
write_state_vtu = false 
vtu_prefix = "GoM"
vtu_vars   = [:Pressure, :Saturations, :Rs]

# --------------------------------
# FluidFlower case -- GRS3 server
# --------------------------------
# matfile_path        = raw"C:/Users/shaowen/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/fluidflower_4mm.mat"
# restart_output_path = "G:/Shaowen/restart_output_fluidflower_4mm_diffusion"
# vtu_path            = "G:/Shaowen/visualization_fluidflower_4mm_diffusion" 

# # Control flag
# restart = true                    # Look in restart_output_path for already-saved results and continue from the last successfully saved step, instead of starting from step 1 again

# # Post-analysis flag
# report_gas_masses        = true   # Compute the percentage of dissolved gas and free gas
# report_co2_concentration = true   # For FluidFlower case validation (dissolved co2 mass / brine volume)
        
# # vtu control 
# write_incon_vtu = true 
# write_state_vtu = true 
# vtu_prefix = "fluidflower"
# vtu_vars   = [:Pressure, :Saturations, :Rs, :Concentration]

# ---------------------------------------------------------
# Run simulation 
# ---------------------------------------------------------
simulate_mrst_case(matfile_path;
                   output_path = restart_output_path,
                   restart    = restart,
                   write_vtu  = write_state_vtu,
                   vtu_outdir = vtu_path,
                   vtu_prefix = vtu_prefix,
                   vtu_vars   = vtu_vars,  # Only write these reservoir state varialbes. This does not affect optional extras for regions and dp.
                   report_gas_masses        = report_gas_masses,
                   report_co2_concentration = report_co2_concentration,
                   write_initial_step0      = write_incon_vtu,
                   nthreads = 8
) 

