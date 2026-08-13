using MAT
using Statistics
using TOML

include(joinpath(@__DIR__, "gom_step62_initial_equilibrium_common.jl"))

length(ARGS) in (2, 3) || error(
    "Usage: gom_step62_initial_equilibrium_select.jl CAMPAIGN_TOML " *
    "TASK_SPEC [OUTPUT_TSV]"
)
manifest_path, task_spec = ARGS[1:2]
output_path = length(ARGS) == 3 ? ARGS[3] : ""

manifest = TOML.parsefile(manifest_path)
cases = manifest["cases"]
available = Int[case["task"] for case in cases]
selected = gom_equilibrium_parse_task_spec(task_spec, available)
by_task = Dict(Int(case["task"]) => case for case in cases)

"""Return the first strictly positive capillary pressure from an SGOF table."""
function entry_pressure_pa(table)
    index = findfirst(value -> value > 0.0, view(table, :, 4))
    isnothing(index) && return 0.0
    return Float64(table[index, 4])
end

rows = Dict{Symbol, Any}[]
for task in selected
    case = by_task[task]
    specific = MAT.matread(case["specific_path"])
    window_slice = specific["window_slice"]
    local_perm_md = Float64.(window_slice["local_perm_md"])
    size(local_perm_md) == (6, 87, 3) ||
        error("Task $task has an unexpected local-permeability shape.")
    positive_perm = max.(local_perm_md, floatmin(Float64))
    log_perm = log10.(positive_perm)
    porosity = Float64.(vec(window_slice["poro"]))
    effective_swi = Float64.(vec(specific["curve_selection"]["effective_swi"]))
    sgof = specific["fault"]["fluid_tables"]["SGOF"]
    tables = vec(sgof["tables"])
    entry_pressure = entry_pressure_pa.(tables)
    push!(rows, Dict{Symbol, Any}(
        :task => task,
        :case_key => case["case_key"],
        :geology_id => case["geology_id"],
        :realization_id => case["realization_id"],
        :level3_case_name => case["level3_case_name"],
        :median_log10_kxx_md => median(vec(view(log_perm, :, :, 1))),
        :median_log10_kyy_md => median(vec(view(log_perm, :, :, 2))),
        :median_log10_kzz_md => median(vec(view(log_perm, :, :, 3))),
        :minimum_log10_k_md => minimum(log_perm),
        :maximum_log10_k_md => maximum(log_perm),
        :median_porosity => median(porosity),
        :median_effective_swi => median(effective_swi),
        :median_entry_pressure_bar => median(entry_pressure)/1.0e5,
        :entry_pressure_log10_sd => std(log10.(max.(entry_pressure, 1.0))),
        :entry_pressure_at_least_1bar_fraction =>
            count(>=(1.0e5), entry_pressure)/length(entry_pressure)
    ))
end

columns = [
    :task,
    :case_key,
    :geology_id,
    :realization_id,
    :level3_case_name,
    :median_log10_kxx_md,
    :median_log10_kyy_md,
    :median_log10_kzz_md,
    :minimum_log10_k_md,
    :maximum_log10_k_md,
    :median_porosity,
    :median_effective_swi,
    :median_entry_pressure_bar,
    :entry_pressure_log10_sd,
    :entry_pressure_at_least_1bar_fraction
]

if isempty(output_path)
    println(join(string.(columns), '\t'))
    for row in rows
        println(join(
            (gom_equilibrium_table_value(row[column]) for column in columns),
            '\t'
        ))
    end
else
    gom_equilibrium_write_table(output_path, columns, rows)
    println("INITIAL_EQUILIBRIUM_SELECTION_TABLE=$output_path")
end

if length(rows) >= 3
    low_k = rows[argmin(getindex.(rows, :median_log10_kzz_md))]
    high_k = rows[argmax(getindex.(rows, :median_log10_kzz_md))]
    heterogeneous_pc = rows[argmax(getindex.(rows, :entry_pressure_log10_sd))]
    println(
        "RECOMMENDED_TASKS=",
        join(unique(Int[
            low_k[:task],
            high_k[:task],
            heterogeneous_pc[:task]
        ]), ',')
    )
end
