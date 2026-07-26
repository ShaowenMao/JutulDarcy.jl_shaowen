using Printf

"""
Export one VTU per report step for ONLY reservoir state variables, with optional region info.

Handles:
- vectors of length ncells  -> exported as `name`
- matrices of size (ncomp, ncells) -> exported as `name_1`, `name_2`, ...

Skips anything that doesn't match ncells.
Also skips variables missing from a given state.

vars:
- :all  -> export everything in states[i][:Reservoir]
- Vector of Symbols/Strings -> export only those names (e.g. [:Pressure, :Saturations, :Rs])

Region info:
- If `write_regions=true`, writes `sat_region`, `rock_region`, `imbi_region` from
  `reservoir_regions = mrst_data["rock"]["regions"]` (Dict with keys "saturation","rocknum","imbibition").

Extra cell data:
- `extra_cell_data` accepts a dictionary of named vectors with one value per cell.
- These static arrays are written to every selected report-time VTU.
"""

function prepare_report_times_vtu_export(G_raw;
    vars = :all,
    verbose::Bool = true,
    write_regions::Bool = false,
    reservoir_regions = nothing,
    region_names::Dict{String,String} = Dict(
        "saturation" => "sat_region",
        "rocknum"    => "rock_region",
        "imbibition" => "imbi_region",
    ),
    write_dp::Bool = false,
    state0_pressure = nothing,
    dp_name::AbstractString = "dP",
    extra_cell_data = nothing,
)
    nc = Int(round(G_raw["cells"]["num"]))
    wanted = (vars === :all) ? nothing : Set(string.(vars))

    p0 = nothing
    if write_dp
        if state0_pressure === nothing
            error("write_dp=true but state0_pressure is nothing. Pass state0_pressure=mrst_data[\"state0\"][\"pressure\"].")
        end
        p0v = vec(state0_pressure)
        if length(p0v) != nc
            error("state0_pressure length=$(length(p0v)) ≠ nc=$nc")
        end
        p0 = Float64.(p0v)
    end

    region_data = Dict{String,AbstractVector}()
    if write_regions
        if reservoir_regions === nothing
            error("write_regions=true but reservoir_regions is nothing. Pass reservoir_regions=mrst_data[\"rock\"][\"regions\"].")
        end
        if !(reservoir_regions isa AbstractDict)
            error("reservoir_regions must be a Dict-like object. Got $(typeof(reservoir_regions)).")
        end

        for (mrst_key, vtk_name) in region_names
            if haskey(reservoir_regions, mrst_key)
                v = reservoir_regions[mrst_key]
                v_int = Int.(round.(vec(v)))
                if length(v_int) == nc
                    region_data[vtk_name] = v_int
                else
                    verbose && @warn "Region '$mrst_key' length=$(length(v_int)) ≠ nc=$nc. Skipping."
                end
            else
                verbose && @warn "reservoir_regions missing key '$mrst_key'. Available: $(collect(keys(reservoir_regions)))."
            end
        end
    end

    extra_data = Dict{String,AbstractVector}()
    if !isnothing(extra_cell_data)
        extra_cell_data isa AbstractDict ||
            error("extra_cell_data must be a dictionary-like object.")
        for (raw_name, raw_values) in pairs(extra_cell_data)
            name = string(raw_name)
            isempty(name) && error("extra_cell_data contains an empty array name.")
            haskey(region_data, name) && error(
                "extra_cell_data[$raw_name] collides with a generated region array."
            )
            write_dp && name == String(dp_name) && error(
                "extra_cell_data[$raw_name] collides with the generated dP array."
            )
            raw_values isa AbstractVector ||
                error("extra_cell_data[$raw_name] must be a vector.")
            values = vec(raw_values)
            length(values) == nc || error(
                "extra_cell_data[$raw_name] has $(length(values)) values, expected $nc."
            )
            haskey(extra_data, name) &&
                error("extra_cell_data contains duplicate normalized name $name.")
            extra_data[name] = copy(values)
        end
    end

    return (
        nc = nc,
        wanted = wanted,
        p0 = p0,
        region_data = region_data,
        extra_cell_data = extra_data,
        verbose = verbose,
        dp_name = String(dp_name)
    )
end

function reservoir_state_for_vtu(state)
    if state isa AbstractDict && haskey(state, :Reservoir)
        return state[:Reservoir]
    else
        return state
    end
end

function reservoir_state_cell_data_for_vtu(state, spec;
    split_matrices::Bool = true,
    step_label::AbstractString = "step"
)
    res = reservoir_state_for_vtu(state)

    cell_data = Dict{String,AbstractVector}()
    skipped = String[]

    if !isempty(spec.extra_cell_data)
        for (k, v) in spec.extra_cell_data
            cell_data[k] = v
        end
    end

    if !isempty(spec.region_data)
        for (k, v) in spec.region_data
            haskey(cell_data, k) &&
                error("$step_label: duplicate static VTU array name $k.")
            cell_data[k] = v
        end
    end

    if !isnothing(spec.p0)
        if !haskey(res, :Pressure)
            spec.verbose && @warn "$step_label: no :Pressure in reservoir state, cannot compute dP. Skipping dP."
        else
            p = res[:Pressure]
            if length(p) == spec.nc
                haskey(cell_data, spec.dp_name) && error(
                    "$step_label: generated dP array collides with static array $(spec.dp_name)."
                )
                cell_data[spec.dp_name] = p .- spec.p0
            else
                spec.verbose && @warn "$step_label: :Pressure length=$(length(p)) ≠ nc=$(spec.nc), cannot compute dP."
            end
        end
    end

    for (k, v) in pairs(res)
        name = string(k)
        if spec.wanted !== nothing && !(name in spec.wanted)
            continue
        end

        if v isa AbstractVector
            if length(v) == spec.nc
                haskey(cell_data, name) &&
                    error("$step_label: state array $name collides with a static VTU array.")
                cell_data[name] = v
            else
                push!(skipped, "$name (vector length=$(length(v)) ≠ nc=$(spec.nc))")
            end
        elseif v isa AbstractMatrix
            if size(v, 2) == spec.nc
                if split_matrices
                    for r in 1:size(v, 1)
                        component_name = "$(name)_$(r)"
                        haskey(cell_data, component_name) && error(
                            "$step_label: state array $component_name collides with a static VTU array."
                        )
                        cell_data[component_name] = vec(v[r, :])
                    end
                else
                    push!(skipped, "$name (matrix $(size(v)) skipped; split_matrices=false)")
                end
            else
                push!(skipped, "$name (matrix $(size(v)) has size(v,2) ≠ nc=$(spec.nc))")
            end
        else
            push!(skipped, "$name (type=$(typeof(v)) not vector/matrix)")
        end
    end

    if isempty(cell_data)
        spec.verbose && @warn "$step_label: no compatible arrays found. Skipping VTU."
        return nothing
    end

    return cell_data
end

function write_report_time_vtu_step(G_raw, state, step_index::Int, spec;
    outdir::AbstractString = "paraview_states",
    prefix::AbstractString = "case",
    split_matrices::Bool = true,
    digits::Int = 4,
)
    cell_data = reservoir_state_cell_data_for_vtu(
        state,
        spec;
        split_matrices = split_matrices,
        step_label = "Step $step_index"
    )
    isnothing(cell_data) && return nothing

    fname = joinpath(outdir, @sprintf("%s_%0*d", prefix, digits, step_index))
    write_volume_vtu(G_raw; cell_data = cell_data, filename = fname)
    return fname * ".vtu"
end

function write_pvd_collection(vtu_paths, vtu_times;
    outdir::AbstractString = "paraview_states",
    prefix::AbstractString = "case"
)
    pvd_path = joinpath(outdir, prefix * ".pvd")
    rel_files = [basename(p) for p in vtu_paths]

    open(pvd_path, "w") do io
        println(io, """<?xml version="1.0"?>""")
        println(io, """<VTKFile type="Collection" version="0.1" byte_order="LittleEndian">""")
        println(io, """  <Collection>""")
        for (f, t) in zip(rel_files, vtu_times)
            @printf(io, "    <DataSet timestep=\"%.16g\" group=\"\" part=\"0\" file=\"%s\"/>\n", t, f)
        end
        println(io, """  </Collection>""")
        println(io, """</VTKFile>""")
    end
    return pvd_path
end

function report_times_vtu_export(G_raw, states;
    outdir::AbstractString = "paraview_states",
    prefix::AbstractString = "case",
    vars = :all,
    split_matrices::Bool = true,
    write_pvd::Bool = true,
    times = nothing,
    digits::Int = 4,
    verbose::Bool = true,

    write_regions::Bool = false,
    reservoir_regions = nothing,
    region_names::Dict{String,String} = Dict(
        "saturation" => "sat_region",
        "rocknum"    => "rock_region",
        "imbibition" => "imbi_region",
    ),

    # write dp = p - p0
    write_dp::Bool = false,
    state0_pressure = nothing,           # pass mrst_data["state0"]["pressure"]
    dp_name::AbstractString = "dP",      # VTK array name
)
    nt = length(states)
    used_times = times === nothing ? collect(1.0:1.0:nt) : Float64.(times[1:nt])
    spec = prepare_report_times_vtu_export(G_raw;
        vars = vars,
        verbose = verbose,
        write_regions = write_regions,
        reservoir_regions = reservoir_regions,
        region_names = region_names,
        write_dp = write_dp,
        state0_pressure = state0_pressure,
        dp_name = dp_name
    )

    mkpath(outdir)
    vtu_paths = String[]
    vtu_times = Float64[]

    for i in 1:nt
        path = write_report_time_vtu_step(G_raw, states[i], i, spec;
            outdir = outdir,
            prefix = prefix,
            split_matrices = split_matrices,
            digits = digits
        )
        if !isnothing(path)
            push!(vtu_paths, path)
            push!(vtu_times, used_times[i])
        end
    end

    pvd_path = nothing
    if write_pvd && !isempty(vtu_paths)
        pvd_path = write_pvd_collection(vtu_paths, vtu_times; outdir = outdir, prefix = prefix)
    end

    return vtu_paths, vtu_times, pvd_path
end

"""
Stream VTU export directly from a Jutul `output_path` without loading all saved
states into memory at once.
"""
function report_times_vtu_export_from_output(G_raw, output_path::AbstractString;
    outdir::AbstractString = "paraview_states",
    prefix::AbstractString = "case",
    vars = :all,
    split_matrices::Bool = true,
    write_pvd::Bool = true,
    digits::Int = 4,
    verbose::Bool = true,

    write_regions::Bool = false,
    reservoir_regions = nothing,
    region_names::Dict{String,String} = Dict(
        "saturation" => "sat_region",
        "rocknum"    => "rock_region",
        "imbibition" => "imbi_region",
    ),

    write_dp::Bool = false,
    state0_pressure = nothing,
    dp_name::AbstractString = "dP",
    state_transform! = nothing,
)
    isdir(output_path) || error("Output path $output_path does not exist or is not a directory.")

    indices = Jutul.valid_restart_indices(output_path)
    isempty(indices) && error("No Jutul restart/output files were found in $output_path.")

    reports = Any[]
    for step_no in indices
        _, report = Jutul.read_restart(output_path, step_no; read_state = false, read_report = true)
        isnothing(report) || push!(reports, report)
    end

    used_times = Float64.(Jutul.report_times(reports))
    n = min(length(indices), length(used_times))
    if n == 0
        error("No successful report steps were found in $output_path.")
    end
    if n != length(indices) && verbose
        @warn "Found $(length(indices)) saved states but $(length(used_times)) report times. Exporting the first $n steps."
    end
    indices = indices[1:n]
    used_times = used_times[1:n]

    spec = prepare_report_times_vtu_export(G_raw;
        vars = vars,
        verbose = verbose,
        write_regions = write_regions,
        reservoir_regions = reservoir_regions,
        region_names = region_names,
        write_dp = write_dp,
        state0_pressure = state0_pressure,
        dp_name = dp_name
    )

    mkpath(outdir)
    vtu_paths = String[]
    vtu_times = Float64[]

    for (local_step, saved_step) in enumerate(indices)
        state, _ = Jutul.read_restart(output_path, saved_step; read_state = true, read_report = false)
        if !isnothing(state_transform!)
            state_transform!(state, local_step)
        end
        path = write_report_time_vtu_step(G_raw, state, saved_step, spec;
            outdir = outdir,
            prefix = prefix,
            split_matrices = split_matrices,
            digits = digits
        )
        if !isnothing(path)
            push!(vtu_paths, path)
            push!(vtu_times, used_times[local_step])
        end
    end

    pvd_path = nothing
    if write_pvd && !isempty(vtu_paths)
        pvd_path = write_pvd_collection(vtu_paths, vtu_times; outdir = outdir, prefix = prefix)
    end

    return vtu_paths, vtu_times, pvd_path
end

