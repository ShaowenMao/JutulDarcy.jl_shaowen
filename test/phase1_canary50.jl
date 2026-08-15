using Test

include(joinpath(
    @__DIR__,
    "..",
    "scripts",
    "engaging",
    "gom_step62_phase1_2430_select_canary50.jl",
))

function synthetic_phase1_metrics()
    metrics = CaseMetric[]
    task = 0
    realization_ids = vcat(collect(1:12), [101, 102, 103])
    for scenario in 1:6, geology in 1:27, realization in realization_ids
        task += 1
        phase = 0.17*scenario + 0.11*geology + 0.013*realization
        values = [
            sin(phase),
            cos(1.3*phase),
            sin(0.7*phase + geology/9),
            cos(0.5*phase + scenario/4),
            abs(sin(1.1*phase)),
            abs(cos(0.9*phase)),
            abs(sin(0.6*phase + 0.2)),
            abs(cos(0.8*phase + 0.3)),
            abs(sin(1.4*phase + 0.1)),
            abs(cos(1.6*phase + 0.4)),
        ]
        geology_id = "s$(lpad(scenario, 2, '0'))_c$(lpad(geology, 3, '0'))"
        case_key = "$(geology_id)_case$(lpad(realization, 2, '0'))"
        push!(metrics, CaseMetric(
            task,
            case_key,
            scenario,
            geology_id,
            realization,
            "case_$realization",
            "/synthetic/$case_key.mat",
            values...,
            NaN,
            NaN,
            NaN,
        ))
    end
    add_screening_scores!(metrics)
    return metrics
end

@testset "Phase-1 reusable canary selection" begin
    metrics = synthetic_phase1_metrics()
    @test length(metrics) == 2430
    embedded_tasks = [item.metric.task for item in select_cohort(metrics)]
    selected = select_canary50(metrics)
    selected_tasks = [item.metric.task for item in selected]
    @test length(selected) == 50
    @test length(unique(selected_tasks)) == 50
    @test selected_tasks[1:24] == embedded_tasks
    @test all(item.gate == "embedded24" for item in selected[1:24])
    @test all(item.gate == "additional26" for item in selected[25:50])
    @test count(item -> item.role == "stratified_low_state", selected) == 6
    @test count(item -> item.role == "stratified_high_state", selected) == 6
    @test count(item -> item.role == "stratified_independent", selected) == 12
    @test count(item -> item.role == "stratified_independent_extra", selected) == 2

    cases = [Dict{String, Any}(
        "task" => metric.task,
        "case_key" => metric.case_key,
        "geology_id" => metric.geology_id,
        "realization_id" => metric.realization_id,
        "level3_case_name" => metric.case_name,
    ) for metric in metrics]
    mktempdir() do directory
        write_taskset_plan(directory, selected, cases)
        plan = readlines(joinpath(directory, "taskset_plan.tsv"))
        @test length(plan) == 50
        taskset_files = filter(
            name -> endswith(name, ".tsv"),
            readdir(joinpath(directory, "tasksets")),
        )
        @test length(taskset_files) == 49
        tasks = Int[]
        for name in sort(taskset_files)
            append!(
                tasks,
                parse.(Int, first.(split.(readlines(
                    joinpath(directory, "tasksets", name)
                )[2:end], '\t'))),
            )
        end
        @test sort(tasks) == collect(1:2430)
        @test length(unique(tasks)) == 2430
    end
end
