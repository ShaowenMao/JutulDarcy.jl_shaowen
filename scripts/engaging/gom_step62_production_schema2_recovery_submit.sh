#!/bin/bash
# Submit a fail-closed checkpoint-recovery DAG for one schema-2 campaign.

set -euo pipefail
umask 027

: "${GOM_RECOVERY_WORKFLOW_REPO:?Set GOM_RECOVERY_WORKFLOW_REPO.}"
: "${GOM_RECOVERY_SIM_REPO:?Set GOM_RECOVERY_SIM_REPO.}"
: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_RECOVERY_SOURCE_RECEIPT:?Set GOM_RECOVERY_SOURCE_RECEIPT.}"
: "${GOM_RECOVERY_TASKS:?Set GOM_RECOVERY_TASKS.}"
: "${GOM_RECOVERY_SUBMISSION_ID:?Set GOM_RECOVERY_SUBMISSION_ID.}"

command -v sbatch >/dev/null
command -v scancel >/dev/null
recovery_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$recovery_python" >/dev/null

workflow_repo="$(realpath "$GOM_RECOVERY_WORKFLOW_REPO")"
simulation_repo="$(realpath "$GOM_RECOVERY_SIM_REPO")"
campaign_manifest="$(realpath "$GOM_PRODUCTION_MANIFEST")"
source_receipt="$(realpath "$GOM_RECOVERY_SOURCE_RECEIPT")"
if test -n "${GOM_RECOVERY_SOURCE_SHARDS:-}"; then
    source_shards="$(realpath "$GOM_RECOVERY_SOURCE_SHARDS")"
else
    case "$source_receipt" in
        *.txt) source_shards="$(realpath "${source_receipt%.txt}_shards.tsv")" ;;
        *)
            echo "Set GOM_RECOVERY_SOURCE_SHARDS when the receipt does not end in .txt." >&2
            exit 1
            ;;
    esac
fi
recovery_id="$GOM_RECOVERY_SUBMISSION_ID"
[[ "$recovery_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || {
    echo "Unsafe GOM_RECOVERY_SUBMISSION_ID: $recovery_id" >&2
    exit 1
}

for repo in "$workflow_repo" "$simulation_repo"; do
    test -z "$(git -C "$repo" status --porcelain)" || {
        echo "Recovery checkouts must be clean: $repo" >&2
        exit 1
    }
done
workflow_commit="$(git -C "$workflow_repo" rev-parse HEAD)"
simulation_commit="$(git -C "$simulation_repo" rev-parse HEAD)"
[[ "$workflow_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$simulation_commit" =~ ^[0-9a-f]{40}$ ]]
test "$(git -C "$workflow_repo" rev-parse HEAD:src)" = \
    "$(git -C "$simulation_repo" rev-parse HEAD:src)" || {
    echo "Recovery-control and simulation src trees differ." >&2
    exit 1
}
cmp -s "$workflow_repo/Project.toml" "$simulation_repo/Project.toml"
cmp -s "$workflow_repo/Manifest.toml" "$simulation_repo/Manifest.toml"

workflow_scripts="$workflow_repo/scripts/engaging"
simulation_scripts="$simulation_repo/scripts/engaging"
plan_tool="$workflow_scripts/gom_step62_production_schema2_recovery_plan.py"
manifest_tool="$simulation_scripts/gom_step62_production_manifest.py"
for required in \
    "$plan_tool" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_gate.sbatch" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_case.sbatch" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_vtu.sbatch" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_complete.sbatch" \
    "$simulation_scripts/gom_step62_production_shard_archive.sbatch" \
    "$simulation_scripts/gom_step62_production_finalize.sbatch"
do
    test -s "$required"
done

"$recovery_python" "$manifest_tool" \
    --manifest "$campaign_manifest" validate
manifest_summary="$(
    "$recovery_python" "$manifest_tool" \
        --manifest "$campaign_manifest" summary --format shell
)"
eval "$manifest_summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2
test "$GOM_PRODUCTION_PHYSICS_PROFILE" = \
    sandpc_effective_globalplateau_v1
test "$GOM_PRODUCTION_QOI_MODE" = required
test "$simulation_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT" || {
    echo "Simulation checkout does not match the campaign manifest." >&2
    exit 1
}

max_concurrent="${GOM_RECOVERY_MAX_CONCURRENT:-64}"
[[ "$max_concurrent" =~ ^[0-9]+$ ]]
test "$max_concurrent" -ge 1
test "$max_concurrent" -le 64 || {
    echo "GOM_RECOVERY_MAX_CONCURRENT cannot exceed 64." >&2
    exit 1
}

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
mkdir -p "$gom_root/logs" "$gom_root/submissions" \
    "$gom_root/recovery_plans/$GOM_PRODUCTION_CAMPAIGN_ID"
plan_dir="$gom_root/recovery_plans/$GOM_PRODUCTION_CAMPAIGN_ID/$recovery_id"
test ! -e "$plan_dir" || {
    echo "Recovery plan directory already exists: $plan_dir" >&2
    exit 1
}
mkdir "$plan_dir"
plan="$plan_dir/recovery_plan.toml"
"$recovery_python" "$plan_tool" build \
    --manifest "$campaign_manifest" \
    --source-receipt "$source_receipt" \
    --source-shards "$source_shards" \
    --tasks "$GOM_RECOVERY_TASKS" \
    --recovery-id "$recovery_id" \
    --workflow-commit "$workflow_commit" \
    --simulation-repo "$simulation_repo" \
    --output "$plan"
plan_summary="$(
    "$recovery_python" "$plan_tool" summary --plan "$plan" --format shell
)"
eval "$plan_summary"
test "$GOM_RECOVERY_ID" = "$recovery_id"
test "$GOM_RECOVERY_SIMULATION_COMMIT" = "$simulation_commit"
test "$GOM_RECOVERY_WORKFLOW_COMMIT" = "$workflow_commit"

durable_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/recovery_submissions/$GOM_PRODUCTION_CAMPAIGN_ID"
durable_dir="$durable_parent/$recovery_id"
test ! -e "$durable_dir" || {
    echo "Durable recovery ID already exists: $durable_dir" >&2
    exit 1
}
mkdir -p "$durable_parent"
durable_stage="$durable_parent/.${recovery_id}.tmp.$$"
test ! -e "$durable_stage"
mkdir "$durable_stage"
cp -- "$plan" "$durable_stage/recovery_plan.toml"
cp -- "${plan}.sha256" "$durable_stage/recovery_plan.toml.sha256"
cp -- "$source_receipt" \
    "$durable_stage/source_submission_receipt.txt"
cp -- "$source_shards" \
    "$durable_stage/source_submission_shards.tsv"
mv -- "$durable_stage" "$durable_dir"

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if test "$submission_complete" != true; then
        if test "${#submitted_jobs[@]}" -gt 0; then
            echo "Recovery submission failed; cancelling partial DAG:" \
                "${submitted_jobs[*]}" >&2
            scancel "${submitted_jobs[@]}" || true
        fi
        if test -d "$durable_dir" && \
           ! test -e "$durable_dir/SUBMISSION_ABORTED"; then
            printf 'status=aborted\nexit_code=%s\nfailed_utc=%s\n' \
                "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$durable_dir/SUBMISSION_ABORTED"
        fi
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

selected_concurrent="$max_concurrent"
if test "$selected_concurrent" -gt "$GOM_RECOVERY_SELECTED_CASE_COUNT"; then
    selected_concurrent="$GOM_RECOVERY_SELECTED_CASE_COUNT"
fi
coverage_concurrent="$max_concurrent"
if test "$coverage_concurrent" -gt "$GOM_RECOVERY_COVERAGE_CASE_COUNT"; then
    coverage_concurrent="$GOM_RECOVERY_COVERAGE_CASE_COUNT"
fi
selected_array="${GOM_RECOVERY_SELECTED_TASK_SPEC}%${selected_concurrent}"
coverage_array="${GOM_RECOVERY_COVERAGE_TASK_SPEC}%${coverage_concurrent}"

common_export="ALL,GOM_GRID_ROOT=$gom_root,GOM_RECOVERY_WORKFLOW_REPO=$workflow_repo,GOM_RECOVERY_WORKFLOW_COMMIT=$workflow_commit,GOM_RECOVERY_PLAN=$plan,GOM_RECOVERY_PLAN_SHA256=$GOM_RECOVERY_PLAN_SHA256"
submit_job --kill-on-invalid-dep=yes --export="$common_export" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_gate.sbatch"
gate_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$gate_job" \
    --array="$selected_array" \
    --time=4-00:00:00 \
    --export="$common_export,GOM_RECOVERY_GATE_JOB_ID=$gate_job" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_case.sbatch"
case_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$case_job" \
    --array="$coverage_array" \
    --export="$common_export,GOM_RECOVERY_CASE_JOB_ID=$case_job" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_vtu.sbatch"
vtu_job="$submitted_job_id"

archive_jobs=()
finalizer_jobs=()
shard_submission_ids=()
mapfile -t shard_rows < <(
    "$recovery_python" "$plan_tool" shards \
        --plan "$plan" --format tsv | tail -n +2
)
test "${#shard_rows[@]}" -eq "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
for row in "${shard_rows[@]}"; do
    IFS=$'\t' read -r start end source_preflight source_full \
        source_vtu source_archive archive_path <<< "$row"
    shard_submission_id="${recovery_id}_shard_${start}_${end}"
    [[ "$shard_submission_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
    shard_submission_ids+=("$shard_submission_id")
    archive_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_CHECK_JOB_ID=$GOM_RECOVERY_SOURCE_CHECK_JOB,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$source_preflight,GOM_PRODUCTION_FULL_JOB_ID=$source_full,GOM_PRODUCTION_VTU_JOB_ID=$vtu_job,GOM_PRODUCTION_TASK_START=$start,GOM_PRODUCTION_TASK_END=$end,GOM_PRODUCTION_SUBMISSION_ID=$shard_submission_id"
    submit_job --kill-on-invalid-dep=yes \
        --dependency="afterok:$vtu_job" \
        --export="$archive_export" \
        "$simulation_scripts/gom_step62_production_shard_archive.sbatch"
    archive_job="$submitted_job_id"
    archive_jobs+=("$archive_job")

    finalizer_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$simulation_repo,GOM_PRODUCTION_MANIFEST=$campaign_manifest,GOM_PRODUCTION_SELECTION_START=$start,GOM_PRODUCTION_SELECTION_END=$end,GOM_PRODUCTION_SUBMISSION_ID=$shard_submission_id,GOM_PRODUCTION_ARCHIVE_JOB_IDS=$archive_job,GOM_PRODUCTION_NEW_SHARD_COUNT=1,GOM_PRODUCTION_REUSED_SHARD_COUNT=0,GOM_PRODUCTION_REUSED_SHARD_RANGES=none"
    submit_job --kill-on-invalid-dep=yes \
        --dependency="afterok:$archive_job" \
        --export="$finalizer_export" \
        "$simulation_scripts/gom_step62_production_finalize.sbatch"
    finalizer_jobs+=("$submitted_job_id")
done

join_colon() {
    local IFS=:
    printf '%s' "$*"
}
archive_job_ids="$(join_colon "${archive_jobs[@]}")"
finalizer_job_ids="$(join_colon "${finalizer_jobs[@]}")"
shard_submission_id_list="$(join_colon "${shard_submission_ids[@]}")"
completion_dependency="afterok:$finalizer_job_ids"
launch_receipt="$durable_dir/submission_receipt.txt"
completion_export="ALL,GOM_GRID_ROOT=$gom_root,GOM_RECOVERY_WORKFLOW_REPO=$workflow_repo,GOM_RECOVERY_WORKFLOW_COMMIT=$workflow_commit,GOM_RECOVERY_PLAN=$plan,GOM_RECOVERY_PLAN_SHA256=$GOM_RECOVERY_PLAN_SHA256,GOM_RECOVERY_GATE_JOB_ID=$gate_job,GOM_RECOVERY_CASE_JOB_ID=$case_job,GOM_RECOVERY_VTU_JOB_ID=$vtu_job,GOM_RECOVERY_ARCHIVE_JOB_IDS=$archive_job_ids,GOM_RECOVERY_FINALIZER_JOB_IDS=$finalizer_job_ids,GOM_RECOVERY_SHARD_SUBMISSION_IDS=$shard_submission_id_list,GOM_RECOVERY_DURABLE_DIR=$durable_dir,GOM_RECOVERY_LAUNCH_RECEIPT=$launch_receipt"
submit_job --kill-on-invalid-dep=yes \
    --dependency="$completion_dependency" \
    --export="$completion_export" \
    "$workflow_scripts/gom_step62_production_schema2_recovery_complete.sbatch"
completion_job="$submitted_job_id"

scratch_receipt="$gom_root/submissions/${recovery_id}_recovery.txt"
test ! -e "$scratch_receipt"
receipt_tmp="${scratch_receipt}.tmp.$$"
printf '%s\n' \
    'status=submitted' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "recovery_id=$recovery_id" \
    "campaign_id=$GOM_RECOVERY_CAMPAIGN_ID" \
    "campaign_manifest=$campaign_manifest" \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    "recovery_plan=$plan" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "workflow_repo=$workflow_repo" \
    "workflow_commit=$workflow_commit" \
    "simulation_repo=$simulation_repo" \
    "simulation_commit=$simulation_commit" \
    "source_submission_id=$GOM_RECOVERY_SOURCE_SUBMISSION_ID" \
    "source_receipt=$source_receipt" \
    "source_shards=$source_shards" \
    "selected_task_spec=$GOM_RECOVERY_SELECTED_TASK_SPEC" \
    "coverage_task_spec=$GOM_RECOVERY_COVERAGE_TASK_SPEC" \
    "selected_case_count=$GOM_RECOVERY_SELECTED_CASE_COUNT" \
    "coverage_case_count=$GOM_RECOVERY_COVERAGE_CASE_COUNT" \
    "affected_shard_count=$GOM_RECOVERY_AFFECTED_SHARD_COUNT" \
    "max_concurrent=$max_concurrent" \
    "gate_job=$gate_job" \
    "case_array_job=$case_job" \
    "vtu_array_job=$vtu_job" \
    "archive_jobs=$archive_job_ids" \
    "finalizer_jobs=$finalizer_job_ids" \
    "completion_job=$completion_job" \
    "durable_recovery_dir=$durable_dir" \
    > "$receipt_tmp"
mv -- "$receipt_tmp" "$scratch_receipt"
cp -- "$scratch_receipt" "$launch_receipt.tmp.$$"
mv -- "$launch_receipt.tmp.$$" "$launch_receipt"

submission_complete=true
trap - EXIT
cat "$scratch_receipt"
printf 'submission_receipt=%s\n' "$scratch_receipt"
