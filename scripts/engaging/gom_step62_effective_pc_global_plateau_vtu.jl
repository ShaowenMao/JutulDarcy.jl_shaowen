using JutulDarcy
import Jutul
import MAT
import SHA

include(joinpath(@__DIR__, "gom_step62_effective_pc_global_plateau_contract.jl"))
using .GoMStep62EffectivePcGlobalPlateauContract

length(ARGS) == 7 || error(
    "Usage: gom_step62_effective_pc_global_plateau_vtu.jl COMMON_MAT SPECIFIC_MAT " *
    "RESTART_DIR VTU_DIR PREFIX SUMMARY_PATH CASE_ID"
)
common_path, specific_path, restart_dir, vtu_dir, prefix, summary_path,
    case_id = ARGS

const MRST_YEAR_SECONDS = 365.2425*24*60*60
const SELECTED_STEPS = [78, 210]

isfile(common_path) || error("Common MAT file does not exist: $common_path")
isfile(specific_path) || error("Specific MAT file does not exist: $specific_path")
isdir(restart_dir) || error("Restart directory does not exist: $restart_dir")
for step in SELECTED_STEPS
    isfile(joinpath(restart_dir, "jutul_$step.jld2")) ||
        error("Missing restart state for report step $step.")
end

case, mrst = JutulDarcy.setup_case_from_mrst_split(
    common_path,
    specific_path;
    validate_split = true,
    nthreads = Threads.nthreads(),
    well_volume_fraction = 1.0e-3,
    disable_hysteresis = false,
    hysteresis_s_min =
        GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_HYSTERESIS_S_MIN,
    use_mrst_transmissibility = false,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau_all_active",
    explicit_fault_hysteresis_mode = "reservoir",
    ds_max = 0.05
)
diagnostics =
    GoMStep62EffectivePcGlobalPlateauContract.validate_assembled_case((; case, mrst))

grid = mrst["G"]
regions = mrst["rock"]["regions"]
state0 = mrst["state0"]
nc = Int(round(grid["cells"]["num"]))
specific = MAT.matread(specific_path)
masks = mrst["masks"]

fault_region_flag = Int32.(vec(masks["isFaultCell"]) .!= 0)
stratigraphy_region_flag =
    Int32.(vec(masks["isSpecificStratigraphyCell"]) .!= 0)
length(fault_region_flag) == nc ||
    error("Fault-region mask has the wrong length.")
length(stratigraphy_region_flag) == nc ||
    error("Stratigraphy-region mask has the wrong length.")
sum(fault_region_flag) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_COMPLETE_FAULT_CELLS ||
    error("Unexpected complete fault-domain cell count.")
sum(stratigraphy_region_flag) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected stratigraphy-domain cell count.")
all((fault_region_flag .+ stratigraphy_region_flag) .<= 1) ||
    error("Fault and stratigraphy region flags overlap.")

fault_cells = sort(Int.(round.(vec(masks["fault_all_cells"]))))
findall(==(Int32(1)), fault_region_flag) == fault_cells ||
    error("Fault-region flag does not match masks.fault_all_cells.")
specific_fault_cells =
    sort(Int.(round.(vec(specific["fault"]["cells"]))))
length(specific_fault_cells) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_FAULT_CELLS ||
    error("Unexpected geology-specific fault cell count.")
all(fault_region_flag[specific_fault_cells] .== 1) ||
    error("Specific fault cells are not contained in the full fault flag.")

stratigraphy = specific["stratigraphy"]
stratigraphy_cells = Int.(round.(vec(stratigraphy["cells"])))
stratigraphy_ids =
    Int32.(round.(vec(stratigraphy["stratigraphic_unit_id"])))
length(stratigraphy_cells) ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected stratigraphy-specific cell count.")
length(stratigraphy_ids) == length(stratigraphy_cells) ||
    error("Stratigraphic IDs do not align with stratigraphy cells.")
sort(unique(stratigraphy_ids)) == collect(Int32(1):Int32(21)) ||
    error("Expected stratigraphic unit IDs 1:21.")
findall(==(Int32(1)), stratigraphy_region_flag) ==
    sort(stratigraphy_cells) ||
    error("Stratigraphy flag does not match the specific cell list.")
stratigraphic_unit_id = zeros(Int32, nc)
stratigraphic_unit_id[stratigraphy_cells] .= stratigraphy_ids

extra_cell_data = Dict{String, AbstractVector}(
    "fault_region_flag" => fault_region_flag,
    "stratigraphy_region_flag" => stratigraphy_region_flag,
    "stratigraphic_unit_id" => stratigraphic_unit_id
)

mkpath(vtu_dir)
initial_prefix = "$(prefix)_incon"
JutulDarcy.export_initial_step0_vtu(
    specific_path,
    mrst;
    outdir = vtu_dir,
    prefix = initial_prefix,
    vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
    split_matrices = true,
    write_regions = true,
    extra_cell_data = extra_cell_data
)
initial_path = joinpath(vtu_dir, "$(initial_prefix)_0001.vtu")
isfile(initial_path) || error("Initial-condition VTU was not written.")

state_specification = JutulDarcy.prepare_report_times_vtu_export(
    grid;
    vars = [:Pressure, :Saturations, :Rs],
    verbose = true,
    write_regions = true,
    reservoir_regions = regions,
    write_dp = true,
    state0_pressure = state0["pressure"],
    dp_name = "dP",
    extra_cell_data = extra_cell_data
)
state_paths = String[]
for step in SELECTED_STEPS
    state, _ = Jutul.read_restart(
        restart_dir,
        step;
        read_state = true,
        read_report = false
    )
    path = JutulDarcy.write_report_time_vtu_step(
        grid,
        state,
        step,
        state_specification;
        outdir = vtu_dir,
        prefix = prefix,
        split_matrices = true,
        digits = 4
    )
    isnothing(path) && error("VTU for report step $step was not written.")
    push!(state_paths, path)
end

schedule_dt = Float64.(vec(mrst["schedule"]["step"]["val"]))
length(schedule_dt) == 210 || error("Expected 210 schedule steps.")
cumulative_years = cumsum(schedule_dt) ./ MRST_YEAR_SECONDS
selected_years_raw = cumulative_years[SELECTED_STEPS]
isapprox(selected_years_raw[1], 50.0; atol = 1.0e-10, rtol = 0) ||
    error("Step 78 is not 50 years.")
isapprox(selected_years_raw[2], 1000.0; atol = 1.0e-10, rtol = 0) ||
    error("Step 210 is not 1000 years.")
selected_years = round.(selected_years_raw; digits = 10)
vtu_paths = vcat(initial_path, state_paths)
pvd_times = vcat(0.0, selected_years)
pvd_path = JutulDarcy.write_pvd_collection(
    vtu_paths,
    pvd_times;
    outdir = vtu_dir,
    prefix = prefix
)
isfile(pvd_path) || error("PVD collection was not written.")

function vtu_cell_array_names(path)
    header_lines = String[]
    open(path, "r") do io
        while !eof(io)
            line = readline(io)
            push!(header_lines, line)
            occursin("<AppendedData", line) && break
        end
    end
    header = join(header_lines, '\n')
    occursin(
        "NumberOfCells=\"$(GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_CELLS)\"",
        header
    ) || error("$path has the wrong cell count.")
    cell_data = match(r"<CellData>(.*?)</CellData>"s, header)
    isnothing(cell_data) && error("$path has no CellData section.")
    names = String[]
    for item in eachmatch(r"<DataArray\b[^>]*>", cell_data.captures[1])
        name = match(r"\bName=\"([^\"]+)\"", item.match)
        isnothing(name) && error("$path has an unnamed CellData array.")
        push!(names, name.captures[1])
    end
    length(names) == length(unique(names)) ||
        error("$path has duplicate CellData arrays.")
    return Set(names)
end

expected_initial_arrays = Set([
    "Pressure", "Saturations_1", "Saturations_2", "Porosity",
    "Permeability_1", "Permeability_2", "Permeability_3",
    "Permeability_4", "Permeability_5", "Permeability_6",
    "sat_region", "rock_region", "imbi_region",
    "fault_region_flag", "stratigraphy_region_flag",
    "stratigraphic_unit_id"
])
expected_state_arrays = Set([
    "Pressure", "dP", "Saturations_1", "Saturations_2", "Rs",
    "sat_region", "rock_region", "imbi_region",
    "fault_region_flag", "stratigraphy_region_flag",
    "stratigraphic_unit_id"
])
vtu_cell_array_names(initial_path) == expected_initial_arrays ||
    error("Initial VTU arrays do not match the compact contract.")
all(path -> vtu_cell_array_names(path) == expected_state_arrays, state_paths) ||
    error("A state VTU does not match the compact contract.")

pvd_text = read(pvd_path, String)
for (path, time) in zip(vtu_paths, pvd_times)
    occursin("file=\"$(basename(path))\"", pvd_text) ||
        error("PVD collection is missing $(basename(path)).")
    time_text = isinteger(time) ? string(round(Int, time)) : string(time)
    occursin("timestep=\"$time_text\"", pvd_text) ||
        error("PVD collection is missing timestep $time.")
end

int32_sha256(values::Vector{Int32}) =
    bytes2hex(SHA.sha256(reinterpret(UInt8, values)))
mkpath(dirname(summary_path))
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "physics_profile=$(GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE)")
    println(io, "case_id=$case_id")
    println(io, "grid=step62")
    println(io, "resolution_slices=87")
    println(io, "cells_per_vtu=$nc")
    println(io, "vtu_files=$(length(vtu_paths))")
    println(io, "pvd_files=1")
    println(io, "pvd_time_unit=years")
    println(io, "initial_state=true")
    println(io, "selected_steps=$(join(SELECTED_STEPS, ','))")
    println(io, "selected_times_years=$(join(selected_years, ','))")
    println(io, "parameter_set=standard_compact_plus_geology_indicators")
    println(io, "additional_parameters=geology_indicators_only")
    println(io, "initial_cell_arrays=$(length(expected_initial_arrays))")
    println(io, "state_cell_arrays=$(length(expected_state_arrays))")
    println(io, "base_saturation_regions=8")
    println(io, "explicit_predict_regions=522")
    println(io, "drainage_saturation_regions=530")
    println(io, "total_sgof_tables=1060")
    println(io, "fault_region_cells=$(sum(fault_region_flag))")
    println(io, "specific_fault_cells=$(length(specific_fault_cells))")
    println(io, "stratigraphy_region_cells=$(sum(stratigraphy_region_flag))")
    println(io, "stratigraphic_unit_ids=1:21")
    println(io, "fault_region_flag_sha256=$(int32_sha256(fault_region_flag))")
    println(
        io,
        "stratigraphy_region_flag_sha256=" *
        int32_sha256(stratigraphy_region_flag)
    )
    println(
        io,
        "stratigraphic_unit_id_sha256=" *
        int32_sha256(stratigraphic_unit_id)
    )
    println(io, "hysteresis_active=true")
    println(io, "hysteresis_s_min=0.05")
    println(io, "fault_hysteresis=drainage_equivalent")
    println(io, "pc_entry_treatment=plateau_all_active")
    println(io, "pc_entry_scope=all_active_drainage")
    println(io, "pc_entry_rule=first_strictly_positive_pc_node")
    println(
        io,
        "pc_plateau_active_tables=$(diagnostics.pc_summary["active_tables"])"
    )
    println(
        io,
        "pc_plateau_adjusted_tables=$(diagnostics.pc_summary["adjusted_tables"])"
    )
    println(
        io,
        "pc_plateau_true_zero_tables=" *
        string(diagnostics.pc_summary["true_zero_pc_tables"])
    )
    println(
        io,
        "pc_input_drainage_sha256=" *
        diagnostics.pc_summary["input_drainage_sha256"]
    )
    println(
        io,
        "pc_output_drainage_sha256=" *
        diagnostics.pc_summary["output_drainage_sha256"]
    )
    println(
        io,
        "pc_kr_sha256=" * diagnostics.pc_summary["kr_sha256_after"]
    )
    println(
        io,
        "pc_tail_sha256=" * diagnostics.pc_summary["pc_tail_sha256_after"]
    )
    println(
        io,
        "base_imbibition_sha256=" *
        diagnostics.pc_summary["base_imbibition_sha256_after"]
    )
    println(io, "pc_kr_unchanged=true")
    println(io, "pc_at_and_above_entry_unchanged=true")
    println(io, "base_imbibition_unchanged=true")
    println(io, "pc_mapping_schema=gom_effective_saturation_pc_v1")
    println(io, "pc_saturation_coordinate=effective_gas_saturation")
    println(io, "pc_reference=sand_theta30")
    println(io, "host_pc_scaling=leverett_kv")
    println(io, "nonpredict_pc_scaling=leverett_local_kzz")
    println(io, "younger_nonpredict_local_perm_md=50,500,500")
    println(io, "transmissibility_source=JutulDarcy_grid_and_rock")
    println(io, "vtu_dir=$vtu_dir")
    println(io, "pvd_path=$pvd_path")
end

println(
    "STEP62_EFFECTIVE_PC_GLOBAL_PLATEAU_VTU_PASS " *
    "case=$case_id summary=$summary_path"
)
