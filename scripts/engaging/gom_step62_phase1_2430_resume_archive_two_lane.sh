#!/bin/bash
# Re-archive an already audited reusable 50-case canary and release the
# remaining 2,380 cases through two or more disjoint rolling lanes.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_CANARY_SELECTION_DIR:?Set GOM_CANARY_SELECTION_DIR.}"
: "${GOM_CANARY_SUBMISSION_DIR:?Set GOM_CANARY_SUBMISSION_DIR.}"
: "${GOM_CANARY_WORKFLOW_REPO:?Set immutable GOM_CANARY_WORKFLOW_REPO.}"
: "${JUTULDARCY_COMBINED_REPO:?Set immutable JUTULDARCY_COMBINED_REPO.}"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430
test "$GOM_PRODUCTION_PHYSICS_PROFILE" = sandpc_effective_globalplateau_v1

receipt_original="$GOM_CANARY_SUBMISSION_DIR/submission_receipt.txt"
source_map="$GOM_CANARY_SUBMISSION_DIR/source_map_canary50.tsv"
selection="$GOM_CANARY_SELECTION_DIR/tasksets/taskset_0001.tsv"
taskset_plan="$GOM_CANARY_SELECTION_DIR/taskset_plan.tsv"
taskset_selection_dir="$GOM_CANARY_SELECTION_DIR/tasksets"
for path in "$receipt_original" "$source_map" "$selection" "$taskset_plan"; do
    test -s "$path"
done

canary_id="$(awk -F= '$1 == "canary_id" {print $2}' "$receipt_original")"
check_job="$(awk -F= '$1 == "campaign_check_job" {print $2}' "$receipt_original")"
[[ "$canary_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
[[ "$check_job" =~ ^[0-9]+$ ]]
grep -Fxq "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" "$receipt_original"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" "$receipt_original"

audit_dir="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance/${canary_id}_full50"
test -f "$audit_dir/PASS"
grep -Fxq 'status=pass' "$audit_dir/ACCEPTANCE_SUMMARY.txt"
campaign_check="$gom_root/results/gom_step62_production_campaign_check_job${check_job}"
test -f "$campaign_check/PASS"

lane_count="${GOM_PRODUCTION_LANE_COUNT:-2}"
[[ "$lane_count" =~ ^[0-9]+$ ]]
test "$lane_count" -ge 2
test "$lane_count" -le 48
test "$(($(wc -l < "$taskset_plan") - 1))" -eq 49

"$production_python" - "$taskset_plan" "$lane_count" <<'PY'
import csv
import sys

path, lane_count_text = sys.argv[1:]
lane_count = int(lane_count_text)
with open(path, newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
indices = [int(row["taskset_index"]) for row in rows]
if indices != list(range(1, 50)):
    raise SystemExit("task-set plan must contain ordered indices 1:49")
assigned = []
for lane in range(1, lane_count + 1):
    assigned.extend(range(lane + 1, 50, lane_count))
if sorted(assigned) != list(range(2, 50)) or len(assigned) != len(set(assigned)):
    raise SystemExit("rolling lanes do not cover task sets 2:49 exactly once")
PY

workflow_commit="$(git -C "$GOM_CANARY_WORKFLOW_REPO" rev-parse HEAD)"
test -z "$(git -C "$GOM_CANARY_WORKFLOW_REPO" status --porcelain)"
test "$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)"

recovery_id="${GOM_CANARY_RECOVERY_ID:-${canary_id}_archive_two_lane_v1}"
[[ "$recovery_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
recovery_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/recovery_submissions"
recovery_dir="$recovery_parent/$recovery_id"
test ! -e "$recovery_dir"
mkdir -p "$recovery_parent" "$gom_root/logs" "$gom_root/submissions"
lock_file="$recovery_parent/.${recovery_id}.submit.lock"
exec 9> "$lock_file"
flock -n 9 || {
    echo "Another recovery submission is active for $recovery_id." >&2
    exit 1
}
mkdir "$recovery_dir"

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

common_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST"
archive_export="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_TASKSET_ID=taskset_0001,GOM_PRODUCTION_TASKSET_SELECTION=$selection,GOM_PRODUCTION_SOURCE_MAP=$source_map,GOM_PRODUCTION_SUBMISSION_ID=$canary_id,GOM_PRODUCTION_TASKSET_AUDIT_DIR=$audit_dir"
submit_job --kill-on-invalid-dep=yes --time="${GOM_CANARY_ARCHIVE_WALLTIME:-12:00:00}" \
    --export="$archive_export" \
    "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_archive.sbatch"
archive_job="$submitted_job_id"

controller_jobs=()
controller_common="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_TASKSET_PLAN=$taskset_plan,GOM_PRODUCTION_TASKSET_SELECTION_DIR=$taskset_selection_dir,GOM_PRODUCTION_CANARY_TASKSET=$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/tasksets/taskset_0001,GOM_PRODUCTION_PARENT_SUBMISSION_ID=$canary_id,GOM_PRODUCTION_TASKSET_STRIDE=$lane_count,GOM_PRODUCTION_LANE_COUNT=$lane_count"
for ((lane_index = 1; lane_index <= lane_count; lane_index++)); do
    lane_start_index=$((lane_index + 1))
    controller_export="$controller_common,GOM_PRODUCTION_LANE_INDEX=$lane_index,GOM_PRODUCTION_LANE_START_INDEX=$lane_start_index,GOM_PRODUCTION_NEXT_TASKSET_INDEX=$lane_start_index"
    submit_job --kill-on-invalid-dep=yes --dependency="afterok:$archive_job" \
        --export="$controller_export" \
        "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_controller.sbatch"
    controller_jobs+=("$submitted_job_id")
done
controller_jobs_csv="$(IFS=,; echo "${controller_jobs[*]}")"

receipt="$recovery_dir/submission_receipt.txt"
printf '%s\n' \
    'status=submitted' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "recovery_id=$recovery_id" \
    "canary_id=$canary_id" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "workflow_commit=$workflow_commit" \
    "archive_job=$archive_job" \
    "lane_count=$lane_count" \
    "controller_jobs=$controller_jobs_csv" \
    "tasksets_covered=2:49" \
    "tasksets_covered_exactly_once=true" \
    > "$receipt"
cp -- "$receipt" "$gom_root/submissions/${recovery_id}.txt"
(
    cd "$recovery_dir"
    sha256sum ./*.txt > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
submission_complete=true
trap - EXIT
cat "$receipt"
