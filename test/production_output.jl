using Test
using JutulDarcy
import Jutul

function run_production_spe1(
        output_path;
        restart = false,
        stop_after_report_step = nothing
    )
    return simulate_mrst_case(
        joinpath(@__DIR__, "mrst", "spe1.mat");
        output_path = output_path,
        steps = 1:5,
        restart = restart,
        stop_after_report_step = stop_after_report_step,
        production_output_mode = true,
        production_summary_dir = joinpath(output_path, "summary"),
        production_retain_years =
            [3*86400/JutulDarcy.MRST_YEAR_SECONDS],
        production_rolling_checkpoints = 2,
        production_case_key = "spe1_production_test",
        production_campaign_manifest_sha256 = repeat("a", 64),
        production_require_hysteresis_history = false,
        in_memory_reports = 1,
        load_all_states_after_sim = false,
        load_all_reports_after_sim = false,
        info_level = -1,
        verbose = false
    )
end

@testset "Production output keeps four milestones plus rolling checkpoints" begin
    mktempdir() do root
        summary_dir = joinpath(root, "summary")
        row_dir = joinpath(summary_dir, "rows")
        retention_dir = joinpath(summary_dir, "retention")
        mkpath.((summary_dir, row_dir, retention_dir))
        milestones = [51, 78, 110, 210]
        policy = JutulDarcy.ProductionOutputPolicy(
            root,
            summary_dir,
            row_dir,
            retention_dir,
            collect(1.0:210.0),
            210,
            Set(milestones),
            [25.0, 50.0, 100.0, 1000.0],
            2,
            "four_milestone_test",
            repeat("c", 64),
            false,
            0,
            nothing,
            nothing,
            false,
            nothing
        )

        for step in (51, 78, 110, 111, 112)
            write(joinpath(root, "jutul_$step.jld2"), "checkpoint")
        end
        kept, deleted = JutulDarcy.production_delete_obsolete_restarts!(
            policy,
            112
        )
        @test kept == [51, 78, 110, 111, 112]
        @test isempty(deleted)

        write(joinpath(root, "jutul_210.jld2"), "checkpoint")
        kept, deleted = JutulDarcy.production_delete_obsolete_restarts!(
            policy,
            210
        )
        @test kept == milestones
        @test deleted == [111, 112]
        @test JutulDarcy.production_restart_indices(policy) == milestones
    end
end

@testset "Production configuration rejects extra restart keys" begin
    mktempdir() do root
        summary_dir = joinpath(root, "summary")
        policy = JutulDarcy.ProductionOutputPolicy(
            root,
            summary_dir,
            joinpath(summary_dir, "rows"),
            joinpath(summary_dir, "retention"),
            [1.0],
            1,
            Set{Int}(),
            Float64[],
            2,
            "config_key_test",
            repeat("b", 64),
            false,
            0,
            nothing,
            nothing,
            false,
            nothing
        )
        path = JutulDarcy.production_check_or_write_config!(policy)
        lines = readlines(path)
        open(path, "w") do io
            println(io, lines[1], '\t', "qoi_mode")
            println(io, lines[2], '\t', "required")
        end
        @test_throws ErrorException JutulDarcy.production_check_or_write_config!(
            policy
        )
    end
end

function restart_indices(path)
    return Jutul.valid_restart_indices(path)
end

function summary_indices(path)
    return JutulDarcy.production_scan_indices(
        joinpath(path, "summary", "rows"),
        JutulDarcy.PRODUCTION_ROW_PATTERN
    )
end

function final_reservoir_state(path)
    state, _ = Jutul.read_restart(path, 5)
    return state[:Reservoir]
end

@testset "Production output rolling retention and restart equivalence" begin
    mktempdir() do root
        resumed_path = joinpath(root, "resumed")
        uninterrupted_path = joinpath(root, "uninterrupted")
        corrupt_path = joinpath(root, "corrupt")

        mkpath(resumed_path)
        run_production_spe1(
            resumed_path;
            restart = false,
            stop_after_report_step = 3
        )
        @test restart_indices(resumed_path) == [2, 3]
        @test summary_indices(resumed_path) == collect(1:3)
        @test !isfile(
            joinpath(
                resumed_path,
                "summary",
                "PRODUCTION_OUTPUT_COMPLETE.tsv"
            )
        )

        run_production_spe1(resumed_path; restart = true)
        @test restart_indices(resumed_path) == [2, 5]
        @test summary_indices(resumed_path) == collect(1:5)
        @test isfile(
            joinpath(
                resumed_path,
                "summary",
                "PRODUCTION_OUTPUT_COMPLETE.tsv"
            )
        )
        @test length(
            readlines(joinpath(resumed_path, "summary", "report_steps.tsv"))
        ) == 6

        mkpath(uninterrupted_path)
        run_production_spe1(uninterrupted_path; restart = false)
        @test restart_indices(uninterrupted_path) == [2, 5]
        @test summary_indices(uninterrupted_path) == collect(1:5)

        resumed = final_reservoir_state(resumed_path)
        uninterrupted = final_reservoir_state(uninterrupted_path)
        for key in (:Pressure, :Saturations, :Rs)
            @test resumed[key] ≈ uninterrupted[key] rtol = 1.0e-12 atol = 0
        end

        # Recreate the interrupted three-step state and damage its highest
        # checkpoint to exercise quarantine/fallback.
        mkpath(corrupt_path)
        run_production_spe1(
            corrupt_path;
            restart = false,
            stop_after_report_step = 3
        )
        open(joinpath(corrupt_path, "jutul_3.jld2"), "w") do io
            write(io, "deliberately truncated")
        end
        run_production_spe1(corrupt_path; restart = true)
        @test restart_indices(corrupt_path) == [2, 5]
        @test summary_indices(corrupt_path) == collect(1:5)
        @test any(
            startswith("jutul_3.jld2.corrupt."),
            readdir(joinpath(corrupt_path, "summary", "quarantine"))
        )
        recovered = final_reservoir_state(corrupt_path)
        for key in (:Pressure, :Saturations, :Rs)
            @test recovered[key] ≈ uninterrupted[key] rtol = 1.0e-12 atol = 0
        end
    end
end
