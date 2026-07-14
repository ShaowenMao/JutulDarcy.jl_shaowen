using JutulDarcy, Test

function split_test_sgof(scale)
    return [
        0.0 0.0 1.0 0.0
        0.5 0.2 0.3 1.0e5*scale
        0.8 1.0 0.0 2.0e5*scale
    ]
end

@testset "MRST reservoir-ready split input" begin
    base_table = split_test_sgof(1.0)
    common = Dict{String, Any}(
        "rock" => Dict{String, Any}(
            "poro" => [0.2, 0.2, NaN, NaN],
            "perm" => reshape([1.0, 1.0, NaN, NaN], :, 1),
            "regions" => Dict{String, Any}(
                "saturation" => [1.0, 1.0, 2.0, 2.0],
                "imbibition" => [4.0, 4.0, 5.0, 5.0]
            )
        ),
        "deck" => Dict{String, Any}(
            "PROPS" => Dict{String, Any}(
                "SGOF" => reshape(Any[base_table, zeros(0, 0), zeros(0, 0)], :, 1)
            ),
            "RUNSPEC" => Dict{String, Any}(
                "TABDIMS" => [3.0]
            )
        )
    )

    custom_tables = Any[split_test_sgof(2.0), split_test_sgof(3.0)]
    specific = Dict{String, Any}(
        "schema" => "gom_jutul_split_specific_v2",
        "fault" => Dict{String, Any}(
            "cells" => [3.0, 4.0],
            "poro" => [0.15, 0.25],
            "perm" => reshape([2.0, 3.0], :, 1),
            "saturation_region" => [2.0, 3.0],
            "fluid_tables" => Dict{String, Any}(
                "SGOF" => Dict{String, Any}(
                    "regions" => [2.0, 3.0],
                    "tables" => reshape(custom_tables, :, 1)
                )
            )
        )
    )

    assembled = JutulDarcy.assemble_mrst_split_case(common, specific)
    regions = assembled["rock"]["regions"]
    sgof = vec(assembled["deck"]["PROPS"]["SGOF"])

    @test assembled["rock"]["poro"] == [0.2, 0.2, 0.15, 0.25]
    @test vec(assembled["rock"]["perm"]) == [1.0, 1.0, 2.0, 3.0]
    @test Int.(vec(regions["saturation"])) == [1, 1, 2, 3]
    @test !haskey(regions, "imbibition")
    @test length(sgof) == 3
    @test sgof[1] == base_table
    @test sgof[2] == custom_tables[1]
    @test sgof[3] == custom_tables[2]
    @test assembled["deck"]["RUNSPEC"]["NOHYST"] === true
    @test assembled["deck"]["RUNSPEC"]["TABDIMS"][1] == 3.0
    @test assembled["fault_saturation_domain_mode"] == "reservoir_ready_explicit"
end
