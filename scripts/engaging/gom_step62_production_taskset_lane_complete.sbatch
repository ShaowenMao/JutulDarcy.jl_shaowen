#!/bin/bash
#SBATCH --job-name=gom_s62_lane_complete
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Verify one rolling lane and submit the campaign finalizer exactly once after
# every lane has durably archived all of its disjoint task sets.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_TASKSET_WORKFLOW_REPO:?Set GOM_TASKSET_WORKFLOW_REPO.}"
: "${GOM_PRODUCTION_TASKSET_PLAN:?Set GOM_PRODUCTION_TASKSET_PLAN.}"
: "${GOM_PRODUCTION_TASKSET_SELECTION_DIR:?Set GOM_PRODUCTION_TASKSET_SELECTION_DIR.}"
: "${GOM_PRODUCTION_PARENT_SUBMISSION_ID:?Set GOM_PRODUCTION_PARENT_SUBMISSION_ID.}"
: "${GOM_PRODUCTION_TASKSET_STRIDE:?Set GOM_PRODUCTION_TASKSET_STRIDE.}"
: "${GOM_PRODUCTION_LANE_COUNT:?Set GOM_PRODUCTION_LANE_COUNT.}"
: "${GOM_PRODUCTION_LANE_INDEX:?Set GOM_PRODUCTION_LANE_INDEX.}"
: "${GOM_PRODUCTION_LANE_START_INDEX:?Set GOM_PRODUCTION_LANE_START_INDEX.}"

[[ "$GOM_PRODUCTION_PARENT_SUBMISSION_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
[[ "$GOM_PRODUCTION_TASKSET_STRIDE" =~ ^[1-9][0-9]*$ ]]
[[ "$GOM_PRODUCTION_LANE_COUNT" =~ ^[1-9][0-9]*$ ]]
[[ "$GOM_PRODUCTION_LANE_INDEX" =~ ^[1-9][0-9]*$ ]]
[[ "$GOM_PRODUCTION_LANE_START_INDEX" =~ ^[1-9][0-9]*$ ]]
test "$GOM_PRODUCTION_LANE_INDEX" -le "$GOM_PRODUCTION_LANE_COUNT"
test "$GOM_PRODUCTION_TASKSET_STRIDE" -eq "$GOM_PRODUCTION_LANE_COUNT"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
verifier="$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_verify.py"
summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430

plan_count="$(($(wc -l < "$GOM_PRODUCTION_TASKSET_PLAN") - 1))"
test "$plan_count" -eq 49
campaign_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
lane_root="$campaign_parent/lane_control/${GOM_PRODUCTION_PARENT_SUBMISSION_ID}_lanes${GOM_PRODUCTION_LANE_COUNT}"
result_dir="$gom_root/results/gom_step62_production_taskset_lane_complete_job${SLURM_JOB_ID}"
mkdir -p "$lane_root" "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

verified_count=0
for ((taskset_index = GOM_PRODUCTION_LANE_START_INDEX;
      taskset_index <= plan_count;
      taskset_index += GOM_PRODUCTION_TASKSET_STRIDE)); do
    plan_row="$(awk -F '\t' -v wanted="$taskset_index" '
        NR > 1 && $1 == wanted {print; found=1}
        END {if (!found) exit 1}
    ' "$GOM_PRODUCTION_TASKSET_PLAN")"
    IFS=$'\t' read -r row_index taskset_id purpose task_count selection_relative array_relative <<< "$plan_row"
    test "$row_index" -eq "$taskset_index"
    test "$purpose" = remaining_production
    selection="$GOM_PRODUCTION_TASKSET_SELECTION_DIR/$(basename -- "$selection_relative")"
    durable="$campaign_parent/tasksets/$taskset_id"
    "$production_python" "$verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --taskset "$durable" --selection "$selection"
    verified_count=$((verified_count + 1))
done
test "$verified_count" -ge 1

lane_label="$(printf '%02d' "$GOM_PRODUCTION_LANE_INDEX")"
marker="$lane_root/lane_${lane_label}.complete"
marker_tmp="$lane_root/.lane_${lane_label}.complete.${SLURM_JOB_ID}.tmp"
if test -e "$marker"; then
    grep -Fxq 'status=pass' "$marker"
    grep -Fxq "lane_index=$GOM_PRODUCTION_LANE_INDEX" "$marker"
    grep -Fxq "verified_taskset_count=$verified_count" "$marker"
else
    printf '%s\n' \
        'status=pass' \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "parent_submission_id=$GOM_PRODUCTION_PARENT_SUBMISSION_ID" \
        "lane_index=$GOM_PRODUCTION_LANE_INDEX" \
        "lane_count=$GOM_PRODUCTION_LANE_COUNT" \
        "lane_start_index=$GOM_PRODUCTION_LANE_START_INDEX" \
        "taskset_stride=$GOM_PRODUCTION_TASKSET_STRIDE" \
        "verified_taskset_count=$verified_count" \
        "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$marker_tmp"
    mv -- "$marker_tmp" "$marker"
fi

finalizer_job=none
exec 9> "$lane_root/finalizer_submission.lock"
flock -x 9
completed_lanes="$(find "$lane_root" -maxdepth 1 -type f -name 'lane_[0-9][0-9].complete' | wc -l)"
test "$completed_lanes" -le "$GOM_PRODUCTION_LANE_COUNT"
if test "$completed_lanes" -eq "$GOM_PRODUCTION_LANE_COUNT"; then
    # Do not count stale or differently configured markers toward completion.
    for ((completed_lane = 1;
          completed_lane <= GOM_PRODUCTION_LANE_COUNT;
          completed_lane++)); do
        completed_label="$(printf '%02d' "$completed_lane")"
        completed_marker="$lane_root/lane_${completed_label}.complete"
        test -f "$completed_marker"
        grep -Fxq 'status=pass' "$completed_marker"
        grep -Fxq "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" "$completed_marker"
        grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
            "$completed_marker"
        grep -Fxq "parent_submission_id=$GOM_PRODUCTION_PARENT_SUBMISSION_ID" \
            "$completed_marker"
        grep -Fxq "lane_index=$completed_lane" "$completed_marker"
        grep -Fxq "lane_count=$GOM_PRODUCTION_LANE_COUNT" "$completed_marker"
        grep -Fxq "lane_start_index=$((completed_lane + 1))" "$completed_marker"
        grep -Fxq "taskset_stride=$GOM_PRODUCTION_TASKSET_STRIDE" "$completed_marker"
    done
    finalizer_receipt="$lane_root/finalizer_submission.txt"
    if test -e "$finalizer_receipt"; then
        grep -Fxq 'status=submitted' "$finalizer_receipt"
        finalizer_job="$(awk -F= '$1 == "finalizer_job" {print $2}' "$finalizer_receipt")"
        [[ "$finalizer_job" =~ ^[0-9]+$ ]]
    else
        raw_id="$(sbatch --parsable --kill-on-invalid-dep=yes \
            --export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST,GOM_TASKSET_WORKFLOW_REPO=$GOM_TASKSET_WORKFLOW_REPO,GOM_PRODUCTION_TASKSET_PLAN=$GOM_PRODUCTION_TASKSET_PLAN,GOM_PRODUCTION_TASKSET_SELECTION_DIR=$GOM_PRODUCTION_TASKSET_SELECTION_DIR,GOM_PRODUCTION_PARENT_SUBMISSION_ID=$GOM_PRODUCTION_PARENT_SUBMISSION_ID" \
            "$GOM_TASKSET_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_finalize.sbatch")"
        finalizer_job="${raw_id%%;*}"
        [[ "$finalizer_job" =~ ^[0-9]+$ ]]
        printf '%s\n' \
            'status=submitted' \
            "finalizer_job=$finalizer_job" \
            "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$finalizer_receipt"
    fi
fi
flock -u 9

printf '%s\n' \
    'status=pass' \
    "lane_index=$GOM_PRODUCTION_LANE_INDEX" \
    "verified_taskset_count=$verified_count" \
    "completed_lanes=$completed_lanes" \
    "lane_count=$GOM_PRODUCTION_LANE_COUNT" \
    "finalizer_job=$finalizer_job" \
    > "$result_dir/lane_complete_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
