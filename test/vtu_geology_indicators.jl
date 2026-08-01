using Test

include(joinpath(
    @__DIR__,
    "..",
    "scripts",
    "engaging",
    "gom_step62_vtu_geology_indicators.jl"
))
using .GoMStep62VtuGeologyIndicators

@testset "Step62 VTU categorical geology indicators" begin
    primary = Int[
        1, 2, 3, 25, 26, 27, 31, 32, 33, 58, 23, 24, 1, 22, 58
    ]
    nc = length(primary)
    fault_cells = Int[4, 5, 6, 7, 8, 9]
    stratigraphy_cells = Int[2, 3, 14]
    fault_mask = falses(nc)
    fault_mask[fault_cells] .= true
    stratigraphy_mask = falses(nc)
    stratigraphy_mask[stratigraphy_cells] .= true

    mrst = Dict{String, Any}(
        "G" => Dict("cells" => Dict("num" => nc)),
        "masks" => Dict(
            "fault_all_cells" => reverse(fault_cells),
            "isFaultCell" => fault_mask,
            "isSpecificStratigraphyCell" => stratigraphy_mask
        ),
        "qoi_semantics" => Dict(
            "schema" => "gom_qoi_semantics_v1",
            "primary_unit_id" => primary,
            "fault_unit_ids" => collect(25:33),
            "predict_fault_unit_ids" => collect(26:31),
            "nonpredict_fault_unit_ids" => [25, 32, 33],
            "combined_stratigraphy_unit_ids" => collect(2:22)
        )
    )
    specific = Dict{String, Any}(
        "fault" => Dict("cells" => [7, 5, 6]),
        "stratigraphy" => Dict(
            "cells" => [14, 2, 3],
            "facies_id" => [1, 1, 2],
            "stratigraphic_unit_id" => [21, 1, 2]
        )
    )

    result = build_gom_step62_vtu_geology_indicators(mrst, specific)
    @test result.fault_region_flag ==
        Int32[0, 0, 0, 2, 1, 1, 1, 2, 2, 0, 0, 0, 0, 0, 0]
    @test result.stratigraphy_region_flag ==
        Int32[0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]
    @test result.stratigraphic_unit_id ==
        Int32[0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 21, 0]
    @test result.predict_fault_cells == [5, 6, 7]
    @test result.nonpredict_fault_cells == [4, 8, 9]
    @test result.stratigraphy_sand_cells == [2, 14]
    @test result.stratigraphy_clay_cells == [3]

    wrong_predict = deepcopy(specific)
    wrong_predict["fault"]["cells"] = [4, 5, 6]
    @test_throws ErrorException build_gom_step62_vtu_geology_indicators(
        mrst,
        wrong_predict
    )

    wrong_facies = deepcopy(specific)
    wrong_facies["stratigraphy"]["facies_id"] = [1, 3, 2]
    @test_throws ErrorException build_gom_step62_vtu_geology_indicators(
        mrst,
        wrong_facies
    )
end
