#!/bin/bash
#SBATCH --job-name=gom_s62_s2_recover_done
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Certify only the recovered shard set. This job deliberately cannot create
# CAMPAIGN_COMPLETE; the normal full-selection finalizer retains that role.

set -euo pipefail
umask 027

: "${GOM_RECOVERY_GATE_JOB_ID:?Set GOM_RECOVERY_GATE_JOB_ID.}"
: "${GOM_RECOVERY_CASE_JOB_ID:?Set GOM_RECOVERY_CASE_JOB_ID.}"
: "${GOM_RECOVERY_VTU_JOB_ID:?Set GOM_RECOVERY_VTU_JOB_ID.}"
: "${GOM_RECOVERY_ARCHIVE_JOB_IDS:?Set GOM_RECOVERY_ARCHIVE_JOB_IDS.}"
: "${GOM_RECOVERY_FINALIZER_JOB_IDS:?Set GOM_RECOVERY_FINALIZER_JOB_IDS.}"
: "${GOM_RECOVERY_SHARD_SUBMISSION_IDS:?Set GOM_RECOVERY_SHARD_SUBMISSION_IDS.}"
: "${GOM_RECOVERY_DURABLE_DIR:?Set GOM_RECOVERY_DURABLE_DIR.}"
: "${GOM_RECOVERY_LAUNCH_RECEIPT:?Set GOM_RECOVERY_LAUNCH_RECEIPT.}"

for job_id in \
    "$GOM_RECOVERY_GATE_JOB_ID" \
    "$GOM_RECOVERY_CASE_JOB_ID" \
    "$GOM_RECOVERY_VTU_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]]
done

source \
    "$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_common.sh"

IFS=: read -r -a archive_jobs <<< "$GOM_RECOVERY_ARCHIVE_JOB_IDS"
IFS=: read -r -a finalizer_jobs <<< "$GOM_RECOVERY_FINALIZER_JOB_IDS"
IFS=: read -r -a shard_submission_ids \
    <<< "$GOM_RECOVERY_SHARD_SUBMISSION_IDS"
test "${#archive_jobs[@]}" -eq "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
test "${#finalizer_jobs[@]}" -eq "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
test "${#shard_submission_ids[@]}" -eq \
    "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
for job_id in "${archive_jobs[@]}" "${finalizer_jobs[@]}"; do
    [[ "$job_id" =~ ^[0-9]+$ ]]
done
for submission_id in "${shard_submission_ids[@]}"; do
    [[ "$submission_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
done

export JUTULDARCY_COMBINED_REPO="$recovery_sim_repo"
export GOM_PRODUCTION_MANIFEST="$GOM_RECOVERY_CAMPAIGN_MANIFEST"
resolver="$recovery_sim_repo/scripts/engaging/gom_step62_production_manifest.py"
shard_verifier="$recovery_sim_repo/scripts/engaging/gom_step62_production_shard_verify.py"
manifest_summary="$(
    "$recovery_python" "$resolver" \
        --manifest "$GOM_RECOVERY_CAMPAIGN_MANIFEST" summary --format shell
)"
eval "$manifest_summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2
test "$GOM_PRODUCTION_MANIFEST_SHA256" = \
    "$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256"

expected_durable_dir="$GOM_PRODUCTION_ARCHIVE_ROOT/recovery_submissions/$GOM_RECOVERY_CAMPAIGN_ID/$GOM_RECOVERY_ID"
test "$(realpath "$GOM_RECOVERY_DURABLE_DIR")" = \
    "$(realpath "$expected_durable_dir")"
test -d "$GOM_RECOVERY_DURABLE_DIR"
test ! -e "$GOM_RECOVERY_DURABLE_DIR/RECOVERY_COMPLETE"
test "$(realpath "$GOM_RECOVERY_LAUNCH_RECEIPT")" = \
    "$(realpath "$GOM_RECOVERY_DURABLE_DIR/submission_receipt.txt")"
test -s "$GOM_RECOVERY_LAUNCH_RECEIPT"
grep -Fxq 'status=submitted' "$GOM_RECOVERY_LAUNCH_RECEIPT"
grep -Fxq "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "$GOM_RECOVERY_LAUNCH_RECEIPT"

cmp -s "$GOM_RECOVERY_PLAN" \
    "$GOM_RECOVERY_DURABLE_DIR/recovery_plan.toml"
cmp -s "${GOM_RECOVERY_PLAN}.sha256" \
    "$GOM_RECOVERY_DURABLE_DIR/recovery_plan.toml.sha256"
cmp -s "$GOM_RECOVERY_SOURCE_RECEIPT" \
    "$GOM_RECOVERY_DURABLE_DIR/source_submission_receipt.txt"
cmp -s "$GOM_RECOVERY_SOURCE_SHARDS" \
    "$GOM_RECOVERY_DURABLE_DIR/source_submission_shards.tsv"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_dir="$gom_root/results/gom_step62_schema2_recovery_complete_job${SLURM_JOB_ID}"
test ! -e "$result_dir"
mkdir -p "$result_dir/shard_control"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

gate_dir="$gom_root/results/gom_step62_schema2_recovery_gate_job${GOM_RECOVERY_GATE_JOB_ID}"
test -f "$gate_dir/PASS"
grep -Fxq "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "$gate_dir/gate_summary.txt"
case_attempt_root="$gom_root/results/gom_step62_schema2_recovery_case_job${GOM_RECOVERY_CASE_JOB_ID}"
while IFS= read -r task; do
    gom_recovery_resolve_plan_task "$task"
    test -f "$case_attempt_root/$GOM_RECOVERY_CASE_KEY/PASS"
    grep -Fxq "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
        "$case_attempt_root/$GOM_RECOVERY_CASE_KEY/recovery_summary.txt"
done < <(
    "$recovery_python" "$recovery_plan_tool" tasks \
        --plan "$GOM_RECOVERY_PLAN" --scope selected
)

mapfile -t shard_rows < <(
    "$recovery_python" "$recovery_plan_tool" shards \
        --plan "$GOM_RECOVERY_PLAN" --format tsv | tail -n +2
)
test "${#shard_rows[@]}" -eq "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
printf 'task_start\ttask_end\tarchive_job\tfinalizer_job\tarchive_path\tsubmission_receipt\n' \
    > "$result_dir/recovered_shards.tsv"

campaign_root="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_RECOVERY_CAMPAIGN_ID"
for index in "${!shard_rows[@]}"; do
    IFS=$'\t' read -r start end source_preflight source_full \
        source_vtu source_archive archive_path <<< "${shard_rows[$index]}"
    archive_job="${archive_jobs[$index]}"
    finalizer_job="${finalizer_jobs[$index]}"
    shard_submission_id="${shard_submission_ids[$index]}"
    archive_result="$gom_root/results/gom_step62_production_shard_archive_job${archive_job}"
    finalizer_result="$gom_root/results/gom_step62_production_finalize_job${finalizer_job}"
    test -f "$archive_result/PASS"
    test -f "$finalizer_result/PASS"
    grep -Fxq 'status=pass' "$archive_result/archive_summary.txt"
    grep -Fxq "submission_id=$shard_submission_id" \
        "$archive_result/archive_summary.txt"
    grep -Fxq "task_start=$start" "$archive_result/archive_summary.txt"
    grep -Fxq "task_end=$end" "$archive_result/archive_summary.txt"
    grep -Fxq "archive_path=$archive_path" \
        "$archive_result/archive_summary.txt"
    grep -Fxq 'status=pass' "$finalizer_result/finalize_summary.txt"
    grep -Fxq "submission_id=$shard_submission_id" \
        "$finalizer_result/finalize_summary.txt"
    grep -Fxq "selection_start=$start" \
        "$finalizer_result/finalize_summary.txt"
    grep -Fxq "selection_end=$end" \
        "$finalizer_result/finalize_summary.txt"
    grep -Fxq 'new_shard_count=1' \
        "$finalizer_result/finalize_summary.txt"
    grep -Fxq 'reused_shard_count=0' \
        "$finalizer_result/finalize_summary.txt"
    grep -Fxq 'campaign_complete=false' \
        "$finalizer_result/finalize_summary.txt"

    verification="$result_dir/shard_control/shard_$(printf '%04d' "$start")_$(printf '%04d' "$end").json"
    "$recovery_python" "$shard_verifier" \
        --manifest "$GOM_RECOVERY_CAMPAIGN_MANIFEST" \
        --shard "$archive_path" --start "$start" --end "$end" --json \
        > "$verification"
    submission_receipt="$campaign_root/submissions/$shard_submission_id"
    test -s "$submission_receipt/SUBMISSION_COMPLETE"
    grep -Fxq 'status=pass' "$submission_receipt/SUBMISSION_COMPLETE"
    grep -Fxq "selection_start=$start" \
        "$submission_receipt/SUBMISSION_COMPLETE"
    grep -Fxq "selection_end=$end" \
        "$submission_receipt/SUBMISSION_COMPLETE"
    (
        cd "$submission_receipt"
        sha256sum --check RECEIPT_SHA256SUMS
    )
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$start" "$end" "$archive_job" "$finalizer_job" \
        "$archive_path" "$submission_receipt" \
        >> "$result_dir/recovered_shards.tsv"
done

test "$(( $(wc -l < "$result_dir/recovered_shards.tsv") - 1 ))" -eq \
    "$GOM_RECOVERY_AFFECTED_SHARD_COUNT"
printf '%s\n' \
    'status=pass' \
    'operation=schema2_checkpoint_recovery' \
    "recovery_id=$GOM_RECOVERY_ID" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "recovery_workflow_commit=$GOM_RECOVERY_WORKFLOW_COMMIT" \
    "simulation_commit=$GOM_RECOVERY_SIMULATION_COMMIT" \
    "campaign_id=$GOM_RECOVERY_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    "source_submission_id=$GOM_RECOVERY_SOURCE_SUBMISSION_ID" \
    "selected_task_spec=$GOM_RECOVERY_SELECTED_TASK_SPEC" \
    "coverage_task_spec=$GOM_RECOVERY_COVERAGE_TASK_SPEC" \
    "selected_case_count=$GOM_RECOVERY_SELECTED_CASE_COUNT" \
    "coverage_case_count=$GOM_RECOVERY_COVERAGE_CASE_COUNT" \
    "affected_shard_count=$GOM_RECOVERY_AFFECTED_SHARD_COUNT" \
    "gate_job_id=$GOM_RECOVERY_GATE_JOB_ID" \
    "case_job_id=$GOM_RECOVERY_CASE_JOB_ID" \
    "vtu_job_id=$GOM_RECOVERY_VTU_JOB_ID" \
    "archive_job_ids=$GOM_RECOVERY_ARCHIVE_JOB_IDS" \
    "finalizer_job_ids=$GOM_RECOVERY_FINALIZER_JOB_IDS" \
    'campaign_complete_created=false' \
    'all_recovered_shards_atomically_promoted_and_verified=true' \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/recovery_complete_summary.txt"

durable_control="$GOM_RECOVERY_DURABLE_DIR/shard_control"
test ! -e "$durable_control"
cp -a -- "$result_dir/shard_control" "$durable_control"
cp -- "$result_dir/recovered_shards.tsv" \
    "$GOM_RECOVERY_DURABLE_DIR/recovered_shards.tsv"
cp -- "$result_dir/recovery_complete_summary.txt" \
    "$GOM_RECOVERY_DURABLE_DIR/recovery_complete_summary.txt"
(
    cd "$GOM_RECOVERY_DURABLE_DIR"
    find . -type f \
        ! -name RECOVERY_CONTROL_SHA256SUMS \
        ! -name RECOVERY_COMPLETE -print0 |
        LC_ALL=C sort -z | xargs -0 sha256sum \
        > RECOVERY_CONTROL_SHA256SUMS.tmp.$SLURM_JOB_ID
    mv -- RECOVERY_CONTROL_SHA256SUMS.tmp.$SLURM_JOB_ID \
        RECOVERY_CONTROL_SHA256SUMS
    sha256sum --check RECOVERY_CONTROL_SHA256SUMS
)
marker_tmp="$GOM_RECOVERY_DURABLE_DIR/RECOVERY_COMPLETE.tmp.$SLURM_JOB_ID"
printf '%s\n' \
    'status=pass' \
    "recovery_id=$GOM_RECOVERY_ID" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    "affected_shard_count=$GOM_RECOVERY_AFFECTED_SHARD_COUNT" \
    "control_sha256sums_sha256=$(sha256sum "$GOM_RECOVERY_DURABLE_DIR/RECOVERY_CONTROL_SHA256SUMS" | awk '{print $1}')" \
    'campaign_complete_created=false' \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$marker_tmp"
mv -- "$marker_tmp" "$GOM_RECOVERY_DURABLE_DIR/RECOVERY_COMPLETE"
printf 'PASS\n' > "$result_dir/PASS"
