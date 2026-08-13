"""
    validate_mrst_combined_specific_identity(common, specific)

Validate the provenance and downstream data contract before a geology-specific
MRST input is applied to the common reservoir model. Historical v3 files retain
their original identity checks. Coordinate-audited v4 files receive strict
validation of geology pairing, units, permeability rotation, 6 by 87 coverage,
Pc/Kr endpoints and regions, and stratigraphy pairing.
"""
function validate_mrst_combined_specific_identity(common, specific)
    schema = haskey(specific, "schema") ?
        mrst_contract_string(specific["schema"], "specific.schema") : ""
    schema in ("gom_jutul_split_specific_v3", "gom_jutul_split_specific_v4") ||
        return nothing

    mrst_contract_require(specific, (
        "common_name", "geology_id", "geology_hash",
        "geology_hash_algorithm", "pairing_key", "fault", "stratigraphy"
    ), "Combined geology-specific file")
    if haskey(common, "name")
        mrst_contract_string(specific["common_name"], "specific.common_name") ==
            mrst_contract_string(common["name"], "common.name") || error(
            "Combined specific common_name does not match common.name."
        )
    end

    geology_id = mrst_contract_string(specific["geology_id"], "geology_id")
    geology_hash = lowercase(mrst_contract_string(
        specific["geology_hash"], "geology_hash"
    ))
    hash_algorithm = lowercase(mrst_contract_string(
        specific["geology_hash_algorithm"], "geology_hash_algorithm"
    ))
    pairing_key = mrst_contract_string(specific["pairing_key"], "pairing_key")
    startswith(hash_algorithm, "sha-256") || error(
        "Combined specific geology_hash_algorithm must use SHA-256."
    )
    pairing_key == "$geology_id:$geology_hash" || error(
        "Combined specific pairing_key is inconsistent with geology_id and geology_hash."
    )
    mrst_contract_is_sha256(geology_hash) || error(
        "Combined specific geology_hash is not a SHA-256 hexadecimal value."
    )

    if schema == "gom_jutul_split_specific_v4"
        return validate_mrst_downstream_contract(common, specific)
    end
    return nothing
end

"""
    validate_mrst_downstream_contract(common, specific)

Independently validate a `gom_jutul_split_specific_v4` input. The returned
dictionary is a compact audit summary; validation failures throw before any
reservoir arrays are modified.
"""
function validate_mrst_downstream_contract(common, specific)
    schema = mrst_contract_string(specific["schema"], "specific.schema")
    schema == "gom_jutul_split_specific_v4" || error(
        "Strict downstream validation requires gom_jutul_split_specific_v4."
    )
    common_contract = mrst_validate_common_downstream_contract(common)
    identity = mrst_validate_geology_pairing(specific)
    permeability = mrst_validate_fault_permeability_contract(specific["fault"])
    coverage = mrst_validate_window_slice_contract(specific)
    saturation = mrst_validate_saturation_contract(specific)
    stratigraphy = mrst_validate_stratigraphy_contract(
        specific["stratigraphy"], identity
    )
    sort(mrst_get_vec(specific["fault"]["cells"])) ==
        sort(mrst_get_vec(common["masks"]["specificFaultCells"])) || error(
        "Specific fault cells do not match the common specific-fault mask."
    )
    sort(mrst_get_vec(specific["stratigraphy"]["cells"])) ==
        sort(mrst_get_vec(common["masks"]["specificStratigraphyCells"])) || error(
        "Specific stratigraphy cells do not match the common stratigraphy mask."
    )
    isempty(intersect(
        mrst_get_vec(specific["fault"]["cells"]),
        mrst_get_vec(specific["stratigraphy"]["cells"])
    )) || error("Fault and stratigraphy cell sets must be disjoint.")
    mrst_validate_declared_downstream_contract(
        specific["downstream_contract"], permeability, coverage,
        common_contract
    )

    return Dict{String, Any}(
        "schema" => "gom_downstream_reservoir_input_validation_v1",
        "passed" => true,
        "geology_id" => identity["geology_id"],
        "geology_hash" => identity["geology_hash"],
        "common_schema" => common_contract["common_schema"],
        "shared_fault_cell_count" => common_contract["shared_fault_cell_count"],
        "shared_fault_footprint_count" =>
            common_contract["shared_fault_footprint_count"],
        "common_max_relative_permeability_transform_error" =>
            common_contract["max_relative_transform_error"],
        "fault_cell_count" => permeability["cell_count"],
        "stratigraphy_cell_count" => stratigraphy["cell_count"],
        "window_count" => coverage["window_count"],
        "slice_count" => coverage["slice_count"],
        "saturation_region_count" => saturation["region_count"],
        "max_relative_permeability_transform_error" =>
            permeability["max_relative_transform_error"],
        "max_down_dip_axis_alignment_error_degrees" =>
            permeability["max_axis_alignment_error_degrees"],
        "pc_kr_endpoint_max_error" => saturation["max_endpoint_error"],
        "effective_swi_max_error" => saturation["max_effective_swi_error"]
    )
end

function mrst_validate_common_downstream_contract(common)
    mrst_contract_require(common, (
        "schema", "name", "G", "rock", "masks",
        "rock_permeability_units", "rock_permeability_component_order",
        "shared_fault_permeability", "downstream_contract"
    ), "Common v2 input")
    common_schema = mrst_contract_string(common["schema"], "common.schema")
    common_schema == "gom_jutul_split_common_v2" || error(
        "A v4 specific input requires gom_jutul_split_common_v2."
    )
    mrst_contract_string(
        common["rock_permeability_units"], "common.rock_permeability_units"
    ) == "m^2" || error("Common rock permeability units must be m^2.")
    mrst_contract_strings(common["rock_permeability_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Common rock permeability component order is invalid."
    )

    grid = common["G"]
    mrst_contract_require(grid, ("cells", "layerSize"), "common.G")
    mrst_contract_require(grid["cells"], ("num",), "common.G.cells")
    nc = Int(round(mrst_contract_scalar(grid["cells"]["num"], "common.G.cells.num")))
    layer_size = Int(round(mrst_contract_scalar(grid["layerSize"], "common.G.layerSize")))
    nc > 0 && layer_size > 0 && nc % layer_size == 0 || error(
        "Common grid size/layerSize contract is invalid."
    )
    slice_count = nc ÷ layer_size

    rock = common["rock"]
    mrst_contract_require(rock, ("poro", "perm"), "common.rock")
    length(mrst_get_vec(rock["poro"])) == nc || error(
        "common.rock.poro does not match the grid cell count."
    )
    rock["perm"] isa AbstractMatrix && size(rock["perm"]) == (nc, 6) || error(
        "common.rock.perm must have grid-cell by 6 size."
    )

    masks = common["masks"]
    mrst_contract_require(masks, (
        "fault_all_cells", "specificFaultCells", "specificStratigraphyCells",
        "specificGeologyCells", "fixedSharedFaultCells"
    ), "common.masks")
    function mask_cells(key, require_nonempty = true)
        cells = mrst_contract_positive_integer_vector(
            masks[key], "common.masks.$key"
        )
        require_nonempty && isempty(cells) && error("common.masks.$key is empty.")
        length(unique(cells)) == length(cells) || error(
            "common.masks.$key contains duplicate cells."
        )
        all(<=(nc), cells) || error("common.masks.$key exceeds the grid size.")
        return cells
    end
    fault_all = mask_cells("fault_all_cells")
    specific_fault = mask_cells("specificFaultCells")
    specific_stratigraphy = mask_cells("specificStratigraphyCells", false)
    specific_geology = mask_cells("specificGeologyCells")
    shared_cells = mask_cells("fixedSharedFaultCells")
    isempty(intersect(specific_fault, shared_cells)) || error(
        "Specific and shared fault masks overlap."
    )
    sort(vcat(specific_fault, shared_cells)) == sort(fault_all) || error(
        "Specific and shared fault masks do not form the complete fault mask."
    )
    isempty(intersect(specific_fault, specific_stratigraphy)) || error(
        "Specific fault and stratigraphy masks overlap."
    )
    sort(unique(vcat(specific_fault, specific_stratigraphy))) ==
        sort(specific_geology) || error(
        "specificGeologyCells is inconsistent with its component masks."
    )
    poro = mrst_get_vec(rock["poro"])
    all(isnan, poro[specific_geology]) || error(
        "Geology-specific common porosity entries must be NaN before import."
    )
    all(isnan, rock["perm"][specific_geology, :]) || error(
        "Geology-specific common permeability entries must be NaN before import."
    )

    shared = common["shared_fault_permeability"]
    mrst_contract_require(shared, (
        "schema", "cell_source", "cell_count", "template_footprint_count",
        "current_grid_layer_size", "current_slice_count",
        "template_footprint_ids", "template_local_perm_m2",
        "local_perm_units", "local_perm_component_order",
        "local_perm_axis_meaning", "global_perm_units",
        "global_perm_component_order", "template_dip_degrees",
        "template_rotation_angle_degrees", "permeability_coordinate_transform"
    ), "common.shared_fault_permeability")
    shared_schema = mrst_contract_string(shared["schema"], "shared.schema")
    shared_schema == "gom_shared_fault_permeability_v1" || error(
        "Unsupported shared-fault permeability schema."
    )
    mrst_contract_string(shared["cell_source"], "shared.cell_source") ==
        "common.masks.fixedSharedFaultCells" || error(
        "Shared-fault cell source is invalid."
    )
    Int(round(mrst_contract_scalar(shared["cell_count"], "shared.cell_count"))) ==
        length(shared_cells) || error("Shared-fault cell count is inconsistent.")
    Int(round(mrst_contract_scalar(
        shared["current_grid_layer_size"], "shared.current_grid_layer_size"
    ))) == layer_size || error("Shared-fault layer size is inconsistent.")
    Int(round(mrst_contract_scalar(
        shared["current_slice_count"], "shared.current_slice_count"
    ))) == slice_count || error("Shared-fault slice count is inconsistent.")
    mrst_contract_string(shared["local_perm_units"], "shared.local_perm_units") ==
        "m^2" || error("Shared local permeability units must be m^2.")
    mrst_contract_string(shared["global_perm_units"], "shared.global_perm_units") ==
        "m^2" || error("Shared global permeability units must be m^2.")
    mrst_contract_strings(shared["local_perm_component_order"]) ==
        ["kxx", "kyy", "kzz"] || error(
        "Shared local permeability component order is invalid."
    )
    mrst_contract_strings(shared["local_perm_axis_meaning"]) ==
        ["fault_normal", "along_strike", "down_dip"] || error(
        "Shared local permeability axes are invalid."
    )
    mrst_contract_strings(shared["global_perm_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Shared global permeability component order is invalid."
    )

    footprints = mrst_contract_positive_integer_vector(
        shared["template_footprint_ids"], "shared.template_footprint_ids"
    )
    nt = length(footprints)
    nt == Int(round(mrst_contract_scalar(
        shared["template_footprint_count"], "shared.template_footprint_count"
    ))) && nt > 0 || error("Shared template footprint count is inconsistent.")
    length(unique(footprints)) == nt && all(<=(layer_size), footprints) || error(
        "Shared template footprint IDs are invalid."
    )
    local_perm = mrst_contract_matrix(
        shared["template_local_perm_m2"], nt, 3, "shared.template_local_perm_m2"
    )
    all(>(0), local_perm) || error("Shared local permeability must be positive.")
    dip = mrst_contract_numeric_vector(
        shared["template_dip_degrees"], nt, "shared.template_dip_degrees"
    )
    theta = mrst_contract_numeric_vector(
        shared["template_rotation_angle_degrees"], nt,
        "shared.template_rotation_angle_degrees"
    )
    all(x -> 0 < x <= 90, dip) || error("Shared fault dip is invalid.")

    lookup = Dict(id => i for (i, id) in enumerate(footprints))
    template_position = Vector{Int}(undef, length(shared_cells))
    counts = zeros(Int, nt)
    for i in eachindex(shared_cells)
        footprint = mod(shared_cells[i] - 1, layer_size) + 1
        haskey(lookup, footprint) || error(
            "A shared fault cell has no template footprint."
        )
        position = lookup[footprint]
        template_position[i] = position
        counts[position] += 1
    end
    sort(unique(mod.(shared_cells .- 1, layer_size) .+ 1)) == sort(footprints) ||
        error("Shared-fault cells and templates do not have exact coverage.")
    all(==(slice_count), counts) || error(
        "Each shared-fault footprint must occur once per along-strike slice."
    )

    transform = shared["permeability_coordinate_transform"]
    mrst_contract_require(transform, (
        "schema", "fault_trace_y_direction_sign", "input_units",
        "output_units", "validation"
    ), "shared permeability coordinate transform")
    transform_schema = mrst_contract_string(transform["schema"], "transform.schema")
    transform_schema == "gom_fault_permeability_coordinate_transform_v1" || error(
        "Unsupported shared permeability coordinate transform."
    )
    mrst_contract_string(transform["input_units"], "transform.input_units") ==
        "m^2" && mrst_contract_string(
        transform["output_units"], "transform.output_units"
    ) == "m^2" || error("Shared coordinate-transform units must be m^2.")
    direction_sign = Int(round(mrst_contract_scalar(
        transform["fault_trace_y_direction_sign"],
        "transform.fault_trace_y_direction_sign"
    )))
    direction_sign in (-1, 1) || error("Fault trace direction sign is invalid.")
    theta_error = maximum(abs.(theta .- direction_sign .* (dip .- 90)))
    theta_error <= 1e-10 || error(
        "Shared-fault rotation angles are inconsistent with dip."
    )

    c = cosd.(theta)
    s = sind.(theta)
    template_global = zeros(Float64, nt, 6)
    template_global[:, 1] .= local_perm[:, 2]
    template_global[:, 4] .= c.^2 .* local_perm[:, 1] .+
        s.^2 .* local_perm[:, 3]
    template_global[:, 5] .= c .* s .* (local_perm[:, 1] .- local_perm[:, 3])
    template_global[:, 6] .= s.^2 .* local_perm[:, 1] .+
        c.^2 .* local_perm[:, 3]
    expected = template_global[template_position, :]
    actual = Float64.(rock["perm"][shared_cells, :])
    all(isfinite, actual) || error("Common shared-fault permeability is nonfinite.")
    transform_error = mrst_contract_relative_error(actual, expected)
    transform_error <= 5e-12 || error(
        "Common shared-fault permeability violates the signed coordinate transform."
    )
    mrst_contract_assert_positive_definite(actual, "common shared-fault permeability")

    down_dip_y = -sind.(theta)
    down_dip_z = cosd.(theta)
    tangent_y = direction_sign .* cosd.(dip)
    tangent_z = sind.(dip)
    alignment = clamp.(down_dip_y .* tangent_y .+ down_dip_z .* tangent_z, -1, 1)
    alignment_error = maximum(acosd.(abs.(alignment)))
    alignment_vector_error = maximum(sqrt.(
        (down_dip_y .- tangent_y).^2 .+ (down_dip_z .- tangent_z).^2
    ))
    alignment_vector_error <= 5e-12 || error(
        "Shared-fault down-dip axis is not aligned with the fault trace."
    )
    validation = transform["validation"]
    mrst_contract_require(validation, ("passed",), "transform.validation")
    Bool(round(Int, mrst_contract_scalar(
        validation["passed"], "transform.validation.passed"
    ))) || error("Exporter shared-fault transform validation did not pass.")

    contract = common["downstream_contract"]
    mrst_contract_require(contract, (
        "schema", "common_schema", "required_specific_schema",
        "shared_fault_schema", "permeability_coordinate_transform_schema",
        "permeability_units", "reservoir_grid_component_order"
    ), "common.downstream_contract")
    mrst_contract_string(contract["schema"], "common contract schema") ==
        "gom_downstream_common_input_contract_v1" || error(
        "Unsupported common downstream contract."
    )
    mrst_contract_string(contract["common_schema"], "common contract schema") ==
        common_schema || error("Common downstream schema is inconsistent.")
    mrst_contract_string(
        contract["required_specific_schema"], "required specific schema"
    ) == "gom_jutul_split_specific_v4" || error(
        "Common downstream contract does not require v4 specific inputs."
    )
    mrst_contract_string(contract["shared_fault_schema"], "shared fault schema") ==
        shared_schema || error("Common shared-fault schema is inconsistent.")
    mrst_contract_string(
        contract["permeability_coordinate_transform_schema"],
        "common transform schema"
    ) == transform_schema || error("Common transform schema is inconsistent.")
    mrst_contract_string(contract["permeability_units"], "common permeability units") ==
        "m^2" || error("Common downstream permeability units must be m^2.")
    mrst_contract_strings(contract["reservoir_grid_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Common downstream component order is invalid."
    )

    return Dict(
        "common_schema" => common_schema,
        "cell_count" => nc,
        "slice_count" => slice_count,
        "shared_fault_cell_count" => length(shared_cells),
        "shared_fault_footprint_count" => nt,
        "max_relative_transform_error" => transform_error,
        "max_axis_alignment_error_degrees" => alignment_error,
        "max_rotation_angle_error_degrees" => theta_error
    )
end

function mrst_validate_geology_pairing(specific)
    mrst_contract_require(specific, (
        "geology_id", "geology_hash_algorithm", "geology_hash", "pairing_key",
        "geology_link", "component_schemas", "metadata", "fault", "stratigraphy"
    ), "Combined v4 input")
    geology_id = mrst_contract_string(specific["geology_id"], "geology_id")
    algorithm = lowercase(mrst_contract_string(
        specific["geology_hash_algorithm"], "geology_hash_algorithm"
    ))
    geology_hash = lowercase(mrst_contract_string(
        specific["geology_hash"], "geology_hash"
    ))
    pairing_key = mrst_contract_string(specific["pairing_key"], "pairing_key")
    startswith(algorithm, "sha-256") || error(
        "The geology hash algorithm must use SHA-256."
    )
    mrst_contract_is_sha256(geology_hash) || error(
        "geology_hash must be a 64-character lowercase SHA-256 value."
    )
    pairing_key == "$geology_id:$geology_hash" || error(
        "pairing_key is inconsistent with geology_id and geology_hash."
    )

    link = specific["geology_link"]
    mrst_contract_require(link, (
        "schema", "geology_id", "geology_hash_algorithm", "geology_hash",
        "pairing_key", "stratigraphy_file", "fault_schema", "stratigraphy_schema",
        "source_link_schema"
    ), "geology_link")
    link_schema = mrst_contract_string(link["schema"], "geology_link.schema")
    link_schema in ("gom_geology_pairing_v1", "gom_geology_pairing_v2") ||
        error("Unsupported geology_link schema.")
    source_link_schema = mrst_contract_string(
        link["source_link_schema"], "geology_link.source_link_schema"
    )
    if link_schema == "gom_geology_pairing_v2"
        mrst_contract_require(link, ("authority",), "manifest-backed geology_link")
        source_link_schema in (
            "gom_step62_1620_input_manifest_v1",
            "gom_step62_phase1_2430_input_manifest_v1",
        ) || error(
            "Manifest-backed geology_link has an unsupported source schema."
        )
        mrst_contract_string(link["authority"], "geology_link.authority") ==
            "validated_immutable_input_manifest" || error(
            "Manifest-backed geology_link has an invalid authority."
        )
    else
        isempty(source_link_schema) && error(
            "Embedded geology_link source schema must be nonempty."
        )
    end
    isempty(mrst_contract_string(
        link["stratigraphy_file"], "geology_link.stratigraphy_file"
    )) && error("geology_link.stratigraphy_file must be nonempty.")

    metadata = specific["metadata"]
    mrst_contract_require(metadata, (
        "reservoir_ready_file", "stratigraphy_file", "geology_id",
        "geology_hash_algorithm", "geology_hash", "pairing_key"
    ), "metadata")
    isempty(mrst_contract_string(
        metadata["reservoir_ready_file"], "metadata.reservoir_ready_file"
    )) && error("metadata.reservoir_ready_file must identify the fault source.")
    mrst_contract_string(metadata["stratigraphy_file"], "metadata.stratigraphy_file") ==
        mrst_contract_string(link["stratigraphy_file"], "geology_link.stratigraphy_file") ||
        error("Metadata and geology_link identify different stratigraphy files.")
    mrst_contract_string(metadata["geology_id"], "metadata.geology_id") == geology_id ||
        error("Metadata geology_id does not match the combined input.")
    lowercase(mrst_contract_string(
        metadata["geology_hash_algorithm"], "metadata.geology_hash_algorithm"
    )) == algorithm || error("Metadata hash algorithm does not match the combined input.")
    lowercase(mrst_contract_string(
        metadata["geology_hash"], "metadata.geology_hash"
    )) == geology_hash || error("Metadata geology_hash does not match the combined input.")
    mrst_contract_string(metadata["pairing_key"], "metadata.pairing_key") == pairing_key ||
        error("Metadata pairing_key does not match the combined input.")

    for (label, block) in (
            ("geology_link", link),
            ("fault", specific["fault"]),
            ("stratigraphy", specific["stratigraphy"])
        )
        mrst_contract_require(block, (
            "geology_id", "geology_hash_algorithm", "geology_hash", "pairing_key"
        ), label)
        mrst_contract_string(block["geology_id"], "$label.geology_id") == geology_id ||
            error("$label geology_id does not match the combined input.")
        lowercase(mrst_contract_string(
            block["geology_hash_algorithm"], "$label.geology_hash_algorithm"
        )) == algorithm || error(
            "$label geology_hash_algorithm does not match the combined input."
        )
        lowercase(mrst_contract_string(
            block["geology_hash"], "$label.geology_hash"
        )) == geology_hash || error(
            "$label geology_hash does not match the combined input."
        )
        mrst_contract_string(block["pairing_key"], "$label.pairing_key") ==
            pairing_key || error(
            "$label pairing_key does not match the combined input."
        )
    end

    schemas = specific["component_schemas"]
    mrst_contract_require(schemas, ("fault", "stratigraphy"), "component_schemas")
    mrst_contract_string(schemas["fault"], "component_schemas.fault") ==
        "gom_jutul_split_specific_v3" || error(
        "Fault component is not the coordinate-audited v3 schema."
    )
    mrst_contract_string(schemas["stratigraphy"], "component_schemas.stratigraphy") ==
        "gom_jutul_stratigraphy_specific_v1" || error(
        "Stratigraphy component schema is invalid."
    )

    return Dict(
        "geology_id" => geology_id,
        "geology_hash_algorithm" => algorithm,
        "geology_hash" => geology_hash,
        "pairing_key" => pairing_key
    )
end

function mrst_validate_fault_permeability_contract(fault)
    mrst_contract_require(fault, (
        "cells", "poro", "perm", "perm_units", "perm_component_order",
        "local_perm_m2", "local_perm_md", "local_perm_m2_units",
        "local_perm_md_units", "local_perm_component_order", "dip",
        "rotation_angle_degrees", "permeability_coordinate_transform"
    ), "fault")
    cells = mrst_contract_positive_integer_vector(fault["cells"], "fault.cells")
    length(unique(cells)) == length(cells) || error("fault.cells must be unique.")
    n = length(cells)
    mrst_contract_string(fault["perm_units"], "fault.perm_units") == "m^2" ||
        error("fault.perm_units must be m^2.")
    mrst_contract_string(
        fault["local_perm_m2_units"], "fault.local_perm_m2_units"
    ) == "m^2" || error("fault.local_perm_m2_units must be m^2.")
    mrst_contract_string(
        fault["local_perm_md_units"], "fault.local_perm_md_units"
    ) == "mD" || error("fault.local_perm_md_units must be mD.")
    mrst_contract_strings(fault["perm_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Global permeability component order is invalid."
    )
    lowercase.(mrst_contract_strings(fault["local_perm_component_order"])) ==
        ["kxx", "kyy", "kzz"] || error(
        "Local permeability component order is invalid."
    )

    global_perm = mrst_contract_matrix(fault["perm"], n, 6, "fault.perm")
    local_m2 = mrst_contract_matrix(
        fault["local_perm_m2"], n, 3, "fault.local_perm_m2"
    )
    local_md = mrst_contract_matrix(
        fault["local_perm_md"], n, 3, "fault.local_perm_md"
    )
    all(>(0), local_m2) || error("fault.local_perm_m2 must be positive.")
    unit_error = mrst_contract_relative_error(local_m2, local_md .* 9.869233e-16)
    unit_error <= 1e-12 || error(
        "fault.local_perm_m2 and fault.local_perm_md are inconsistent."
    )

    dip = mrst_contract_numeric_vector(fault["dip"], n, "fault.dip")
    theta = mrst_contract_numeric_vector(
        fault["rotation_angle_degrees"], n, "fault.rotation_angle_degrees"
    )
    all(x -> 0 < x <= 90, dip) || error("fault.dip must be in (0, 90].")
    transform = fault["permeability_coordinate_transform"]
    mrst_contract_require(transform, (
        "schema", "source_component_order", "source_axis_meaning",
        "target_component_order", "global_x_alignment",
        "fault_trace_y_direction_sign", "rotation_angle_definition",
        "input_units", "output_units", "validation"
    ), "fault.permeability_coordinate_transform")
    transform_schema = mrst_contract_string(transform["schema"], "transform.schema")
    transform_schema == "gom_fault_permeability_coordinate_transform_v1" ||
        error("Unsupported permeability coordinate-transform schema.")
    mrst_contract_strings(transform["source_component_order"]) ==
        ["kxx", "kyy", "kzz"] || error("Transform source order is invalid.")
    mrst_contract_strings(transform["source_axis_meaning"]) ==
        ["fault_normal", "along_strike", "down_dip"] || error(
        "Transform source-axis meanings are invalid."
    )
    mrst_contract_strings(transform["target_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Transform target order is invalid."
    )
    mrst_contract_string(transform["input_units"], "transform.input_units") ==
        "m^2" || error("Transform input units must be m^2.")
    mrst_contract_string(transform["output_units"], "transform.output_units") ==
        "m^2" || error("Transform output units must be m^2.")
    direction_sign = Int(round(mrst_contract_scalar(
        transform["fault_trace_y_direction_sign"], "fault_trace_y_direction_sign"
    )))
    direction_sign in (-1, 1) || error(
        "fault_trace_y_direction_sign must be -1 or +1."
    )
    theta_expected = direction_sign .* (dip .- 90.0)
    theta_error = maximum(abs.(theta .- theta_expected))
    theta_error <= 1e-10 || error(
        "Stored rotation angles are inconsistent with dip and trace direction."
    )

    c = cosd.(theta)
    s = sind.(theta)
    expected = zeros(Float64, n, 6)
    expected[:, 1] .= local_m2[:, 2]
    expected[:, 4] .= c.^2 .* local_m2[:, 1] .+ s.^2 .* local_m2[:, 3]
    expected[:, 5] .= c .* s .* (local_m2[:, 1] .- local_m2[:, 3])
    expected[:, 6] .= s.^2 .* local_m2[:, 1] .+ c.^2 .* local_m2[:, 3]
    transform_error = mrst_contract_relative_error(global_perm, expected)
    transform_error <= 5e-12 || error(
        "Global fault permeability does not match the declared local-to-grid transform."
    )
    mrst_contract_assert_positive_definite(global_perm, "fault.perm")

    down_dip_y = -sind.(theta)
    down_dip_z = cosd.(theta)
    tangent_y = direction_sign .* cosd.(dip)
    tangent_z = sind.(dip)
    alignment = clamp.(down_dip_y .* tangent_y .+ down_dip_z .* tangent_z, -1, 1)
    alignment_error = maximum(acosd.(abs.(alignment)))
    alignment_vector_error = maximum(sqrt.(
        (down_dip_y .- tangent_y).^2 .+ (down_dip_z .- tangent_z).^2
    ))
    alignment_vector_error <= 5e-12 || error(
        "The transformed kzz axis is not aligned with the fault trace."
    )

    validation = transform["validation"]
    mrst_contract_require(validation, ("passed",), "transform.validation")
    Bool(round(Int, mrst_contract_scalar(
        validation["passed"], "transform.validation.passed"
    ))) || error("Exporter permeability-transform validation did not pass.")

    return Dict(
        "cell_count" => n,
        "transform_schema" => transform_schema,
        "max_relative_transform_error" => transform_error,
        "max_axis_alignment_error_degrees" => alignment_error,
        "max_axis_alignment_vector_error" => alignment_vector_error,
        "max_rotation_angle_error_degrees" => theta_error,
        "max_relative_unit_error" => unit_error
    )
end

function mrst_validate_window_slice_contract(specific)
    fault = specific["fault"]
    ws = specific["window_slice"]
    mrst_contract_require(ws, (
        "dimension_order", "window_names", "window_unit_ids", "slice_indices",
        "saturation_region", "local_saturation_region", "poro",
        "local_perm_md", "local_perm_m2", "selected_sample_index",
        "exact_replay_seed"
    ), "window_slice")
    mrst_contract_string(ws["dimension_order"], "window_slice.dimension_order") ==
        "window x slice x component" || error(
        "window_slice.dimension_order is invalid."
    )
    window_names = mrst_contract_strings(ws["window_names"])
    window_names == ["famp$i" for i in 1:6] || error(
        "The v4 contract requires ordered windows famp1 through famp6."
    )
    slice_indices = mrst_contract_positive_integer_vector(
        ws["slice_indices"], "window_slice.slice_indices"
    )
    slice_indices == collect(1:87) || error(
        "The v4 contract requires ordered slices 1 through 87."
    )
    size(ws["poro"]) == (6, 87) || error(
        "window_slice.poro must have 6 by 87 coverage."
    )
    size(ws["local_perm_m2"]) == (6, 87, 3) || error(
        "window_slice.local_perm_m2 must have 6 by 87 by 3 coverage."
    )
    size(ws["local_perm_md"]) == (6, 87, 3) || error(
        "window_slice.local_perm_md must have 6 by 87 by 3 coverage."
    )
    for key in ("selected_sample_index", "exact_replay_seed")
        size(ws[key]) == (6, 87) || error(
            "window_slice.$key must have 6 by 87 coverage."
        )
        all(x -> x isa Real && isfinite(x) && x > 0 && isinteger(x), ws[key]) ||
            error("window_slice.$key must contain positive integer identifiers.")
    end
    poro = Float64.(ws["poro"])
    all(x -> isfinite(x) && 0 < x < 1, poro) || error(
        "window_slice.poro must be finite and in (0, 1)."
    )
    local_m2 = Float64.(ws["local_perm_m2"])
    local_md = Float64.(ws["local_perm_md"])
    all(x -> isfinite(x) && x > 0, local_m2) || error(
        "window_slice.local_perm_m2 must be finite and positive."
    )
    mrst_contract_relative_error(local_m2, local_md .* 9.869233e-16) <= 1e-12 ||
        error("Window-slice mD and m^2 permeability arrays disagree.")
    mrst_contract_positive_integer_vector(
        ws["window_unit_ids"], "window_slice.window_unit_ids"
    ) == mrst_contract_positive_integer_vector(
        fault["window_unit_ids"], "fault.window_unit_ids"
    ) || error("Window-unit IDs disagree between window_slice and fault metadata.")

    n = length(mrst_get_vec(fault["cells"]))
    window_index = mrst_contract_positive_integer_vector(
        fault["window_index"], "fault.window_index"
    )
    slice_position = mrst_contract_positive_integer_vector(
        fault["slice_position"], "fault.slice_position"
    )
    slice_index = mrst_contract_positive_integer_vector(
        fault["slice_index"], "fault.slice_index"
    )
    all(length(v) == n for v in (window_index, slice_position, slice_index)) ||
        error("Fault window/slice vectors have invalid lengths.")
    all(x -> 1 <= x <= 6, window_index) || error(
        "fault.window_index contains invalid values."
    )
    all(x -> 1 <= x <= 87, slice_position) || error(
        "fault.slice_position contains invalid values."
    )
    slice_index == slice_indices[slice_position] || error(
        "fault.slice_index is inconsistent with window_slice.slice_indices."
    )

    counts = zeros(Int, 6, 87)
    for i in eachindex(window_index)
        counts[window_index[i], slice_position[i]] += 1
    end
    all(>(0), counts) || error(
        "At least one of the 6 by 87 window-slice assignments has no fault cells."
    )
    exported_counts = Int.(round.(fault["window_slice_cell_counts"]))
    exported_counts == counts || error(
        "fault.window_slice_cell_counts disagrees with per-cell assignments."
    )

    cell_poro = mrst_contract_numeric_vector(fault["poro"], n, "fault.poro")
    cell_local_m2 = mrst_contract_matrix(
        fault["local_perm_m2"], n, 3, "fault.local_perm_m2"
    )
    cell_local_md = mrst_contract_matrix(
        fault["local_perm_md"], n, 3, "fault.local_perm_md"
    )
    for i in 1:n
        w = window_index[i]
        s = slice_position[i]
        isapprox(cell_poro[i], poro[w, s]; rtol = 1e-12, atol = 0) || error(
            "Per-cell porosity disagrees with window_slice at cell assignment $i."
        )
        for component in 1:3
            isapprox(cell_local_m2[i, component], local_m2[w, s, component];
                rtol = 1e-12, atol = 0) || error(
                "Per-cell local m^2 permeability disagrees at assignment $i."
            )
            isapprox(cell_local_md[i, component], local_md[w, s, component];
                rtol = 1e-12, atol = 0) || error(
                "Per-cell local mD permeability disagrees at assignment $i."
            )
        end
    end

    return Dict(
        "window_count" => 6,
        "slice_count" => 87,
        "assignment_count" => 522,
        "min_cells_per_assignment" => minimum(counts),
        "max_cells_per_assignment" => maximum(counts)
    )
end

function mrst_validate_saturation_contract(specific)
    fault = specific["fault"]
    regions = specific["saturation_regions"]
    mrst_contract_require(regions, (
        "schema", "representation", "base_region_count", "region_count",
        "local_region_ids", "global_region_ids", "local_satnum",
        "global_satnum", "region_curve_linear_indices"
    ), "saturation_regions")
    mrst_contract_string(regions["schema"], "saturation_regions.schema") ==
        "gom_fault_saturation_regions_v1" || error(
        "Unsupported saturation-region schema."
    )
    local_satnum = Int.(round.(regions["local_satnum"]))
    global_satnum = Int.(round.(regions["global_satnum"]))
    size(local_satnum) == (6, 87) && size(global_satnum) == (6, 87) || error(
        "Saturation-region maps must have 6 by 87 coverage."
    )
    region_count = Int(round(mrst_contract_scalar(
        regions["region_count"], "saturation_regions.region_count"
    )))
    base_region = Int(round(mrst_contract_scalar(
        regions["base_region_count"], "saturation_regions.base_region_count"
    )))
    local_ids = mrst_contract_positive_integer_vector(
        regions["local_region_ids"], "saturation_regions.local_region_ids"
    )
    global_ids = mrst_contract_positive_integer_vector(
        regions["global_region_ids"], "saturation_regions.global_region_ids"
    )
    local_ids == collect(1:region_count) || error(
        "Local saturation-region IDs must be contiguous."
    )
    global_ids == base_region .+ local_ids || error(
        "Global saturation-region IDs are incorrectly offset."
    )
    sort(unique(vec(local_satnum))) == local_ids || error(
        "The local SATNUM map does not use every declared region."
    )
    global_satnum == base_region .+ local_satnum || error(
        "Global SATNUM is not the declared offset of local SATNUM."
    )
    Int.(round.(specific["window_slice"]["local_saturation_region"])) ==
        local_satnum || error(
        "window_slice.local_saturation_region disagrees with saturation_regions."
    )
    Int.(round.(specific["window_slice"]["saturation_region"])) ==
        global_satnum || error(
        "window_slice.saturation_region disagrees with saturation_regions."
    )
    representation = mrst_contract_string(
        regions["representation"], "saturation_regions.representation"
    )
    if representation == "full_slice"
        region_count == 522 && length(unique(vec(local_satnum))) == 522 || error(
            "Full-slice Pc/Kr requires one region per 6 by 87 assignment."
        )
    end

    window_index = mrst_contract_positive_integer_vector(
        fault["window_index"], "fault.window_index"
    )
    slice_position = mrst_contract_positive_integer_vector(
        fault["slice_position"], "fault.slice_position"
    )
    cell_local = mrst_contract_positive_integer_vector(
        fault["local_saturation_region"], "fault.local_saturation_region"
    )
    cell_global = mrst_contract_positive_integer_vector(
        fault["saturation_region"], "fault.saturation_region"
    )
    for i in eachindex(window_index)
        expected_local = local_satnum[window_index[i], slice_position[i]]
        cell_local[i] == expected_local || error(
            "Per-cell local saturation region disagrees at assignment $i."
        )
        cell_global[i] == global_satnum[window_index[i], slice_position[i]] ||
            error("Per-cell global saturation region disagrees at assignment $i.")
    end
    Int.(round.(fault["region_matrix"])) == global_satnum || error(
        "fault.region_matrix disagrees with saturation_regions.global_satnum."
    )
    mrst_contract_positive_integer_vector(
        fault["table_regions"], "fault.table_regions"
    ) == global_ids || error(
        "fault.table_regions disagrees with declared global region IDs."
    )

    sgof = fault["fluid_tables"]["SGOF"]
    mrst_contract_require(sgof, (
        "regions", "tables", "column_names", "column_units", "point_counts",
        "bulk_sg_max", "effective_swi", "local_regions",
        "source_curve_linear_indices"
    ), "fault.fluid_tables.SGOF")
    mrst_contract_strings(sgof["column_names"]) ==
        ["SGAS", "KRG", "KROG", "PCOG"] || error(
        "SGOF column order is invalid."
    )
    mrst_contract_strings(sgof["column_units"]) ==
        ["fraction", "fraction", "fraction", "Pa"] || error(
        "SGOF units are invalid."
    )
    table_regions = mrst_contract_positive_integer_vector(
        sgof["regions"], "SGOF.regions"
    )
    tables = mrst_get_vec(sgof["tables"])
    table_regions == global_ids && length(tables) == region_count || error(
        "SGOF does not provide one table per declared region."
    )
    mrst_contract_positive_integer_vector(sgof["local_regions"], "SGOF.local_regions") ==
        local_ids || error("SGOF local region IDs are inconsistent.")
    source_curve_indices = mrst_contract_positive_integer_vector(
        regions["region_curve_linear_indices"],
        "saturation_regions.region_curve_linear_indices"
    )
    length(source_curve_indices) == region_count || error(
        "Saturation-region source-curve indices have an invalid length."
    )
    mrst_contract_positive_integer_vector(
        sgof["source_curve_linear_indices"], "SGOF.source_curve_linear_indices"
    ) == source_curve_indices || error(
        "SGOF source-curve indices disagree with saturation-region metadata."
    )
    point_counts = mrst_contract_positive_integer_vector(
        sgof["point_counts"], "SGOF.point_counts"
    )
    bulk_sg_max = mrst_contract_numeric_vector(
        sgof["bulk_sg_max"], region_count, "SGOF.bulk_sg_max"
    )
    effective_swi = mrst_contract_numeric_vector(
        sgof["effective_swi"], region_count, "SGOF.effective_swi"
    )
    length(point_counts) == region_count || error(
        "SGOF point counts must contain one value per region."
    )
    all(x -> 0 < x <= 1, bulk_sg_max) || error(
        "SGOF bulk_sg_max values are outside (0, 1]."
    )
    all(x -> 0 <= x < 1, effective_swi) || error(
        "SGOF effective_swi values are outside [0, 1)."
    )

    endpoint_error = 0.0
    swi_error = 0.0
    for i in 1:region_count
        table = tables[i]
        table isa AbstractMatrix && size(table, 2) == 4 && size(table, 1) >= 2 ||
            error("SGOF table $i must be an n by 4 matrix with n >= 2.")
        values = Float64.(table)
        all(isfinite, values) || error("SGOF table $i contains nonfinite values.")
        sg = values[:, 1]
        krg = values[:, 2]
        krw = values[:, 3]
        pc = values[:, 4]
        all(diff(sg) .> 0) && 0 <= first(sg) && last(sg) <= 1 || error(
            "SGOF saturation is invalid for region $i."
        )
        all(x -> -1e-12 <= x <= 1 + 1e-12, krg) &&
            all(x -> -1e-12 <= x <= 1 + 1e-12, krw) &&
            all(diff(krg) .>= -1e-10) && all(diff(krw) .<= 1e-10) || error(
            "SGOF relative permeability is invalid for region $i."
        )
        all(pc .>= 0) && all(diff(pc) .>= -1e-5) || error(
            "SGOF capillary pressure is invalid for region $i."
        )
        point_counts[i] == size(values, 1) || error(
            "SGOF point count is incorrect for region $i."
        )
        endpoint_error = max(endpoint_error, abs(last(sg) - bulk_sg_max[i]))
        swi_error = max(swi_error, abs(effective_swi[i] - (1 - last(sg))))
    end
    endpoint_error <= 1e-10 || error(
        "SGOF bulk gas-saturation endpoints are inconsistent."
    )
    swi_error <= 1e-10 || error(
        "SGOF effective Swi values are inconsistent with curve endpoints."
    )

    return Dict(
        "region_count" => region_count,
        "table_count" => length(tables),
        "representation" => representation,
        "max_endpoint_error" => endpoint_error,
        "max_effective_swi_error" => swi_error
    )
end

function mrst_validate_stratigraphy_contract(stratigraphy, identity)
    mrst_contract_require(stratigraphy, (
        "cells", "poro", "perm", "perm_units", "perm_component_order",
        "saturation_region", "rock_region", "side_id", "stratigraphic_unit_id",
        "grid_unit_id", "facies_id", "source_window_index", "source_layer_index",
        "geology_id", "geology_hash_algorithm", "geology_hash", "pairing_key"
    ), "stratigraphy")
    mrst_contract_string(stratigraphy["geology_id"], "stratigraphy.geology_id") ==
        identity["geology_id"] || error("Stratigraphy geology_id is mismatched.")
    lowercase(mrst_contract_string(
        stratigraphy["geology_hash_algorithm"], "stratigraphy.geology_hash_algorithm"
    )) == identity["geology_hash_algorithm"] || error(
        "Stratigraphy hash algorithm is mismatched."
    )
    lowercase(mrst_contract_string(
        stratigraphy["geology_hash"], "stratigraphy.geology_hash"
    )) == identity["geology_hash"] || error("Stratigraphy hash is mismatched.")
    mrst_contract_string(stratigraphy["pairing_key"], "stratigraphy.pairing_key") ==
        identity["pairing_key"] || error("Stratigraphy pairing_key is mismatched.")
    mrst_contract_string(stratigraphy["perm_units"], "stratigraphy.perm_units") ==
        "m^2" || error("Stratigraphy permeability units must be m^2.")
    mrst_contract_strings(stratigraphy["perm_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Stratigraphy permeability component order is invalid."
    )

    cells = mrst_contract_positive_integer_vector(
        stratigraphy["cells"], "stratigraphy.cells"
    )
    length(unique(cells)) == length(cells) || error(
        "stratigraphy.cells must be unique."
    )
    n = length(cells)
    poro = mrst_contract_numeric_vector(stratigraphy["poro"], n, "stratigraphy.poro")
    all(x -> 0 < x < 1, poro) || error("Stratigraphy porosity must be in (0, 1).")
    perm = mrst_contract_matrix(stratigraphy["perm"], n, 6, "stratigraphy.perm")
    mrst_contract_assert_positive_definite(perm, "stratigraphy.perm")
    for key in (
            "saturation_region", "rock_region", "side_id", "stratigraphic_unit_id",
            "grid_unit_id", "facies_id", "source_window_index", "source_layer_index"
        )
        values = mrst_contract_numeric_vector(stratigraphy[key], n, "stratigraphy.$key")
        all(x -> x >= 0 && isinteger(x), values) || error(
            "stratigraphy.$key must contain nonnegative integer identifiers."
        )
    end
    all(x -> x in (1, 2), mrst_get_vec(stratigraphy["side_id"])) || error(
        "Stratigraphy side_id must use the declared two classes."
    )
    all(x -> x in (1, 2), mrst_get_vec(stratigraphy["facies_id"])) || error(
        "Stratigraphy facies_id must use the declared sand/clay classes."
    )
    all(x -> x in 0:6, mrst_get_vec(stratigraphy["source_window_index"])) || error(
        "Stratigraphy source_window_index must be 0 or 1 through 6."
    )
    return Dict("cell_count" => n)
end

function mrst_validate_declared_downstream_contract(
        contract, permeability, coverage, common_contract
    )
    mrst_contract_require(contract, (
        "schema", "combined_specific_schema", "required_common_schema",
        "validation_policy",
        "permeability_coordinate_transform_schema", "fault_local_component_order",
        "fault_local_axis_meaning", "reservoir_grid_component_order",
        "permeability_units", "window_count", "slice_count", "pc_units",
        "saturation_endpoint_definition"
    ), "downstream_contract")
    mrst_contract_string(contract["schema"], "downstream_contract.schema") ==
        "gom_downstream_reservoir_input_contract_v1" || error(
        "Unsupported downstream contract schema."
    )
    mrst_contract_string(
        contract["combined_specific_schema"], "downstream_contract.combined_specific_schema"
    ) == "gom_jutul_split_specific_v4" || error(
        "Downstream contract declares an invalid combined-specific schema."
    )
    mrst_contract_string(
        contract["required_common_schema"], "downstream_contract.required_common_schema"
    ) == common_contract["common_schema"] || error(
        "Specific and common downstream schemas are incompatible."
    )
    mrst_contract_string(
        contract["permeability_coordinate_transform_schema"],
        "downstream_contract.permeability_coordinate_transform_schema"
    ) == permeability["transform_schema"] || error(
        "Downstream and fault coordinate-transform schemas disagree."
    )
    mrst_contract_strings(contract["fault_local_component_order"]) ==
        ["kxx", "kyy", "kzz"] || error("Declared local component order is invalid.")
    mrst_contract_strings(contract["fault_local_axis_meaning"]) ==
        ["fault_normal", "along_strike", "down_dip"] || error(
        "Declared local permeability axes are invalid."
    )
    mrst_contract_strings(contract["reservoir_grid_component_order"]) ==
        ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"] || error(
        "Declared reservoir-grid component order is invalid."
    )
    mrst_contract_string(contract["permeability_units"], "permeability_units") ==
        "m^2" || error("Declared permeability units must be m^2.")
    mrst_contract_string(contract["pc_units"], "pc_units") == "Pa" || error(
        "Declared Pc units must be Pa."
    )
    Int(round(mrst_contract_scalar(contract["window_count"], "window_count"))) ==
        coverage["window_count"] || error("Declared window count is inconsistent.")
    Int(round(mrst_contract_scalar(contract["slice_count"], "slice_count"))) ==
        coverage["slice_count"] || error("Declared slice count is inconsistent.")
    return nothing
end

function mrst_contract_require(block, keys, label)
    block isa AbstractDict || error("$label must be a dictionary-like block.")
    for key in keys
        haskey(block, key) || error("$label is missing $key.")
    end
    return nothing
end

function mrst_contract_string(value, label)
    if value isa AbstractString
        out = String(value)
    elseif value isa AbstractArray && length(value) == 1 && first(value) isa AbstractString
        out = String(first(value))
    else
        error("$label must be a text scalar.")
    end
    isempty(out) && error("$label must be nonempty.")
    return out
end

mrst_contract_strings(value) = String.(mrst_get_vec(value))

function mrst_contract_scalar(value, label)
    raw = value isa AbstractArray ? only(vec(value)) : value
    raw isa Real && isfinite(raw) || error("$label must be a finite numeric scalar.")
    return Float64(raw)
end

function mrst_contract_numeric_vector(value, n, label)
    raw = mrst_get_vec(value)
    length(raw) == n || error("$label has $(length(raw)) values, expected $n.")
    all(x -> x isa Real && isfinite(x), raw) || error(
        "$label must contain finite numeric values."
    )
    return Float64.(raw)
end

function mrst_contract_positive_integer_vector(value, label)
    raw = mrst_get_vec(value)
    all(x -> x isa Real && isfinite(x) && x >= 1 && isinteger(x), raw) || error(
        "$label must contain positive integer values."
    )
    return Int.(round.(raw))
end

function mrst_contract_matrix(value, nrows, ncols, label)
    value isa AbstractMatrix || error("$label must be a matrix.")
    size(value) == (nrows, ncols) || error(
        "$label has size $(size(value)), expected ($nrows, $ncols)."
    )
    all(x -> x isa Real && isfinite(x), value) || error(
        "$label must contain finite numeric values."
    )
    return Float64.(value)
end

function mrst_contract_relative_error(actual, expected)
    size(actual) == size(expected) || error("Cannot compare arrays with different sizes.")
    scale = max.(abs.(Float64.(expected)), floatmin(Float64))
    return maximum(abs.(Float64.(actual) .- Float64.(expected)) ./ scale)
end

function mrst_contract_assert_positive_definite(perm, label)
    scale = max.(maximum(abs.(perm[:, [1, 4, 6]]), dims = 2)[:, 1], floatmin(Float64))
    a = perm[:, 1] ./ scale
    b = perm[:, 2] ./ scale
    c = perm[:, 3] ./ scale
    d = perm[:, 4] ./ scale
    e = perm[:, 5] ./ scale
    f = perm[:, 6] ./ scale
    minor2 = a .* d .- b.^2
    determinant = a .* d .* f .+ 2 .* b .* c .* e .-
        a .* e.^2 .- d .* c.^2 .- f .* b.^2
    all(a .> 0) && all(minor2 .> 0) && all(determinant .> 0) || error(
        "$label contains a tensor that is not symmetric positive definite."
    )
    return nothing
end

function mrst_contract_is_sha256(value)
    return length(value) == 64 && all(c -> isdigit(c) || c in 'a':'f', value)
end
