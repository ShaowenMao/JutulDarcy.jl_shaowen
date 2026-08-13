#!/bin/bash
# Submit a schema-2/3 Step62 campaign as dependency-gated durable shards.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"

command -v sbatch >/dev/null
command -v scancel >/dev/null
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$production_python" >/dev/null
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
scripts="$JUTULDARCY_COMBINED_REPO/scripts/engaging"
resolver="$scripts/gom_step62_production_manifest.py"
shard_verifier="$scripts/gom_step62_production_shard_verify.py"
mkdir -p "$gom_root/logs" "$gom_root/submissions"
test -f "$shard_verifier"

"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
    validate
manifest_summary="$($production_python "$resolver" \
    --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$manifest_summary"
case "$GOM_PRODUCTION_SCHEMA_VERSION" in
    2|3) ;;
    *)
        echo "The ensemble submitter requires manifest schema 2 or 3." >&2
        exit 1
        ;;
esac
case "$GOM_PRODUCTION_PHYSICS_PROFILE" in
    legacy_fault_plateau_npctheta30)
        preflight_script="$scripts/gom_step62_production_preflight.sbatch"
        full_script="$scripts/gom_step62_production_full.sbatch"
        vtu_script="$scripts/gom_step62_production_vtu.sbatch"
        ;;
    sandpc_effective_globalplateau_v1)
        preflight_script="$scripts/gom_step62_effective_pc_global_plateau_preflight.sbatch"
        full_script="$scripts/gom_step62_effective_pc_global_plateau_full.sbatch"
        vtu_script="$scripts/gom_step62_effective_pc_global_plateau_vtu.sbatch"
        ;;
    *)
        echo "Unsupported physics profile: $GOM_PRODUCTION_PHYSICS_PROFILE" >&2
        exit 1
        ;;
esac
test -f "$preflight_script"
test -f "$full_script"
test -f "$vtu_script"

selection_start="${GOM_PRODUCTION_SELECTION_START:-1}"
selection_end="${GOM_PRODUCTION_SELECTION_END:-$GOM_PRODUCTION_CASE_COUNT}"
max_concurrent="${GOM_PRODUCTION_MAX_CONCURRENT:-64}"
shard_window="${GOM_PRODUCTION_SHARD_WINDOW:-2}"
for value in "$selection_start" "$selection_end" \
    "$max_concurrent" "$shard_window"
do
    [[ "$value" =~ ^[0-9]+$ ]]
done
test "$selection_start" -ge 1
test "$selection_end" -ge "$selection_start"
test "$selection_end" -le "$GOM_PRODUCTION_CASE_COUNT"
test "$max_concurrent" -ge 1
test "$max_concurrent" -le 64 || {
    echo "GOM_PRODUCTION_MAX_CONCURRENT cannot exceed the 64-task CPU ceiling." >&2
    exit 1
}
test "$shard_window" -ge 1

if test "$selection_start" -eq 1 && \
   test "$selection_end" -eq "$GOM_PRODUCTION_CASE_COUNT"; then
    case "$GOM_PRODUCTION_ENSEMBLE_KIND" in
        full_1620)
            test "${GOM_PRODUCTION_CONFIRM_FULL_1620:-}" = YES || {
                echo "Set GOM_PRODUCTION_CONFIRM_FULL_1620=YES only after the acceptance and canary gates pass." >&2
                exit 1
            }
            ;;
        phase1_2430)
            test "${GOM_PRODUCTION_CONFIRM_PHASE1_2430:-}" = YES || {
                echo "Set GOM_PRODUCTION_CONFIRM_PHASE1_2430=YES only after the acceptance and canary gates pass." >&2
                exit 1
            }
            ;;
    esac
fi

observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT" || {
    echo "JutulDarcy checkout does not match the campaign manifest." >&2
    exit 1
}
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)" || {
    echo "JutulDarcy checkout must be clean before production submission." >&2
    exit 1
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
submission_id="${GOM_PRODUCTION_SUBMISSION_ID:-${GOM_PRODUCTION_CAMPAIGN_ID}_${selection_start}_${selection_end}_${timestamp}}"
[[ "$submission_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || {
    echo "Unsafe GOM_PRODUCTION_SUBMISSION_ID: $submission_id" >&2
    exit 1
}

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if test "$submission_complete" != true && \
       test "${#submitted_jobs[@]}" -gt 0; then
        echo "Submission failed; cancelling partial DAG: ${submitted_jobs[*]}" >&2
        scancel "${submitted_jobs[@]}" || true
    fi
    return "$exit_code"
}
trap cancel_partial_dag EXIT

submit_job() {
    raw_id="$(sbatch --parsable "$@")"
    job_id="${raw_id%%;*}"
    [[ "$job_id" =~ ^[0-9]+$ ]] || {
        echo "Unexpected sbatch job ID: $raw_id" >&2
        return 1
    }
    submitted_jobs+=("$job_id")
    submitted_job_id="$job_id"
}

join_colon_or_none() {
    if test "$#" -eq 0; then
        printf 'none'
    else
        local IFS=:
        printf '%s' "$*"
    fi
}

common_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST"
submit_job --kill-on-invalid-dep=yes --export="$common_export" \
    "$scripts/gom_step62_production_campaign_check.sbatch"
check_job="$submitted_job_id"

shard_receipt="$gom_root/submissions/${submission_id}_shards.tsv"
temporary_shards="${shard_receipt}.tmp.$$"
printf 'shard_index\ttask_start\ttask_end\tmode\tpreflight_job\tfull_job\tvtu_job\tarchive_job\twave_gate_archive_job\tarchive_path\n' \
    > "$temporary_shards"

preflight_jobs=()
full_jobs=()
vtu_jobs=()
archive_jobs=()
logical_archive_gates=()
reused_shard_ranges=()
campaign_root="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
cursor="$selection_start"
shard_index=0
while test "$cursor" -le "$selection_end"; do
    shard_index=$((shard_index + 1))
    shard_end=$((cursor + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
    if test "$shard_end" -gt "$selection_end"; then
        shard_end="$selection_end"
    fi
    shard_count=$((shard_end - cursor + 1))
    shard_concurrent="$max_concurrent"
    if test "$shard_concurrent" -gt "$shard_count"; then
        shard_concurrent="$shard_count"
    fi
    array_spec="${cursor}-${shard_end}%${shard_concurrent}"

    shard_name="shard_$(printf '%04d' "$cursor")_$(printf '%04d' "$shard_end")"
    durable_shard="$campaign_root/shards/$shard_name"

    dependency="afterok:$check_job"
    wave_gate=none
    if test "$shard_index" -gt "$shard_window"; then
        gate_index=$((shard_index - shard_window - 1))
        wave_gate="${logical_archive_gates[$gate_index]}"
        if test "$wave_gate" != none; then
            dependency="afterok:${check_job}:${wave_gate}"
        fi
    fi

    mode=new
    preflight_job=none
    full_job=none
    vtu_job=none
    archive_job=none
    if test -e "$durable_shard"; then
        # Never overwrite or silently trust a durable shard. Reuse is allowed
        # only after the exact campaign, task order, and pinned control-plane
        # checks succeed.
        "$production_python" "$shard_verifier" \
            --manifest "$GOM_PRODUCTION_MANIFEST" \
            --shard "$durable_shard" --start "$cursor" --end "$shard_end"
        mode=reused
        reused_shard_ranges+=("${cursor}-${shard_end}")
    else
        submit_job --kill-on-invalid-dep=yes \
            --dependency="$dependency" \
            --array="$array_spec" \
            --export="$common_export" \
            "$preflight_script"
        preflight_job="$submitted_job_id"
        preflight_jobs+=("$preflight_job")

        submit_job --kill-on-invalid-dep=yes \
            --dependency="aftercorr:$preflight_job" \
            --array="$array_spec" \
            --time=4-00:00:00 \
            --export="$common_export,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job" \
            "$full_script"
        full_job="$submitted_job_id"
        full_jobs+=("$full_job")

        submit_job --kill-on-invalid-dep=yes \
            --dependency="aftercorr:$full_job" \
            --array="$array_spec" \
            --export="$common_export,GOM_PRODUCTION_FULL_JOB_ID=$full_job" \
            "$vtu_script"
        vtu_job="$submitted_job_id"
        vtu_jobs+=("$vtu_job")

        submit_job --kill-on-invalid-dep=yes \
            --dependency="afterok:$vtu_job" \
            --export="$common_export,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job,GOM_PRODUCTION_FULL_JOB_ID=$full_job,GOM_PRODUCTION_VTU_JOB_ID=$vtu_job,GOM_PRODUCTION_TASK_START=$cursor,GOM_PRODUCTION_TASK_END=$shard_end,GOM_PRODUCTION_SUBMISSION_ID=$submission_id" \
            "$scripts/gom_step62_production_shard_archive.sbatch"
        archive_job="$submitted_job_id"
        archive_jobs+=("$archive_job")
    fi
    logical_archive_gates+=("$archive_job")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$shard_index" "$cursor" "$shard_end" "$mode" \
        "$preflight_job" "$full_job" "$vtu_job" "$archive_job" \
        "$wave_gate" "$durable_shard" >> "$temporary_shards"
    cursor=$((shard_end + 1))
done
mv -- "$temporary_shards" "$shard_receipt"

logical_shard_count="${#logical_archive_gates[@]}"
new_shard_count="${#archive_jobs[@]}"
reused_shard_count="${#reused_shard_ranges[@]}"
test "$((new_shard_count + reused_shard_count))" -eq "$logical_shard_count"
archive_job_ids="$(join_colon_or_none "${archive_jobs[@]}")"
reused_ranges="$(join_colon_or_none "${reused_shard_ranges[@]}")"
if test "$new_shard_count" -eq 0; then
    archive_dependency="afterok:$check_job"
else
    archive_dependency="afterok:$(join_colon_or_none "${archive_jobs[@]}")"
fi
submit_job --kill-on-invalid-dep=yes \
    --dependency="$archive_dependency" \
    --export="$common_export,GOM_PRODUCTION_SELECTION_START=$selection_start,GOM_PRODUCTION_SELECTION_END=$selection_end,GOM_PRODUCTION_SUBMISSION_ID=$submission_id,GOM_PRODUCTION_ARCHIVE_JOB_IDS=$archive_job_ids,GOM_PRODUCTION_NEW_SHARD_COUNT=$new_shard_count,GOM_PRODUCTION_REUSED_SHARD_COUNT=$reused_shard_count,GOM_PRODUCTION_REUSED_SHARD_RANGES=$reused_ranges" \
    "$scripts/gom_step62_production_finalize.sbatch"
finalize_job="$submitted_job_id"

receipt="$gom_root/submissions/${submission_id}.txt"
temporary_receipt="${receipt}.tmp.$$"
printf '%s\n' \
    "status=submitted" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "submission_id=$submission_id" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "manifest=$GOM_PRODUCTION_MANIFEST" \
    "manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
    "ensemble_kind=$GOM_PRODUCTION_ENSEMBLE_KIND" \
    "selection_start=$selection_start" \
    "selection_end=$selection_end" \
    "selection_count=$((selection_end - selection_start + 1))" \
    "archive_shard_size=$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" \
    "shard_count=$logical_shard_count" \
    "new_shard_count=$new_shard_count" \
    "reused_shard_count=$reused_shard_count" \
    "reused_shard_ranges=$reused_ranges" \
    "shard_window=$shard_window" \
    "max_concurrent=$max_concurrent" \
    "qoi_mode=$GOM_PRODUCTION_QOI_MODE" \
    "qoi_schema_version=$GOM_PRODUCTION_QOI_SCHEMA_VERSION" \
    "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
    "campaign_check_job=$check_job" \
    "preflight_array_jobs=$(join_colon_or_none "${preflight_jobs[@]}")" \
    "full_array_jobs=$(join_colon_or_none "${full_jobs[@]}")" \
    "vtu_array_jobs=$(join_colon_or_none "${vtu_jobs[@]}")" \
    "archive_jobs=$archive_job_ids" \
    "finalize_job=$finalize_job" \
    "shard_receipt=$shard_receipt" \
    > "$temporary_receipt"
mv -- "$temporary_receipt" "$receipt"

durable_receipt_root="$GOM_PRODUCTION_ARCHIVE_ROOT/submission_receipts/$GOM_PRODUCTION_CAMPAIGN_ID"
mkdir -p "$durable_receipt_root"
durable_temporary="$durable_receipt_root/.${submission_id}.txt.tmp.$$"
cp -- "$receipt" "$durable_temporary"
mv -- "$durable_temporary" "$durable_receipt_root/${submission_id}.txt"
cp -- "$shard_receipt" "$durable_receipt_root/${submission_id}_shards.tsv"

submission_complete=true
trap - EXIT
cat "$receipt"
printf 'submission_receipt=%s\n' "$receipt"
