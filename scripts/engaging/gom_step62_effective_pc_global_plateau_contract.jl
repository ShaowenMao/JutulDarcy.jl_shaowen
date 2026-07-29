module GoMStep62EffectivePcGlobalPlateauContract

using LinearAlgebra
using Statistics
import Jutul
import JutulDarcy

const PHYSICS_PROFILE = "sandpc_effective_globalplateau_v1"
const PC_MAPPING_SCHEMA = "gom_effective_saturation_pc_v1"
const PC_MAPPING_METHOD = "entry_renormalized_analytic_brooks_corey"
const PC_ENTRY_TREATMENT = "plateau_all_active"
const PC_ENTRY_SCOPE = "all_active_drainage"
const PC_ENTRY_RULE = "first_strictly_positive_pc_node"
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
const EXPECTED_MRST_DRAINAGE_REGIONS = 14
const EXPECTED_MRST_TOTAL_SGOF_TABLES = 28
const EXPECTED_HYSTERESIS_S_MIN = 0.05
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
const EXPECTED_EFFECTIVE_PC_REGIONS = [1, 3, 4, 5, 6, 7, 8]
const EXPECTED_UNCHANGED_PC_REGIONS = [2, 9, 10, 11, 12, 13, 14]
const EXPECTED_EFFECTIVE_ENTRY_PRESSURES_PA = Dict(
    1 => 10_308.8435301809,
    3 => 43_730.4324189280,
    4 => 4_719.94193353115,
    5 => 2_906.87463898870,
    6 => 7_506.99155341164,
    7 => 7_107.37390598980,
    8 => 2_901.99498947906
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

scalar_value(x) = x isa AbstractArray ? only(vec(x)) : x
as_int_vector(x) = Int.(round.(vec(x)))

function as_string_vector(value)
    if value isa AbstractString
        return [String(value)]
    elseif value isa AbstractArray
        result = String[]
        for item in vec(value)
            append!(result, as_string_vector(item))
        end
        return result
    else
        error("Expected string or string array, got $(typeof(value)).")
    end
end

function valid_sha256(value)
    value isa AbstractString || return false
    return occursin(r"^[0-9a-f]{64}$", lowercase(value))
end

function get_any(dictionary, names::Tuple; label = first(names))
    for name in names
        haskey(dictionary, name) && return dictionary[name]
    end
    error("Missing $label metadata.")
end

function require_scalar_close(dictionary, names::Tuple, expected;
        atol = 100*eps(Float64), label = first(names))
    observed = Float64(scalar_value(get_any(dictionary, names; label = label)))
    isapprox(observed, expected; rtol = 0, atol = atol) ||
        error("$label is $observed; expected $expected.")
    return observed
end

function validate_pc_mapping_metadata(metadata)
    mapping = get_any(metadata, ("pc_mapping",); label = "pc_mapping")
    get_any(mapping, ("schema",)) == PC_MAPPING_SCHEMA ||
        error("Unexpected effective-saturation Pc mapping schema.")
    get_any(mapping, ("method",)) == PC_MAPPING_METHOD ||
        error("Unexpected effective-saturation Pc mapping method.")
    get_any(mapping, ("physics_profile",)) == PHYSICS_PROFILE ||
        error("Pc mapping metadata has the wrong physics profile.")
    as_int_vector(get_any(
        mapping,
        ("affected_drainage_regions", "affectedDrainageRegions")
    )) == EXPECTED_EFFECTIVE_PC_REGIONS ||
        error("Unexpected effective-saturation Pc region set.")
    as_int_vector(get_any(
        mapping,
        ("unchanged_drainage_regions", "unchangedDrainageRegions")
    )) == EXPECTED_UNCHANGED_PC_REGIONS ||
        error("Unexpected unchanged Pc region set.")
    as_int_vector(get_any(mapping, ("affected_imbibition_regions",))) ==
        EXPECTED_EFFECTIVE_PC_REGIONS .+ EXPECTED_MRST_DRAINAGE_REGIONS ||
        error("Unexpected effective-saturation imbibition region set.")
    as_int_vector(get_any(mapping, ("unchanged_imbibition_regions",))) ==
        EXPECTED_UNCHANGED_PC_REGIONS .+ EXPECTED_MRST_DRAINAGE_REGIONS ||
        error("Unexpected unchanged imbibition region set.")
    as_int_vector(get_any(mapping, ("predict_drainage_regions",))) ==
        collect(9:14) ||
        error("Unexpected PREDICT source drainage-region set.")
    require_scalar_close(
        mapping,
        ("reference_swi", "referenceSwi"),
        0.05;
        label = "reference Swi"
    )
    require_scalar_close(
        mapping,
        ("reference_sg_max",),
        0.95;
        label = "reference maximum gas saturation"
    )
    require_scalar_close(
        mapping,
        ("host_target_swi", "hostTargetSwi"),
        0.3092;
        label = "host target Swi"
    )
    require_scalar_close(
        mapping,
        ("nonpredict_target_swi", "nonPredictTargetSwi"),
        0.3696;
        label = "non-PREDICT target Swi"
    )
    require_scalar_close(
        mapping,
        ("entry_sg", "entrySg"),
        0.001;
        label = "reference entry Sg"
    )
    require_scalar_close(
        mapping,
        ("reference_entry_pressure_Pa", "referenceEntryPressure_Pa"),
        2_127.5290793963;
        atol = 1.0e-6,
        label = "reference entry pressure"
    )
    require_scalar_close(
        mapping,
        ("reference_prescale_cap_Pa", "referencePreScaleCap_Pa"),
        1.1e6;
        atol = 1.0e-6,
        label = "reference pre-scale cap"
    )
    get_any(mapping, ("cap_order", "capOrder")) ==
        "reference_before_leverett" ||
        error("Reference Pc cap was not applied before Leverett scaling.")
    Int(round(scalar_value(get_any(
        mapping,
        ("tail_log_node_count", "tailLogNodeCount")
    )))) == 36 || error("Unexpected effective-Pc tail refinement.")
    get_any(mapping, ("tail_node_coordinate",)) ==
        "log_spaced_effective_water_saturation_entry_to_cap_onset" ||
        error("Unexpected effective-Pc tail-node coordinate.")
    require_scalar_close(
        mapping,
        ("relative_error_tolerance", "relativeErrorTolerance"),
        0.01;
        label = "effective-Pc relative error tolerance"
    )
    require_scalar_close(
        mapping,
        ("adjacent_pc_ratio_limit", "adjacentPcRatioLimit"),
        2.0;
        label = "effective-Pc adjacent-node ratio limit"
    )
    Bool(scalar_value(get_any(
        mapping,
        ("mrst_entry_plateau_applied", "mrstEntryPlateauApplied")
    ))) == false ||
        error("MRST must export unplateaued Pc; Jutul applies the plateau.")
    get_any(mapping, ("jutul_plateau_mode", "jutulPlateauMode")) ==
        PC_ENTRY_TREATMENT ||
        error("MRST metadata names the wrong Jutul plateau mode.")
    get_any(mapping, ("plateau_scope",)) ==
        "all_active_assembled_pc_curves" ||
        error("MRST metadata names the wrong plateau scope.")
    require_scalar_close(
        mapping,
        ("brooks_corey_lambda",),
        1.1140754975445266;
        atol = 5.0e-13,
        label = "Brooks-Corey lambda"
    )
    max_kr_error = require_scalar_close(
        mapping,
        ("max_dense_kr_absolute_error",),
        0.0;
        atol = 1.0e-14,
        label = "maximum dense Kr error"
    )
    max_pc_error = Float64(scalar_value(
        get_any(mapping, ("max_analytic_pc_relative_error",))
    ))
    0 <= max_pc_error <= 0.01 ||
        error("Refined effective-Pc interpolation error exceeds 1%.")
    reference_fit_error = Float64(scalar_value(
        get_any(mapping, ("reference_fit_max_relative_error",))
    ))
    0 <= reference_fit_error <= 1.0e-12 ||
        error("Native reference no longer satisfies the frozen fit.")
    max_pc_ratio = Float64(scalar_value(
        get_any(mapping, ("max_adjacent_positive_pc_ratio",))
    ))
    1 <= max_pc_ratio <= 2.0 ||
        error("Refined effective-Pc adjacent-node ratio exceeds 2.")

    original_point_counts =
        as_int_vector(get_any(mapping, ("original_table_point_counts",)))
    refined_point_counts =
        as_int_vector(get_any(mapping, ("refined_table_point_counts",)))
    inserted_point_counts =
        as_int_vector(get_any(mapping, ("inserted_table_point_counts",)))
    drainage_point_counts =
        as_int_vector(get_any(mapping, ("drainage_table_point_counts",)))
    length(original_point_counts) == EXPECTED_MRST_TOTAL_SGOF_TABLES ||
        error("Original Pc point-count vector must have 28 entries.")
    length(refined_point_counts) == EXPECTED_MRST_TOTAL_SGOF_TABLES ||
        error("Refined Pc point-count vector must have 28 entries.")
    length(inserted_point_counts) == EXPECTED_MRST_TOTAL_SGOF_TABLES ||
        error("Inserted Pc point-count vector must have 28 entries.")
    length(drainage_point_counts) == EXPECTED_MRST_DRAINAGE_REGIONS ||
        error("Drainage Pc point-count vector must have 14 entries.")
    all(>=(2), original_point_counts) &&
        all(>=(2), refined_point_counts) &&
        all(>=(0), inserted_point_counts) ||
        error("Pc mapping metadata contains invalid point counts.")
    refined_point_counts - original_point_counts == inserted_point_counts ||
        error("Pc point-count accounting is inconsistent.")
    drainage_point_counts == refined_point_counts[1:14] ||
        error("Drainage point counts disagree with refined table counts.")
    affected_tables = sort(vcat(
        EXPECTED_EFFECTIVE_PC_REGIONS,
        EXPECTED_EFFECTIVE_PC_REGIONS .+ EXPECTED_MRST_DRAINAGE_REGIONS
    ))
    unchanged_tables =
        setdiff(collect(1:EXPECTED_MRST_TOTAL_SGOF_TABLES), affected_tables)
    all(>(0), inserted_point_counts[affected_tables]) ||
        error("An affected effective-Pc table received no refined nodes.")
    all(iszero, inserted_point_counts[unchanged_tables]) ||
        error("An unchanged SGOF table received refined nodes.")

    digest_contract = (
        original_table_sha256 = 28,
        refined_table_sha256 = 28,
        drainage_table_sha256 = 14,
        drainage_kr_sha256 = 14,
        drainage_pc_tail_sha256 = 14,
        base_imbibition_sha256 = 14
    )
    digests = Dict{String, Vector{String}}()
    for (key, expected_count) in pairs(digest_contract)
        values = as_string_vector(get_any(mapping, (String(key),)))
        length(values) == expected_count ||
            error("$key must contain $expected_count digests.")
        all(valid_sha256, values) ||
            error("$key contains an invalid SHA-256 digest.")
        digests[String(key)] = values
    end
    digests["drainage_table_sha256"] ==
        digests["refined_table_sha256"][1:14] ||
        error("Drainage table digests disagree with refined-table digests.")
    digests["base_imbibition_sha256"] ==
        digests["refined_table_sha256"][15:28] ||
        error("Imbibition table digests disagree with refined-table digests.")
    all(
        digests["original_table_sha256"][index] ==
            digests["refined_table_sha256"][index]
        for index in unchanged_tables
    ) || error("An unchanged SGOF table digest changed.")
    all(
        digests["original_table_sha256"][index] !=
            digests["refined_table_sha256"][index]
        for index in affected_tables
    ) || error("An affected SGOF table digest did not change.")
    valid_sha256(get_any(mapping, ("reference_deck_sha256",))) ||
        error("Pc mapping reference deck digest is invalid.")
    digest_value_count =
        sum(length(values) for values in values(digests)) + 1

    return (
        mapping = mapping,
        digest_count = digest_value_count,
        point_counts = drainage_point_counts,
        original_point_counts = original_point_counts,
        refined_point_counts = refined_point_counts,
        max_dense_kr_absolute_error = max_kr_error,
        reference_fit_max_relative_error = reference_fit_error,
        max_analytic_pc_relative_error = max_pc_error,
        max_adjacent_positive_pc_ratio = max_pc_ratio
    )
end

function validate_pc_plateau_tables(sgof, pc_summary)
    active_regions = as_int_vector(pc_summary["adjusted_regions"])
    active_regions == collect(1:EXPECTED_DRAINAGE_REGIONS) ||
        error("The global plateau did not adjust exactly regions 1:530.")
    entry_rows = as_int_vector(pc_summary["entry_row_indices"])
    entry_sg = Float64.(vec(pc_summary["entry_sg"]))
    entry_pressure = Float64.(vec(pc_summary["entry_pressure_pa"]))
    length(entry_rows) == EXPECTED_DRAINAGE_REGIONS ||
        error("Pc plateau entry-row metadata has the wrong length.")
    all(>(1), entry_rows) ||
        error("Every input drainage curve must begin below its positive entry.")
    all(value -> isfinite(value) && value > 0, entry_sg) ||
        error("Pc plateau entry saturation metadata is invalid.")
    all(value -> isfinite(value) && value > 0, entry_pressure) ||
        error("Pc plateau entry-pressure metadata is invalid.")
    for (region, expected) in EXPECTED_EFFECTIVE_ENTRY_PRESSURES_PA
        isapprox(
            entry_pressure[region],
            expected;
            rtol = 1.0e-10,
            atol = 1.0e-6
        ) || error(
            "Drainage region $region entry pressure is " *
            "$(entry_pressure[region]) Pa; expected $expected Pa."
        )
    end

    maximum_piecewise_slope = 0.0
    for region in 1:EXPECTED_DRAINAGE_REGIONS
        table = sgof[region]
        table isa AbstractMatrix && size(table, 1) >= 2 &&
            size(table, 2) >= 4 ||
            error("Drainage SGOF region $region is invalid.")
        sg = Float64.(table[:, 1])
        kr = Float64.(table[:, 2:3])
        pc = Float64.(table[:, 4])
        all(isfinite, sg) && all(isfinite, kr) && all(isfinite, pc) ||
            error("Drainage SGOF region $region contains non-finite values.")
        sg[1] == 0.0 && all(diff(sg) .> 0) ||
            error("Drainage SGOF region $region has invalid Sg nodes.")
        all(pc .>= 0) && all(diff(pc) .>= 0) ||
            error("Drainage SGOF region $region has invalid Pc.")
        row = entry_rows[region]
        2 <= row <= length(pc) ||
            error("Drainage SGOF region $region has an invalid entry row.")
        all(pc[1:row] .== pc[row]) ||
            error("Drainage SGOF region $region lacks the required plateau.")
        isapprox(pc[row], entry_pressure[region]; rtol = 0, atol = 0) ||
            error("Drainage SGOF region $region entry pressure disagrees with metadata.")
        maximum_piecewise_slope = max(
            maximum_piecewise_slope,
            maximum(diff(pc)./diff(sg))
        )
    end

    for region in (EXPECTED_BASE_REGIONS + 1):EXPECTED_DRAINAGE_REGIONS
        drainage = sgof[region]
        imbibition = sgof[EXPECTED_DRAINAGE_REGIONS + region]
        drainage == imbibition ||
            error("Explicit PREDICT region $region is not drainage-equivalent.")
    end
    return (maximum_piecewise_pc_slope_pa_per_sg = maximum_piecewise_slope,)
end

function validate_younger_tensor(perm, poro, satnum)
    younger = findall(==(5), satnum)
    length(younger) == EXPECTED_YOUNGER_NONPREDICT_CELLS || error(
        "Non-PREDICT Younger region has $(length(younger)) cells; expected " *
        "$EXPECTED_YOUNGER_NONPREDICT_CELLS."
    )
    younger_poro = poro[younger]
    isapprox(minimum(younger_poro), EXPECTED_YOUNGER_POROSITY_MIN;
        rtol = 0, atol = 1.0e-10) ||
        error("Non-PREDICT Younger minimum porosity changed.")
    isapprox(median(younger_poro), EXPECTED_YOUNGER_POROSITY_MEDIAN;
        rtol = 0, atol = 1.0e-10) ||
        error("Non-PREDICT Younger median porosity changed.")
    isapprox(maximum(younger_poro), EXPECTED_YOUNGER_POROSITY_MAX;
        rtol = 0, atol = 1.0e-10) ||
        error("Non-PREDICT Younger maximum porosity changed.")

    expected_principal = MILLI_DARCY_M2 .* [50.0, 500.0, 500.0]
    component_atol = 1.0e-10*MILLI_DARCY_M2
    minimum_eigenvalue = Inf
    maximum_eigenvalue = -Inf
    for cell in younger
        tensor = Symmetric([
            perm[cell, 1] perm[cell, 2] perm[cell, 3]
            perm[cell, 2] perm[cell, 4] perm[cell, 5]
            perm[cell, 3] perm[cell, 5] perm[cell, 6]
        ])
        values = eigvals(tensor)
        all(isapprox.(values, expected_principal;
            rtol = 1.0e-6, atol = component_atol)) ||
            error("Non-PREDICT Younger cell $cell changed permeability.")
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
    metadata = get(mrst, "metadata", nothing)
    isnothing(metadata) &&
        error("Assembled input is missing common physics metadata.")
    get(metadata, "physics_profile", "") == PHYSICS_PROFILE ||
        error("Assembled input has the wrong physics profile.")
    Int(round(scalar_value(metadata[
        "shared_drainage_saturation_region_count"
    ]))) == EXPECTED_BASE_REGIONS ||
        error("Unexpected shared/base MRST saturation-region count.")
    Int(round(scalar_value(metadata[
        "mrst_drainage_saturation_region_count"
    ]))) == EXPECTED_MRST_DRAINAGE_REGIONS ||
        error("Unexpected source MRST drainage-region count.")
    Int(round(scalar_value(metadata[
        "mrst_total_sgof_table_count"
    ]))) == EXPECTED_MRST_TOTAL_SGOF_TABLES ||
        error("Unexpected source MRST SGOF table count.")
    valid_sha256(get(metadata, "sand_reference_deck_sha256", "")) ||
        error("Invalid sand-reference deck digest.")
    valid_sha256(get(metadata, "fixed_sgr_file_sha256", "")) ||
        error("Invalid fixed-SGR asset digest.")
    get(metadata, "fixed_sgr_asset_contract", "") == "youngerkxx50_v1" ||
        error("Unexpected fixed-SGR asset contract.")
    string(scalar_value(get(
        metadata,
        "fixed_sgr_asset_version",
        ""
    ))) == "1" || error("Unexpected fixed-SGR asset version.")
    as_int_vector(metadata["predict_drainage_saturation_regions"]) ==
        collect(9:14) ||
        error("Unexpected common PREDICT drainage-region metadata.")
    mapping = validate_pc_mapping_metadata(metadata)

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
    isapprox(Float64(props["EHYSTR"][12]), EXPECTED_HYSTERESIS_S_MIN;
        rtol = 0, atol = eps(Float64)) ||
        error("Unexpected hysteresis S_min.")
    length(poro) == EXPECTED_CELLS || error("Porosity has the wrong length.")
    size(perm) == (EXPECTED_CELLS, 6) ||
        error("Permeability tensor has the wrong shape.")
    all(isfinite, poro) && all(value -> 0 < value < 1, poro) ||
        error("Porosity is invalid.")
    all(isfinite, perm) || error("Permeability contains non-finite values.")
    sort(unique(satnum)) == collect(1:EXPECTED_DRAINAGE_REGIONS) ||
        error("Unexpected drainage saturation regions.")
    imbnum == satnum .+ EXPECTED_DRAINAGE_REGIONS ||
        error("Drainage and imbibition regions are not paired.")
    length(sgof) == EXPECTED_TOTAL_SGOF_TABLES ||
        error("Unexpected SGOF table count.")
    all(isfinite, transmissibility) && all(>(0.0), transmissibility) ||
        error("Jutul transmissibility is invalid.")

    fault_summary["base_regions"] == EXPECTED_BASE_REGIONS ||
        error("Unexpected shared/base saturation-region count.")
    fault_summary["fault_regions"] == EXPECTED_FAULT_REGIONS ||
        error("Unexpected explicit PREDICT saturation-region count.")
    fault_summary["drainage_regions"] == EXPECTED_DRAINAGE_REGIONS ||
        error("Unexpected total drainage saturation-region count.")
    fault_summary["sgof_tables"] == EXPECTED_TOTAL_SGOF_TABLES ||
        error("Unexpected total SGOF table count.")
    fault_summary["hysteresis"] ==
        "reservoir_only_fault_drainage_duplicate" ||
        error("Explicit PREDICT regions are not drainage-equivalent.")

    pc_summary["treatment"] == PC_ENTRY_TREATMENT ||
        error("Domain-wide Pc plateau treatment is not active.")
    pc_summary["scope"] == PC_ENTRY_SCOPE ||
        error("Domain-wide Pc plateau has the wrong scope.")
    pc_summary["entry_rule"] == PC_ENTRY_RULE ||
        error("Domain-wide Pc plateau has the wrong entry rule.")
    for (key, expected) in (
            "active_tables" => EXPECTED_DRAINAGE_REGIONS,
            "nonzero_entry_tables" => EXPECTED_DRAINAGE_REGIONS,
            "adjusted_tables" => EXPECTED_DRAINAGE_REGIONS,
            "already_plateaued_tables" => 0,
            "true_zero_pc_tables" => 0,
            "skipped_tables" => 0,
            "mirrored_explicit_hysteresis_tables" => EXPECTED_FAULT_REGIONS,
            "drainage_region_count" => EXPECTED_DRAINAGE_REGIONS
        )
        pc_summary[key] == expected ||
            error("Pc plateau summary $key=$(pc_summary[key]); expected $expected.")
    end
    isempty(pc_summary["true_zero_pc_regions"]) ||
        error("This profile must not contain a true zero-Pc active table.")
    for key in (
            "input_drainage_sha256",
            "output_drainage_sha256",
            "kr_sha256_before",
            "kr_sha256_after",
            "pc_tail_sha256_before",
            "pc_tail_sha256_after",
            "base_imbibition_sha256_before",
            "base_imbibition_sha256_after"
        )
        valid_sha256(pc_summary[key]) ||
            error("Pc plateau summary has invalid $key.")
    end
    pc_summary["input_drainage_sha256"] !=
        pc_summary["output_drainage_sha256"] ||
        error("Global Pc plateau did not change the drainage-table digest.")
    pc_summary["kr_sha256_before"] == pc_summary["kr_sha256_after"] &&
        pc_summary["kr_unchanged"] === true ||
        error("Global Pc plateau changed Sg or Kr.")
    pc_summary["pc_tail_sha256_before"] ==
        pc_summary["pc_tail_sha256_after"] &&
        pc_summary["pc_at_and_above_entry_unchanged"] === true ||
        error("Global Pc plateau changed Pc at or above entry.")
    pc_summary["base_imbibition_sha256_before"] ==
        pc_summary["base_imbibition_sha256_after"] &&
        pc_summary["base_imbibition_unchanged"] === true ||
        error("Global Pc plateau changed base imbibition tables.")

    pc_tables = validate_pc_plateau_tables(sgof, pc_summary)
    younger = validate_younger_tensor(perm, poro, satnum)

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
        issubset(
            REQUIRED_QOI_INTERFACES,
            Set(interface.id for interface in interfaces)
        ) || error("One or more required QoI interfaces is missing.")
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
        pc_tables = pc_tables,
        pc_mapping = mapping,
        younger = younger,
        qoi = qoi_diagnostics
    )
end

end
