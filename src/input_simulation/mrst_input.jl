function get_mrst_input_path(name)
    function valid_mat_path(S)
        base, ext = splitext(S)
        if ext != "" && ext != ".mat"
            error("MRST input file should have .mat extension, file $S had extension $ext")
        end
        pth = "$(base).mat"
        return (pth, ispath(pth))
    end

    fn, ok = valid_mat_path(name)
    if !ok
        # The path given does not work directly, but could be found through
        # either an environment variable or as a part of the default cases that
        # come with JutulDarcy. Let us try those and otherwise try to give a
        # helpful message explaining what we did try.
        has_global_path = haskey(ENV, "JUTUL_MRST_EXPORTS_PATH")
        if has_global_path
            base_path = ENV["JUTUL_MRST_EXPORTS_PATH"]
        else
            base_path = ""
        end
        pth_env = joinpath(base_path, name)
        fn_env, ok = valid_mat_path(pth_env)
        if ok
            fn = fn_env
        else
            base_path, = splitdir(pathof(JutulDarcy))
            pth_mod = joinpath(base_path, "..", "test", "mrst", "$(name).mat")
            fn_mod, ok = valid_mat_path(pth_mod)
            if ok
                fn = fn_mod
            else
                if has_global_path
                    error("Did not find valid .mat file in either of the following paths:\n$fn (input) \n$fn_env (from ENV[\"JUTUL_MRST_EXPORTS_PATH\"])\n$pth_mod (included test files)")
                else
                    error("Did not find valid .mat file in $fn. You can set ENV[\"JUTUL_MRST_EXPORTS_PATH\"] if you have a global path for .mat files.")
                end
            end
        end
    end
    return fn
end

function mrst_diffusion_override(diffusion, nc::Int)
    if isnothing(diffusion)
        # Leave diffusion disabled for this case.
        out = nothing
    elseif diffusion isa Number
        # Single scalar -> same coefficient in every cell.
        out = fill(float(diffusion), nc)
    elseif diffusion isa Tuple
        # Tuple -> one uniform coefficient per phase, expanded to all cells.
        out = zeros(Float64, length(diffusion), nc)
        for (i, coeff) in enumerate(diffusion)
            out[i, :] .= coeff
        end
    elseif diffusion isa AbstractVector
        if length(diffusion) == nc
            # Cellwise diffusion for a single phase / shared coefficient field.
            out = collect(diffusion)
        else
            # Short vector -> interpret as one uniform coefficient per phase.
            out = zeros(Float64, length(diffusion), nc)
            for (i, coeff) in enumerate(diffusion)
                out[i, :] .= coeff
            end
        end
    elseif diffusion isa AbstractMatrix
        if size(diffusion, 2) == nc
            # Already in the internal layout: (nphases, ncells).
            out = copy(diffusion)
        elseif size(diffusion, 1) == nc
            # Accept transposed input as a convenience for callers.
            out = collect(diffusion')
        else
            error("Diffusion override matrix must have $nc columns (or rows before transpose).")
        end
    else
        error("Unsupported diffusion override of type $(typeof(diffusion)).")
    end
    # Internal convention used downstream is either:
    #   Vector{Float64}          -> one coefficient per cell
    #   Matrix{Float64}(nph, nc) -> one coefficient per phase and cell
    return out
end

function mrst_get_vec(d)
    if isa(d, AbstractArray)
        return vec(copy(d))
    else
        return [d]
    end
end

function normalize_mrst_schedule_control!(mrst_data)
    if !haskey(mrst_data, "schedule") || !haskey(mrst_data["schedule"], "control")
        return mrst_data
    end

    schedule = mrst_data["schedule"]
    ctrl = schedule["control"]

    function wrap_well_set(w)
        if w isa AbstractDict
            return reshape(Any[w], 1, 1)
        else
            return w
        end
    end

    if ctrl isa AbstractDict
        array_lengths = Int[]
        for v in values(ctrl)
            if v isa AbstractArray
                push!(array_lengths, length(v))
            end
        end
        isempty(array_lengths) && return mrst_data
        nctrl = maximum(array_lengths)
        normalized = Matrix{Any}(undef, nctrl, 1)
        for i in 1:nctrl
            ctrl_i = Dict{String, Any}()
            for (k, v) in pairs(ctrl)
                key = String(k)
                if v isa AbstractArray && length(v) == nctrl
                    value = vec(v)[i]
                else
                    value = v
                end
                if key == "W"
                    value = wrap_well_set(value)
                end
                ctrl_i[key] = value
            end
            normalized[i, 1] = ctrl_i
        end
        schedule["control"] = normalized
    elseif ctrl isa AbstractArray
        for ctrl_i in ctrl
            if ctrl_i isa AbstractDict && haskey(ctrl_i, "W")
                ctrl_i["W"] = wrap_well_set(ctrl_i["W"])
            end
        end
    end
    return mrst_data
end

function mrst_has_pressure_boundary_conditions(mrst_data)
    if !haskey(mrst_data, "schedule") || !haskey(mrst_data["schedule"], "control")
        return false
    end
    ctrl = mrst_data["schedule"]["control"]
    controls = ctrl isa AbstractArray ? vec(ctrl) : [ctrl]
    for ctrl_i in controls
        if ctrl_i isa AbstractDict && haskey(ctrl_i, "bc")
            bc = ctrl_i["bc"]
            if length(bc) > 0
                return true
            end
        end
    end
    return false
end

function restore_mrst_split_fault_tables!(assembled, fault)
    if !haskey(fault, "fluid_tables")
        return assembled
    end
    props = assembled["deck"]["PROPS"]
    for (keyword, table_data) in pairs(fault["fluid_tables"])
        key = String(keyword)
        if !(table_data isa AbstractDict) || !haskey(table_data, "tables")
            continue
        end
        haskey(props, key) || error("Split-specific file provides $key tables, but common deck.PROPS has no $key entry.")
        haskey(table_data, "regions") || error("Split-specific fluid table $key is missing regions.")
        regions = Int.(mrst_get_vec(table_data["regions"]))
        tables = mrst_get_vec(table_data["tables"])
        length(regions) == length(tables) || error("Split-specific fluid table $key has $(length(regions)) regions but $(length(tables)) tables.")
        target = props[key]
        for (region, table) in zip(regions, tables)
            1 <= region <= length(target) || error("Split-specific fluid table $key region $region is outside common table length $(length(target)).")
            target[region] = table
        end
    end
    return assembled
end

function mrst_has_explicit_fault_saturation_data(specific)
    return haskey(specific, "fault") &&
           haskey(specific["fault"], "saturation_region")
end

function normalize_mrst_explicit_fault_hysteresis_mode(mode)
    if isnothing(mode)
        return "disable"
    elseif mode isa Symbol
        return lowercase(String(mode))
    else
        return lowercase(strip(String(mode)))
    end
end

function normalize_mrst_fault_pc_entry_treatment(treatment)
    if isnothing(treatment)
        return "none"
    elseif treatment isa Symbol
        return lowercase(String(treatment))
    else
        return lowercase(strip(String(treatment)))
    end
end

function apply_mrst_fault_pc_entry_treatment!(tables, regions;
        treatment = "none",
        sg_max::Real = 1.0e-4
    )
    normalized = normalize_mrst_fault_pc_entry_treatment(treatment)
    normalized in ("", "none", "off", "false", "0") && return nothing

    if !(normalized in ("plateau", "entry_plateau", "pc_plateau"))
        error("Unknown FAULT_PC_ENTRY_TREATMENT=$treatment. Valid options: none, plateau.")
    end

    adjusted = 0
    skipped = 0
    max_old_slope = 0.0
    max_entry_pressure = 0.0
    for (region, table) in zip(regions, tables)
        if !(table isa AbstractMatrix) || size(table, 1) < 2 || size(table, 2) < 4
            skipped += 1
            continue
        end
        sg1 = table[1, 1]
        sg2 = table[2, 1]
        pc1 = table[1, 4]
        pc2 = table[2, 4]
        if sg1 == 0 && pc1 == 0 && sg2 > sg1 && sg2 <= sg_max && pc2 > 0
            old_slope = (pc2 - pc1)/(sg2 - sg1)
            max_old_slope = max(max_old_slope, old_slope)
            max_entry_pressure = max(max_entry_pressure, pc2)
            table[1, 4] = pc2
            adjusted += 1
        else
            skipped += 1
        end
    end

    summary = Dict{String, Any}(
        "treatment" => normalized,
        "sg_max" => Float64(sg_max),
        "adjusted_tables" => adjusted,
        "skipped_tables" => skipped,
        "max_original_initial_slope" => max_old_slope,
        "max_entry_pressure" => max_entry_pressure
    )
    jutul_message(
        "MRST split input",
        "FAULT_PC_ENTRY_TREATMENT=$normalized: adjusted $adjusted fault SGOF Pc tables with Sg[2] <= $sg_max.",
        color = :yellow
    )
    return summary
end

function apply_mrst_explicit_fault_saturation_data!(assembled, specific;
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable"
    )
    hyst_mode = normalize_mrst_explicit_fault_hysteresis_mode(explicit_fault_hysteresis_mode)
    if !(hyst_mode in ("", "disable", "disabled", "none", "off", "false", "0", "reservoir", "reservoir_only", "reservoir-only"))
        error("Unknown EXPLICIT_FAULT_HYSTERESIS_MODE=$explicit_fault_hysteresis_mode. Valid options: disable, reservoir.")
    end
    reservoir_hysteresis = hyst_mode in ("reservoir", "reservoir_only", "reservoir-only")

    fault = specific["fault"]
    for key in ("cells", "saturation_region", "fluid_tables")
        haskey(fault, key) || error("Explicit fault saturation data is missing fault[\"$key\"].")
    end

    cells = Int.(mrst_get_vec(fault["cells"]))
    cell_regions = Int.(mrst_get_vec(fault["saturation_region"]))
    length(cells) == length(cell_regions) || error(
        "fault.cells has $(length(cells)) entries but fault.saturation_region has $(length(cell_regions))."
    )

    fluid_tables = fault["fluid_tables"]
    haskey(fluid_tables, "SGOF") || error("Explicit fault saturation data requires fault.fluid_tables.SGOF.")
    sgof_data = fluid_tables["SGOF"]
    haskey(sgof_data, "regions") || error("Explicit fault SGOF data is missing regions.")
    haskey(sgof_data, "tables") || error("Explicit fault SGOF data is missing tables.")

    custom_regions = Int.(mrst_get_vec(sgof_data["regions"]))
    custom_tables = mrst_get_vec(sgof_data["tables"])
    length(custom_regions) == length(custom_tables) || error(
        "Explicit fault SGOF data has $(length(custom_regions)) regions but $(length(custom_tables)) tables."
    )
    length(unique(custom_regions)) == length(custom_regions) || error("Explicit fault SGOF regions must be unique.")

    order = sortperm(custom_regions)
    custom_regions = custom_regions[order]
    custom_tables = [deepcopy(table) for table in custom_tables[order]]
    pc_entry_summary = apply_mrst_fault_pc_entry_treatment!(
        custom_tables,
        custom_regions;
        treatment = fault_pc_entry_treatment,
        sg_max = fault_pc_entry_sg_max
    )
    base_regions = minimum(custom_regions) - 1
    maximum_region = maximum(custom_regions)
    custom_regions == collect((base_regions + 1):maximum_region) || error(
        "Explicit fault SGOF regions must be contiguous after the $base_regions shared base regions."
    )
    all(in(custom_regions), cell_regions) || error(
        "fault.saturation_region contains ids outside the explicit SGOF region set."
    )

    rock_regions = assembled["rock"]["regions"]
    haskey(rock_regions, "saturation") || error("Explicit fault saturation data requires rock.regions.saturation.")
    sat = vec(rock_regions["saturation"])
    all(c -> 1 <= c <= length(sat), cells) || error("Explicit fault cells are outside rock.regions.saturation.")
    sat[cells] .= cell_regions

    props = assembled["deck"]["PROPS"]
    haskey(props, "SGOF") || error("Explicit fault saturation data requires deck.PROPS.SGOF.")
    old_tables = mrst_get_vec(props["SGOF"])
    length(old_tables) >= base_regions || error(
        "Common SGOF data has $(length(old_tables)) tables, fewer than the $base_regions shared base regions."
    )

    runspec = assembled["deck"]["RUNSPEC"]
    hysteresis_summary = "disabled"
    if reservoir_hysteresis
        haskey(props, "EHYSTR") || error(
            "EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir requires common deck.PROPS.EHYSTR."
        )
        iseven(length(old_tables)) || error(
            "EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir requires common drainage/imbibition SGOF pairs, got $(length(old_tables)) tables."
        )
        old_drainage_regions = length(old_tables) ÷ 2
        length(old_tables) >= 2*base_regions || error(
            "Common SGOF data has $(length(old_tables)) tables, fewer than paired base regions require."
        )

        new_tables = Vector{Any}(undef, 2*maximum_region)
        for region in 1:base_regions
            isempty(old_tables[region]) && error("Common drainage SGOF base region $region is empty.")
            isempty(old_tables[old_drainage_regions + region]) && error("Common imbibition SGOF base region $region is empty.")
            new_tables[region] = deepcopy(old_tables[region])
            new_tables[maximum_region + region] = deepcopy(old_tables[old_drainage_regions + region])
        end
        for (region, table) in zip(custom_regions, custom_tables)
            isempty(table) && error("Explicit fault SGOF region $region is empty.")
            new_tables[region] = table
            # Fault-specific imbibition curves are not provided. Duplicate the
            # drainage table so reservoir hysteresis can remain active while
            # fault regions behave as drainage-only.
            new_tables[maximum_region + region] = deepcopy(table)
        end
        props["SGOF"] = reshape(new_tables, :, 1)
        if haskey(rock_regions, "imbibition")
            imb = vec(rock_regions["imbibition"])
            imb .= sat .+ maximum_region
        end
        if haskey(runspec, "NOHYST")
            delete!(runspec, "NOHYST")
        end
        update_mrst_tabdims_num_saturation_tables!(assembled, length(new_tables))
        hysteresis_summary = "reservoir_only_fault_drainage_duplicate"
    else
        new_tables = Vector{Any}(undef, maximum_region)
        for region in 1:base_regions
            isempty(old_tables[region]) && error("Common SGOF base region $region is empty.")
            new_tables[region] = deepcopy(old_tables[region])
        end
        for (region, table) in zip(custom_regions, custom_tables)
            isempty(table) && error("Explicit fault SGOF region $region is empty.")
            new_tables[region] = table
        end
        props["SGOF"] = reshape(new_tables, :, 1)

        # The reservoir-ready package commonly provides drainage curves only.
        # Keep the default conservative behavior: remove stale imbibition ids
        # and force the deck onto drainage unless reservoir-only hysteresis is
        # explicitly requested.
        if haskey(rock_regions, "imbibition")
            delete!(rock_regions, "imbibition")
        end
        runspec["NOHYST"] = true
        update_mrst_tabdims_num_saturation_tables!(assembled, maximum_region)
    end

    assembled["fault_saturation_domain_mode"] = "reservoir_ready_explicit"
    assembled["fault_saturation_domain_summary"] = Dict{String, Any}(
        "base_regions" => base_regions,
        "fault_regions" => length(custom_regions),
        "drainage_regions" => maximum_region,
        "sgof_tables" => length(new_tables),
        "hysteresis" => hysteresis_summary,
        "pc_entry_treatment" => isnothing(pc_entry_summary) ? Dict{String, Any}("treatment" => "none") : pc_entry_summary
    )
    jutul_message(
        "MRST split input",
        "Applied $(length(custom_regions)) explicit reservoir-ready fault saturation regions and SGOF tables; hysteresis=$hysteresis_summary.",
        color = :yellow
    )
    return assembled
end

function normalize_mrst_fault_saturation_domain_mode(mode)
    if isnothing(mode)
        return "input"
    elseif mode isa Symbol
        return lowercase(String(mode))
    else
        return lowercase(strip(String(mode)))
    end
end

function mrst_window_x_groups(assembled, window_cells)
    centroids = assembled["G"]["cells"]["centroids"]
    groups = Vector{Vector{Float64}}(undef, length(window_cells))
    for (i, cells_i_raw) in enumerate(window_cells)
        cells_i = Int.(mrst_get_vec(cells_i_raw))
        x_i = centroids[cells_i, 1]
        groups[i] = sort(unique(vec(x_i)))
    end
    return groups
end

function mrst_lookup_x_group(x_to_group, x)
    if haskey(x_to_group, x)
        return x_to_group[x]
    end

    # The x values come from the same centroid array, so exact lookup should
    # normally work. Keep a tiny nearest fallback to make the remap robust to
    # harmless MAT roundoff or future centroid formatting changes.
    keys_x = collect(keys(x_to_group))
    _, ix = findmin(abs.(keys_x .- x))
    nearest = keys_x[ix]
    tol = max(1.0e-8, 1.0e-10*max(abs(x), abs(nearest), 1.0))
    if abs(nearest - x) <= tol
        return x_to_group[nearest]
    end
    error("Could not map fault-cell x centroid $x to a PREDICT draw group.")
end

function update_mrst_tabdims_num_saturation_tables!(assembled, n_tables::Int)
    if haskey(assembled, "deck") && haskey(assembled["deck"], "RUNSPEC")
        runspec = assembled["deck"]["RUNSPEC"]
        if haskey(runspec, "TABDIMS") && length(runspec["TABDIMS"]) >= 1
            runspec["TABDIMS"][1] = Float64(n_tables)
        end
    end
    return assembled
end

function expand_mrst_predict_fault_saturation_domains!(assembled, specific)
    haskey(specific, "fault") || error("PREDICT fault saturation-domain remap requires specific[\"fault\"].")
    haskey(specific, "predict_sample_ids") || error("PREDICT fault saturation-domain remap requires specific[\"predict_sample_ids\"].")

    fault = specific["fault"]
    rock = assembled["rock"]
    regions = rock["regions"]
    haskey(regions, "saturation") || error("PREDICT fault saturation-domain remap requires rock.regions.saturation.")
    haskey(fault, "cells") || error("PREDICT fault saturation-domain remap requires fault.cells.")
    haskey(fault, "window_index") || error("PREDICT fault saturation-domain remap requires fault.window_index.")
    haskey(assembled, "masks") && haskey(assembled["masks"], "windowCells") || error("PREDICT fault saturation-domain remap requires masks.windowCells in the common input.")

    cells = Int.(mrst_get_vec(fault["cells"]))
    window_index = Int.(mrst_get_vec(fault["window_index"]))
    length(cells) == length(window_index) || error("fault.cells and fault.window_index have different lengths.")
    nwindows = maximum(window_index)
    all((1 .<= window_index) .& (window_index .<= nwindows)) || error("fault.window_index must use positive contiguous window ids.")

    sample_ids = specific["predict_sample_ids"]["ids"]
    nsamples = if ndims(sample_ids) == 2 && size(sample_ids, 1) == nwindows
        size(sample_ids, 2)
    elseif ndims(sample_ids) == 2 && size(sample_ids, 2) == nwindows
        size(sample_ids, 1)
    else
        error("predict_sample_ids.ids has size $(size(sample_ids)), which does not match $nwindows fault windows.")
    end

    window_cells = mrst_get_vec(assembled["masks"]["windowCells"])
    length(window_cells) == nwindows || error("masks.windowCells has $(length(window_cells)) windows but fault.window_index uses $nwindows.")
    x_groups = mrst_window_x_groups(assembled, window_cells)
    all(length(g) == nsamples for g in x_groups) || error("Window x-group counts $(length.(x_groups)) do not match $nsamples PREDICT samples.")
    x_to_group = [Dict(x => j for (j, x) in enumerate(groups_i)) for groups_i in x_groups]

    sat_raw = regions["saturation"]
    old_sat = Int.(vec(sat_raw))
    old_fault_sat = old_sat[cells]
    base_regions = minimum(old_fault_sat) - 1
    old_predict_regions = sort(unique(old_fault_sat))
    expected_old_predict_regions = collect((base_regions + 1):(base_regions + nwindows))
    old_predict_regions == expected_old_predict_regions || error(
        "Expected old PREDICT fault saturation regions $expected_old_predict_regions, got $old_predict_regions."
    )

    sat = vec(sat_raw)
    centroids = assembled["G"]["cells"]["centroids"]
    for (cell, win) in zip(cells, window_index)
        x = centroids[cell, 1]
        draw_group = mrst_lookup_x_group(x_to_group[win], x)
        sat[cell] = base_regions + (draw_group - 1)*nwindows + win
    end

    new_drainage_regions = base_regions + nsamples*nwindows
    if haskey(regions, "imbibition")
        imb = vec(regions["imbibition"])
        imb .= vec(sat_raw) .+ new_drainage_regions
    end

    props = assembled["deck"]["PROPS"]
    haskey(props, "SGOF") || error("PREDICT fault saturation-domain remap requires deck.PROPS.SGOF.")
    old_tables = mrst_get_vec(props["SGOF"])
    iseven(length(old_tables)) || error("Expected drainage/imbibition SGOF pairs, got $(length(old_tables)) tables.")
    old_drainage_regions = length(old_tables) ÷ 2
    maximum(old_sat) <= old_drainage_regions || error("Old SATNUM maximum $(maximum(old_sat)) exceeds drainage SGOF table count $old_drainage_regions.")
    base_regions < old_drainage_regions || error("Base saturation-domain count $base_regions is incompatible with $old_drainage_regions old drainage tables.")

    new_tables = Vector{Any}(undef, 2*new_drainage_regions)
    for reg in 1:base_regions
        new_tables[reg] = deepcopy(old_tables[reg])
        new_tables[new_drainage_regions + reg] = deepcopy(old_tables[old_drainage_regions + reg])
    end
    for draw_group in 1:nsamples, win in 1:nwindows
        old_reg = base_regions + win
        new_reg = base_regions + (draw_group - 1)*nwindows + win
        new_tables[new_reg] = deepcopy(old_tables[old_reg])
        new_tables[new_drainage_regions + new_reg] = deepcopy(old_tables[old_drainage_regions + old_reg])
    end
    props["SGOF"] = reshape(new_tables, :, 1)
    update_mrst_tabdims_num_saturation_tables!(assembled, length(new_tables))

    assembled["fault_saturation_domain_mode"] = "predict_sample"
    assembled["fault_saturation_domain_summary"] = Dict{String, Any}(
        "base_regions" => base_regions,
        "fault_windows" => nwindows,
        "predict_samples_per_window" => nsamples,
        "predict_fault_regions" => nsamples*nwindows,
        "drainage_regions" => new_drainage_regions,
        "sgof_tables" => length(new_tables)
    )
    jutul_message(
        "MRST split input",
        "FAULT_SATURATION_DOMAIN_MODE=predict_sample: remapped $(length(cells)) PREDICT fault cells to $(nsamples*nwindows) fault saturation domains ($(length(new_tables)) SGOF tables including imbibition).",
        color = :yellow
    )
    return assembled
end

function apply_mrst_fault_saturation_domain_mode!(assembled, specific, mode)
    normalized = normalize_mrst_fault_saturation_domain_mode(mode)
    if normalized in ("", "input", "default", "none", "off", "false", "0")
        return assembled
    elseif normalized in ("predict_sample", "predict_samples", "predict_sample_522", "sample", "samples")
        return expand_mrst_predict_fault_saturation_domains!(assembled, specific)
    else
        error("Unknown FAULT_SATURATION_DOMAIN_MODE=$mode. Valid options: input, predict_sample.")
    end
end

function validate_mrst_split_case(assembled, specific)
    errors = String[]
    fault = haskey(specific, "fault") ? specific["fault"] : nothing
    if isnothing(fault)
        push!(errors, "specific file is missing top-level fault data")
    else
        for key in ("cells", "poro", "perm")
            if !haskey(fault, key)
                push!(errors, "specific fault block is missing $key")
            end
        end
    end

    if haskey(assembled, "rock")
        rock = assembled["rock"]
        if haskey(rock, "poro") && any(isnan, rock["poro"])
            push!(errors, "assembled rock.poro still contains NaN values")
        end
        if haskey(rock, "perm") && any(isnan, rock["perm"])
            push!(errors, "assembled rock.perm still contains NaN values")
        end
    else
        push!(errors, "assembled case is missing rock data")
    end

    if haskey(assembled, "schedule") && haskey(assembled["schedule"], "control")
        if assembled["schedule"]["control"] isa AbstractDict
            push!(errors, "assembled schedule.control was not normalized to an array of controls")
        end
    end

    if mrst_has_pressure_boundary_conditions(assembled) && !haskey(assembled, "T_all")
        push!(errors, "pressure boundary conditions require T_all in the current MRST importer")
    end

    if !isempty(errors)
        error("Invalid assembled MRST split case:\n - $(join(errors, "\n - "))")
    end
    return true
end

function assemble_mrst_split_case(common, specific;
        validate::Bool = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable"
    )
    haskey(specific, "fault") || error("Specific MRST split file must contain a top-level fault block.")
    assembled = deepcopy(common)
    fault = specific["fault"]
    cells = Int.(mrst_get_vec(fault["cells"]))
    length(cells) == length(unique(cells)) || error("Split-specific fault cells must be unique.")

    rock = assembled["rock"]
    nc = length(vec(rock["poro"]))
    all(c -> 1 <= c <= nc, cells) || error("Split-specific fault cells must be between 1 and $nc.")

    poro = rock["poro"]
    fault_poro = fault["poro"]
    if poro isa AbstractVector
        poro[cells] .= vec(fault_poro)
    else
        poro[cells, :] .= fault_poro
    end

    perm = rock["perm"]
    fault_perm = fault["perm"]
    if perm isa AbstractVector
        perm[cells] .= vec(fault_perm)
    else
        perm[cells, :] .= fault_perm
    end

    if mrst_has_explicit_fault_saturation_data(specific)
        normalized_mode = normalize_mrst_fault_saturation_domain_mode(fault_saturation_domain_mode)
        if !(normalized_mode in ("", "input", "default", "none", "off", "false", "0"))
            error("Explicit reservoir-ready fault saturation data must use fault_saturation_domain_mode=\"input\".")
        end
        apply_mrst_explicit_fault_saturation_data!(assembled, specific;
            fault_pc_entry_treatment = fault_pc_entry_treatment,
            fault_pc_entry_sg_max = fault_pc_entry_sg_max,
            explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode
        )
    else
        restore_mrst_split_fault_tables!(assembled, fault)
        apply_mrst_fault_saturation_domain_mode!(assembled, specific, fault_saturation_domain_mode)
    end
    normalize_mrst_schedule_control!(assembled)
    if validate
        validate_mrst_split_case(assembled, specific)
    end
    return assembled
end

function read_mrst_split_case(common_path::AbstractString, specific_path::AbstractString;
        validate::Bool = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable"
    )
    common_fn = get_mrst_input_path(String(common_path))
    specific_fn = get_mrst_input_path(String(specific_path))
    @debug "Reading MRST split common MAT file $common_fn..."
    common = MAT.matread(common_fn)
    @debug "Reading MRST split specific MAT file $specific_fn..."
    specific = MAT.matread(specific_fn)
    assembled = assemble_mrst_split_case(common, specific;
        validate = validate,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode
    )
    assembled["split_input"] = Dict{String, Any}(
        "common_path" => common_fn,
        "specific_path" => specific_fn
    )
    return assembled
end

function disable_mrst_hysteresis!(mrst_data)
    if !(haskey(mrst_data, "deck") && haskey(mrst_data["deck"], "RUNSPEC"))
        @warn "DISABLE_HYSTERESIS=true was requested, but the MRST data has no deck RUNSPEC."
        return false
    end

    runspec = mrst_data["deck"]["RUNSPEC"]
    runspec["NOHYST"] = true

    props = get(mrst_data["deck"], "PROPS", Dict{String, Any}())
    if haskey(props, "EHYSTR")
        jutul_message("MRST model", "DISABLE_HYSTERESIS=true: ignoring EHYSTR through RUNSPEC NOHYST.", color = :yellow)
    else
        jutul_message("MRST model", "DISABLE_HYSTERESIS=true: RUNSPEC NOHYST set, but no EHYSTR table was present.", color = :yellow)
    end
    return true
end

function override_mrst_hysteresis_s_min!(mrst_data, hysteresis_s_min)
    isnothing(hysteresis_s_min) && return false

    if !(haskey(mrst_data, "deck") && haskey(mrst_data["deck"], "PROPS"))
        @warn "HYSTERESIS_S_MIN=$hysteresis_s_min was requested, but the MRST data has no deck PROPS."
        return false
    end

    props = mrst_data["deck"]["PROPS"]
    if !haskey(props, "EHYSTR")
        @warn "HYSTERESIS_S_MIN=$hysteresis_s_min was requested, but no EHYSTR table was present."
        return false
    end

    ehystr = props["EHYSTR"]
    if length(ehystr) < 12
        @warn "HYSTERESIS_S_MIN=$hysteresis_s_min was requested, but EHYSTR has length $(length(ehystr)) < 12."
        return false
    end

    old_s_min = ehystr[12]
    ehystr[12] = Float64(hysteresis_s_min)
    jutul_message("MRST model", "HYSTERESIS_S_MIN=$(ehystr[12]): overriding EHYSTR[12] from $old_s_min.", color = :yellow)
    return true
end

function reservoir_domain_from_mrst_data(exported;
        extraout = false,
        convert_grid = false,
        diffusion = nothing,
        use_mrst_transmissibility::Bool = true
    )
    @debug "Unpacking MRST data..."
    normalize_mrst_schedule_control!(exported)
    G_raw = exported["G"]
    if convert_grid && haskey(G_raw, "nodes")
        g = UnstructuredMesh(G_raw)
    else
        g = MRSTWrapMesh(G_raw)
    end
    has_exported_trans = haskey(exported, "T") && length(exported["T"]) > 0
    has_trans = use_mrst_transmissibility && has_exported_trans

    poro = mrst_get_vec(exported["rock"]["poro"])
    perm = copy((exported["rock"]["perm"])')

    diffusion_coeff = mrst_diffusion_override(diffusion, length(poro))
    if isnothing(diffusion_coeff)
        domain = reservoir_domain(g, porosity = poro, permeability = perm)
    else
        domain = reservoir_domain(g, porosity = poro, permeability = perm, diffusion = diffusion_coeff)
    end

    if haskey(exported, "rock") && haskey(exported["rock"], "regions") &&
    haskey(exported["rock"]["regions"], "rocknum")
        rocknum = Int64.(mrst_get_vec(exported["rock"]["regions"]["rocknum"]))
        domain[:rocknum, Cells()] = rocknum
    end

    if haskey(exported["rock"], "ntg")
        ntg = mrst_get_vec(exported["rock"]["ntg"])
        domain[:net_to_gross, Cells()] = ntg
        # TODO: MRST exporter assumes pv = vol*poro and defines poro from that.
        # We fix that calculation here in the Jutul side. If we fix it in the
        # MATLAB exporter all old exported mat files will be rendered obsolete.
        domain[:porosity] = poro./ntg
    end
    nf = number_of_faces(domain)
    if haskey(exported, "N")
        N = Int64.(exported["N"]')
        nf = size(N, 2)
        if nf != number_of_faces(domain)
            jutul_message("Case setup", "Mismatch beteween neighborship and grid. Simulation model will work, but post-processing based on geometry may fail.")
            d = Jutul.dim(g)
            domain.entities[Faces()] = nf
            domain[:areas, Faces()] = fill!(zeros(nf), NaN)
            domain[:normals, Faces()] = fill!(zeros(d, nf), NaN)
            domain[:face_centroids, Faces()] = fill!(zeros(d, nf), NaN)
        end
        domain[:neighbors, Faces()] = N
    end
    # Deal with face data
    if has_trans
        @debug "Found precomputed transmissibilities, reusing"
        T = mrst_get_vec(exported["T"])
        domain[:transmissibilities, Faces()] = T
    elseif has_exported_trans
        jutul_message("MRST model", "Ignoring exported MRST transmissibilities; JutulDarcy will compute T from grid and rock.", color = :yellow)
    end
    if extraout
        return (domain, exported)
    else
        return domain
    end
end

function reservoir_domain_from_mrst(name::String;
        extraout = false,
        convert_grid = false,
        diffusion = nothing,
        use_mrst_transmissibility::Bool = true
    )
    fn = get_mrst_input_path(name)
    @debug "Reading MAT file $fn..."
    exported = MAT.matread(fn)
    return reservoir_domain_from_mrst_data(exported;
        extraout = extraout,
        convert_grid = convert_grid,
        diffusion = diffusion,
        use_mrst_transmissibility = use_mrst_transmissibility
    )
end

function get_well_from_mrst_data(
        mrst_data, system, ix;
        volume = 1e-3,
        extraout = false,
        use_lengths = false,
        well_type = :simple,
        W_data = mrst_data["W"],
        kwarg...
    )
    W_mrst = W_data[ix]
    if haskey(W_mrst, "isMS") && W_mrst["isMS"]
        # This should always be treated as a MS well.
        well_type = :ms
    end
    if haskey(mrst_data, "surface_conditions")
        p = only(mrst_data["surface_conditions"]["pressure"])::Float64
        T = only(mrst_data["surface_conditions"]["T"])::Float64
        cond = (p = p, T = T)
    else
        cond = default_surface_cond()
    end
    function awrap(x::Any)
        x
    end
    function awrap(x::Number)
        [x]
    end
    ref_depth = W_mrst["refDepth"]
    rc = Int64.(awrap(W_mrst["cells"]))
    n = length(rc)
    # dz = awrap(w.dZ)
    WI = awrap(W_mrst["WI"])
    WIth = haskey(W_mrst, "WIth") ? awrap(W_mrst["WIth"]) : fill(0.0, length(WI))
    cell_centroids = copy((mrst_data["G"]["cells"]["centroids"])')
    centers = cell_centroids[:, rc]
    if size(centers, 1) == 2
        centers = vcat(centers, zeros(1, size(centers, 2)))
    end
    z_res = centers[3, :]
    res_volume = vec(copy(mrst_data["G"]["cells"]["volumes"]))

    well_cell_volume = res_volume[rc]
    nm =  W_mrst["name"]
    segment_models = nothing
    if well_type == :ms
        if haskey(W_mrst, "isMS") && W_mrst["isMS"]
            @info "MS well found: $nm"
            nodes = W_mrst["nodes"]
            V = vec(copy(nodes["vol"]))
            z = vec(copy(nodes["depth"]))
            cn = copy(W_mrst["cells_to_nodes"])
            top_node_depth = z[1]
            if !(z[1] ≈ ref_depth)
                @warn "$nm: Multisegment well with reference depth $ref_depth differs from top node depth $top_node_depth. Replacing reference depth."
                ref_depth = top_node_depth
            end
            # pvol - volume of each node (except for top node)
            pvol = V[2:end]
            # accumulator_volume - volume of top node
            accumulator_volume = V[1]
            # perf_cells - nodes that belong to the perforations in rc
            rc = Int64.(vec(cn[:, 1]))
            perf_cells = Int64.(vec(cn[:, 2]))
            # well_topo - well topology
            well_topo = Int64.(copy(W_mrst["topo"])')
            # depth from tubing to perforation for each perf
            dz = z_res .- z[perf_cells]
            # reservoir_cells - reservoir cells to be used to pick init values from
            n_nodes = length(z)
            reservoir_cells = zeros(Int64, n_nodes)
            for i in 1:n_nodes
                if i == 1
                    reservoir_cells[i] = rc[1]
                else
                    pos = findall(perf_cells .== i)
                    if isempty(pos)
                        # Not connected, guess by depth
                        z_local = z_res
                        cells_local = rc
                    else
                        z_local = z_res[pos]
                        cells_local = rc[pos]
                    end
                    d = (z[i] .- z_local).^2
                    reservoir_cells[i] = cells_local[argmin(d)]
                end
            end
            # Set node centers to cell centroids in xy plane and their corresponding true depths
            xy = cell_centroids[1:2, reservoir_cells[2:end]]
            centers = vcat(xy, z[2:end]')
            # Segment data follows
            segs = W_mrst["segments"]
            L = vec(segs["length"])
            D = vec(segs["diameter"])
            rough = vec(segs["roughness"])
            n_segs = size(well_topo, 2)
            if length(L) != n_segs
                @warn "Inconsistent segments. Adding averages."
                L = repeat([mean(L)], n_segs)
                D = repeat([mean(D)], n_segs)
                rough = repeat([mean(rough)], n_segs)
            end
            @assert size(well_topo, 2) == length(L) == length(D) == length(rough)
            segment_models = map(SegmentWellBoreFrictionHB, L, rough, D)
        else
            pvol, accumulator_volume, perf_cells, well_topo, z, dz, reservoir_cells = simple_ms_setup(n, volume, well_cell_volume, rc, ref_depth, z_res)
        end
        if use_lengths
            L_i = nothing
        else
            L_i = 1.0
        end
        W = MultiSegmentWell(rc, pvol, centers, WI = WI, WIth = WIth, reference_depth = ref_depth,
                                                        dz = dz,
                                                        N = well_topo,
                                                        name = Symbol(nm),
                                                        segment_models = segment_models,
                                                        segment_length = L_i,
                                                        perforation_cells = perf_cells,
                                                        accumulator_volume = accumulator_volume,
                                                        surface_conditions = cond)
    elseif well_type == :simple || well_type == :std
        # For simple well, distance from ref depth to perf
        dz = z_res .- ref_depth
        z = [ref_depth]
        accumulator_volume = volume*mean(well_cell_volume)
        W = SimpleWell(rc, WI = WI, WIth = WIth, dz = dz, surface_conditions = cond, name = Symbol(nm), volume = accumulator_volume)
        reservoir_cells = [rc[1]]
    else
        error("Unsupported well type $well_type (can be :ms, :simple or :std)")
    end
    if well_type == :std
        wsys = SimpleWellSystem(system)
    else
        wsys = system
    end
    W_domain = discretized_domain_well(W, z = z)
    wmodel = SimulationModel(W_domain, wsys; kwarg...)
    if haskey(mrst_data["deck"], "SOLUTION")
        sol = mrst_data["deck"]["SOLUTION"]
        if haskey(sol, "FIELDSEP")
            fsep = sol["FIELDSEP"]
            stage = Int.(fsep[:, 1])
            T = fsep[:, 2]
            p = fsep[:, 3]
            liquid_dest = Int.(fsep[:, 4])
            vapor_dest = Int.(fsep[:, 5])
            n = length(stage)
            for i in eachindex(stage)
                cond = (p = p[i], T = T[i])
                l = liquid_dest[i]
                if l == 0 && i < n
                    l = i+1
                end
                v = vapor_dest[i]
                add_separator_stage!(wmodel, cond, (l, v), clear = i == 1)
            end
        end
    end
    if extraout
        out = (wmodel, W_mrst, vec(reservoir_cells))
    else
        out = wmodel
    end
    return out
end

function simple_ms_setup(n, volume, well_cell_volume, rc, ref_depth, z_res)
    well_volume = volume*sum(well_cell_volume)
    # For a MS well, this is the drop from the perforated cell center to the perforation (assumed zero here)
    dz = zeros(length(rc))
    pvol = (well_volume/n)*ones(n)
    z = vcat(ref_depth, z_res)
    reservoir_cells = vcat(rc[1], rc)
    well_topo = nothing
    perf_cells = nothing
    accumulator_volume = pvol[1]
    return (pvol, accumulator_volume, perf_cells, well_topo, z, dz, reservoir_cells)
end

function model_from_mat(G, data_domain, mrst_data, res_context)
    ## Set up reservoir part
    @debug "Loading model from MRST:" keys(mrst_data)
    @assert haskey(mrst_data, "deck") "Model must contain deck field"
    return model_from_mat_deck(G, data_domain, mrst_data, res_context)
end

function rescale_btable(pvt, scaling, ix = 2)
    pvt = deepcopy(pvt)
    for (i, tab) in enumerate(pvt)
        if tab isa Vector
            tab[ix] /= scaling.water_density[i]
        else
            tab[:, ix] /= scaling.water_density[i]
        end
    end
    return pvt
end

function rescale_btable(pvt, scaling::Missing, ix = 2)
    return pvt
end

function deck_pvt_water(props; scaling = missing)
    if haskey(props, "PVTW_EXTENDED")
        t = rescale_btable(props["PVTW_EXTENDED"], scaling)
        pvt = PVTW_EXTENDED(t)
    else
        t = rescale_btable(props["PVTW"], scaling)
        pvt = PVTW(t)
    end
    return pvt
end

function rescale_live_table(pvt, scaling, k = :pvto)
    pvt = deepcopy(pvt)
    for (i, tab) in enumerate(pvt)
        if k == :pvto
            # rs is key
            # bo is second in data
            tab["key"] *= scaling.rs[i]
            tab["data"][:, 2] /= scaling.oil_density[i]
        else
            @assert k == :pvtg
            # rv is first
            # bo is second in data
            tab["data"][:, 1] *= scaling.rv[i]
            tab["data"][:, 2] /= scaling.gas_density[i]
        end
    end
    return pvt
end

function rescale_live_table(pvt, scaling::Missing, ix = 2)
    return pvt
end


function deck_pvt_oil(props; scaling = missing)
    if haskey(props, "PVTO")
        t = vec(props["PVTO"])
        t = rescale_live_table(t, scaling, :pvto)
        pvt = PVTO(t)
    elseif haskey(props, "PVDO")
        t = rescale_btable(props["PVDO"], scaling)
        pvt = PVDO(t)
    else
        t = rescale_btable(props["PVCDO"], scaling)
        pvt = PVCDO(t)
    end
    return pvt
end

function deck_pvt_gas(props; scaling = missing)
    if haskey(props, "PVTG")
        t = vec(props["PVTG"])
        t = rescale_live_table(t, scaling, :pvtg)
        pvt = PVTG(t)
    else
        t = rescale_btable(props["PVDG"], scaling)
        pvt = PVDG(t)
    end
    return pvt
end

function deck_relperm(runspec, props; oil, water, gas, satnum = nothing)
    if (water + oil + gas) == 1
        # Early return for single-phase.
        return BrooksCoreyRelativePermeabilities(1)
    end
    if haskey(runspec, "ENDSCALE")
        if haskey(props, "SCALECRS")
            scalecrs = props["SCALECRS"]
            if scalecrs isa String
                scalecrs = [scalecrs]
            end
            two_point_scaling = length(scalecrs) == 0 || lowercase(first(scalecrs)) == "no"
        else
            two_point_scaling = true
        end
        if two_point_scaling
            Jutul.jutul_message("Rel. Perm. Scaling", "Two-point scaling active.")
            scaling = TwoPointKrScale()
        else
            Jutul.jutul_message("Rel. Perm. Scaling", "Three-point scaling active.")
            scaling = ThreePointKrScale()
        end
    else
        scaling = NoKrScale()
    end

    hysteresis_w = hysteresis_ow = hysteresis_og = hysteresis_g = NoHysteresis()
    if haskey(props, "EHYSTR") && !haskey(runspec, "NOHYST")
        ehystr = props["EHYSTR"]
        pc_curve, hyst_type, kr_curve, killough_tol, hyst_krpc_active, hyst_flag, _, wetting_og, = props["EHYSTR"]
        if hyst_krpc_active == "PC" || hyst_krpc_active == "BOTH"
            jutul_message("EHYSTR", "Capillary pressure hysteresis is not supported and will be ignored.", color = :yellow)
        end
        if hyst_krpc_active != "PC"
            killough = KilloughHysteresis(tol = killough_tol, s_min = ehystr[12])
            if wetting_og == "DEFAULT"
                oil_is_wetting_for_og = true
            else
                oil_is_wetting_for_og = wetting_og == "OIL"
            end
            if hyst_type in (5, 6, 7)
                # Special case, oil wet models
                if hyst_type == 5
                    hysteresis_g = CarlsonHysteresis()
                    hysteresis_w = CarlsonHysteresis()
                elseif hyst_type == 6
                    hysteresis_g = killough
                    hysteresis_w = killough
                else
                    @assert hyst_type == 7
                    hysteresis_g = killough
                    hysteresis_w = killough
                    jutul_message("EHYSTR", "Option 7 for positional argument 2: This option may not be correctly implemented.", color = :yellow)
                end
            else
                if hyst_type == 0
                    # Carlson for non-wetting, drainage for wetting
                    nw_hyst = CarlsonHysteresis()
                    w_hyst = NoHysteresis()
                elseif hyst_type == 1
                    # Carlson for non-wetting, imbibition for wetting
                    nw_hyst = CarlsonHysteresis()
                    w_hyst = ImbibitionOnlyHysteresis()
                elseif hyst_type == 2
                    nw_hyst = killough
                    w_hyst = NoHysteresis()
                elseif hyst_type == 3
                    nw_hyst = killough
                    w_hyst = ImbibitionOnlyHysteresis()
                elseif hyst_type == 4
                    # TODO: Killough for wetting may require some additional modifications.
                    jutul_message("EHYSTR", "Option 4 for positional argument 2: Wetting-phase Killough hysteresis is not fully featured and uses same format as non-wetting.", color = :yellow)
                    nw_hyst = killough
                    w_hyst = killough
                elseif hyst_type == 8
                    nw_hyst = JargonHysteresis()
                    w_hyst = NoHysteresis()
                elseif hyst_type == 9
                    nw_hyst = JargonHysteresis()
                    w_hyst = ImbibitionOnlyHysteresis()
                elseif hyst_type == -1
                    nw_hyst = ImbibitionOnlyHysteresis()
                    w_hyst = ImbibitionOnlyHysteresis()
                else
                    error("Hysteresis type $hyst_type (argument 2 to EHYSTR) is not supported.")
                end
                if oil_is_wetting_for_og
                    hysteresis_og = w_hyst
                    hysteresis_g = nw_hyst
                else
                    hysteresis_og = nw_hyst
                    hysteresis_g = w_hyst
                end
                hysteresis_w = w_hyst
                hysteresis_ow = nw_hyst
            end
        end
    end
    tables_krw = []
    tables_krow = []
    tables_krog = []
    tables_krg = []

    function get_swcon(x, reg)
        if length(x) == 0
            out = 0.0
        else
            out = x[reg].connate
        end
        return out
    end
    if haskey(props, "SWOF") || haskey(props, "SGOF")
        if haskey(props, "SWOF")
            for swof in props["SWOF"]
                krw, krow = table_to_relperm(swof, first_label = :w, second_label = :ow)
                push!(tables_krw, krw)
                push!(tables_krow, krow)
            end
        end
        if haskey(props, "SLGOF")
            for (reg, slgof) in enumerate(props["SLGOF"])
                swcon = get_swcon(tables_krw, reg)
                sgof = copy(slgof)
                sgof[:, 1] = 1.0 .- sgof[:, 1]
                sgof = sgof[end:-1:1, :]
                krg, krog = table_to_relperm(sgof, swcon = swcon, first_label = :g, second_label = :og)
                push!(tables_krg, krg)
                push!(tables_krog, krog)
            end
        end
        if haskey(props, "SGOF")
            for (reg, sgof) in enumerate(props["SGOF"])
                swcon = get_swcon(tables_krw, reg)
                krg, krog = table_to_relperm(sgof, swcon = swcon, first_label = :g, second_label = :og)
                push!(tables_krg, krg)
                push!(tables_krog, krog)
            end
        end
    else
        if haskey(props, "SWFN")
            for swfn in props["SWFN"]
                krw = PhaseRelativePermeability(swfn[:, 1], swfn[:, 2], label = :w)
                push!(tables_krw, krw)
            end
        end
        if haskey(props, "SOF3")
            @assert !haskey(props, "SOF2") "SOF2 and SOF3 simultaneously is not supported."
            for sof3 in props["SOF3"]
                # Oil pairs
                so = sof3[:, 1]
                krow_t = sof3[:, 2]
                krog_t = sof3[:, 3]
                krow = PhaseRelativePermeability(so, krow_t, label = :ow)
                krog = PhaseRelativePermeability(so, krog_t, label = :og)

                push!(tables_krow, krow)
                push!(tables_krog, krog)
            end
        end
        if haskey(props, "SOF2")
            for sof2 in props["SOF2"]
                # Oil pairs
                so = sof2[:, 1]
                kro_t = sof2[:, 2]
                krow = PhaseRelativePermeability(so, kro_t, label = :ow)
                krog = PhaseRelativePermeability(so, kro_t, label = :og)

                push!(tables_krow, krow)
                push!(tables_krog, krog)
            end
        end
        if haskey(props, "SGFN")
            for sgfn in props["SGFN"]
                # Gas
                krg = PhaseRelativePermeability(sgfn[:, 1], sgfn[:, 2], label = :g)
                push!(tables_krg, krg)
            end
        end
        if haskey(props, "GSF")
            # SG, KRG, PCWG
            for gsf in props["GSF"]
                # Gas
                sg = gsf[:, 1]
                krg_t = gsf[:, 2]
                krg = PhaseRelativePermeability(sg, krg_t, label = :g)
                push!(tables_krg, krg)
            end
        end
        if haskey(props, "WSF")
            # SW, KRW
            for wsf in props["WSF"]
                # Gas
                sw = wsf[:, 1]
                krw_t = wsf[:, 2]
                krw = PhaseRelativePermeability(sw, krw_t, label = :w)
                push!(tables_krw, krw)
            end
        end
    end
    function convert_to_tuple_or_nothing(x, keep)
        if !keep || length(x) == 0
            out = nothing
        else
            out = tuple(x...)
        end
    end
    function check(phase, table, phasename, krname)
        if phase && isnothing(table)
            @warn "$phase was enabled but relperm $krname was not defined through any keyword."
        end
    end
    check(water, tables_krw, "gas", "KRW")
    check(gas && oil, tables_krog, "Phases gas and oil", "KROG")
    check(water && oil, tables_krow, "Phases water and oil", "KROW")
    check(gas, tables_krg, "Phase gas", "KRG")

    tables_krw = convert_to_tuple_or_nothing(tables_krw, water)
    tables_krow = convert_to_tuple_or_nothing(tables_krow, water && oil)
    tables_krog = convert_to_tuple_or_nothing(tables_krog, gas && oil)
    tables_krg = convert_to_tuple_or_nothing(tables_krg, gas)

    return ReservoirRelativePermeabilities(;
        w = tables_krw,
        ow = tables_krow,
        og = tables_krog,
        g = tables_krg,
        regions = satnum,
        scaling = scaling,
        hysteresis_w = hysteresis_w,
        hysteresis_ow = hysteresis_ow,
        hysteresis_og = hysteresis_og,
        hysteresis_g = hysteresis_g
    )
end

function flat_region_expand(x::AbstractMatrix, n = nothing)
    # Utility to handle mismatch between MRST and Jutul parsers in simple PVT
    # table format.
    if !isnothing(n)
        @assert size(x, 2) == n
    end
    x = map(i -> x[i, :], axes(x, 1))
    return x
end

function flat_region_expand(x::Vector{Float64}, n = nothing)
    return [x]
end


function flat_region_expand(x::Vector, n = nothing)
    return x
end

function deck_pc(props; oil, water, gas, satnum = nothing, is_co2 = false)
    function get_pc(T, pc_ix; reverse = false, sgn = 1.0)
        found = false
        PC = []
        for tab in T
            s = vec(tab[:, 1])
            pc = vec(tab[:, pc_ix])
            found = found || any(x -> x != 0, pc)
            if reverse
                @. s = 1.0 - s
                ix = length(s):-1:1
                pc = -pc[ix]
                s = s[ix]
            end
            @. pc = sgn*pc
            s, pc = saturation_table_handle_defaults(s, pc)
            if length(T) == 1
                constant_dx = missing
            else
                constant_dx = false
            end
            interp_phase_pair = get_1d_interpolator(s, pc, constant_dx = constant_dx)
            push!(PC, interp_phase_pair)
        end
        out = Tuple(PC)
        return (out, found)
    end
    pc_impl = Vector{Any}()
    if water && oil
        if haskey(props, "SWOF")
            interp_ow, found_pcow = get_pc(props["SWOF"], 4, sgn = -1)
        else
            interp_ow, found_pcow = get_pc(props["SWFN"], 3, sgn = -1)
        end
        push!(pc_impl, interp_ow)
    else
        found_pcow = false
    end
    if oil && gas
        if haskey(props, "SGOF")
            interp_og, found_pcog = get_pc(props["SGOF"], 4)
        elseif haskey(props, "SLGOF")
            interp_og, found_pcog = get_pc(props["SLGOF"], 4, sgn = -1)
        else
            interp_og, found_pcog = get_pc(props["SGFN"], 3)
        end
        push!(pc_impl, interp_og)
    else
        found_pcog = false
    end
    if water && gas && !oil
        if haskey(props, "WSF") && false
            interp_wg, found_pcwg = get_pc(props["WSF"], 3, sgn = -1)
            if found_pcwg
                jutul_message("WSF", "WSF capillary pressure is not well tested.", color = :yellow)
            end
            push!(pc_impl, interp_wg)
        else
            found_pcwg = false
        end
    else
        found_pcwg = false
    end
    found = found_pcow || found_pcog
    if found
        return SimpleCapillaryPressure(tuple(pc_impl...), regions = satnum)
    else
        return nothing
    end
end

function model_from_mat_deck(G, data_domain, mrst_data, res_context)
    ## Set up reservoir part
    deck = mrst_data["deck"]
    rock = mrst_data["rock"]
    if haskey(rock, "regions")
        if haskey(rock["regions"], "saturation")
            raw_satnum = rock["regions"]["saturation"]
        elseif haskey(rock["regions"], "imbibition")
            raw_satnum = ones(Int64, number_of_cells(G))
        else
            raw_satnum = nothing
        end
        if isnothing(raw_satnum)
            satnum = nothing
        else
            satnum = Int64.(vec(raw_satnum))
        end
    else
        satnum = nothing
    end
    props = deck["PROPS"]
    runspec = deck["RUNSPEC"]

    has(name) = haskey(runspec, name) && runspec[name]
    has_wat = has("WATER")
    has_oil = has("OIL")
    has_gas = has("GAS")
    has_disgas = has("DISGAS")
    has_vapoil = has("VAPOIL")

    is_immiscible = !has_disgas && !has_vapoil
    is_compositional = haskey(mrst_data, "mixture")

    phases = []
    rhoS = Vector{Float64}()
    if haskey(props, "DENSITY")
        deck_density = props["DENSITY"]
        if size(deck_density, 1) > 1
            @warn "Multiple PVT regions found. Picking first one." deck_density
            deck_density = deck_density[1, :]
        end
        deck_density = vec(deck_density)
        rhoOS = deck_density[1]
        rhoWS = deck_density[2]
        rhoGS = deck_density[3]
    else
        @assert is_compositional
        rhoOS = rhoWS = rhoGS = 1.0
        has_oil = true
        has_gas = true
    end
    pvt = []
    if is_compositional
        if has_wat
            push!(rhoS, rhoWS)
        end
        @assert has_oil
        @assert has_gas
        push!(rhoS, rhoOS)
        push!(rhoS, rhoGS)
        nph = length(rhoS)
        mixture = mrst_data["mixture"]
        comps = mixture["components"]
        names = copy(vec(mixture["names"]))
        components = map(x -> MolecularProperty(x["mw"], x["pc"], x["Tc"], x["Vc"], x["acf"]), comps)
        if haskey(mrst_data, "eos")
            eosm = mrst_data["eos"]
            nm = eosm["name"]
            if nm == "pr"
                eos_t = PengRobinson()
            elseif nm == "prcorr"
                eos_t = PengRobinsonCorrected()
            elseif nm == "srk"
                eos_t = SoaveRedlichKwong()
            elseif nm == "rk"
                eos_t = RedlichKwong()
            elseif nm == "zj"
                eos_t = ZudkevitchJoffe()
            else
                error("$nm not supported")
            end
            if isempty(eosm["bic"])
                bic = nothing
            else
                bic = copy(eosm["bic"])
            end
            if isempty(eosm["volume_shift"])
                vs = nothing
            else
                vs = copy(eosm["volume_shift"])
                vs = tuple(vs...)
            end
        else
            eos_t = PengRobinson()
            vs = nothing
            bic = nothing
        end
        mixture = MultiComponentMixture(components, names = names, A_ij = bic)
        eos = GenericCubicEOS(mixture, eos_t, volume_shift = vs)
        if nph == 2
            phases = (LiquidPhase(), VaporPhase())
        else
            phases = (AqueousPhase(), LiquidPhase(), VaporPhase())
        end
        sys = MultiPhaseCompositionalSystemLV(eos, phases, reference_densities = rhoS)
        model = SimulationModel(G, sys, context = res_context, data_domain = data_domain)
        # Insert pressure
        svar = model.secondary_variables
        T = copy(vec(mrst_data["state0"]["T"]))
        if length(unique(T)) == 1
            T = T[1]
        end
        set_deck_specialization!(model, runspec, props, satnum, has_oil, has_wat, has_gas)
        param = setup_parameters(model, Temperature = T)
    else
        if has_wat
            push!(pvt, deck_pvt_water(props))
            push!(phases, AqueousPhase())
            push!(rhoS, rhoWS)
        end

        if has_oil
            push!(pvt, deck_pvt_oil(props))
            push!(phases, LiquidPhase())
            push!(rhoS, rhoOS)
        end

        if has_gas
            push!(pvt, deck_pvt_gas(props))
            push!(phases, VaporPhase())
            push!(rhoS, rhoGS)
        end

        sys = pick_system_from_pvt(pvt, rhoS, phases, is_immiscible)
        model = SimulationModel(G, sys, context = res_context, data_domain = data_domain)
        # Modify secondary variables
        svar = model.secondary_variables
        # PVT
        pvt = tuple(pvt...)
        rho = DeckPhaseMassDensities(pvt)
        if !is_immiscible
            set_secondary_variables!(model, ShrinkageFactors = DeckShrinkageFactors(pvt))
        end
        mu = DeckPhaseViscosities(pvt)
        set_secondary_variables!(model, PhaseViscosities = mu, PhaseMassDensities = rho)
        set_deck_specialization!(model, runspec, props, satnum, has_oil, has_wat, has_gas)
        param = setup_parameters(model)
    end

    r = mrst_data["rock"]
    if haskey(r, "krscale")
        d = r["krscale"]["drainage"]
        for (k, v) in d
            name = Symbol("RelPermScaling$(uppercase(k))")
            @assert size(v, 2) == 4
            if haskey(param, name)
                vals = param[name]
                for c in axes(vals, 2)
                    for i = axes(vals, 1)
                        mrst_val = v[c, i]
                        if isfinite(mrst_val)
                            vals[i, c] = mrst_val
                        end
                    end
                end
            end
        end
    end
    return (model, param)
end

function set_deck_specialization!(model, runspec, props, satnum, oil, water, gas)
    sys = model.system
    svar = model.secondary_variables
    param = model.parameters
    is_co2 = haskey(runspec, "CO2STORE") || haskey(runspec, "JUTUL_CO2BRINE")
    if number_of_phases(sys) > 1
        set_deck_relperm!(svar, param, sys, runspec, props; oil = oil, water = water, gas = gas, satnum = satnum)
        set_deck_pc!(svar, param, sys, props; oil = oil, water = water, gas = gas, satnum = satnum, is_co2 = is_co2)
    end
    set_deck_pvmult!(svar, runspec, param, sys, props, model.data_domain)
end

function set_thermal_deck_specialization!(model, props, pvtnum, oil, water, gas)
    # SPECHEAT - fluid heat capacity F(T)
    # SPECROCK - rock heat capacity by volume F(T)
    if haskey(props, "SPECHEAT")
        ix = Int[]
        if water
            push!(ix, 2)
        end
        if oil
            push!(ix, 1)
        end
        if gas
            push!(ix, 3)
        end
        tab = []
        for (i, specheat) in enumerate(props["SPECHEAT"])
            T = specheat[:, 1] .+ 273.15
            C_f = specheat[:, ix .+ 1]

            N = length(ix)
            F = SVector{N, Float64}[]
            for i in axes(C_f, 1)
                push!(F, SVector{N, Float64}(C_f[i, :]...))
            end
            push!(tab, get_1d_interpolator(T, F))
        end
        tab = tuple(tab...)
        v = TemperatureDependentVariable(tab, regions = pvtnum)
        v = wrap_reservoir_variable(model.system, v, :thermal)
        set_secondary_variables!(model, ComponentHeatCapacity = v)
    end

    if !model_or_domain_is_well(model) && haskey(props, "SPECROCK")
        rock_density = first(model.data_domain[:rock_density])
        tab = []
        for (i, specrock) in enumerate(props["SPECROCK"])
            T = specrock[:, 1] .+ 273.15
            # (1 / volume) / (mass / volume) = 1 / mass... Input file does not
            # know rock density.
            C_r = specrock[:, 2] ./ rock_density
            push!(tab, get_1d_interpolator(T, C_r))
        end
        tab = tuple(tab...)
        v = TemperatureDependentVariable(tab, regions = pvtnum)
        v = wrap_reservoir_variable(model.system, v, :thermal)
        set_secondary_variables!(model, RockHeatCapacity = v)
    end
end

function set_deck_pc!(vars, param, sys, props; kwarg...)
    pc = deck_pc(props; kwarg...)
    if !isnothing(pc)
        vars[:CapillaryPressure] = wrap_reservoir_variable(sys, pc, :flow)
    end
end

function set_deck_relperm!(vars, param, sys, runspec, props; kwarg...)
    kr = deck_relperm(runspec, props; kwarg...)
    vars[:RelativePermeabilities] = kr
    add_relperm_parameters!(param, kr)
end

function set_deck_pvmult!(vars, runspec, param, sys, props, reservoir)
    # Rock compressibility (if present)
    if haskey(reservoir, :rocknum)
        regions = reservoir[:rocknum]
    elseif haskey(reservoir, :pvtnum)
        regions = reservoir[:pvtnum]
    else
        regions = nothing
    end
    ϕ = missing

    if haskey(props, "ROCKTAB")
        rt = vec(props["ROCKTAB"])
        tab = map(x -> get_1d_interpolator(x[:, 1], x[:, 2]), rt)
        tab_perm = map(x -> get_1d_interpolator(x[:, 1], x[:, 3]), rt)
        rockcomp = get(runspec, "ROCKCOMP", ["REVERS", 1, "NO", "CZ", 0.0])
        if rockcomp[1] == "REVERS"
            ϕ = TableCompressiblePoreVolume(tab, regions = regions)
            Kfn = ScalarPressureTable(tab_perm, regions = regions)
        else
            if rockcomp[1] != "IRREVERS"
                jutul_message("ROCKCOMP", "Only IRREVERS and REVERS are supported, using IRREVERS fallback for $(rockcomp[1])")
            end
            ϕ = HystereticTableCompressiblePoreVolume(tab, regions = regions)
            Kfn = HystereticScalarPressureTableMin(tab_perm, regions = regions)
            param[:MinPressure] = MinPressure()
        end
        vars[:PermeabilityMultiplier] = Kfn
    elseif haskey(props, "ROCK")
        rock = props["ROCK"]
        if rock isa Matrix
            # Do nothing
        else
            rock::Vector
            rock = collect(hcat(rock...)')
        end
        if size(rock, 1) > 1
            if isnothing(regions)
                @warn "Should have PVTNUM or ROCKNUM for multiple entries in ROCK. Taking the first entry." rock
                rock = rock[1:1, :]
            end
        end
        p_r = rock[:, 1]
        c_r = rock[:, 2]
        if any(x -> x > 0, c_r)
            ϕ = LinearlyCompressiblePoreVolume(
                    reference_pressure = p_r,
                    expansion = c_r,
                    regions = regions
            )
        end
    end
    if !ismissing(ϕ)
        static = param[:FluidVolume]
        delete!(param, :FluidVolume)
        param[:StaticFluidVolume] = static
        vars[:FluidVolume] = ϕ
    end
end

function wrap_reservoir_variable(sys::CompositeSystem, var::JutulVariables, type::Symbol = :flow)
    return Pair(type, var)
end

function wrap_reservoir_variable(sys, var, type::Symbol = :flow)
    return var
end

function unwrap_reservoir_variable(var)
    return var
end

function unwrap_reservoir_variable(var::Pair)
    return last(var)
end

function init_from_mat(mrst_data, model, param)
    state0 = mrst_data["state0"]
    p0 = state0["pressure"]
    if isa(p0, AbstractArray)
        p0 = vec(p0)
    else
        p0 = [p0]
    end
    min_p = minimum(p0)
    if min_p <= 1.1*DEFAULT_MINIMUM_PRESSURE
        @warn "Lowest initial pressure $min_p is close to lower default Jutul pressure limit of $DEFAULT_MINIMUM_PRESSURE. Case may not be feasible to simulate."
    end
    sys = model.system
    s = copy(state0["s"]')
    if haskey(model.secondary_variables, :CapillaryPressure)
        phases = get_phases(sys)
        if length(phases) == 2 && phases[2] isa VaporPhase && phases[1] isa LiquidPhase
            pc = zeros(1, length(p0))
            pc_impl = model[:CapillaryPressure]
            Jutul.update_secondary_variable!(pc, pc_impl, model, (Saturations = s, ), 1:length(p0))
            pc = vec(pc)
            @. p0 += pc
        end
    end
    init = Dict{Symbol, Any}(:Pressure => p0)
    if haskey(state0, "components")
        # Compositional
        z0 = copy(state0["components"]')
        ϵ_c = MultiComponentFlash.MINIMUM_COMPOSITION
        z0 = max.(z0, ϵ_c)
        norm_count = 0
        for (i, t) in enumerate(sum(z0, dims = 1))
            norm_count += t < 0.9
            for j in axes(z0, 1)
                z0[j, i] /= t
            end
        end
        if norm_count > 0
            @warn "$norm_count of $(size(z0, 2)) cells had composition with sum less than 0.9. All values have been normalized."
        end
        init[:OverallMoleFractions] = z0
        s = copy(state0["s"])
        if size(s, 2) == 3
            sw = vec(s[:, 1])
            # sw = min.(sw, 1 - MINIMUM_COMPOSITIONAL_SATURATION)
            sw = min.(sw, 1.0)
            init[:ImmiscibleSaturation] = sw
        else
            @assert size(s, 2) == 2
        end
    else
        # Blackoil or immiscible
        vapoil = has_vapoil(sys)
        disgas = has_disgas(sys)
        black_oil = vapoil || disgas
        if black_oil
            if has_disgas(sys)
                rs_var = model[:Rs]
            else
                rs_var = nothing
            end
            if has_vapoil(sys)
                rv_var = model[:Rv]
            else
                rv_var = nothing
            end
            # Blackoil
            if size(s, 1) > 2
                sw = vec(s[1, :])
                sw = min.(sw, 1 - MINIMUM_COMPOSITIONAL_SATURATION)
                init[:ImmiscibleSaturation] = sw
                so = vec(s[2, :])
                sg = vec(s[3, :])
            else
                so = vec(s[1, :])
                sg = vec(s[2, :])
                sw = zeros(size(so))
            end
            if blackoil_formulation(sys) == :zg
                init[:GasMassFraction] = copy(vec(state0["zg"]))
                @assert typeof(sys)<:BlackOilGasFractionSystem
            else
                @assert typeof(sys)<:BlackOilVariableSwitchingSystem
                F_rs = sys.rs_max
                F_rv = sys.rv_max
                nc = length(p0)
                if isnothing(F_rs)
                    rs = zeros(nc)
                    @assert sys isa VapoilBlackOilSystem
                    @assert model isa VapoilBlackOilModel
                else
                    rs = vec(state0["rs"])
                end
                if isnothing(F_rv)
                    rv = zeros(nc)
                    @assert sys isa DisgasBlackOilSystem
                    @assert model isa DisgasBlackOilModel
                else
                    rv = vec(state0["rv"])
                end
                bo = BlackOilX{Float64}[]
                nc = length(p0)
                sizehint!(bo, nc)
                for i in 1:nc
                    reg_rs = region(rs_var, i)
                    reg_rv = region(rv_var, i)
                    F_rs_i = table_by_region(F_rs, reg_rs)
                    F_rv_i = table_by_region(F_rv, reg_rv)
                    bo_i = blackoil_unknown_init(F_rs_i, F_rv_i, sw[i], so[i], sg[i], rs[i], rv[i], p0[i])
                    push!(bo, bo_i)
                end
                init[:BlackOilUnknown] = bo
            end
        else
            # Immiscible
            init[:Saturations] = s
        end
    end
    return init
end

"""
    setup_case_from_mrst("filename.mat"; kwarg...)

Set up a [`Jutul.JutulCase`](@ref) from a MRST-exported .mat file.
"""
function setup_case_from_mrst(casename;
        convert_grid = false,
        diffusion = nothing,
        use_mrst_transmissibility::Bool = true,
        kwarg...
    )
    data_domain, mrst_data = reservoir_domain_from_mrst(
        casename,
        extraout = true,
        convert_grid = convert_grid,
        diffusion = diffusion,
        use_mrst_transmissibility = use_mrst_transmissibility
    )
    return setup_case_from_mrst_data(data_domain, mrst_data;
        convert_grid = convert_grid,
        diffusion = diffusion,
        kwarg...
    )
end

"""
    setup_case_from_mrst_split(common_path, specific_path; kwarg...)

Set up a [`Jutul.JutulCase`](@ref) from a shared MRST common `.mat` file and a
realization-specific `.mat` file. The split input is assembled in memory.
"""
function setup_case_from_mrst_split(common_path::AbstractString, specific_path::AbstractString;
        convert_grid = false,
        diffusion = nothing,
        validate_split::Bool = true,
        use_mrst_transmissibility::Bool = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable",
        kwarg...
    )
    mrst_data = read_mrst_split_case(common_path, specific_path;
        validate = validate_split,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode
    )
    data_domain = reservoir_domain_from_mrst_data(mrst_data;
        extraout = false,
        convert_grid = convert_grid,
        diffusion = diffusion,
        use_mrst_transmissibility = use_mrst_transmissibility
    )
    return setup_case_from_mrst_data(data_domain, mrst_data;
        convert_grid = convert_grid,
        diffusion = diffusion,
        kwarg...
    )
end

function setup_case_from_mrst_data(data_domain, mrst_data;
        wells = :simple,
        backend = :csr,
        block_backend = true,
        split_wells = false,
        use_well_lengths = false,
        facility_grouping = missing,
        minbatch = 1000,
        steps = :full,
        nthreads = Threads.nthreads(),
        legacy_output = false,
        convert_grid = false,
        ds_max = 0.2,
        dz_max = 0.2,
        dp_max_abs = nothing,
        dp_max_rel = 0.2,
        p_min = DEFAULT_MINIMUM_PRESSURE,
        p_max = Inf,
        dr_max = Inf,
        diffusion = nothing,
        disable_hysteresis::Bool = false,
        hysteresis_s_min::Union{Nothing, Float64} = nothing,
        kwarg...
    )
    normalize_mrst_schedule_control!(mrst_data)
    if disable_hysteresis
        if !isnothing(hysteresis_s_min)
            @warn "Both DISABLE_HYSTERESIS=true and HYSTERESIS_S_MIN=$hysteresis_s_min were set. NOHYST disables hysteresis, so HYSTERESIS_S_MIN is ignored."
        end
        disable_mrst_hysteresis!(mrst_data)
    elseif !isnothing(hysteresis_s_min)
        override_mrst_hysteresis_s_min!(mrst_data, hysteresis_s_min)
    end
    G = discretized_domain_tpfv_flow(data_domain; kwarg...)
    if ismissing(facility_grouping)
        if split_wells
            facility_grouping = :perwell
        else
            facility_grouping = :onegroup
        end
    end
    # Set up initializers
    models = OrderedDict()
    initializer = Dict()
    forces = Dict()
    res_context, = Jutul.select_contexts(backend, block_backend = block_backend, minbatch = minbatch, nthreads = nthreads)
    model, param_res = model_from_mat(G, data_domain, mrst_data, res_context)
    init = init_from_mat(mrst_data, model, param_res)

    is_comp = model isa CompositionalModel
    rhoS = reference_densities(model.system)

    has_schedule = haskey(mrst_data, "schedule")
    if has_schedule
        @assert !haskey(mrst_data, "dt")
        @assert !haskey(mrst_data, "W")

        schedule = mrst_data["schedule"]

        dt = schedule["step"]["val"]
        first_ctrl = schedule["control"][1]
        first_well_set = vec(deepcopy(first_ctrl["W"]))
        first_well_set = set_wi_to_maximum!(first_well_set, schedule["control"])
    else
        dt = mrst_data["dt"]
        first_well_set = vec(mrst_data["W"])
    end
    if isa(dt, Real)
        dt = [dt]
    end
    timesteps = vec(copy(dt))
    res_context = model.context
    if wells == :ms || true
        w_context = DefaultContext(nthreads = 1)
    else
        w_context = res_context
    end

    initializer[:Reservoir] = init
    forces[:Reservoir] = nothing
    models[:Reservoir] = model
    well_symbols = map((x) -> Symbol(x["name"]), first_well_set)
    num_wells = length(well_symbols)
    parameters = Dict{Symbol, Any}()
    parameters[:Reservoir] = param_res
    controls = Dict()
    sys = model.system
    for i = 1:num_wells
        sym = well_symbols[i]
        wi, wdata, res_cells = get_well_from_mrst_data(mrst_data, sys, i, W_data = first_well_set,
                extraout = true, well_type = wells, context = w_context, use_lengths = use_well_lengths)

        param_w = setup_parameters(wi)

        if typeof(wi.system) == typeof(model.system)
            set_secondary_variables!(wi, PhaseMassDensities = model.secondary_variables[:PhaseMassDensities])
            if haskey(wi.secondary_variables, :ShrinkageFactors)
                set_secondary_variables!(wi, ShrinkageFactors = model.secondary_variables[:ShrinkageFactors])
            end
            if haskey(model.secondary_variables, :PhaseViscosities)
                set_secondary_variables!(wi, PhaseViscosities = model.secondary_variables[:PhaseViscosities])
            else
                set_parameters(wi, PhaseViscosities = model.parameters[:PhaseViscosities])
            end
            if haskey(param_w, :Temperature)
                param_w[:Temperature] = param_res[:Temperature][res_cells]
            end
        end
        models[sym] = wi
        ctrl = mrst_well_ctrl(model, wdata, is_comp, rhoS)
        if isa(ctrl, InjectorControl)
            factor = 1.01
            if is_comp
                mw = MultiComponentFlash.molar_masses(model.system.equation_of_state)
                ci = copy(vec(wdata["components"]))
                ci = map((x, mwi) -> max(mwi*x, 1e-10), ci, mw)
                ci = normalize(ci, 1)
            else
                ci = vec(wdata["compi"])
            end
        elseif isa(ctrl, ProducerControl)
            factor = 0.99
            ci = nothing
        else
            # Shut.
            ci = nothing
            factor = 1.0
        end
        @debug "$sym: Well $i/$num_wells" typeof(ctrl) ci

        pw = vec(init[:Pressure][res_cells])
        w0 = Dict{Symbol, Any}(:Pressure => pw, :TotalMassFlux => 1e-12)
        if is_comp
            if isnothing(ci)
                cw_0 = init[:OverallMoleFractions][:, res_cells]
                cw_0::Matrix{Float64}
            else
                cw_0 = ci
            end
            w0[:OverallMoleFractions] = cw_0
        elseif haskey(init, :Saturations)
            w0[:Saturations] = init[:Saturations][:, res_cells]
        end
        for sk in [:GasMassFraction, :BlackOilUnknown, :ImmiscibleSaturation]
            if haskey(init, sk)
                w0[sk] = vec(init[sk][res_cells])
            end
        end
        parameters[sym] = param_w
        controls[sym] = ctrl
        forces[sym] = nothing
        initializer[sym] = w0
    end
    #
    mode = PredictionMode()
    F0 = Dict(:TotalSurfaceMassRate => 0.0)

    facility_symbols = []
    facility_owned_wells = []
    function add_facility!(wsymbols, sym)
        g = WellGroup(wsymbols)
        WG = SimulationModel(g, mode)
        ctrls = facility_subset(wsymbols, controls)
        facility_forces = setup_forces(WG, control = ctrls)
        # Specifics
        @assert !haskey(models, sym)
        models[sym] = WG
        forces[sym] = facility_forces
        # Generics
        initializer[sym] = F0
        parameters[sym] = setup_parameters(WG)
        # Store the subs
        push!(facility_symbols, sym)
        push!(facility_owned_wells, wsymbols)
    end

    if num_wells > 0
        if facility_grouping == :onegroup
            add_facility!(well_symbols, :Facility)
        elseif facility_grouping == :perwell
            for sym in well_symbols
                gsym = Symbol(string(sym)*string(:_ctrl))
                add_facility!([sym], gsym)
            end
        elseif isnothing(facility_grouping)
            # Do nothing
        else
            error("Unknown grouping $facility_grouping")
        end
        vectorize(d::T) where T<:Number = [d]
        vectorize(d) = vec(d)

        if has_schedule
            control_ix = Int64.(vectorize(schedule["step"]["control"]))
            nctrl = maximum(control_ix)
            # We may have multiple controls and need to do further work.
            current_control = deepcopy(controls)
            all_controls = Vector{typeof(forces)}()
            for i = 1:nctrl
                ctrl_i = schedule["control"][i]
                new_force = deepcopy(forces)
                if haskey(ctrl_i, "bc")
                    bc = ctrl_i["bc"]
                    if length(bc) > 0
                        @assert all(isequal("pressure"), bc["type"]) "Only pressure bc is supported."
                        bc_converted = Vector{FlowBoundaryCondition}()
                        for ix in eachindex(bc["face"])
                            face = Int(bc["face"][ix])
                            sat = bc["sat"][ix, :]
                            val = bc["value"][ix]

                            bc_cell = Int(sum(mrst_data["G"]["faces"]["neighbors"][face, :]))
                            @assert haskey(mrst_data, "T_all")
                            T_bf = mrst_data["T_all"][face]
                            push!(bc_converted, FlowBoundaryCondition(bc_cell, val, fractional_flow = sat, trans_flow = T_bf))
                        end
                        new_force[:Reservoir] = setup_forces(model, bc = bc_converted)
                    end
                end
                # Create controls for this set of wells
                local_mrst_wells = vec(ctrl_i["W"])
                limits = Dict{Symbol, Any}()
                found_limits = false
                for (wno, wsym) in enumerate(well_symbols)
                    wdata = local_mrst_wells[wno]
                    wmodel = models[wsym]
                    current_control[wsym] = mrst_well_ctrl(model, wdata, is_comp, rhoS)
                    cstatus = vectorize(wdata["cstatus"])
                    lims = wdata["lims"]
                    if !isempty(lims)
                        limits[wsym] = convert_to_immutable_storage(lims)
                        found_limits = true
                    end
                    Ω_w = models[wsym].domain
                    WI = physical_representation(Ω_w).perforations.WI
                    new_WI = vectorize(wdata["WI"])
                    if all(cstatus) && all(WI .== new_WI)
                        new_force[wsym] = nothing
                    else
                        # Set mask to new / static so that static*mask = new.
                        # In addition: Account for completion closures.
                        wi_mask = vec(new_WI./WI)
                        for ix in eachindex(wi_mask)
                            if (!cstatus[ix] || !isfinite(wi_mask[ix]))
                                wi_mask[ix] = 0
                            end
                        end
                        new_force[wsym] = setup_forces(wmodel, mask = PerforationMask(wi_mask))
                    end
                end
                # Now copy into the corresponding facilit(y/ies)
                if !found_limits
                    limits = Dict()
                end
                for (fsymbol, wsymbols) in zip(facility_symbols, facility_owned_wells)
                    ctrls = facility_subset(wsymbols, current_control)
                    WG = models[fsymbol]
                    limits_local = facility_subset(wsymbols, limits)
                    new_force[fsymbol] = setup_forces(WG, control = ctrls, limits = limits_local)
                end
                push!(all_controls, new_force)
            end
            if nctrl == 1
                # No need to make a complicated vector since one control is
                # valid for all steps.
                forces = only(all_controls)
            else
                forces = all_controls[control_ix]
            end
        end
    end
    if steps != :full
        if steps isa Int64
            steps = [steps]
        end
        steps::Union{Vector{Int64}, UnitRange}
        timesteps = timesteps[steps]
        if forces isa AbstractVector
            forces = forces[steps]
        end
    end
    if legacy_output
        return (models, parameters, initializer, timesteps, forces, mrst_data)
    else
        model = reservoir_multimodel(models)
        # Replace various variables - if they are available
        replace_variables!(model, OverallMoleFractions = OverallMoleFractions(dz_max = dz_max), throw = false)
        replace_variables!(model, Saturations = Saturations(ds_max = ds_max), throw = false)
        replace_variables!(model, ImmiscibleSaturation = ImmiscibleSaturation(ds_max = ds_max), throw = false)
        replace_variables!(model, BlackOilUnknown = BlackOilUnknown(ds_max = ds_max, dr_max = dr_max), throw = false)

        p_def = Pressure(max_abs = dp_max_abs, max_rel = dp_max_rel, minimum = p_min, maximum = p_max)
        replace_variables!(model, Pressure = p_def, throw = false)

        state0 = setup_state(model, initializer)
        parameters = setup_parameters(model, parameters)

        case = JutulCase(model, timesteps, forces, state0 = state0, parameters = parameters)
        return (case, mrst_data)
    end
end

function set_wi_to_maximum!(wells, controls)
    for (i, well) in enumerate(wells)
        WI = well["WI"]
        for ctrl in controls
            new_WI = ctrl["W"][i]["WI"]
            if WI isa AbstractArray
                @. WI = max(WI, new_WI)
            else
                WI = max(WI, new_WI)
            end
        end
        well["WI"] = WI
    end
    return wells
end

function facility_subset(well_symbols, controls)
    ctrls = Dict()
    for k in keys(controls)
        if any(well_symbols .== k)
            ctrls[k] = controls[k]
        end
    end
    return ctrls
end

function mrst_well_ctrl(model, wdata, is_comp, rhoS)
    t_mrst = wdata["val"]
    is_injector = wdata["sign"] > 0
    is_shut = wdata["status"] < 1
    comp_i = vec(wdata["compi"])
    phases = get_phases(model.system)
    nph = length(phases)
    name = wdata["name"]

    if is_shut
        @debug "$name: Shut well (requested)"
        ctrl = DisabledControl()
    else
        wt = lowercase(wdata["type"])
        is_rate_ctrl = true
        if wt == "bhp"
            target = BottomHolePressureTarget(t_mrst)
            # Not rate controlled
            is_rate_ctrl = false
        elseif wt == "rate"
            target = TotalRateTarget(t_mrst)
        elseif wt == "wrat"
            target = SurfaceWaterRateTarget(t_mrst)
        elseif wt == "orat"
            target = SurfaceOilRateTarget(t_mrst)
        elseif wt == "grat"
            target = SurfaceGasRateTarget(t_mrst)
        elseif wt == "lrat"
            target = SurfaceLiquidRateTarget(t_mrst)
        elseif wt == "resv_history"
            target = HistoricalReservoirVoidageTarget(t_mrst, tuple(comp_i...))
        else
            error("$wt target is not supported.")
        end

        if is_rate_ctrl && t_mrst == 0.0
            @debug "$name: Shut well (zero rate)"
            ctrl = DisabledControl()
        elseif is_injector
            if is_comp
                ci = copy(vec(wdata["components"]))
                mw = MultiComponentFlash.molar_masses(model.system.equation_of_state)
                ci = map((x, mwi) -> max(mwi*x, 1e-10), ci, mw)
                ct = copy(ci)
                normalize!(ct, 1)
                if nph == 3
                    # Should go at end - need better logic if this isn't either one or zero
                    c_water = comp_i[1]
                    hc_weight = max(1.0 - c_water, 1e-3)
                    ct = ct.*hc_weight
                    push!(ct, c_water)
                end
                normalize!(ct, 1)
            else
                ct = comp_i
            end
            if haskey(wdata, "rhoS") && length(wdata["rhoS"]) > 0
                rhoSw = tuple(wdata["rhoS"][1:nph]...)
            else
                rhoSw = rhoS
            end
            rhoS_inj = sum(comp_i.*rhoSw)
            ctrl = InjectorControl(target, ct, density = rhoS_inj, phases = collect(enumerate(comp_i)))
        else
            ctrl = ProducerControl(target)
        end
    end
    return ctrl
end

function add_co2_concentration_to_state!(state, rmodel; label::AbstractString = "state")
    res = reservoir_state_for_vtu(state)

    if !haskey(res, :Saturations)
        @warn "Skipping CO2 concentration for $label: missing :Saturations"
        return false
    end

    sys = rmodel.system
    disgas = has_disgas(sys)
    nc = length(res[:Saturations][1, :])

    if !disgas
        res[:Concentration] = zeros(eltype(res[:Saturations]), nc)
        return true
    end

    req = (:PhaseMassDensities, :ShrinkageFactors, :Rs)
    missing = Symbol[]
    for k in req
        haskey(res, k) || push!(missing, k)
    end
    if !isempty(missing)
        @warn "Skipping CO2 concentration for $label: missing variables." missing
        return false
    end

    sw        = res[:Saturations][1, :]
    rs        = res[:Rs]
    bo        = res[:ShrinkageFactors][1, :]
    bg        = res[:ShrinkageFactors][2, :]
    rho_g_res = res[:PhaseMassDensities][2, :]

    c = rs .* bo .* rho_g_res ./ bg
    c = ifelse.(sw .> 0.0, c, 0.0)
    res[:Concentration] = c
    return true
end

function final_saved_state(output_path, states)
    if !isempty(states)
        return states[end]
    end
    if isnothing(output_path) || !isdir(output_path)
        return nothing
    end
    indices = Jutul.valid_restart_indices(output_path)
    isempty(indices) && return nothing
    state, _ = Jutul.read_restart(output_path, last(indices); read_state = true, read_report = false)
    if length(keys(state)) == 0
        return nothing
    end
    return state
end

function completed_report_steps(states, reports, output_path = nothing)
    if !isnothing(output_path) && isdir(output_path)
        indices = Jutul.valid_restart_indices(output_path)
        return isempty(indices) ? 0 : maximum(indices)
    elseif !isempty(states)
        return length(states)
    elseif isempty(reports)
        return 0
    else
        last_report = findlast(report -> !ismissing(report), reports)
        return isnothing(last_report) ? 0 : last_report
    end
end

"""
    export_mrst_case_vtu_from_output(file_name, output_path; <keyword arguments>)

Stream VTU export from saved Jutul `output_path` files without loading all
states into memory at once. This is intended for post-processing after a
simulation has completed.
"""
function export_mrst_case_vtu_from_output(fn, output_path;
        common_mrst_path = nothing,
        specific_mrst_path = nothing,
        validate_split::Bool = true,
        backend = :csr,
        nthreads = Threads.nthreads(),
        minbatch = 1000,
        split_wells = false,
        report_co2_concentration::Bool = false,
        write_initial_step0::Bool = false,
        write_state_vtu::Bool = true,
        vtu_outdir::AbstractString = "",
        vtu_prefix::AbstractString = "case",
        vtu_vars = [:Pressure, :Saturations],
        ds_max = 0.2,
        dz_max = 0.2,
        dp_max_abs = nothing,
        dp_max_rel = 0.2,
        p_min = DEFAULT_MINIMUM_PRESSURE,
        p_max = Inf,
        verbose = true,
        steps = :full,
        general_ad = false,
        wells = :simple,
        linear_solver = :bicgstab,
        diffusion = nothing,
        disable_hysteresis::Bool = false,
        hysteresis_s_min::Union{Nothing, Float64} = nothing,
        use_mrst_transmissibility::Bool = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable",
    )
    is_split_input = !isnothing(common_mrst_path) || !isnothing(specific_mrst_path)
    if is_split_input
        if isnothing(common_mrst_path) || isnothing(specific_mrst_path)
            error("Both common_mrst_path and specific_mrst_path must be provided for split MRST input.")
        end
        common_mrst_path = get_mrst_input_path(String(common_mrst_path))
        specific_mrst_path = get_mrst_input_path(String(specific_mrst_path))
        fn = specific_mrst_path
    else
        ext = lowercase(last(splitext(fn)))
        if ext == ".data"
            error("Streaming VTU export from saved output is currently only supported for MRST .mat cases.")
        end
        fn = get_mrst_input_path(fn)
    end

    output_path = realpath(output_path)

    if split_wells
        fg = :perwell
    else
        fg = :onegroup
    end
    block_backend = linear_solver != :direct && linear_solver != :lu

    setup_kwargs = (
        block_backend = block_backend,
        steps = steps,
        backend = backend,
        nthreads = nthreads,
        split_wells = split_wells,
        facility_grouping = fg,
        general_ad = general_ad,
        minbatch = minbatch,
        wells = wells,
        dp_max_abs = dp_max_abs,
        dp_max_rel = dp_max_rel,
        p_min = p_min,
        p_max = p_max,
        dz_max = dz_max,
        ds_max = ds_max,
        diffusion = diffusion,
        disable_hysteresis = disable_hysteresis,
        hysteresis_s_min = hysteresis_s_min,
        use_mrst_transmissibility = use_mrst_transmissibility,
        fault_saturation_domain_mode = fault_saturation_domain_mode,
        fault_pc_entry_treatment = fault_pc_entry_treatment,
        fault_pc_entry_sg_max = fault_pc_entry_sg_max,
        explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode
    )
    case, mrst_data = if is_split_input
        setup_case_from_mrst_split(common_mrst_path, specific_mrst_path;
            validate_split = validate_split,
            setup_kwargs...
        )
    else
        setup_case_from_mrst(fn; setup_kwargs...)
    end

    model = case.model
    rmodel = model.models[:Reservoir]
    outdir_local = isempty(vtu_outdir) ? joinpath(pwd(), "paraview_states") : vtu_outdir

    if write_initial_step0
        vtu_vars0 = union(vtu_vars, [:Porosity, :Permeability])
        export_initial_step0_vtu(fn, mrst_data;
            outdir = outdir_local,
            prefix = "$(vtu_prefix)_incon",
            vtu_vars = vtu_vars0,
            split_matrices = true,
            write_regions = true
        )
    end

    if !write_state_vtu
        return (String[], Float64[], nothing)
    end

    has_regions = haskey(mrst_data, "rock") && haskey(mrst_data["rock"], "regions")
    has_p0 = haskey(mrst_data, "state0") && haskey(mrst_data["state0"], "pressure")

    state_transform! = nothing
    if report_co2_concentration && (:Concentration in vtu_vars)
        state_transform! = (state, step_no) -> add_co2_concentration_to_state!(state, rmodel; label = "saved state $step_no")
    end

    return report_times_vtu_export_from_output(mrst_data["G"], output_path;
        outdir = outdir_local,
        prefix = vtu_prefix,
        vars = vtu_vars,
        split_matrices = true,
        write_pvd = true,
        verbose = verbose,
        write_regions = has_regions,
        reservoir_regions = has_regions ? mrst_data["rock"]["regions"] : nothing,
        write_dp = has_p0,
        state0_pressure = has_p0 ? mrst_data["state0"]["pressure"] : nothing,
        dp_name = "dP",
        state_transform! = state_transform!
    )
end

"""
    ws, states = simulate_mrst_case(file_name)
    simulate_mrst_case(file_name; <keyword arguments>)

Simulate a MRST case from `file_name` as exported by `writeJutulInput` in MRST.

# Arguments
- `file_name::String`: The path to a `.mat` or `.data` file that is to be
  simulated.

# Keyword arguments
- `extra_outputs::Vector{Symbol} = [:Saturations]`: Additional variables to
  output from the simulation.
- `write_output::Bool = true`: Write output (in the default JLD2 format)
- `output_path = nothing`: Directory for output files. Files will be written
  under this directory. Defaults to the folder of `file_name`.
- `write_mrst = true`: Write MRST compatible output after completed simulation
  that can be read by `readJutulOutput` in MRST.
- `backend=:csc`: choice of backend for linear systems. `:csc` for default Julia
  sparse, `:csr` for experimental parallel CSR.
- `verbose=true`: print some extra information specific to this routine upon
  calling
- `nthreads=Threads.nthreads()`: number of threads to use
- `linear_solver=:bicgstab`: name of Krylov.jl solver to use, or :direct (for
  small cases only)
- `max_nonlinear_iterations = nothing`: Optional override for the simulator
  nonlinear iteration cap
- `max_timestep_cuts = nothing`: Optional override for the simulator timestep
  cut cap
- `info_level = nothing`: Optional override for Jutul verbosity. 0 for minimal
  printing, -1 for no printing, 1-5 for various levels of verbosity
- `report_level = nothing`: Optional override for simulator reporting verbosity
- `diffusion = nothing`: Optional diffusion override for MRST `.mat` cases.
  Scalars apply uniformly, vectors can be cellwise, and tuples/matrices can be
  used for per-phase values.
- `disable_hysteresis::Bool = false`: If `true`, set `RUNSPEC["NOHYST"]` on
  MRST `.mat` input after reading it so EHYSTR hysteresis tables are ignored
  without modifying the original input file.
- `load_all_states_after_sim::Bool = true`: If `false`, keep reports in memory
  but avoid reading all saved states back from JLD2 at the end of the
  simulation. Recommended for large simulation-only HPC jobs that use the
  separate VTU postprocessing workflow. In this mode, the function returns a
  lightweight named tuple with the raw `SimResult`, reports, output path, and
  setup metadata instead of building a `ReservoirSimResult`.
- `fault_saturation_domain_mode = "input"`: For split MRST GoM inputs, set to
  `"predict_sample"` to relabel each independent PREDICT fault sample into its
  own saturation domain while cloning the original Pc/Kr tables.
- `fault_pc_entry_treatment = "none"`: For explicit split fault SGOF tables,
  set to `"plateau"` to replace `Pc(Sg=0)=0` with the first positive entry
  pressure when the second saturation point is below `fault_pc_entry_sg_max`.
- `explicit_fault_hysteresis_mode = "disable"`: For explicit split fault
  SGOF tables, keep the conservative default of disabling hysteresis. Set to
  `"reservoir"` to keep reservoir hysteresis active while duplicating each
  fault drainage table as its own imbibition table.

Additional input arguments are passed onto, [`setup_case_from_mrst`](@ref),
[`setup_reservoir_simulator`](@ref) and [`simulator_config`](@ref) if
applicable.
"""
function simulate_mrst_case(fn;
        common_mrst_path = nothing,
        specific_mrst_path = nothing,
        validate_split::Bool = true,
        extra_outputs::Vector{Symbol} = [:Saturations],
        output_path = nothing,
        backend = :csr,
        mode = :default,
        nthreads = Threads.nthreads(),
        minbatch = 1000,
        split_wells = false,
        report_gas_masses::Bool = false,
        report_co2_concentration::Bool = false,
        write_initial_step0::Bool = false,
        write_vtu::Bool = false, 
        vtu_outdir::AbstractString = "",
        vtu_prefix::AbstractString = "case",
        vtu_vars = [:Pressure, :Saturations],
        write_mrst = false,
        write_output = true,
        ds_max = 0.2,
        dr_max = Inf,
        dz_max = 0.2,
        dp_max_abs = nothing,
        dp_max_rel = 0.2,
        p_min = DEFAULT_MINIMUM_PRESSURE,
        p_max = Inf,
        verbose = true,
        do_sim = true,
        steps = :full,
        general_ad = false,
        legacy_output = false,
        restart = false,
        stop_after_report_step::Union{Nothing, Int} = nothing,
        wells = :simple,
        plot = false,
        linear_solver = :bicgstab,
        max_nonlinear_iterations::Union{Nothing, Int} = nothing,
        max_timestep_cuts::Union{Nothing, Int} = nothing,
        info_level::Union{Nothing, Int} = nothing,
        report_level::Union{Nothing, Int} = nothing,
        load_all_states_after_sim::Bool = true,
        load_all_reports_after_sim::Bool = true,
        in_memory_reports::Int = 10,
        nonlinear_relaxation::Bool = false,
        target_its::Real = 8,
        target_ds::Real = Inf,
        timestep_max_increase::Real = 10.0,
        diffusion = nothing,
        disable_hysteresis::Bool = false,
        hysteresis_s_min::Union{Nothing, Float64} = nothing,
        use_mrst_transmissibility::Bool = true,
        fault_saturation_domain_mode = "input",
        fault_pc_entry_treatment = "none",
        fault_pc_entry_sg_max::Real = 1.0e-4,
        explicit_fault_hysteresis_mode = "disable",
        kwarg...
    )
    is_split_input = !isnothing(common_mrst_path) || !isnothing(specific_mrst_path)
    if is_split_input
        if isnothing(common_mrst_path) || isnothing(specific_mrst_path)
            error("Both common_mrst_path and specific_mrst_path must be provided for split MRST input.")
        end
        common_mrst_path = get_mrst_input_path(String(common_mrst_path))
        specific_mrst_path = get_mrst_input_path(String(specific_mrst_path))
        fn = specific_mrst_path
        is_data = false
    else
        ext = lowercase(last(splitext(fn)))
        is_data = ext == ".data"
        if !is_data
            fn = get_mrst_input_path(fn)
        end
    end
    if split_wells
        fg = :perwell
    else
        fg = :onegroup
    end
    if mode != :default
        Jutul.jutul_message("Mode is $mode", "Adjusting default settings accordingly.", color = :green)
        backend = :csr
        use_blocks = true
        fg = :perwell
    end
    if verbose
        if is_split_input
            jutul_message("MRST model", "Reading split input common=$common_mrst_path specific=$specific_mrst_path.")
        else
            jutul_message("MRST model", "Reading input file $fn.")
        end
        @info "This is the first call to simulate_mrst_case. Compilation may take some time..." maxlog = 1
    end
    block_backend = linear_solver != :direct && linear_solver != :lu
    if is_data
        case, deck = setup_case_from_data_file(fn,
            block_backend = block_backend,
            include_data = true,
            backend = backend,
            nthreads = nthreads,
            split_wells = split_wells,
            general_ad = general_ad,
            minbatch = minbatch,
            dp_max_abs = dp_max_abs,
            dp_max_rel = dp_max_rel,
            p_min = p_min,
            p_max = p_max,
            dz_max = dz_max,
            ds_max = ds_max
        )
        # A bit of a hack
        mrst_data = deck
        if disable_hysteresis
            @warn "DISABLE_HYSTERESIS=true currently only rewrites MRST .mat deck data. For .data input, include NOHYST in the deck itself."
        end
        if !isnothing(hysteresis_s_min)
            @warn "HYSTERESIS_S_MIN=$hysteresis_s_min currently only rewrites MRST .mat deck data. For .data input, edit EHYSTR in the deck itself."
        end
    elseif is_split_input
        case, mrst_data = setup_case_from_mrst_split(common_mrst_path, specific_mrst_path;
            validate_split = validate_split,
            block_backend = block_backend,
            steps = steps,
            backend = backend,
            nthreads = nthreads,
            split_wells = split_wells,
            facility_grouping = fg,
            general_ad = general_ad,
            minbatch = minbatch,
            wells = wells,
            dp_max_abs = dp_max_abs,
            dp_max_rel = dp_max_rel,
            p_min = p_min,
            p_max = p_max,
            dz_max = dz_max,
            ds_max = ds_max,
            dr_max = dr_max,
            diffusion = diffusion,
            disable_hysteresis = disable_hysteresis,
            hysteresis_s_min = hysteresis_s_min,
            use_mrst_transmissibility = use_mrst_transmissibility,
            fault_saturation_domain_mode = fault_saturation_domain_mode,
            fault_pc_entry_treatment = fault_pc_entry_treatment,
            fault_pc_entry_sg_max = fault_pc_entry_sg_max,
            explicit_fault_hysteresis_mode = explicit_fault_hysteresis_mode
        )
        deck = mrst_data["deck"]
    else
        case, mrst_data = setup_case_from_mrst(fn,
            block_backend = block_backend,
            steps = steps,
            backend = backend,
            nthreads = nthreads,
            split_wells = split_wells,
            facility_grouping = fg,
            general_ad = general_ad,
            minbatch = minbatch,
            wells = wells,
            dp_max_abs = dp_max_abs,
            dp_max_rel = dp_max_rel,
            p_min = p_min,
            p_max = p_max,
            dz_max = dz_max,
            ds_max = ds_max,
            dr_max = dr_max,
            diffusion = diffusion,
            disable_hysteresis = disable_hysteresis,
            hysteresis_s_min = hysteresis_s_min,
            use_mrst_transmissibility = use_mrst_transmissibility
        )
        deck = mrst_data["deck"]
    end
    model = case.model
    forces = case.forces
    dt = case.dt
    if !isnothing(stop_after_report_step)
        nreport = length(dt)
        1 <= stop_after_report_step <= nreport || error(
            "STOP_AFTER_REPORT_STEP=$stop_after_report_step must be between 1 and $nreport."
        )
        if restart isa Integer && !(restart isa Bool) && restart > stop_after_report_step
            error("Restart step $restart is after STOP_AFTER_REPORT_STEP=$stop_after_report_step.")
        end
        dt = dt[1:stop_after_report_step]
        if forces isa AbstractVector
            length(forces) == nreport || error(
                "Cannot truncate a force vector with $(length(forces)) entries for a $nreport-step schedule."
            )
            forces = forces[1:stop_after_report_step]
        end
        verbose && jutul_message(
            "MRST checkpoint",
            "Schedule truncated after report step $stop_after_report_step."
        )
    end
    parameters = case.parameters
    models = model.models
    rmodel = models[:Reservoir]
    if rmodel isa StandardBlackOilModel
        sys = rmodel.system
        if has_disgas(sys)
            push!(extra_outputs, :Rs)
        end
        if has_vapoil(sys)
            push!(extra_outputs, :Rv)
        end
        push!(extra_outputs, :Saturations)
        # Save more secondary variables into final output to calculate mass fraction of dissolved and free gas 
        if report_gas_masses
            for v in (:FluidVolume, :PhaseMassDensities, :ShrinkageFactors)
                v in extra_outputs || push!(extra_outputs, v)
            end
        end
        # If user wants CO2 concentration, ensure we have required secondary variables
        if report_co2_concentration
            for v in (:ShrinkageFactors, :PhaseMassDensities)
                v in extra_outputs || push!(extra_outputs, v)
            end
        end
    elseif rmodel isa CompositionalModel
        push!(extra_outputs, :LiquidMassFractions)
        push!(extra_outputs, :VaporMassFractions)
        push!(extra_outputs, :Saturations)
    end

    out = rmodel.output_variables
    for k in extra_outputs
        k in out || push!(out, k)
    end

    if write_output
        fn = realpath(fn)
        if isnothing(output_path)
            # Put output under a folder with the same name as the .mat file, suffixed by _output
            directory, filename = splitdir(fn)
            casename, = splitext(filename)
            output_path = joinpath(directory, "$(casename)_output")
        end
        mkpath(output_path)
    else
        output_path = nothing
    end
    if !write_output && !load_all_states_after_sim
        @warn "Forcing load_all_states_after_sim=true because write_output=false would otherwise discard all saved states."
        load_all_states_after_sim = true
    end
    needs_state_history_in_memory = write_vtu || write_mrst || plot || legacy_output
    if needs_state_history_in_memory && !load_all_states_after_sim
        @warn "Forcing load_all_states_after_sim=true because the requested workflow needs in-memory states." write_vtu write_mrst plot legacy_output
        load_all_states_after_sim = true
    end
    # Let Jutul keep the full state history on disk only when we are in the
    # low-memory simulation workflow.
    sim, cfg = setup_reservoir_simulator(
        case;
        mode = mode,
        linear_solver = linear_solver,
        output_path = output_path,
        output_states = load_all_states_after_sim,
        output_reports = load_all_reports_after_sim,
        in_memory_reports = in_memory_reports,
        relaxation = nonlinear_relaxation,
        target_its = target_its,
        target_ds = target_ds,
        timestep_max_increase = Float64(timestep_max_increase),
        kwarg...
    )

    # Visualize initial conditions
    if write_vtu && write_initial_step0
        outdir_local = isempty(vtu_outdir) ? joinpath(pwd(), "paraview_states") : vtu_outdir

        vtu_vars0 = union(vtu_vars, [:Porosity, :Permeability])  # initial only (add :Saturations too if not already)
        export_initial_step0_vtu(fn, mrst_data;
            outdir = outdir_local,
            prefix = "$(vtu_prefix)_incon",   # avoids overwriting series
            vtu_vars = vtu_vars0,
            split_matrices = true,           # gives Permeability_1.._3/_6 reliably
            write_regions = true
        )
    end

    M = first(values(models))
    sys = M.system
    if sys isa CompositionalSystem
        s = "compositional"
    elseif sys isa BlackOilSystem
        s = "black-oil"
    elseif sys isa ImmiscibleSystem
        s = "immiscible"
    else
        s = "unknown"
    end
    ncomp = number_of_components(sys)
    nph = number_of_phases(sys)
    nc = number_of_cells(M.domain)
    sim_result = nothing
    if do_sim
        if verbose
            jutul_message("MRST model", "Starting simulation of $s system with $nc cells and $nph phases and $ncomp components.")
        end
        rspec = deck["RUNSPEC"]
        if haskey(rspec, "START")
            start = DateTime(0) + Day(rspec["START"])
        else
            start = nothing
        end

        if !isnothing(max_nonlinear_iterations)
            cfg[:max_nonlinear_iterations] = max_nonlinear_iterations
        end
        if !isnothing(max_timestep_cuts)
            cfg[:max_timestep_cuts] = max_timestep_cuts
        end
        if !isnothing(info_level)
            cfg[:info_level] = info_level
        end
        if !isnothing(report_level)
            cfg[:report_level] = report_level
        end

        #result = simulate(sim, dt, forces = forces, config = cfg, restart = restart, start_date = start);
        sim_result = simulate(sim, dt;
                          forces = forces,
                          config = cfg,
                          output_path = output_path,
                          restart = restart,
                          start_date = start
        )

        states, reports = sim_result

        # Calculate mass fractions of dissolved and free gas 
        if report_gas_masses
            final_state = final_saved_state(output_path, states)
            if isnothing(final_state)
                @warn "Skipping gas-mass report: final state is unavailable."
            elseif !haskey(final_state, :Reservoir)
                @warn "Skipping gas-mass report: final state has no :Reservoir."
            else
                res = final_state[:Reservoir]

                # Requirements
                req = (:FluidVolume, :Saturations, :PhaseMassDensities)
                missing_req = Symbol[]
                for k in req
                    haskey(res, k) || push!(missing_req, k)
                end
                has_rs   = haskey(res, :Rs)
                has_shrk = haskey(res, :ShrinkageFactors)

                if !isempty(missing_req) || !has_rs || !has_shrk
                    @warn "Skipping gas-mass report: missing variables in final state." missing_req has_rs has_shrk
                else
                    # --- safe to compute ---
                    rs        = res[:Rs]
                    pv        = res[:FluidVolume]
                    sw        = res[:Saturations][1, :]
                    sg        = res[:Saturations][2, :]
                    bo        = res[:ShrinkageFactors][1, :]
                    bg        = res[:ShrinkageFactors][2, :]
                    rho_g_res = res[:PhaseMassDensities][2, :]

                    m_free      = sg .* pv .* rho_g_res
                    m_dissolved = sw .* pv .* rs .* bo .* rho_g_res ./ bg

                    M_free      = sum(m_free)
                    M_dissolved = sum(m_dissolved)
                    M_total     = M_free + M_dissolved

                    println("Free gas mass: $M_free kg")
                    println("Dissolved gas mass: $M_dissolved kg")
                    println("Total gas mass: $M_total kg")
                    println("Gas dissolution ratio: $(M_dissolved / M_total * 100) %")
                    println("Free gas ratio: $(M_free / M_total * 100) %")
                    println("-----------------------------------------------------")
                end
            end
        end

        # Calculate concentration of dissolved CO2 in brine (kg/m^3 brine)
        if report_co2_concentration && (write_vtu && (:Concentration in vtu_vars))
            if isempty(states)
                @warn "Skipping CO2 concentration: states is empty."
            else
                for (i, st) in pairs(states)
                    add_co2_concentration_to_state!(st, rmodel; label = "state $i")
                end
            end
        end

        # Write visualization files (guarded)
        if write_vtu && !isempty(states)
            times_seconds = cumsum(dt)

            has_regions = haskey(mrst_data, "rock") && haskey(mrst_data["rock"], "regions")
            has_p0 = haskey(mrst_data, "state0") && haskey(mrst_data["state0"], "pressure")

            outdir_local = isempty(vtu_outdir) ? joinpath(pwd(), "paraview_states") : vtu_outdir

            report_times_vtu_export(mrst_data["G"], states;
                                    outdir = outdir_local,
                                    prefix = vtu_prefix,
                                    vars = vtu_vars,
                                    split_matrices = true,
                                    write_pvd = true,
                                    times = times_seconds,

                                    # only enable if available
                                    write_regions = has_regions,
                                    reservoir_regions = has_regions ? mrst_data["rock"]["regions"] : nothing,

                                    write_dp = has_p0,
                                    state0_pressure = has_p0 ? mrst_data["state0"]["pressure"] : nothing,
                                    dp_name = "dP"
            )
        end 

        if write_output && write_mrst
            mrst_output_path = "$(output_path)_mrst"
            if verbose
                jutul_message("MRST model", "Writing output to $mrst_output_path.")
            end
            write_reservoir_simulator_output_to_mrst(sim.model, states, reports, forces, mrst_output_path, parameters = parameters)
        end
        ns = completed_report_steps(states, reports, output_path)
        nt = length(dt)
        if verbose
            if ns == nt
                jutul_message("MRST model", "Model was successfully simulated.")
            else
                jutul_message("MRST model", "Simulation aborted: $ns/$nt steps completed.")
            end
        end
    else
        states = []
        reports = []
        if verbose
            jutul_message("MRST model", "Model set up. Skipping simulation as do_sim = false.")
        end
    end
    if mode != :default
        return sim_result
    elseif legacy_output
        setup = (case = case, sim = sim, config = cfg, mrst = mrst_data)
        return (states, reports, output_path, setup)
    elseif !do_sim
        return (
            case = case,
            sim = sim,
            config = cfg,
            mrst = mrst_data,
            output_path = output_path
        )
    elseif !load_all_states_after_sim
        return (
            result = sim_result,
            reports = reports,
            output_path = output_path,
            case = case,
            sim = sim,
            config = cfg,
            mrst = mrst_data
        )
    else
        result = ReservoirSimResult(model, sim_result, forces,
            case = case,
            sim = sim,
            config = cfg,
            mrst = mrst_data,
            path = output_path
        )
        if plot isa Symbol
            if plot == :wells
                plot_wells = true
                plot_res = false
            elseif plot == :reservoir
                plot_res = true
                plot_wells = false
            end
            plot = true
        elseif plot
            plot_res = plot_wells = true
        end
        if plot
            plot_reservoir_simulation_result(model, result, reservoir = plot_res, wells = plot_wells)
        end
        return result
    end
end

function write_reservoir_simulator_output_to_mrst(model, states, reports, forces, output_path; parameters = nothing, write_states = true, write_wells = true, convert_names = true)
    function valid_wellname(wname)
        # Strip non-ascii since it goes to a .mat file.
        wname = collect(String(wname))
        ok = map(x -> isletter(x) || ('0' <= x <= '9'), wname)
        return String(wname[ok])
    end
    mkpath(output_path)
    prep_write(x) = x
    prep_write(x::AbstractMatrix) = collect(x')
    if write_states
        N = min(length(states), length(reports))
        for i in 1:N
            state = states[i]
            if model isa MultiModel
                res_state = state[:Reservoir]
            else
                res_state = state
            end
            state_path = joinpath(output_path, "state$i.mat")
            # @info "Writing to $state_path"
            D = Dict{String, Any}()
            for k in keys(res_state)
                mk = String(k)
                if convert_names
                    if k == :Pressure
                        mk = "pressure"
                    elseif k == :Saturations
                        mk = "s"
                    elseif k == :Rs
                        mk = "rs"
                    elseif k == :Rv
                        mk = "rv"
                    elseif k == :OverallMoleFractions
                        mk = "components"
                    end
                end
                vals = res_state[k]
                if eltype(vals)<:Real
                    D[mk] = prep_write(vals)
                end
            end
            matwrite(state_path, Dict("data" => D))
        end
        if write_wells && model isa MultiModel
            ix = 1:N
            if forces isa Vector
                forces = forces[ix]
            end
            states = states[ix]
            reports = reports[ix]
            wd = full_well_outputs(model, states, forces)
            wd_m = Dict{String, Any}()
            for k in keys(wd)
                tmp = Dict{String, Any}()
                for f in keys(wd[k])
                    tmp[String(f)] = wd[k][f]
                end
                tmp["name"] = "$k"
                wd_m[valid_wellname(k)] = tmp
            end
            wd_m["time"] = report_times(reports)
            ws_path = joinpath(output_path, "wells.mat")
            matwrite(ws_path, wd_m)
        end
    end
end

function write_reservoir_simulator_reports_to_opm_format(reports, name::String = "JUTUL"; digits = 5)
    open("$name.INFOSTEP", "w") do io
        write_reservoir_simulator_reports_to_opm_format!(io, reports, Val(:steps), digits = digits)
    end
    open("$name.INFOITER", "w") do io
        write_reservoir_simulator_reports_to_opm_format!(io, reports, Val(:iterations))
    end
end

function write_reservoir_simulator_reports_to_opm_format!(io, reports, ::Val{:steps}; digits = 5)
    header = ["Time(day)", "TStep(day)","Assembly","LSetup","LSolve","Update","Output","WellIt","Lins","NewtIt","LinIt","Conv"]
    rep_stats = timing_breakdown(reports, reduce = false)
    rep_time = report_timesteps(reports)
    day = si_unit(:day)
    t = 0.0
    n = 0
    for report in reports
        n += length(report[:ministeps])
    end
    data = zeros(Union{Float64, Int}, n, 12)
    index = 1
    for (i, report) in enumerate(reports)
        for (j, minireport) in enumerate(report[:ministeps])
            stats = Jutul.stats_ministep(minireport[:steps])
            dt = minireport[:dt]/day
            data[index, 1] = t
            data[index, 2] = dt
            data[index, 3] = stats.equations + stats.secondary + stats.linear_system
            data[index, 4] = stats.linear_setup
            data[index, 5] = stats.linear_solve
            data[index, 6] = stats.update
            data[index, 7] = 0.0 # TODO
            data[index, 8] = 0 # TODO
            data[index, 9] = stats.linearizations
            data[index, 10] = stats.newtons
            data[index, 11] = stats.linear_iterations
            data[index, 12] = Int(minireport[:success])
            if minireport[:success]
                t += dt
            end
            index += 1
        end
    end
    function formatter(v, i, j)
        if v isa Float64
            return round(v, digits = digits);
        else
            return v
        end
    end
    Jutul.pretty_table(io, data, header = header, formatters = formatter, tf = Jutul.tf_borderless, hlines = :none)
end

function write_reservoir_simulator_reports_to_opm_format!(io, reports, ::Val{:iterations})
    header = ["ReportStep","TimeStep","Time","Iteration"]
    sample = reports[1][:ministeps][1][:steps][1]
    res_error = x -> only(x[:errors][:Reservoir])
    res_sample = res_error(sample)
    phases = res_sample.criterions.MB.names
    day = si_unit(:day)
    for name in phases
        push!(header, "MB_$name")
    end
    for name in phases
        push!(header, "CNV_$name")
    end
    push!(header, "WellStatus")
    n = 0
    for report in reports
        for ministep in report[:ministeps]
            for step in ministep[:steps]
                n += 1
            end
        end
    end
    function formatter(v, i, j)
        if v isa Float64
            return v# round(v, digits = 3);
        else
            return v
        end
    end
    data = Matrix{Union{Float64, Int, String}}(undef, n, length(header))
    index = 1
    t = 0.0
    for (report_i, report) in enumerate(reports)
        for (step_i, ministep) in enumerate(report[:ministeps])
            for (it, step) in enumerate(ministep[:steps])
                res = res_error(step)
                mb = res.criterions.MB.errors
                cnv = res.criterions.CNV.errors
                for i in eachindex(phases)
                    data[index, 4 + i] = mb[i]
                    data[index, 4 + i + length(phases)] = cnv[i]
                end
                wells_ok = true
                for (k, v) in step[:errors]
                    if k != :Reservoir
                        for err in v
                            for cname in keys(err.criterions)
                                e = err.criterions[cname].errors
                                wells_ok = wells_ok && all(e .<= err.tolerances[cname])
                            end
                        end
                    end
                end
                data[index, 1] = report_i - 1
                data[index, 2] = step_i - 1
                data[index, 3] = t
                data[index, 4] = it - 1
                if wells_ok
                    data[index, end] = "CONV"
                else
                    data[index, end] = "FAIL"
                end
                index += 1
            end
            if ministep[:success]
                t += ministep[:dt]/day
            end
        end
    end
    Jutul.pretty_table(io, data, header = header, formatters = formatter, tf = Jutul.tf_borderless, hlines = :none)
end
