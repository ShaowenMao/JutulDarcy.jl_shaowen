using JutulDarcy
import MAT

length(ARGS) == 4 || error(
    "Usage: audit_gom_step62_zero_pc.jl " *
    "COMMON_MAT SPECIFIC_MAT SUMMARY_PATH DETAIL_PATH"
)
common_path, specific_path, summary_path, detail_path = ARGS

mrst = JutulDarcy.read_mrst_split_case(
    common_path,
    specific_path;
    validate = true,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau",
    fault_pc_entry_sg_max = 1.0e-4,
    explicit_fault_hysteresis_mode = "reservoir"
)
specific = MAT.matread(specific_path)

regions = mrst["rock"]["regions"]
satnum = Int.(round.(vec(regions["saturation"])))
imbnum = Int.(round.(vec(regions["imbibition"])))
sgof = vec(mrst["deck"]["PROPS"]["SGOF"])
fault_summary = mrst["fault_saturation_domain_summary"]
drainage_regions = Int(fault_summary["drainage_regions"])
length(sgof) == 2*drainage_regions ||
    error("Expected paired drainage/imbibition SGOF tables.")

pc_values(table) = Float64.(table[:, 4])
is_all_zero_pc(table) = all(iszero, pc_values(table))

zero_drainage = [
    region for region in 1:drainage_regions
    if is_all_zero_pc(sgof[region])
]
zero_imbibition = [
    region for region in (drainage_regions + 1):length(sgof)
    if is_all_zero_pc(sgof[region])
]
zero_cell = in.(satnum, Ref(Set(zero_drainage)))

masks = mrst["masks"]
fault_cell = Bool.(vec(masks["isFaultCell"]))
stratigraphy_cell = Bool.(vec(masks["isSpecificStratigraphyCell"]))
length(fault_cell) == length(satnum) ||
    error("Fault mask does not align with SATNUM.")
length(stratigraphy_cell) == length(satnum) ||
    error("Stratigraphy mask does not align with SATNUM.")

stratigraphy = specific["stratigraphy"]
stratigraphy_cells = Int.(round.(vec(stratigraphy["cells"])))
stratigraphy_satnum =
    Int.(round.(vec(stratigraphy["saturation_region"])))
side_id = Int.(round.(vec(stratigraphy["side_id"])))
facies_id = Int.(round.(vec(stratigraphy["facies_id"])))
unit_id = Int.(round.(vec(stratigraphy["stratigraphic_unit_id"])))
length(stratigraphy_cells) == length(stratigraphy_satnum) ==
    length(side_id) == length(facies_id) == length(unit_id) ||
    error("Stratigraphy metadata vectors have inconsistent lengths.")
satnum[stratigraphy_cells] == stratigraphy_satnum ||
    error("Assembled SATNUM does not match stratigraphy-specific SATNUM.")

case_id = String(specific["level3_case_name"])
geology_id = String(specific["geology_id"])
zero_drainage_text = join(zero_drainage, ",")
zero_imbibition_text = join(zero_imbibition, ",")

mkpath(dirname(summary_path))
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "case_id=$case_id")
    println(io, "geology_id=$geology_id")
    println(io, "cells=$(length(satnum))")
    println(io, "drainage_regions=$drainage_regions")
    println(io, "total_sgof_tables=$(length(sgof))")
    println(io, "zero_pc_drainage_regions=$zero_drainage_text")
    println(io, "zero_pc_imbibition_regions=$zero_imbibition_text")
    println(io, "zero_pc_cell_count=$(count(zero_cell))")
    println(io, "zero_pc_2d_footprint_count=$(count(zero_cell) ÷ 87)")
    println(
        io,
        "zero_pc_stratigraphy_cell_count=" *
        string(count(zero_cell .& stratigraphy_cell))
    )
    println(
        io,
        "zero_pc_stratigraphy_2d_footprint_count=" *
        string(count(zero_cell .& stratigraphy_cell) ÷ 87)
    )
    println(
        io,
        "zero_pc_fault_cell_count=" *
        string(count(zero_cell .& fault_cell))
    )
    println(
        io,
        "zero_pc_outside_fault_and_stratigraphy_cell_count=" *
        string(count(zero_cell .& .!fault_cell .& .!stratigraphy_cell))
    )
    println(
        io,
        "zero_pc_outside_fault_and_stratigraphy_2d_footprint_count=" *
        string(
            count(zero_cell .& .!fault_cell .& .!stratigraphy_cell) ÷ 87
        )
    )
    for side in 1:2
        side_mask = side_id .== side
        side_name = side == 1 ? "footwall_Al" : "hangingwall_Ar"
        println(
            io,
            "zero_pc_$(side_name)_cell_count=" *
            string(count(side_mask .& in.(stratigraphy_satnum, Ref(Set(zero_drainage)))))
        )
    end
    for region in 1:min(5, drainage_regions)
        table = sgof[region]
        pc = pc_values(table)
        println(io, "region_$(region)_cell_count=$(count(==(region), satnum))")
        println(io, "region_$(region)_pc_row_count=$(length(pc))")
        println(io, "region_$(region)_pc_min_pa=$(minimum(pc))")
        println(io, "region_$(region)_pc_max_pa=$(maximum(pc))")
        println(io, "region_$(region)_pc_all_zero=$(all(iszero, pc))")
    end
    for region in zero_drainage
        paired = drainage_regions + region
        println(io, "zero_pc_region_$(region)_paired_imbibition=$paired")
        println(
            io,
            "zero_pc_region_$(region)_paired_imbibition_all_zero=" *
            string(is_all_zero_pc(sgof[paired]))
        )
    end
end

open(detail_path, "w") do io
    println(
        io,
        join(
            [
                "side_id",
                "side_name",
                "unit_id",
                "facies_id",
                "facies_name",
                "saturation_region",
                "pc_all_zero",
                "cell_count",
                "footprint_2d_count"
            ],
            '\t'
        )
    )
    for side in 1:2
        side_name = side == 1 ? "footwall_Al" : "hangingwall_Ar"
        for unit in 1:21
            selection = (side_id .== side) .& (unit_id .== unit)
            count(selection) > 0 || error(
                "Missing stratigraphy cells for side $side, unit $unit."
            )
            facies_values = unique(facies_id[selection])
            saturation_values = unique(stratigraphy_satnum[selection])
            length(facies_values) == 1 ||
                error("Nonuniform facies for side $side, unit $unit.")
            length(saturation_values) == 1 ||
                error("Nonuniform SATNUM for side $side, unit $unit.")
            facies = only(facies_values)
            saturation = only(saturation_values)
            facies_name = facies == 1 ? "sand" :
                facies == 2 ? "clay" : "unknown"
            n = count(selection)
            println(
                io,
                join(
                    [
                        side,
                        side_name,
                        unit,
                        facies,
                        facies_name,
                        saturation,
                        saturation in zero_drainage,
                        n,
                        n ÷ 87
                    ],
                    '\t'
                )
            )
        end
    end
end

println(
    "GOM_ZERO_PC_AUDIT_PASS " *
    "case=$case_id zero_drainage=$zero_drainage_text " *
    "zero_imbibition=$zero_imbibition_text summary=$summary_path"
)
