using JutulDarcy
import Jutul
import MAT

length(ARGS) == 9 || error(
    "Usage: gom_step62_production_preflight.jl COMMON_MAT SPECIFIC_MAT " *
    "RESULT_DIR CASE_KEY GEOLOGY_ID REALIZATION_ID GEOLOGY_HASH " *
    "LEVEL3_CASE_NAME MANIFEST_SHA256"
)
common_path, specific_path, result_dir, expected_case_key,
    expected_geology_id, expected_realization_text, expected_geology_hash,
    expected_level3_case_name,
    expected_manifest_sha256 = ARGS
expected_realization_id = parse(Int, expected_realization_text)
mkpath(result_dir)

const EXPECTED_CELLS = 2_165_082
const EXPECTED_FOOTPRINTS = 24_886
const EXPECTED_SLICES = 87
const EXPECTED_FAULT_CELLS = 32_190
const EXPECTED_STRATIGRAPHY_CELLS = 828_240
const EXPECTED_BASE_REGIONS = 5
const EXPECTED_FAULT_REGIONS = 522
const EXPECTED_DRAINAGE_REGIONS = 527
const EXPECTED_TOTAL_SGOF_TABLES = 1_054
const EXPECTED_HYSTERESIS_S_MIN = 0.05
const EXPECTED_PC_ENTRY_SG_MAX = 1.0e-4
const EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA = [
    19329.0593991,
    2086.23681374,
    642.426217335
]

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
specific_realization_id =
    Int(round(scalar_value(specific["realization_id"])))
specific_realization_id == expected_realization_id ||
    error("Specific input realization ID does not match the immutable manifest.")

setup = simulate_mrst_case(
    specific_path;
    common_mrst_path = common_path,
    specific_mrst_path = specific_path,
    do_sim = false,
    write_output = false,
    verbose = true,
    disable_hysteresis = false,
    hysteresis_s_min = EXPECTED_HYSTERESIS_S_MIN,
    use_mrst_transmissibility = false,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau",
    fault_pc_entry_sg_max = EXPECTED_PC_ENTRY_SG_MAX,
    explicit_fault_hysteresis_mode = "reservoir",
    ds_max = 0.05,
    max_nonlinear_iterations = 10,
    max_timestep_cuts = 25,
    well_volume_fraction = 1.0e-3,
    nthreads = Threads.nthreads()
)

reservoir_model = setup.case.model.models[:Reservoir]
relative_permeability = reservoir_model[:RelativePermeabilities]
JutulDarcy.hysteresis_is_active(relative_permeability) ||
    error("Hysteresis is not active in the requested preflight.")

mrst = setup.mrst
rock = mrst["rock"]
regions = rock["regions"]
poro = Float64.(vec(rock["poro"]))
perm = Float64.(rock["perm"])
satnum = Int.(round.(vec(regions["saturation"])))
imbnum = Int.(round.(vec(regions["imbibition"])))
props = mrst["deck"]["PROPS"]
runspec = mrst["deck"]["RUNSPEC"]
sgof = vec(props["SGOF"])
fault_summary = mrst["fault_saturation_domain_summary"]
pc_summary = fault_summary["pc_entry_treatment"]
transmissibility = Float64.(
    vec(setup.case.parameters[:Reservoir][:Transmissibilities])
)
nc = Jutul.number_of_cells(reservoir_model.domain)

nc == EXPECTED_CELLS || error("Unexpected cell count: $nc")
nc == EXPECTED_FOOTPRINTS*EXPECTED_SLICES ||
    error("Cell count is inconsistent with the Step62 extrusion.")
!haskey(mrst, "T") || error("MRST transmissibility unexpectedly present.")
!haskey(mrst, "T_all") ||
    error("MRST half-transmissibility unexpectedly present.")
!haskey(runspec, "NOHYST") || error("NOHYST is unexpectedly active.")
haskey(props, "EHYSTR") || error("EHYSTR is missing.")
isapprox(
    Float64(props["EHYSTR"][12]),
    EXPECTED_HYSTERESIS_S_MIN;
    rtol = 0,
    atol = eps(Float64)
) || error("Unexpected hysteresis S_min.")
length(poro) == EXPECTED_CELLS || error("Porosity has the wrong length.")
size(perm) == (EXPECTED_CELLS, 6) ||
    error("Permeability tensor has the wrong shape.")
all(isfinite, poro) || error("Porosity contains non-finite values.")
all(value -> 0 < value < 1, poro) ||
    error("Porosity is outside physical bounds.")
all(isfinite, perm) || error("Permeability contains non-finite values.")
sort(unique(satnum)) == collect(1:EXPECTED_DRAINAGE_REGIONS) ||
    error("Unexpected drainage saturation regions.")
imbnum == satnum .+ EXPECTED_DRAINAGE_REGIONS ||
    error("Drainage and imbibition regions are not paired.")
sort(unique(imbnum)) ==
    collect(
        (EXPECTED_DRAINAGE_REGIONS + 1):EXPECTED_TOTAL_SGOF_TABLES
    ) || error("Unexpected imbibition saturation regions.")
length(sgof) == EXPECTED_TOTAL_SGOF_TABLES ||
    error("Unexpected SGOF table count.")
all(isfinite, transmissibility) ||
    error("Jutul transmissibility contains non-finite values.")
all(>(0.0), transmissibility) ||
    error("Jutul transmissibility is not strictly positive.")

for (offset, expected_pc) in enumerate(
        EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA
    )
    region = 2 + offset
    table = sgof[region]
    entry_index = findfirst(
        value -> isapprox(
            value,
            0.001;
            rtol = 0,
            atol = 10*eps(0.001)
        ),
        table[:, 1]
    )
    isnothing(entry_index) &&
        error("Base non-PREDICT SGOF region $region has no Sg=0.001 row.")
    isapprox(
        table[entry_index, 4],
        expected_pc;
        rtol = 1.0e-10,
        atol = 1.0e-6
    ) || error(
        "Base non-PREDICT SGOF region $region does not use the " *
        "30-degree reference."
    )
end

fault_summary["base_regions"] == EXPECTED_BASE_REGIONS ||
    error("Unexpected base saturation-region count.")
fault_summary["fault_regions"] == EXPECTED_FAULT_REGIONS ||
    error("Unexpected explicit fault saturation-region count.")
fault_summary["drainage_regions"] == EXPECTED_DRAINAGE_REGIONS ||
    error("Unexpected total drainage saturation-region count.")
fault_summary["sgof_tables"] == EXPECTED_TOTAL_SGOF_TABLES ||
    error("Unexpected total drainage/imbibition table count.")
fault_summary["hysteresis"] ==
    "reservoir_only_fault_drainage_duplicate" ||
    error("Explicit fault regions are not drainage-equivalent.")
pc_summary["treatment"] == "plateau" ||
    error("Fault Pc plateau treatment is not active.")
pc_summary["adjusted_tables"] == EXPECTED_FAULT_REGIONS ||
    error("Not all explicit fault Pc tables received the plateau.")
pc_summary["skipped_tables"] == 0 ||
    error("One or more explicit fault Pc tables skipped the plateau.")
isapprox(
    Float64(pc_summary["sg_max"]),
    EXPECTED_PC_ENTRY_SG_MAX;
    rtol = 0,
    atol = eps(Float64)
) || error("Unexpected fault Pc plateau Sg threshold.")

for region in (EXPECTED_BASE_REGIONS + 1):EXPECTED_DRAINAGE_REGIONS
    drainage = sgof[region]
    imbibition = sgof[EXPECTED_DRAINAGE_REGIONS + region]
    drainage == imbibition ||
        error("Explicit fault region $region has hysteretic Kr.")
    drainage[1, 1] == 0 ||
        error("Explicit fault region $region does not start at Sg=0.")
    drainage[2, 1] <= EXPECTED_PC_ENTRY_SG_MAX ||
        error("Explicit fault region $region plateau is too wide.")
    drainage[1, 4] == drainage[2, 4] ||
        error("Explicit fault region $region lacks an entry plateau.")
    drainage[1, 4] > 0 ||
        error("Explicit fault region $region has non-positive entry Pc.")
end

# Rotated symmetric permeability ordering:
# [Kxx, Kxy, Kxz, Kyy, Kyz, Kzz].
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

mrst["stratigraphy_specific_summary"]["cell_count"] ==
    EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected geology-specific stratigraphy cell count.")
length(vec(specific["fault"]["cells"])) == EXPECTED_FAULT_CELLS ||
    error("Unexpected geology-specific fault cell count.")
length(vec(specific["stratigraphy"]["cells"])) ==
    EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected geology-specific stratigraphy cell count.")

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

schema = specific["schema"]
geology_hash = specific["geology_hash"]
level3_case_name = specific["level3_case_name"]
summary_path = joinpath(result_dir, "preflight_summary.txt")
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "case_key=$expected_case_key")
    println(io, "campaign_manifest_sha256=$(lowercase(expected_manifest_sha256))")
    println(io, "schema=$schema")
    println(io, "common_name=$expected_common_name")
    println(io, "geology_id=$expected_geology_id")
    println(io, "geology_hash=$geology_hash")
    println(io, "realization_id=$expected_realization_id")
    println(io, "level3_case_name=$level3_case_name")
    println(io, "resolution_slices=$EXPECTED_SLICES")
    println(io, "cells=$nc")
    println(io, "fault_cells=$EXPECTED_FAULT_CELLS")
    println(io, "stratigraphy_cells=$EXPECTED_STRATIGRAPHY_CELLS")
    println(io, "drainage_saturation_regions=$EXPECTED_DRAINAGE_REGIONS")
    println(io, "total_sgof_tables=$EXPECTED_TOTAL_SGOF_TABLES")
    println(io, "hysteresis_active=true")
    println(io, "hysteresis_s_min=$EXPECTED_HYSTERESIS_S_MIN")
    println(io, "fault_hysteresis=drainage_equivalent")
    println(io, "pc_curve_treatment=fault_plateau")
    println(io, "pc_plateau_adjusted_tables=$(pc_summary["adjusted_tables"])")
    println(io, "pc_plateau_skipped_tables=$(pc_summary["skipped_tables"])")
    println(io, "pc_plateau_sg_max=$EXPECTED_PC_ENTRY_SG_MAX")
    println(io, "nonpredict_pc_reference_contact_angle_deg=30.0")
    println(
        io,
        "nonpredict_pc_entry_pressures_Pa=" *
        join(EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA, ",")
    )
    println(io, "mrst_transmissibility_present=false")
    println(io, "jutul_transmissibility=true")
    println(io, "transmissibility_min=$(minimum(transmissibility))")
    println(io, "porosity_min=$(minimum(poro))")
    println(io, "porosity_max=$(maximum(poro))")
    println(
        io,
        "permeability_tensor_min_determinant=" *
        string(minimum(tensor_determinant))
    )
    println(io, "schedule_steps=$(length(dt))")
    println(io, "schedule_end_years=$(sum(dt)/mrst_year_seconds)")
end
println(
    "STEP62_PRODUCTION_PREFLIGHT_PASS " *
    "case=$expected_case_key summary=$summary_path"
)
