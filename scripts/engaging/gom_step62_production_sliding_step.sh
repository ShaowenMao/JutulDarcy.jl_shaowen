#!/bin/bash
# Advance one lane of a shard-level sliding production campaign.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_SLIDING_WORKFLOW_REPO:?Set the workflow checkout.}"
: "${GOM_PRODUCTION_SLIDING_WORKFLOW_COMMIT:?Set the workflow commit.}"
: "${GOM_PRODUCTION_SIM_REPO:?Set the immutable simulation checkout.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the schema-2/3 campaign manifest.}"
: "${GOM_PRODUCTION_SLIDING_ID:?Set the sliding campaign ID.}"
: "${GOM_PRODUCTION_SLIDING_LANE_ID:?Set the lane ID.}"

workflow_repo="$GOM_PRODUCTION_SLIDING_WORKFLOW_REPO"
workflow_commit="$GOM_PRODUCTION_SLIDING_WORKFLOW_COMMIT"
simulation_repo="$GOM_PRODUCTION_SIM_REPO"
campaign_manifest="$GOM_PRODUCTION_MANIFEST"
sliding_id="$GOM_PRODUCTION_SLIDING_ID"
lane_id="$GOM_PRODUCTION_SLIDING_LANE_ID"
phase="${GOM_PRODUCTION_SLIDING_PHASE:-release}"
event_id="${GOM_PRODUCTION_SLIDING_EVENT_ID:-${SLURM_JOB_ID:-}}"
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"

command -v "$production_python" >/dev/null
command -v git >/dev/null
command -v sbatch >/dev/null
command -v flock >/dev/null
[[ "$sliding_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
[[ "$lane_id" =~ ^[0-9]+$ ]]
[[ "$event_id" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
    echo "A stable controller event ID is required." >&2
    exit 1
}
case "$phase" in
    release|complete) ;;
    *)
        echo "Unsupported sliding phase: $phase" >&2
        exit 1
        ;;
esac

test "$(git -C "$workflow_repo" rev-parse HEAD)" = "$workflow_commit" || {
    echo "Sliding workflow checkout does not match its pinned commit." >&2
    exit 1
}
test -z "$(git -C "$workflow_repo" status --porcelain)" || {
    echo "Sliding workflow checkout must be clean." >&2
    exit 1
}
test -z "$(git -C "$simulation_repo" status --porcelain)" || {
    echo "Simulation checkout must be clean." >&2
    exit 1
}

scripts="$simulation_repo/scripts/engaging"
resolver="$scripts/gom_step62_production_manifest.py"
launcher="$scripts/gom_step62_production_ensemble_submit.sh"
shard_verifier="$scripts/gom_step62_production_shard_verify.py"
controller="$workflow_repo/scripts/engaging/gom_step62_production_sliding_controller.sbatch"
for required in "$resolver" "$launcher" "$shard_verifier" "$controller"; do
    test -f "$required"
done

manifest_summary="$($production_python "$resolver" \
    --manifest "$campaign_manifest" summary --format shell)"
eval "$manifest_summary"
campaign_identity="$GOM_PRODUCTION_SCHEMA_VERSION:$GOM_PRODUCTION_ENSEMBLE_KIND:$GOM_PRODUCTION_CASE_COUNT"
case "$campaign_identity" in
    2:full_1620:1620|3:phase1_2430:2430) ;;
    *)
        echo "Sliding production supports only full_1620/schema-2 or" \
            "phase1_2430/schema-3." >&2
        exit 1
        ;;
esac
test "$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" -eq 50
test "$GOM_PRODUCTION_JUTULDARCY_COMMIT" = \
    "$(git -C "$simulation_repo" rev-parse HEAD)"

state_dir="$GOM_PRODUCTION_ARCHIVE_ROOT/sliding_submissions/$GOM_PRODUCTION_CAMPAIGN_ID/$sliding_id"
config="$state_dir/SLIDING_CONFIG"
cursor_file="$state_dir/NEXT_START"
test -s "$config"
test -s "$cursor_file"
grep -Fxq "status=configured" "$config"
grep -Fxq "sliding_id=$sliding_id" "$config"
grep -Fxq "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" "$config"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" "$config"
grep -Fxq "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" "$config"
grep -Fxq "workflow_commit=$workflow_commit" "$config"

max_lanes="$(awk -F= '$1 == "max_lanes" {print $2}' "$config")"
max_concurrent="$(awk -F= '$1 == "max_concurrent" {print $2}' "$config")"
[[ "$max_lanes" =~ ^[0-9]+$ ]]
[[ "$max_concurrent" =~ ^[0-9]+$ ]]
test "$lane_id" -ge 1
test "$lane_id" -le "$max_lanes"
test "$max_concurrent" -ge 1
test "$max_concurrent" -le 64

mkdir -p "$gom_root/logs" "$gom_root/submissions" \
    "$state_dir/claims" "$state_dir/controllers" "$state_dir/events" \
    "$state_dir/receipts"
exec 9>> "$state_dir/.sliding.lock"
flock -w 1800 9 || {
    echo "Timed out waiting for the sliding campaign lock." >&2
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
            echo "Existing sliding record differs: $destination" >&2
            exit 1
        }
        return
    fi
    temporary="${destination}.tmp.$$"
    cp -- "$source" "$temporary"
    mv -- "$temporary" "$destination"
}

atomic_write() {
    local destination="$1"
    shift
    local temporary="${destination}.tmp.$$"
    printf '%s\n' "$@" > "$temporary"
    mv -- "$temporary" "$destination"
}

event_marker="$state_dir/events/${event_id}.txt"
if test -s "$event_marker"; then
    cat "$event_marker"
    exit 0
fi

# Recover idempotently if a controller was requeued after recording its shard
# claim but before writing its final event marker.  The claim is authoritative;
# NEXT_START is only a cached cursor and may safely lag another lane.
mapfile -t prior_claims < <(grep -l -Fx "controller_event_id=$event_id" \
    "$state_dir"/claims/*.txt 2>/dev/null || true)
test "${#prior_claims[@]}" -le 1
if test "${#prior_claims[@]}" -eq 1; then
    prior_end="$(awk -F= '$1 == "selection_end" {print $2}' "${prior_claims[0]}")"
    [[ "$prior_end" =~ ^[0-9]+$ ]]
    cached_start="$(cat "$cursor_file")"
    [[ "$cached_start" =~ ^[0-9]+$ ]]
    recovered_start=$((prior_end + 1))
    if test "$cached_start" -lt "$recovered_start"; then
        atomic_write "$cursor_file" "$recovered_start"
    fi
    atomic_write "$event_marker" \
        'status=recovered_from_claim' \
        "controller_event_id=$event_id" \
        "lane_id=$lane_id" \
        "claim=${prior_claims[0]}" \
        "recovered_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "$event_marker"
    exit 0
fi

validate_submission_receipt() {
    local receipt="$1"
    local expected_id="$2"
    local expected_start="$3"
    local expected_end="$4"
    test -s "$receipt"
    test "$(receipt_value status "$receipt")" = submitted
    test "$(receipt_value submission_id "$receipt")" = "$expected_id"
    test "$(receipt_value campaign_id "$receipt")" = "$GOM_PRODUCTION_CAMPAIGN_ID"
    test "$(receipt_value manifest_sha256 "$receipt")" = "$GOM_PRODUCTION_MANIFEST_SHA256"
    test "$(receipt_value selection_start "$receipt")" -eq "$expected_start"
    test "$(receipt_value selection_end "$receipt")" -eq "$expected_end"
    test "$(receipt_value physics_profile "$receipt")" = "$GOM_PRODUCTION_PHYSICS_PROFILE"
    local finalizer
    finalizer="$(receipt_value finalize_job "$receipt")"
    [[ "$finalizer" =~ ^[0-9]+$ ]]
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
    export GOM_PRODUCTION_SHARD_WINDOW=1
    export GOM_PRODUCTION_PYTHON="$production_python"
    if test "$selection_start" -eq 1 && \
       test "$selection_end" -eq "$GOM_PRODUCTION_CASE_COUNT"; then
        unset GOM_PRODUCTION_SELECTION_START GOM_PRODUCTION_SELECTION_END
        case "$GOM_PRODUCTION_ENSEMBLE_KIND" in
            full_1620)
                export GOM_PRODUCTION_CONFIRM_FULL_1620=YES
                unset GOM_PRODUCTION_CONFIRM_PHASE1_2430
                ;;
            phase1_2430)
                export GOM_PRODUCTION_CONFIRM_PHASE1_2430=YES
                unset GOM_PRODUCTION_CONFIRM_FULL_1620
                ;;
        esac
    else
        export GOM_PRODUCTION_SELECTION_START="$selection_start"
        export GOM_PRODUCTION_SELECTION_END="$selection_end"
        unset GOM_PRODUCTION_CONFIRM_FULL_1620
        unset GOM_PRODUCTION_CONFIRM_PHASE1_2430
    fi
    bash "$launcher"
}

schedule_controller() {
    local dependency_job="$1"
    local next_phase="$2"
    local record_key="$3"
    local record="$state_dir/controllers/${record_key}.txt"
    if test -s "$record"; then
        grep -Eq '^controller_job=[0-9]+$' "$record"
        return
    fi
    local export_list raw_id controller_job temporary
    export_list="ALL,GOM_GRID_ROOT=$gom_root,GOM_PRODUCTION_SLIDING_WORKFLOW_REPO=$workflow_repo,GOM_PRODUCTION_SLIDING_WORKFLOW_COMMIT=$workflow_commit,GOM_PRODUCTION_SIM_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_SLIDING_ID=$sliding_id,GOM_PRODUCTION_SLIDING_LANE_ID=$lane_id,GOM_PRODUCTION_SLIDING_PHASE=$next_phase,GOM_PRODUCTION_PYTHON=$production_python"
    raw_id="$(sbatch --parsable --kill-on-invalid-dep=yes \
        --dependency="afterok:$dependency_job" \
        --export="$export_list" "$controller")"
    controller_job="${raw_id%%;*}"
    [[ "$controller_job" =~ ^[0-9]+$ ]]
    temporary="${record}.tmp.$$"
    printf '%s\n' \
        'status=submitted' \
        "controller_job=$controller_job" \
        "dependency_job=$dependency_job" \
        "phase=$next_phase" \
        "lane_id=$lane_id" \
        "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$temporary"
    mv -- "$temporary" "$record"
    printf 'SLIDING_CONTROLLER_SUBMITTED lane=%s phase=%s job=%s dependency=%s\n' \
        "$lane_id" "$next_phase" "$controller_job" "$dependency_job"
}

all_shards_are_durable() {
    local start=1 end shard_name shard_path
    while test "$start" -le "$GOM_PRODUCTION_CASE_COUNT"; do
        end=$((start + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
        if test "$end" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
            end="$GOM_PRODUCTION_CASE_COUNT"
        fi
        shard_name="shard_$(printf '%04d' "$start")_$(printf '%04d' "$end")"
        shard_path="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/shards/$shard_name"
        if ! test -s "$shard_path/SHARD_COMPLETE"; then
            return 1
        fi
        "$production_python" "$shard_verifier" \
            --manifest "$campaign_manifest" --shard "$shard_path" \
            --start "$start" --end "$end" >/dev/null
        start=$((end + 1))
    done
}

try_reconcile() {
    local drained="$state_dir/LANE_${lane_id}_DRAINED"
    if ! all_shards_are_durable; then
        atomic_write "$drained" \
            'status=waiting_for_other_lane' \
            "lane_id=$lane_id" \
            "checked_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        atomic_write "$event_marker" \
            'status=lane_drained' \
            "controller_event_id=$event_id" \
            "lane_id=$lane_id" \
            "checked_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$drained"
        return
    fi

    local marker="$state_dir/RECONCILE_SUBMITTED"
    if test -s "$marker"; then
        atomic_write "$event_marker" \
            'status=reconcile_already_submitted' \
            "controller_event_id=$event_id" \
            "lane_id=$lane_id" \
            "checked_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$marker"
        return
    fi
    local submission_id="${sliding_id}_complete"
    local receipt="$gom_root/submissions/${submission_id}.txt"
    if ! test -s "$receipt"; then
        run_ensemble_launcher "$submission_id" 1 "$GOM_PRODUCTION_CASE_COUNT"
    fi
    validate_submission_receipt "$receipt" "$submission_id" 1 \
        "$GOM_PRODUCTION_CASE_COUNT"
    atomic_copy_once "$receipt" "$state_dir/receipts/${submission_id}.txt"
    local finalizer
    finalizer="$(receipt_value finalize_job "$receipt")"
    schedule_controller "$finalizer" complete "after_${submission_id}"
    atomic_write "$marker" \
        'status=submitted' \
        "submission_id=$submission_id" \
        "finalize_job=$finalizer" \
        "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    atomic_write "$event_marker" \
        'status=reconcile_submitted' \
        "controller_event_id=$event_id" \
        "lane_id=$lane_id" \
        "submission_id=$submission_id" \
        "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "$marker"
}

case "$phase" in
    release)
        next_start="$(cat "$cursor_file")"
        [[ "$next_start" =~ ^[0-9]+$ ]]
        if test "$next_start" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
            try_reconcile
            exit 0
        fi
        test "$(((next_start - 1) % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0
        selection_end=$((next_start + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
        if test "$selection_end" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
            selection_end="$GOM_PRODUCTION_CASE_COUNT"
        fi
        submission_id="${sliding_id}_shard_$(printf '%04d' "$next_start")_$(printf '%04d' "$selection_end")"
        receipt="$gom_root/submissions/${submission_id}.txt"
        if ! test -s "$receipt"; then
            run_ensemble_launcher "$submission_id" "$next_start" "$selection_end"
        fi
        validate_submission_receipt "$receipt" "$submission_id" \
            "$next_start" "$selection_end"
        atomic_copy_once "$receipt" "$state_dir/receipts/${submission_id}.txt"
        shard_receipt="$gom_root/submissions/${submission_id}_shards.tsv"
        test -s "$shard_receipt"
        atomic_copy_once "$shard_receipt" \
            "$state_dir/receipts/${submission_id}_shards.tsv"
        finalizer="$(receipt_value finalize_job "$receipt")"
        following_start=$((selection_end + 1))
        schedule_controller "$finalizer" release \
            "after_${submission_id}_lane_${lane_id}"
        claim="$state_dir/claims/${submission_id}.txt"
        atomic_write "$claim" \
            'status=claimed' \
            "controller_event_id=$event_id" \
            "lane_id=$lane_id" \
            "selection_start=$next_start" \
            "selection_end=$selection_end" \
            "finalize_job=$finalizer" \
            "claimed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        atomic_write "$cursor_file" "$following_start"
        atomic_write "$event_marker" \
            'status=shard_submitted' \
            "controller_event_id=$event_id" \
            "lane_id=$lane_id" \
            "submission_id=$submission_id" \
            "selection_start=$next_start" \
            "selection_end=$selection_end" \
            "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$claim"
        ;;
    complete)
        submission_id="${sliding_id}_complete"
        receipt="$state_dir/receipts/${submission_id}.txt"
        validate_submission_receipt "$receipt" "$submission_id" 1 \
            "$GOM_PRODUCTION_CASE_COUNT"
        campaign_root="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
        submission_root="$campaign_root/submissions/$submission_id"
        test -s "$campaign_root/CAMPAIGN_COMPLETE"
        test -s "$submission_root/SUBMISSION_COMPLETE"
        marker="$state_dir/SLIDING_COMPLETE"
        atomic_write "$marker" \
            'status=pass' \
            "sliding_id=$sliding_id" \
            "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
            "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
            "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        atomic_write "$event_marker" \
            'status=complete' \
            "controller_event_id=$event_id" \
            "lane_id=$lane_id" \
            "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$marker"
        ;;
esac
