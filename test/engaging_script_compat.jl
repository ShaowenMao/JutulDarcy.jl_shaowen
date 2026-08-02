using Test

@testset "Engaging Julia script compatibility" begin
    scripts_dir = normpath(joinpath(@__DIR__, "..", "scripts", "engaging"))
    julia_scripts = sort(filter(
        path -> endswith(path, ".jl"),
        readdir(scripts_dir; join = true)
    ))
    @test !isempty(julia_scripts)

    # Parse every cluster entry point with the Julia runtime executing this
    # test. Meta.parseall records syntax failures as :error/:incomplete nodes
    # instead of always throwing, so inspect the complete expression tree.
    function collect_parse_issues!(issues, node)
        node isa Expr || return issues
        if node.head === :error || node.head === :incomplete
            push!(issues, node)
        end
        for argument in node.args
            collect_parse_issues!(issues, argument)
        end
        return issues
    end
    for path in julia_scripts
        parsed = Meta.parseall(read(path, String); filename = path)
        parse_issues = Expr[]
        collect_parse_issues!(parse_issues, parsed)
        @test isempty(parse_issues)
    end

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

    # The effective-Pc validator must follow the current QoI output schema;
    # hard-coding its original schema 1 would make a scientifically complete
    # simulation fail only during final post-processing.
    effective_final = read(
        joinpath(
            scripts_dir,
            "gom_step62_effective_pc_global_plateau_final_check.jl"
        ),
        String
    )
    @test occursin(
        "JutulDarcy.PRODUCTION_QOI_SCHEMA_VERSION",
        effective_final
    )

    # The specialized effective-Pc smoke workflow is also the acceptance
    # launcher for task 1. Keep its interrupted-versus-uninterrupted control
    # aligned with the documented task-1/task-5 production contract.
    effective_smoke = read(
        joinpath(
            scripts_dir,
            "gom_step62_effective_pc_global_plateau_smoke.sbatch"
        ),
        String
    )
    @test occursin(
        r"(?s)SLURM_ARRAY_TASK_ID\" -eq 1.*SLURM_ARRAY_TASK_ID\" -eq 5",
        effective_smoke
    )

    # The effective-Pc acceptance launcher supports both its frozen legacy
    # seven-case manifest and task positions from the schema-2 full ensemble.
    # An unconditional seven-case assertion previously cancelled the entire
    # acceptance DAG before preflight.
    effective_campaign_check = read(
        joinpath(
            scripts_dir,
            "gom_step62_effective_pc_global_plateau_campaign_check.sbatch"
        ),
        String
    )
    @test occursin(
        "GOM_PRODUCTION_SCHEMA_VERSION\" -eq 1",
        effective_campaign_check
    )
    @test occursin(
        "GOM_PRODUCTION_ENSEMBLE_KIND\" = full_1620",
        effective_campaign_check
    )
    @test occursin(
        "GOM_PRODUCTION_CASE_COUNT\" -eq 1620",
        effective_campaign_check
    )
    @test occursin(
        "manifest_case_count=\$GOM_PRODUCTION_CASE_COUNT",
        effective_campaign_check
    )
end
