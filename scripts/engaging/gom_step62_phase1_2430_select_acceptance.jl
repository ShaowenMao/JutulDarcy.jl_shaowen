#!/usr/bin/env julia

"""
Select the 24-case full-schedule acceptance cohort for a phase-1 campaign.

The selector reads only immutable reservoir-input MAT files. For each of the
six thickness scenarios it chooses one central medoid benchmark, one
barrier-like low-state benchmark, one conduit-like high-state benchmark, and
one maximally heterogeneous independent realization. Reservoir outcomes are
never used, which keeps the acceptance selection independent of the QoIs it
will later test.
"""

using Dates
using MAT
using Printf
using SHA
using Statistics
using TOML

mutable struct CaseMetric
    task::Int
    case_key::String
    scenario::Int
    geology_id::String
    realization_id::Int
    case_name::String
    specific_path::String
    logkxx_median::Float64
    logkyy_median::Float64
    logkzz_median::Float64
    logpe_median::Float64
    logkxx_span90::Float64
    logkyy_span90::Float64
    logkzz_span90::Float64
    logpe_span90::Float64
    swi_span90::Float64
    poro_span90::Float64
    conduit_score::Float64
    barrier_score::Float64
    heterogeneity_score::Float64
end

function positive_log_values(values, label, case_key)
    result = log10.(Float64.(vec(values)))
    all(isfinite, result) || error("$case_key has non-finite $label values")
    return result
end

function finite_values(values, label, case_key)
    result = Float64.(vec(values))
    all(isfinite, result) || error("$case_key has non-finite $label values")
    return result
end

function median_and_span90(values)
    return median(values), quantile(values, 0.95) - quantile(values, 0.05)
end

function parse_identity(case_key)
    matched = match(r"^s(\d{2})_c(\d{3})_case(\d+)$", case_key)
    matched === nothing && error("Unexpected case key: $case_key")
    return parse(Int, matched.captures[1]), parse(Int, matched.captures[3])
end

function read_case_metric(case_record)
    case_key = String(case_record["case_key"])
    scenario, _ = parse_identity(case_key)
    path = String(case_record["specific_path"])
    isfile(path) || error("Missing specific MAT: $path")
    data = matread(path)

    fault = data["fault"]
    component_order = String.(vec(fault["perm_component_order"]))
    component_index = Dict(name => index for (index, name) in enumerate(component_order))
    all(haskey(component_index, name) for name in ("Kxx", "Kyy", "Kzz")) ||
        error("$case_key has an unsupported permeability component order")
    permeability = Float64.(fault["perm"])
    size(permeability, 2) == 6 || error("$case_key does not contain six tensor components")

    logkxx = positive_log_values(permeability[:, component_index["Kxx"]], "Kxx", case_key)
    logkyy = positive_log_values(permeability[:, component_index["Kyy"]], "Kyy", case_key)
    logkzz = positive_log_values(permeability[:, component_index["Kzz"]], "Kzz", case_key)
    region_table = data["saturation_regions"]["region_table"]
    logpe = positive_log_values(region_table["ConnectedEntryPcBar"], "entry pressure", case_key)
    swi = finite_values(data["curve_selection"]["effective_swi"], "effective Swi", case_key)
    poro = finite_values(data["window_slice"]["poro"], "porosity", case_key)
    length(logpe) == 522 || error("$case_key has $(length(logpe)) entry-pressure domains, expected 522")
    length(swi) == 522 || error("$case_key has $(length(swi)) Swi domains, expected 522")
    length(poro) == 522 || error("$case_key has $(length(poro)) porosity domains, expected 522")
    all((0.0 .<= swi) .& (swi .<= 1.0)) || error("$case_key has Swi outside [0, 1]")
    all((0.0 .< poro) .& (poro .< 1.0)) || error("$case_key has porosity outside (0, 1)")

    kxx_median, kxx_span = median_and_span90(logkxx)
    kyy_median, kyy_span = median_and_span90(logkyy)
    kzz_median, kzz_span = median_and_span90(logkzz)
    pe_median, pe_span = median_and_span90(logpe)
    _, swi_span = median_and_span90(swi)
    _, poro_span = median_and_span90(poro)

    return CaseMetric(
        Int(case_record["task"]),
        case_key,
        scenario,
        String(case_record["geology_id"]),
        Int(case_record["realization_id"]),
        String(case_record["level3_case_name"]),
        path,
        kxx_median,
        kyy_median,
        kzz_median,
        pe_median,
        kxx_span,
        kyy_span,
        kzz_span,
        pe_span,
        swi_span,
        poro_span,
        NaN,
        NaN,
        NaN,
    )
end

function percentile_ranks(values, tasks)
    count = length(values)
    count == length(tasks) || error("Rank input length mismatch")
    count > 1 || return fill(0.5, count)
    order = sortperm(eachindex(values); by = index -> (values[index], tasks[index]))
    ranks = zeros(Float64, count)
    first_position = 1
    while first_position <= count
        last_position = first_position
        tied_value = values[order[first_position]]
        while last_position < count && values[order[last_position + 1]] == tied_value
            last_position += 1
        end
        average_zero_based_rank = ((first_position - 1) + (last_position - 1)) / 2
        percentile = average_zero_based_rank / (count - 1)
        for position in first_position:last_position
            ranks[order[position]] = percentile
        end
        first_position = last_position + 1
    end
    return ranks
end

function add_screening_scores!(metrics)
    tasks = getfield.(metrics, :task)
    kzz_rank = percentile_ranks(getfield.(metrics, :logkzz_median), tasks)
    pe_rank = percentile_ranks(getfield.(metrics, :logpe_median), tasks)
    spans = (
        percentile_ranks(getfield.(metrics, :logkxx_span90), tasks),
        percentile_ranks(getfield.(metrics, :logkyy_span90), tasks),
        percentile_ranks(getfield.(metrics, :logkzz_span90), tasks),
        percentile_ranks(getfield.(metrics, :logpe_span90), tasks),
        percentile_ranks(getfield.(metrics, :swi_span90), tasks),
        percentile_ranks(getfield.(metrics, :poro_span90), tasks),
    )
    for index in eachindex(metrics)
        # Equal-weight input screening only; this is not a leakage predictor.
        metrics[index].conduit_score = 0.5 * (kzz_rank[index] + 1.0 - pe_rank[index])
        metrics[index].barrier_score = 1.0 - metrics[index].conduit_score
        metrics[index].heterogeneity_score = mean(rank[index] for rank in spans)
    end
end

function select_best(candidates, field)
    isempty(candidates) && error("No candidates for $field")
    return first(sort(candidates; by = metric -> (-getfield(metric, field), metric.task)))
end

function select_cohort(metrics)
    selected = NamedTuple[]
    for scenario in 1:6
        scenario_metrics = filter(metric -> metric.scenario == scenario, metrics)
        medoid_key = @sprintf("s%02d_c014_case101", scenario)
        medoid_candidates = filter(metric -> metric.case_key == medoid_key, scenario_metrics)
        length(medoid_candidates) == 1 || error("Expected exactly one $medoid_key")
        push!(selected, (metric = only(medoid_candidates), role = "central_medoid",
                         reason = "central geology (c014), representative medoid benchmark"))

        barrier_candidates = filter(metric -> metric.realization_id == 102, scenario_metrics)
        barrier = select_best(barrier_candidates, :barrier_score)
        push!(selected, (metric = barrier, role = "barrier_stress",
                         reason = "largest barrier screening score among scenario low-state benchmarks"))

        conduit_candidates = filter(metric -> metric.realization_id == 103, scenario_metrics)
        conduit = select_best(conduit_candidates, :conduit_score)
        push!(selected, (metric = conduit, role = "conduit_stress",
                         reason = "largest conduit screening score among scenario high-state benchmarks"))

        independent_candidates = filter(metric -> 1 <= metric.realization_id <= 12, scenario_metrics)
        heterogeneous = select_best(independent_candidates, :heterogeneity_score)
        push!(selected, (metric = heterogeneous, role = "heterogeneous_independent",
                         reason = "largest six-property heterogeneity score among scenario independent cases"))
    end
    tasks = getfield.(getfield.(selected, :metric), :task)
    length(selected) == 24 || error("Expected 24 selected cases")
    length(unique(tasks)) == 24 || error("Acceptance selection contains duplicate tasks")
    return selected
end

function write_metrics(path, metrics)
    header = [
        "task", "case_key", "scenario", "geology_id", "realization_id", "case_name",
        "logkxx_median", "logkyy_median", "logkzz_median", "logpe_median",
        "logkxx_span90", "logkyy_span90", "logkzz_span90", "logpe_span90",
        "swi_span90", "poro_span90", "conduit_score", "barrier_score",
        "heterogeneity_score", "specific_path",
    ]
    open(path, "w") do io
        println(io, join(header, '\t'))
        for metric in sort(metrics; by = item -> item.task)
            values = Any[
                metric.task, metric.case_key, metric.scenario, metric.geology_id,
                metric.realization_id, metric.case_name, metric.logkxx_median,
                metric.logkyy_median, metric.logkzz_median, metric.logpe_median,
                metric.logkxx_span90, metric.logkyy_span90, metric.logkzz_span90,
                metric.logpe_span90, metric.swi_span90, metric.poro_span90,
                metric.conduit_score, metric.barrier_score,
                metric.heterogeneity_score, metric.specific_path,
            ]
            println(io, join(values, '\t'))
        end
    end
end

function write_selection(path, selected)
    open(path, "w") do io
        println(io, join([
            "task", "case_key", "scenario", "geology_id", "realization_id",
            "case_name", "acceptance_role", "selection_reason", "conduit_score",
            "barrier_score", "heterogeneity_score",
        ], '\t'))
        for item in sort(selected; by = entry -> (entry.metric.scenario, entry.role))
            metric = item.metric
            println(io, join(Any[
                metric.task, metric.case_key, metric.scenario, metric.geology_id,
                metric.realization_id, metric.case_name, item.role, item.reason,
                metric.conduit_score, metric.barrier_score,
                metric.heterogeneity_score,
            ], '\t'))
        end
    end
end

function main(args)
    length(args) == 2 || error("Usage: select_acceptance.jl CAMPAIGN_TOML OUTPUT_DIR")
    campaign_path = abspath(args[1])
    output_dir = abspath(args[2])
    isfile(campaign_path) || error("Missing campaign manifest: $campaign_path")
    mkpath(output_dir)

    campaign = TOML.parsefile(campaign_path)
    campaign["schema_version"] == 3 || error("Acceptance selection requires schema 3")
    campaign["ensemble_kind"] == "phase1_2430" || error("Expected phase1_2430 campaign")
    campaign["case_count"] == 2430 || error("Expected 2,430 campaign cases")
    cases = campaign["cases"]
    length(cases) == 2430 || error("Campaign case list length mismatch")

    metrics = CaseMetric[]
    for (index, case_record) in enumerate(cases)
        push!(metrics, read_case_metric(case_record))
        index % 50 == 0 && @info "Acceptance metric progress" completed=index total=length(cases)
        index % 100 == 0 && GC.gc(false)
    end
    add_screening_scores!(metrics)
    selected = select_cohort(metrics)

    write_metrics(joinpath(output_dir, "all_case_input_metrics.tsv"), metrics)
    write_selection(joinpath(output_dir, "acceptance_selection.tsv"), selected)
    selected_tasks = sort(getfield.(getfield.(selected, :metric), :task))
    write(joinpath(output_dir, "acceptance_array_spec.txt"), join(selected_tasks, ',') * "\n")
    manifest_sha = bytes2hex(sha256(read(campaign_path)))
    created_utc = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")
    campaign_id = campaign["campaign_id"]
    case_order_sha = campaign["case_order_sha256"]
    open(joinpath(output_dir, "SELECTION_METADATA.txt"), "w") do io
        println(io, "schema=gom_phase1_2430_acceptance_selection_v1")
        println(io, "created_utc=$created_utc")
        println(io, "campaign_id=$campaign_id")
        println(io, "campaign_manifest=$campaign_path")
        println(io, "campaign_manifest_sha256=$manifest_sha")
        println(io, "campaign_case_order_sha256=$case_order_sha")
        println(io, "selection_count=24")
        println(io, "scenario_count=6")
        println(io, "cases_per_scenario=4")
        println(io, "selection_uses_reservoir_outcomes=false")
        println(io, "conduit_screen=equal percentile ranks of median global Kzz and inverse median entry pressure")
        println(io, "heterogeneity_screen=mean percentile rank of 90-percent spans for Kxx,Kyy,Kzz,Pe,Swi,porosity")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
