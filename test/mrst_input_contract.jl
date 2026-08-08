using JutulDarcy, Test

function downstream_contract_fixture()
    nw = 6
    ns = 87
    n = nw*ns
    layer_size = 8
    nc = layer_size*ns
    fault_cells = [layer_size*(s - 1) + w for s in 1:ns for w in 1:nw]
    stratigraphy_cells = [7]
    shared_cells = collect(layer_size:layer_size:nc)
    geology_id = "s05_c012"
    geology_hash = repeat("a", 64)
    pairing_key = "$geology_id:$geology_hash"
    local_ids = collect(1:n)
    base_region = 3
    global_ids = base_region .+ local_ids
    local_satnum = reshape(local_ids, nw, ns)
    global_satnum = base_region .+ local_satnum
    window_index = repeat(collect(1:nw), ns)
    slice_position = repeat(collect(1:ns), inner = nw)

    local_m2 = zeros(Float64, nw, ns, 3)
    local_m2[:, :, 1] .= 1.0e-15
    local_m2[:, :, 2] .= 2.0e-15
    local_m2[:, :, 3] .= 3.0e-15
    local_md = local_m2 ./ 9.869233e-16
    cell_local_m2 = hcat(
        vec(local_m2[:, :, 1]),
        vec(local_m2[:, :, 2]),
        vec(local_m2[:, :, 3])
    )
    cell_local_md = cell_local_m2 ./ 9.869233e-16
    dip = fill(45.0, n)
    theta = fill(-45.0, n)
    global_perm = zeros(Float64, n, 6)
    global_perm[:, 1] .= 2.0e-15
    global_perm[:, 4] .= 2.0e-15
    global_perm[:, 5] .= 1.0e-15
    global_perm[:, 6] .= 2.0e-15

    table = [
        0.0 0.0 1.0 0.0
        0.4 0.2 0.5 1.0e5
        0.8 1.0 0.0 2.0e5
    ]
    tables = reshape(Any[copy(table) for _ in 1:n], :, 1)

    identity = Dict{String, Any}(
        "geology_id" => geology_id,
        "geology_hash_algorithm" => "sha-256 canonical test payload",
        "geology_hash" => geology_hash,
        "pairing_key" => pairing_key
    )
    transform = Dict{String, Any}(
        "schema" => "gom_fault_permeability_coordinate_transform_v1",
        "source_component_order" => ["kxx", "kyy", "kzz"],
        "source_axis_meaning" => ["fault_normal", "along_strike", "down_dip"],
        "target_component_order" => ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "global_x_alignment" => "local kyy (along_strike)",
        "fault_trace_y_direction_sign" => 1,
        "rotation_angle_definition" =>
            "theta = fault_trace_y_direction_sign * (dip - 90 degrees)",
        "input_units" => "m^2",
        "output_units" => "m^2",
        "validation" => Dict{String, Any}("passed" => true)
    )
    fault = merge(copy(identity), Dict{String, Any}(
        "cells" => fault_cells,
        "poro" => fill(0.2, n),
        "perm" => global_perm,
        "perm_units" => "m^2",
        "perm_component_order" => ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "local_perm_m2" => cell_local_m2,
        "local_perm_md" => cell_local_md,
        "local_perm_m2_units" => "m^2",
        "local_perm_md_units" => "mD",
        "local_perm_component_order" => ["kxx", "kyy", "kzz"],
        "window_index" => window_index,
        "slice_position" => slice_position,
        "slice_index" => slice_position,
        "window_unit_ids" => collect(26:31),
        "window_slice_cell_counts" => ones(Int, nw, ns),
        "local_saturation_region" => vec(local_satnum),
        "saturation_region" => vec(global_satnum),
        "region_matrix" => global_satnum,
        "table_regions" => global_ids,
        "dip" => dip,
        "rotation_angle_degrees" => theta,
        "permeability_coordinate_transform" => transform,
        "fluid_tables" => Dict{String, Any}(
            "SGOF" => Dict{String, Any}(
                "regions" => global_ids,
                "tables" => tables,
                "column_names" => ["SGAS", "KRG", "KROG", "PCOG"],
                "column_units" => ["fraction", "fraction", "fraction", "Pa"],
                "point_counts" => fill(3, n),
                "bulk_sg_max" => fill(0.8, n),
                "effective_swi" => fill(0.2, n),
                "local_regions" => local_ids,
                "source_curve_linear_indices" => local_ids
            )
        )
    ))
    strat_perm = reshape([1.0e-15, 0.0, 0.0, 1.0e-15, 0.0, 1.0e-15], 1, 6)
    stratigraphy = merge(copy(identity), Dict{String, Any}(
        "cells" => stratigraphy_cells,
        "poro" => [0.25],
        "perm" => strat_perm,
        "perm_units" => "m^2",
        "perm_component_order" => ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "saturation_region" => [1],
        "rock_region" => [1],
        "side_id" => [1],
        "stratigraphic_unit_id" => [1],
        "grid_unit_id" => [1],
        "facies_id" => [1],
        "source_window_index" => [1],
        "source_layer_index" => [1]
    ))
    window_slice = Dict{String, Any}(
        "dimension_order" => "window x slice x component",
        "window_names" => ["famp$i" for i in 1:nw],
        "window_unit_ids" => collect(26:31),
        "slice_indices" => collect(1:ns),
        "saturation_region" => global_satnum,
        "local_saturation_region" => local_satnum,
        "poro" => fill(0.2, nw, ns),
        "local_perm_m2" => local_m2,
        "local_perm_md" => local_md,
        "selected_sample_index" => reshape(collect(1:n), nw, ns),
        "exact_replay_seed" => reshape(collect(1001:(1000 + n)), nw, ns)
    )
    saturation_regions = Dict{String, Any}(
        "schema" => "gom_fault_saturation_regions_v1",
        "representation" => "full_slice",
        "base_region_count" => base_region,
        "region_count" => n,
        "local_region_ids" => local_ids,
        "global_region_ids" => global_ids,
        "local_satnum" => local_satnum,
        "global_satnum" => global_satnum,
        "region_curve_linear_indices" => local_ids
    )
    downstream_contract = Dict{String, Any}(
        "schema" => "gom_downstream_reservoir_input_contract_v1",
        "combined_specific_schema" => "gom_jutul_split_specific_v4",
        "required_common_schema" => "gom_jutul_split_common_v2",
        "validation_policy" => "strict at MATLAB export and JutulDarcy import",
        "permeability_coordinate_transform_schema" =>
            "gom_fault_permeability_coordinate_transform_v1",
        "fault_local_component_order" => ["kxx", "kyy", "kzz"],
        "fault_local_axis_meaning" => ["fault_normal", "along_strike", "down_dip"],
        "reservoir_grid_component_order" =>
            ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "permeability_units" => "m^2",
        "window_count" => nw,
        "slice_count" => ns,
        "pc_units" => "Pa",
        "saturation_endpoint_definition" => "effective_swi = 1 - bulk_sg_max"
    )
    geology_link = merge(copy(identity), Dict{String, Any}(
        "schema" => "gom_geology_pairing_v1",
        "stratigraphy_file" => "geology_stratigraphy_s05_c012.mat",
        "fault_schema" => "1.5",
        "stratigraphy_schema" => "1.0"
    ))
    specific = Dict{String, Any}(
        "schema" => "gom_jutul_split_specific_v4",
        "common_name" => "tiny_common",
        "geology_id" => geology_id,
        "geology_hash_algorithm" => identity["geology_hash_algorithm"],
        "geology_hash" => geology_hash,
        "pairing_key" => pairing_key,
        "geology_link" => geology_link,
        "component_schemas" => Dict{String, Any}(
            "fault" => "gom_jutul_split_specific_v3",
            "stratigraphy" => "gom_jutul_stratigraphy_specific_v1"
        ),
        "metadata" => Dict{String, Any}(
            "reservoir_ready_file" => "fault_properties_s05_c012_case01.mat",
            "stratigraphy_file" => "geology_stratigraphy_s05_c012.mat",
            "geology_id" => geology_id,
            "geology_hash_algorithm" => identity["geology_hash_algorithm"],
            "geology_hash" => geology_hash,
            "pairing_key" => pairing_key
        ),
        "fault" => fault,
        "stratigraphy" => stratigraphy,
        "window_slice" => window_slice,
        "saturation_regions" => saturation_regions,
        "downstream_contract" => downstream_contract
    )

    shared_local = reshape([4.0e-15, 5.0e-15, 6.0e-15], 1, 3)
    shared_global = reshape(
        [5.0e-15, 0.0, 0.0, 5.0e-15, 1.0e-15, 5.0e-15], 1, 6
    )
    common_perm = fill(0.0, nc, 6)
    common_perm[:, 1] .= 1.0e-15
    common_perm[:, 4] .= 1.0e-15
    common_perm[:, 6] .= 1.0e-15
    common_poro = fill(0.2, nc)
    specific_geology_cells = vcat(fault_cells, stratigraphy_cells)
    common_perm[specific_geology_cells, :] .= NaN
    common_poro[specific_geology_cells] .= NaN
    common_perm[shared_cells, :] .= repeat(shared_global, length(shared_cells), 1)
    shared_transform = deepcopy(transform)
    shared = Dict{String, Any}(
        "schema" => "gom_shared_fault_permeability_v1",
        "cell_source" => "common.masks.fixedSharedFaultCells",
        "cell_count" => length(shared_cells),
        "template_footprint_count" => 1,
        "current_grid_layer_size" => layer_size,
        "current_slice_count" => ns,
        "template_footprint_ids" => [layer_size],
        "template_local_perm_m2" => shared_local,
        "local_perm_units" => "m^2",
        "local_perm_component_order" => ["kxx", "kyy", "kzz"],
        "local_perm_axis_meaning" => ["fault_normal", "along_strike", "down_dip"],
        "global_perm_units" => "m^2",
        "global_perm_component_order" =>
            ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "template_dip_degrees" => [45.0],
        "template_rotation_angle_degrees" => [-45.0],
        "permeability_coordinate_transform" => shared_transform
    )
    common_contract = Dict{String, Any}(
        "schema" => "gom_downstream_common_input_contract_v1",
        "common_schema" => "gom_jutul_split_common_v2",
        "required_specific_schema" => "gom_jutul_split_specific_v4",
        "shared_fault_schema" => "gom_shared_fault_permeability_v1",
        "permeability_coordinate_transform_schema" =>
            "gom_fault_permeability_coordinate_transform_v1",
        "permeability_units" => "m^2",
        "reservoir_grid_component_order" =>
            ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"]
    )
    common = Dict{String, Any}(
        "schema" => "gom_jutul_split_common_v2",
        "name" => "tiny_common",
        "G" => Dict{String, Any}(
            "layerSize" => layer_size,
            "cells" => Dict{String, Any}("num" => nc)
        ),
        "rock" => Dict{String, Any}(
            "poro" => common_poro,
            "perm" => common_perm
        ),
        "rock_permeability_units" => "m^2",
        "rock_permeability_component_order" =>
            ["Kxx", "Kxy", "Kxz", "Kyy", "Kyz", "Kzz"],
        "masks" => Dict{String, Any}(
            "fault_all_cells" => vcat(fault_cells, shared_cells),
            "specificFaultCells" => fault_cells,
            "specificStratigraphyCells" => stratigraphy_cells,
            "specificGeologyCells" => specific_geology_cells,
            "fixedSharedFaultCells" => shared_cells
        ),
        "shared_fault_permeability" => shared,
        "downstream_contract" => common_contract
    )
    return common, specific
end

@testset "strict GoM downstream contract" begin
    common, specific = downstream_contract_fixture()
    report = JutulDarcy.validate_mrst_combined_specific_identity(common, specific)
    @test report["passed"]
    @test report["window_count"] == 6
    @test report["slice_count"] == 87
    @test report["saturation_region_count"] == 522
    @test report["shared_fault_cell_count"] == 87
    @test report["shared_fault_footprint_count"] == 1
    @test report["max_relative_permeability_transform_error"] <= 5e-12
    @test report["common_max_relative_permeability_transform_error"] <= 5e-12

    wrong_common_rotation = deepcopy(common)
    wrong_common_rotation["rock"]["perm"][:, 5] .*= -1
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        wrong_common_rotation, specific
    )

    old_common_schema = deepcopy(common)
    old_common_schema["schema"] = "gom_jutul_split_common_v1"
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        old_common_schema, specific
    )

    wrong_hash = deepcopy(specific)
    wrong_hash["stratigraphy"]["geology_hash"] = repeat("0", 64)
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        common, wrong_hash
    )

    wrong_rotation = deepcopy(specific)
    wrong_rotation["fault"]["perm"][:, 5] .*= -1
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        common, wrong_rotation
    )

    wrong_coverage = deepcopy(specific)
    wrong_coverage["window_slice"]["poro"] =
        wrong_coverage["window_slice"]["poro"][1:5, :]
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        common, wrong_coverage
    )

    wrong_endpoint = deepcopy(specific)
    wrong_endpoint["fault"]["fluid_tables"]["SGOF"]["effective_swi"][1] += 0.01
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        common, wrong_endpoint
    )

    wrong_kr = deepcopy(specific)
    wrong_kr["fault"]["fluid_tables"]["SGOF"]["tables"][1][2, 2] = 1.2
    @test_throws ErrorException JutulDarcy.validate_mrst_combined_specific_identity(
        common, wrong_kr
    )
end
