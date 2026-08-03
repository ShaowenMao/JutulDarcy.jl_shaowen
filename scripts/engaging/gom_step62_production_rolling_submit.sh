#!/bin/bash
# Start or attach a scheduler-safe rolling submission for the full campaign.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_ROLLING_WORKFLOW_REPO:?Set the workflow checkout.}"
: "${GOM_PRODUCTION_SIM_REPO:?Set the immutable simulation checkout.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the schema-2 campaign manifest.}"
: "${GOM_PRODUCTION_ROLLING_ID:?Set the rolling submission ID.}"

workflow_repo="$GOM_PRODUCTION_ROLLING_WORKFLOW_REPO"
simulation_repo="$GOM_PRODUCTION_SIM_REPO"
campaign_manifest="$GOM_PRODUCTION_MANIFEST"
rolling_id="$GOM_PRODUCTION_ROLLING_ID"
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
wave_cases="${GOM_PRODUCTION_ROLLING_WAVE_CASES:-100}"
max_concurrent="${GOM_PRODUCTION_MAX_CONCURRENT:-64}"
shard_window="${GOM_PRODUCTION_SHARD_WINDOW:-2}"
next_start="${GOM_PRODUCTION_ROLLING_START:-1}"
source_receipt="${GOM_PRODUCTION_ROLLING_SOURCE_RECEIPT:-}"

command -v "$production_python" >/dev/null
command -v git >/dev/null
command -v sbatch >/dev/null
[[ "$rolling_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
for value in "$wave_cases" "$max_concurrent" "$shard_window" "$next_start"; do
    [[ "$value" =~ ^[0-9]+$ ]]
    test "$value" -ge 1
done
test "$wave_cases" -le 100
test "$max_concurrent" -le 64
test "$shard_window" -le 2

workflow_commit="$(git -C "$workflow_repo" rev-parse HEAD)"
test -z "$(git -C "$workflow_repo" status --porcelain)" || {
    echo "Rolling workflow checkout must be clean." >&2
    exit 1
}
test -z "$(git -C "$simulation_repo" status --porcelain)" || {
    echo "Simulation checkout must be clean." >&2
    exit 1
}

resolver="$simulation_repo/scripts/engaging/gom_step62_production_manifest.py"
controller="$workflow_repo/scripts/engaging/gom_step62_production_rolling_controller.sbatch"
test -f "$resolver"
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
test "$((wave_cases % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0
test "$next_start" -le "$GOM_PRODUCTION_CASE_COUNT"
test "$(((next_start - 1) % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0

source_finalizer=""
source_sha256="none"
if test "$next_start" -gt 1; then
    test -n "$source_receipt" || {
        echo "An attachment source receipt is required when start > 1." >&2
        exit 1
    }
    test -s "$source_receipt"
    receipt_value() {
        local key="$1"
        local value
        value="$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' "$source_receipt")"
        test -n "$value"
        test "$(printf '%s\n' "$value" | wc -l)" -eq 1
        printf '%s' "$value"
    }
    test "$(receipt_value status)" = submitted
    test "$(receipt_value campaign_id)" = "$GOM_PRODUCTION_CAMPAIGN_ID"
    test "$(receipt_value manifest_sha256)" = \
        "$GOM_PRODUCTION_MANIFEST_SHA256"
    test "$(receipt_value selection_start)" -eq 1
    test "$(receipt_value selection_end)" -eq "$((next_start - 1))"
    source_finalizer="$(receipt_value finalize_job)"
    [[ "$source_finalizer" =~ ^[0-9]+$ ]]
    source_sha256="$(sha256sum "$source_receipt" | awk '{print $1}')"
else
    test -z "$source_receipt"
fi

state_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/rolling_submissions/$GOM_PRODUCTION_CAMPAIGN_ID"
state_dir="$state_parent/$rolling_id"
mkdir -p "$state_parent" "$gom_root/logs" "$gom_root/submissions"
if ! test -d "$state_dir"; then
    temporary_state="$state_parent/.${rolling_id}.tmp.$$"
    test ! -e "$temporary_state"
    mkdir "$temporary_state"
    printf '%s\n' \
        'status=configured' \
        "rolling_id=$rolling_id" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest=$campaign_manifest" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "simulation_repo=$simulation_repo" \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "workflow_repo=$workflow_repo" \
        "workflow_commit=$workflow_commit" \
        "case_count=$GOM_PRODUCTION_CASE_COUNT" \
        "wave_cases=$wave_cases" \
        "max_concurrent=$max_concurrent" \
        "shard_window=$shard_window" \
        "initial_next_start=$next_start" \
        "source_receipt=${source_receipt:-none}" \
        "source_receipt_sha256=$source_sha256" \
        "configured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$temporary_state/ROLLING_CONFIG"
    if test -n "$source_receipt"; then
        cp -- "$source_receipt" "$temporary_state/ATTACHMENT_SOURCE_RECEIPT"
    fi
    mv -- "$temporary_state" "$state_dir"
fi

config="$state_dir/ROLLING_CONFIG"
test -s "$config"
grep -Fxq "rolling_id=$rolling_id" "$config"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" "$config"
grep -Fxq "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" "$config"
grep -Fxq "workflow_commit=$workflow_commit" "$config"
grep -Fxq "initial_next_start=$next_start" "$config"
grep -Fxq "source_receipt_sha256=$source_sha256" "$config"

submitted_marker="$state_dir/ROLLING_SUBMITTED"
if test -s "$submitted_marker"; then
    cat "$submitted_marker"
    exit 0
fi

export_list="ALL,GOM_GRID_ROOT=$gom_root,GOM_PRODUCTION_ROLLING_WORKFLOW_REPO=$workflow_repo,GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT=$workflow_commit,GOM_PRODUCTION_SIM_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_ROLLING_ID=$rolling_id,GOM_PRODUCTION_ROLLING_WAVE_CASES=$wave_cases,GOM_PRODUCTION_MAX_CONCURRENT=$max_concurrent,GOM_PRODUCTION_SHARD_WINDOW=$shard_window,GOM_PRODUCTION_PYTHON=$production_python,GOM_PRODUCTION_ROLLING_PHASE=wave,GOM_PRODUCTION_ROLLING_NEXT_START=$next_start"
dependency_arguments=()
if test -n "$source_finalizer"; then
    dependency_arguments+=(--kill-on-invalid-dep=yes)
    dependency_arguments+=(--dependency="afterok:$source_finalizer")
fi
raw_id="$(sbatch --parsable "${dependency_arguments[@]}" \
    --export="$export_list" "$controller")"
controller_job="${raw_id%%;*}"
[[ "$controller_job" =~ ^[0-9]+$ ]]

temporary_marker="${submitted_marker}.tmp.$$"
printf '%s\n' \
    'status=submitted' \
    "rolling_id=$rolling_id" \
    "controller_job=$controller_job" \
    "dependency_job=${source_finalizer:-none}" \
    "next_start=$next_start" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$temporary_marker"
mv -- "$temporary_marker" "$submitted_marker"
cat "$submitted_marker"
