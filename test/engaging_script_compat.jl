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

    # Strict metadata writing reads the locked physics environment. Every
    # effective-Pc batch entry point that writes metadata must therefore load
    # that environment after resolving its case and before the first write.
    effective_batch_scripts = sort(filter(
        path -> endswith(path, ".sbatch") && occursin(
            "gom_step62_effective_pc_global_plateau_",
            basename(path)
        ),
        readdir(scripts_dir; join = true)
    ))
    metadata_writers = 0
    for path in effective_batch_scripts
        source = read(path, String)
        write_match = findfirst("gom_effective_pc_write_metadata", source)
        isnothing(write_match) && continue
        metadata_writers += 1
        export_match = findfirst(
            "gom_effective_pc_export_locked_physics",
            source
        )
        @test !isnothing(export_match)
        if !isnothing(export_match)
            @test first(export_match) < first(write_match)
        end
    end
    @test metadata_writers >= 6

    # A successful canary is an official production shard. Preserve the
    # no-rerun contract: the launcher must classify exact durable shards as
    # reused, and the finalizer must independently validate every new and
    # reused shard before certifying combined coverage.
    ensemble_submit = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_ensemble_submit.sh"
        ),
        String
    )
    production_finalize = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_finalize.sbatch"
        ),
        String
    )
    shard_archive = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_shard_archive.sbatch"
        ),
        String
    )
    for source in (ensemble_submit, production_finalize, shard_archive)
        @test occursin("gom_step62_production_shard_verify.py", source)
    end
    @test occursin("mode=reused", ensemble_submit)
    @test occursin("GOM_PRODUCTION_REUSED_SHARD_RANGES", ensemble_submit)
    @test occursin(
        "all_shard_control_planes_validated=true",
        production_finalize
    )
    @test occursin("SHARD_CONTROL_VALIDATION.tsv", production_finalize)
    @test occursin("sha256sums_sha256=", shard_archive)

    # Engaging counts pending array elements against a per-user QOS ceiling.
    # The rolling control plane must keep the scientific checkout pinned,
    # bound each wave to two shards, and finish with the normal full-selection
    # finalizer rather than inventing a second campaign-completion path.
    rolling_submit = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_rolling_submit.sh"
        ),
        String
    )
    rolling_step = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_rolling_step.sh"
        ),
        String
    )
    rolling_controller = read(
        joinpath(
            scripts_dir,
            "gom_step62_production_rolling_controller.sbatch"
        ),
        String
    )
    @test occursin("GOM_PRODUCTION_ROLLING_SOURCE_RECEIPT", rolling_submit)
    @test occursin("test \"\$wave_cases\" -le 100", rolling_step)
    @test occursin("test \"\$shard_window\" -le 2", rolling_step)
    @test occursin("GOM_PRODUCTION_CONFIRM_FULL_1620=YES", rolling_step)
    @test occursin("CAMPAIGN_COMPLETE", rolling_step)
    @test occursin("gom_step62_production_rolling_step.sh", rolling_controller)

    # Schema-2 recovery is an orchestration-only layer around the manifest's
    # original scientific checkout. It must audit the full affected shard,
    # lock each source tree, regenerate the entire shard VTU set, and reuse
    # the normal atomic archive/finalizer without claiming campaign coverage.
    recovery_names = [
        "gom_step62_production_schema2_recovery_common.sh",
        "gom_step62_production_schema2_recovery_gate.sbatch",
        "gom_step62_production_schema2_recovery_case.sbatch",
        "gom_step62_production_schema2_recovery_vtu.sbatch",
        "gom_step62_production_schema2_recovery_complete.sbatch",
        "gom_step62_production_schema2_recovery_submit.sh",
    ]
    recovery_sources = Dict(
        name => read(joinpath(scripts_dir, name), String)
        for name in recovery_names
    )
    recovery_common = recovery_sources[recovery_names[1]]
    recovery_gate = recovery_sources[recovery_names[2]]
    recovery_case = recovery_sources[recovery_names[3]]
    recovery_vtu = recovery_sources[recovery_names[4]]
    recovery_complete = recovery_sources[recovery_names[5]]
    recovery_submit = recovery_sources[recovery_names[6]]
    @test occursin("rev-parse HEAD:src", recovery_common)
    @test occursin("cmp -s \"\$recovery_workflow_repo/Manifest.toml\"", recovery_common)
    @test occursin("Unselected task \$task is incomplete", recovery_gate)
    @test occursin("flock -n", recovery_gate)
    @test occursin("flock -n", recovery_case)
    @test occursin("recovery_quarantine", recovery_case)
    @test occursin(
        "\$recovery_sim_repo/scripts/engaging/gom_sampling_cases.sbatch",
        recovery_case
    )
    @test occursin(
        "gom_step62_effective_pc_global_plateau_vtu.sbatch",
        recovery_vtu
    )
    @test occursin(
        r"(?s)case \"\$GOM_RECOVERY_TASK_SELECTED\" in.*true\).*recovery_case_dir/PASS.*false\).*test ! -e \"\$recovery_case_dir\"",
        recovery_vtu
    )
    @test occursin("campaign_complete_created=false", recovery_complete)
    @test occursin(
        "checksum_tmp=\"\$result_dir/RECOVERY_CONTROL_SHA256SUMS.tmp\"",
        recovery_complete,
    )
    @test occursin(
        "rm -rf -- \"\$durable_control\"",
        recovery_complete,
    )
    @test occursin(
        "GOM_RECOVERY_COMPLETION_SCRIPT_COMMIT:-\$GOM_RECOVERY_WORKFLOW_COMMIT",
        recovery_complete,
    )
    @test occursin(
        "completion_script_commit=\$completion_script_commit",
        recovery_complete,
    )
    @test !occursin(
        "> RECOVERY_CONTROL_SHA256SUMS.tmp.\$SLURM_JOB_ID",
        recovery_complete,
    )
    @test occursin("gom_step62_production_shard_archive.sbatch", recovery_submit)
    @test occursin("gom_step62_production_finalize.sbatch", recovery_submit)
    @test occursin("afterok:\$case_job", recovery_submit)
    @test occursin("afterok:\$vtu_job", recovery_submit)
end
