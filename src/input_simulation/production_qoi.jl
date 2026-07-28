const PRODUCTION_QOI_SCHEMA_VERSION = 1
const PRODUCTION_QOI_ROW_PATTERN = r"^step_(\d{6})\.tsv$"
const PRODUCTION_QOI_SG_THRESHOLDS = (1.0e-4, 1.0e-3, 1.0e-2)
const PRODUCTION_QOI_FLUX_METHOD =
    "report_endpoint_instantaneous_blackoil_component_mass_flux"

"""
One immutable accounting region. `atomic_codes` refers to the disjoint
cell-level partition in `ProductionQoIContext.atomic_code`. Aggregate regions
are exact unions of atomic regions; no coordinate boxes or SATNUM inference is
used.
"""
struct ProductionQoIRegion
    id::String
    label::String
    role::String
    atomic_codes::Vector{UInt8}
    source_ucid_ids::String
    facies::String
    definition::String
end

"""
An oriented set of simulator-internal faces. A positive reported flux is from
`from_region_id` to `to_region_id`. `signs[i]` converts Jutul's N[1]→N[2]
orientation for `faces[i]` into that semantic orientation.
"""
struct ProductionQoIInterface
    id::String
    label::String
    from_region_id::String
    to_region_id::String
    role::String
    faces::Vector{Int32}
    signs::Vector{Int8}
    definition::String
end

mutable struct ProductionQoIContext
    mode::String
    summary_dir::String
    ready_dir::String
    row_dir::String
    case_key::String
    campaign_manifest_sha256::String
    atomic_code::Vector{UInt8}
    atomic_regions::Vector{ProductionQoIRegion}
    regions::Vector{ProductionQoIRegion}
    region_index::Dict{String, Int}
    interfaces::Vector{ProductionQoIInterface}
    interface_faces::Vector{Int32}
    interface_face_slot::Vector{Int32}
    initial_pressure::Vector{Float64}
    pore_volume::Vector{Float64}
    centroids::Matrix{Float64}
    gas_critical_saturation::Vector{Float64}
    initial_atomic_total_co2_mass_kg::Vector{Float64}
    initial_total_co2_mass_kg::Float64
    primary_label_sha256::String
    region_manifest_sha256::String
    interface_manifest_sha256::String
    injector_name::String
end

production_qoi_active(::Nothing) = false
production_qoi_active(context::ProductionQoIContext) = context.mode != "off"

production_qoi_ready_path(context::ProductionQoIContext, step::Integer) =
    joinpath(context.ready_dir, @sprintf("step_%06d.tsv", step))

production_qoi_row_path(context::ProductionQoIContext, step::Integer) =
    joinpath(context.row_dir, @sprintf("step_%06d.tsv", step))

function production_qoi_normalize_mode(mode)
    value = lowercase(strip(String(mode)))
    value in ("off", "auto", "required") || error(
        "Unknown PRODUCTION_QOI_MODE=$mode. Valid values are off, auto, required."
    )
    return value
end

function production_qoi_vec(data, key::AbstractString; length_expected = nothing)
    haskey(data, key) || error("QoI metadata is missing $key.")
    values = vec(data[key])
    if !isnothing(length_expected)
        length(values) == length_expected || error(
            "QoI metadata $key has $(length(values)) values, expected " *
            "$length_expected."
        )
    end
    return values
end

production_qoi_scalar(value) =
    value isa AbstractArray ? only(vec(value)) : value

function production_qoi_integer_vec(
        data,
        key::AbstractString;
        length_expected = nothing,
        minimum = typemin(Int),
        maximum = typemax(Int)
    )
    values = production_qoi_vec(data, key; length_expected = length_expected)
    all(value -> value isa Real && isfinite(value) && isinteger(value) &&
        minimum <= value <= maximum, values) || error(
        "QoI metadata $key contains an invalid integer."
    )
    return Int.(values)
end

function production_qoi_float_vec(
        values,
        label::AbstractString;
        length_expected = nothing,
        positive::Bool = false
    )
    result = Float64.(vec(values))
    if !isnothing(length_expected)
        length(result) == length_expected || error(
            "$label has $(length(result)) values, expected $length_expected."
        )
    end
    all(isfinite, result) || error("$label contains a non-finite value.")
    if positive
        all(>(0.0), result) || error("$label must be strictly positive.")
    end
    return result
end

function production_qoi_centroids(mrst_data, nc::Integer)
    haskey(mrst_data, "G") && haskey(mrst_data["G"], "cells") &&
        haskey(mrst_data["G"]["cells"], "centroids") || error(
            "QoI output requires G.cells.centroids."
        )
    raw = Float64.(mrst_data["G"]["cells"]["centroids"])
    centroids = if size(raw, 1) == nc
        permutedims(raw)
    elseif size(raw, 2) == nc
        raw
    else
        error(
            "G.cells.centroids has shape $(size(raw)); one dimension must " *
            "equal the cell count $nc."
        )
    end
    size(centroids, 1) in (2, 3) || error(
        "QoI output supports only two- or three-dimensional centroids."
    )
    all(isfinite, centroids) ||
        error("G.cells.centroids contains a non-finite coordinate.")
    if size(centroids, 1) == 2
        centroids = vcat(centroids, zeros(1, nc))
    end
    return centroids
end

function production_qoi_pore_volume(mrst_data, nc::Integer)
    cells = mrst_data["G"]["cells"]
    haskey(cells, "volumes") ||
        error("QoI output requires G.cells.volumes.")
    volumes = production_qoi_float_vec(
        cells["volumes"],
        "G.cells.volumes";
        length_expected = nc,
        positive = true
    )
    porosity = production_qoi_float_vec(
        mrst_data["rock"]["poro"],
        "rock.poro";
        length_expected = nc
    )
    all(value -> 0.0 <= value <= 1.0, porosity) ||
        error("rock.poro is outside [0,1].")
    pore_volume = volumes .* porosity
    all(>=(0.0), pore_volume) ||
        error("QoI pore volume contains a negative value.")
    return pore_volume
end

function production_qoi_sha256_bytes(values)
    return bytes2hex(SHA.sha256(reinterpret(UInt8, values)))
end

function production_qoi_sha256_cell_ids(
        atomic_code::AbstractVector{UInt8},
        selected_codes::AbstractVector{UInt8}
    )
    selected = falses(256)
    for code in selected_codes
        selected[Int(code) + 1] = true
    end
    io = IOBuffer()
    @inbounds for cell in eachindex(atomic_code)
        if selected[Int(atomic_code[cell]) + 1]
            write(io, htol(Int64(cell)))
        end
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function production_qoi_sha256_faces(
        faces::AbstractVector{Int32},
        signs::AbstractVector{Int8}
    )
    length(faces) == length(signs) ||
        error("Cannot hash mismatched QoI face/sign arrays.")
    io = IOBuffer()
    for index in eachindex(faces)
        write(io, htol(Int64(faces[index])))
        write(io, signs[index])
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function production_qoi_injector_name(mrst_data)
    haskey(mrst_data, "schedule") || return ""
    schedule = mrst_data["schedule"]
    haskey(schedule, "control") || return ""
    controls = vec(schedule["control"])
    isempty(controls) && return ""
    haskey(controls[1], "W") || return ""
    for well in vec(controls[1]["W"])
        sign_value = haskey(well, "sign") ?
            production_qoi_scalar(well["sign"]) : 0
        if sign_value isa Real && sign_value > 0 && haskey(well, "name")
            return String(well["name"])
        end
    end
    return ""
end

function production_qoi_critical_saturation(rmodel, nc::Integer)
    relperm = rmodel[:RelativePermeabilities]
    relperm isa ReservoirRelativePermeabilities || error(
        "QoI mobile/immobile accounting requires ReservoirRelativePermeabilities."
    )
    krg = relperm.krg
    regions = relperm.regions
    use_imbibition = hysteresis_is_active(relperm)
    by_region = Dict{Int, Float64}()
    result = Vector{Float64}(undef, nc)
    @inbounds for cell in 1:nc
        reg = Int(region(regions, cell))
        critical = get!(by_region, reg) do
            table = use_imbibition ?
                imbibition_table_by_region(krg, reg) :
                table_by_region(krg, reg)
            value = Float64(table.critical)
            isfinite(value) && 0.0 <= value <= 1.0 || error(
                "Gas critical saturation for relative-permeability region " *
                "$reg is invalid: $value."
            )
            value
        end
        result[cell] = critical
    end
    return result
end

function production_qoi_neighbors(rmodel, nc::Integer)
    haskey(rmodel.data_domain, :neighbors, Faces()) || error(
        "QoI interface accounting requires simulator neighborship."
    )
    neighbors = Int.(rmodel.data_domain[:neighbors, Faces()])
    size(neighbors, 1) == 2 || error(
        "Simulator neighborship must be a 2×nface matrix."
    )
    all(cell -> 1 <= cell <= nc, neighbors) || error(
        "Simulator internal-face neighborship contains an invalid cell."
    )
    return neighbors
end

function production_qoi_add_aggregate!(
        regions,
        id,
        label,
        atomic_codes,
        definition;
        facies = "",
        source_ucid_ids = ""
    )
    codes = sort!(unique!(UInt8.(collect(atomic_codes))))
    isempty(codes) && error("QoI aggregate $id has no atomic regions.")
    push!(
        regions,
        ProductionQoIRegion(
            String(id),
            String(label),
            "aggregate",
            codes,
            String(source_ucid_ids),
            String(facies),
            String(definition)
        )
    )
    return regions[end]
end

function production_qoi_compile_regions(mrst_data)
    haskey(mrst_data, "qoi_semantics") || error(
        "The assembled input has no qoi_semantics block. Regenerate the " *
        "split common MAT file with writeJutulInput_gom_common.m."
    )
    semantics = mrst_data["qoi_semantics"]
    String(semantics["schema"]) == "gom_qoi_semantics_v1" || error(
        "Unsupported QoI semantic schema $(semantics["schema"])."
    )
    primary = production_qoi_integer_vec(
        semantics,
        "primary_unit_id";
        minimum = 1,
        maximum = 58
    )
    nc = length(primary)
    Int(production_qoi_scalar(semantics["cell_count"])) == nc || error(
        "qoi_semantics.cell_count does not match primary_unit_id."
    )
    allowed_primary = Set(vcat(collect(1:33), 58))
    all(in(allowed_primary), primary) || error(
        "qoi_semantics.primary_unit_id contains a non-primary UCID."
    )

    haskey(mrst_data, "qoi_stratigraphy") || error(
        "QoI output requires paired Al/Ar stratigraphy metadata."
    )
    strat = mrst_data["qoi_stratigraphy"]
    strat_cells = production_qoi_integer_vec(
        strat,
        "cells";
        minimum = 1,
        maximum = nc
    )
    length(unique(strat_cells)) == length(strat_cells) || error(
        "QoI stratigraphy contains duplicate cells."
    )
    nstrat = length(strat_cells)
    side = production_qoi_integer_vec(
        strat,
        "side_id";
        length_expected = nstrat,
        minimum = 1,
        maximum = 2
    )
    unit = production_qoi_integer_vec(
        strat,
        "stratigraphic_unit_id";
        length_expected = nstrat,
        minimum = 1,
        maximum = 21
    )
    facies = production_qoi_integer_vec(
        strat,
        "facies_id";
        length_expected = nstrat,
        minimum = 1,
        maximum = 2
    )

    expected_strat = findall(value -> 2 <= value <= 22, primary)
    sort(strat_cells) == expected_strat || error(
        "QoI Al/Ar stratigraphy cells do not equal primary UCIDs 2:22."
    )

    pair_facies = fill(0, 2, 21)
    for index in eachindex(strat_cells)
        cell = strat_cells[index]
        primary[cell] == unit[index] + 1 || error(
            "Stratigraphy cell $cell has unit $(unit[index]) but primary " *
            "UCID $(primary[cell])."
        )
        observed = pair_facies[side[index], unit[index]]
        if observed == 0
            pair_facies[side[index], unit[index]] = facies[index]
        elseif observed != facies[index]
            error(
                "Stratigraphy side $(side[index]), unit $(unit[index]) " *
                "contains mixed facies; refine the atomic QoI partition."
            )
        end
    end
    all(!iszero, pair_facies) ||
        error("One or more of the 42 Al/Ar stratigraphic units is empty.")

    atomic_regions = ProductionQoIRegion[]
    atomic_code = zeros(UInt8, nc)
    group_to_code = Dict{Int, UInt8}()

    function add_atomic(id, label, source_ucid_id; facies = "", definition = "")
        code = UInt8(length(atomic_regions) + 1)
        push!(
            atomic_regions,
            ProductionQoIRegion(
                String(id),
                String(label),
                "atomic",
                UInt8[code],
                string(source_ucid_id),
                String(facies),
                String(definition)
            )
        )
        return code
    end

    storage_code = add_atomic(
        "storage_lm2",
        "Storage reservoir LM2",
        1;
        facies = "sand",
        definition = "Exact primary UCID 1 (res_LM2)."
    )
    group_to_code[1] = storage_code

    al_codes = UInt8[]
    ar_codes = UInt8[]
    strat_code = zeros(UInt8, 2, 21)
    for side_id in 1:2, unit_id in 1:21
        prefix = side_id == 1 ? "al" : "ar"
        side_label = side_id == 1 ? "Al (footwall)" : "Ar (hanging wall)"
        facies_label = pair_facies[side_id, unit_id] == 1 ? "sand" : "clay"
        code = add_atomic(
            @sprintf("%s_%02d", prefix, unit_id),
            "$side_label A$unit_id",
            unit_id + 1;
            facies = facies_label,
            definition =
                "Primary UCID $(unit_id + 1) split by exact side_id=$side_id."
        )
        strat_code[side_id, unit_id] = code
        push!(side_id == 1 ? al_codes : ar_codes, code)
    end

    mmum_code = add_atomic(
        "mm_um",
        "MM–UM overburden",
        23;
        definition = "Exact primary UCID 23 (MMUM)."
    )
    younger_code = add_atomic(
        "younger",
        "Younger overburden",
        24;
        definition = "Exact primary UCID 24 (Younger)."
    )
    group_to_code[23] = mmum_code
    group_to_code[24] = younger_code

    fault_ids = (
        "fault_lm2",
        "fault_w1",
        "fault_w2",
        "fault_w3",
        "fault_w4",
        "fault_w5",
        "fault_w6",
        "fault_mm_um",
        "fault_younger"
    )
    fault_labels = (
        "Non-PREDICT fault LM2",
        "PREDICT fault W1",
        "PREDICT fault W2",
        "PREDICT fault W3",
        "PREDICT fault W4",
        "PREDICT fault W5",
        "PREDICT fault W6",
        "Non-PREDICT fault MM–UM",
        "Non-PREDICT fault Younger"
    )
    fault_codes = UInt8[]
    for (offset, group_id) in enumerate(25:33)
        code = add_atomic(
            fault_ids[offset],
            fault_labels[offset],
            group_id;
            definition = "Exact primary fault UCID $group_id."
        )
        group_to_code[group_id] = code
        push!(fault_codes, code)
    end

    seal_code = add_atomic(
        "complete_top_seal_amphb",
        "Complete top seal AmphB",
        58;
        facies = "clay",
        definition = "Exact primary UCID 58 (AmphB remainder)."
    )
    group_to_code[58] = seal_code

    @inbounds for cell in 1:nc
        group = primary[cell]
        if !(2 <= group <= 22)
            atomic_code[cell] = group_to_code[group]
        end
    end
    @inbounds for index in eachindex(strat_cells)
        atomic_code[strat_cells[index]] = strat_code[side[index], unit[index]]
    end
    all(!iszero, atomic_code) ||
        error("The QoI atomic partition leaves one or more cells uncovered.")
    maximum(atomic_code) == length(atomic_regions) || error(
        "The QoI atomic code table is inconsistent."
    )
    atomic_counts = zeros(Int, length(atomic_regions))
    for code in atomic_code
        atomic_counts[Int(code)] += 1
    end
    all(>(0), atomic_counts) ||
        error("One or more required QoI atomic regions is empty.")

    regions = copy(atomic_regions)
    all_codes = UInt8.(1:length(atomic_regions))
    strat_codes = vcat(al_codes, ar_codes)
    sand_codes = UInt8[
        code for code in strat_codes
        if atomic_regions[Int(code)].facies == "sand"
    ]
    clay_codes = UInt8[
        code for code in strat_codes
        if atomic_regions[Int(code)].facies == "clay"
    ]
    predict_fault_codes = fault_codes[2:7]
    nonpredict_fault_codes = fault_codes[[1, 8, 9]]

    production_qoi_add_aggregate!(
        regions, "domain_all", "Complete simulation domain", all_codes,
        "Disjoint union of every atomic QoI region."
    )
    production_qoi_add_aggregate!(
        regions, "stratigraphy_all", "All Al/Ar stratigraphy", strat_codes,
        "Union of the 42 exact Al/Ar atomic units.";
        source_ucid_ids = "2:22"
    )
    production_qoi_add_aggregate!(
        regions, "stratigraphy_al", "All Al stratigraphy", al_codes,
        "Union of Al1–Al21 (side_id=1).";
        source_ucid_ids = "2:22"
    )
    production_qoi_add_aggregate!(
        regions, "stratigraphy_ar", "All Ar stratigraphy", ar_codes,
        "Union of Ar1–Ar21 (side_id=2).";
        source_ucid_ids = "2:22"
    )
    production_qoi_add_aggregate!(
        regions, "stratigraphy_sand", "Sand stratigraphic interbeds",
        sand_codes, "Union of exact Al/Ar units with facies_id=1.";
        facies = "sand", source_ucid_ids = "2:22"
    )
    production_qoi_add_aggregate!(
        regions, "stratigraphy_clay", "Clay stratigraphic interbeds",
        clay_codes, "Union of exact Al/Ar units with facies_id=2.";
        facies = "clay", source_ucid_ids = "2:22"
    )
    production_qoi_add_aggregate!(
        regions, "top_seal_system", "Complete top-seal system",
        vcat(strat_codes, seal_code),
        "All Al/Ar stratigraphy plus the AmphB complete-seal remainder."
    )
    production_qoi_add_aggregate!(
        regions, "top_seal_clay", "Clay-bearing top-seal system",
        vcat(clay_codes, seal_code),
        "Clay Al/Ar units plus the AmphB complete-seal remainder.";
        facies = "clay"
    )
    production_qoi_add_aggregate!(
        regions, "top_seal_sand_interbeds", "Top-seal sand interbeds",
        sand_codes, "All Al/Ar units with facies_id=1.";
        facies = "sand"
    )
    production_qoi_add_aggregate!(
        regions, "overburden_mmum_younger", "MM–UM and Younger overburden",
        UInt8[mmum_code, younger_code],
        "Exact union of primary UCIDs 23 and 24.";
        source_ucid_ids = "23,24"
    )
    production_qoi_add_aggregate!(
        regions, "fault_all", "Complete fault domain", fault_codes,
        "Exact union of primary UCIDs 25:33.";
        source_ucid_ids = "25:33"
    )
    production_qoi_add_aggregate!(
        regions, "fault_predict_all", "All PREDICT fault windows",
        predict_fault_codes, "Exact union of W1–W6 (primary UCIDs 26:31).";
        source_ucid_ids = "26:31"
    )
    production_qoi_add_aggregate!(
        regions, "fault_nonpredict_all", "All non-PREDICT fault bands",
        nonpredict_fault_codes,
        "Exact union of fault LM2, MM–UM and Younger (UCIDs 25,32,33).";
        source_ucid_ids = "25,32,33"
    )
    production_qoi_add_aggregate!(
        regions, "domain_nonfault", "Complete non-fault domain",
        setdiff(all_codes, fault_codes),
        "Exact union of every atomic region outside primary UCIDs 25:33."
    )

    region_index = Dict(region.id => i for (i, region) in enumerate(regions))
    length(region_index) == length(regions) ||
        error("Duplicate QoI region identifier.")
    return (
        atomic_code = atomic_code,
        atomic_regions = atomic_regions,
        regions = regions,
        region_index = region_index,
        primary_label_sha256 =
            bytes2hex(SHA.sha256(UInt8.(primary))),
        special_codes = (
            storage = UInt8[storage_code],
            al = al_codes,
            ar = ar_codes,
            fault = fault_codes,
            predict_fault = predict_fault_codes,
            nonpredict_fault = nonpredict_fault_codes,
            complete_seal = UInt8[seal_code],
            overburden = UInt8[mmum_code, younger_code],
            top_seal = vcat(strat_codes, seal_code)
        )
    )
end

function production_qoi_codeset(codes)
    result = falses(256)
    for code in codes
        result[Int(code) + 1] = true
    end
    return result
end

function production_qoi_build_interfaces(
        atomic_code::Vector{UInt8},
        atomic_regions::Vector{ProductionQoIRegion},
        neighbors::AbstractMatrix{<:Integer},
        special_codes
    )
    pair_faces = Dict{Tuple{UInt8, UInt8}, Vector{Int32}}()
    pair_signs = Dict{Tuple{UInt8, UInt8}, Vector{Int8}}()
    @inbounds for face in axes(neighbors, 2)
        left_code = atomic_code[neighbors[1, face]]
        right_code = atomic_code[neighbors[2, face]]
        left_code == right_code && continue
        low, high = minmax(left_code, right_code)
        pair = (low, high)
        push!(get!(pair_faces, pair, Int32[]), Int32(face))
        push!(
            get!(pair_signs, pair, Int8[]),
            left_code == low ? Int8(1) : Int8(-1)
        )
    end

    interfaces = ProductionQoIInterface[]
    for pair in sort!(collect(keys(pair_faces)))
        low, high = pair
        source = atomic_regions[Int(low)]
        target = atomic_regions[Int(high)]
        push!(
            interfaces,
            ProductionQoIInterface(
                source.id * "__to__" * target.id,
                source.label * " → " * target.label,
                source.id,
                target.id,
                "atomic_contact",
                pair_faces[pair],
                pair_signs[pair],
                "Every simulator face joining these two disjoint atomic regions."
            )
        )
    end

    function add_composite(
            id,
            label,
            from_id,
            to_id,
            from_codes,
            to_codes,
            definition
        )
        from_set = production_qoi_codeset(from_codes)
        to_set = production_qoi_codeset(to_codes)
        any(from_set .& to_set) &&
            error("Composite QoI interface $id has overlapping sides.")
        faces = Int32[]
        signs = Int8[]
        for pair in sort!(collect(keys(pair_faces)))
            low, high = pair
            if from_set[Int(low) + 1] && to_set[Int(high) + 1]
                append!(faces, pair_faces[pair])
                append!(signs, pair_signs[pair])
            elseif from_set[Int(high) + 1] && to_set[Int(low) + 1]
                append!(faces, pair_faces[pair])
                append!(signs, .-pair_signs[pair])
            end
        end
        isempty(faces) && return nothing
        order = sortperm(faces)
        faces = faces[order]
        signs = signs[order]
        length(unique(faces)) == length(faces) ||
            error("Composite QoI interface $id contains duplicate faces.")
        push!(
            interfaces,
            ProductionQoIInterface(
                String(id),
                String(label),
                String(from_id),
                String(to_id),
                "semantic_contact",
                faces,
                signs,
                String(definition)
            )
        )
        return interfaces[end]
    end

    add_composite(
        "storage_to_fault", "Storage reservoir → fault",
        "storage_lm2", "fault_all",
        special_codes.storage, special_codes.fault,
        "All direct contacts from storage LM2 into any fault band."
    )
    add_composite(
        "storage_to_al", "Storage reservoir → Al stratigraphy",
        "storage_lm2", "stratigraphy_al",
        special_codes.storage, special_codes.al,
        "All direct contacts from storage LM2 into Al."
    )
    add_composite(
        "storage_to_ar", "Storage reservoir → Ar stratigraphy",
        "storage_lm2", "stratigraphy_ar",
        special_codes.storage, special_codes.ar,
        "All direct contacts from storage LM2 into Ar."
    )
    add_composite(
        "fault_to_al", "Fault → Al stratigraphy",
        "fault_all", "stratigraphy_al",
        special_codes.fault, special_codes.al,
        "All direct contacts from any fault band into Al."
    )
    add_composite(
        "fault_to_ar", "Fault → Ar stratigraphy",
        "fault_all", "stratigraphy_ar",
        special_codes.fault, special_codes.ar,
        "All direct contacts from any fault band into Ar."
    )
    add_composite(
        "predict_to_nonpredict_fault", "PREDICT → non-PREDICT fault",
        "fault_predict_all", "fault_nonpredict_all",
        special_codes.predict_fault, special_codes.nonpredict_fault,
        "All contacts from W1–W6 into the three non-PREDICT fault bands."
    )
    nonfault_codes = setdiff(
        UInt8.(1:length(atomic_regions)),
        special_codes.fault
    )
    add_composite(
        "fault_to_nonfault", "Fault → surrounding non-fault domain",
        "fault_all", "domain_nonfault",
        special_codes.fault, nonfault_codes,
        "Every direct outward contact from the fault to a non-fault cell."
    )
    add_composite(
        "complete_seal_to_overburden",
        "Complete top seal → MM–UM/Younger overburden",
        "complete_top_seal_amphb", "overburden_mmum_younger",
        special_codes.complete_seal, special_codes.overburden,
        "Direct contacts from the AmphB complete seal into MM–UM or Younger."
    )
    add_composite(
        "fault_to_overburden", "Fault → MM–UM/Younger overburden",
        "fault_all", "overburden_mmum_younger",
        special_codes.fault, special_codes.overburden,
        "Direct contacts from fault bands into MM–UM or Younger."
    )
    for side in ("al", "ar")
        codes = side == "al" ? special_codes.al : special_codes.ar
        for unit in 1:20
            add_composite(
                @sprintf("%s_%02d_to_%s_%02d", side, unit, side, unit + 1),
                @sprintf("%s A%d → A%d", uppercasefirst(side), unit, unit + 1),
                @sprintf("%s_%02d", side, unit),
                @sprintf("%s_%02d", side, unit + 1),
                UInt8[codes[unit]],
                UInt8[codes[unit + 1]],
                "Direct lower-to-upper contact within the $side stratigraphy."
            )
        end
    end

    length(unique(interface.id for interface in interfaces)) ==
        length(interfaces) || error("Duplicate QoI interface identifier.")
    return interfaces
end

function production_qoi_write_table(
        path::AbstractString,
        columns::AbstractVector{Symbol},
        rows
    )
    production_atomic_write(path) do io
        println(io, join(string.(columns), '\t'))
        for row in rows
            println(
                io,
                join(
                    (
                        production_format_value(
                            row isa NamedTuple ?
                                get(row, column, nothing) :
                                get(row, column, nothing)
                        )
                        for column in columns
                    ),
                    '\t'
                )
            )
        end
    end
    return path
end

function production_qoi_static_atomic_stats(
        atomic_code,
        pore_volume,
        centroids,
        natomic::Integer
    )
    count = zeros(Int, natomic)
    pv = zeros(Float64, natomic)
    bounds_min = fill(Inf, 3, natomic)
    bounds_max = fill(-Inf, 3, natomic)
    cells = [Int32[] for _ in 1:natomic]
    @inbounds for cell in eachindex(atomic_code)
        code = Int(atomic_code[cell])
        count[code] += 1
        pv[code] += pore_volume[cell]
        push!(cells[code], Int32(cell))
        for axis in 1:3
            coordinate = centroids[axis, cell]
            bounds_min[axis, code] = min(bounds_min[axis, code], coordinate)
            bounds_max[axis, code] = max(bounds_max[axis, code], coordinate)
        end
    end
    all(>(0), count) || error("One or more atomic QoI regions is empty.")
    return (
        count = count,
        pore_volume = pv,
        bounds_min = bounds_min,
        bounds_max = bounds_max,
        cells = cells
    )
end

function production_qoi_hash_cell_list(cells)
    io = IOBuffer()
    for cell in cells
        write(io, htol(Int64(cell)))
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function production_qoi_region_manifest_rows(
        regions,
        atomic_code,
        static_stats
    )
    rows = NamedTuple[]
    for region in regions
        codes = Int.(region.atomic_codes)
        count = sum(static_stats.count[codes])
        pv = sum(static_stats.pore_volume[codes])
        bounds_min = vec(minimum(static_stats.bounds_min[:, codes]; dims = 2))
        bounds_max = vec(maximum(static_stats.bounds_max[:, codes]; dims = 2))
        cell_hash = if region.role == "atomic"
            production_qoi_hash_cell_list(static_stats.cells[only(codes)])
        else
            production_qoi_sha256_cell_ids(
                atomic_code,
                region.atomic_codes
            )
        end
        push!(
            rows,
            (
                schema_version = PRODUCTION_QOI_SCHEMA_VERSION,
                region_id = region.id,
                region_label = region.label,
                region_role = region.role,
                atomic_codes = join(codes, ","),
                source_ucid_ids = region.source_ucid_ids,
                facies = region.facies,
                cell_count = count,
                pore_volume_m3 = pv,
                x_min_m = bounds_min[1],
                x_max_m = bounds_max[1],
                y_min_m = bounds_min[2],
                y_max_m = bounds_max[2],
                z_min_m = bounds_min[3],
                z_max_m = bounds_max[3],
                cell_id_sha256 = cell_hash,
                definition = region.definition
            )
        )
    end
    return rows
end

const PRODUCTION_QOI_REGION_MANIFEST_COLUMNS = Symbol[
    :schema_version,
    :region_id,
    :region_label,
    :region_role,
    :atomic_codes,
    :source_ucid_ids,
    :facies,
    :cell_count,
    :pore_volume_m3,
    :x_min_m,
    :x_max_m,
    :y_min_m,
    :y_max_m,
    :z_min_m,
    :z_max_m,
    :cell_id_sha256,
    :definition
]

const PRODUCTION_QOI_INTERFACE_MANIFEST_COLUMNS = Symbol[
    :schema_version,
    :interface_id,
    :interface_label,
    :interface_role,
    :from_region_id,
    :to_region_id,
    :face_count,
    :face_sign_sha256,
    :orientation,
    :flux_method,
    :definition
]

function production_qoi_interface_manifest_rows(interfaces)
    return [
        (
            schema_version = PRODUCTION_QOI_SCHEMA_VERSION,
            interface_id = interface.id,
            interface_label = interface.label,
            interface_role = interface.role,
            from_region_id = interface.from_region_id,
            to_region_id = interface.to_region_id,
            face_count = length(interface.faces),
            face_sign_sha256 = production_qoi_sha256_faces(
                interface.faces,
                interface.signs
            ),
            orientation =
                "positive_" * interface.from_region_id * "_to_" *
                interface.to_region_id,
            flux_method = PRODUCTION_QOI_FLUX_METHOD,
            definition = interface.definition
        )
        for interface in interfaces
    ]
end

function production_qoi_file_sha256(path::AbstractString)
    return bytes2hex(SHA.sha256(read(path)))
end

function production_qoi_write_or_validate_manifest(
        path,
        columns,
        rows
    )
    if !isfile(path)
        production_qoi_write_table(path, columns, rows)
        return path
    end
    temporary = path * ".expected.$(getpid()).$(Threads.threadid())"
    try
        production_qoi_write_table(temporary, columns, rows)
        production_qoi_file_sha256(temporary) ==
            production_qoi_file_sha256(path) || error(
                "QoI manifest definition changed on restart: $path."
            )
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return path
end

function production_qoi_full_reservoir_state(sim)
    storage = Jutul.get_simulator_storage(sim)
    model = Jutul.get_simulator_model(sim)
    if model isa Jutul.MultiModel
        haskey(storage, :Reservoir) ||
            error("QoI output found no Reservoir simulator storage.")
        return storage[:Reservoir].state0
    end
    return storage.state0
end

function production_qoi_reservoir_model(sim)
    model = Jutul.get_simulator_model(sim)
    return model isa Jutul.MultiModel ? model.models[:Reservoir] : model
end

function production_qoi_initial_pressure(mrst_data, initial_state, nc)
    if haskey(initial_state, :Pressure)
        return production_qoi_float_vec(
            initial_state[:Pressure],
            "initial simulator Pressure";
            length_expected = nc,
            positive = true
        )
    end
    haskey(mrst_data, "state0") &&
        haskey(mrst_data["state0"], "pressure") || error(
            "QoI output requires initial reservoir pressure."
        )
    return production_qoi_float_vec(
        mrst_data["state0"]["pressure"],
        "state0.pressure";
        length_expected = nc,
        positive = true
    )
end

function setup_production_qoi(
        mode,
        summary_dir::AbstractString,
        mrst_data,
        sim;
        case_key::AbstractString = "",
        campaign_manifest_sha256::AbstractString = ""
    )
    normalized = production_qoi_normalize_mode(mode)
    normalized == "off" && return nothing
    if isnothing(mrst_data) || isnothing(sim)
        normalized == "auto" && return nothing
        error("PRODUCTION_QOI_MODE=required needs MRST data and a simulator.")
    end
    if !haskey(mrst_data, "qoi_semantics") ||
            !haskey(mrst_data, "qoi_stratigraphy")
        normalized == "auto" && return nothing
        error(
            "PRODUCTION_QOI_MODE=required needs exact qoi_semantics and " *
            "qoi_stratigraphy metadata. Regenerate the split inputs."
        )
    end

    compiled = production_qoi_compile_regions(mrst_data)
    atomic_code = compiled.atomic_code
    nc = length(atomic_code)
    rmodel = production_qoi_reservoir_model(sim)
    rmodel isa StandardBlackOilModel ||
        error("GoM production QoI output requires StandardBlackOilModel.")
    indices = phase_indices(rmodel.system)
    number_of_phases(rmodel.system) == 2 &&
        indices.l == 1 && indices.v == 2 && has_disgas(rmodel.system) ||
        error(
            "GoM production QoI output requires the two-phase " *
            "liquid(1)/vapor(2) dissolved-gas black-oil formulation."
        )
    neighbors = production_qoi_neighbors(rmodel, nc)
    interfaces = production_qoi_build_interfaces(
        atomic_code,
        compiled.atomic_regions,
        neighbors,
        compiled.special_codes
    )
    all(
        interface ->
            haskey(compiled.region_index, interface.from_region_id) &&
            haskey(compiled.region_index, interface.to_region_id),
        interfaces
    ) || error("A QoI interface references an undefined region.")
    interface_faces = sort!(unique!(vcat(
        (
            interface.faces
            for interface in interfaces
            if interface.role == "atomic_contact"
        )...
    )))
    interface_face_slot = zeros(Int32, size(neighbors, 2))
    for (slot, face) in enumerate(interface_faces)
        interface_face_slot[face] = Int32(slot)
    end
    pore_volume = production_qoi_pore_volume(mrst_data, nc)
    centroids = production_qoi_centroids(mrst_data, nc)
    initial_state = production_qoi_full_reservoir_state(sim)
    initial_pressure =
        production_qoi_initial_pressure(mrst_data, initial_state, nc)
    gas_critical_saturation =
        production_qoi_critical_saturation(rmodel, nc)

    qoi_root = joinpath(summary_dir, "qoi")
    ready_dir = joinpath(qoi_root, "ready")
    row_dir = joinpath(qoi_root, "rows")
    mkpath(ready_dir)
    mkpath(row_dir)

    static_stats = production_qoi_static_atomic_stats(
        atomic_code,
        pore_volume,
        centroids,
        length(compiled.atomic_regions)
    )
    region_rows = production_qoi_region_manifest_rows(
        compiled.regions,
        atomic_code,
        static_stats
    )
    region_manifest_path = joinpath(summary_dir, "qoi_region_manifest.tsv")
    production_qoi_write_or_validate_manifest(
        region_manifest_path,
        PRODUCTION_QOI_REGION_MANIFEST_COLUMNS,
        region_rows
    )
    interface_rows =
        production_qoi_interface_manifest_rows(interfaces)
    interface_manifest_path =
        joinpath(summary_dir, "qoi_interface_manifest.tsv")
    production_qoi_write_or_validate_manifest(
        interface_manifest_path,
        PRODUCTION_QOI_INTERFACE_MANIFEST_COLUMNS,
        interface_rows
    )

    context = ProductionQoIContext(
        normalized,
        abspath(summary_dir),
        abspath(ready_dir),
        abspath(row_dir),
        String(case_key),
        lowercase(String(campaign_manifest_sha256)),
        atomic_code,
        compiled.atomic_regions,
        compiled.regions,
        compiled.region_index,
        interfaces,
        interface_faces,
        interface_face_slot,
        initial_pressure,
        pore_volume,
        centroids,
        gas_critical_saturation,
        zeros(Float64, length(compiled.atomic_regions)),
        NaN,
        compiled.primary_label_sha256,
        production_qoi_file_sha256(region_manifest_path),
        production_qoi_file_sha256(interface_manifest_path),
        production_qoi_injector_name(mrst_data)
    )
    context.initial_total_co2_mass_kg =
        production_qoi_domain_total_mass(initial_state)
    context.initial_atomic_total_co2_mass_kg .=
        production_qoi_atomic_inventory(context, initial_state).total
    return context
end

const PRODUCTION_QOI_BUNDLE_COLUMNS = Symbol[
    :schema_version,
    :record_type,
    :case_key,
    :campaign_manifest_sha256,
    :step,
    :time_seconds,
    :time_years,
    :qoi_evaluation_seconds,
    :region_id,
    :region_label,
    :region_role,
    :cell_count,
    :pore_volume_m3,
    :mobile_free_co2_mass_kg,
    :immobile_free_co2_mass_kg,
    :dissolved_co2_mass_kg,
    :total_co2_mass_kg,
    :fraction_of_net_domain_co2_change,
    :gas_saturation_mean,
    :gas_saturation_max,
    :historical_gas_saturation_max,
    :hysteresis_scanning_cell_count,
    :gas_filled_pore_volume_m3,
    :cells_sg_ge_1e_4,
    :cells_sg_ge_1e_3,
    :cells_sg_ge_1e_2,
    :pressure_change_mean_pa,
    :pressure_change_max_pa,
    :pressure_change_abs_max_pa,
    :capillary_pressure_mean_pa,
    :capillary_pressure_max_pa,
    :plume_cell_count_sg_ge_1e_4,
    :plume_x_min_m,
    :plume_x_max_m,
    :plume_y_min_m,
    :plume_y_max_m,
    :plume_z_min_m,
    :plume_z_max_m,
    :domain_mobile_free_co2_mass_kg,
    :domain_immobile_free_co2_mass_kg,
    :domain_dissolved_co2_mass_kg,
    :domain_total_co2_mass_kg,
    :net_domain_co2_change_kg,
    :storage_total_co2_mass_kg,
    :fault_total_co2_mass_kg,
    :stratigraphy_total_co2_mass_kg,
    :top_seal_total_co2_mass_kg,
    :complete_top_seal_total_co2_mass_kg,
    :overburden_total_co2_mass_kg,
    :fault_fraction_of_net_domain_co2_change,
    :top_seal_fraction_of_net_domain_co2_change,
    :overburden_fraction_of_net_domain_co2_change,
    :domain_gas_saturation_max,
    :fault_gas_saturation_max,
    :top_seal_gas_saturation_max,
    :complete_top_seal_gas_saturation_max,
    :overburden_gas_saturation_max,
    :domain_pressure_change_max_pa,
    :fault_pressure_change_max_pa,
    :domain_hysteresis_scanning_cell_count,
    :fault_hysteresis_scanning_cell_count,
    :injector_name,
    :injector_bhp_pa,
    :interface_id,
    :interface_label,
    :interface_role,
    :from_region_id,
    :to_region_id,
    :face_count,
    :free_co2_forward_rate_kg_s,
    :free_co2_reverse_rate_kg_s,
    :free_co2_net_rate_kg_s,
    :dissolved_co2_forward_rate_kg_s,
    :dissolved_co2_reverse_rate_kg_s,
    :dissolved_co2_net_rate_kg_s,
    :total_co2_forward_rate_kg_s,
    :total_co2_reverse_rate_kg_s,
    :total_co2_net_rate_kg_s,
    :flux_method
]

const PRODUCTION_QOI_GLOBAL_COLUMNS = Symbol[
    :schema_version,
    :case_key,
    :campaign_manifest_sha256,
    :step,
    :time_seconds,
    :time_years,
    :qoi_evaluation_seconds,
    :domain_mobile_free_co2_mass_kg,
    :domain_immobile_free_co2_mass_kg,
    :domain_dissolved_co2_mass_kg,
    :domain_total_co2_mass_kg,
    :net_domain_co2_change_kg,
    :storage_total_co2_mass_kg,
    :fault_total_co2_mass_kg,
    :stratigraphy_total_co2_mass_kg,
    :top_seal_total_co2_mass_kg,
    :complete_top_seal_total_co2_mass_kg,
    :overburden_total_co2_mass_kg,
    :fault_fraction_of_net_domain_co2_change,
    :top_seal_fraction_of_net_domain_co2_change,
    :overburden_fraction_of_net_domain_co2_change,
    :domain_gas_saturation_max,
    :fault_gas_saturation_max,
    :top_seal_gas_saturation_max,
    :complete_top_seal_gas_saturation_max,
    :overburden_gas_saturation_max,
    :domain_pressure_change_max_pa,
    :fault_pressure_change_max_pa,
    :domain_hysteresis_scanning_cell_count,
    :fault_hysteresis_scanning_cell_count,
    :injector_name,
    :injector_bhp_pa,
    :flux_method
]

const PRODUCTION_QOI_REGION_COLUMNS = Symbol[
    :schema_version,
    :case_key,
    :campaign_manifest_sha256,
    :step,
    :time_seconds,
    :time_years,
    :region_id,
    :region_label,
    :region_role,
    :cell_count,
    :pore_volume_m3,
    :mobile_free_co2_mass_kg,
    :immobile_free_co2_mass_kg,
    :dissolved_co2_mass_kg,
    :total_co2_mass_kg,
    :fraction_of_net_domain_co2_change,
    :gas_saturation_mean,
    :gas_saturation_max,
    :historical_gas_saturation_max,
    :hysteresis_scanning_cell_count,
    :gas_filled_pore_volume_m3,
    :cells_sg_ge_1e_4,
    :cells_sg_ge_1e_3,
    :cells_sg_ge_1e_2,
    :pressure_change_mean_pa,
    :pressure_change_max_pa,
    :pressure_change_abs_max_pa,
    :capillary_pressure_mean_pa,
    :capillary_pressure_max_pa,
    :plume_cell_count_sg_ge_1e_4,
    :plume_x_min_m,
    :plume_x_max_m,
    :plume_y_min_m,
    :plume_y_max_m,
    :plume_z_min_m,
    :plume_z_max_m
]

const PRODUCTION_QOI_INTERFACE_COLUMNS = Symbol[
    :schema_version,
    :case_key,
    :campaign_manifest_sha256,
    :step,
    :time_seconds,
    :time_years,
    :interface_id,
    :interface_label,
    :interface_role,
    :from_region_id,
    :to_region_id,
    :face_count,
    :free_co2_forward_rate_kg_s,
    :free_co2_reverse_rate_kg_s,
    :free_co2_net_rate_kg_s,
    :dissolved_co2_forward_rate_kg_s,
    :dissolved_co2_reverse_rate_kg_s,
    :dissolved_co2_net_rate_kg_s,
    :total_co2_forward_rate_kg_s,
    :total_co2_reverse_rate_kg_s,
    :total_co2_net_rate_kg_s,
    :flux_method
]

function production_qoi_state_arrays(state, nc::Integer)
    required = (
        :FluidVolume,
        :Saturations,
        :PhaseMassDensities,
        :Rs,
        :ShrinkageFactors,
        :Pressure
    )
    all(key -> haskey(state, key), required) || error(
        "QoI reservoir state is missing one of $(join(string.(required), ", "))."
    )
    fluid_volume = vec(state[:FluidVolume])
    length(fluid_volume) == nc ||
        error("FluidVolume has the wrong cell count.")
    all(value -> value isa Real && isfinite(value) && value > 0,
        fluid_volume) ||
        error("FluidVolume must contain finite, positive values.")
    pressure = vec(state[:Pressure])
    length(pressure) == nc ||
        error("Pressure has the wrong cell count.")
    all(value -> value isa Real && isfinite(value) && value > 0, pressure) ||
        error("Pressure must contain finite, positive values.")
    saturations = state[:Saturations]
    densities = state[:PhaseMassDensities]
    shrinkage = state[:ShrinkageFactors]
    ndims(saturations) == 2 && size(saturations, 2) == nc &&
        size(saturations, 1) >= 2 || error(
            "QoI Saturations must be phase-by-cell with at least two phases."
        )
    ndims(densities) == 2 && size(densities, 2) == nc &&
        size(densities, 1) >= 2 || error(
            "QoI PhaseMassDensities must be phase-by-cell."
        )
    ndims(shrinkage) == 2 && size(shrinkage, 2) == nc &&
        size(shrinkage, 1) >= 2 || error(
            "QoI ShrinkageFactors must be phase-by-cell."
        )
    sw = view(saturations, 1, :)
    sg = view(saturations, 2, :)
    rs = vec(state[:Rs])
    length(rs) == nc || error("Rs has the wrong cell count.")
    all(value -> value isa Real && isfinite(value), rs) ||
        error("Rs contains a non-finite value.")
    bo = view(shrinkage, 1, :)
    bg = view(shrinkage, 2, :)
    gas_density = view(densities, 2, :)
    all(values -> all(isfinite, values),
        (sw, sg, bo, bg, gas_density)) ||
        error("QoI state contains a non-finite fluid value.")
    all(value -> -1.0e-8 <= value <= 1.0 + 1.0e-8, sw) &&
        all(value -> -1.0e-8 <= value <= 1.0 + 1.0e-8, sg) ||
        error("QoI state contains saturation outside tolerance.")
    all(>(0.0), bg) ||
        error("QoI state contains a non-positive gas shrinkage factor.")

    capillary_pressure = nothing
    if haskey(state, :CapillaryPressure)
        raw_pc = state[:CapillaryPressure]
        if raw_pc isa AbstractVector && length(raw_pc) == nc
            capillary_pressure = vec(raw_pc)
        elseif ndims(raw_pc) == 2 && size(raw_pc, 2) == nc
            size(raw_pc, 1) == 1 || error(
                "Two-phase QoI output expected one CapillaryPressure row."
            )
            capillary_pressure = view(raw_pc, 1, :)
        elseif ndims(raw_pc) == 2 && size(raw_pc, 1) == nc &&
                size(raw_pc, 2) == 1
            capillary_pressure = view(raw_pc, :, 1)
        else
            error("Unsupported CapillaryPressure shape $(size(raw_pc)).")
        end
        all(isfinite, capillary_pressure) ||
            error("CapillaryPressure contains a non-finite value.")
    end
    max_gas_saturation = nothing
    if haskey(state, :MaxSaturations)
        historical = state[:MaxSaturations]
        size(historical) == size(saturations) || error(
            "MaxSaturations shape does not match Saturations."
        )
        max_gas_saturation = view(historical, 2, :)
        all(value -> value isa Real && isfinite(value) &&
            -1.0e-8 <= value <= 1.0 + 1.0e-8, max_gas_saturation) ||
            error("MaxSaturations contains an invalid gas saturation.")
    end
    return (
        fluid_volume = fluid_volume,
        pressure = pressure,
        sw = sw,
        sg = sg,
        rs = rs,
        bo = bo,
        bg = bg,
        gas_density = gas_density,
        capillary_pressure = capillary_pressure,
        max_gas_saturation = max_gas_saturation
    )
end

function production_qoi_domain_total_mass(state)
    haskey(state, :Saturations) || error(
        "Cannot initialize QoI mass baseline without Saturations."
    )
    nc = size(state[:Saturations], 2)
    arrays = production_qoi_state_arrays(state, nc)
    total = 0.0
    @inbounds for cell in 1:nc
        free =
            arrays.sg[cell]*arrays.fluid_volume[cell]*
            arrays.gas_density[cell]
        dissolved =
            arrays.sw[cell]*arrays.fluid_volume[cell]*arrays.rs[cell]*
            arrays.bo[cell]*arrays.gas_density[cell]/arrays.bg[cell]
        total += free + dissolved
    end
    return total
end

function production_qoi_atomic_inventory(context, state)
    nc = length(context.atomic_code)
    arrays = production_qoi_state_arrays(state, nc)
    natomic = length(context.atomic_regions)
    count = zeros(Int, natomic)
    pv = zeros(Float64, natomic)
    mobile = zeros(Float64, natomic)
    immobile = zeros(Float64, natomic)
    dissolved = zeros(Float64, natomic)
    total = zeros(Float64, natomic)
    sg_sum = zeros(Float64, natomic)
    sg_max = fill(-Inf, natomic)
    historical_sg_max = fill(-Inf, natomic)
    scanning_count = zeros(Int, natomic)
    gas_pv = zeros(Float64, natomic)
    threshold_counts = zeros(Int, 3, natomic)
    dp_sum = zeros(Float64, natomic)
    dp_max = fill(-Inf, natomic)
    dp_abs_max = zeros(Float64, natomic)
    pc_sum = zeros(Float64, natomic)
    pc_max = fill(-Inf, natomic)
    pc_count = zeros(Int, natomic)
    plume_count = zeros(Int, natomic)
    plume_min = fill(Inf, 3, natomic)
    plume_max = fill(-Inf, 3, natomic)

    reconstructed_total = 0.0
    @inbounds for cell in 1:nc
        code = Int(context.atomic_code[cell])
        sg = arrays.sg[cell]
        sw = arrays.sw[cell]
        fv = arrays.fluid_volume[cell]
        rho_g = arrays.gas_density[cell]
        sg_critical = context.gas_critical_saturation[cell]
        immobile_sg = min(max(sg, 0.0), sg_critical)
        mobile_sg = max(sg - sg_critical, 0.0)
        mobile_mass = mobile_sg*fv*rho_g
        immobile_mass = immobile_sg*fv*rho_g
        dissolved_mass =
            sw*fv*arrays.rs[cell]*arrays.bo[cell]*rho_g/arrays.bg[cell]
        total_mass = mobile_mass + immobile_mass + dissolved_mass
        dp = arrays.pressure[cell] - context.initial_pressure[cell]

        count[code] += 1
        pv[code] += context.pore_volume[cell]
        mobile[code] += mobile_mass
        immobile[code] += immobile_mass
        dissolved[code] += dissolved_mass
        total[code] += total_mass
        sg_sum[code] += sg
        sg_max[code] = max(sg_max[code], sg)
        if !isnothing(arrays.max_gas_saturation)
            historical_sg = arrays.max_gas_saturation[cell]
            historical_sg_max[code] =
                max(historical_sg_max[code], historical_sg)
            scanning_count[code] += historical_sg > sg + 1.0e-12
        end
        gas_pv[code] += max(sg, 0.0)*fv
        for threshold_index in 1:3
            threshold_counts[threshold_index, code] +=
                sg >= PRODUCTION_QOI_SG_THRESHOLDS[threshold_index]
        end
        dp_sum[code] += dp
        dp_max[code] = max(dp_max[code], dp)
        dp_abs_max[code] = max(dp_abs_max[code], abs(dp))
        if !isnothing(arrays.capillary_pressure)
            pc = arrays.capillary_pressure[cell]
            pc_sum[code] += pc
            pc_max[code] = max(pc_max[code], pc)
            pc_count[code] += 1
        end
        if sg >= PRODUCTION_QOI_SG_THRESHOLDS[1]
            plume_count[code] += 1
            for axis in 1:3
                coordinate = context.centroids[axis, cell]
                plume_min[axis, code] =
                    min(plume_min[axis, code], coordinate)
                plume_max[axis, code] =
                    max(plume_max[axis, code], coordinate)
            end
        end
        reconstructed_total += total_mass
    end

    if haskey(state, :TotalMasses)
        total_masses = state[:TotalMasses]
        if ndims(total_masses) == 2 && size(total_masses, 1) >= 2 &&
                size(total_masses, 2) == nc
            stored_total = sum(Float64, view(total_masses, 2, :))
            tolerance = max(1.0e-3, abs(stored_total)*1.0e-10)
            abs(reconstructed_total - stored_total) <= tolerance || error(
                "QoI reconstructed CO2 mass $reconstructed_total kg does " *
                "not match gas-component TotalMasses $stored_total kg."
            )
        end
    end

    return (
        count = count,
        pore_volume = pv,
        mobile = mobile,
        immobile = immobile,
        dissolved = dissolved,
        total = total,
        sg_sum = sg_sum,
        sg_max = sg_max,
        historical_sg_max = historical_sg_max,
        scanning_count = scanning_count,
        gas_pore_volume = gas_pv,
        threshold_counts = threshold_counts,
        dp_sum = dp_sum,
        dp_max = dp_max,
        dp_abs_max = dp_abs_max,
        pc_sum = pc_sum,
        pc_max = pc_max,
        pc_count = pc_count,
        plume_count = plume_count,
        plume_min = plume_min,
        plume_max = plume_max
    )
end

function production_qoi_base_row(
        context,
        record_type,
        step,
        seconds
    )
    return Dict{Symbol, Any}(
        :schema_version => PRODUCTION_QOI_SCHEMA_VERSION,
        :record_type => String(record_type),
        :case_key => context.case_key,
        :campaign_manifest_sha256 => context.campaign_manifest_sha256,
        :step => Int(step),
        :time_seconds => Float64(seconds),
        :time_years => Float64(seconds)/MRST_YEAR_SECONDS
    )
end

function production_qoi_region_rows(
        context,
        inventory,
        step,
        seconds
    )
    domain_codes = context.regions[
        context.region_index["domain_all"]
    ].atomic_codes
    domain_total = sum(inventory.total[Int.(domain_codes)])
    net_change = domain_total - context.initial_total_co2_mass_kg
    rows = Dict{Symbol, Any}[]
    for region in context.regions
        codes = Int.(region.atomic_codes)
        cell_count = sum(inventory.count[codes])
        pore_volume = sum(inventory.pore_volume[codes])
        plume_count = sum(inventory.plume_count[codes])
        pc_count = sum(inventory.pc_count[codes])
        row = production_qoi_base_row(context, "region", step, seconds)
        merge!(
            row,
            Dict{Symbol, Any}(
                :region_id => region.id,
                :region_label => region.label,
                :region_role => region.role,
                :cell_count => cell_count,
                :pore_volume_m3 => pore_volume,
                :mobile_free_co2_mass_kg =>
                    sum(inventory.mobile[codes]),
                :immobile_free_co2_mass_kg =>
                    sum(inventory.immobile[codes]),
                :dissolved_co2_mass_kg =>
                    sum(inventory.dissolved[codes]),
                :total_co2_mass_kg => sum(inventory.total[codes]),
                :fraction_of_net_domain_co2_change =>
                    net_change > 1.0e-12 ?
                        (
                            sum(inventory.total[codes]) -
                            sum(context.initial_atomic_total_co2_mass_kg[codes])
                        )/net_change : NaN,
                :gas_saturation_mean =>
                    sum(inventory.sg_sum[codes])/cell_count,
                :gas_saturation_max => maximum(inventory.sg_max[codes]),
                :historical_gas_saturation_max =>
                    all(isfinite, inventory.historical_sg_max[codes]) ?
                        maximum(inventory.historical_sg_max[codes]) : NaN,
                :hysteresis_scanning_cell_count =>
                    sum(inventory.scanning_count[codes]),
                :gas_filled_pore_volume_m3 =>
                    sum(inventory.gas_pore_volume[codes]),
                :cells_sg_ge_1e_4 =>
                    sum(inventory.threshold_counts[1, codes]),
                :cells_sg_ge_1e_3 =>
                    sum(inventory.threshold_counts[2, codes]),
                :cells_sg_ge_1e_2 =>
                    sum(inventory.threshold_counts[3, codes]),
                :pressure_change_mean_pa =>
                    sum(inventory.dp_sum[codes])/cell_count,
                :pressure_change_max_pa =>
                    maximum(inventory.dp_max[codes]),
                :pressure_change_abs_max_pa =>
                    maximum(inventory.dp_abs_max[codes]),
                :capillary_pressure_mean_pa =>
                    pc_count > 0 ?
                        sum(inventory.pc_sum[codes])/pc_count : NaN,
                :capillary_pressure_max_pa =>
                    pc_count > 0 ?
                        maximum(inventory.pc_max[codes]) : NaN,
                :plume_cell_count_sg_ge_1e_4 => plume_count,
                :plume_x_min_m => plume_count > 0 ?
                    minimum(inventory.plume_min[1, codes]) : NaN,
                :plume_x_max_m => plume_count > 0 ?
                    maximum(inventory.plume_max[1, codes]) : NaN,
                :plume_y_min_m => plume_count > 0 ?
                    minimum(inventory.plume_min[2, codes]) : NaN,
                :plume_y_max_m => plume_count > 0 ?
                    maximum(inventory.plume_max[2, codes]) : NaN,
                :plume_z_min_m => plume_count > 0 ?
                    minimum(inventory.plume_min[3, codes]) : NaN,
                :plume_z_max_m => plume_count > 0 ?
                    maximum(inventory.plume_max[3, codes]) : NaN
            )
        )
        push!(rows, row)
    end
    return rows
end

function production_qoi_injector_bhp(context, sim)
    isempty(context.injector_name) && return NaN
    storage = Jutul.get_simulator_storage(sim)
    model = Jutul.get_simulator_model(sim)
    model isa Jutul.MultiModel || return NaN
    key = Symbol(context.injector_name)
    haskey(storage, key) || return NaN
    state = storage[key].state0
    haskey(state, :Pressure) || return NaN
    pressure = Float64.(vec(state[:Pressure]))
    isempty(pressure) && return NaN
    all(isfinite, pressure) || error(
        "Injector $(context.injector_name) has non-finite pressure."
    )
    return maximum(pressure)
end

function production_qoi_global_row(
        context,
        region_rows,
        step,
        seconds,
        sim
    )
    by_id = Dict(String(row[:region_id]) => row for row in region_rows)
    getrow(id) = by_id[id]
    domain = getrow("domain_all")
    storage = getrow("storage_lm2")
    fault = getrow("fault_all")
    stratigraphy = getrow("stratigraphy_all")
    top_seal = getrow("top_seal_system")
    complete_seal = getrow("complete_top_seal_amphb")
    overburden = getrow("overburden_mmum_younger")
    net_change =
        domain[:total_co2_mass_kg] - context.initial_total_co2_mass_kg
    function excess_mass(region_id)
        region = context.regions[context.region_index[region_id]]
        codes = Int.(region.atomic_codes)
        return getrow(region_id)[:total_co2_mass_kg] -
            sum(context.initial_atomic_total_co2_mass_kg[codes])
    end
    fraction(value) = net_change > 1.0e-12 ? value/net_change : NaN
    row = production_qoi_base_row(context, "global", step, seconds)
    merge!(
        row,
        Dict{Symbol, Any}(
            :domain_mobile_free_co2_mass_kg =>
                domain[:mobile_free_co2_mass_kg],
            :domain_immobile_free_co2_mass_kg =>
                domain[:immobile_free_co2_mass_kg],
            :domain_dissolved_co2_mass_kg =>
                domain[:dissolved_co2_mass_kg],
            :domain_total_co2_mass_kg => domain[:total_co2_mass_kg],
            :net_domain_co2_change_kg => net_change,
            :storage_total_co2_mass_kg => storage[:total_co2_mass_kg],
            :fault_total_co2_mass_kg => fault[:total_co2_mass_kg],
            :stratigraphy_total_co2_mass_kg =>
                stratigraphy[:total_co2_mass_kg],
            :top_seal_total_co2_mass_kg =>
                top_seal[:total_co2_mass_kg],
            :complete_top_seal_total_co2_mass_kg =>
                complete_seal[:total_co2_mass_kg],
            :overburden_total_co2_mass_kg =>
                overburden[:total_co2_mass_kg],
            :fault_fraction_of_net_domain_co2_change =>
                fraction(excess_mass("fault_all")),
            :top_seal_fraction_of_net_domain_co2_change =>
                fraction(excess_mass("top_seal_system")),
            :overburden_fraction_of_net_domain_co2_change =>
                fraction(excess_mass("overburden_mmum_younger")),
            :domain_gas_saturation_max =>
                domain[:gas_saturation_max],
            :fault_gas_saturation_max =>
                fault[:gas_saturation_max],
            :top_seal_gas_saturation_max =>
                top_seal[:gas_saturation_max],
            :complete_top_seal_gas_saturation_max =>
                complete_seal[:gas_saturation_max],
            :overburden_gas_saturation_max =>
                overburden[:gas_saturation_max],
            :domain_pressure_change_max_pa =>
                domain[:pressure_change_max_pa],
            :fault_pressure_change_max_pa =>
                fault[:pressure_change_max_pa],
            :domain_hysteresis_scanning_cell_count =>
                domain[:hysteresis_scanning_cell_count],
            :fault_hysteresis_scanning_cell_count =>
                fault[:hysteresis_scanning_cell_count],
            :injector_name => context.injector_name,
            :injector_bhp_pa =>
                production_qoi_injector_bhp(context, sim),
            :flux_method => PRODUCTION_QOI_FLUX_METHOD
        )
    )
    return row
end

function production_qoi_face_co2_flux(
        face::Integer,
        left::Integer,
        right::Integer,
        state,
        rmodel
    )
    rmodel isa StandardBlackOilModel || error(
        "QoI interface flux currently requires StandardBlackOilModel."
    )
    sys = rmodel.system
    has_disgas(sys) || error(
        "QoI dissolved/free interface flux requires dissolved gas."
    )
    if haskey(state, :Diffusivities)
        diffusivities = state[:Diffusivities]
        any(value -> !iszero(value), diffusivities) && error(
            "QoI free/dissolved interface flux does not yet split nonzero " *
            "diffusive transport. Disable diffusion or extend the split."
        )
    end

    indices = phase_indices(sys)
    liquid = indices.l
    vapor = indices.v
    flux_type = Jutul.DefaultFlux()
    gradient = Jutul.TPFA(left, right, 1)
    upwind_scheme = Jutul.SPU(left, right)
    potentials = darcy_permeability_potential_differences(
        face,
        state,
        rmodel,
        flux_type,
        gradient,
        upwind_scheme
    )
    surface_mobility = state.SurfaceVolumeMobilities
    liquid_potential = potentials[liquid]
    vapor_potential = potentials[vapor]
    liquid_mobility = phase_upwind(
        upwind_scheme,
        surface_mobility,
        liquid,
        liquid_potential
    )
    vapor_mobility = phase_upwind(
        upwind_scheme,
        surface_mobility,
        vapor,
        vapor_potential
    )
    rs = upwind(
        upwind_scheme,
        state.Rs,
        liquid_potential
    )
    gas_reference_density = reference_densities(sys)[vapor]
    free = Float64(
        gas_reference_density*vapor_mobility*vapor_potential
    )
    dissolved = Float64(
        gas_reference_density*rs*liquid_mobility*liquid_potential
    )
    total = free + dissolved
    all(isfinite, (free, dissolved, total)) || error(
        "QoI interface face $face has a non-finite CO2 component flux."
    )
    return (free, dissolved, total)
end

function production_qoi_interface_rows(
        context,
        state,
        rmodel,
        step,
        seconds
    )
    neighbors = production_qoi_neighbors(
        rmodel,
        length(context.atomic_code)
    )
    nselected = length(context.interface_faces)
    free_flux = Vector{Float64}(undef, nselected)
    dissolved_flux = Vector{Float64}(undef, nselected)
    total_flux = Vector{Float64}(undef, nselected)
    @inbounds for (slot, face32) in enumerate(context.interface_faces)
        face = Int(face32)
        left = neighbors[1, face]
        right = neighbors[2, face]
        free, dissolved, total =
            production_qoi_face_co2_flux(
                face,
                left,
                right,
                state,
                rmodel
            )
        free_flux[slot] = free
        dissolved_flux[slot] = dissolved
        total_flux[slot] = total
    end

    rows = Dict{Symbol, Any}[]
    for interface in context.interfaces
        free_forward, free_reverse,
        dissolved_forward, dissolved_reverse,
        total_forward, total_reverse =
            production_qoi_oriented_flux_totals(
                interface,
                context.interface_face_slot,
                free_flux,
                dissolved_flux,
                total_flux
            )
        row = production_qoi_base_row(
            context,
            "interface",
            step,
            seconds
        )
        merge!(
            row,
            Dict{Symbol, Any}(
                :interface_id => interface.id,
                :interface_label => interface.label,
                :interface_role => interface.role,
                :from_region_id => interface.from_region_id,
                :to_region_id => interface.to_region_id,
                :face_count => length(interface.faces),
                :free_co2_forward_rate_kg_s => free_forward,
                :free_co2_reverse_rate_kg_s => free_reverse,
                :free_co2_net_rate_kg_s =>
                    free_forward - free_reverse,
                :dissolved_co2_forward_rate_kg_s =>
                    dissolved_forward,
                :dissolved_co2_reverse_rate_kg_s =>
                    dissolved_reverse,
                :dissolved_co2_net_rate_kg_s =>
                    dissolved_forward - dissolved_reverse,
                :total_co2_forward_rate_kg_s => total_forward,
                :total_co2_reverse_rate_kg_s => total_reverse,
                :total_co2_net_rate_kg_s =>
                    total_forward - total_reverse,
                :flux_method => PRODUCTION_QOI_FLUX_METHOD
            )
        )
        push!(rows, row)
    end
    return rows
end

function production_qoi_oriented_flux_totals(
        interface,
        face_slot,
        free_flux,
        dissolved_flux,
        total_flux
    )
    free_forward = 0.0
    free_reverse = 0.0
    dissolved_forward = 0.0
    dissolved_reverse = 0.0
    total_forward = 0.0
    total_reverse = 0.0
        @inbounds for index in eachindex(interface.faces)
            face = Int(interface.faces[index])
            slot = Int(face_slot[face])
            slot > 0 || error(
                "QoI interface $(interface.id) references an uncompiled face."
            )
            sign_value = Float64(interface.signs[index])
            free = sign_value*free_flux[slot]
            dissolved = sign_value*dissolved_flux[slot]
            total = sign_value*total_flux[slot]
            free_forward += max(free, 0.0)
            free_reverse += max(-free, 0.0)
            dissolved_forward += max(dissolved, 0.0)
            dissolved_reverse += max(-dissolved, 0.0)
            total_forward += max(total, 0.0)
            total_reverse += max(-total, 0.0)
        end
    return (
        free_forward,
        free_reverse,
        dissolved_forward,
        dissolved_reverse,
        total_forward,
        total_reverse
    )
end

function production_qoi_snapshot_rows!(
        context::ProductionQoIContext,
        step::Integer,
        seconds::Real,
        sim
    )
    started = time_ns()
    state = production_qoi_full_reservoir_state(sim)
    rmodel = production_qoi_reservoir_model(sim)
    inventory = production_qoi_atomic_inventory(context, state)
    region_rows =
        production_qoi_region_rows(context, inventory, step, seconds)
    global_row =
        production_qoi_global_row(context, region_rows, step, seconds, sim)
    interface_rows =
        production_qoi_interface_rows(
            context,
            state,
            rmodel,
            step,
            seconds
        )
    elapsed = (time_ns() - started)/1.0e9
    global_row[:qoi_evaluation_seconds] = elapsed
    return vcat(
        Dict{Symbol, Any}[global_row],
        region_rows,
        interface_rows
    )
end

function production_stage_qoi_bundle!(
        context::ProductionQoIContext,
        step::Integer,
        seconds::Real,
        sim
    )
    ready_path = production_qoi_ready_path(context, step)
    row_path = production_qoi_row_path(context, step)
    !isfile(ready_path) || error(
        "QoI ready bundle already exists for report step $step."
    )
    !isfile(row_path) || error(
        "QoI committed bundle already exists for report step $step."
    )
    rows = production_qoi_snapshot_rows!(context, step, seconds, sim)
    production_qoi_write_table(
        ready_path,
        PRODUCTION_QOI_BUNDLE_COLUMNS,
        rows
    )
    production_qoi_validate_bundle(context, ready_path, step)
    return ready_path
end

function production_qoi_parse_table(path::AbstractString)
    lines = readlines(path)
    length(lines) >= 2 || error("QoI table $path is empty.")
    header = split(lines[1], '\t'; keepempty = true)
    length(unique(header)) == length(header) ||
        error("QoI table $path has duplicate columns.")
    rows = Dict{String, String}[]
    for (offset, line) in enumerate(lines[2:end])
        line_number = offset + 1
        values = split(line, '\t'; keepempty = true)
        length(values) == length(header) || error(
            "QoI table $path line $line_number has $(length(values)) " *
            "values for $(length(header)) columns."
        )
        push!(rows, Dict(header .=> values))
    end
    return header, rows
end

function production_qoi_validate_bundle(
        context::ProductionQoIContext,
        path::AbstractString,
        expected_step::Integer
    )
    header, rows = production_qoi_parse_table(path)
    header == string.(PRODUCTION_QOI_BUNDLE_COLUMNS) || error(
        "QoI bundle $path has an unsupported header."
    )
    expected_count = 1 + length(context.regions) + length(context.interfaces)
    length(rows) == expected_count || error(
        "QoI bundle $path has $(length(rows)) records, expected $expected_count."
    )
    all(row -> parse(Int, row["schema_version"]) ==
        PRODUCTION_QOI_SCHEMA_VERSION, rows) ||
        error("QoI bundle $path has an unsupported schema.")
    all(row -> parse(Int, row["step"]) == expected_step, rows) ||
        error("QoI bundle $path contains the wrong report step.")
    count(row -> row["record_type"] == "global", rows) == 1 ||
        error("QoI bundle $path must contain exactly one global record.")
    region_ids = sort!([
        row["region_id"] for row in rows if row["record_type"] == "region"
    ])
    region_ids == sort!([region.id for region in context.regions]) || error(
        "QoI bundle $path has missing or duplicate region records."
    )
    interface_ids = sort!([
        row["interface_id"]
        for row in rows if row["record_type"] == "interface"
    ])
    interface_ids ==
        sort!([interface.id for interface in context.interfaces]) || error(
            "QoI bundle $path has missing or duplicate interface records."
        )
    return rows
end

function production_commit_qoi_bundle!(
        context::ProductionQoIContext,
        step::Integer
    )
    ready_path = production_qoi_ready_path(context, step)
    row_path = production_qoi_row_path(context, step)
    isfile(ready_path) ||
        error("Missing staged QoI bundle for report step $step.")
    !isfile(row_path) ||
        error("QoI bundle for report step $step is already committed.")
    production_qoi_validate_bundle(context, ready_path, step)
    mv(ready_path, row_path; force = false)
    return row_path
end

production_qoi_row_indices(context::ProductionQoIContext) =
    production_scan_indices(context.row_dir, PRODUCTION_QOI_ROW_PATTERN)

production_qoi_ready_indices(context::ProductionQoIContext) =
    production_scan_indices(context.ready_dir, PRODUCTION_QOI_ROW_PATTERN)

function production_reconcile_qoi!(
        context::ProductionQoIContext,
        policy,
        previous_step::Integer
    )
    previous_step >= 0 || error("Invalid previous QoI step $previous_step.")
    for step in production_qoi_ready_indices(context)
        ready_path = production_qoi_ready_path(context, step)
        row_path = production_qoi_row_path(context, step)
        if step == previous_step && !isfile(row_path)
            isfile(production_restart_path(policy, step)) || error(
                "Staged QoI bundle $step has no validated restart checkpoint."
            )
            production_commit_qoi_bundle!(context, step)
        elseif step <= previous_step && isfile(row_path)
            production_quarantine!(
                policy,
                ready_path,
                "Duplicate staged QoI bundle for committed report step $step."
            )
        elseif step <= previous_step
            error(
                "Historical QoI bundle $step was staged but not committed; " *
                "only the selected restart step can be promoted safely."
            )
        else
            production_quarantine!(
                policy,
                ready_path,
                "QoI bundle is newer than selected restart $previous_step."
            )
        end
    end

    for step in production_qoi_row_indices(context)
        if step > previous_step
            production_quarantine!(
                policy,
                production_qoi_row_path(context, step),
                "Committed QoI bundle is newer than selected restart " *
                "$previous_step."
            )
        end
    end

    observed = production_qoi_row_indices(context)
    expected = collect(1:previous_step)
    observed == expected || error(
        "Committed QoI bundle prefix is $(join(observed, ",")); expected " *
        "$(join(expected, ",")). Missing historical QoI data cannot be " *
        "reconstructed after restart deletion."
    )
    for step in expected
        production_qoi_validate_bundle(
            context,
            production_qoi_row_path(context, step),
            step
        )
    end
    return nothing
end

function production_qoi_write_dict_table(
        path::AbstractString,
        columns::AbstractVector{Symbol},
        rows::AbstractVector{<:AbstractDict}
    )
    production_atomic_write(path) do io
        println(io, join(string.(columns), '\t'))
        for row in rows
            println(
                io,
                join(
                    (
                        get(row, string(column), "")
                        for column in columns
                    ),
                    '\t'
                )
            )
        end
    end
    return path
end

production_qoi_parse_float(row, key) = parse(Float64, row[String(key)])
production_qoi_parse_int(row, key) = parse(Int, row[String(key)])

function production_qoi_first_arrival_years(
        rows,
        field::AbstractString;
        threshold = PRODUCTION_QOI_SG_THRESHOLDS[1]
    )
    for row in rows
        value = parse(Float64, row[field])
        if isfinite(value) && value >= threshold
            return parse(Float64, row["time_years"])
        end
    end
    return NaN
end

function production_qoi_peak_interface(
        rows,
        interface_id::AbstractString
    )
    selected = [
        row for row in rows
        if row["interface_id"] == interface_id
    ]
    isempty(selected) && return (NaN, NaN)
    values = [
        parse(Float64, row["total_co2_forward_rate_kg_s"])
        for row in selected
    ]
    index = argmax(values)
    return (
        values[index],
        parse(Float64, selected[index]["time_years"])
    )
end

const PRODUCTION_QOI_CASE_SUMMARY_COLUMNS = Symbol[
    :schema_version,
    :case_key,
    :campaign_manifest_sha256,
    :final_step,
    :final_time_seconds,
    :final_time_years,
    :arrival_sg_threshold,
    :first_fault_arrival_years,
    :first_top_seal_arrival_years,
    :first_complete_top_seal_arrival_years,
    :first_overburden_arrival_years,
    :peak_storage_to_fault_forward_rate_kg_s,
    :peak_storage_to_fault_forward_rate_time_years,
    :peak_fault_to_nonfault_forward_rate_kg_s,
    :peak_fault_to_nonfault_forward_rate_time_years,
    :final_domain_mobile_free_co2_mass_kg,
    :final_domain_immobile_free_co2_mass_kg,
    :final_domain_dissolved_co2_mass_kg,
    :final_domain_total_co2_mass_kg,
    :final_net_domain_co2_change_kg,
    :final_storage_total_co2_mass_kg,
    :final_fault_total_co2_mass_kg,
    :final_top_seal_total_co2_mass_kg,
    :final_complete_top_seal_total_co2_mass_kg,
    :final_overburden_total_co2_mass_kg,
    :maximum_fault_pressure_change_pa,
    :maximum_qoi_evaluation_seconds,
    :interface_flux_method,
    :interface_flux_integration_note
]

function production_qoi_write_case_summary!(
        context,
        global_rows,
        interface_rows
    )
    isempty(global_rows) && return nothing
    final = global_rows[end]
    storage_peak, storage_peak_time =
        production_qoi_peak_interface(
            interface_rows,
            "storage_to_fault"
        )
    outward_peak, outward_peak_time =
        production_qoi_peak_interface(
            interface_rows,
            "fault_to_nonfault"
        )
    summary = Dict{String, String}()
    function setvalue(key, value)
        summary[string(key)] = production_format_value(value)
    end
    setvalue(:schema_version, PRODUCTION_QOI_SCHEMA_VERSION)
    setvalue(:case_key, context.case_key)
    setvalue(
        :campaign_manifest_sha256,
        context.campaign_manifest_sha256
    )
    setvalue(:final_step, parse(Int, final["step"]))
    setvalue(:final_time_seconds, parse(Float64, final["time_seconds"]))
    setvalue(:final_time_years, parse(Float64, final["time_years"]))
    setvalue(:arrival_sg_threshold, PRODUCTION_QOI_SG_THRESHOLDS[1])
    setvalue(
        :first_fault_arrival_years,
        production_qoi_first_arrival_years(
            global_rows,
            "fault_gas_saturation_max"
        )
    )
    setvalue(
        :first_top_seal_arrival_years,
        production_qoi_first_arrival_years(
            global_rows,
            "top_seal_gas_saturation_max"
        )
    )
    setvalue(
        :first_complete_top_seal_arrival_years,
        production_qoi_first_arrival_years(
            global_rows,
            "complete_top_seal_gas_saturation_max"
        )
    )
    setvalue(
        :first_overburden_arrival_years,
        production_qoi_first_arrival_years(
            global_rows,
            "overburden_gas_saturation_max"
        )
    )
    setvalue(
        :peak_storage_to_fault_forward_rate_kg_s,
        storage_peak
    )
    setvalue(
        :peak_storage_to_fault_forward_rate_time_years,
        storage_peak_time
    )
    setvalue(
        :peak_fault_to_nonfault_forward_rate_kg_s,
        outward_peak
    )
    setvalue(
        :peak_fault_to_nonfault_forward_rate_time_years,
        outward_peak_time
    )
    for (target, source) in (
            (:final_domain_mobile_free_co2_mass_kg,
                "domain_mobile_free_co2_mass_kg"),
            (:final_domain_immobile_free_co2_mass_kg,
                "domain_immobile_free_co2_mass_kg"),
            (:final_domain_dissolved_co2_mass_kg,
                "domain_dissolved_co2_mass_kg"),
            (:final_domain_total_co2_mass_kg,
                "domain_total_co2_mass_kg"),
            (:final_net_domain_co2_change_kg,
                "net_domain_co2_change_kg"),
            (:final_storage_total_co2_mass_kg,
                "storage_total_co2_mass_kg"),
            (:final_fault_total_co2_mass_kg,
                "fault_total_co2_mass_kg"),
            (:final_top_seal_total_co2_mass_kg,
                "top_seal_total_co2_mass_kg"),
            (:final_complete_top_seal_total_co2_mass_kg,
                "complete_top_seal_total_co2_mass_kg"),
            (:final_overburden_total_co2_mass_kg,
                "overburden_total_co2_mass_kg")
        )
        setvalue(target, parse(Float64, final[source]))
    end
    setvalue(
        :maximum_fault_pressure_change_pa,
        maximum(
            parse(Float64, row["fault_pressure_change_max_pa"])
            for row in global_rows
        )
    )
    setvalue(
        :maximum_qoi_evaluation_seconds,
        maximum(
            parse(Float64, row["qoi_evaluation_seconds"])
            for row in global_rows
        )
    )
    setvalue(:interface_flux_method, PRODUCTION_QOI_FLUX_METHOD)
    setvalue(
        :interface_flux_integration_note,
        "Rates are instantaneous at report endpoints; no cumulative " *
        "interface transfer is claimed across adaptive ministeps."
    )
    production_qoi_write_dict_table(
        joinpath(context.summary_dir, "leakage_case_summary.tsv"),
        PRODUCTION_QOI_CASE_SUMMARY_COLUMNS,
        [summary]
    )
    return summary
end

function production_consolidate_qoi!(
        context::ProductionQoIContext;
        require_complete::Bool = false,
        final_schedule_step::Integer = 0
    )
    indices = production_qoi_row_indices(context)
    isempty(indices) && return nothing
    expected_latest = require_complete ? final_schedule_step : maximum(indices)
    indices == collect(1:expected_latest) || error(
        "QoI output has report steps $(join(indices, ",")); expected " *
        "the complete prefix 1:$expected_latest."
    )
    global_rows = Dict{String, String}[]
    region_rows = Dict{String, String}[]
    interface_rows = Dict{String, String}[]
    for step in 1:expected_latest
        rows = production_qoi_validate_bundle(
            context,
            production_qoi_row_path(context, step),
            step
        )
        for row in rows
            if row["record_type"] == "global"
                push!(global_rows, row)
            elseif row["record_type"] == "region"
                push!(region_rows, row)
            elseif row["record_type"] == "interface"
                push!(interface_rows, row)
            end
        end
    end
    production_qoi_write_dict_table(
        joinpath(context.summary_dir, "leakage_global_steps.tsv"),
        PRODUCTION_QOI_GLOBAL_COLUMNS,
        global_rows
    )
    production_qoi_write_dict_table(
        joinpath(
            context.summary_dir,
            "regional_co2_inventory_steps.tsv"
        ),
        PRODUCTION_QOI_REGION_COLUMNS,
        region_rows
    )
    production_qoi_write_dict_table(
        joinpath(context.summary_dir, "interface_flux_steps.tsv"),
        PRODUCTION_QOI_INTERFACE_COLUMNS,
        interface_rows
    )
    production_qoi_write_case_summary!(
        context,
        global_rows,
        interface_rows
    )
    if require_complete
        marker = (
            schema_version = PRODUCTION_QOI_SCHEMA_VERSION,
            status = "complete",
            case_key = context.case_key,
            schedule_steps = final_schedule_step,
            primary_label_sha256 = context.primary_label_sha256,
            region_manifest_sha256 = context.region_manifest_sha256,
            interface_manifest_sha256 = context.interface_manifest_sha256,
            completed_utc = string(Dates.now(Dates.UTC))
        )
        production_write_named_row(
            joinpath(context.summary_dir, "QOI_OUTPUT_COMPLETE.tsv"),
            marker
        )
    end
    return (
        global_rows = length(global_rows),
        region_rows = length(region_rows),
        interface_rows = length(interface_rows)
    )
end
