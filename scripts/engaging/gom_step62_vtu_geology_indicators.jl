module GoMStep62VtuGeologyIndicators

export build_gom_step62_vtu_geology_indicators

function integer_vector(container, key; length_expected = nothing)
    haskey(container, key) || error("Missing required geology field '$key'.")
    raw = Float64.(vec(container[key]))
    all(isfinite, raw) ||
        error("Geology field '$key' contains a non-finite value.")
    all(isinteger, raw) ||
        error("Geology field '$key' contains a non-integer value.")
    values = Int.(raw)
    if !isnothing(length_expected)
        length(values) == length_expected || error(
            "Geology field '$key' has $(length(values)) values; expected " *
            "$length_expected."
        )
    end
    return values
end

function unique_cells(container, key, nc; length_expected = nothing)
    cells = integer_vector(container, key; length_expected)
    all(cell -> 1 <= cell <= nc, cells) ||
        error("Geology field '$key' contains an out-of-range cell index.")
    length(unique(cells)) == length(cells) ||
        error("Geology field '$key' contains duplicate cell indices.")
    return sort(cells)
end

"""
Build the categorical geology indicators used by Step62 VTU exports.

`fault_region_flag`:

* `0`: outside the complete fault domain
* `1`: PREDICT fault cells
* `2`: non-PREDICT fault cells

`stratigraphy_region_flag`:

* `0`: outside the paired Al/Ar stratigraphy
* `1`: sand stratigraphic cells (`facies_id == 1`)
* `2`: clay stratigraphic cells (`facies_id == 2`)

The classifications come from the exact split-input metadata and are
cross-checked against the assembled masks and primary UCIDs. They are never
inferred from rock properties, saturation regions, or spatial thresholds.
"""
function build_gom_step62_vtu_geology_indicators(mrst, specific)
    grid = mrst["G"]
    nc = Int(round(grid["cells"]["num"]))
    masks = mrst["masks"]
    qoi = mrst["qoi_semantics"]
    String(qoi["schema"]) == "gom_qoi_semantics_v1" ||
        error("Unsupported QoI semantic schema $(qoi["schema"]).")

    primary = integer_vector(qoi, "primary_unit_id"; length_expected = nc)
    fault_unit_ids = Set(integer_vector(qoi, "fault_unit_ids"))
    predict_unit_ids = Set(integer_vector(qoi, "predict_fault_unit_ids"))
    nonpredict_unit_ids =
        Set(integer_vector(qoi, "nonpredict_fault_unit_ids"))
    stratigraphy_unit_ids =
        Set(integer_vector(qoi, "combined_stratigraphy_unit_ids"))

    isempty(intersect(predict_unit_ids, nonpredict_unit_ids)) ||
        error("PREDICT and non-PREDICT fault UCIDs overlap.")
    union(predict_unit_ids, nonpredict_unit_ids) == fault_unit_ids ||
        error("PREDICT and non-PREDICT UCIDs do not partition the fault UCIDs.")

    fault_cells = unique_cells(masks, "fault_all_cells", nc)
    mask_fault = Bool.(vec(masks["isFaultCell"]))
    length(mask_fault) == nc || error("Fault mask has the wrong length.")
    findall(mask_fault) == fault_cells ||
        error("Fault mask does not match masks.fault_all_cells.")

    primary_fault_cells = findall(in(fault_unit_ids), primary)
    primary_fault_cells == fault_cells ||
        error("Complete fault mask does not match the primary fault UCIDs.")
    predict_fault_cells = findall(in(predict_unit_ids), primary)
    nonpredict_fault_cells = findall(in(nonpredict_unit_ids), primary)
    vcat(predict_fault_cells, nonpredict_fault_cells) |> sort == fault_cells ||
        error("PREDICT/non-PREDICT cells do not partition the fault domain.")

    haskey(specific, "fault") ||
        error("Specific input has no PREDICT fault metadata.")
    specific_predict_cells =
        unique_cells(specific["fault"], "cells", nc)
    specific_predict_cells == predict_fault_cells || error(
        "Specific PREDICT fault cells do not match primary PREDICT UCIDs."
    )

    haskey(specific, "stratigraphy") ||
        error("Specific input has no stratigraphy metadata.")
    stratigraphy = specific["stratigraphy"]
    stratigraphy_cells = unique_cells(stratigraphy, "cells", nc)
    nstrat = length(stratigraphy_cells)
    facies_ids =
        integer_vector(stratigraphy, "facies_id"; length_expected = nstrat)
    stratigraphic_ids = integer_vector(
        stratigraphy,
        "stratigraphic_unit_id";
        length_expected = nstrat
    )
    all(in((1, 2)), facies_ids) ||
        error("Stratigraphic facies IDs must be 1 (sand) or 2 (clay).")

    # The facies and unit arrays align with the unsorted source cell array.
    source_stratigraphy_cells =
        integer_vector(stratigraphy, "cells"; length_expected = nstrat)
    primary_stratigraphy_cells =
        findall(in(stratigraphy_unit_ids), primary)
    primary_stratigraphy_cells == stratigraphy_cells ||
        error("Stratigraphy cells do not match the primary stratigraphy UCIDs.")
    mask_stratigraphy = Bool.(vec(masks["isSpecificStratigraphyCell"]))
    length(mask_stratigraphy) == nc ||
        error("Specific-stratigraphy mask has the wrong length.")
    findall(mask_stratigraphy) == stratigraphy_cells ||
        error("Specific-stratigraphy mask does not match the cell metadata.")

    isempty(intersect(fault_cells, stratigraphy_cells)) ||
        error("Fault and stratigraphy domains overlap.")

    fault_region_flag = zeros(Int32, nc)
    fault_region_flag[nonpredict_fault_cells] .= Int32(2)
    fault_region_flag[predict_fault_cells] .= Int32(1)

    stratigraphy_region_flag = zeros(Int32, nc)
    stratigraphy_region_flag[source_stratigraphy_cells] .= Int32.(facies_ids)
    stratigraphic_unit_id = zeros(Int32, nc)
    stratigraphic_unit_id[source_stratigraphy_cells] .=
        Int32.(stratigraphic_ids)

    sort(unique(fault_region_flag)) == Int32[0, 1, 2] ||
        error("Fault indicator does not contain exactly values 0, 1, and 2.")
    sort(unique(stratigraphy_region_flag)) == Int32[0, 1, 2] || error(
        "Stratigraphy indicator does not contain exactly values 0, 1, and 2."
    )
    findall(==(Int32(1)), fault_region_flag) == predict_fault_cells ||
        error("Fault indicator value 1 does not exactly identify PREDICT cells.")
    findall(==(Int32(2)), fault_region_flag) == nonpredict_fault_cells ||
        error(
            "Fault indicator value 2 does not exactly identify non-PREDICT cells."
        )

    stratigraphy_sand_cells =
        sort(source_stratigraphy_cells[facies_ids .== 1])
    stratigraphy_clay_cells =
        sort(source_stratigraphy_cells[facies_ids .== 2])
    findall(==(Int32(1)), stratigraphy_region_flag) ==
        stratigraphy_sand_cells || error(
        "Stratigraphy indicator value 1 does not exactly identify sand cells."
    )
    findall(==(Int32(2)), stratigraphy_region_flag) ==
        stratigraphy_clay_cells || error(
        "Stratigraphy indicator value 2 does not exactly identify clay cells."
    )
    all(
        (fault_region_flag .== 0) .|
        (stratigraphy_region_flag .== 0)
    ) || error("Fault and stratigraphy indicators overlap.")

    return (
        fault_region_flag = fault_region_flag,
        stratigraphy_region_flag = stratigraphy_region_flag,
        stratigraphic_unit_id = stratigraphic_unit_id,
        fault_cells = fault_cells,
        predict_fault_cells = predict_fault_cells,
        nonpredict_fault_cells = nonpredict_fault_cells,
        stratigraphy_cells = stratigraphy_cells,
        stratigraphy_sand_cells = stratigraphy_sand_cells,
        stratigraphy_clay_cells = stratigraphy_clay_cells
    )
end

end
