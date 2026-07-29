using Test

@testset "Engaging Julia script compatibility" begin
    scripts_dir = normpath(joinpath(@__DIR__, "..", "scripts", "engaging"))
    julia_scripts = sort(filter(
        path -> endswith(path, ".jl"),
        readdir(scripts_dir; join = true)
    ))
    @test !isempty(julia_scripts)

    # Julia 1.10 supports enumerate(iter), but unlike Python it does not
    # accept a start keyword. This pattern previously allowed a complete
    # simulation to fail during its final TSV validation.
    # Keep the scan deliberately conservative and multiline-aware. A
    # validator script is small enough that a false positive should be
    # reviewed rather than allowing a cluster-incompatible call through.
    unsupported_enumerate_start =
        r"(?s)\benumerate\s*\(.{0,4096}?\bstart\s*="
    @test occursin(
        unsupported_enumerate_start,
        "enumerate(items, start = 2)"
    )
    @test occursin(
        unsupported_enumerate_start,
        "enumerate(\n    items;\n    start = 2\n)"
    )
    for path in julia_scripts
        @test !occursin(unsupported_enumerate_start, read(path, String))
    end

    # Preserve human-readable TSV line numbering without relying on a
    # version-specific iterator API.
    lines = ["name\tvalue", "first\t1", "second\t2"]
    observed = Tuple{Int, String}[]
    for (offset, line) in enumerate(lines[2:end])
        push!(observed, (offset + 1, line))
    end
    @test observed == [(2, "first\t1"), (3, "second\t2")]
end
