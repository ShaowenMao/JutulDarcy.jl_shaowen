using HYPRE
using MAT
using Statistics

using JutulDarcy
import Jutul

include(joinpath(@__DIR__, "gom_step62_initial_equilibrium_common.jl"))

length(ARGS) == 11 || error(
    "Usage: gom_step62_initial_equilibrium_audit.jl COMMON_MAT " *
    "SPECIFIC_MAT RESULT_DIR CASE_KEY GEOLOGY_ID REALIZATION_ID " *
    "GEOLOGY_HASH LEVEL3_CASE_NAME MANIFEST_SHA256 COMMON_SHA256 " *
    "SPECIFIC_SHA256"
)

common_path, specific_path, result_dir, expected_case_key,
    expected_geology_id, expected_realization_text, expected_geology_hash,
    expected_level3_case_name, expected_manifest_sha256,
    expected_common_sha256, expected_specific_sha256 = ARGS
expected_realization_id = parse(Int, expected_realization_text)

const EXPECTED_CELLS = 2_165_082
const EXPECTED_FAULT_CELLS = 32_190
const EXPECTED_WINDOWS = 6
const EXPECTED_SLICES = 87

report_years_text = get(
    ENV,
    "GOM_EQUILIBRIUM_REPORT_YEARS",
    "0.0027378507871321013,0.08213552361396304,1,10,100,1000"
)
report_years = gom_equilibrium_parse_report_years(report_years_text)
report_seconds = report_years .* GOM_EQUILIBRIUM_SECONDS_PER_YEAR
report_steps = diff(vcat(0.0, report_seconds))

mkpath(result_dir)
isfile(joinpath(result_dir, "COMPLETE")) && error(
    "Refusing to overwrite a completed equilibrium audit: $result_dir"
)

"""Validate immutable input identity before constructing the simulator."""
function validate_input_identity()
    isfile(common_path) || error("Common MAT does not exist: $common_path")
    isfile(specific_path) || error("Specific MAT does not exist: $specific_path")
    observed_common = gom_equilibrium_file_sha256(common_path)
    observed_specific = gom_equilibrium_file_sha256(specific_path)
    observed_common == lowercase(expected_common_sha256) ||
        error("Common MAT SHA-256 does not match the campaign manifest.")
    observed_specific == lowercase(expected_specific_sha256) ||
        error("Specific MAT SHA-256 does not match the campaign manifest.")
    occursin(r"^[0-9a-f]{64}$", lowercase(expected_manifest_sha256)) ||
        error("Campaign manifest SHA-256 is invalid.")

    specific = MAT.matread(specific_path)
    get(specific, "geology_id", "") == expected_geology_id ||
        error("Specific MAT geology ID does not match the manifest.")
    lowercase(get(specific, "geology_hash", "")) ==
        lowercase(expected_geology_hash) ||
        error("Specific MAT geology hash does not match the manifest.")
    Int(round(gom_equilibrium_scalar(specific["realization_id"]))) ==
        expected_realization_id ||
        error("Specific MAT realization ID does not match the manifest.")
    get(specific, "level3_case_name", "") == expected_level3_case_name ||
        error("Specific MAT Level-3 case name does not match the manifest.")
    expected_case_key ==
        "$(expected_geology_id)_case$(lpad(expected_realization_id, 2, '0'))" ||
        error("Case key is inconsistent with geology and realization IDs.")
    return specific
end

"""Return the reservoir substate from a MultiModel or reservoir-only state."""
gom_equilibrium_reservoir_state(state) =
    haskey(state, :Reservoir) ? state[:Reservoir] : state

"""Compute component and total masses for a cell selection."""
function region_masses(total_masses, selection)
    selected = gom_equilibrium_region_view(total_masses, selection)
    component_count = size(selected, 1)
    masses = [
        sum(Float64(Jutul.value(value)) for value in view(selected, component, :))
        for component in 1:component_count
    ]
    return (
        component_1 = masses[1],
        component_2 = component_count >= 2 ? masses[2] : 0.0,
        total = sum(masses)
    )
end

specific_metadata = validate_input_identity()
raw_common_pressure = MAT.matopen(common_path) do file
    state0 = read(file, "state0")
    haskey(state0, "pressure") || error("Common MAT state0 has no pressure.")
    Float64.(vec(state0["pressure"]))
end
HYPRE.Init(nthreads = Threads.nthreads())
println("HYPRE threads = ", HYPRE.NumThreads())

setup = simulate_mrst_case(
    specific_path;
    common_mrst_path = common_path,
    specific_mrst_path = specific_path,
    do_sim = false,
    write_output = false,
    verbose = true,
    extra_outputs = [
        :Saturations,
        :Rs,
        :CapillaryPressure,
        :PhaseMassDensities,
        :PhaseMobilities,
        :TotalMasses
    ],
    disable_hysteresis = false,
    hysteresis_s_min = 0.05,
    use_mrst_transmissibility = false,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau_all_active",
    explicit_fault_hysteresis_mode = "reservoir",
    ds_max = 0.05,
    dr_max = Inf,
    max_nonlinear_iterations = 10,
    max_timestep_cuts = 25,
    nonlinear_relaxation = true,
    target_its = 5,
    target_ds = 0.05,
    timestep_max_increase = 1.25,
    linear_solver_arg = Dict{Symbol, Any}(
        :update_interval => :iteration,
        :update_interval_partial => :iteration
    ),
    info_level = 1,
    report_level = 1,
    well_volume_fraction = 1.0e-3,
    nthreads = Threads.nthreads()
)

case = setup.case
simulator = setup.sim
config = setup.config
mrst = setup.mrst
model = case.model
reservoir_model = model.models[:Reservoir]
cell_count = Jutul.number_of_cells(reservoir_model.domain)
cell_count == EXPECTED_CELLS || error("Unexpected cell count: $cell_count")
regions = gom_equilibrium_regions(specific_metadata, cell_count)
empty!(specific_metadata)
length(regions.fault_cells) == EXPECTED_FAULT_CELLS ||
    error("Unexpected fault-cell count: $(length(regions.fault_cells))")

phase_indices = JutulDarcy.phase_indices(reservoir_model.system)
liquid_phase = phase_indices.l
vapor_phase = phase_indices.v
reference_phase = JutulDarcy.get_reference_phase_index(reservoir_model.system)

storage = Jutul.get_simulator_storage(simulator)
initial_full_state = storage[:Reservoir].state0
initial_pressure = Float64.(vec(initial_full_state[:Pressure]))
initial_saturation = Float64.(initial_full_state[:Saturations])
initial_rs = Float64.(vec(initial_full_state[:Rs]))
initial_total_masses = Float64.(initial_full_state[:TotalMasses])
length(raw_common_pressure) == cell_count ||
    error("Raw common-MAT initial pressure has the wrong cell count.")
assembled_state0_pressure = Float64.(vec(mrst["state0"]["pressure"]))
length(assembled_state0_pressure) == cell_count ||
    error("Assembled MRST initial pressure has the wrong cell count.")
initial_pc = gom_equilibrium_capillary_pressure(initial_full_state, cell_count)
import_offset = initial_pressure .- raw_common_pressure
assembled_offset = assembled_state0_pressure .- raw_common_pressure
imported_minus_assembled = initial_pressure .- assembled_state0_pressure
offset_minus_pc = import_offset .- initial_pc

initial_mass_by_region = Dict{String, Any}(
    label => region_masses(initial_total_masses, selection)
    for (label, selection) in regions.regions
)

import_rows = Dict{Symbol, Any}[]
for (label, selection) in regions.regions
    raw_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(raw_common_pressure, selection)
    )
    assembled_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(assembled_state0_pressure, selection)
    )
    imported_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(initial_pressure, selection)
    )
    offset_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(import_offset, selection)
    )
    assembled_offset_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(assembled_offset, selection)
    )
    imported_minus_assembled_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(imported_minus_assembled, selection)
    )
    pc_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(initial_pc, selection)
    )
    mismatch_stats = gom_equilibrium_moments(
        gom_equilibrium_region_view(offset_minus_pc, selection)
    )
    push!(import_rows, Dict{Symbol, Any}(
        :region => label,
        :cell_count => raw_stats.count,
        :raw_pressure_min_pa => raw_stats.minimum,
        :raw_pressure_max_pa => raw_stats.maximum,
        :assembled_pressure_min_pa => assembled_stats.minimum,
        :assembled_pressure_max_pa => assembled_stats.maximum,
        :imported_pressure_min_pa => imported_stats.minimum,
        :imported_pressure_max_pa => imported_stats.maximum,
        :assembled_offset_max_abs_pa => assembled_offset_stats.max_abs,
        :import_offset_mean_pa => offset_stats.mean,
        :import_offset_rms_pa => offset_stats.rms,
        :import_offset_max_abs_pa => offset_stats.max_abs,
        :imported_minus_assembled_max_abs_pa =>
            imported_minus_assembled_stats.max_abs,
        :capillary_pressure_mean_pa => pc_stats.mean,
        :capillary_pressure_rms_pa => pc_stats.rms,
        :capillary_pressure_max_abs_pa => pc_stats.max_abs,
        :offset_minus_pc_max_abs_pa => mismatch_stats.max_abs
    ))
end

import_columns = [
    :region,
    :cell_count,
    :raw_pressure_min_pa,
    :raw_pressure_max_pa,
    :assembled_pressure_min_pa,
    :assembled_pressure_max_pa,
    :imported_pressure_min_pa,
    :imported_pressure_max_pa,
    :assembled_offset_max_abs_pa,
    :import_offset_mean_pa,
    :import_offset_rms_pa,
    :import_offset_max_abs_pa,
    :imported_minus_assembled_max_abs_pa,
    :capillary_pressure_mean_pa,
    :capillary_pressure_rms_pa,
    :capillary_pressure_max_abs_pa,
    :offset_minus_pc_max_abs_pa
]
gom_equilibrium_write_table(
    joinpath(result_dir, "initial_import_pressure_audit.tsv"),
    import_columns,
    import_rows
)

face_rows = gom_equilibrium_face_diagnostics(
    "initial",
    initial_full_state,
    reservoir_model,
    regions.fault_mask
)

state_rows = Dict{Symbol, Any}[]
function append_rows!(state_label, time_years, state, previous_pressure)
    pressure = Float64.(vec(state[:Pressure]))
    saturation = Float64.(state[:Saturations])
    rs = Float64.(vec(state[:Rs]))
    total_masses = Float64.(state[:TotalMasses])
    size(saturation, 2) == cell_count || error("Unexpected saturation shape.")
    size(total_masses, 2) == cell_count || error("Unexpected TotalMasses shape.")
    gas_saturation = view(saturation, vapor_phase, :)
    saturation_sum_error = abs.(vec(sum(saturation; dims = 1)) .- 1.0)
    pressure_delta = pressure .- initial_pressure
    pressure_increment = pressure .- previous_pressure
    rs_delta = rs .- initial_rs
    for (label, selection) in regions.regions
        regional_pressure_delta =
            gom_equilibrium_region_view(pressure_delta, selection)
        regional_pressure_increment =
            gom_equilibrium_region_view(pressure_increment, selection)
        gas = gom_equilibrium_region_view(gas_saturation, selection)
        regional_rs_delta = gom_equilibrium_region_view(rs_delta, selection)
        sum_error = gom_equilibrium_region_view(saturation_sum_error, selection)
        delta_stats = gom_equilibrium_moments(regional_pressure_delta)
        increment_stats = gom_equilibrium_moments(regional_pressure_increment)
        gas_stats = gom_equilibrium_moments(gas)
        rs_stats = gom_equilibrium_moments(regional_rs_delta)
        sum_stats = gom_equilibrium_moments(sum_error)
        masses = region_masses(total_masses, selection)
        initial_masses = initial_mass_by_region[label]
        push!(state_rows, Dict{Symbol, Any}(
            :state => String(state_label),
            :time_years => time_years,
            :region => label,
            :cell_count => delta_stats.count,
            :pressure_delta_min_pa => delta_stats.minimum,
            :pressure_delta_max_pa => delta_stats.maximum,
            :pressure_delta_mean_pa => delta_stats.mean,
            :pressure_delta_rms_pa => delta_stats.rms,
            :pressure_delta_max_abs_pa => delta_stats.max_abs,
            :pressure_increment_max_abs_pa => increment_stats.max_abs,
            :gas_saturation_mean => gas_stats.mean,
            :gas_saturation_max => gas_stats.maximum,
            :rs_delta_max_abs => rs_stats.max_abs,
            :saturation_sum_error_max_abs => sum_stats.max_abs,
            :component_1_mass_kg => masses.component_1,
            :component_1_mass_change_kg =>
                masses.component_1 - initial_masses.component_1,
            :component_2_mass_kg => masses.component_2,
            :component_2_mass_change_kg =>
                masses.component_2 - initial_masses.component_2,
            :total_mass_kg => masses.total,
            :total_mass_change_kg => masses.total - initial_masses.total,
            :total_mass_relative_change =>
                (masses.total - initial_masses.total)/initial_masses.total
        ))
    end
    return pressure
end

previous_pressure = Ref(append_rows!(
    "initial",
    0.0,
    initial_full_state,
    initial_pressure
))

zero_forces = setup_reservoir_forces(model)
reservoir_forces = zero_forces[:Reservoir]
isnothing(reservoir_forces.bc) || isempty(reservoir_forces.bc) ||
    error("Zero-injection control unexpectedly contains boundary conditions.")
isnothing(reservoir_forces.sources) || isempty(reservoir_forces.sources) ||
    error("Zero-injection control unexpectedly contains source terms.")
facility_forces = get(zero_forces, :Facility, nothing)
well_count = 0
if !isnothing(facility_forces)
    controls = facility_forces.control
    well_count = length(controls)
    all(control -> control isa JutulDarcy.DisabledControl, values(controls)) ||
        error("Zero-injection control contains an active well control.")
end

config[:max_nonlinear_iterations] = 10
config[:max_timestep_cuts] = 25
config[:info_level] = 1
config[:report_level] = 1
config[:output_substates] = false

println(
    "Starting zero-injection control for $expected_case_key at report years ",
    join(report_years, ", ")
)
elapsed_seconds = @elapsed simulation_result = Jutul.simulate(
    case.state0,
    simulator,
    report_steps;
    parameters = case.parameters,
    forces = zero_forces,
    config = config
)
states, reports = simulation_result
length(states) == length(report_years) || error(
    "Zero-injection control returned $(length(states)) states for " *
    "$(length(report_years)) report times."
)
length(reports) == length(report_years) || error(
    "Zero-injection control returned $(length(reports)) reports for " *
    "$(length(report_years)) report times."
)

for (index, raw_state) in enumerate(states)
    state = gom_equilibrium_reservoir_state(raw_state)
    previous_pressure[] = append_rows!(
        "report_$index",
        report_years[index],
        state,
        previous_pressure[]
    )
end

final_full_state = Jutul.get_simulator_storage(simulator)[:Reservoir].state
append!(face_rows, gom_equilibrium_face_diagnostics(
    "final",
    final_full_state,
    reservoir_model,
    regions.fault_mask
))

state_columns = [
    :state,
    :time_years,
    :region,
    :cell_count,
    :pressure_delta_min_pa,
    :pressure_delta_max_pa,
    :pressure_delta_mean_pa,
    :pressure_delta_rms_pa,
    :pressure_delta_max_abs_pa,
    :pressure_increment_max_abs_pa,
    :gas_saturation_mean,
    :gas_saturation_max,
    :rs_delta_max_abs,
    :saturation_sum_error_max_abs,
    :component_1_mass_kg,
    :component_1_mass_change_kg,
    :component_2_mass_kg,
    :component_2_mass_change_kg,
    :total_mass_kg,
    :total_mass_change_kg,
    :total_mass_relative_change
]
gom_equilibrium_write_table(
    joinpath(result_dir, "zero_injection_state_evolution.tsv"),
    state_columns,
    state_rows
)

face_columns = [
    :state,
    :face_category,
    :face_count,
    :head_abs_mean_pa,
    :head_abs_rms_pa,
    :head_abs_p50_pa,
    :head_abs_p90_pa,
    :head_abs_p99_pa,
    :head_abs_max_pa,
    :liquid_flux_abs_mean_m3_s,
    :liquid_flux_abs_rms_m3_s,
    :liquid_flux_abs_p50_m3_s,
    :liquid_flux_abs_p90_m3_s,
    :liquid_flux_abs_p99_m3_s,
    :liquid_flux_abs_max_m3_s
]
gom_equilibrium_write_table(
    joinpath(result_dir, "liquid_face_equilibrium.tsv"),
    face_columns,
    face_rows
)

solver_stats = Jutul.report_stats(reports)
failed_ministeps = sum(
    count(ministep -> !get(ministep, :success, false),
        get(report, :ministeps, Any[]))
    for report in reports
)
global_final = only(filter(
    row -> row[:state] == "report_$(length(report_years))" &&
        row[:region] == "domain",
    state_rows
))
global_initial_face = only(filter(
    row -> row[:state] == "initial" &&
        row[:face_category] == "all_internal_faces",
    face_rows
))
global_final_face = only(filter(
    row -> row[:state] == "final" &&
        row[:face_category] == "all_internal_faces",
    face_rows
))
fault_import = only(filter(row -> row[:region] == "fault_all", import_rows))

summary_pairs = [
    "status" => "complete",
    "interpretation" => "pending_cross_case_scientific_review",
    "case_key" => expected_case_key,
    "geology_id" => expected_geology_id,
    "geology_hash" => lowercase(expected_geology_hash),
    "realization_id" => expected_realization_id,
    "level3_case_name" => expected_level3_case_name,
    "campaign_manifest_sha256" => lowercase(expected_manifest_sha256),
    "common_mat_sha256" => lowercase(expected_common_sha256),
    "specific_mat_sha256" => lowercase(expected_specific_sha256),
    "cells" => cell_count,
    "fault_cells" => length(regions.fault_cells),
    "windows" => EXPECTED_WINDOWS,
    "slices" => EXPECTED_SLICES,
    "reference_phase_index" => reference_phase,
    "liquid_phase_index" => liquid_phase,
    "vapor_phase_index" => vapor_phase,
    "reference_phase_is_liquid" => reference_phase == liquid_phase,
    "zero_boundary_conditions" => true,
    "zero_source_terms" => true,
    "well_count" => well_count,
    "all_wells_disabled" => true,
    "report_years" => join(report_years, ','),
    "report_steps" => length(report_years),
    "simulation_elapsed_seconds" => elapsed_seconds,
    "solver_ministeps" => solver_stats.ministeps,
    "solver_newton_iterations" => solver_stats.newtons,
    "solver_linear_iterations" => solver_stats.linear_iterations,
    "solver_failed_ministeps" => failed_ministeps,
    "initial_gas_saturation_max" => maximum(initial_saturation[vapor_phase, :]),
    "final_gas_saturation_max" => global_final[:gas_saturation_max],
    "final_global_pressure_delta_max_abs_pa" =>
        global_final[:pressure_delta_max_abs_pa],
    "final_global_pressure_increment_max_abs_pa" =>
        global_final[:pressure_increment_max_abs_pa],
    "final_global_total_mass_relative_change" =>
        global_final[:total_mass_relative_change],
    "fault_import_pressure_offset_max_abs_pa" =>
        fault_import[:import_offset_max_abs_pa],
    "fault_import_offset_minus_pc_max_abs_pa" =>
        fault_import[:offset_minus_pc_max_abs_pa],
    "initial_head_residual_max_abs_pa" =>
        global_initial_face[:head_abs_max_pa],
    "final_head_residual_max_abs_pa" =>
        global_final_face[:head_abs_max_pa],
    "initial_liquid_flux_max_abs_m3_s" =>
        global_initial_face[:liquid_flux_abs_max_m3_s],
    "final_liquid_flux_max_abs_m3_s" =>
        global_final_face[:liquid_flux_abs_max_m3_s]
]
gom_equilibrium_write_key_values(
    joinpath(result_dir, "equilibrium_summary.txt"),
    summary_pairs
)
open(joinpath(result_dir, "COMPLETE"), "w") do io
    println(io, "complete")
end
println(
    "STEP62_INITIAL_EQUILIBRIUM_COMPLETE case=$expected_case_key " *
    "result=$result_dir"
)
