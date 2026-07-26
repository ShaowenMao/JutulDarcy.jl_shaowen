using JutulDarcy
import Jutul
import MAT
import SHA

length(ARGS) == 7 || error(
    "Usage: gom_step62_four_geology_hyst_plateau_standard_vtu.jl " *
    "COMMON_MAT SPECIFIC_MAT RESTART_DIR VTU_DIR PREFIX SUMMARY_PATH CASE_ID"
)
common_path, specific_path, restart_dir, vtu_dir, prefix, summary_path,
    case_id = ARGS

const MRST_YEAR_SECONDS = 365.2425*24*60*60
const SELECTED_STEPS = [78, 210]
const EXPECTED_CELLS = 2_165_082
const EXPECTED_FAULT_REGIONS = 522
const EXPECTED_FAULT_CELLS = 150_597
const EXPECTED_SPECIFIC_FAULT_CELLS = 32_190
const EXPECTED_STRATIGRAPHY_CELLS = 828_240
const EXPECTED_DRAINAGE_REGIONS = 527
const EXPECTED_TOTAL_SGOF_TABLES = 1_054
const EXPECTED_HYSTERESIS_S_MIN = 0.05
const EXPECTED_PC_ENTRY_SG_MAX = 1.0e-4

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
    hysteresis_s_min = EXPECTED_HYSTERESIS_S_MIN,
    use_mrst_transmissibility = false,
    fault_saturation_domain_mode = "input",
    fault_pc_entry_treatment = "plateau",
    fault_pc_entry_sg_max = EXPECTED_PC_ENTRY_SG_MAX,
    explicit_fault_hysteresis_mode = "reservoir",
    ds_max = 0.05
)

reservoir_model = case.model.models[:Reservoir]
JutulDarcy.hysteresis_is_active(reservoir_model[:RelativePermeabilities]) ||
    error("Imported model does not have active hysteresis.")

grid = mrst["G"]
regions = mrst["rock"]["regions"]
state0 = mrst["state0"]
fault_summary = mrst["fault_saturation_domain_summary"]
pc_summary = fault_summary["pc_entry_treatment"]
nc = Int(round(grid["cells"]["num"]))
specific = MAT.matread(specific_path)

nc == EXPECTED_CELLS || error("Expected $EXPECTED_CELLS cells, found $nc.")
fault_summary["fault_regions"] == EXPECTED_FAULT_REGIONS ||
    error("Unexpected fault saturation-region count.")
fault_summary["drainage_regions"] == EXPECTED_DRAINAGE_REGIONS ||
    error("Unexpected drainage saturation-region count.")
fault_summary["sgof_tables"] == EXPECTED_TOTAL_SGOF_TABLES ||
    error("Unexpected total SGOF table count.")
fault_summary["hysteresis"] ==
    "reservoir_only_fault_drainage_duplicate" ||
    error("Fault regions are not drainage-equivalent under reservoir hysteresis.")
pc_summary["treatment"] == "plateau" ||
    error("Fault Pc plateau treatment is not active.")
pc_summary["adjusted_tables"] == EXPECTED_FAULT_REGIONS ||
    error("Expected all $EXPECTED_FAULT_REGIONS fault Pc tables to be adjusted.")
pc_summary["skipped_tables"] == 0 ||
    error("One or more fault Pc tables skipped plateau treatment.")
!haskey(mrst, "T") || error("MRST transmissibility unexpectedly present.")
!haskey(mrst, "T_all") || error("MRST half-transmissibility unexpectedly present.")

masks = mrst["masks"]
fault_region_flag = Int32.(vec(masks["isFaultCell"]) .!= 0)
stratigraphy_region_flag =
    Int32.(vec(masks["isSpecificStratigraphyCell"]) .!= 0)
length(fault_region_flag) == nc || error("Fault-region mask has the wrong length.")
length(stratigraphy_region_flag) == nc ||
    error("Stratigraphy-region mask has the wrong length.")
sum(fault_region_flag) == EXPECTED_FAULT_CELLS ||
    error("Unexpected complete fault-domain cell count.")
sum(stratigraphy_region_flag) == EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected stratigraphy-domain cell count.")
all((fault_region_flag .+ stratigraphy_region_flag) .<= 1) ||
    error("Fault and stratigraphy region flags overlap.")

fault_cells = sort(Int.(round.(vec(masks["fault_all_cells"]))))
findall(==(Int32(1)), fault_region_flag) == fault_cells ||
    error("Fault-region flag does not exactly match masks.fault_all_cells.")
specific_fault_cells =
    sort(Int.(round.(vec(specific["fault"]["cells"]))))
length(specific_fault_cells) == EXPECTED_SPECIFIC_FAULT_CELLS ||
    error("Unexpected geology-specific fault cell count.")
all(fault_region_flag[specific_fault_cells] .== 1) ||
    error("Geology-specific fault cells are not contained in the full fault flag.")

stratigraphy = specific["stratigraphy"]
stratigraphy_cells = Int.(round.(vec(stratigraphy["cells"])))
stratigraphy_ids =
    Int32.(round.(vec(stratigraphy["stratigraphic_unit_id"])))
length(stratigraphy_cells) == EXPECTED_STRATIGRAPHY_CELLS ||
    error("Unexpected stratigraphy-specific cell count.")
length(stratigraphy_ids) == length(stratigraphy_cells) ||
    error("Stratigraphic unit IDs do not align with stratigraphy cells.")
sort(unique(stratigraphy_ids)) == collect(Int32(1):Int32(21)) ||
    error("Expected stratigraphic unit IDs 1:21.")
findall(==(Int32(1)), stratigraphy_region_flag) ==
    sort(stratigraphy_cells) ||
    error("Stratigraphy flag does not exactly match the specific cell list.")
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
@assert isapprox(selected_years_raw[1], 50.0; atol = 1.0e-10, rtol = 0)
@assert isapprox(selected_years_raw[2], 1000.0; atol = 1.0e-10, rtol = 0)
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

function vtu_xml_header(path)
    lines = String[]
    open(path, "r") do io
        while !eof(io)
            line = readline(io)
            push!(lines, line)
            occursin("<AppendedData", line) && break
        end
    end
    return join(lines, '\n')
end

function cell_array_metadata(path)
    header = vtu_xml_header(path)
    occursin("NumberOfCells=\"$EXPECTED_CELLS\"", header) ||
        error("$path does not declare $EXPECTED_CELLS cells.")
    cell_data_match = match(r"<CellData>(.*?)</CellData>"s, header)
    isnothing(cell_data_match) &&
        error("$path does not contain a CellData section.")
    metadata = Dict{String, NamedTuple}()
    for item in eachmatch(
            r"<DataArray\b[^>]*>",
            cell_data_match.captures[1]
        )
        tag = item.match
        name_match = match(r"\bName=\"([^\"]+)\"", tag)
        type_match = match(r"\btype=\"([^\"]+)\"", tag)
        isnothing(name_match) && error("A CellData array is missing Name.")
        isnothing(type_match) && error("A CellData array is missing type.")
        name = name_match.captures[1]
        haskey(metadata, name) &&
            error("Duplicate CellData array name: $name")
        component_match =
            match(r"\bNumberOfComponents=\"([^\"]+)\"", tag)
        components = isnothing(component_match) ?
            1 : parse(Int, component_match.captures[1])
        metadata[name] = (
            type = type_match.captures[1],
            components = components
        )
    end
    return metadata
end

expected_initial_arrays = Set([
    "Pressure",
    "Saturations_1",
    "Saturations_2",
    "Porosity",
    "Permeability_1",
    "Permeability_2",
    "Permeability_3",
    "Permeability_4",
    "Permeability_5",
    "Permeability_6",
    "sat_region",
    "rock_region",
    "imbi_region",
    "fault_region_flag",
    "stratigraphy_region_flag",
    "stratigraphic_unit_id"
])
expected_state_arrays = Set([
    "Pressure",
    "dP",
    "Saturations_1",
    "Saturations_2",
    "Rs",
    "sat_region",
    "rock_region",
    "imbi_region",
    "fault_region_flag",
    "stratigraphy_region_flag",
    "stratigraphic_unit_id"
])

initial_metadata = cell_array_metadata(initial_path)
Set(keys(initial_metadata)) == expected_initial_arrays ||
    error("Initial VTU cell arrays do not match the compact geology format.")
length(initial_metadata) == length(expected_initial_arrays) ||
    error("Initial VTU has duplicate or missing cell arrays.")
for path in state_paths
    state_metadata = cell_array_metadata(path)
    Set(keys(state_metadata)) == expected_state_arrays ||
        error("$path cell arrays do not match the compact geology format.")
    length(state_metadata) == length(expected_state_arrays) ||
        error("$path has duplicate or missing cell arrays.")
end
for path in vtu_paths
    metadata = cell_array_metadata(path)
    for name in (
            "fault_region_flag",
            "stratigraphy_region_flag",
            "stratigraphic_unit_id"
        )
        metadata[name].type == "Int32" ||
            error("$path: $name must be exported as Int32.")
        metadata[name].components == 1 ||
            error("$path: $name must be a one-component cell array.")
    end
end

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
fault_region_sha256 = int32_sha256(fault_region_flag)
stratigraphy_region_sha256 =
    int32_sha256(stratigraphy_region_flag)
stratigraphic_unit_sha256 =
    int32_sha256(stratigraphic_unit_id)

mkpath(dirname(summary_path))
open(summary_path, "w") do io
    println(io, "status=pass")
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
    println(io, "fault_region_cells=$(sum(fault_region_flag))")
    println(io, "specific_fault_cells=$(length(specific_fault_cells))")
    println(io, "stratigraphy_region_cells=$(sum(stratigraphy_region_flag))")
    println(io, "stratigraphic_unit_ids=1:21")
    println(io, "fault_region_flag_sha256=$fault_region_sha256")
    println(io, "stratigraphy_region_flag_sha256=$stratigraphy_region_sha256")
    println(io, "stratigraphic_unit_id_sha256=$stratigraphic_unit_sha256")
    println(io, "hysteresis_active=true")
    println(io, "hysteresis_s_min=$EXPECTED_HYSTERESIS_S_MIN")
    println(io, "fault_hysteresis=drainage_equivalent")
    println(io, "fault_pc_entry_treatment=plateau")
    println(io, "fault_pc_adjusted_tables=$(pc_summary["adjusted_tables"])")
    println(io, "transmissibility_source=JutulDarcy_grid_and_rock")
    println(io, "vtu_dir=$vtu_dir")
    println(io, "pvd_path=$pvd_path")
end

println(
    "STEP62_FOUR_GEOLOGY_HYST_PLATEAU_STANDARD_VTU_PASS " *
    "case=$case_id summary=$summary_path"
)
