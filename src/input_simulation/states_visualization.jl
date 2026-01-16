using Printf
include("vtk_export.jl")

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
"""
# function report_times_vtu_export(G_raw, states;
#     outdir::AbstractString = "paraview_states",
#     prefix::AbstractString = "case",
#     vars = :all,
#     split_matrices::Bool = true,
#     write_pvd::Bool = true,
#     times = nothing,
#     digits::Int = 4,
#     verbose::Bool = true,

#     # NEW:
#     write_regions::Bool = false,
#     reservoir_regions = nothing,                 # pass mrst_data["rock"]["regions"] when write_regions=true
#     region_names::Dict{String,String} = Dict(  # map MRST keys -> VTK array names
#         "saturation" => "sat_region",
#         "rocknum"    => "rock_region",
#         "imbibition" => "imbi_region",
#     ),
# )
#     nt = length(states)
#     used_times = times === nothing ? collect(1.0:1.0:nt) : Float64.(times[1:nt])

#     nc = Int(round(G_raw["cells"]["num"]))
#     wanted = (vars === :all) ? nothing : Set(string.(vars))

#     # Preload regions once (constant in time)
#     region_data = Dict{String,AbstractVector}()
#     if write_regions
#         if reservoir_regions === nothing
#             error("write_regions=true but reservoir_regions is nothing. Pass reservoir_regions=mrst_data[\"rock\"][\"regions\"].")
#         end
#         if !(reservoir_regions isa AbstractDict)
#             error("reservoir_regions must be a Dict-like object (e.g. mrst_data[\"rock\"][\"regions\"]). Got $(typeof(reservoir_regions)).")
#         end

#         for (mrst_key, vtk_name) in region_names
#             if haskey(reservoir_regions, mrst_key)
#                 v = reservoir_regions[mrst_key]
#                 v_int = to_int_vec(v)
#                 if length(v_int) == nc
#                     region_data[vtk_name] = v_int
#                 else
#                     verbose && @warn "Region '$mrst_key' length=$(length(v_int)) ≠ nc=$nc. Skipping."
#                 end
#             else
#                 verbose && @warn "reservoir_regions missing key '$mrst_key'. Available: $(collect(keys(reservoir_regions)))."
#             end
#         end

#         if verbose && isempty(region_data)
#             @warn "write_regions=true, but no valid region arrays were added."
#         end
#     end

#     mkpath(outdir)
#     vtu_paths = String[]

#     for i in 1:nt
#         res = states[i][:Reservoir]

#         cell_data = Dict{String,AbstractVector}()
#         skipped = String[]

#         # Add region arrays (same for every time step)
#         if write_regions && !isempty(region_data)
#             for (k, v) in region_data
#                 cell_data[k] = v
#             end
#         end

#         # Add selected reservoir state arrays
#         for (k, v) in pairs(res)
#             name = string(k)
#             if wanted !== nothing && !(name in wanted)
#                 continue
#             end

#             # 1) vector per cell
#             if v isa AbstractVector
#                 if length(v) == nc
#                     cell_data[name] = v
#                 else
#                     push!(skipped, "$name (vector length=$(length(v)) ≠ nc=$nc)")
#                 end

#             # 2) matrix with ncomp × nc
#             elseif v isa AbstractMatrix
#                 if size(v, 2) == nc
#                     if split_matrices
#                         for r in 1:size(v, 1)
#                             cell_data["$(name)_$(r)"] = vec(v[r, :])
#                         end
#                     else
#                         push!(skipped, "$name (matrix $(size(v)) skipped; split_matrices=false)")
#                     end
#                 else
#                     push!(skipped, "$name (matrix $(size(v)) has size(v,2) ≠ nc=$nc)")
#                 end

#             else
#                 push!(skipped, "$name (type=$(typeof(v)) not vector/matrix)")
#             end
#         end

#         # If we only wrote regions and no reservoir vars, still allow export (useful for debugging)
#         if isempty(cell_data)
#             if verbose
#                 @warn "Step $i: no compatible arrays found (reservoir + regions). Skipping VTU."
#                 if !isempty(skipped)
#                     @info "Step $i skipped variables:\n  " * join(skipped, "\n  ")
#                 end
#             end
#             continue
#         end

#         fname = joinpath(outdir, @sprintf("%s_%0*d", prefix, digits, i))
#         write_volume_vtu(G_raw; cell_data = cell_data, filename = fname)
#         push!(vtu_paths, fname * ".vtu")

#         if verbose && !isempty(skipped)
#             @info "Step $i wrote $(length(cell_data)) arrays, skipped $(length(skipped))."
#         end
#     end

#     # optional: PVD
#     pvd_path = nothing
#     if write_pvd && !isempty(vtu_paths)
#         pvd_path = joinpath(outdir, prefix * ".pvd")
#         rel_files = [basename(p) for p in vtu_paths]
#         tuse = used_times[1:length(rel_files)]

#         open(pvd_path, "w") do io
#             println(io, """<?xml version="1.0"?>""")
#             println(io, """<VTKFile type="Collection" version="0.1" byte_order="LittleEndian">""")
#             println(io, """  <Collection>""")
#             for (f, t) in zip(rel_files, tuse)
#                 println(io, """    <DataSet timestep="$t" group="" part="0" file="$f"/>""")
#             end
#             println(io, """  </Collection>""")
#             println(io, """</VTKFile>""")
#         end
#     end

#     return vtu_paths, used_times[1:length(vtu_paths)], pvd_path
# end


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

    nc = Int(round(G_raw["cells"]["num"]))
    wanted = (vars === :all) ? nothing : Set(string.(vars))

    # --- preload p0 once ---
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

    # --- preload regions once (constant in time) ---
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
                v_int = to_int_vec(v)
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

    mkpath(outdir)

    # --- IMPORTANT: track files AND the corresponding times actually written ---
    vtu_paths = String[]
    vtu_times = Float64[]

    for i in 1:nt
        res = states[i][:Reservoir]

        cell_data = Dict{String,AbstractVector}()
        skipped = String[]

        # Add region arrays
        if write_regions && !isempty(region_data)
            for (k, v) in region_data
                cell_data[k] = v
            end
        end

        # Add dP every step (cell-centered)
        if write_dp
            if !haskey(res, :Pressure)
                verbose && @warn "Step $i: no :Pressure in reservoir state, cannot compute dP. Skipping dP."
            else
                p = res[:Pressure]
                if length(p) == nc
                    cell_data[string(dp_name)] = p .- p0
                else
                    verbose && @warn "Step $i: :Pressure length=$(length(p)) ≠ nc=$nc, cannot compute dP."
                end
            end
        end

        # Add selected reservoir state arrays
        for (k, v) in pairs(res)
            name = string(k)
            if wanted !== nothing && !(name in wanted)
                continue
            end

            if v isa AbstractVector
                if length(v) == nc
                    cell_data[name] = v
                else
                    push!(skipped, "$name (vector length=$(length(v)) ≠ nc=$nc)")
                end
            elseif v isa AbstractMatrix
                if size(v, 2) == nc
                    if split_matrices
                        for r in 1:size(v, 1)
                            cell_data["$(name)_$(r)"] = vec(v[r, :])
                        end
                    else
                        push!(skipped, "$name (matrix $(size(v)) skipped; split_matrices=false)")
                    end
                else
                    push!(skipped, "$name (matrix $(size(v)) has size(v,2) ≠ nc=$nc)")
                end
            else
                push!(skipped, "$name (type=$(typeof(v)) not vector/matrix)")
            end
        end

        if isempty(cell_data)
            verbose && @warn "Step $i: no compatible arrays found. Skipping VTU."
            continue
        end

        # Write VTU
        fname = joinpath(outdir, @sprintf("%s_%0*d", prefix, digits, i))
        write_volume_vtu(G_raw; cell_data = cell_data, filename = fname)

        # Record path + the matching time for THIS step
        push!(vtu_paths, fname * ".vtu")
        push!(vtu_times, used_times[i])
    end

    # Write PVD with correct non-uniform times (and correct alignment even if some steps were skipped)
    pvd_path = nothing
    if write_pvd && !isempty(vtu_paths)
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
    end

    return vtu_paths, vtu_times, pvd_path
end

