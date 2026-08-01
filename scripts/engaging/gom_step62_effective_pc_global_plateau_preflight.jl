using JutulDarcy
import MAT

include(joinpath(@__DIR__, "gom_step62_effective_pc_global_plateau_contract.jl"))
using .GoMStep62EffectivePcGlobalPlateauContract

length(ARGS) == 9 || error(
    "Usage: gom_step62_effective_pc_global_plateau_preflight.jl COMMON_MAT SPECIFIC_MAT " *
    "RESULT_DIR CASE_KEY GEOLOGY_ID REALIZATION_ID GEOLOGY_HASH " *
    "LEVEL3_CASE_NAME MANIFEST_SHA256"
)
common_path, specific_path, result_dir, expected_case_key,
    expected_geology_id, expected_realization_text, expected_geology_hash,
    expected_level3_case_name, expected_manifest_sha256 = ARGS
expected_realization_id = parse(Int, expected_realization_text)
mkpath(result_dir)

scalar_value(x) = x isa AbstractArray ? only(vec(x)) : x

isfile(common_path) || error("Common MAT does not exist: $common_path")
isfile(specific_path) || error("Specific MAT does not exist: $specific_path")
occursin(r"^[0-9a-f]{64}$", lowercase(expected_manifest_sha256)) ||
    error("Expected campaign manifest SHA-256 is invalid.")
expected_case_key ==
    "$(expected_geology_id)_case$(lpad(expected_realization_id, 2, '0'))" ||
    error("Case key does not match geology and realization identity.")

specific = MAT.matread(specific_path)
get(specific, "schema", "") == "gom_jutul_split_specific_v3" ||
    error("Expected combined geology-specific schema v3.")
common_metadata = MAT.matopen(common_path) do file
    read(file, "metadata")
end
get(common_metadata, "physics_profile", "") ==
    GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE ||
    error("Common input has the wrong physics profile.")
get(specific, "metadata", Dict{String, Any}())["physics_profile"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE ||
    error("Specific input has the wrong physics profile.")
get(common_metadata, "fixed_sgr_file", "") ==
    "faultPermSGR_Gupper87lyr_predictMesh_youngerkxx50_effective_globalplateau_v1.mat" ||
    error("Common input does not name the versioned Younger-cap50 asset.")
occursin(
    r"^[0-9a-f]{64}$",
    lowercase(get(common_metadata, "fixed_sgr_file_sha256", ""))
) || error("Common input has an invalid fixed-SGR asset digest.")
modification = get(
    common_metadata,
    "fixed_sgr_modification",
    Dict{String, Any}()
)
get(modification, "schema", "") == "gom_fixed_sgr_modification_v2" ||
    error("Common input lacks versioned fixed-SGR provenance.")
get(modification, "physicsProfile", "") ==
    GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE ||
    error("Fixed-SGR provenance has the wrong physics profile.")
get(modification, "assetContract", "") == "youngerkxx50_v1" ||
    error("Fixed-SGR provenance has the wrong independent asset contract.")
string(scalar_value(get(modification, "assetVersion", ""))) == "1" ||
    error("Fixed-SGR provenance has the wrong asset version.")
Int(round(scalar_value(modification["changedRowCount"]))) == 10_701 ||
    error("Fixed-SGR provenance has the wrong changed-row count.")
Bool(scalar_value(modification["porosityChanged"])) == false ||
    error("Fixed-SGR provenance says porosity changed.")
Int(round(scalar_value(
    common_metadata["shared_drainage_saturation_region_count"]
))) == GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_BASE_REGIONS ||
    error("Common metadata has the wrong shared-region count.")
Int(round(scalar_value(
    common_metadata["mrst_drainage_saturation_region_count"]
))) == 14 ||
    error("Common metadata has the wrong six-window drainage count.")
expected_common_name = first(splitext(basename(common_path)))
get(specific, "common_name", "") == expected_common_name ||
    error(
        "Specific input names common input " *
        "$(get(specific, "common_name", "<missing>")); expected " *
        "$expected_common_name."
    )
get(specific, "geology_id", "") == expected_geology_id ||
    error("Specific input geology ID does not match the immutable manifest.")
lowercase(get(specific, "geology_hash", "")) ==
    lowercase(expected_geology_hash) ||
    error("Specific input geology hash does not match the immutable manifest.")
get(specific, "level3_case_name", "") == expected_level3_case_name ||
    error("Specific input Level-3 case name does not match the manifest.")
Int(round(scalar_value(specific["realization_id"]))) ==
    expected_realization_id ||
    error("Specific input realization ID does not match the manifest.")

setup = simulate_mrst_case(
    specific_path;
    common_mrst_path = common_path,
    specific_mrst_path = specific_path,
    do_sim = false,
    write_output = false,
    verbose = true,
    disable_hysteresis = false,
    hysteresis_s_min =
        GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_HYSTERESIS_S_MIN,
    use_mrst_transmissibility = false,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau_all_active",
    explicit_fault_hysteresis_mode = "reservoir",
    ds_max = 0.05,
    max_nonlinear_iterations = 10,
    max_timestep_cuts = 25,
    well_volume_fraction = 1.0e-3,
    nthreads = Threads.nthreads()
)
diagnostics =
    GoMStep62EffectivePcGlobalPlateauContract.validate_assembled_case(setup)

# Validate every symmetric permeability tensor, not only the modified
# non-PREDICT Younger band.
perm = diagnostics.perm
kxx = @view perm[:, 1]
kxy = @view perm[:, 2]
kxz = @view perm[:, 3]
kyy = @view perm[:, 4]
kyz = @view perm[:, 5]
kzz = @view perm[:, 6]
second_principal_minor = kxx.*kyy .- kxy.^2
tensor_determinant = (
    kxx.*kyy.*kzz .+
    2.0.*kxy.*kxz.*kyz .-
    kxx.*kyz.^2 .-
    kyy.*kxz.^2 .-
    kzz.*kxy.^2
)
all(>(0.0), kxx) || error("Kxx is not strictly positive.")
all(>(0.0), kyy) || error("Kyy is not strictly positive.")
all(>(0.0), kzz) || error("Kzz is not strictly positive.")
all(>(0.0), second_principal_minor) ||
    error("Permeability second principal minor is not strictly positive.")
all(>(0.0), tensor_determinant) ||
    error("Permeability tensor is not positive definite.")

mrst = diagnostics.mrst
mrst["stratigraphy_specific_summary"]["cell_count"] ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected geology-specific stratigraphy cell count.")
length(vec(specific["fault"]["cells"])) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_FAULT_CELLS ||
    error("Unexpected geology-specific fault cell count.")
length(vec(specific["stratigraphy"]["cells"])) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected geology-specific stratigraphy cell count.")

base_counts = [
    count(==(region), diagnostics.satnum)
    for region in 1:GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_BASE_REGIONS
]
all(>(0), base_counts) || error("One or more shared/base regions is empty.")

dt = Float64.(vec(setup.case.dt))
length(dt) == 210 || error("Expected 210 schedule steps.")
all(>(0.0), dt) || error("Schedule contains a non-positive step.")
mrst_year_seconds = 365.2425*24*60*60
isapprox(
    sum(dt),
    1000*mrst_year_seconds;
    rtol = 0,
    atol = 1.0
) || error("Schedule does not end at 1000 years.")

summary_path = joinpath(result_dir, "preflight_summary.txt")
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "physics_profile=$(GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE)")
    println(io, "case_key=$expected_case_key")
    println(io, "campaign_manifest_sha256=$(lowercase(expected_manifest_sha256))")
    println(io, "schema=$(specific["schema"])")
    println(io, "common_name=$expected_common_name")
    println(io, "geology_id=$expected_geology_id")
    println(io, "geology_hash=$(specific["geology_hash"])")
    println(io, "realization_id=$expected_realization_id")
    println(io, "level3_case_name=$(specific["level3_case_name"])")
    println(
        io,
        "resolution_slices=$(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_SLICES)"
    )
    println(io, "cells=$(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_CELLS)")
    println(
        io,
        "fault_cells=$(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_FAULT_CELLS)"
    )
    println(
        io,
        "stratigraphy_cells=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_STRATIGRAPHY_CELLS)
    )
    println(
        io,
        "base_saturation_regions=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_BASE_REGIONS)
    )
    println(io, "base_region_cell_counts=$(join(base_counts, ','))")
    println(
        io,
        "explicit_predict_regions=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_FAULT_REGIONS)
    )
    println(
        io,
        "drainage_saturation_regions=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_DRAINAGE_REGIONS)
    )
    println(
        io,
        "total_sgof_tables=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_TOTAL_SGOF_TABLES)
    )
    println(io, "hysteresis_active=true")
    println(
        io,
        "hysteresis_s_min=" *
        string(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_HYSTERESIS_S_MIN)
    )
    println(io, "fault_hysteresis=drainage_equivalent")
    println(
        io,
        "pc_mapping_schema=" *
        GoMStep62EffectivePcGlobalPlateauContract.PC_MAPPING_SCHEMA
    )
    println(
        io,
        "pc_mapping_method=" *
        GoMStep62EffectivePcGlobalPlateauContract.PC_MAPPING_METHOD
    )
    println(
        io,
        "pc_mapping_digest_count=$(diagnostics.pc_mapping.digest_count)"
    )
    println(
        io,
        "pc_mapping_point_count_min=$(minimum(diagnostics.pc_mapping.point_counts))"
    )
    println(
        io,
        "pc_mapping_point_count_max=$(maximum(diagnostics.pc_mapping.point_counts))"
    )
    println(
        io,
        "pc_mapping_max_dense_kr_absolute_error=" *
        string(diagnostics.pc_mapping.max_dense_kr_absolute_error)
    )
    println(
        io,
        "pc_mapping_max_analytic_pc_relative_error=" *
        string(diagnostics.pc_mapping.max_analytic_pc_relative_error)
    )
    println(
        io,
        "pc_mapping_max_adjacent_positive_pc_ratio=" *
        string(diagnostics.pc_mapping.max_adjacent_positive_pc_ratio)
    )
    println(
        io,
        "pc_entry_treatment=$(diagnostics.pc_summary["treatment"])"
    )
    println(io, "pc_entry_scope=$(diagnostics.pc_summary["scope"])")
    println(io, "pc_entry_rule=$(diagnostics.pc_summary["entry_rule"])")
    println(
        io,
        "pc_plateau_active_tables=$(diagnostics.pc_summary["active_tables"])"
    )
    println(
        io,
        "pc_plateau_nonzero_entry_tables=" *
        string(diagnostics.pc_summary["nonzero_entry_tables"])
    )
    println(
        io,
        "pc_plateau_adjusted_tables=$(diagnostics.pc_summary["adjusted_tables"])"
    )
    println(
        io,
        "pc_plateau_already_plateaued_tables=" *
        string(diagnostics.pc_summary["already_plateaued_tables"])
    )
    println(
        io,
        "pc_plateau_true_zero_tables=" *
        string(diagnostics.pc_summary["true_zero_pc_tables"])
    )
    println(
        io,
        "pc_plateau_skipped_tables=$(diagnostics.pc_summary["skipped_tables"])"
    )
    println(
        io,
        "pc_plateau_mirrored_explicit_tables=" *
        string(diagnostics.pc_summary[
            "mirrored_explicit_hysteresis_tables"
        ])
    )
    println(
        io,
        "pc_input_drainage_sha256=" *
        diagnostics.pc_summary["input_drainage_sha256"]
    )
    println(
        io,
        "pc_output_drainage_sha256=" *
        diagnostics.pc_summary["output_drainage_sha256"]
    )
    println(
        io,
        "pc_kr_sha256=" * diagnostics.pc_summary["kr_sha256_after"]
    )
    println(
        io,
        "pc_tail_sha256=" * diagnostics.pc_summary["pc_tail_sha256_after"]
    )
    println(
        io,
        "base_imbibition_sha256=" *
        diagnostics.pc_summary["base_imbibition_sha256_after"]
    )
    println(io, "pc_kr_unchanged=true")
    println(io, "pc_at_and_above_entry_unchanged=true")
    println(io, "base_imbibition_unchanged=true")
    println(
        io,
        "pc_max_piecewise_slope_pa_per_sg=" *
        string(diagnostics.pc_tables.maximum_piecewise_pc_slope_pa_per_sg)
    )
    println(
        io,
        "pc_cap_onset_interval_cell_counts=" *
        "unavailable_setup_only_no_dynamic_saturation"
    )
    println(io, "total_ministeps=not_applicable_setup_only")
    println(io, "newton_iterations=not_applicable_setup_only")
    println(io, "linear_iterations=not_applicable_setup_only")
    println(io, "rejected_or_cut_ministeps=not_applicable_setup_only")
    println(io, "smallest_accepted_ministep_seconds=not_applicable_setup_only")
    println(io, "host_regions_max_gas_saturation=not_applicable_setup_only")
    println(
        io,
        "nonpredict_fault_max_gas_saturation=not_applicable_setup_only"
    )
    println(io, "pc_reference=sand_theta30")
    println(io, "pc_saturation_coordinate=effective_gas_saturation")
    println(io, "host_pc_scaling=leverett_kv")
    println(io, "nonpredict_pc_scaling=leverett_local_kzz")
    println(io, "younger_nonpredict_cells=$(diagnostics.younger.cells)")
    println(
        io,
        "younger_nonpredict_porosity_range=" *
        "$(diagnostics.younger.porosity_min)," *
        "$(diagnostics.younger.porosity_median)," *
        "$(diagnostics.younger.porosity_max)"
    )
    println(
        io,
        "younger_nonpredict_principal_perm_md=" *
        "$(diagnostics.younger.principal_min_md),500.0,500.0"
    )
    println(io, "mrst_transmissibility_present=false")
    println(io, "jutul_transmissibility=true")
    println(io, "transmissibility_min=$(minimum(diagnostics.transmissibility))")
    println(io, "qoi_schema=gom_qoi_semantics_v1")
    println(
        io,
        "qoi_primary_label_sha256=$(diagnostics.qoi.primary_label_sha256)"
    )
    println(io, "qoi_atomic_regions=$(diagnostics.qoi.atomic_regions)")
    println(io, "qoi_reporting_regions=$(diagnostics.qoi.reporting_regions)")
    println(io, "qoi_interfaces=$(diagnostics.qoi.interfaces)")
    println(io, "porosity_min=$(minimum(diagnostics.poro))")
    println(io, "porosity_max=$(maximum(diagnostics.poro))")
    println(
        io,
        "permeability_tensor_min_determinant=" *
        string(minimum(tensor_determinant))
    )
    println(io, "schedule_steps=$(length(dt))")
    println(io, "schedule_end_years=$(sum(dt)/mrst_year_seconds)")
end
println(
    "STEP62_EFFECTIVE_PC_GLOBAL_PLATEAU_PREFLIGHT_PASS " *
    "case=$expected_case_key summary=$summary_path"
)
