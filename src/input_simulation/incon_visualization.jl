# incon_visualization.jl
using MAT

"""
    export_initial_step0_vtu(fn, mrst_data;
        outdir, prefix,
        vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
        split_matrices = true,
        write_regions = true,
        extra_cell_data = nothing)

Export ONE VTU for the initial condition using:
- grid from `mrst_data["G"]`
- rock/state0/regions from `mrst_data`

Permeability:
- supports nc×1, nc×3, nc×6 in MAT export
- stores as ncomp×nc for compatibility with the state exporter

Extra cell data:
- accepts a dictionary of named vectors with exactly one value per cell
- appends only those explicitly supplied arrays to the initial-condition VTU
"""
function export_initial_step0_vtu(fn::AbstractString, mrst_data::Dict{String,Any};
        outdir::AbstractString,
        prefix::AbstractString,
        vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
        split_matrices::Bool = true,
        write_regions::Bool = true,
        extra_cell_data = nothing
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

    # ---- Explicit caller-supplied cell arrays ----
    extra_names = Symbol[]
    if !isnothing(extra_cell_data)
        extra_cell_data isa AbstractDict ||
            error("extra_cell_data must be a dictionary-like object.")
        for (raw_name, raw_values) in pairs(extra_cell_data)
            name = Symbol(raw_name)
            name_text = String(name)
            reserved_name =
                name in (
                    :Pressure,
                    :Saturations,
                    :Porosity,
                    :Permeability,
                    :sat_region,
                    :rock_region,
                    :imbi_region
                ) ||
                startswith(name_text, "Saturations_") ||
                startswith(name_text, "Permeability_")
            reserved_name && error(
                "extra_cell_data[$raw_name] collides with a generated VTU array name."
            )
            haskey(res0, name) &&
                error("extra_cell_data duplicates the built-in array $name.")
            raw_values isa AbstractVector ||
                error("extra_cell_data[$raw_name] must be a vector.")
            values = vec(raw_values)
            length(values) == nc || error(
                "extra_cell_data[$raw_name] has $(length(values)) values, expected $nc."
            )
            res0[name] = copy(values)
            push!(extra_names, name)
        end
    end
    effective_vtu_vars = if vtu_vars === :all
        :all
    else
        unique(vcat(Symbol.(collect(vtu_vars)), extra_names))
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
        vars = effective_vtu_vars,
        split_matrices = split_matrices,   # true -> Permeability_1..; false -> multi-comp array
        write_pvd = false,
        times = [0.0],
        write_regions = do_regions,
        reservoir_regions = do_regions ? reservoir_regions : nothing,
        write_dp = false
    )

    return nothing
end
