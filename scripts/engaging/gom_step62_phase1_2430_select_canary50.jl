#!/usr/bin/env julia

"""
Build the reusable 50-case production canary for a phase-1 campaign.

The first 24 rows are exactly the established acceptance cohort: one central,
barrier, conduit, and heterogeneous-independent case for each thickness
scenario. The remaining 26 rows broaden input-space coverage without using
reservoir outcomes. They contain, per scenario, two additional independent
cases plus one additional low-state and high-state case, followed by two
independent cases from the scenarios with the largest remaining maximin gap.

The script also partitions the other 2,380 campaign tasks into immutable
50-case task sets. The canary and remaining task sets therefore form an exact,
non-overlapping cover of all 2,430 production cases.
"""

include(joinpath(@__DIR__, "gom_step62_phase1_2430_select_acceptance.jl"))

const CANARY_FEATURE_FIELDS = (
    :logkxx_median,
    :logkyy_median,
    :logkzz_median,
    :logpe_median,
    :logkxx_span90,
    :logkyy_span90,
    :logkzz_span90,
    :logpe_span90,
    :swi_span90,
    :poro_span90,
)

function scenario_rank_features(metrics)
    features = Dict{Int, Vector{Float64}}()
    for scenario in 1:6
        scenario_metrics = sort(
            filter(metric -> metric.scenario == scenario, metrics);
            by = metric -> metric.task,
        )
        tasks = getfield.(scenario_metrics, :task)
        ranked_fields = [
            percentile_ranks(getfield.(scenario_metrics, field), tasks)
            for field in CANARY_FEATURE_FIELDS
        ]
        for (index, metric) in enumerate(scenario_metrics)
            features[metric.task] = [ranked[index] for ranked in ranked_fields]
        end
    end
    length(features) == length(metrics) || error("Feature coverage mismatch")
    return features
end

function euclidean_distance(left, right)
    length(left) == length(right) || error("Feature-vector length mismatch")
    return sqrt(sum((left[index] - right[index])^2 for index in eachindex(left)))
end

function minimum_distance(metric, reference, features)
    isempty(reference) && error("Maximin selection requires a reference set")
    return minimum(
        euclidean_distance(features[metric.task], features[item.task])
        for item in reference
    )
end

function select_maximin(candidates, reference, features)
    isempty(candidates) && error("No maximin candidates remain")
    scored = [
        (metric = metric, distance = minimum_distance(metric, reference, features))
        for metric in candidates
    ]
    return first(sort(scored; by = item -> (-item.distance, item.metric.task)))
end

function canary_entry(metric, role, reason, gate; distance = NaN)
    return (
        metric = metric,
        role = role,
        reason = reason,
        gate = gate,
        maximin_distance = distance,
    )
end

function select_canary50(metrics)
    embedded = [
        canary_entry(
            item.metric,
            item.role,
            item.reason,
            "embedded24";
        )
        for item in select_cohort(metrics)
    ]
    features = scenario_rank_features(metrics)
    additional = NamedTuple[]

    for scenario in 1:6
        scenario_metrics = filter(metric -> metric.scenario == scenario, metrics)
        scenario_reference = [item.metric for item in embedded if item.metric.scenario == scenario]

        low_candidates = filter(
            metric -> metric.realization_id == 102 &&
                all(item.metric.task != metric.task for item in embedded),
            scenario_metrics,
        )
        low = select_maximin(low_candidates, scenario_reference, features)
        push!(additional, canary_entry(
            low.metric,
            "stratified_low_state",
            "maximin low-state benchmark relative to the embedded scenario cases",
            "additional26";
            distance = low.distance,
        ))
        push!(scenario_reference, low.metric)

        high_candidates = filter(
            metric -> metric.realization_id == 103 &&
                all(item.metric.task != metric.task for item in embedded),
            scenario_metrics,
        )
        high = select_maximin(high_candidates, scenario_reference, features)
        push!(additional, canary_entry(
            high.metric,
            "stratified_high_state",
            "maximin high-state benchmark relative to the embedded scenario cases",
            "additional26";
            distance = high.distance,
        ))
        push!(scenario_reference, high.metric)

        independent_candidates = filter(
            metric -> 1 <= metric.realization_id <= 12 &&
                all(item.metric.task != metric.task for item in embedded),
            scenario_metrics,
        )
        for replicate in 1:2
            independent = select_maximin(
                independent_candidates,
                scenario_reference,
                features,
            )
            push!(additional, canary_entry(
                independent.metric,
                "stratified_independent",
                "scenario maximin independent benchmark $(replicate) of 2",
                "additional26";
                distance = independent.distance,
            ))
            push!(scenario_reference, independent.metric)
            filter!(metric -> metric.task != independent.metric.task, independent_candidates)
        end
    end

    selected_metrics = vcat(
        [item.metric for item in embedded],
        [item.metric for item in additional],
    )
    scenario_gaps = NamedTuple[]
    for scenario in 1:6
        scenario_reference = filter(metric -> metric.scenario == scenario, selected_metrics)
        remaining = filter(
            metric -> metric.scenario == scenario &&
                1 <= metric.realization_id <= 12 &&
                all(selected.task != metric.task for selected in selected_metrics),
            metrics,
        )
        best = select_maximin(remaining, scenario_reference, features)
        push!(scenario_gaps, (
            scenario = scenario,
            metric = best.metric,
            distance = best.distance,
        ))
    end
    for gap in first(sort(scenario_gaps; by = item -> (-item.distance, item.scenario, item.metric.task)), 2)
        push!(additional, canary_entry(
            gap.metric,
            "stratified_independent_extra",
            "independent benchmark from a scenario with a largest remaining input-space gap",
            "additional26";
            distance = gap.distance,
        ))
    end

    selected = vcat(embedded, additional)
    selected_tasks = [item.metric.task for item in selected]
    length(embedded) == 24 || error("Expected 24 embedded acceptance cases")
    length(additional) == 26 || error("Expected 26 additional canary cases")
    length(selected) == 50 || error("Expected 50 canary cases")
    length(unique(selected_tasks)) == 50 || error("Canary selection contains duplicate tasks")
    return selected
end

function write_canary_selection(path, selected)
    open(path, "w") do io
        println(io, join([
            "canary_order", "gate", "task", "case_key", "scenario",
            "geology_id", "realization_id", "case_name", "acceptance_role",
            "selection_reason", "maximin_distance", "conduit_score",
            "barrier_score", "heterogeneity_score",
        ], '\t'))
        for (order, item) in enumerate(selected)
            metric = item.metric
            println(io, join(Any[
                order, item.gate, metric.task, metric.case_key, metric.scenario,
                metric.geology_id, metric.realization_id, metric.case_name,
                item.role, item.reason, item.maximin_distance,
                metric.conduit_score, metric.barrier_score,
                metric.heterogeneity_score,
            ], '\t'))
        end
    end
end

function write_taskset(path, tasks, cases_by_task; purpose)
    open(path, "w") do io
        println(io, "task\tcase_key\tgeology_id\trealization_id\tcase_name\tpurpose")
        for task in tasks
            case_record = cases_by_task[task]
            println(io, join(Any[
                task,
                case_record["case_key"],
                case_record["geology_id"],
                case_record["realization_id"],
                case_record["level3_case_name"],
                purpose,
            ], '\t'))
        end
    end
end

function write_taskset_plan(output_dir, selected, cases)
    taskset_dir = joinpath(output_dir, "tasksets")
    mkpath(taskset_dir)
    cases_by_task = Dict(Int(case_record["task"]) => case_record for case_record in cases)
    selected_tasks = [item.metric.task for item in selected]
    selected_set = Set(selected_tasks)
    remaining_tasks = [task for task in 1:length(cases) if !(task in selected_set)]
    tasksets = [(purpose = "reusable_canary50", tasks = selected_tasks)]
    for start in 1:50:length(remaining_tasks)
        finish = min(start + 49, length(remaining_tasks))
        push!(tasksets, (
            purpose = "remaining_production",
            tasks = remaining_tasks[start:finish],
        ))
    end
    length(tasksets) == 49 || error("Expected 49 production task sets")

    open(joinpath(output_dir, "taskset_plan.tsv"), "w") do io
        println(io, "taskset_index\ttaskset_id\tpurpose\ttask_count\tselection_file\tarray_spec_file")
        for (index, taskset) in enumerate(tasksets)
            taskset_id = @sprintf("taskset_%04d", index)
            selection_name = "$taskset_id.tsv"
            array_name = "$taskset_id.array.txt"
            write_taskset(
                joinpath(taskset_dir, selection_name),
                taskset.tasks,
                cases_by_task;
                purpose = taskset.purpose,
            )
            write(
                joinpath(taskset_dir, array_name),
                join(sort(taskset.tasks), ',') * "\n",
            )
            println(io, join(Any[
                index,
                taskset_id,
                taskset.purpose,
                length(taskset.tasks),
                "tasksets/$selection_name",
                "tasksets/$array_name",
            ], '\t'))
        end
    end

    covered = vcat((taskset.tasks for taskset in tasksets)...)
    sort(covered) == collect(1:length(cases)) || error("Task-set plan does not cover the campaign")
    length(unique(covered)) == length(cases) || error("Task-set plan overlaps")
end

function main_canary50(args)
    length(args) == 2 || error("Usage: select_canary50.jl CAMPAIGN_TOML OUTPUT_DIR")
    campaign_path = abspath(args[1])
    output_dir = abspath(args[2])
    isfile(campaign_path) || error("Missing campaign manifest: $campaign_path")
    mkpath(output_dir)

    campaign = TOML.parsefile(campaign_path)
    campaign["schema_version"] == 3 || error("Canary selection requires schema 3")
    campaign["ensemble_kind"] == "phase1_2430" || error("Expected phase1_2430 campaign")
    campaign["case_count"] == 2430 || error("Expected 2,430 campaign cases")
    cases = campaign["cases"]
    length(cases) == 2430 || error("Campaign case list length mismatch")

    metrics = CaseMetric[]
    for (index, case_record) in enumerate(cases)
        push!(metrics, read_case_metric(case_record))
        index % 50 == 0 && @info "Canary metric progress" completed=index total=length(cases)
        index % 100 == 0 && GC.gc(false)
    end
    add_screening_scores!(metrics)
    selected = select_canary50(metrics)

    write_metrics(joinpath(output_dir, "all_case_input_metrics.tsv"), metrics)
    write_canary_selection(joinpath(output_dir, "canary50_selection.tsv"), selected)
    write_canary_selection(joinpath(output_dir, "embedded24_selection.tsv"), selected[1:24])
    write_canary_selection(joinpath(output_dir, "additional26_selection.tsv"), selected[25:50])
    embedded_tasks = sort(item.metric.task for item in selected[1:24])
    additional_tasks = sort(item.metric.task for item in selected[25:50])
    write(joinpath(output_dir, "embedded24_array_spec.txt"), join(embedded_tasks, ',') * "\n")
    write(joinpath(output_dir, "additional26_array_spec.txt"), join(additional_tasks, ',') * "\n")
    write(joinpath(output_dir, "canary50_array_spec.txt"), join(sort(vcat(embedded_tasks, additional_tasks)), ',') * "\n")
    write_taskset_plan(output_dir, selected, cases)

    manifest_sha = bytes2hex(sha256(read(campaign_path)))
    created_utc = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")
    campaign_id = campaign["campaign_id"]
    case_order_sha = campaign["case_order_sha256"]
    open(joinpath(output_dir, "SELECTION_METADATA.txt"), "w") do io
        println(io, "schema=gom_phase1_2430_reusable_canary50_selection_v1")
        println(io, "created_utc=$created_utc")
        println(io, "campaign_id=$campaign_id")
        println(io, "campaign_manifest=$campaign_path")
        println(io, "campaign_manifest_sha256=$manifest_sha")
        println(io, "campaign_case_order_sha256=$case_order_sha")
        println(io, "selection_count=50")
        println(io, "embedded_acceptance_count=24")
        println(io, "additional_stratified_count=26")
        println(io, "scenario_count=6")
        println(io, "selection_uses_reservoir_outcomes=false")
        println(io, "maximin_features=$(join(string.(CANARY_FEATURE_FIELDS), ','))")
        println(io, "production_taskset_count=49")
        println(io, "taskset_case_limit=50")
        println(io, "campaign_tasks_covered_exactly_once=true")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main_canary50(ARGS)
end
