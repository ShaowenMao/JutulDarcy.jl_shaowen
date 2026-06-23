# incon_visualization.jl
using MAT

"""
    export_initial_step0_vtu(fn, mrst_data;
        outdir, prefix,
        vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
        split_matrices = true,
        write_regions = true)

Export ONE VTU for the initial condition using:
- grid from `mrst_data["G"]`
- rock/state0/regions from `mrst_data`

Permeability:
- supports nc×1, nc×3, nc×6 in MAT export
- stores as ncomp×nc for compatibility with the state exporter
"""
function export_initial_step0_vtu(fn::AbstractString, mrst_data::Dict{String,Any};
        outdir::AbstractString,
        prefix::AbstractString,
        vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
        split_matrices::Bool = true,
        write_regions::Bool = true
    )

    mkpath(outdir)

    exported = mrst_data

    st0 = Dict{Symbol, Any}(:Reservoir => Dict{Symbol, Any}())
    res0 = st0[:Reservoir]

    # ---- Pressure ----
    if haskey(exported, "state0") && haskey(exported["state0"], "pressure")
        res0[:Pressure] = vec(copy(exported["state0"]["pressure"]))
    end

    # ---- Saturations ----
    # Many MRST exports include state0.s (nc×nph). If not present, skip.
    if haskey(exported, "state0") && haskey(exported["state0"], "s")
        s0 = copy(exported["state0"]["s"])
        nc = haskey(res0, :Pressure) ? length(res0[:Pressure]) : size(s0, 1)

        # Convert nc×nph -> nph×nc if needed
        if size(s0, 1) == nc
            res0[:Saturations] = permutedims(s0)
        else
            res0[:Saturations] = s0
        end
    end

    # Determine nc (for shaping perm)
    nc = if haskey(res0, :Pressure)
        length(res0[:Pressure])
    elseif haskey(res0, :Saturations)
        size(res0[:Saturations], 2)
    else
        # fall back to rock size if needed
        haskey(exported, "rock") && haskey(exported["rock"], "poro") ? length(vec(exported["rock"]["poro"])) : 0
    end

    # ---- Porosity ----
    if (:Porosity in vtu_vars) && haskey(exported, "rock") && haskey(exported["rock"], "poro")
        res0[:Porosity] = vec(copy(exported["rock"]["poro"]))
    end

    # ---- Permeability (auto 1/3/6 components) ----
    if (:Permeability in vtu_vars) && haskey(exported, "rock") && haskey(exported["rock"], "perm")
        perm_raw = copy(exported["rock"]["perm"])
        perm_mat = perm_raw isa AbstractVector ? reshape(vec(perm_raw), :, 1) : Array(perm_raw)  # usually nc×ncomp

        if nc > 0 && size(perm_mat, 1) == nc
            # convert to ncomp×nc for compatibility with your exporter conventions
            res0[:Permeability] = permutedims(perm_mat)
        elseif nc > 0 && size(perm_mat, 2) == nc
            res0[:Permeability] = perm_mat
        else
            @warn "Permeability size doesn't match nc; writing as-is." size(perm_mat) nc
            res0[:Permeability] = perm_mat
        end
    end

    # ---- Regions (cell data) ----
    reservoir_regions = nothing
    do_regions = false
    if write_regions && haskey(exported, "rock") && haskey(exported["rock"], "regions")
        reservoir_regions = exported["rock"]["regions"]  # Dict{String,Any}
        do_regions = true
    end

    report_times_vtu_export(mrst_data["G"], [st0];
        outdir = outdir,
        prefix = prefix,            # will produce prefix_0000.vtu
        vars = vtu_vars,
        split_matrices = split_matrices,   # true -> Permeability_1..; false -> multi-comp array
        write_pvd = false,
        times = [0.0],
        write_regions = do_regions,
        reservoir_regions = do_regions ? reservoir_regions : nothing,
        write_dp = false
    )

    return nothing
end
