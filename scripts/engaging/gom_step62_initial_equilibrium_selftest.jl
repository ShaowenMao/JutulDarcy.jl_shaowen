using Test

include(joinpath(@__DIR__, "gom_step62_initial_equilibrium_common.jl"))

@testset "Step62 initial-equilibrium helpers" begin
    @test gom_equilibrium_parse_report_years("0.1,1,10") == [0.1, 1.0, 10.0]
    @test_throws ErrorException gom_equilibrium_parse_report_years("1,1")
    @test_throws ErrorException gom_equilibrium_parse_report_years("1,0")
    @test gom_equilibrium_parse_task_spec("all", [3, 1, 2]) == [1, 2, 3]
    @test gom_equilibrium_parse_task_spec("1,3-4", 1:5) == [1, 3, 4]
    @test_throws ErrorException gom_equilibrium_parse_task_spec("1,6", 1:5)

    moments = gom_equilibrium_moments([-2.0, 0.0, 2.0])
    @test moments.count == 3
    @test moments.minimum == -2.0
    @test moments.maximum == 2.0
    @test moments.mean == 0.0
    @test moments.max_abs == 2.0

    distribution = gom_equilibrium_absolute_distribution([-2.0, 0.0, 1.0])
    @test distribution.count == 3
    @test distribution.maximum == 2.0

    mktempdir() do directory
        source = joinpath(directory, "source.txt")
        write(source, "equilibrium\n")
        expected_sha = bytes2hex(SHA.sha256(Vector{UInt8}(codeunits("equilibrium\n"))))
        @test gom_equilibrium_file_sha256(source) == expected_sha

        table = joinpath(directory, "table.tsv")
        rows = [Dict{Symbol, Any}(:name => "test", :value => 1.5)]
        gom_equilibrium_write_table(table, [:name, :value], rows)
        @test readlines(table) == ["name\tvalue", "test\t1.5"]
    end
end

println("GOM_STEP62_INITIAL_EQUILIBRIUM_SELFTEST_PASS")
