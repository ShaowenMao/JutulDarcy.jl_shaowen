using JutulDarcy
import SHA

include(joinpath(@__DIR__, "gom_step62_effective_pc_global_plateau_contract.jl"))
using .GoMStep62EffectivePcGlobalPlateauContract

length(ARGS) == 5 || error(
    "Usage: gom_step62_effective_pc_global_plateau_final_check.jl " *
    "RESTART_DIR SUMMARY_DIR OUTPUT_PATH CASE_KEY MANIFEST_SHA256"
)
restart_dir, summary_dir, output_path, expected_case_key,
    expected_manifest_sha256 = ARGS

const SANDPC_EXPECTED_STEPS = 210
const SANDPC_EXPECTED_REGIONS =
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_QOI_REPORTING_REGIONS
const SANDPC_EXPECTED_INTERFACES =
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_QOI_INTERFACES

function parse_key_values(path)
    isfile(path) && filesize(path) > 0 ||
        error("Required metadata file is missing or empty: $path")
    values = Dict{String, String}()
    for (line_number, line) in enumerate(readlines(path))
        parts = split(line, '='; limit = 2)
        length(parts) == 2 ||
            error("$path line $line_number is not key=value metadata.")
        haskey(values, parts[1]) &&
            error("$path contains duplicate key $(parts[1]).")
        values[parts[1]] = parts[2]
    end
    return values
end

function parse_tsv(path; expected_columns = nothing)
    isfile(path) && filesize(path) > 0 ||
        error("Required QoI file is missing or empty: $path")
    lines = readlines(path)
    length(lines) >= 2 || error("$path has no data rows.")
    header = String.(split(lines[1], '\t'; keepempty = true))
    length(unique(header)) == length(header) ||
        error("$path has duplicate columns.")
    if !isnothing(expected_columns)
        header == string.(expected_columns) ||
            error("$path has an unexpected column contract.")
    end
    rows = Dict{String, String}[]
    for (offset, line) in enumerate(lines[2:end])
        line_number = offset + 1
        values = String.(split(line, '\t'; keepempty = true))
        length(values) == length(header) ||
            error("$path line $line_number has the wrong field count.")
        push!(rows, Dict(header .=> values))
    end
    return header, rows
end

function validate_identity(row, label)
    parse(Int, row["schema_version"]) == 1 ||
        error("$label has the wrong schema version.")
    row["case_key"] == expected_case_key ||
        error("$label has the wrong case key.")
    lowercase(row["campaign_manifest_sha256"]) ==
        lowercase(expected_manifest_sha256) ||
        error("$label has the wrong campaign manifest SHA-256.")
end

function validate_time_row(row, step, expected_seconds, expected_years, label)
    parse(Int, row["step"]) == step ||
        error("$label has the wrong step.")
    observed_seconds = parse(Float64, row["time_seconds"])
    observed_years = parse(Float64, row["time_years"])
    isapprox(
        observed_seconds,
        expected_seconds;
        rtol = 1.0e-12,
        atol = 1.0e-6
    ) || error("$label has the wrong time_seconds.")
    isapprox(
        observed_years,
        expected_years;
        rtol = 1.0e-12,
        atol = 1.0e-10
    ) || error("$label has the wrong time_years.")
end

run_metadata = parse_key_values(joinpath(dirname(output_path), "RUN_METADATA.txt"))
run_metadata["physics_profile"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE ||
    error("Run metadata has the wrong physics profile.")
run_metadata["case_key"] == expected_case_key ||
    error("Run metadata has the wrong case key.")
lowercase(run_metadata["campaign_manifest_sha256"]) ==
    lowercase(expected_manifest_sha256) ||
    error("Run metadata has the wrong campaign manifest SHA-256.")
run_metadata["production_qoi_mode"] == "required" ||
    error("Run metadata does not require temporal QoI output.")
run_metadata["transmissibility_source"] == "JutulDarcy_grid_and_rock" ||
    error("Run metadata does not select Jutul transmissibility.")
run_metadata["fault_pc_entry_treatment"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PC_ENTRY_TREATMENT ||
    error("Run metadata has the wrong Pc entry treatment.")
run_metadata["pc_entry_scope"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PC_ENTRY_SCOPE ||
    error("Run metadata has the wrong Pc entry scope.")
run_metadata["pc_entry_rule"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PC_ENTRY_RULE ||
    error("Run metadata has the wrong Pc entry rule.")
run_metadata["pc_mapping_schema"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PC_MAPPING_SCHEMA ||
    error("Run metadata has the wrong effective-Pc mapping schema.")
run_metadata["pc_mapping_method"] ==
    GoMStep62EffectivePcGlobalPlateauContract.PC_MAPPING_METHOD ||
    error("Run metadata has the wrong effective-Pc mapping method.")
run_metadata["old_restart_reuse"] == "false" ||
    error("Run metadata does not prohibit old restart reuse.")

_, production_rows = parse_tsv(joinpath(summary_dir, "report_steps.tsv"))
length(production_rows) == SANDPC_EXPECTED_STEPS ||
    error("Production report_steps.tsv does not contain 210 rows.")
expected_seconds = Float64[]
expected_years = Float64[]
for (step, row) in enumerate(production_rows)
    parse(Int, row["step"]) == step ||
        error("Production report row $step has the wrong step.")
    row["case_key"] == expected_case_key ||
        error("Production report row $step has the wrong case key.")
    lowercase(row["campaign_manifest_sha256"]) ==
        lowercase(expected_manifest_sha256) ||
        error("Production report row $step has the wrong campaign hash.")
    push!(expected_seconds, parse(Float64, row["time_seconds"]))
    push!(expected_years, parse(Float64, row["time_years"]))
end
all(diff(expected_seconds) .> 0) ||
    error("Production report times are not strictly increasing.")

region_manifest_path = joinpath(summary_dir, "qoi_region_manifest.tsv")
_, region_manifest = parse_tsv(
    region_manifest_path;
    expected_columns = JutulDarcy.PRODUCTION_QOI_REGION_MANIFEST_COLUMNS
)
length(region_manifest) == SANDPC_EXPECTED_REGIONS ||
    error(
        "QoI region manifest does not contain " *
        "$SANDPC_EXPECTED_REGIONS regions."
    )
region_ids = Set{String}()
for row in region_manifest
    parse(Int, row["schema_version"]) == 1 ||
        error("QoI region manifest has the wrong schema.")
    push!(region_ids, row["region_id"])
    parse(Int, row["cell_count"]) > 0 ||
        error("QoI region $(row["region_id"]) is empty.")
    parse(Float64, row["pore_volume_m3"]) > 0 ||
        error("QoI region $(row["region_id"]) has non-positive pore volume.")
    occursin(r"^[0-9a-f]{64}$", row["cell_id_sha256"]) ||
        error("QoI region $(row["region_id"]) has an invalid cell digest.")
end
length(region_ids) == SANDPC_EXPECTED_REGIONS ||
    error("QoI region manifest contains duplicate region IDs.")

interface_manifest_path = joinpath(summary_dir, "qoi_interface_manifest.tsv")
_, interface_manifest = parse_tsv(
    interface_manifest_path;
    expected_columns = JutulDarcy.PRODUCTION_QOI_INTERFACE_MANIFEST_COLUMNS
)
length(interface_manifest) == SANDPC_EXPECTED_INTERFACES || error(
    "QoI interface manifest does not contain " *
    "$SANDPC_EXPECTED_INTERFACES interfaces."
)
interface_ids = Set{String}()
for row in interface_manifest
    parse(Int, row["schema_version"]) == 1 ||
        error("QoI interface manifest has the wrong schema.")
    push!(interface_ids, row["interface_id"])
    row["from_region_id"] in region_ids ||
        error("QoI interface $(row["interface_id"]) has an unknown source.")
    row["to_region_id"] in region_ids ||
        error("QoI interface $(row["interface_id"]) has an unknown target.")
    parse(Int, row["face_count"]) > 0 ||
        error("QoI interface $(row["interface_id"]) is empty.")
    occursin(r"^[0-9a-f]{64}$", row["face_sign_sha256"]) ||
        error("QoI interface $(row["interface_id"]) has an invalid digest.")
end
length(interface_ids) == SANDPC_EXPECTED_INTERFACES ||
    error("QoI interface manifest contains duplicate interface IDs.")
issubset(
    GoMStep62EffectivePcGlobalPlateauContract.REQUIRED_QOI_INTERFACES,
    interface_ids
) || error("One or more required QoI interface IDs is missing.")

_, global_rows = parse_tsv(
    joinpath(summary_dir, "leakage_global_steps.tsv");
    expected_columns = JutulDarcy.PRODUCTION_QOI_GLOBAL_COLUMNS
)
length(global_rows) == SANDPC_EXPECTED_STEPS ||
    error("leakage_global_steps.tsv does not contain 210 rows.")
for (step, row) in enumerate(global_rows)
    validate_identity(row, "Global QoI row $step")
    validate_time_row(
        row,
        step,
        expected_seconds[step],
        expected_years[step],
        "Global QoI row $step"
    )
end

_, regional_rows = parse_tsv(
    joinpath(summary_dir, "regional_co2_inventory_steps.tsv");
    expected_columns = JutulDarcy.PRODUCTION_QOI_REGION_COLUMNS
)
length(regional_rows) ==
    SANDPC_EXPECTED_STEPS*SANDPC_EXPECTED_REGIONS || error(
    "regional_co2_inventory_steps.tsv has the wrong row count."
)
for step in 1:SANDPC_EXPECTED_STEPS
    rows = @view regional_rows[
        ((step - 1)*SANDPC_EXPECTED_REGIONS + 1):
        (step*SANDPC_EXPECTED_REGIONS)
    ]
    Set(row["region_id"] for row in rows) == region_ids ||
        error("Regional QoI step $step has missing or duplicate region IDs.")
    for row in rows
        validate_identity(row, "Regional QoI step $step")
        validate_time_row(
            row,
            step,
            expected_seconds[step],
            expected_years[step],
            "Regional QoI step $step"
        )
    end
end

_, interface_rows = parse_tsv(
    joinpath(summary_dir, "interface_flux_steps.tsv");
    expected_columns = JutulDarcy.PRODUCTION_QOI_INTERFACE_COLUMNS
)
length(interface_rows) ==
    SANDPC_EXPECTED_STEPS*SANDPC_EXPECTED_INTERFACES ||
    error("interface_flux_steps.tsv has the wrong row count.")
for step in 1:SANDPC_EXPECTED_STEPS
    rows = @view interface_rows[
        ((step - 1)*SANDPC_EXPECTED_INTERFACES + 1):
        (step*SANDPC_EXPECTED_INTERFACES)
    ]
    Set(row["interface_id"] for row in rows) == interface_ids ||
        error("Interface QoI step $step has missing or duplicate IDs.")
    for row in rows
        validate_identity(row, "Interface QoI step $step")
        validate_time_row(
            row,
            step,
            expected_seconds[step],
            expected_years[step],
            "Interface QoI step $step"
        )
    end
end

_, case_summary_rows = parse_tsv(
    joinpath(summary_dir, "leakage_case_summary.tsv");
    expected_columns = JutulDarcy.PRODUCTION_QOI_CASE_SUMMARY_COLUMNS
)
length(case_summary_rows) == 1 ||
    error("leakage_case_summary.tsv must contain exactly one row.")
case_summary = only(case_summary_rows)
validate_identity(case_summary, "QoI case summary")
parse(Int, case_summary["final_step"]) == SANDPC_EXPECTED_STEPS ||
    error("QoI case summary has the wrong final step.")
isapprox(
    parse(Float64, case_summary["final_time_seconds"]),
    expected_seconds[end];
    rtol = 1.0e-12,
    atol = 1.0e-6
) || error("QoI case summary has the wrong final time.")

_, completion_rows =
    parse_tsv(joinpath(summary_dir, "QOI_OUTPUT_COMPLETE.tsv"))
length(completion_rows) == 1 ||
    error("QOI_OUTPUT_COMPLETE.tsv must contain exactly one row.")
completion = only(completion_rows)
parse(Int, completion["schema_version"]) == 1 ||
    error("QoI completion marker has the wrong schema.")
completion["status"] == "complete" ||
    error("QoI completion marker does not say complete.")
completion["case_key"] == expected_case_key ||
    error("QoI completion marker has the wrong case key.")
parse(Int, completion["schedule_steps"]) == SANDPC_EXPECTED_STEPS ||
    error("QoI completion marker has the wrong schedule length.")
completion["primary_label_sha256"] ==
    GoMStep62EffectivePcGlobalPlateauContract.EXPECTED_QOI_PRIMARY_LABEL_SHA256 ||
    error("QoI completion marker has the wrong primary-label digest.")
region_manifest_sha256 = bytes2hex(SHA.sha256(read(region_manifest_path)))
interface_manifest_sha256 =
    bytes2hex(SHA.sha256(read(interface_manifest_path)))
completion["region_manifest_sha256"] == region_manifest_sha256 ||
    error("QoI completion marker has the wrong region-manifest digest.")
completion["interface_manifest_sha256"] == interface_manifest_sha256 ||
    error("QoI completion marker has the wrong interface-manifest digest.")

qoi_row_dir = joinpath(summary_dir, "qoi", "rows")
qoi_ready_dir = joinpath(summary_dir, "qoi", "ready")
qoi_row_names = sort(filter(
    name -> occursin(r"^step_\d{6}\.tsv$", name),
    readdir(qoi_row_dir)
))
length(qoi_row_names) == SANDPC_EXPECTED_STEPS ||
    error("QoI bundle directory does not contain exactly 210 rows.")
isempty(readdir(qoi_ready_dir)) ||
    error("QoI ready directory is not empty after completion.")
for step in 1:SANDPC_EXPECTED_STEPS
    expected_name = "step_$(lpad(step, 6, '0')).tsv"
    qoi_row_names[step] == expected_name ||
        error("QoI bundle step sequence is incomplete.")
    _, bundle = parse_tsv(joinpath(qoi_row_dir, expected_name))
    length(bundle) ==
        1 + SANDPC_EXPECTED_REGIONS + SANDPC_EXPECTED_INTERFACES ||
        error("QoI bundle $expected_name has the wrong record count.")
    all(row -> row["case_key"] == expected_case_key, bundle) ||
        error("QoI bundle $expected_name has the wrong case key.")
    all(
        row -> lowercase(row["campaign_manifest_sha256"]) ==
            lowercase(expected_manifest_sha256),
        bundle
    ) || error("QoI bundle $expected_name has the wrong campaign hash.")
    all(row -> parse(Int, row["step"]) == step, bundle) ||
        error("QoI bundle $expected_name has the wrong step.")
    count(row -> row["record_type"] == "global", bundle) == 1 ||
        error("QoI bundle $expected_name lacks one global row.")
    Set(
        row["region_id"]
        for row in bundle if row["record_type"] == "region"
    ) == region_ids ||
        error("QoI bundle $expected_name has wrong region IDs.")
    Set(
        row["interface_id"]
        for row in bundle if row["record_type"] == "interface"
    ) == interface_ids ||
        error("QoI bundle $expected_name has wrong interface IDs.")
end

# Retain every established state, hysteresis, schedule, and production-row
# check from the accepted production validator.
include(joinpath(@__DIR__, "gom_step62_production_final_check.jl"))

open(output_path, "a") do io
    println(io, "physics_profile=$(GoMStep62EffectivePcGlobalPlateauContract.PHYSICS_PROFILE)")
    println(io, "production_qoi_mode=required")
    println(io, "qoi_region_rows=$(length(regional_rows))")
    println(io, "qoi_interface_rows=$(length(interface_rows))")
    println(io, "qoi_global_rows=$(length(global_rows))")
    println(io, "qoi_regions=$(length(region_ids))")
    println(io, "qoi_interfaces=$(length(interface_ids))")
    println(io, "qoi_region_manifest_sha256=$region_manifest_sha256")
    println(io, "qoi_interface_manifest_sha256=$interface_manifest_sha256")
end

println(
    "STEP62_EFFECTIVE_PC_GLOBAL_PLATEAU_QOI_FINAL_CHECK_PASS " *
    "case=$expected_case_key summary=$output_path"
)
