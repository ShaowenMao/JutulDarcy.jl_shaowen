module GoMStep62SandPcYCap50Contract

using LinearAlgebra
using Statistics
import Jutul
import JutulDarcy

const PHYSICS_PROFILE = "sandpc_ycap50_v1"
const EXPECTED_CELLS = 2_165_082
const EXPECTED_FOOTPRINTS = 24_886
const EXPECTED_SLICES = 87
const EXPECTED_FAULT_CELLS = 32_190
const EXPECTED_COMPLETE_FAULT_CELLS = 150_597
const EXPECTED_STRATIGRAPHY_CELLS = 828_240
const EXPECTED_BASE_REGIONS = 8
const EXPECTED_FAULT_REGIONS = 522
const EXPECTED_DRAINAGE_REGIONS = 530
const EXPECTED_TOTAL_SGOF_TABLES = 1_060
const EXPECTED_HYSTERESIS_S_MIN = 0.05
const EXPECTED_PC_ENTRY_SG_MAX = 1.0e-4
const EXPECTED_QOI_ATOMIC_REGIONS = 55
const EXPECTED_QOI_REPORTING_REGIONS = 69
const EXPECTED_QOI_INTERFACES = 193
const EXPECTED_QOI_PRIMARY_LABEL_SHA256 =
    "af168e103f8bbd2579fc2b15adfb92a8f23a8415ecb8a9929a965d93427a882d"
const EXPECTED_YOUNGER_NONPREDICT_CELLS = 10_701
const EXPECTED_YOUNGER_POROSITY_MIN = 0.327043235101
const EXPECTED_YOUNGER_POROSITY_MEDIAN = 0.351178026314
const EXPECTED_YOUNGER_POROSITY_MAX = 0.376642655825
const MILLI_DARCY_M2 = 9.869233e-16
const SAND_REFERENCE_ENTRY_PC_PA = 2_127.5290793963
const SAND_REFERENCE_SG = [
    0.0, 0.001, 0.0327586206896552, 0.0655172413793103,
    0.0982758620689655, 0.131034482758621, 0.163793103448276,
    0.196551724137931, 0.229310344827586, 0.262068965517241,
    0.294827586206897, 0.327586206896552, 0.360344827586207,
    0.393103448275862, 0.425862068965517, 0.458620689655172,
    0.491379310344828, 0.524137931034483, 0.556896551724138,
    0.589655172413793, 0.622413793103448, 0.655172413793103,
    0.687931034482759, 0.720689655172414, 0.753448275862069,
    0.786206896551724, 0.818965517241379, 0.851724137931034,
    0.88448275862069, 0.917241379310345, 0.949, 0.95
]
const SAND_REFERENCE_PC_PA = 1.0e5 .* [
    0.0, 0.021275290793963, 0.0219353425229389,
    0.0226632107435921, 0.0234440997564098, 0.024284142642694,
    0.0251904664438437, 0.0261714033626282, 0.0272367584564193,
    0.0283981523348905, 0.0296694646674108, 0.0310674150046951,
    0.0326123333935237, 0.0343291975751691, 0.0362490513502057,
    0.0384109788319319, 0.0408649075448139, 0.043675678554607,
    0.0469291090924114, 0.0507412918206338, 0.0552733530041737,
    0.0607558321714522, 0.0675309323510349, 0.0761301386973941,
    0.0874275704706403, 0.102972655104215, 0.125808170264687,
    0.162875030577446, 0.234376975917849, 0.436637515074132,
    10.006570196713, 11.0
]

# Shared/base SATNUM layout:
# 1 host LM2, 2 seal, 3:5 non-PREDICT LM2/MM-UM/Younger,
# 6 Al/Ar sand, 7 host MM-UM, 8 host Younger.
const EXPECTED_HOST_PC_ENTRY_PRESSURES_PA = Dict(
    1 => 10_308.843530180905,
    6 => 7_506.991553411633,
    7 => 7_107.373905989798,
    8 => 2_901.9949894790535
)
const EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA = Dict(
    3 => 43_730.432418928046,
    4 => 4_719.941933531145,
    5 => 2_906.874638988702
)
const EXPECTED_PC_ENTRY_PRESSURES_PA = merge(
    EXPECTED_HOST_PC_ENTRY_PRESSURES_PA,
    EXPECTED_NONPREDICT_PC_ENTRY_PRESSURES_PA
)
const REQUIRED_QOI_INTERFACES = Set([
    "storage_to_fault",
    "storage_to_al",
    "storage_to_ar",
    "fault_to_al",
    "fault_to_ar",
    "predict_to_nonpredict_fault",
    "fault_to_nonfault",
    "complete_seal_to_overburden",
    "fault_to_overburden"
])

function entry_pressure(table, region, table_role)
    entry_index = findfirst(
        value -> isapprox(
            value,
            0.001;
            rtol = 0,
            atol = 10*eps(0.001)
        ),
        table[:, 1]
    )
    isnothing(entry_index) && error(
        "$table_role SGOF region $region has no Sg=0.001 row."
    )
    return Float64(table[entry_index, 4])
end

function interpolate_sand_reference_pc(sg::Real)
    SAND_REFERENCE_SG[1] <= sg <= SAND_REFERENCE_SG[end] || error(
        "Cannot evaluate the sand Pc reference outside its Sg support: $sg."
    )
    right = searchsortedfirst(SAND_REFERENCE_SG, sg)
    if right == 1 || SAND_REFERENCE_SG[right] == sg
        return SAND_REFERENCE_PC_PA[right]
    end
    left = right - 1
    fraction = (sg - SAND_REFERENCE_SG[left]) /
        (SAND_REFERENCE_SG[right] - SAND_REFERENCE_SG[left])
    return SAND_REFERENCE_PC_PA[left] +
        fraction*(SAND_REFERENCE_PC_PA[right] - SAND_REFERENCE_PC_PA[left])
end

function validate_pc_tables(sgof)
    for (region, expected_pc) in EXPECTED_PC_ENTRY_PRESSURES_PA
        drainage = sgof[region]
        imbibition = sgof[EXPECTED_DRAINAGE_REGIONS + region]
        observed_pc = entry_pressure(drainage, region, "drainage")
        isapprox(
            observed_pc,
            expected_pc;
            rtol = 1.0e-10,
            atol = 1.0e-6
        ) || error(
            "Drainage SGOF region $region entry Pc is $observed_pc Pa; " *
            "expected $expected_pc Pa."
        )
        isapprox(
            Float64(drainage[1, 4]),
            0.0;
            rtol = 0,
            atol = 1.0e-9
        ) || error(
            "Drainage shared SGOF region $region unexpectedly has a " *
            "Pc plateau at Sg=0."
        )

        # Imbibition tables preserve their original saturation support and
        # generally do not contain Sg=0 or Sg=0.001. Validate both branches
        # against the sand-reference shape on each table's actual nodes.
        scale = expected_pc/SAND_REFERENCE_ENTRY_PC_PA
        for (role, table) in (("drainage", drainage), ("imbibition", imbibition))
            sg = Float64.(table[:, 1])
            pc = Float64.(table[:, 4])
            issorted(sg) && all(diff(sg) .> 0) ||
                error("$role SGOF region $region has invalid Sg support.")
            all(isfinite, pc) && all(>=(0.0), pc) ||
                error("$role SGOF region $region has invalid Pc values.")
            all(diff(pc) .>= 0) ||
                error("$role SGOF region $region has non-monotone Pc.")
            expected_curve =
                scale .* interpolate_sand_reference_pc.(sg)
            all(
                isapprox.(
                    pc,
                    expected_curve;
                    rtol = 1.0e-9,
                    atol = 1.0e-6
                )
            ) || error(
                "$role SGOF region $region does not match the scaled " *
                "30-degree sand reference on its native saturation nodes."
            )
        end
    end
    return nothing
end

function validate_younger_tensor(perm, poro, satnum)
    younger = findall(==(5), satnum)
    length(younger) == EXPECTED_YOUNGER_NONPREDICT_CELLS || error(
        "Non-PREDICT Younger region has $(length(younger)) cells; expected " *
        "$EXPECTED_YOUNGER_NONPREDICT_CELLS."
    )
    younger_poro = poro[younger]
    isapprox(
        minimum(younger_poro),
        EXPECTED_YOUNGER_POROSITY_MIN;
        rtol = 0,
        atol = 1.0e-10
    ) || error("Non-PREDICT Younger minimum porosity changed unexpectedly.")
    isapprox(
        median(younger_poro),
        EXPECTED_YOUNGER_POROSITY_MEDIAN;
        rtol = 0,
        atol = 1.0e-10
    ) || error("Non-PREDICT Younger median porosity changed unexpectedly.")
    isapprox(
        maximum(younger_poro),
        EXPECTED_YOUNGER_POROSITY_MAX;
        rtol = 0,
        atol = 1.0e-10
    ) || error("Non-PREDICT Younger maximum porosity changed unexpectedly.")

    expected_principal = MILLI_DARCY_M2 .* [50.0, 500.0, 500.0]
    expected_kxx = 500.0*MILLI_DARCY_M2
    component_atol = 1.0e-10*MILLI_DARCY_M2
    all(
        value -> isapprox(
            value,
            expected_kxx;
            rtol = 1.0e-6,
            atol = component_atol
        ),
        @view perm[younger, 1]
    ) || error("Non-PREDICT Younger global Kxx is not 500 mD.")
    maximum(abs, @view perm[younger, 2]) <= component_atol ||
        error("Non-PREDICT Younger global Kxy is not zero.")
    maximum(abs, @view perm[younger, 3]) <= component_atol ||
        error("Non-PREDICT Younger global Kxz is not zero.")

    minimum_eigenvalue = Inf
    maximum_eigenvalue = -Inf
    for cell in younger
        tensor = Symmetric([
            perm[cell, 1] perm[cell, 2] perm[cell, 3]
            perm[cell, 2] perm[cell, 4] perm[cell, 5]
            perm[cell, 3] perm[cell, 5] perm[cell, 6]
        ])
        values = eigvals(tensor)
        all(
            isapprox.(
                values,
                expected_principal;
                rtol = 1.0e-6,
                atol = component_atol
            )
        ) || error(
            "Non-PREDICT Younger cell $cell does not have principal " *
            "permeabilities [50, 500, 500] mD."
        )
        minimum_eigenvalue = min(minimum_eigenvalue, values[1])
        maximum_eigenvalue = max(maximum_eigenvalue, values[3])
    end
    return (
        cells = length(younger),
        porosity_min = minimum(younger_poro),
        porosity_median = median(younger_poro),
        porosity_max = maximum(younger_poro),
        principal_min_md = minimum_eigenvalue/MILLI_DARCY_M2,
        principal_max_md = maximum_eigenvalue/MILLI_DARCY_M2
    )
end

function validate_assembled_case(setup; validate_qoi = true)
    reservoir_model = setup.case.model.models[:Reservoir]
    relative_permeability = reservoir_model[:RelativePermeabilities]
    JutulDarcy.hysteresis_is_active(relative_permeability) ||
        error("Hysteresis is not active.")

    mrst = setup.mrst
    haskey(mrst, "metadata") ||
        error("Assembled input is missing common physics metadata.")
    get(mrst["metadata"], "physics_profile", "") == PHYSICS_PROFILE ||
        error("Assembled input has the wrong physics profile.")
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
    sort(unique(imbnum)) == collect(
        (EXPECTED_DRAINAGE_REGIONS + 1):EXPECTED_TOTAL_SGOF_TABLES
    ) || error("Unexpected imbibition saturation regions.")
    length(sgof) == EXPECTED_TOTAL_SGOF_TABLES ||
        error("Unexpected SGOF table count.")
    all(isfinite, transmissibility) ||
        error("Jutul transmissibility contains non-finite values.")
    all(>(0.0), transmissibility) ||
        error("Jutul transmissibility is not strictly positive.")

    fault_summary["base_regions"] == EXPECTED_BASE_REGIONS ||
        error("Unexpected shared/base saturation-region count.")
    fault_summary["fault_regions"] == EXPECTED_FAULT_REGIONS ||
        error("Unexpected explicit PREDICT saturation-region count.")
    fault_summary["drainage_regions"] == EXPECTED_DRAINAGE_REGIONS ||
        error("Unexpected total drainage saturation-region count.")
    fault_summary["sgof_tables"] == EXPECTED_TOTAL_SGOF_TABLES ||
        error("Unexpected total drainage/imbibition table count.")
    fault_summary["hysteresis"] ==
        "reservoir_only_fault_drainage_duplicate" ||
        error("Explicit PREDICT regions are not drainage-equivalent.")
    pc_summary["treatment"] == "plateau" ||
        error("Explicit PREDICT Pc plateau treatment is not active.")
    pc_summary["adjusted_tables"] == EXPECTED_FAULT_REGIONS ||
        error("Not all 522 explicit PREDICT Pc tables received the plateau.")
    pc_summary["skipped_tables"] == 0 ||
        error("One or more explicit PREDICT Pc tables skipped the plateau.")
    isapprox(
        Float64(pc_summary["sg_max"]),
        EXPECTED_PC_ENTRY_SG_MAX;
        rtol = 0,
        atol = eps(Float64)
    ) || error("Unexpected fault Pc plateau Sg threshold.")

    validate_pc_tables(sgof)
    younger = validate_younger_tensor(perm, poro, satnum)

    for region in (EXPECTED_BASE_REGIONS + 1):EXPECTED_DRAINAGE_REGIONS
        drainage = sgof[region]
        imbibition = sgof[EXPECTED_DRAINAGE_REGIONS + region]
        drainage == imbibition ||
            error("Explicit PREDICT region $region has hysteretic Kr.")
        drainage[1, 1] == 0 ||
            error("Explicit PREDICT region $region does not start at Sg=0.")
        drainage[2, 1] <= EXPECTED_PC_ENTRY_SG_MAX ||
            error("Explicit PREDICT region $region plateau is too wide.")
        drainage[1, 4] == drainage[2, 4] ||
            error("Explicit PREDICT region $region lacks an entry plateau.")
        drainage[1, 4] > 0 ||
            error("Explicit PREDICT region $region has non-positive entry Pc.")
    end

    qoi_diagnostics = nothing
    if validate_qoi
        qoi = JutulDarcy.production_qoi_compile_regions(mrst)
        length(qoi.atomic_code) == EXPECTED_CELLS ||
            error("QoI atomic cell labels have the wrong length.")
        length(qoi.atomic_regions) == EXPECTED_QOI_ATOMIC_REGIONS ||
            error("Unexpected QoI atomic-region count.")
        length(qoi.regions) == EXPECTED_QOI_REPORTING_REGIONS ||
            error("Unexpected QoI reporting-region count.")
        qoi.primary_label_sha256 == EXPECTED_QOI_PRIMARY_LABEL_SHA256 ||
            error("QoI primary UCID label digest changed.")
        neighbors = JutulDarcy.production_qoi_neighbors(
            reservoir_model,
            EXPECTED_CELLS
        )
        interfaces = JutulDarcy.production_qoi_build_interfaces(
            qoi.atomic_code,
            qoi.atomic_regions,
            neighbors,
            qoi.special_codes
        )
        length(interfaces) == EXPECTED_QOI_INTERFACES ||
            error("Unexpected QoI interface count.")
        interface_ids = Set(interface.id for interface in interfaces)
        issubset(REQUIRED_QOI_INTERFACES, interface_ids) ||
            error("One or more required QoI interfaces is missing.")
        all(!isempty(interface.faces) for interface in interfaces) ||
            error("A compiled QoI interface contains no simulator faces.")
        qoi_diagnostics = (
            atomic_regions = length(qoi.atomic_regions),
            reporting_regions = length(qoi.regions),
            interfaces = length(interfaces),
            primary_label_sha256 = qoi.primary_label_sha256
        )
    end

    return (
        mrst = mrst,
        reservoir_model = reservoir_model,
        poro = poro,
        perm = perm,
        satnum = satnum,
        imbnum = imbnum,
        sgof = sgof,
        transmissibility = transmissibility,
        fault_summary = fault_summary,
        pc_summary = pc_summary,
        younger = younger,
        qoi = qoi_diagnostics
    )
end

end
