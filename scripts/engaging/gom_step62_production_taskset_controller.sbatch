#!/bin/bash
#SBATCH --job-name=gom_s62_taskset_ctl
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Advance exactly one 50-case task set in one rolling lane. The next controller
# in this lane is submitted only after the task set has been durably promoted.
# Multiple lanes therefore overlap slow task sets without growing an unbounded
# Slurm queue or weakening archive backpressure.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_TASKSET_WORKFLOW_REPO:?Set GOM_TASKSET_WORKFLOW_REPO.}"
: "${GOM_PRODUCTION_CHECK_JOB_ID:?Set GOM_PRODUCTION_CHECK_JOB_ID.}"
: "${GOM_PRODUCTION_TASKSET_PLAN:?Set GOM_PRODUCTION_TASKSET_PLAN.}"
: "${GOM_PRODUCTION_TASKSET_SELECTION_DIR:?Set GOM_PRODUCTION_TASKSET_SELECTION_DIR.}"
: "${GOM_PRODUCTION_CANARY_TASKSET:?Set GOM_PRODUCTION_CANARY_TASKSET.}"
: "${GOM_PRODUCTION_PARENT_SUBMISSION_ID:?Set GOM_PRODUCTION_PARENT_SUBMISSION_ID.}"
: "${GOM_PRODUCTION_NEXT_TASKSET_INDEX:?Set GOM_PRODUCTION_NEXT_TASKSET_INDEX.}"

[[ "$GOM_PRODUCTION_CHECK_JOB_ID" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_NEXT_TASKSET_INDEX" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_PARENT_SUBMISSION_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
test -s "$GOM_PRODUCTION_TASKSET_PLAN"
test -d "$GOM_PRODUCTION_TASKSET_SELECTION_DIR"

taskset_stride="${GOM_PRODUCTION_TASKSET_STRIDE:-1}"
lane_count="${GOM_PRODUCTION_LANE_COUNT:-1}"
lane_index="${GOM_PRODUCTION_LANE_INDEX:-1}"
lane_start_index="${GOM_PRODUCTION_LANE_START_INDEX:-$GOM_PRODUCTION_NEXT_TASKSET_INDEX}"
[[ "$taskset_stride" =~ ^[1-9][0-9]*$ ]]
[[ "$lane_count" =~ ^[1-9][0-9]*$ ]]
[[ "$lane_index" =~ ^[1-9][0-9]*$ ]]
[[ "$lane_start_index" =~ ^[1-9][0-9]*$ ]]
test "$lane_index" -le "$lane_count"
test "$taskset_stride" -eq "$lane_count"
test "$GOM_PRODUCTION_NEXT_TASKSET_INDEX" -ge "$lane_start_index"
test "$((
    (GOM_PRODUCTION_NEXT_TASKSET_INDEX - lane_start_index) % taskset_stride
))" -eq 0

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
verifier="$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_verify.py"
summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430

canary_selection="$GOM_PRODUCTION_TASKSET_SELECTION_DIR/taskset_0001.tsv"
test -s "$canary_selection"
"$production_python" "$verifier" \
    --manifest "$GOM_PRODUCTION_MANIFEST" \
    --taskset "$GOM_PRODUCTION_CANARY_TASKSET" \
    --selection "$canary_selection"

plan_count="$(($(wc -l < "$GOM_PRODUCTION_TASKSET_PLAN") - 1))"
test "$plan_count" -eq 49
index="$GOM_PRODUCTION_NEXT_TASKSET_INDEX"

common_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST"
controller_common="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_TASKSET_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$GOM_PRODUCTION_CHECK_JOB_ID,GOM_PRODUCTION_TASKSET_PLAN=$GOM_PRODUCTION_TASKSET_PLAN,GOM_PRODUCTION_TASKSET_SELECTION_DIR=$GOM_PRODUCTION_TASKSET_SELECTION_DIR,GOM_PRODUCTION_CANARY_TASKSET=$GOM_PRODUCTION_CANARY_TASKSET,GOM_PRODUCTION_PARENT_SUBMISSION_ID=$GOM_PRODUCTION_PARENT_SUBMISSION_ID,GOM_PRODUCTION_TASKSET_STRIDE=$taskset_stride,GOM_PRODUCTION_LANE_COUNT=$lane_count,GOM_PRODUCTION_LANE_INDEX=$lane_index,GOM_PRODUCTION_LANE_START_INDEX=$lane_start_index"

if test "$index" -gt "$plan_count"; then
    sbatch --parsable --kill-on-invalid-dep=yes \
        --export="$controller_common" \
        "$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_lane_complete.sbatch"
    exit 0
fi

plan_row="$(awk -F '\t' -v wanted="$index" 'NR > 1 && $1 == wanted {print; found=1} END {if (!found) exit 1}' "$GOM_PRODUCTION_TASKSET_PLAN")"
IFS=$'\t' read -r taskset_index taskset_id purpose task_count selection_relative array_relative <<< "$plan_row"
test "$taskset_index" -eq "$index"
test "$purpose" = remaining_production
test "$task_count" -ge 1
test "$task_count" -le 50
selection="$GOM_PRODUCTION_TASKSET_SELECTION_DIR/$(basename -- "$selection_relative")"
array_file="$GOM_PRODUCTION_TASKSET_SELECTION_DIR/$(basename -- "$array_relative")"
test -s "$selection"
test -s "$array_file"
array_spec="$(tr -d '[:space:]' < "$array_file")"
test -n "$array_spec"
test "$(tr ',' '\n' < "$array_file" | sed '/^$/d' | wc -l)" -eq "$task_count"

campaign_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
durable="$campaign_parent/tasksets/$taskset_id"
next_index=$((index + taskset_stride))
if test -e "$durable"; then
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$durable" --selection "$selection"
    sbatch --parsable --kill-on-invalid-dep=yes \
        --export="$controller_common,GOM_PRODUCTION_NEXT_TASKSET_INDEX=$next_index" \
        "$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_controller.sbatch"
    exit 0
fi

submission_id="${GOM_PRODUCTION_PARENT_SUBMISSION_ID}_${taskset_id}"
submission_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/taskset_submissions/$GOM_PRODUCTION_PARENT_SUBMISSION_ID"
mkdir -p "$submission_parent" "$gom_root/submissions"
receipt="$submission_parent/${taskset_id}.txt"
source_map="$submission_parent/${taskset_id}_source_map.tsv"
test ! -e "$receipt"
test ! -e "$source_map"

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if test "$submission_complete" != true && test "${#submitted_jobs[@]}" -gt 0; then
        scancel "${submitted_jobs[@]}" || true
    fi
    return "$exit_code"
}
trap cancel_partial_dag EXIT
submit_job() {
    raw_id="$(sbatch --parsable "$@")"
    job_id="${raw_id%%;*}"
    [[ "$job_id" =~ ^[0-9]+$ ]]
    submitted_jobs+=("$job_id")
    submitted_job_id="$job_id"
}

submit_job --kill-on-invalid-dep=yes --array="$array_spec%$task_count" \
    --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_preflight.sbatch"
preflight_job="$submitted_job_id"
# Keep array stages as compact scheduler records on Engaging. A task-level
# aftercorr dependency expands every pending array element in squeue.
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$preflight_job" \
    --array="$array_spec%$task_count" --time=4-00:00:00 \
    --export="$common_export,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_full.sbatch"
full_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$full_job" \
    --array="$array_spec%$task_count" \
    --export="$common_export,GOM_PRODUCTION_FULL_JOB_ID=$full_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
vtu_job="$submitted_job_id"

"$production_python" - \
    "$gom_root" "$selection" "$source_map" \
    "$preflight_job" "$full_job" "$vtu_job" <<'PY'
import csv
import pathlib
import sys

root, selection, output, preflight, full, vtu = sys.argv[1:]
root = pathlib.Path(root)
with open(selection, newline="", encoding="utf-8") as handle:
    selected = list(csv.DictReader(handle, delimiter="\t"))
fields = ["task", "preflight_root", "full_root", "vtu_root", "preflight_job", "full_job", "vtu_job"]
with open(output, "x", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for row in selected:
        writer.writerow({
            "task": row["task"],
            "preflight_root": root / "results" / f"gom_step62_effective_pc_global_plateau_preflight_job{preflight}",
            "full_root": root / "results" / f"gom_step62_effective_pc_global_plateau_full_job{full}",
            "vtu_root": root / "results" / f"gom_step62_effective_pc_global_plateau_vtu_job{vtu}",
            "preflight_job": preflight,
            "full_job": full,
            "vtu_job": vtu,
        })
PY

archive_export="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_TASKSET_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$GOM_PRODUCTION_CHECK_JOB_ID,GOM_PRODUCTION_TASKSET_ID=$taskset_id,GOM_PRODUCTION_TASKSET_SELECTION=$selection,GOM_PRODUCTION_SOURCE_MAP=$source_map,GOM_PRODUCTION_SUBMISSION_ID=$submission_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu_job" \
    --export="$archive_export" \
    "$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_archive.sbatch"
archive_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes --dependency="afterok:$archive_job" \
    --export="$controller_common,GOM_PRODUCTION_NEXT_TASKSET_INDEX=$next_index" \
    "$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_controller.sbatch"
next_controller_job="$submitted_job_id"

printf '%s\n' \
    "status=submitted" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "parent_submission_id=$GOM_PRODUCTION_PARENT_SUBMISSION_ID" \
    "submission_id=$submission_id" \
    "lane_index=$lane_index" \
    "lane_count=$lane_count" \
    "lane_start_index=$lane_start_index" \
    "taskset_stride=$taskset_stride" \
    "taskset_index=$index" \
    "taskset_id=$taskset_id" \
    "task_count=$task_count" \
    "selection_sha256=$(sha256sum "$selection" | awk '{print $1}')" \
    "preflight_job=$preflight_job" \
    "full_job=$full_job" \
    "vtu_job=$vtu_job" \
    "archive_job=$archive_job" \
    "next_controller_job=$next_controller_job" \
    > "$receipt"
cp -- "$receipt" "$gom_root/submissions/${submission_id}.txt"
submission_complete=true
trap - EXIT
