#!/bin/bash
# Advance a schema-2 production campaign by one scheduler-safe wave.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_ROLLING_WORKFLOW_REPO:?Set the workflow checkout.}"
: "${GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT:?Set the workflow commit.}"
: "${GOM_PRODUCTION_SIM_REPO:?Set the immutable simulation checkout.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the schema-2 campaign manifest.}"
: "${GOM_PRODUCTION_ROLLING_ID:?Set the rolling submission ID.}"

workflow_repo="$GOM_PRODUCTION_ROLLING_WORKFLOW_REPO"
workflow_commit="$GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT"
simulation_repo="$GOM_PRODUCTION_SIM_REPO"
campaign_manifest="$GOM_PRODUCTION_MANIFEST"
rolling_id="$GOM_PRODUCTION_ROLLING_ID"
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
wave_cases="${GOM_PRODUCTION_ROLLING_WAVE_CASES:-100}"
max_concurrent="${GOM_PRODUCTION_MAX_CONCURRENT:-64}"
shard_window="${GOM_PRODUCTION_SHARD_WINDOW:-2}"
phase="${GOM_PRODUCTION_ROLLING_PHASE:-wave}"
next_start="${GOM_PRODUCTION_ROLLING_NEXT_START:-1}"

command -v "$production_python" >/dev/null
command -v git >/dev/null
command -v sbatch >/dev/null
command -v flock >/dev/null
[[ "$rolling_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || {
    echo "Unsafe rolling submission ID: $rolling_id" >&2
    exit 1
}
case "$phase" in
    wave|reconcile|complete) ;;
    *)
        echo "Unsupported rolling phase: $phase" >&2
        exit 1
        ;;
esac
for value in "$wave_cases" "$max_concurrent" "$shard_window"; do
    [[ "$value" =~ ^[0-9]+$ ]]
    test "$value" -ge 1
done
[[ "$next_start" =~ ^[0-9]+$ ]]

observed_workflow_commit="$(git -C "$workflow_repo" rev-parse HEAD)"
test "$observed_workflow_commit" = "$workflow_commit" || {
    echo "Rolling workflow checkout does not match its pinned commit." >&2
    exit 1
}
test -z "$(git -C "$workflow_repo" status --porcelain)" || {
    echo "Rolling workflow checkout must be clean." >&2
    exit 1
}
test -z "$(git -C "$simulation_repo" status --porcelain)" || {
    echo "Simulation checkout must be clean." >&2
    exit 1
}

resolver="$simulation_repo/scripts/engaging/gom_step62_production_manifest.py"
launcher="$simulation_repo/scripts/engaging/gom_step62_production_ensemble_submit.sh"
controller="$workflow_repo/scripts/engaging/gom_step62_production_rolling_controller.sbatch"
test -f "$resolver"
test -f "$launcher"
test -f "$controller"

manifest_summary="$($production_python "$resolver" \
    --manifest "$campaign_manifest" summary --format shell)"
eval "$manifest_summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = full_1620
test "$GOM_PRODUCTION_CASE_COUNT" -eq 1620
test "$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" -eq 50
test "$GOM_PRODUCTION_JUTULDARCY_COMMIT" = \
    "$(git -C "$simulation_repo" rev-parse HEAD)"
test "$wave_cases" -le 100 || {
    echo "Rolling waves may contain at most 100 cases under the QOS limit." >&2
    exit 1
}
test "$((wave_cases % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0
test "$max_concurrent" -le 64
test "$shard_window" -le 2

state_dir="$GOM_PRODUCTION_ARCHIVE_ROOT/rolling_submissions/$GOM_PRODUCTION_CAMPAIGN_ID/$rolling_id"
config="$state_dir/ROLLING_CONFIG"
test -f "$config"
grep -Fxq "status=configured" "$config"
grep -Fxq "rolling_id=$rolling_id" "$config"
grep -Fxq "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" "$config"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" "$config"
grep -Fxq "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" "$config"
grep -Fxq "workflow_commit=$workflow_commit" "$config"
grep -Fxq "wave_cases=$wave_cases" "$config"
grep -Fxq "max_concurrent=$max_concurrent" "$config"
grep -Fxq "shard_window=$shard_window" "$config"

mkdir -p "$gom_root/logs" "$gom_root/submissions"
exec 9>> "$state_dir/.rolling.lock"
flock -w 1800 9 || {
    echo "Timed out waiting for the rolling campaign lock." >&2
    exit 1
}

receipt_value() {
    local key="$1"
    local receipt="$2"
    local value
    value="$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' "$receipt")"
    test -n "$value"
    test "$(printf '%s\n' "$value" | wc -l)" -eq 1
    printf '%s' "$value"
}

atomic_copy_once() {
    local source="$1"
    local destination="$2"
    local temporary
    if test -e "$destination"; then
        cmp -s "$source" "$destination" || {
            echo "Existing rolling record differs: $destination" >&2
            exit 1
        }
        return
    fi
    temporary="${destination}.tmp.$$"
    cp -- "$source" "$temporary"
    mv -- "$temporary" "$destination"
}

validate_submission_receipt() {
    local receipt="$1"
    local submission_id="$2"
    local selection_start="$3"
    local selection_end="$4"
    test -s "$receipt"
    test "$(receipt_value status "$receipt")" = submitted
    test "$(receipt_value submission_id "$receipt")" = "$submission_id"
    test "$(receipt_value campaign_id "$receipt")" = \
        "$GOM_PRODUCTION_CAMPAIGN_ID"
    test "$(receipt_value manifest_sha256 "$receipt")" = \
        "$GOM_PRODUCTION_MANIFEST_SHA256"
    test "$(receipt_value selection_start "$receipt")" -eq \
        "$selection_start"
    test "$(receipt_value selection_end "$receipt")" -eq \
        "$selection_end"
    test "$(receipt_value physics_profile "$receipt")" = \
        "$GOM_PRODUCTION_PHYSICS_PROFILE"
    local finalizer
    finalizer="$(receipt_value finalize_job "$receipt")"
    [[ "$finalizer" =~ ^[0-9]+$ ]]
}

schedule_controller() {
    local dependency_job="$1"
    local next_phase="$2"
    local scheduled_start="$3"
    local record_key="$4"
    local record="$state_dir/controller_${record_key}.txt"
    if test -s "$record"; then
        grep -Eq '^controller_job=[0-9]+$' "$record"
        return
    fi
    local export_list raw_id controller_job temporary
    export_list="ALL,GOM_GRID_ROOT=$gom_root,GOM_PRODUCTION_ROLLING_WORKFLOW_REPO=$workflow_repo,GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT=$workflow_commit,GOM_PRODUCTION_SIM_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_ROLLING_ID=$rolling_id,GOM_PRODUCTION_ROLLING_WAVE_CASES=$wave_cases,GOM_PRODUCTION_MAX_CONCURRENT=$max_concurrent,GOM_PRODUCTION_SHARD_WINDOW=$shard_window,GOM_PRODUCTION_PYTHON=$production_python,GOM_PRODUCTION_ROLLING_PHASE=$next_phase,GOM_PRODUCTION_ROLLING_NEXT_START=$scheduled_start"
    raw_id="$(sbatch --parsable --kill-on-invalid-dep=yes \
        --dependency="afterok:$dependency_job" \
        --export="$export_list" "$controller")"
    controller_job="${raw_id%%;*}"
    [[ "$controller_job" =~ ^[0-9]+$ ]]
    temporary="${record}.tmp.$$"
    printf '%s\n' \
        "status=submitted" \
        "controller_job=$controller_job" \
        "dependency_job=$dependency_job" \
        "phase=$next_phase" \
        "next_start=$scheduled_start" \
        "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$temporary"
    mv -- "$temporary" "$record"
    printf 'ROLLING_CONTROLLER_SUBMITTED phase=%s next_start=%s job=%s dependency=%s\n' \
        "$next_phase" "$scheduled_start" "$controller_job" "$dependency_job"
}

run_ensemble_launcher() {
    local submission_id="$1"
    local selection_start="$2"
    local selection_end="$3"
    export GOM_GRID_ROOT="$gom_root"
    export JUTULDARCY_COMBINED_REPO="$simulation_repo"
    export GOM_PRODUCTION_MANIFEST="$campaign_manifest"
    export GOM_PRODUCTION_SUBMISSION_ID="$submission_id"
    export GOM_PRODUCTION_MAX_CONCURRENT="$max_concurrent"
    export GOM_PRODUCTION_SHARD_WINDOW="$shard_window"
    export GOM_PRODUCTION_PYTHON="$production_python"
    if test "$selection_start" -eq 1 && \
       test "$selection_end" -eq "$GOM_PRODUCTION_CASE_COUNT"; then
        unset GOM_PRODUCTION_SELECTION_START GOM_PRODUCTION_SELECTION_END
        export GOM_PRODUCTION_CONFIRM_FULL_1620=YES
    else
        export GOM_PRODUCTION_SELECTION_START="$selection_start"
        export GOM_PRODUCTION_SELECTION_END="$selection_end"
        unset GOM_PRODUCTION_CONFIRM_FULL_1620
    fi
    bash "$launcher"
}

case "$phase" in
    wave)
        test "$next_start" -ge 1
        test "$next_start" -le "$GOM_PRODUCTION_CASE_COUNT"
        test "$(((next_start - 1) % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0
        selection_end=$((next_start + wave_cases - 1))
        if test "$selection_end" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
            selection_end="$GOM_PRODUCTION_CASE_COUNT"
        fi
        submission_id="${rolling_id}_wave_$(printf '%04d' "$next_start")_$(printf '%04d' "$selection_end")"
        receipt="$gom_root/submissions/${submission_id}.txt"
        if ! test -s "$receipt"; then
            run_ensemble_launcher "$submission_id" "$next_start" "$selection_end"
        fi
        validate_submission_receipt \
            "$receipt" "$submission_id" "$next_start" "$selection_end"
        wave_record="$state_dir/${submission_id}.txt"
        atomic_copy_once "$receipt" "$wave_record"
        finalizer_job="$(receipt_value finalize_job "$receipt")"
        following_start=$((selection_end + 1))
        if test "$following_start" -le "$GOM_PRODUCTION_CASE_COUNT"; then
            schedule_controller "$finalizer_job" wave "$following_start" \
                "after_${submission_id}"
        else
            schedule_controller "$finalizer_job" reconcile 1 \
                "after_${submission_id}"
        fi
        ;;
    reconcile)
        submission_id="${rolling_id}_complete"
        receipt="$gom_root/submissions/${submission_id}.txt"
        if ! test -s "$receipt"; then
            run_ensemble_launcher "$submission_id" 1 \
                "$GOM_PRODUCTION_CASE_COUNT"
        fi
        validate_submission_receipt "$receipt" "$submission_id" 1 \
            "$GOM_PRODUCTION_CASE_COUNT"
        atomic_copy_once "$receipt" \
            "$state_dir/${submission_id}.txt"
        finalizer_job="$(receipt_value finalize_job "$receipt")"
        schedule_controller "$finalizer_job" complete 1 \
            "after_${submission_id}"
        ;;
    complete)
        submission_id="${rolling_id}_complete"
        receipt="$state_dir/${submission_id}.txt"
        validate_submission_receipt "$receipt" "$submission_id" 1 \
            "$GOM_PRODUCTION_CASE_COUNT"
        campaign_complete="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/CAMPAIGN_COMPLETE"
        submission_complete="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/submissions/$submission_id/SUBMISSION_COMPLETE"
        test -s "$campaign_complete"
        test -s "$submission_complete"
        grep -Fxq 'status=pass' "$campaign_complete"
        grep -Fxq 'status=pass' "$submission_complete"
        marker="$state_dir/ROLLING_COMPLETE"
        if ! test -e "$marker"; then
            temporary="${marker}.tmp.$$"
            printf '%s\n' \
                'status=pass' \
                "rolling_id=$rolling_id" \
                "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
                "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
                "case_count=$GOM_PRODUCTION_CASE_COUNT" \
                "campaign_complete=$campaign_complete" \
                "submission_complete=$submission_complete" \
                "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$temporary"
            mv -- "$temporary" "$marker"
        fi
        cat "$marker"
        ;;
esac
