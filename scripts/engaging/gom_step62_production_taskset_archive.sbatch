#!/bin/bash
#SBATCH --job-name=gom_s62_taskset_archive
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Promote one explicit, possibly noncontiguous task set to durable storage.
# Every case is resolved against the checksum-audited campaign, copied from its
# recorded Slurm stage, checksummed, verified, and only then atomically renamed.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set immutable JUTULDARCY_COMBINED_REPO.}"
: "${GOM_TASKSET_WORKFLOW_REPO:?Set GOM_TASKSET_WORKFLOW_REPO.}"
: "${GOM_PRODUCTION_CHECK_JOB_ID:?Set GOM_PRODUCTION_CHECK_JOB_ID.}"
: "${GOM_PRODUCTION_TASKSET_ID:?Set GOM_PRODUCTION_TASKSET_ID.}"
: "${GOM_PRODUCTION_TASKSET_SELECTION:?Set GOM_PRODUCTION_TASKSET_SELECTION.}"
: "${GOM_PRODUCTION_SOURCE_MAP:?Set GOM_PRODUCTION_SOURCE_MAP.}"
: "${GOM_PRODUCTION_SUBMISSION_ID:?Set GOM_PRODUCTION_SUBMISSION_ID.}"

[[ "$GOM_PRODUCTION_CHECK_JOB_ID" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_TASKSET_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
[[ "$GOM_PRODUCTION_SUBMISSION_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
test -s "$GOM_PRODUCTION_TASKSET_SELECTION"
test -s "$GOM_PRODUCTION_SOURCE_MAP"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
verifier="$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_verify.py"
command -v "$production_python" >/dev/null
test -f "$resolver"
test -f "$verifier"

summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = phase1_2430
test "$GOM_PRODUCTION_PHYSICS_PROFILE" = sandpc_effective_globalplateau_v1

result_dir="$gom_root/results/gom_step62_production_taskset_archive_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

archive_root="$GOM_PRODUCTION_ARCHIVE_ROOT"
campaign_parent="$archive_root/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
incoming_parent="$archive_root/.incoming"
incoming="$incoming_parent/${GOM_PRODUCTION_CAMPAIGN_ID}_${GOM_PRODUCTION_TASKSET_ID}_archivejob${SLURM_JOB_ID}"
final="$campaign_parent/tasksets/$GOM_PRODUCTION_TASKSET_ID"
mkdir -p "$incoming_parent" "$campaign_parent/tasksets" "$campaign_parent/submissions"

selection_sha256="$(sha256sum "$GOM_PRODUCTION_TASKSET_SELECTION" | awk '{print $1}')"
source_map_sha256="$(sha256sum "$GOM_PRODUCTION_SOURCE_MAP" | awk '{print $1}')"
case_count="$(($(wc -l < "$GOM_PRODUCTION_TASKSET_SELECTION") - 1))"
test "$case_count" -ge 1
test "$case_count" -le "$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE"

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_PRODUCTION_CHECK_JOB_ID}"
test -f "$check_root/PASS"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
grep -Fxq "manifest=$GOM_PRODUCTION_MANIFEST" \
    "$check_root/campaign_check_summary.txt"
test "$(sha256sum "$check_root/campaign.toml" | awk '{print $1}')" = \
    "$GOM_PRODUCTION_MANIFEST_SHA256"
cmp --silent "$check_root/campaign.toml" "$GOM_PRODUCTION_MANIFEST"

# Validate the complete source map and campaign pairing once before copying any
# large payload. The campaign summary above has already verified every input
# MAT checksum, so this step only checks identities and output-root contracts.
"$production_python" - \
    "$GOM_PRODUCTION_MANIFEST" \
    "$GOM_PRODUCTION_TASKSET_SELECTION" \
    "$GOM_PRODUCTION_SOURCE_MAP" <<'PY'
import csv
import pathlib
import sys
import tomllib

manifest_path, selection_path, source_map_path = sys.argv[1:]
with open(manifest_path, "rb") as handle:
    campaign = tomllib.load(handle)
with open(selection_path, newline="", encoding="utf-8") as handle:
    selected = list(csv.DictReader(handle, delimiter="\t"))
with open(source_map_path, newline="", encoding="utf-8") as handle:
    sources = list(csv.DictReader(handle, delimiter="\t"))
required_selection = {"task", "case_key", "geology_id", "realization_id"}
required_source = {
    "task", "preflight_root", "full_root", "vtu_root",
    "preflight_job", "full_job", "vtu_job",
}
if not selected or not required_selection.issubset(selected[0]):
    raise SystemExit("task-set selection has an unexpected schema")
if not sources or not required_source.issubset(sources[0]):
    raise SystemExit("task-set source map has an unexpected schema")
source_by_task = {}
for row in sources:
    task = int(row["task"])
    if task in source_by_task:
        raise SystemExit(f"duplicate source-map task {task}")
    for field in ("preflight_job", "full_job", "vtu_job"):
        if not row[field].isdigit():
            raise SystemExit(f"non-numeric {field} for task {task}")
    for field in ("preflight_root", "full_root", "vtu_root"):
        if not pathlib.Path(row[field]).is_absolute():
            raise SystemExit(f"non-absolute {field} for task {task}")
    source_by_task[task] = row
tasks = []
for row in selected:
    task = int(row["task"])
    if task in tasks or not 1 <= task <= len(campaign["cases"]):
        raise SystemExit(f"invalid or duplicate selected task {task}")
    case = campaign["cases"][task - 1]
    expected = {
        "case_key": str(case["case_key"]),
        "geology_id": str(case["geology_id"]),
        "realization_id": str(case["realization_id"]),
    }
    if {key: row[key] for key in expected} != expected:
        raise SystemExit(f"campaign identity mismatch for task {task}")
    tasks.append(task)
if set(tasks) != set(source_by_task):
    raise SystemExit("source-map tasks do not exactly equal selected tasks")
PY

copy_log_if_present() {
    path="$1"
    destination="$2"
    if test -f "$path"; then
        cp -- "$path" "$destination/"
    fi
}

compact_atomic_rows() {
    production_dir="$1"
    inventory="$production_dir/ATOMIC_ROW_ARCHIVES.tsv"
    printf 'source_directory\tfile_count\tarchive\tarchive_bytes\n' > "$inventory"
    for specification in \
            rows:tsv \
            retention:tsv \
            qoi/rows:tsv \
            qoi_schema4/rows:tsv \
            qoi_schema4/spatial_rows:bin; do
        relative="${specification%:*}"
        extension="${specification##*:}"
        source_dir="$production_dir/$relative"
        test -d "$source_dir" || continue
        file_count="$(find "$source_dir" -maxdepth 1 -type f -name "step_*.$extension" | wc -l)"
        test "$file_count" -eq 210
        archive_name="${relative//\//_}.tar.gz"
        archive_path="$production_dir/$archive_name"
        parent="$(dirname -- "$source_dir")"
        base="$(basename -- "$source_dir")"
        tar -czf "$archive_path" -C "$parent" "$base"
        archived_count="$(tar -tzf "$archive_path" | grep -c "/step_[0-9][0-9]*\\.$extension$")"
        test "$archived_count" -eq "$file_count"
        printf '%s\t%s\t%s\t%s\n' \
            "$relative" "$file_count" "$archive_name" \
            "$(stat -c '%s' "$archive_path")" >> "$inventory"
        resolved_source="$(realpath -- "$source_dir")"
        resolved_production="$(realpath -- "$production_dir")"
        case "$resolved_source" in
            "$resolved_production"/*) ;;
            *) echo "Refusing unsafe staged-row removal: $resolved_source" >&2; exit 1 ;;
        esac
        rm -rf -- "$resolved_source"
    done
}

archive_already_present=false
if test -e "$final"; then
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$final" \
        --selection "$GOM_PRODUCTION_TASKSET_SELECTION" \
        --json > "$result_dir/existing_taskset_verification.json"
    archive_already_present=true
else
    test ! -e "$incoming"
    mkdir -p "$incoming/payload/cases" \
        "$incoming/payload/stages/campaign_check" \
        "$incoming/payload/slurm_logs"
    cp -- "$check_root/campaign_check_summary.txt" \
        "$check_root/validation.txt" \
        "$check_root/PASS" \
        "$incoming/payload/stages/campaign_check/"
    cp -- "$GOM_PRODUCTION_TASKSET_SELECTION" "$incoming/TASKSET_SELECTION.tsv"
    cp -- "$GOM_PRODUCTION_SOURCE_MAP" "$incoming/SOURCE_MAP.tsv"
    printf 'task\tcase_key\tgeology_id\trealization_id\n' > "$incoming/CASE_INDEX.tsv"

    declare -A preflight_roots full_roots vtu_roots preflight_jobs full_jobs vtu_jobs
    while IFS=$'\t' read -r task preflight_root full_root vtu_root preflight_job full_job vtu_job rest; do
        test "$task" != task || continue
        preflight_roots[$task]="$preflight_root"
        full_roots[$task]="$full_root"
        vtu_roots[$task]="$vtu_root"
        preflight_jobs[$task]="$preflight_job"
        full_jobs[$task]="$full_job"
        vtu_jobs[$task]="$vtu_job"
    done < "$GOM_PRODUCTION_SOURCE_MAP"

    while IFS=$'\t' read -r task case_key geology_id realization_id rest; do
        test "$task" != task || continue
        preflight_root="${preflight_roots[$task]}"
        full_root="${full_roots[$task]}"
        vtu_root="${vtu_roots[$task]}"
        preflight_job="${preflight_jobs[$task]}"
        full_job="${full_jobs[$task]}"
        vtu_job="${vtu_jobs[$task]}"
        preflight_case="$preflight_root/$case_key"
        full_tag="gom_step62_effective_pc_global_plateau_${case_key}_sandpc_effective_globalplateau_v1_full1000y_job${full_job}_${task}"
        full_case="$full_root/$full_tag"
        vtu_case="$vtu_root/$case_key"

        test -f "$preflight_case/PASS"
        test -f "$full_case/PASS"
        test -f "$vtu_case/PASS"
        grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
        grep -Fxq 'initial_pressure_convention=liquid_reference' "$preflight_case/preflight_summary.txt"
        grep -Fxq 'initial_pressure_max_abs_difference_from_common_pa=0.0' "$preflight_case/preflight_summary.txt"
        grep -Fxq 'status=pass' "$full_case/production_summary.txt"
        grep -Fxq "case_key=$case_key" "$full_case/production_summary.txt"
        grep -Fxq 'steps_completed=210' "$full_case/production_summary.txt"
        grep -Fxq 'retained_restart_steps=51,78,110,210' "$full_case/production_summary.txt"
        grep -Fxq 'production_qoi_mode=required' "$full_case/production_summary.txt"
        grep -Fxq 'qoi_schema4_validated=true' "$full_case/final_state_summary.txt"
        grep -Fxq 'status=pass' "$full_case/runtime_diagnostics.txt"
        awk -F '\t' '
            NR == 1 {
                for (column = 1; column <= NF; column++) {
                    if ($column == "mass_balance_relative_residual") target = column
                }
                if (!target) exit 2
                next
            }
            { final = $target }
            END {
                if (NR < 2 || final == "") exit 3
                value = final + 0.0
                if (value < 0.0) value = -value
                if (value > 1.0e-3) exit 4
            }
        ' "$full_case/restart/production_output/qoi_schema4/qoi_schema4_steps.tsv"
        grep -Fxq 'status=pass' "$vtu_case/export_summary.txt"
        grep -Fxq 'vtu_files=3' "$vtu_case/export_summary.txt"
        (
            cd "$full_case"
            sha256sum --check RETAINED_RESTART_SHA256.txt
            sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
        )
        (cd "$vtu_case" && sha256sum --check VTU_SHA256.txt)

        destination="$incoming/payload/cases/$case_key"
        mkdir -p "$destination"
        cp -a -- "$preflight_case" "$destination/preflight"
        cp -a -- "$full_case" "$destination/production"
        cp -a -- "$vtu_case" "$destination/vtu"
        if test "$GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS" = true; then
            compact_atomic_rows "$destination/production/restart/production_output"
        fi
        printf '%s\t%s\t%s\t%s\n' \
            "$task" "$case_key" "$geology_id" "$realization_id" \
            >> "$incoming/CASE_INDEX.tsv"

        copy_log_if_present "$gom_root/logs/gom_s62_epc_pf-${preflight_job}_${task}.out" "$incoming/payload/slurm_logs"
        copy_log_if_present "$gom_root/logs/gom_s62_epc_pf-${preflight_job}_${task}.err" "$incoming/payload/slurm_logs"
        copy_log_if_present "$gom_root/logs/gom_s62_epc_full-${full_job}_${task}.out" "$incoming/payload/slurm_logs"
        copy_log_if_present "$gom_root/logs/gom_s62_epc_full-${full_job}_${task}.err" "$incoming/payload/slurm_logs"
        copy_log_if_present "$gom_root/logs/gom_s62_epc_vtu-${vtu_job}_${task}.out" "$incoming/payload/slurm_logs"
        copy_log_if_present "$gom_root/logs/gom_s62_epc_vtu-${vtu_job}_${task}.err" "$incoming/payload/slurm_logs"
    done < "$GOM_PRODUCTION_TASKSET_SELECTION"

    test "$(($(wc -l < "$incoming/CASE_INDEX.tsv") - 1))" -eq "$case_count"
    cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
    cp -- "$GOM_PRODUCTION_MANIFEST.sha256" "$incoming/campaign.toml.sha256.original"
    git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD > "$incoming/JUTULDARCY_COMMIT.txt"
    if test -n "${GOM_PRODUCTION_TASKSET_AUDIT_DIR:-}"; then
        test -f "$GOM_PRODUCTION_TASKSET_AUDIT_DIR/PASS"
        cp -a -- "$GOM_PRODUCTION_TASKSET_AUDIT_DIR" "$incoming/audit"
    fi
    printf '%s\n' \
        "status=ready_for_promotion" \
        "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
        "taskset_id=$GOM_PRODUCTION_TASKSET_ID" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
        "taskset_selection_sha256=$selection_sha256" \
        "source_map_sha256=$source_map_sha256" \
        "case_count=$case_count" \
        "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
        "atomic_rows_compacted=$GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS" \
        "archive_job_id=$SLURM_JOB_ID" \
        "archive_started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$incoming/TASKSET_METADATA.txt"
    (
        cd "$incoming"
        find . -type f ! -name SHA256SUMS ! -name TASKSET_COMPLETE -print0 | \
            LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
        test -s SHA256SUMS
        sha256sum --check SHA256SUMS
    )
    sha256sums_sha256="$(sha256sum "$incoming/SHA256SUMS" | awk '{print $1}')"
    printf '%s\n' \
        "status=pass" \
        "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
        "taskset_id=$GOM_PRODUCTION_TASKSET_ID" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
        "taskset_selection_sha256=$selection_sha256" \
        "case_count=$case_count" \
        "all_payload_sha256_verified_before_atomic_promote=true" \
        "sha256sums_sha256=$sha256sums_sha256" \
        "promoted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$incoming/TASKSET_COMPLETE"
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$incoming" \
        --selection "$GOM_PRODUCTION_TASKSET_SELECTION" \
        --json > "$result_dir/staged_taskset_verification.json"
    mv -- "$incoming" "$final"
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$final" \
        --selection "$GOM_PRODUCTION_TASKSET_SELECTION" \
        --json > "$result_dir/promoted_taskset_verification.json"
fi

scratch_removed=false
if test "$GOM_PRODUCTION_ARCHIVE_REMOVE_VERIFIED_SCRATCH" = true; then
    declare -A preflight_roots full_roots vtu_roots full_jobs
    while IFS=$'\t' read -r task preflight_root full_root vtu_root preflight_job full_job vtu_job rest; do
        test "$task" != task || continue
        preflight_roots[$task]="$preflight_root"
        full_roots[$task]="$full_root"
        vtu_roots[$task]="$vtu_root"
        full_jobs[$task]="$full_job"
    done < "$GOM_PRODUCTION_SOURCE_MAP"
    while IFS=$'\t' read -r task case_key rest; do
        test "$task" != task || continue
        full_tag="gom_step62_effective_pc_global_plateau_${case_key}_sandpc_effective_globalplateau_v1_full1000y_job${full_jobs[$task]}_${task}"
        for target_and_root in \
            "${preflight_roots[$task]}/$case_key|${preflight_roots[$task]}" \
            "${full_roots[$task]}/$full_tag|${full_roots[$task]}" \
            "${vtu_roots[$task]}/$case_key|${vtu_roots[$task]}"; do
            target="${target_and_root%%|*}"
            allowed_root="${target_and_root#*|}"
            test -d "$target" || continue
            test -f "$target/PASS"
            resolved_target="$(realpath -- "$target")"
            resolved_allowed="$(realpath -- "$allowed_root")"
            case "$resolved_target" in
                "$resolved_allowed"/*) ;;
                *) echo "Refusing unsafe scratch removal: $resolved_target" >&2; exit 1 ;;
            esac
            rm -rf -- "$resolved_target"
        done
    done < "$GOM_PRODUCTION_TASKSET_SELECTION"
    scratch_removed=true
fi

printf '%s\n' \
    "status=pass" \
    "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
    "taskset_id=$GOM_PRODUCTION_TASKSET_ID" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_count=$case_count" \
    "archive_path=$final" \
    "archive_already_present=$archive_already_present" \
    "scratch_removed=$scratch_removed" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/archive_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
