const PRODUCTION_QOI_SCHEMA4_VERSION = 4
const PRODUCTION_QOI_SCHEMA4_ROW_PATTERN = r"^step_(\d{6})\.tsv$"
const PRODUCTION_QOI_SCHEMA4_BINARY_PATTERN = r"^step_(\d{6})\.bin$"
const PRODUCTION_QOI_SCHEMA4_MAGIC = UInt8[0x47, 0x4f, 0x4d, 0x51, 0x4f, 0x49, 0x34, 0x00]
const PRODUCTION_QOI_SCHEMA4_WINDOWS = 6
const PRODUCTION_QOI_SCHEMA4_SLICES = 87
const PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS = (
    "pressure_pa",
    "capillary_pressure_pa",
    "gas_saturation",
    "historical_max_gas_saturation",
    "dissolved_gas_ratio",
    "free_co2_mass_kg",
    "dissolved_co2_mass_kg"
)
const PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS = (
    "top_seal_system",
    "overburden_mmum_younger"
)
const PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS = (
    "free_co2_mass_kg",
    "dissolved_co2_mass_kg",
    "gas_saturation_max"
)
const PRODUCTION_QOI_SCHEMA4_INTERFACE_IDS = (
    "storage_to_fault",
    "storage_to_top_seal_system",
    "fault_to_top_seal_system",
    "non_overburden_to_overburden"
)

"""
Restart-safe additions to the production QoI contract.

Schema-3 files remain byte-for-byte compatible. Schema 4 writes only to the
separate `qoi_schema4` directory and adds accepted-ministep cumulative
accounting plus compact 6 by 87 and 87-slice report histories.
"""
mutable struct ProductionQoISchema4Context
    mode::String
    root_dir::String
    ready_dir::String
    row_dir::String
    spatial_ready_dir::String
    spatial_row_dir::String
    case_key::String
    campaign_manifest_sha256::String
    fault_groups::Vector{Vector{Int32}}
    fault_group_pore_volume::Vector{Float64}
    leakage_cells::Vector{Int32}
    leakage_region::Vector{UInt8}
    leakage_slice::Vector{UInt8}
    stratigraphic_unit::Vector{Int16}
    stratigraphic_side::Vector{Int8}
    interfaces::Vector{ProductionQoIInterface}
    selected_faces::Vector{Int32}
    face_slot::Vector{Int32}
    mapping_sha256::String
    provenance_manifest_sha256::String
    realization_manifest_sha256::String
    cumulative_interface_kg::Array{Float64, 3}
    cumulative_injected_co2_kg::Float64
    cumulative_produced_co2_kg::Float64
    cumulative_boundary_out_kg::Float64
    cumulative_boundary_in_kg::Float64
    accepted_ministep_count::Int
    accepted_seconds::Float64
    control_switch_count::Int
    previous_active_control::String
    last_actual_co2_rate_kg_s::Float64
    last_total_well_mass_rate_kg_s::Float64
    last_bhp_pa::Float64
    last_requested_control::String
    last_requested_target_value::Float64
    last_requested_target_unit::String
    last_requested_target_co2_rate_kg_s::Float64
    last_active_control::String
    last_active_target_value::Float64
    last_active_target_unit::String
    last_active_target_co2_rate_kg_s::Float64
    ministep_accounting_seconds::Float64
end

production_qoi_schema4_active(::Nothing) = false
production_qoi_schema4_active(context::ProductionQoISchema4Context) =
    context.mode != "off"

production_qoi_schema4_ready_path(context, step::Integer) =
    joinpath(context.ready_dir, @sprintf("step_%06d.tsv", step))
production_qoi_schema4_row_path(context, step::Integer) =
    joinpath(context.row_dir, @sprintf("step_%06d.tsv", step))
production_qoi_schema4_spatial_ready_path(context, step::Integer) =
    joinpath(context.spatial_ready_dir, @sprintf("step_%06d.bin", step))
production_qoi_schema4_spatial_row_path(context, step::Integer) =
    joinpath(context.spatial_row_dir, @sprintf("step_%06d.bin", step))

function production_qoi_schema4_mode()
    mode = lowercase(strip(get(ENV, "PRODUCTION_QOI_SCHEMA4_MODE", "auto")))
    mode in ("off", "auto", "required") || error(
        "Unknown PRODUCTION_QOI_SCHEMA4_MODE=$mode. Valid values are off, auto, required."
    )
    return mode
end

function production_qoi_schema4_capable(mrst_data)
    required = (
        "qoi_fault",
        "qoi_stratigraphy",
        "qoi_case_metadata",
        "downstream_contract_validation"
    )
    all(key -> haskey(mrst_data, key), required) || return false
    fault = mrst_data["qoi_fault"]
    all(key -> haskey(fault, key), ("cells", "window_index", "slice_index")) ||
        return false
    validation = mrst_data["downstream_contract_validation"]
    return get(validation, "passed", false) == true &&
        Int(round(production_qoi_scalar(validation["window_count"]))) ==
            PRODUCTION_QOI_SCHEMA4_WINDOWS &&
        Int(round(production_qoi_scalar(validation["slice_count"]))) ==
            PRODUCTION_QOI_SCHEMA4_SLICES
end

function production_qoi_schema4_region_codes(context, region_id::AbstractString)
    haskey(context.region_index, String(region_id)) ||
        error("Schema-4 QoI region $region_id is undefined.")
    return context.regions[context.region_index[String(region_id)]].atomic_codes
end

function production_qoi_schema4_build_interface(
        context,
        neighbors,
        id::AbstractString,
        label::AbstractString,
        from_id::AbstractString,
        to_id::AbstractString,
        from_codes,
        to_codes,
        definition::AbstractString
    )
    from_set = production_qoi_codeset(from_codes)
    to_set = production_qoi_codeset(to_codes)
    any(from_set .& to_set) && error("Schema-4 interface $id has overlapping sides.")
    faces = Int32[]
    signs = Int8[]
    @inbounds for face in axes(neighbors, 2)
        left_code = context.atomic_code[neighbors[1, face]]
        right_code = context.atomic_code[neighbors[2, face]]
        if from_set[Int(left_code) + 1] && to_set[Int(right_code) + 1]
            push!(faces, Int32(face))
            push!(signs, Int8(1))
        elseif from_set[Int(right_code) + 1] && to_set[Int(left_code) + 1]
            push!(faces, Int32(face))
            push!(signs, Int8(-1))
        end
    end
    isempty(faces) && error("Schema-4 interface $id has no simulator faces.")
    return ProductionQoIInterface(
        String(id),
        String(label),
        String(from_id),
        String(to_id),
        "accepted_ministep_semantic_contact",
        faces,
        signs,
        String(definition)
    )
end

function production_qoi_schema4_interfaces(context, rmodel)
    neighbors = production_qoi_neighbors(rmodel, length(context.atomic_code))
    storage = production_qoi_schema4_region_codes(context, "storage_lm2")
    fault = production_qoi_schema4_region_codes(context, "fault_all")
    top_seal = production_qoi_schema4_region_codes(context, "top_seal_system")
    overburden = production_qoi_schema4_region_codes(
        context,
        "overburden_mmum_younger"
    )
    all_codes = UInt8.(1:length(context.atomic_regions))
    non_overburden = setdiff(all_codes, overburden)
    return ProductionQoIInterface[
        production_qoi_schema4_build_interface(
            context, neighbors,
            "storage_to_fault", "Storage reservoir to fault",
            "storage_lm2", "fault_all", storage, fault,
            "All direct contacts from the storage reservoir into the complete fault."
        ),
        production_qoi_schema4_build_interface(
            context, neighbors,
            "storage_to_top_seal_system", "Storage reservoir to top-seal system",
            "storage_lm2", "top_seal_system", storage, top_seal,
            "All direct contacts from the storage reservoir into the complete top-seal system."
        ),
        production_qoi_schema4_build_interface(
            context, neighbors,
            "fault_to_top_seal_system", "Fault to top-seal system",
            "fault_all", "top_seal_system", fault, top_seal,
            "All direct contacts from the complete fault into the complete top-seal system."
        ),
        production_qoi_schema4_build_interface(
            context, neighbors,
            "non_overburden_to_overburden", "Complete lower domain to overburden",
            "domain_nonoverburden", "overburden_mmum_younger",
            non_overburden, overburden,
            "Every direct contact from a non-overburden cell into MM-UM or Younger overburden."
        )
    ]
end

function production_qoi_schema4_fault_groups(context, mrst_data)
    fault = mrst_data["qoi_fault"]
    cells = Int.(production_qoi_vec(fault, "cells"))
    windows = Int.(production_qoi_vec(
        fault,
        "window_index";
        length_expected = length(cells)
    ))
    slices = Int.(production_qoi_vec(
        fault,
        "slice_index";
        length_expected = length(cells)
    ))
    groups = [Int32[] for _ in 1:(
        PRODUCTION_QOI_SCHEMA4_WINDOWS*PRODUCTION_QOI_SCHEMA4_SLICES
    )]
    for index in eachindex(cells)
        window = windows[index]
        slice = slices[index]
        1 <= window <= PRODUCTION_QOI_SCHEMA4_WINDOWS ||
            error("Fault QoI window index $window is outside 1:6.")
        1 <= slice <= PRODUCTION_QOI_SCHEMA4_SLICES ||
            error("Fault QoI slice index $slice is outside 1:87.")
        cell = cells[index]
        1 <= cell <= length(context.atomic_code) ||
            error("Fault QoI cell $cell is outside the simulator grid.")
        push!(groups[(window - 1)*PRODUCTION_QOI_SCHEMA4_SLICES + slice], Int32(cell))
    end
    all(!isempty, groups) || error(
        "Schema-4 QoI output requires complete 6 by 87 fault coverage."
    )
    pvs = [sum(context.pore_volume[Int(cell)] for cell in group) for group in groups]
    all(>(0.0), pvs) || error("A schema-4 fault group has zero pore volume.")
    return groups, pvs
end

function production_qoi_schema4_fault_slice_centers(context, groups)
    centers = zeros(Float64, 2, PRODUCTION_QOI_SCHEMA4_SLICES)
    for slice in 1:PRODUCTION_QOI_SCHEMA4_SLICES
        cells = Int32[]
        for window in 1:PRODUCTION_QOI_SCHEMA4_WINDOWS
            append!(cells, groups[(window - 1)*PRODUCTION_QOI_SCHEMA4_SLICES + slice])
        end
        for cell in cells
            centers[1, slice] += context.centroids[1, Int(cell)]
            centers[2, slice] += context.centroids[2, Int(cell)]
        end
        centers[:, slice] ./= length(cells)
    end
    return centers
end

function production_qoi_schema4_nearest_slice(centers, x, y)
    best_slice = 1
    best_distance = Inf
    @inbounds for slice in axes(centers, 2)
        distance = abs2(x - centers[1, slice]) + abs2(y - centers[2, slice])
        if distance < best_distance
            best_distance = distance
            best_slice = slice
        end
    end
    return best_slice
end

function production_qoi_schema4_leakage_mapping(context, groups)
    centers = production_qoi_schema4_fault_slice_centers(context, groups)
    region_sets = map(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS) do id
        production_qoi_codeset(production_qoi_schema4_region_codes(context, id))
    end
    cells = Int32[]
    regions = UInt8[]
    slices = UInt8[]
    @inbounds for cell in eachindex(context.atomic_code)
        code_index = Int(context.atomic_code[cell]) + 1
        region = if region_sets[1][code_index]
            1
        elseif region_sets[2][code_index]
            2
        else
            0
        end
        region == 0 && continue
        slice = production_qoi_schema4_nearest_slice(
            centers,
            context.centroids[1, cell],
            context.centroids[2, cell]
        )
        push!(cells, Int32(cell))
        push!(regions, UInt8(region))
        push!(slices, UInt8(slice))
    end
    all(region -> any(==(region), regions), UInt8.(1:2)) ||
        error("Schema-4 leakage mapping is missing a semantic region.")
    counts = zeros(Int, 2, PRODUCTION_QOI_SCHEMA4_SLICES)
    for index in eachindex(regions)
        counts[Int(regions[index]), Int(slices[index])] += 1
    end
    all(>(0), counts) || error(
        "Schema-4 leakage mapping does not cover every region-by-slice bin."
    )
    return cells, regions, slices
end

function production_qoi_schema4_stratigraphic_lookup(context, mrst_data)
    nc = length(context.atomic_code)
    units = zeros(Int16, nc)
    sides = zeros(Int8, nc)
    stratigraphy = mrst_data["qoi_stratigraphy"]
    haskey(stratigraphy, "cells") || return units, sides
    cells = Int.(production_qoi_vec(stratigraphy, "cells"))
    if haskey(stratigraphy, "stratigraphic_unit_id")
        values = Int.(production_qoi_vec(
            stratigraphy,
            "stratigraphic_unit_id";
            length_expected = length(cells)
        ))
        units[cells] .= Int16.(values)
    end
    if haskey(stratigraphy, "side_id")
        values = Int.(production_qoi_vec(
            stratigraphy,
            "side_id";
            length_expected = length(cells)
        ))
        sides[cells] .= Int8.(values)
    end
    return units, sides
end

function production_qoi_schema4_mapping_sha256(groups, cells, regions, slices)
    io = IOBuffer()
    for (group_index, group) in enumerate(groups)
        for cell in group
            write(io, htol(Int64(group_index)))
            write(io, htol(Int64(cell)))
        end
    end
    for index in eachindex(cells)
        write(io, htol(Int64(cells[index])))
        write(io, regions[index])
        write(io, slices[index])
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function production_qoi_schema4_manifest_value(value)
    if value isa AbstractArray
        return join(production_format_value.(vec(value)), ",")
    end
    return production_format_value(value)
end

function production_qoi_schema4_collect_metadata!(rows, prefix, value, source)
    if value isa AbstractDict
        for key in sort!(collect(keys(value)); by = string)
            child = isempty(prefix) ? String(key) : prefix * "." * String(key)
            production_qoi_schema4_collect_metadata!(
                rows,
                child,
                value[key],
                source
            )
        end
    elseif value isa Union{AbstractString, Symbol, Real, Bool} ||
            (value isa AbstractVector && length(value) <= 12)
        push!(rows, Dict{Symbol, Any}(
            :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
            :key => prefix,
            :value => production_qoi_schema4_manifest_value(value),
            :source => source
        ))
    end
    return rows
end

function production_qoi_schema4_write_manifests!(
        context,
        extension,
        mrst_data
    )
    definition = (
        schema_version = PRODUCTION_QOI_SCHEMA4_VERSION,
        base_qoi_schema_version = PRODUCTION_QOI_SCHEMA_VERSION,
        case_key = context.case_key,
        campaign_manifest_sha256 = context.campaign_manifest_sha256,
        window_count = PRODUCTION_QOI_SCHEMA4_WINDOWS,
        slice_count = PRODUCTION_QOI_SCHEMA4_SLICES,
        fault_field_order = join(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS, ","),
        fault_dimension_order =
            "window_major_then_slice_by_field_column_major",
        leakage_region_order = join(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS, ","),
        leakage_field_order = join(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS, ","),
        leakage_dimension_order =
            "region_by_slice_by_field_column_major",
        binary_numeric_type = "Float64",
        binary_byte_order = "little_endian",
        elevation_definition = "elevation_m=-G.cells.centroids_z_m",
        leakage_slice_mapping =
            "nearest_frozen_fault_slice_center_in_horizontal_centroid_space",
        mapping_sha256 = extension.mapping_sha256,
        interface_integration =
            "accepted_adaptive_ministep_forward_reverse_net_blackoil_co2_mass",
        spatial_evaluation = "report_endpoint",
        historical_gas_saturation =
            "MaxSaturations_gas_when_present_otherwise_current_Sg"
    )
    definition_path = joinpath(extension.root_dir, "schema4_definition.tsv")
    if isfile(definition_path)
        observed = production_read_named_row(definition_path)
        for (key, value) in pairs(definition)
            observed[string(key)] == production_format_value(value) || error(
                "Schema-4 definition changed on restart for $key."
            )
        end
    else
        production_write_named_row(definition_path, definition)
    end

    provenance_rows = Dict{Symbol, Any}[]
    production_qoi_schema4_collect_metadata!(
        provenance_rows,
        "case",
        mrst_data["qoi_case_metadata"],
        "validated_mrst_input"
    )
    for key in (
            "GOM_PRODUCTION_CAMPAIGN_ID",
            "GOM_PRODUCTION_ENSEMBLE_KIND",
            "GOM_PRODUCTION_PHYSICS_PROFILE",
            "GOM_PRODUCTION_CASE_KEY",
            "GOM_PRODUCTION_GEOLOGY_ID",
            "GOM_PRODUCTION_REALIZATION_ID",
            "GOM_PRODUCTION_LEVEL3_CASE_NAME",
            "GOM_PRODUCTION_MANIFEST_SHA256",
            "GOM_PRODUCTION_CASE_ORDER_SHA256",
            "GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256",
            "GOM_PRODUCTION_COMMON_SHA256",
            "GOM_PRODUCTION_SPECIFIC_SHA256",
            "GOM_PRODUCTION_MRST_PREPARE_COMMIT",
            "GOM_PRODUCTION_JUTULDARCY_COMMIT",
            "GOM_PRODUCTION_JUTUL_MANIFEST_SHA256",
            "GOM_PRODUCTION_COORDINATE_TRANSFORM_SHA256",
            "GOM_UQ_PHASE",
            "GOM_UQ_REPLICATE_ID",
            "GOM_UQ_BALANCED_DESIGN",
            "GOM_UQ_ADAPTIVE_DESIGN",
            "GOM_UQ_SAMPLING_SEED"
        )
        haskey(ENV, key) || continue
        push!(provenance_rows, Dict{Symbol, Any}(
            :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
            :key => "environment." * key,
            :value => ENV[key],
            :source => "production_environment"
        ))
    end
    sort!(provenance_rows; by = row -> String(row[:key]))
    provenance_path = joinpath(extension.root_dir, "case_uq_manifest.tsv")
    production_qoi_write_or_validate_manifest(
        provenance_path,
        Symbol[:schema_version, :key, :value, :source],
        provenance_rows
    )
    extension.provenance_manifest_sha256 =
        production_qoi_file_sha256(provenance_path)

    realization_rows = Dict{Symbol, Any}[]
    case_metadata = mrst_data["qoi_case_metadata"]
    if haskey(case_metadata, "window_slice")
        ws = case_metadata["window_slice"]
        indices = haskey(ws, "selected_sample_index") ?
            Int.(ws["selected_sample_index"]) :
            fill(0, PRODUCTION_QOI_SCHEMA4_WINDOWS, PRODUCTION_QOI_SCHEMA4_SLICES)
        seeds = haskey(ws, "exact_replay_seed") ?
            Int64.(ws["exact_replay_seed"]) :
            fill(Int64(0), PRODUCTION_QOI_SCHEMA4_WINDOWS, PRODUCTION_QOI_SCHEMA4_SLICES)
        size(indices) == (
            PRODUCTION_QOI_SCHEMA4_WINDOWS,
            PRODUCTION_QOI_SCHEMA4_SLICES
        ) || error("selected_sample_index is not 6 by 87.")
        size(seeds) == size(indices) || error("exact_replay_seed is not 6 by 87.")
        for window in 1:PRODUCTION_QOI_SCHEMA4_WINDOWS
            for slice in 1:PRODUCTION_QOI_SCHEMA4_SLICES
                push!(realization_rows, Dict{Symbol, Any}(
                    :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
                    :window => window,
                    :slice => slice,
                    :selected_realization_index => indices[window, slice],
                    :exact_replay_seed => seeds[window, slice]
                ))
            end
        end
    end
    isempty(realization_rows) && error(
        "Schema-4 production output requires selected realization indices and replay seeds."
    )
    realization_path = joinpath(extension.root_dir, "realization_manifest.tsv")
    production_qoi_write_or_validate_manifest(
        realization_path,
        Symbol[
            :schema_version,
            :window,
            :slice,
            :selected_realization_index,
            :exact_replay_seed
        ],
        realization_rows
    )
    extension.realization_manifest_sha256 =
        production_qoi_file_sha256(realization_path)

    fault_rows = Dict{Symbol, Any}[]
    for window in 1:PRODUCTION_QOI_SCHEMA4_WINDOWS
        for slice in 1:PRODUCTION_QOI_SCHEMA4_SLICES
            group = (window - 1)*PRODUCTION_QOI_SCHEMA4_SLICES + slice
            cells = extension.fault_groups[group]
            push!(fault_rows, Dict{Symbol, Any}(
                :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
                :window => window,
                :slice => slice,
                :cell_count => length(cells),
                :pore_volume_m3 => extension.fault_group_pore_volume[group],
                :cell_ids_sha256 => bytes2hex(SHA.sha256(reinterpret(
                    UInt8,
                    Int64.(cells)
                )))
            ))
        end
    end
    production_qoi_write_or_validate_manifest(
        joinpath(extension.root_dir, "fault_group_manifest.tsv"),
        Symbol[
            :schema_version,
            :window,
            :slice,
            :cell_count,
            :pore_volume_m3,
            :cell_ids_sha256
        ],
        fault_rows
    )

    interface_rows = production_qoi_interface_manifest_rows(extension.interfaces)
    production_qoi_write_or_validate_manifest(
        joinpath(extension.root_dir, "cumulative_interface_manifest.tsv"),
        PRODUCTION_QOI_INTERFACE_MANIFEST_COLUMNS,
        interface_rows
    )
    return extension
end

function setup_production_qoi_schema4(context, mrst_data, sim)
    mode = production_qoi_schema4_mode()
    mode == "off" && return nothing
    capable = production_qoi_schema4_capable(mrst_data)
    if !capable
        mode == "required" && error(
            "Schema-4 QoI output requires a validated v4 MRST input with " *
            "complete 6 by 87 realization metadata."
        )
        return nothing
    end

    groups, group_pv = production_qoi_schema4_fault_groups(context, mrst_data)
    leakage_cells, leakage_region, leakage_slice =
        production_qoi_schema4_leakage_mapping(context, groups)
    strat_unit, strat_side =
        production_qoi_schema4_stratigraphic_lookup(context, mrst_data)
    rmodel = production_qoi_reservoir_model(sim)
    interfaces = production_qoi_schema4_interfaces(context, rmodel)
    selected_faces = sort!(unique!(vcat((interface.faces for interface in interfaces)...)))
    neighbors = production_qoi_neighbors(rmodel, length(context.atomic_code))
    face_slot = zeros(Int32, size(neighbors, 2))
    for (slot, face) in enumerate(selected_faces)
        face_slot[Int(face)] = Int32(slot)
    end
    mapping_sha256 = production_qoi_schema4_mapping_sha256(
        groups,
        leakage_cells,
        leakage_region,
        leakage_slice
    )

    root = joinpath(context.summary_dir, "qoi_schema4")
    ready = joinpath(root, "ready")
    rows = joinpath(root, "rows")
    spatial_ready = joinpath(root, "spatial_ready")
    spatial_rows = joinpath(root, "spatial_rows")
    foreach(mkpath, (root, ready, rows, spatial_ready, spatial_rows))
    extension = ProductionQoISchema4Context(
        mode,
        abspath(root),
        abspath(ready),
        abspath(rows),
        abspath(spatial_ready),
        abspath(spatial_rows),
        context.case_key,
        context.campaign_manifest_sha256,
        groups,
        group_pv,
        leakage_cells,
        leakage_region,
        leakage_slice,
        strat_unit,
        strat_side,
        interfaces,
        selected_faces,
        face_slot,
        mapping_sha256,
        "",
        "",
        zeros(Float64, length(interfaces), 3, 2),
        0.0,
        0.0,
        0.0,
        0.0,
        0,
        0.0,
        0,
        "",
        0.0,
        0.0,
        NaN,
        "",
        NaN,
        "",
        NaN,
        "",
        NaN,
        "",
        NaN,
        0.0
    )
    production_qoi_schema4_write_manifests!(context, extension, mrst_data)
    return extension
end

function production_qoi_schema4_current_states(sim)
    storage = Jutul.get_simulator_storage(sim)
    model = Jutul.get_simulator_model(sim)
    if model isa Jutul.MultiModel
        states = Dict{Symbol, Any}(
            key => storage[key].state for key in keys(model.models)
        )
        return states, states[:Reservoir], model.models[:Reservoir]
    end
    return storage.state, storage.state, model
end

function production_qoi_schema4_control_descriptor(control, well_model)
    if isnothing(control) || control isa DisabledControl
        return (
            name = "disabled",
            target_value = 0.0,
            target_unit = "-",
            target_co2_rate_kg_s = 0.0
        )
    end
    target = control.target
    information = well_target_information(target)
    name = ismissing(information) ? string(typeof(target)) :
        String(information.symbol)
    unit = ismissing(information) ? "unknown" : String(information.unit_label)
    target_value = hasproperty(target, :value) ? Float64(target.value) : NaN
    target_co2_rate = NaN
    indices = phase_indices(well_model.system)
    gas = indices.v
    if target isa TotalMassRateTarget && control isa InjectorControl
        target_co2_rate = target_value*Float64(control.injection_mixture[gas])
    elseif target isa SurfaceGasRateTarget
        target_co2_rate =
            target_value*Float64(reference_densities(well_model.system)[gas])
    end
    return (
        name = name,
        target_value = target_value,
        target_unit = unit,
        target_co2_rate_kg_s = target_co2_rate
    )
end

function production_qoi_schema4_requested_control(forces, well::Symbol)
    haskey(forces, :Facility) || return nothing
    facility = forces[:Facility]
    haskey(facility, :control) || return nothing
    controls = facility[:control]
    return haskey(controls, well) ? controls[well] : nothing
end

@inline production_qoi_schema4_primal(value) =
    production_qoi_primal_float(value)

function production_qoi_schema4_surface_mixture(control, well_state)
    if control isa InjectorControl
        return production_qoi_schema4_primal.(control.injection_mixture)
    elseif haskey(well_state, :MassFractions)
        mixture = production_qoi_schema4_primal.(well_state[:MassFractions])
    else
        masses = production_qoi_schema4_primal.(
            @view well_state[:TotalMasses][:, well_top_node()]
        )
        total = sum(masses)
        isfinite(total) && total > 0.0 || error(
            "Schema-4 producer surface mixture has invalid total mass $total."
        )
        mixture = masses./total
    end
    all(value -> isfinite(value) && value >= 0.0, mixture) || error(
        "Schema-4 well surface mixture is non-finite or negative."
    )
    return mixture
end

function production_qoi_schema4_well_accounting(
        context,
        states,
        model,
        forces
    )
    isempty(context.injector_name) && return (
        actual_co2_rate_kg_s = 0.0,
        total_mass_rate_kg_s = 0.0,
        bhp_pa = NaN,
        requested = (name = "none", target_value = NaN,
            target_unit = "-", target_co2_rate_kg_s = NaN),
        active = (name = "none", target_value = NaN,
            target_unit = "-", target_co2_rate_kg_s = NaN)
    )
    model isa Jutul.MultiModel || error(
        "Schema-4 well accounting requires a MultiModel with Facility."
    )
    well = Symbol(context.injector_name)
    haskey(model.models, well) || error(
        "Schema-4 injector $(context.injector_name) is not a simulator submodel."
    )
    haskey(model.models, :Facility) || error(
        "Schema-4 well accounting found no Facility model."
    )
    facility_model = model.models[:Facility]
    well_model = model.models[well]
    facility_state = states[:Facility]
    well_state = states[well]
    # The accepted nonlinear state can still carry separate reservoir and well
    # AD tags. Equation-assembly cross terms deliberately combine those tags,
    # so diagnostics must instead read the facility rate directly and retain
    # only its converged primal value.
    total_rate = production_qoi_schema4_primal(
        facility_surface_mass_rate_for_well(
            facility_model,
            well,
            facility_state;
            effective = true
        )
    )
    active_control =
        facility_state[:WellGroupConfiguration].operating_controls[well]
    gas = phase_indices(well_model.system).v
    if iszero(total_rate)
        co2_rate = 0.0
    else
        mixture = production_qoi_schema4_surface_mixture(
            active_control,
            well_state
        )
        co2_rate = total_rate*mixture[gas]
    end
    requested_control = production_qoi_schema4_requested_control(forces, well)
    return (
        actual_co2_rate_kg_s = co2_rate,
        total_mass_rate_kg_s = total_rate,
        bhp_pa = production_qoi_schema4_primal(well_state[:Pressure][1]),
        requested = production_qoi_schema4_control_descriptor(
            requested_control,
            well_model
        ),
        active = production_qoi_schema4_control_descriptor(
            active_control,
            well_model
        )
    )
end

function production_qoi_schema4_boundary_rate(rmodel, state, forces)
    haskey(forces, :Reservoir) || return 0.0
    reservoir_forces = forces[:Reservoir]
    isnothing(reservoir_forces) && return 0.0
    haskey(reservoir_forces, :bc) || return 0.0
    conditions = reservoir_forces[:bc]
    isnothing(conditions) && return 0.0
    gas = phase_indices(rmodel.system).v
    component_count = length(reference_densities(rmodel.system))
    mapping = global_map(rmodel)
    gas_rate = 0.0
    for condition in conditions
        qtotal = compute_bc_total_flux(condition, mapping, state)
        component_rate = fill(zero(qtotal), component_count)
        apply_flow_bc!(
            component_rate,
            qtotal,
            condition,
            rmodel,
            state,
            NaN
        )
        gas_rate += production_qoi_schema4_primal(component_rate[gas])
    end
    isfinite(gas_rate) || error("Schema-4 boundary CO2 rate is non-finite.")
    return gas_rate
end

function production_qoi_schema4_interface_rates(context, extension, state, rmodel)
    neighbors = production_qoi_neighbors(rmodel, length(context.atomic_code))
    nfaces = length(extension.selected_faces)
    rates = zeros(Float64, nfaces, 3)
    @inbounds for (slot, face32) in enumerate(extension.selected_faces)
        face = Int(face32)
        left = neighbors[1, face]
        right = neighbors[2, face]
        free, dissolved, total = production_qoi_face_co2_flux(
            face,
            left,
            right,
            state,
            rmodel
        )
        rates[slot, 1] = production_qoi_schema4_primal(free)
        rates[slot, 2] = production_qoi_schema4_primal(dissolved)
        rates[slot, 3] = production_qoi_schema4_primal(total)
    end
    output = zeros(Float64, length(extension.interfaces), 3, 2)
    for (interface_index, interface) in enumerate(extension.interfaces)
        for index in eachindex(interface.faces)
            face = Int(interface.faces[index])
            slot = Int(extension.face_slot[face])
            sign = Float64(interface.signs[index])
            for component in 1:3
                oriented = sign*rates[slot, component]
                output[interface_index, component, 1] += max(oriented, 0.0)
                output[interface_index, component, 2] += max(-oriented, 0.0)
            end
        end
    end
    return output
end

function production_qoi_schema4_integrate_interface_rates!(
        cumulative,
        rates,
        dt::Real
    )
    size(cumulative) == size(rates) || error(
        "Schema-4 cumulative/rate interface arrays have different shapes."
    )
    dt = Float64(dt)
    isfinite(dt) && dt > 0.0 || error(
        "Schema-4 interface integration requires a positive finite dt."
    )
    all(value -> isfinite(value) && value >= 0.0, rates) || error(
        "Schema-4 forward/reverse interface rates must be finite and non-negative."
    )
    cumulative .+= rates.*dt
    return cumulative
end

function production_qoi_schema4_mass_balance(
        initial_mass,
        domain_mass,
        injected,
        produced,
        boundary_out,
        boundary_in
    )
    expected = Float64(initial_mass) + Float64(injected) - Float64(produced) -
        Float64(boundary_out) + Float64(boundary_in)
    residual = Float64(domain_mass) - expected
    scale = max(abs(expected), abs(Float64(initial_mass)), 1.0)
    return (
        expected_domain_mass_kg = expected,
        residual_kg = residual,
        relative_residual = residual/scale
    )
end

"""
Accumulate quantities only after an adaptive ministep has converged. Failed
attempts never modify cumulative state, and restart reconciliation restores the
last committed report boundary before any continuation ministeps run.
"""
function production_qoi_schema4_accept_ministep!(
        context::ProductionQoIContext,
        sim,
        dt::Real,
        forces
    )
    extension = context.schema4
    production_qoi_schema4_active(extension) || return nothing
    dt = Float64(dt)
    isfinite(dt) && dt > 0.0 || error(
        "Schema-4 accepted ministep has invalid dt=$dt."
    )
    started = time_ns()
    states, reservoir_state, rmodel =
        production_qoi_schema4_current_states(sim)
    model = Jutul.get_simulator_model(sim)

    well = production_qoi_schema4_well_accounting(
        context,
        states,
        model,
        forces
    )
    extension.cumulative_injected_co2_kg +=
        max(well.actual_co2_rate_kg_s, 0.0)*dt
    extension.cumulative_produced_co2_kg +=
        max(-well.actual_co2_rate_kg_s, 0.0)*dt
    extension.last_actual_co2_rate_kg_s = well.actual_co2_rate_kg_s
    extension.last_total_well_mass_rate_kg_s = well.total_mass_rate_kg_s
    extension.last_bhp_pa = well.bhp_pa
    extension.last_requested_control = well.requested.name
    extension.last_requested_target_value = well.requested.target_value
    extension.last_requested_target_unit = well.requested.target_unit
    extension.last_requested_target_co2_rate_kg_s =
        well.requested.target_co2_rate_kg_s
    extension.last_active_control = well.active.name
    extension.last_active_target_value = well.active.target_value
    extension.last_active_target_unit = well.active.target_unit
    extension.last_active_target_co2_rate_kg_s =
        well.active.target_co2_rate_kg_s
    if !isempty(extension.previous_active_control) &&
            extension.previous_active_control != well.active.name
        extension.control_switch_count += 1
    end
    extension.previous_active_control = well.active.name

    boundary_rate = production_qoi_schema4_boundary_rate(
        rmodel,
        reservoir_state,
        forces
    )
    extension.cumulative_boundary_out_kg += max(boundary_rate, 0.0)*dt
    extension.cumulative_boundary_in_kg += max(-boundary_rate, 0.0)*dt

    rates = production_qoi_schema4_interface_rates(
        context,
        extension,
        reservoir_state,
        rmodel
    )
    production_qoi_schema4_integrate_interface_rates!(
        extension.cumulative_interface_kg,
        rates,
        dt
    )
    extension.accepted_ministep_count += 1
    extension.accepted_seconds += dt
    extension.ministep_accounting_seconds += (time_ns() - started)/1.0e9
    return nothing
end

function production_qoi_schema4_install_hook!(config, context)
    extension = context.schema4
    production_qoi_schema4_active(extension) || return config
    previous = config[:post_ministep_hook]
    config[:post_ministep_hook] = function (
            done,
            report,
            sim,
            dt,
            forces,
            max_iter,
            cfg
        )
        accepted = done
        updated_report = report
        if !ismissing(previous)
            result = previous(
                done,
                report,
                sim,
                dt,
                forces,
                max_iter,
                cfg
            )
            result isa Tuple && length(result) == 2 || error(
                "Existing post_ministep_hook did not return (done, report)."
            )
            accepted, updated_report = result
        end
        accepted && production_qoi_schema4_accept_ministep!(
            context,
            sim,
            dt,
            forces
        )
        return accepted, updated_report
    end
    return config
end

function production_qoi_schema4_spatial_snapshot(context, state)
    extension = context.schema4
    arrays = production_qoi_state_arrays(state, length(context.atomic_code))
    isnothing(arrays.capillary_pressure) && error(
        "Schema-4 fault history requires dynamic CapillaryPressure."
    )
    fault = zeros(
        Float64,
        length(extension.fault_groups),
        length(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS)
    )
    for (group_index, cells32) in enumerate(extension.fault_groups)
        pv_total = extension.fault_group_pore_volume[group_index]
        for cell32 in cells32
            cell = Int(cell32)
            weight = context.pore_volume[cell]/pv_total
            sg = max(Float64(arrays.sg[cell]), 0.0)
            sw = max(Float64(arrays.sw[cell]), 0.0)
            fv = Float64(arrays.fluid_volume[cell])
            rho_g = Float64(arrays.gas_density[cell])
            historical_sg = isnothing(arrays.max_gas_saturation) ?
                sg : Float64(arrays.max_gas_saturation[cell])
            free = sg*fv*rho_g
            dissolved = sw*fv*Float64(arrays.rs[cell])*
                Float64(arrays.bo[cell])*rho_g/Float64(arrays.bg[cell])
            fault[group_index, 1] += weight*Float64(arrays.pressure[cell])
            fault[group_index, 2] +=
                weight*Float64(arrays.capillary_pressure[cell])
            fault[group_index, 3] += weight*sg
            fault[group_index, 4] += weight*historical_sg
            fault[group_index, 5] += weight*Float64(arrays.rs[cell])
            fault[group_index, 6] += free
            fault[group_index, 7] += dissolved
        end
    end

    leakage = zeros(
        Float64,
        length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS),
        PRODUCTION_QOI_SCHEMA4_SLICES,
        length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS)
    )
    leakage[:, :, 3] .= -Inf
    for index in eachindex(extension.leakage_cells)
        cell = Int(extension.leakage_cells[index])
        region = Int(extension.leakage_region[index])
        slice = Int(extension.leakage_slice[index])
        sg = max(Float64(arrays.sg[cell]), 0.0)
        sw = max(Float64(arrays.sw[cell]), 0.0)
        fv = Float64(arrays.fluid_volume[cell])
        rho_g = Float64(arrays.gas_density[cell])
        leakage[region, slice, 1] += sg*fv*rho_g
        leakage[region, slice, 2] += sw*fv*Float64(arrays.rs[cell])*
            Float64(arrays.bo[cell])*rho_g/Float64(arrays.bg[cell])
        leakage[region, slice, 3] = max(
            leakage[region, slice, 3],
            sg
        )
    end
    all(isfinite, fault) || error("Schema-4 fault snapshot is non-finite.")
    all(isfinite, leakage) || error("Schema-4 leakage snapshot is non-finite.")
    return fault, leakage
end

function production_qoi_schema4_write_float64(io, value::Real)
    write(io, htol(reinterpret(UInt64, Float64(value))))
end

function production_qoi_schema4_read_float64(io)
    return reinterpret(Float64, ltoh(read(io, UInt64)))
end

function production_qoi_schema4_write_binary(path, step, fault, leakage)
    size(fault) == (
        PRODUCTION_QOI_SCHEMA4_WINDOWS*PRODUCTION_QOI_SCHEMA4_SLICES,
        length(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS)
    ) || error("Schema-4 fault binary array has the wrong shape.")
    size(leakage) == (
        length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS),
        PRODUCTION_QOI_SCHEMA4_SLICES,
        length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS)
    ) || error("Schema-4 leakage binary array has the wrong shape.")
    production_atomic_write(path) do io
        write(io, PRODUCTION_QOI_SCHEMA4_MAGIC)
        for value in (
                PRODUCTION_QOI_SCHEMA4_VERSION,
                Int(step),
                PRODUCTION_QOI_SCHEMA4_WINDOWS,
                PRODUCTION_QOI_SCHEMA4_SLICES,
                length(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS),
                length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS),
                length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS)
            )
            write(io, htol(UInt32(value)))
        end
        for value in fault
            production_qoi_schema4_write_float64(io, value)
        end
        for value in leakage
            production_qoi_schema4_write_float64(io, value)
        end
    end
    return path
end

function production_qoi_schema4_expected_binary_bytes()
    header = length(PRODUCTION_QOI_SCHEMA4_MAGIC) + 7*sizeof(UInt32)
    fault = PRODUCTION_QOI_SCHEMA4_WINDOWS*
        PRODUCTION_QOI_SCHEMA4_SLICES*
        length(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS)*sizeof(Float64)
    leakage = length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS)*
        PRODUCTION_QOI_SCHEMA4_SLICES*
        length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS)*sizeof(Float64)
    return header + fault + leakage
end

function production_qoi_schema4_read_binary(path)
    filesize(path) == production_qoi_schema4_expected_binary_bytes() || error(
        "Schema-4 spatial binary $path has $(filesize(path)) bytes; expected " *
        "$(production_qoi_schema4_expected_binary_bytes())."
    )
    open(path, "r") do io
        read(io, length(PRODUCTION_QOI_SCHEMA4_MAGIC)) ==
            PRODUCTION_QOI_SCHEMA4_MAGIC || error(
                "Schema-4 spatial binary $path has invalid magic bytes."
            )
        values = Int[ltoh(read(io, UInt32)) for _ in 1:7]
        schema, step, nw, ns, nf, nr, nl = values
        schema == PRODUCTION_QOI_SCHEMA4_VERSION || error(
            "Schema-4 spatial binary $path has schema $schema."
        )
        (nw, ns, nf, nr, nl) == (
            PRODUCTION_QOI_SCHEMA4_WINDOWS,
            PRODUCTION_QOI_SCHEMA4_SLICES,
            length(PRODUCTION_QOI_SCHEMA4_FAULT_FIELDS),
            length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_REGIONS),
            length(PRODUCTION_QOI_SCHEMA4_LEAKAGE_FIELDS)
        ) || error("Schema-4 spatial binary $path has invalid dimensions.")
        fault = Array{Float64}(undef, nw*ns, nf)
        leakage = Array{Float64}(undef, nr, ns, nl)
        for index in eachindex(fault)
            fault[index] = production_qoi_schema4_read_float64(io)
        end
        for index in eachindex(leakage)
            leakage[index] = production_qoi_schema4_read_float64(io)
        end
        eof(io) || error("Schema-4 spatial binary $path has trailing bytes.")
        all(isfinite, fault) && all(isfinite, leakage) || error(
            "Schema-4 spatial binary $path contains non-finite values."
        )
        return (step = step, fault = fault, leakage = leakage)
    end
end

function production_qoi_schema4_migration(context, state)
    extension = context.schema4
    arrays = production_qoi_state_arrays(state, length(context.atomic_code))
    thresholds = PRODUCTION_QOI_SG_THRESHOLDS
    count_thresholds = length(thresholds)
    highest_domain = fill(-Inf, count_thresholds)
    highest_fault = fill(-Inf, count_thresholds)
    highest_window = zeros(Int, count_thresholds)
    highest_stratigraphic = fill(-Inf, count_thresholds)
    highest_stratigraphic_unit = zeros(Int, count_thresholds)
    highest_stratigraphic_side = zeros(Int, count_thresholds)

    # One full-grid pass serves all thresholds. This avoids three repeated
    # scans of the 2.1-million-cell production grid at every report boundary.
    @inbounds for cell in eachindex(context.atomic_code)
        sg = Float64(arrays.sg[cell])
        elevation = -context.centroids[3, cell]
        unit = Int(extension.stratigraphic_unit[cell])
        side = Int(extension.stratigraphic_side[cell])
        for threshold_index in eachindex(thresholds)
            sg >= thresholds[threshold_index] || continue
            highest_domain[threshold_index] = max(
                highest_domain[threshold_index],
                elevation
            )
            if unit > 0 &&
                    elevation > highest_stratigraphic[threshold_index]
                highest_stratigraphic[threshold_index] = elevation
                highest_stratigraphic_unit[threshold_index] = unit
                highest_stratigraphic_side[threshold_index] = side
            end
        end
    end

    # Fault groups are much smaller than the full grid. Scan each group once
    # to recover both the highest reached fault elevation and window.
    for window in 1:PRODUCTION_QOI_SCHEMA4_WINDOWS
        for slice in 1:PRODUCTION_QOI_SCHEMA4_SLICES
            group = (window - 1)*PRODUCTION_QOI_SCHEMA4_SLICES + slice
            @inbounds for cell32 in extension.fault_groups[group]
                cell = Int(cell32)
                sg = Float64(arrays.sg[cell])
                elevation = -context.centroids[3, cell]
                for threshold_index in eachindex(thresholds)
                    sg >= thresholds[threshold_index] || continue
                    highest_fault[threshold_index] = max(
                        highest_fault[threshold_index],
                        elevation
                    )
                    highest_window[threshold_index] = window
                end
            end
        end
    end
    return [
        (
            threshold = thresholds[index],
            highest_domain_elevation_m = isfinite(highest_domain[index]) ?
                highest_domain[index] : NaN,
            highest_fault_elevation_m = isfinite(highest_fault[index]) ?
                highest_fault[index] : NaN,
            highest_fault_window = highest_window[index],
            highest_stratigraphic_elevation_m =
                isfinite(highest_stratigraphic[index]) ?
                    highest_stratigraphic[index] : NaN,
            highest_stratigraphic_unit =
                highest_stratigraphic_unit[index],
            highest_stratigraphic_side =
                highest_stratigraphic_side[index]
        ) for index in eachindex(thresholds)
    ]
end

function production_qoi_schema4_threshold_suffix(threshold)
    if threshold == 1.0e-4
        return "sg_1e_4"
    elseif threshold == 1.0e-3
        return "sg_1e_3"
    elseif threshold == 1.0e-2
        return "sg_1e_2"
    end
    error("Unsupported schema-4 migration threshold $threshold.")
end

function production_qoi_schema4_report_row(
        context,
        step,
        seconds,
        state,
        spatial_path,
        spatial_evaluation_seconds
    )
    extension = context.schema4
    domain_mass = production_qoi_domain_total_mass(state)
    boundary_net = extension.cumulative_boundary_out_kg -
        extension.cumulative_boundary_in_kg
    balance = production_qoi_schema4_mass_balance(
        context.initial_total_co2_mass_kg,
        domain_mass,
        extension.cumulative_injected_co2_kg,
        extension.cumulative_produced_co2_kg,
        extension.cumulative_boundary_out_kg,
        extension.cumulative_boundary_in_kg
    )
    entries = Pair{Symbol, Any}[
        :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
        :base_qoi_schema_version => PRODUCTION_QOI_SCHEMA_VERSION,
        :case_key => context.case_key,
        :campaign_manifest_sha256 => context.campaign_manifest_sha256,
        :step => Int(step),
        :time_seconds => Float64(seconds),
        :time_years => Float64(seconds)/MRST_YEAR_SECONDS,
        :accepted_ministep_count => extension.accepted_ministep_count,
        :accepted_seconds => extension.accepted_seconds,
        :actual_co2_rate_kg_s => extension.last_actual_co2_rate_kg_s,
        :total_well_mass_rate_kg_s =>
            extension.last_total_well_mass_rate_kg_s,
        :injector_bhp_pa => extension.last_bhp_pa,
        :requested_control => extension.last_requested_control,
        :requested_target_value => extension.last_requested_target_value,
        :requested_target_unit => extension.last_requested_target_unit,
        :requested_target_co2_rate_kg_s =>
            extension.last_requested_target_co2_rate_kg_s,
        :active_control => extension.last_active_control,
        :active_target_value => extension.last_active_target_value,
        :active_target_unit => extension.last_active_target_unit,
        :active_target_co2_rate_kg_s =>
            extension.last_active_target_co2_rate_kg_s,
        :control_switch_count => extension.control_switch_count,
        :cumulative_injected_co2_kg => extension.cumulative_injected_co2_kg,
        :cumulative_produced_co2_kg => extension.cumulative_produced_co2_kg,
        :cumulative_boundary_out_co2_kg =>
            extension.cumulative_boundary_out_kg,
        :cumulative_boundary_in_co2_kg =>
            extension.cumulative_boundary_in_kg,
        :cumulative_boundary_net_out_co2_kg => boundary_net,
        :domain_co2_mass_kg => domain_mass,
        :expected_domain_co2_mass_kg => balance.expected_domain_mass_kg,
        :mass_balance_residual_kg => balance.residual_kg,
        :mass_balance_relative_residual => balance.relative_residual,
        :mapping_sha256 => extension.mapping_sha256,
        :provenance_manifest_sha256 =>
            extension.provenance_manifest_sha256,
        :realization_manifest_sha256 =>
            extension.realization_manifest_sha256,
        :spatial_binary_file => basename(spatial_path),
        :spatial_binary_bytes => filesize(spatial_path),
        :spatial_binary_sha256 => production_qoi_file_sha256(spatial_path),
        :ministep_accounting_seconds =>
            extension.ministep_accounting_seconds,
        :spatial_evaluation_seconds => Float64(spatial_evaluation_seconds)
    ]
    for (interface_index, interface) in enumerate(extension.interfaces)
        for (component_index, component) in enumerate(("free", "dissolved", "total"))
            forward = extension.cumulative_interface_kg[
                interface_index,
                component_index,
                1
            ]
            reverse = extension.cumulative_interface_kg[
                interface_index,
                component_index,
                2
            ]
            prefix = "cumulative_" * interface.id * "_" * component
            push!(entries, Symbol(prefix * "_forward_kg") => forward)
            push!(entries, Symbol(prefix * "_reverse_kg") => reverse)
            push!(entries, Symbol(prefix * "_net_kg") => forward - reverse)
        end
    end
    for migration in production_qoi_schema4_migration(context, state)
        suffix = production_qoi_schema4_threshold_suffix(migration.threshold)
        push!(entries, Symbol("highest_domain_elevation_m_" * suffix) =>
            migration.highest_domain_elevation_m)
        push!(entries, Symbol("highest_fault_elevation_m_" * suffix) =>
            migration.highest_fault_elevation_m)
        push!(entries, Symbol("highest_fault_window_" * suffix) =>
            migration.highest_fault_window)
        push!(entries, Symbol("highest_stratigraphic_elevation_m_" * suffix) =>
            migration.highest_stratigraphic_elevation_m)
        push!(entries, Symbol("highest_stratigraphic_unit_" * suffix) =>
            migration.highest_stratigraphic_unit)
        push!(entries, Symbol("highest_stratigraphic_side_" * suffix) =>
            migration.highest_stratigraphic_side)
    end
    return (; entries...)
end

function production_qoi_schema4_validate_row(context, path, step)
    row = production_read_named_row(path)
    parse(Int, row["schema_version"]) == PRODUCTION_QOI_SCHEMA4_VERSION ||
        error("Schema-4 row $step has an unsupported schema.")
    parse(Int, row["step"]) == step || error(
        "Schema-4 row $step contains the wrong report step."
    )
    row["case_key"] == context.case_key || error(
        "Schema-4 row $step has the wrong case key."
    )
    row["mapping_sha256"] == context.schema4.mapping_sha256 || error(
        "Schema-4 row $step has the wrong spatial mapping hash."
    )
    spatial_path = production_qoi_schema4_spatial_row_path(context.schema4, step)
    if dirname(path) == context.schema4.ready_dir
        spatial_path = production_qoi_schema4_spatial_ready_path(
            context.schema4,
            step
        )
    end
    isfile(spatial_path) || error(
        "Schema-4 row $step is missing its spatial binary."
    )
    parsed = production_qoi_schema4_read_binary(spatial_path)
    parsed.step == step || error(
        "Schema-4 spatial binary contains step $(parsed.step), expected $step."
    )
    parse(Int, row["spatial_binary_bytes"]) == filesize(spatial_path) ||
        error("Schema-4 row $step has the wrong spatial byte count.")
    row["spatial_binary_sha256"] == production_qoi_file_sha256(spatial_path) ||
        error("Schema-4 row $step has the wrong spatial SHA-256.")
    for key in (
            "cumulative_injected_co2_kg",
            "cumulative_produced_co2_kg",
            "cumulative_boundary_out_co2_kg",
            "cumulative_boundary_in_co2_kg",
            "domain_co2_mass_kg",
            "expected_domain_co2_mass_kg",
            "mass_balance_residual_kg",
            "mass_balance_relative_residual"
        )
        isfinite(parse(Float64, row[key])) || error(
            "Schema-4 row $step has non-finite $key."
        )
    end
    return row
end

function production_stage_qoi_schema4!(
        context::ProductionQoIContext,
        step::Integer,
        seconds::Real,
        sim
    )
    extension = context.schema4
    production_qoi_schema4_active(extension) || return nothing
    ready_path = production_qoi_schema4_ready_path(extension, step)
    spatial_path = production_qoi_schema4_spatial_ready_path(extension, step)
    for path in (
            ready_path,
            spatial_path,
            production_qoi_schema4_row_path(extension, step),
            production_qoi_schema4_spatial_row_path(extension, step)
        )
        !isfile(path) || error(
            "Schema-4 report artifact already exists for step $step: $path"
        )
    end
    tolerance = max(1.0e-6, 1.0e-10*abs(Float64(seconds)))
    abs(extension.accepted_seconds - Float64(seconds)) <= tolerance || error(
        "Schema-4 accepted-ministep time $(extension.accepted_seconds) does " *
        "not match report time $(Float64(seconds))."
    )
    state = production_qoi_full_reservoir_state(sim)
    started = time_ns()
    fault, leakage = production_qoi_schema4_spatial_snapshot(context, state)
    production_qoi_schema4_write_binary(
        spatial_path,
        step,
        fault,
        leakage
    )
    spatial_elapsed = (time_ns() - started)/1.0e9
    row = production_qoi_schema4_report_row(
        context,
        step,
        seconds,
        state,
        spatial_path,
        spatial_elapsed
    )
    production_write_named_row(ready_path, row)
    production_qoi_schema4_validate_row(context, ready_path, step)
    return ready_path, spatial_path
end

function production_commit_qoi_schema4!(context::ProductionQoIContext, step::Integer)
    extension = context.schema4
    production_qoi_schema4_active(extension) || return nothing
    ready = production_qoi_schema4_ready_path(extension, step)
    spatial_ready = production_qoi_schema4_spatial_ready_path(extension, step)
    row = production_qoi_schema4_row_path(extension, step)
    spatial_row = production_qoi_schema4_spatial_row_path(extension, step)
    isfile(ready) && isfile(spatial_ready) || error(
        "Schema-4 staged artifacts are incomplete for step $step."
    )
    !isfile(row) && !isfile(spatial_row) || error(
        "Schema-4 artifacts are already committed for step $step."
    )
    production_qoi_schema4_validate_row(context, ready, step)
    mv(spatial_ready, spatial_row; force = false)
    mv(ready, row; force = false)
    production_qoi_schema4_validate_row(context, row, step)
    return row, spatial_row
end

production_qoi_schema4_row_indices(extension) = production_scan_indices(
    extension.row_dir,
    PRODUCTION_QOI_SCHEMA4_ROW_PATTERN
)
production_qoi_schema4_ready_indices(extension) = production_scan_indices(
    extension.ready_dir,
    PRODUCTION_QOI_SCHEMA4_ROW_PATTERN
)
production_qoi_schema4_spatial_row_indices(extension) = production_scan_indices(
    extension.spatial_row_dir,
    PRODUCTION_QOI_SCHEMA4_BINARY_PATTERN
)
production_qoi_schema4_spatial_ready_indices(extension) = production_scan_indices(
    extension.spatial_ready_dir,
    PRODUCTION_QOI_SCHEMA4_BINARY_PATTERN
)

function production_qoi_schema4_restore!(context, row)
    extension = context.schema4
    extension.cumulative_injected_co2_kg =
        parse(Float64, row["cumulative_injected_co2_kg"])
    extension.cumulative_produced_co2_kg =
        parse(Float64, row["cumulative_produced_co2_kg"])
    extension.cumulative_boundary_out_kg =
        parse(Float64, row["cumulative_boundary_out_co2_kg"])
    extension.cumulative_boundary_in_kg =
        parse(Float64, row["cumulative_boundary_in_co2_kg"])
    extension.accepted_ministep_count =
        parse(Int, row["accepted_ministep_count"])
    extension.accepted_seconds = parse(Float64, row["accepted_seconds"])
    extension.control_switch_count = parse(Int, row["control_switch_count"])
    extension.previous_active_control = row["active_control"]
    extension.last_actual_co2_rate_kg_s =
        parse(Float64, row["actual_co2_rate_kg_s"])
    extension.last_total_well_mass_rate_kg_s =
        parse(Float64, row["total_well_mass_rate_kg_s"])
    extension.last_bhp_pa = parse(Float64, row["injector_bhp_pa"])
    extension.last_requested_control = row["requested_control"]
    extension.last_requested_target_value =
        parse(Float64, row["requested_target_value"])
    extension.last_requested_target_unit = row["requested_target_unit"]
    extension.last_requested_target_co2_rate_kg_s =
        parse(Float64, row["requested_target_co2_rate_kg_s"])
    extension.last_active_control = row["active_control"]
    extension.last_active_target_value =
        parse(Float64, row["active_target_value"])
    extension.last_active_target_unit = row["active_target_unit"]
    extension.last_active_target_co2_rate_kg_s =
        parse(Float64, row["active_target_co2_rate_kg_s"])
    extension.ministep_accounting_seconds =
        parse(Float64, row["ministep_accounting_seconds"])
    for (interface_index, interface) in enumerate(extension.interfaces)
        for (component_index, component) in enumerate(("free", "dissolved", "total"))
            prefix = "cumulative_" * interface.id * "_" * component
            extension.cumulative_interface_kg[
                interface_index,
                component_index,
                1
            ] = parse(Float64, row[prefix * "_forward_kg"])
            extension.cumulative_interface_kg[
                interface_index,
                component_index,
                2
            ] = parse(Float64, row[prefix * "_reverse_kg"])
        end
    end
    return extension
end

function production_reconcile_qoi_schema4!(
        context::ProductionQoIContext,
        policy,
        previous_step::Integer
    )
    extension = context.schema4
    production_qoi_schema4_active(extension) || return nothing
    steps = sort!(unique!(vcat(
        production_qoi_schema4_ready_indices(extension),
        production_qoi_schema4_spatial_ready_indices(extension),
        production_qoi_schema4_row_indices(extension),
        production_qoi_schema4_spatial_row_indices(extension)
    )))
    for step in steps
        scalar_path = production_qoi_schema4_ready_path(extension, step)
        spatial_path = production_qoi_schema4_spatial_ready_path(extension, step)
        row_path = production_qoi_schema4_row_path(extension, step)
        spatial_row_path = production_qoi_schema4_spatial_row_path(extension, step)
        scalar_ready = isfile(scalar_path)
        spatial_ready = isfile(spatial_path)
        scalar_committed = isfile(row_path)
        spatial_committed = isfile(spatial_row_path)
        if step == previous_step && scalar_ready && spatial_ready &&
                !scalar_committed && !spatial_committed
            isfile(production_restart_path(policy, step)) || error(
                "Staged schema-4 step $step has no validated restart checkpoint."
            )
            production_commit_qoi_schema4!(context, step)
        elseif step == previous_step && scalar_ready && !spatial_ready &&
                !scalar_committed && spatial_committed
            # Normal commit moves the spatial binary first. This is the only
            # valid partially committed state if the process stops between
            # the two atomic renames.
            isfile(production_restart_path(policy, step)) || error(
                "Partially committed schema-4 step $step has no restart checkpoint."
            )
            mv(scalar_path, row_path; force = false)
            production_qoi_schema4_validate_row(context, row_path, step)
        elseif step <= previous_step && scalar_committed && spatial_committed
            scalar_ready && production_quarantine!(
                policy,
                scalar_path,
                "Duplicate staged schema-4 scalar for committed step $step."
            )
            spatial_ready && production_quarantine!(
                policy,
                spatial_path,
                "Duplicate staged schema-4 spatial binary for committed step $step."
            )
        elseif step <= previous_step &&
                !(scalar_committed && spatial_committed)
            error(
                "Historical schema-4 step $step has an unsafe scalar/spatial " *
                "artifact combination."
            )
        else
            for path in (scalar_path, spatial_path, row_path, spatial_row_path)
                isfile(path) || continue
                production_quarantine!(
                    policy,
                    path,
                    "Schema-4 artifact is newer than selected restart $previous_step."
                )
            end
        end
    end

    observed = production_qoi_schema4_row_indices(extension)
    spatial_observed = production_qoi_schema4_spatial_row_indices(extension)
    observed == spatial_observed || error(
        "Schema-4 committed scalar/spatial step sets differ after reconciliation."
    )
    expected = collect(1:previous_step)
    observed == expected || error(
        "Committed schema-4 prefix is $(join(observed, ",")); expected " *
        "$(join(expected, ","))."
    )
    previous_injected = -Inf
    previous_produced = -Inf
    previous_boundary_out = -Inf
    previous_boundary_in = -Inf
    last_row = nothing
    for step in expected
        row = production_qoi_schema4_validate_row(
            context,
            production_qoi_schema4_row_path(extension, step),
            step
        )
        injected = parse(Float64, row["cumulative_injected_co2_kg"])
        produced = parse(Float64, row["cumulative_produced_co2_kg"])
        boundary_out = parse(Float64, row["cumulative_boundary_out_co2_kg"])
        boundary_in = parse(Float64, row["cumulative_boundary_in_co2_kg"])
        injected >= previous_injected && produced >= previous_produced &&
            boundary_out >= previous_boundary_out && boundary_in >= previous_boundary_in ||
            error("Schema-4 cumulative accounting decreases at step $step.")
        previous_injected = injected
        previous_produced = produced
        previous_boundary_out = boundary_out
        previous_boundary_in = boundary_in
        last_row = row
    end
    !isnothing(last_row) && production_qoi_schema4_restore!(context, last_row)
    return nothing
end

function production_consolidate_qoi_schema4!(
        context::ProductionQoIContext;
        require_complete::Bool = false,
        final_schedule_step::Integer = 0
    )
    extension = context.schema4
    production_qoi_schema4_active(extension) || return nothing
    indices = production_qoi_schema4_row_indices(extension)
    isempty(indices) && return nothing
    expected_latest = require_complete ? final_schedule_step : maximum(indices)
    indices == collect(1:expected_latest) || error(
        "Schema-4 output is not a complete prefix through $expected_latest."
    )
    destination = joinpath(extension.root_dir, "qoi_schema4_steps.tsv")
    production_atomic_write(destination) do io
        first_lines = readlines(production_qoi_schema4_row_path(extension, 1))
        println(io, first_lines[1])
        println(io, first_lines[2])
        for step in 2:expected_latest
            lines = readlines(production_qoi_schema4_row_path(extension, step))
            lines[1] == first_lines[1] || error(
                "Schema-4 scalar header changed at step $step."
            )
            println(io, lines[2])
        end
    end

    index_rows = Dict{Symbol, Any}[]
    total_spatial_bytes = 0
    for step in 1:expected_latest
        scalar = production_qoi_schema4_validate_row(
            context,
            production_qoi_schema4_row_path(extension, step),
            step
        )
        spatial_path = production_qoi_schema4_spatial_row_path(extension, step)
        bytes = filesize(spatial_path)
        total_spatial_bytes += bytes
        push!(index_rows, Dict{Symbol, Any}(
            :schema_version => PRODUCTION_QOI_SCHEMA4_VERSION,
            :step => step,
            :time_seconds => parse(Float64, scalar["time_seconds"]),
            :relative_path => relpath(spatial_path, extension.root_dir),
            :bytes => bytes,
            :sha256 => production_qoi_file_sha256(spatial_path)
        ))
    end
    production_qoi_write_table(
        joinpath(extension.root_dir, "spatial_history_index.tsv"),
        Symbol[:schema_version, :step, :time_seconds, :relative_path, :bytes, :sha256],
        index_rows
    )
    if require_complete
        payload_bytes = sum(
            filesize(joinpath(directory, name))
            for (directory, _, files) in walkdir(extension.root_dir)
            for name in files
            if name != "QOI_SCHEMA4_COMPLETE.tsv"
        )
        storage_budget_bytes = 10*1024*1024
        payload_bytes <= storage_budget_bytes || error(
            "Schema-4 payload is $(payload_bytes/1.0e6) MB, exceeding the " *
            "10 MiB per-case production budget."
        )
        marker = (
            schema_version = PRODUCTION_QOI_SCHEMA4_VERSION,
            status = "complete",
            case_key = context.case_key,
            schedule_steps = final_schedule_step,
            expected_spatial_bytes_per_step =
                production_qoi_schema4_expected_binary_bytes(),
            total_spatial_bytes = total_spatial_bytes,
            consolidated_scalar_bytes = filesize(destination),
            payload_bytes_before_completion_marker = payload_bytes,
            storage_budget_bytes = storage_budget_bytes,
            storage_budget_passed = true,
            mapping_sha256 = extension.mapping_sha256,
            provenance_manifest_sha256 =
                extension.provenance_manifest_sha256,
            realization_manifest_sha256 =
                extension.realization_manifest_sha256,
            accepted_ministep_count = extension.accepted_ministep_count,
            ministep_accounting_seconds =
                extension.ministep_accounting_seconds,
            completed_utc = string(Dates.now(Dates.UTC))
        )
        production_write_named_row(
            joinpath(extension.root_dir, "QOI_SCHEMA4_COMPLETE.tsv"),
            marker
        )
    end
    return destination
end
