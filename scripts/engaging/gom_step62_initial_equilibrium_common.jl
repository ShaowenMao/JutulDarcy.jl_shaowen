using Printf
using SHA
using Statistics

import Jutul
import JutulDarcy

const GOM_EQUILIBRIUM_SECONDS_PER_DAY = 24.0*60.0*60.0
const GOM_EQUILIBRIUM_SECONDS_PER_YEAR = 365.25*GOM_EQUILIBRIUM_SECONDS_PER_DAY

"""Return a scalar from a MATLAB scalar or one-element array."""
gom_equilibrium_scalar(value) =
    value isa AbstractArray ? only(vec(value)) : value

"""Compute a lowercase SHA-256 digest for a file."""
gom_equilibrium_file_sha256(path::AbstractString) =
    open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end

"""Parse a comma-separated list of positive, increasing report years."""
function gom_equilibrium_parse_report_years(text::AbstractString)
    values = parse.(Float64, strip.(split(text, ',')))
    isempty(values) && error("At least one report time is required.")
    all(value -> isfinite(value) && value > 0.0, values) ||
        error("Every equilibrium report time must be finite and positive.")
    issorted(values; lt = <) && all(diff(values) .> 0.0) ||
        error("Equilibrium report times must be strictly increasing.")
    return values
end

"""Parse `all`, a comma list, or inclusive ranges such as `1,4-6`."""
function gom_equilibrium_parse_task_spec(
        text::AbstractString,
        available::AbstractVector{<:Integer}
    )
    allowed = sort!(unique!(Int.(collect(available))))
    normalized = lowercase(strip(text))
    normalized == "all" && return allowed
    selected = Int[]
    for token_raw in split(normalized, ',')
        token = strip(token_raw)
        isempty(token) && error("Task specification contains an empty token.")
        if occursin('-', token)
            bounds = split(token, '-'; limit = 2)
            length(bounds) == 2 || error("Invalid task range: $token")
            first_task = parse(Int, strip(bounds[1]))
            last_task = parse(Int, strip(bounds[2]))
            first_task <= last_task || error("Reversed task range: $token")
            append!(selected, first_task:last_task)
        else
            push!(selected, parse(Int, token))
        end
    end
    selected = sort!(unique!(selected))
    invalid = setdiff(selected, allowed)
    isempty(invalid) || error(
        "Task specification includes unavailable tasks: $(join(invalid, ", "))."
    )
    isempty(selected) && error("No tasks were selected.")
    return selected
end

"""Return stable finite-value moments without allocating a full copy."""
function gom_equilibrium_moments(values)
    count = 0
    minimum_value = Inf
    maximum_value = -Inf
    sum_value = 0.0
    sum_square = 0.0
    max_abs = 0.0
    for raw in values
        value = Float64(Jutul.value(raw))
        isfinite(value) || error("Diagnostic input contains a non-finite value.")
        count += 1
        minimum_value = min(minimum_value, value)
        maximum_value = max(maximum_value, value)
        sum_value += value
        sum_square += abs2(value)
        max_abs = max(max_abs, abs(value))
    end
    count > 0 || error("Cannot summarize an empty diagnostic array.")
    return (
        count = count,
        minimum = minimum_value,
        maximum = maximum_value,
        mean = sum_value/count,
        rms = sqrt(sum_square/count),
        max_abs = max_abs
    )
end

"""Return absolute-value quantiles and moments for a diagnostic vector."""
function gom_equilibrium_absolute_distribution(values)
    absolute_values = Vector{Float64}(undef, length(values))
    for (index, raw) in enumerate(values)
        value = abs(Float64(Jutul.value(raw)))
        isfinite(value) || error("Diagnostic input contains a non-finite value.")
        absolute_values[index] = value
    end
    isempty(absolute_values) && error("Cannot summarize an empty diagnostic array.")
    return (
        count = length(absolute_values),
        mean = mean(absolute_values),
        rms = sqrt(sum(abs2, absolute_values)/length(absolute_values)),
        p50 = quantile(absolute_values, 0.50),
        p90 = quantile(absolute_values, 0.90),
        p99 = quantile(absolute_values, 0.99),
        maximum = maximum(absolute_values)
    )
end

"""Convert a value to a deterministic, tab-safe text representation."""
function gom_equilibrium_table_value(value)
    if value isa AbstractFloat
        return @sprintf("%.17g", value)
    elseif value isa Integer || value isa Bool
        return string(value)
    elseif value === nothing
        return ""
    end
    text = string(value)
    occursin(r"[\t\r\n]", text) && error("Table value contains a tab or newline.")
    return text
end

"""Atomically write dictionaries to a tab-separated table."""
function gom_equilibrium_write_table(
        path::AbstractString,
        columns::AbstractVector{Symbol},
        rows
    )
    mkpath(dirname(path))
    temporary = path * ".tmp.$(getpid()).$(Threads.threadid())"
    open(temporary, "w") do io
        println(io, join(string.(columns), '\t'))
        for row in rows
            values = map(columns) do column
                haskey(row, column) || error("Table row is missing column $column.")
                gom_equilibrium_table_value(row[column])
            end
            println(io, join(values, '\t'))
        end
    end
    mv(temporary, path; force = true)
    return path
end

"""Atomically write a deterministic key-value summary."""
function gom_equilibrium_write_key_values(path::AbstractString, pairs_to_write)
    mkpath(dirname(path))
    temporary = path * ".tmp.$(getpid()).$(Threads.threadid())"
    open(temporary, "w") do io
        seen = Set{String}()
        for (key_raw, value) in pairs_to_write
            key = String(key_raw)
            key in seen && error("Duplicate summary key: $key")
            push!(seen, key)
            println(io, key, '=', gom_equilibrium_table_value(value))
        end
    end
    mv(temporary, path; force = true)
    return path
end

"""Extract a one-row, two-phase capillary-pressure vector."""
function gom_equilibrium_capillary_pressure(state, cell_count::Integer)
    if !haskey(state, :CapillaryPressure)
        return zeros(Float64, cell_count)
    end
    raw = state[:CapillaryPressure]
    if raw isa AbstractVector
        length(raw) == cell_count || error("CapillaryPressure has the wrong length.")
        return Float64.(vec(raw))
    elseif size(raw) == (1, cell_count)
        return Float64.(vec(view(raw, 1, :)))
    elseif size(raw) == (cell_count, 1)
        return Float64.(vec(view(raw, :, 1)))
    end
    error("Unsupported CapillaryPressure shape $(size(raw)).")
end

"""Build domain, complete-fault, and W1-W6 selections from specific metadata."""
function gom_equilibrium_regions(specific, cell_count::Integer)
    haskey(specific, "fault") || error("Specific input has no fault metadata.")
    fault = specific["fault"]
    fault_cells = Int.(round.(vec(fault["cells"])))
    window_index = Int.(round.(vec(fault["window_index"])))
    length(fault_cells) == length(window_index) ||
        error("Fault cells and window indices have different lengths.")
    all(cell -> 1 <= cell <= cell_count, fault_cells) ||
        error("Fault metadata contains an invalid reservoir cell index.")
    all(window -> 1 <= window <= 6, window_index) ||
        error("Fault metadata contains an invalid throw-window index.")
    rows = Pair{String, Any}["domain" => Colon(), "fault_all" => fault_cells]
    for window in 1:6
        selection = fault_cells[window_index .== window]
        isempty(selection) && error("Window W$window contains no fault cells.")
        push!(rows, "W$window" => selection)
    end
    fault_mask = falses(cell_count)
    fault_mask[fault_cells] .= true
    return (regions = rows, fault_mask = fault_mask, fault_cells = fault_cells)
end

"""Return a vector or matrix view for a region selection."""
gom_equilibrium_region_view(values::AbstractVector, ::Colon) = values
gom_equilibrium_region_view(values::AbstractVector, indices) = view(values, indices)
gom_equilibrium_region_view(values::AbstractMatrix, ::Colon) = values
gom_equilibrium_region_view(values::AbstractMatrix, indices) = view(values, :, indices)

"""Summarize exact TPFA liquid-potential residuals and liquid volume fluxes."""
function gom_equilibrium_face_diagnostics(
        state_label::AbstractString,
        state,
        reservoir_model,
        fault_mask::BitVector
    )
    cell_count = length(fault_mask)
    neighbors = JutulDarcy.production_qoi_neighbors(reservoir_model, cell_count)
    face_count = size(neighbors, 2)
    head_residual = Vector{Float64}(undef, face_count)
    volume_flux = Vector{Float64}(undef, face_count)
    touches_fault = falses(face_count)
    inside_fault = falses(face_count)
    liquid_phase = JutulDarcy.phase_indices(reservoir_model.system).l
    flux_type = Jutul.DefaultFlux()

    Threads.@threads for face in 1:face_count
        left = neighbors[1, face]
        right = neighbors[2, face]
        gradient = Jutul.TPFA(left, right, 1)
        upwind = Jutul.SPU(left, right)
        potentials = JutulDarcy.darcy_permeability_potential_differences(
            face,
            state,
            reservoir_model,
            flux_type,
            gradient,
            upwind
        )
        potential = Float64(Jutul.value(potentials[liquid_phase]))
        transmissibility = Float64(Jutul.value(
            JutulDarcy.effective_transmissibility(state, face, gradient)
        ))
        isfinite(transmissibility) && transmissibility > 0.0 ||
            error("Face $face has invalid transmissibility $transmissibility.")
        head_residual[face] = -potential/transmissibility
        volume_flux[face] = Float64(Jutul.value(
            JutulDarcy.darcy_phase_volume_flux(
                face,
                liquid_phase,
                state,
                reservoir_model,
                flux_type,
                gradient,
                upwind,
                potential
            )
        ))
        left_fault = fault_mask[left]
        right_fault = fault_mask[right]
        touches_fault[face] = left_fault || right_fault
        inside_fault[face] = left_fault && right_fault
    end

    rows = Dict{Symbol, Any}[]
    categories = (
        ("all_internal_faces", trues(face_count)),
        ("faces_touching_fault", touches_fault),
        ("faces_inside_fault", inside_fault)
    )
    for (category, selection) in categories
        count(selection) > 0 || error("Face category $category is empty.")
        head = gom_equilibrium_absolute_distribution(head_residual[selection])
        flux = gom_equilibrium_absolute_distribution(volume_flux[selection])
        push!(rows, Dict{Symbol, Any}(
            :state => String(state_label),
            :face_category => category,
            :face_count => head.count,
            :head_abs_mean_pa => head.mean,
            :head_abs_rms_pa => head.rms,
            :head_abs_p50_pa => head.p50,
            :head_abs_p90_pa => head.p90,
            :head_abs_p99_pa => head.p99,
            :head_abs_max_pa => head.maximum,
            :liquid_flux_abs_mean_m3_s => flux.mean,
            :liquid_flux_abs_rms_m3_s => flux.rms,
            :liquid_flux_abs_p50_m3_s => flux.p50,
            :liquid_flux_abs_p90_m3_s => flux.p90,
            :liquid_flux_abs_p99_m3_s => flux.p99,
            :liquid_flux_abs_max_m3_s => flux.maximum
        ))
    end
    return rows
end
