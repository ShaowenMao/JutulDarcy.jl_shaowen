#!/bin/bash
# Start a scheduler-safe, shard-level sliding production campaign.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_SLIDING_WORKFLOW_REPO:?Set the workflow checkout.}"
: "${GOM_PRODUCTION_SIM_REPO:?Set the immutable simulation checkout.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the schema-2 campaign manifest.}"
: "${GOM_PRODUCTION_SLIDING_ID:?Set the sliding campaign ID.}"
: "${GOM_PRODUCTION_SLIDING_SEED_DEPENDENCIES:?Set comma-separated seed dependencies.}"

workflow_repo="$GOM_PRODUCTION_SLIDING_WORKFLOW_REPO"
simulation_repo="$GOM_PRODUCTION_SIM_REPO"
campaign_manifest="$GOM_PRODUCTION_MANIFEST"
sliding_id="$GOM_PRODUCTION_SLIDING_ID"
seed_dependencies_csv="$GOM_PRODUCTION_SLIDING_SEED_DEPENDENCIES"
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
next_start="${GOM_PRODUCTION_SLIDING_START:-1}"
max_lanes="${GOM_PRODUCTION_SLIDING_LANES:-2}"
max_concurrent="${GOM_PRODUCTION_MAX_CONCURRENT:-64}"
open_shards_csv="${GOM_PRODUCTION_SLIDING_OPEN_SHARDS:-none}"
source_receipt="${GOM_PRODUCTION_SLIDING_SOURCE_RECEIPT:-}"
superseded_controller="${GOM_PRODUCTION_SLIDING_SUPERSEDED_CONTROLLER_JOB:-none}"

for command in "$production_python" git sbatch flock sha256sum; do
    command -v "$command" >/dev/null
done
[[ "$sliding_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
for value in "$next_start" "$max_lanes" "$max_concurrent"; do
    [[ "$value" =~ ^[0-9]+$ ]]
    test "$value" -ge 1
done
test "$max_lanes" -le 2 || {
    echo "At most two sliding shard lanes are permitted." >&2
    exit 1
}
test "$max_concurrent" -le 64 || {
    echo "The production CPU ceiling is 64 cases." >&2
    exit 1
}
if test "$superseded_controller" != none; then
    [[ "$superseded_controller" =~ ^[0-9]+$ ]]
fi

workflow_commit="$(git -C "$workflow_repo" rev-parse HEAD)"
simulation_commit="$(git -C "$simulation_repo" rev-parse HEAD)"
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
shard_verifier="$scripts/gom_step62_production_shard_verify.py"
controller="$workflow_repo/scripts/engaging/gom_step62_production_sliding_controller.sbatch"
for required in "$resolver" "$shard_verifier" "$controller"; do
    test -f "$required"
done

manifest_summary="$($production_python "$resolver" \
    --manifest "$campaign_manifest" summary --format shell)"
eval "$manifest_summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = full_1620
test "$GOM_PRODUCTION_CASE_COUNT" -eq 1620
test "$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" -eq 50
test "$GOM_PRODUCTION_JUTULDARCY_COMMIT" = "$simulation_commit"
test "$next_start" -le "$GOM_PRODUCTION_CASE_COUNT"
test "$(((next_start - 1) % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0

receipt_value() {
    local key="$1"
    local receipt="$2"
    local value
    value="$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' "$receipt")"
    test -n "$value"
    test "$(printf '%s\n' "$value" | wc -l)" -eq 1
    printf '%s' "$value"
}

source_sha256=none
if test "$next_start" -gt 1; then
    test -s "$source_receipt" || {
        echo "An attachment source receipt is required when start > 1." >&2
        exit 1
    }
    test "$(receipt_value status "$source_receipt")" = submitted
    test "$(receipt_value campaign_id "$source_receipt")" = \
        "$GOM_PRODUCTION_CAMPAIGN_ID"
    test "$(receipt_value manifest_sha256 "$source_receipt")" = \
        "$GOM_PRODUCTION_MANIFEST_SHA256"
    test "$(receipt_value selection_end "$source_receipt")" -eq \
        "$((next_start - 1))"
    source_sha256="$(sha256sum "$source_receipt" | awk '{print $1}')"
else
    test -z "$source_receipt"
fi

declare -A open_shards=()
open_count=0
if test "$open_shards_csv" != none; then
    IFS=',' read -r -a open_values <<< "$open_shards_csv"
    for range in "${open_values[@]}"; do
        [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        test "$start" -lt "$next_start"
        expected_end=$((start + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
        if test "$expected_end" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
            expected_end="$GOM_PRODUCTION_CASE_COUNT"
        fi
        test "$end" -eq "$expected_end"
        test "$(((start - 1) % GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))" -eq 0
        test -z "${open_shards[$range]:-}"
        open_shards[$range]=1
        open_count=$((open_count + 1))
    done
fi
test "$open_count" -lt "$max_lanes"

# Every earlier shard must be either checksum-verified durable or explicitly
# identified as the one in-flight shard that occupies a sliding lane.
campaign_shards="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/shards"
cursor=1
while test "$cursor" -lt "$next_start"; do
    shard_end=$((cursor + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
    if test "$shard_end" -gt "$GOM_PRODUCTION_CASE_COUNT"; then
        shard_end="$GOM_PRODUCTION_CASE_COUNT"
    fi
    range="${cursor}-${shard_end}"
    shard_name="shard_$(printf '%04d' "$cursor")_$(printf '%04d' "$shard_end")"
    shard_path="$campaign_shards/$shard_name"
    if test -n "${open_shards[$range]:-}"; then
        test ! -s "$shard_path/SHARD_COMPLETE" || {
            echo "Declared open shard is already durable: $range" >&2
            exit 1
        }
    else
        test -s "$shard_path/SHARD_COMPLETE"
        "$production_python" "$shard_verifier" \
            --manifest "$campaign_manifest" --shard "$shard_path" \
            --start "$cursor" --end "$shard_end" >/dev/null
    fi
    cursor=$((shard_end + 1))
done

IFS=',' read -r -a seed_dependencies <<< "$seed_dependencies_csv"
test "${#seed_dependencies[@]}" -eq "$max_lanes"
immediate_count=0
deferred_count=0
for dependency in "${seed_dependencies[@]}"; do
    if test "$dependency" = none; then
        immediate_count=$((immediate_count + 1))
    else
        [[ "$dependency" =~ ^[0-9]+$ ]]
        deferred_count=$((deferred_count + 1))
    fi
done
test "$deferred_count" -eq "$open_count" || {
    echo "Each open shard requires one dependency-gated seed lane." >&2
    exit 1
}
test "$immediate_count" -eq "$((max_lanes - open_count))"

state_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/sliding_submissions/$GOM_PRODUCTION_CAMPAIGN_ID"
state_dir="$state_parent/$sliding_id"
mkdir -p "$state_parent" "$gom_root/logs" "$gom_root/submissions"
if ! test -d "$state_dir"; then
    temporary_state="$state_parent/.${sliding_id}.tmp.$$"
    test ! -e "$temporary_state"
    mkdir -p "$temporary_state/controllers" "$temporary_state/claims" \
        "$temporary_state/receipts"
    printf '%s\n' \
        'status=configured' \
        "sliding_id=$sliding_id" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest=$campaign_manifest" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "simulation_repo=$simulation_repo" \
        "simulation_commit=$simulation_commit" \
        "workflow_repo=$workflow_repo" \
        "workflow_commit=$workflow_commit" \
        "case_count=$GOM_PRODUCTION_CASE_COUNT" \
        "shard_size=$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" \
        "initial_next_start=$next_start" \
        "max_lanes=$max_lanes" \
        "max_concurrent=$max_concurrent" \
        "open_shards=$open_shards_csv" \
        "seed_dependencies=$seed_dependencies_csv" \
        "source_receipt=${source_receipt:-none}" \
        "source_receipt_sha256=$source_sha256" \
        "superseded_controller_job=$superseded_controller" \
        "configured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$temporary_state/SLIDING_CONFIG"
    printf '%s\n' "$next_start" > "$temporary_state/NEXT_START"
    if test -n "$source_receipt"; then
        cp -- "$source_receipt" "$temporary_state/ATTACHMENT_SOURCE_RECEIPT"
    fi
    mv -- "$temporary_state" "$state_dir"
fi

config="$state_dir/SLIDING_CONFIG"
test -s "$config"
grep -Fxq "sliding_id=$sliding_id" "$config"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" "$config"
grep -Fxq "simulation_commit=$simulation_commit" "$config"
grep -Fxq "workflow_commit=$workflow_commit" "$config"
grep -Fxq "initial_next_start=$next_start" "$config"
grep -Fxq "seed_dependencies=$seed_dependencies_csv" "$config"
grep -Fxq "source_receipt_sha256=$source_sha256" "$config"

submitted_marker="$state_dir/SLIDING_SUBMITTED"
if test -s "$submitted_marker"; then
    cat "$submitted_marker"
    exit 0
fi

seed_lines=()
for index in "${!seed_dependencies[@]}"; do
    lane_id=$((index + 1))
    dependency="${seed_dependencies[$index]}"
    seed_record="$state_dir/controllers/seed_lane_${lane_id}.txt"
    if test -s "$seed_record"; then
        grep -Fxq "dependency_job=$dependency" "$seed_record"
        controller_job="$(awk -F= '$1 == "controller_job" {print $2}' "$seed_record")"
        [[ "$controller_job" =~ ^[0-9]+$ ]]
    else
        export_list="ALL,GOM_GRID_ROOT=$gom_root,GOM_PRODUCTION_SLIDING_WORKFLOW_REPO=$workflow_repo,GOM_PRODUCTION_SLIDING_WORKFLOW_COMMIT=$workflow_commit,GOM_PRODUCTION_SIM_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_SLIDING_ID=$sliding_id,GOM_PRODUCTION_SLIDING_LANE_ID=$lane_id,GOM_PRODUCTION_SLIDING_PHASE=release,GOM_PRODUCTION_PYTHON=$production_python"
        dependency_arguments=()
        if test "$dependency" != none; then
            dependency_arguments+=(--kill-on-invalid-dep=yes)
            dependency_arguments+=(--dependency="afterok:$dependency")
        fi
        raw_id="$(sbatch --parsable "${dependency_arguments[@]}" \
            --export="$export_list" "$controller")"
        controller_job="${raw_id%%;*}"
        [[ "$controller_job" =~ ^[0-9]+$ ]]
        temporary_seed="${seed_record}.tmp.$$"
        printf '%s\n' \
            'status=submitted' \
            "controller_job=$controller_job" \
            "dependency_job=$dependency" \
            "lane_id=$lane_id" \
            "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$temporary_seed"
        mv -- "$temporary_seed" "$seed_record"
    fi
    seed_lines+=("lane_${lane_id}_controller_job=$controller_job")
    seed_lines+=("lane_${lane_id}_dependency=$dependency")
done

temporary_marker="${submitted_marker}.tmp.$$"
printf '%s\n' \
    'status=submitted' \
    "sliding_id=$sliding_id" \
    "initial_next_start=$next_start" \
    "max_lanes=$max_lanes" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${seed_lines[@]}" \
    > "$temporary_marker"
mv -- "$temporary_marker" "$submitted_marker"
cat "$submitted_marker"
