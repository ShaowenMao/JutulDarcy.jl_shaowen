using JutulDarcy
import Jutul
import MAT

length(ARGS) == 3 || error(
    "Usage: gom_step62_four_geology_hyst_plateau_preflight.jl " *
    "COMMON_MAT SPECIFIC_MAT RESULT_DIR"
)
common_path, specific_path, result_dir = ARGS
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
const EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG = parse(
    Float64,
    get(ENV, "EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG", "NaN")
)
const EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA = [
    19329.0593991,
    2086.23681374,
    642.426217335
]

scalar_value(x) = x isa AbstractArray ? only(vec(x)) : x

specific = MAT.matread(specific_path)
get(specific, "schema", "") in
    ("gom_jutul_split_specific_v3", "gom_jutul_split_specific_v4") ||
    error("Expected combined geology-specific schema v3 or v4.")
get(specific, "common_name", "") == "gom_step62_87slice_s05_c012_common" ||
    error("Combined specific file names the wrong common input.")

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

@assert nc == EXPECTED_CELLS
@assert nc == EXPECTED_FOOTPRINTS*EXPECTED_SLICES
@assert !haskey(mrst, "T")
@assert !haskey(mrst, "T_all")
@assert !haskey(runspec, "NOHYST")
@assert haskey(props, "EHYSTR")
@assert isapprox(
    Float64(props["EHYSTR"][12]),
    EXPECTED_HYSTERESIS_S_MIN;
    rtol = 0,
    atol = eps(Float64)
)
@assert length(poro) == EXPECTED_CELLS
@assert size(perm) == (EXPECTED_CELLS, 6)
@assert all(isfinite, poro)
@assert all(x -> 0 < x < 1, poro)
@assert all(isfinite, perm)
@assert sort(unique(satnum)) == collect(1:EXPECTED_DRAINAGE_REGIONS)
@assert imbnum == satnum .+ EXPECTED_DRAINAGE_REGIONS
@assert sort(unique(imbnum)) ==
    collect((EXPECTED_DRAINAGE_REGIONS + 1):EXPECTED_TOTAL_SGOF_TABLES)
@assert length(sgof) == EXPECTED_TOTAL_SGOF_TABLES
@assert all(isfinite, transmissibility)
@assert all(>(0.0), transmissibility)

if isfinite(EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG)
    @assert EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG == 30
    for (offset, expected_pc) in enumerate(
        EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA
    )
        region = 2 + offset
        table = sgof[region]
        entry_index = findfirst(
            x -> isapprox(x, 0.001; rtol = 0, atol = 10*eps(0.001)),
            table[:, 1]
        )
        isnothing(entry_index) &&
            error("Base non-PREDICT SGOF region $region has no Sg=0.001 row.")
        @assert isapprox(
            table[entry_index, 4],
            expected_pc;
            rtol = 1.0e-10,
            atol = 1.0e-6
        )
    end
end

@assert fault_summary["base_regions"] == EXPECTED_BASE_REGIONS
@assert fault_summary["fault_regions"] == EXPECTED_FAULT_REGIONS
@assert fault_summary["drainage_regions"] == EXPECTED_DRAINAGE_REGIONS
@assert fault_summary["sgof_tables"] == EXPECTED_TOTAL_SGOF_TABLES
@assert fault_summary["hysteresis"] ==
    "reservoir_only_fault_drainage_duplicate"
@assert pc_summary["treatment"] == "plateau"
@assert pc_summary["adjusted_tables"] == EXPECTED_FAULT_REGIONS
@assert pc_summary["skipped_tables"] == 0
@assert isapprox(
    Float64(pc_summary["sg_max"]),
    EXPECTED_PC_ENTRY_SG_MAX;
    rtol = 0,
    atol = eps(Float64)
)

for region in (EXPECTED_BASE_REGIONS + 1):EXPECTED_DRAINAGE_REGIONS
    drainage = sgof[region]
    imbibition = sgof[EXPECTED_DRAINAGE_REGIONS + region]
    @assert drainage == imbibition
    @assert drainage[1, 1] == 0
    @assert drainage[2, 1] <= EXPECTED_PC_ENTRY_SG_MAX
    @assert drainage[1, 4] == drainage[2, 4]
    @assert drainage[1, 4] > 0
end

# Rotated symmetric permeability uses
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
@assert all(>(0.0), kxx)
@assert all(>(0.0), kyy)
@assert all(>(0.0), kzz)
@assert all(>(0.0), second_principal_minor)
@assert all(>(0.0), tensor_determinant)

@assert mrst["stratigraphy_specific_summary"]["cell_count"] ==
    EXPECTED_STRATIGRAPHY_CELLS
@assert length(vec(specific["fault"]["cells"])) == EXPECTED_FAULT_CELLS
@assert length(vec(specific["stratigraphy"]["cells"])) ==
    EXPECTED_STRATIGRAPHY_CELLS

dt = Float64.(vec(setup.case.dt))
@assert length(dt) == 210
@assert all(>(0.0), dt)
mrst_year_seconds = 365.2425*24*60*60
@assert isapprox(sum(dt), 1000*mrst_year_seconds; rtol = 0, atol = 1.0)

schema = specific["schema"]
geology_id = specific["geology_id"]
geology_hash = specific["geology_hash"]
realization_id = Int(round(scalar_value(specific["realization_id"])))
level3_case_name = specific["level3_case_name"]
summary_path = joinpath(result_dir, "preflight_summary.txt")
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "schema=$schema")
    println(io, "geology_id=$geology_id")
    println(io, "geology_hash=$geology_hash")
    println(io, "realization_id=$realization_id")
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
    if isfinite(EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG)
        println(
            io,
            "nonpredict_pc_reference_contact_angle_deg=" *
            string(EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG)
        )
        println(
            io,
            "nonpredict_pc_entry_pressures_Pa=" *
            join(EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA, ",")
        )
    end
    println(io, "mrst_transmissibility_present=false")
    println(io, "jutul_transmissibility=true")
    println(io, "transmissibility_min=$(minimum(transmissibility))")
    println(io, "porosity_min=$(minimum(poro))")
    println(io, "porosity_max=$(maximum(poro))")
    println(io, "permeability_tensor_min_determinant=$(minimum(tensor_determinant))")
    println(io, "schedule_steps=$(length(dt))")
    println(io, "schedule_end_years=$(sum(dt)/mrst_year_seconds)")
end
println("STEP62_FOUR_GEOLOGY_HYST_PLATEAU_PREFLIGHT_PASS summary=$summary_path")
