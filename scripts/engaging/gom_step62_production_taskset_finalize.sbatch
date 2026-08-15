#!/bin/bash
#SBATCH --job-name=gom_s62_taskset_final
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Verify that all 49 immutable task sets form an exact 2,430-case campaign.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_TASKSET_WORKFLOW_REPO:?Set GOM_TASKSET_WORKFLOW_REPO.}"
: "${GOM_PRODUCTION_TASKSET_PLAN:?Set GOM_PRODUCTION_TASKSET_PLAN.}"
: "${GOM_PRODUCTION_TASKSET_SELECTION_DIR:?Set GOM_PRODUCTION_TASKSET_SELECTION_DIR.}"
: "${GOM_PRODUCTION_PARENT_SUBMISSION_ID:?Set GOM_PRODUCTION_PARENT_SUBMISSION_ID.}"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
verifier="$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_verify.py"
summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430
test "$(($(wc -l < "$GOM_PRODUCTION_TASKSET_PLAN") - 1))" -eq 49

result_dir="$gom_root/results/gom_step62_production_taskset_finalize_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

campaign_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
submission_parent="$campaign_parent/submissions"
submission_id="${GOM_PRODUCTION_PARENT_SUBMISSION_ID}_all2430_tasksets"
incoming="$submission_parent/.${submission_id}.tmp.${SLURM_JOB_ID}"
final="$submission_parent/$submission_id"
test ! -e "$incoming"
test ! -e "$final"
mkdir -p "$incoming/taskset_control" "$submission_parent"

printf 'task\tcase_key\tgeology_id\trealization_id\n' > "$incoming/CASE_INDEX.tsv"
printf 'taskset_index\ttaskset_id\tpurpose\tcase_count\tselection_sha256\tsha256sums_sha256\n' \
    > "$incoming/TASKSET_INDEX.tsv"

taskset_count=0
while IFS=$'\t' read -r taskset_index taskset_id purpose task_count selection_relative array_relative; do
    test "$taskset_index" != taskset_index || continue
    taskset="$campaign_parent/tasksets/$taskset_id"
    selection="$GOM_PRODUCTION_TASKSET_SELECTION_DIR/$(basename -- "$selection_relative")"
    validation="$incoming/taskset_control/${taskset_id}.json"
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$taskset" --selection "$selection" --json \
        > "$validation"
    tail -n +2 "$taskset/CASE_INDEX.tsv" >> "$incoming/CASE_INDEX.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$taskset_index" "$taskset_id" "$purpose" "$task_count" \
        "$(sha256sum "$selection" | awk '{print $1}')" \
        "$(sha256sum "$taskset/SHA256SUMS" | awk '{print $1}')" \
        >> "$incoming/TASKSET_INDEX.tsv"
    taskset_count=$((taskset_count + 1))
done < "$GOM_PRODUCTION_TASKSET_PLAN"
test "$taskset_count" -eq 49

"$production_python" - "$incoming/CASE_INDEX.tsv" "$GOM_PRODUCTION_CASE_COUNT" <<'PY'
import csv
import sys

path, expected_text = sys.argv[1:]
expected = int(expected_text)
with open(path, newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
tasks = [int(row["task"]) for row in rows]
case_keys = [row["case_key"] for row in rows]
if len(rows) != expected:
    raise SystemExit(f"campaign index has {len(rows)} rows, expected {expected}")
if sorted(tasks) != list(range(1, expected + 1)):
    raise SystemExit("task-set union does not cover every campaign task exactly once")
if len(set(case_keys)) != expected:
    raise SystemExit("task-set union contains duplicate case keys")
PY

cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" "$incoming/campaign.toml.sha256.original"
cp -- "$GOM_PRODUCTION_TASKSET_PLAN" "$incoming/taskset_plan.tsv"
printf '%s\n' \
    "status=pass" \
    "submission_id=$submission_id" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
    "case_count=2430" \
    "taskset_count=49" \
    "reusable_canary_case_count=50" \
    "remaining_production_case_count=2380" \
    "all_taskset_control_planes_validated=true" \
    "all_campaign_tasks_present_exactly_once=true" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$incoming/CAMPAIGN_COMPLETE"
(
    cd "$incoming"
    find . -type f ! -name SHA256SUMS.txt ! -name PASS -print0 | \
        LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
printf 'PASS\n' > "$incoming/PASS"
mv -- "$incoming" "$final"

printf '%s\n' \
    "status=pass" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_count=2430" \
    "taskset_count=49" \
    "completion_path=$final" \
    > "$result_dir/finalize_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
