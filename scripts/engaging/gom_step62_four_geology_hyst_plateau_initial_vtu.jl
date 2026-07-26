using JutulDarcy
import MAT
import SHA

length(ARGS) == 6 || error(
    "Usage: gom_step62_four_geology_hyst_plateau_initial_vtu.jl " *
    "COMMON_MAT SPECIFIC_MAT VTU_DIR PREFIX SUMMARY_PATH CASE_ID"
)
common_path, specific_path, vtu_dir, prefix, summary_path, case_id = ARGS

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
    error("Unexpected stratigraphy-region cell count.")
all((fault_region_flag .== 0) .| (fault_region_flag .== 1)) ||
    error("Fault-region flag is not binary.")
all((stratigraphy_region_flag .== 0) .|
    (stratigraphy_region_flag .== 1)) ||
    error("Stratigraphy-region flag is not binary.")
all((fault_region_flag .+ stratigraphy_region_flag) .<= 1) ||
    error("Fault and stratigraphy region flags overlap.")

fault_cells = sort(Int.(round.(vec(masks["fault_all_cells"]))))
length(fault_cells) == EXPECTED_FAULT_CELLS ||
    error("Unexpected common fault-domain cell count.")
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
JutulDarcy.export_initial_step0_vtu(
    specific_path,
    mrst;
    outdir = vtu_dir,
    prefix = prefix,
    vtu_vars = [:Pressure, :Saturations, :Porosity, :Permeability],
    split_matrices = true,
    write_regions = true,
    extra_cell_data = extra_cell_data
)
vtu_path = joinpath(vtu_dir, "$(prefix)_0001.vtu")
isfile(vtu_path) || error("Initial-condition VTU was not written.")

pvd_path = JutulDarcy.write_pvd_collection(
    [vtu_path],
    [0.0];
    outdir = vtu_dir,
    prefix = prefix
)
isfile(pvd_path) || error("Initial-condition PVD collection was not written.")

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

expected_arrays = Set([
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
array_metadata = cell_array_metadata(vtu_path)
Set(keys(array_metadata)) == expected_arrays ||
    error("Initial VTU cell arrays do not match the established compact format.")
length(array_metadata) == length(expected_arrays) ||
    error("Initial VTU must contain exactly $(length(expected_arrays)) cell arrays.")
for name in (
        "fault_region_flag",
        "stratigraphy_region_flag",
        "stratigraphic_unit_id"
    )
    array_metadata[name].type == "Int32" ||
        error("$name must be exported as Int32.")
    array_metadata[name].components == 1 ||
        error("$name must be a one-component cell array.")
end

int32_sha256(values::Vector{Int32}) =
    bytes2hex(SHA.sha256(reinterpret(UInt8, values)))
fault_region_sha256 = int32_sha256(fault_region_flag)
stratigraphy_region_sha256 =
    int32_sha256(stratigraphy_region_flag)
stratigraphic_unit_sha256 =
    int32_sha256(stratigraphic_unit_id)

pvd_text = read(pvd_path, String)
occursin("file=\"$(basename(vtu_path))\"", pvd_text) ||
    error("PVD collection does not reference the initial VTU.")
occursin("timestep=\"0\"", pvd_text) ||
    error("PVD collection does not assign the initial VTU to time zero.")

mkpath(dirname(summary_path))
open(summary_path, "w") do io
    println(io, "status=pass")
    println(io, "case_id=$case_id")
    println(io, "grid=step62")
    println(io, "resolution_slices=87")
    println(io, "cells=$nc")
    println(io, "initial_state=true")
    println(io, "time_years=0")
    println(io, "parameter_set=standard_compact_plus_geology_indicators")
    println(io, "additional_parameters=geology_indicators_only")
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
    println(io, "vtu_path=$vtu_path")
    println(io, "pvd_path=$pvd_path")
end

println(
    "STEP62_FOUR_GEOLOGY_HYST_PLATEAU_INITIAL_VTU_PASS " *
    "case=$case_id summary=$summary_path"
)
