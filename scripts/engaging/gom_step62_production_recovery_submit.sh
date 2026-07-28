#!/bin/bash
# Recover the immutable r4 seven-case campaign without rerunning six complete
# simulations. Resume task 5, validate all seven, export VTUs, then archive.

set -euo pipefail
umask 027

: "${GOM_RECOVERY_WORKFLOW_REPO:?Set the immutable recovery workflow repository.}"
: "${GOM_RECOVERY_SIM_REPO:?Set the original campaign-pinned repository.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the original campaign manifest.}"
: "${GOM_RECOVERY_FULL_JOB_ID:?Set the original full-array job ID.}"
: "${GOM_RECOVERY_CHECK_JOB_ID:?Set the original campaign-check job ID.}"
: "${GOM_RECOVERY_PREFLIGHT_JOB_ID:?Set the original preflight array job ID.}"
: "${GOM_RECOVERY_SMOKE_JOB_ID:?Set the original smoke array job ID.}"

for job_id in \
    "$GOM_RECOVERY_FULL_JOB_ID" \
    "$GOM_RECOVERY_CHECK_JOB_ID" \
    "$GOM_RECOVERY_PREFLIGHT_JOB_ID" \
    "$GOM_RECOVERY_SMOKE_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]] ||
        { echo "Recovery source job IDs must be numeric." >&2; exit 1; }
done

command -v sbatch >/dev/null
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$production_python" >/dev/null
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
workflow_scripts="$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging"
sim_scripts="$GOM_RECOVERY_SIM_REPO/scripts/engaging"
resolver="$GOM_RECOVERY_SIM_REPO/scripts/engaging/gom_step62_production_manifest.py"
validator="$workflow_scripts/gom_step62_production_final_check.jl"
expected_validator_sha256="82ae9403a3cf59e62c5243a5aab0a11c8419d40c84909f062736ef8dd046937b"
mkdir -p "$gom_root/logs" "$gom_root/submissions"

"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
    validate
resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 1 --format shell
)"
eval "$resolved_case"
test "$(git -C "$GOM_RECOVERY_SIM_REPO" rev-parse HEAD)" = \
    "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
test "$(sha256sum "$GOM_RECOVERY_SIM_REPO/Manifest.toml" | awk '{print $1}')" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"
test -z "$(git -C "$GOM_RECOVERY_SIM_REPO" status --porcelain)"
test -z "$(git -C "$GOM_RECOVERY_WORKFLOW_REPO" status --porcelain)"
workflow_commit="$(git -C "$GOM_RECOVERY_WORKFLOW_REPO" rev-parse HEAD)"
validator_sha256="$(sha256sum "$validator" | awk '{print $1}')"
test "$validator_sha256" = "$expected_validator_sha256"

archive_final="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/${GOM_PRODUCTION_CAMPAIGN_ID}_fulljob${GOM_RECOVERY_FULL_JOB_ID}"
test ! -e "$archive_final"

campaign_key="${GOM_PRODUCTION_CAMPAIGN_ID}_fulljob${GOM_RECOVERY_FULL_JOB_ID}"
submission_lock="$gom_root/submissions/.${campaign_key}.recovery-submit.lock"
active_state="$gom_root/submissions/${campaign_key}.recovery-active.txt"
exec 8> "$submission_lock"
flock -n 8 || {
    echo "Another recovery submission is in progress for $campaign_key." >&2
    exit 1
}
if test -s "$active_state"; then
    active_jobs=()
    while IFS='=' read -r key value; do
        case "$key" in
            *_job)
                [[ "$value" =~ ^[0-9]+$ ]] && active_jobs+=("$value")
                ;;
        esac
    done < "$active_state"
    for job_id in "${active_jobs[@]}"; do
        if test -n "$(squeue -h -j "$job_id" -o '%i' 2>/dev/null || true)"; then
            echo "Recovery DAG is already active for $campaign_key (job $job_id)." >&2
            exit 1
        fi
    done
fi

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_RECOVERY_CHECK_JOB_ID}"
preflight_root="$gom_root/results/gom_step62_production_preflight_job${GOM_RECOVERY_PREFLIGHT_JOB_ID}"
smoke_root="$gom_root/results/gom_step62_production_smoke_job${GOM_RECOVERY_SMOKE_JOB_ID}"
full_root="$gom_root/results/gom_step62_production_full_job${GOM_RECOVERY_FULL_JOB_ID}"
test -f "$check_root/PASS"
test -s "$check_root/campaign_check_summary.txt"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
for task in 1 2 3 4 5 6 7; do
    resolved_case="$(
        "$production_python" "$resolver" \
            --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell
    )"
    eval "$resolved_case"
    case_key="$GOM_PRODUCTION_CASE_KEY"
    preflight_case="$preflight_root/$case_key"
    smoke_tag="gom_step62_production_${case_key}_hyst_faultpcplateau_npctheta30_smoke3_job${GOM_RECOVERY_SMOKE_JOB_ID}_${task}"
    smoke_case="$smoke_root/$smoke_tag"
    full_tag="gom_step62_production_${case_key}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_RECOVERY_FULL_JOB_ID}_${task}"
    full_case="$full_root/$full_tag"
    test -f "$preflight_case/PASS"
    test -f "$smoke_case/PASS"
    grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
    grep -Fxq 'status=pass' "$smoke_case/smoke_summary.txt"
    test -s "$full_case/RUN_METADATA.txt"
    test -s "$full_case/exit_status.txt"
done

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if [ "$submission_complete" != true ] &&
            [ "${#submitted_jobs[@]}" -gt 0 ]; then
        echo "Submission failed; cancelling recovery DAG: " \
            "${submitted_jobs[*]}" >&2
        scancel "${submitted_jobs[@]}" || true
    fi
    exit "$exit_code"
}
trap cancel_partial_dag EXIT

submit_job() {
    raw_id="$(sbatch --parsable "$@")"
    submitted_job_id="${raw_id%%;*}"
    [[ "$submitted_job_id" =~ ^[0-9]+$ ]] ||
        { echo "Unexpected sbatch job ID: $raw_id" >&2; return 1; }
    submitted_jobs+=("$submitted_job_id")
}

recovery_exports="ALL,GOM_GRID_ROOT=$gom_root,GOM_RECOVERY_WORKFLOW_REPO=$GOM_RECOVERY_WORKFLOW_REPO,GOM_RECOVERY_WORKFLOW_COMMIT=$workflow_commit,GOM_RECOVERY_SIM_REPO=$GOM_RECOVERY_SIM_REPO,GOM_RECOVERY_VALIDATOR_SHA256=$validator_sha256,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST,GOM_RECOVERY_FULL_JOB_ID=$GOM_RECOVERY_FULL_JOB_ID"

submit_job --kill-on-invalid-dep=yes --array='1' \
    --export="$recovery_exports" \
    "$workflow_scripts/gom_step62_production_recovery_preflight.sbatch"
recovery_preflight_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$recovery_preflight_job" --array='1-4,6-7' \
    --export="$recovery_exports" \
    "$workflow_scripts/gom_step62_production_recovery_finalize.sbatch"
completed_finalize_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$recovery_preflight_job" --array='5' \
    --export="$recovery_exports" \
    "$workflow_scripts/gom_step62_production_recovery_resume.sbatch"
resume_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes --dependency="afterok:$resume_job" \
    --array='5' --export="$recovery_exports" \
    "$workflow_scripts/gom_step62_production_recovery_finalize.sbatch"
task5_finalize_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$completed_finalize_job:$task5_finalize_job" \
    --array='1-7' \
    --export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$GOM_RECOVERY_SIM_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST,GOM_PRODUCTION_FULL_JOB_ID=$GOM_RECOVERY_FULL_JOB_ID,PRODUCTION_QOI_MODE=off" \
    "$sim_scripts/gom_step62_production_vtu.sbatch"
vtu_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu_job" \
    --export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$GOM_RECOVERY_SIM_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST,GOM_PRODUCTION_CHECK_JOB_ID=$GOM_RECOVERY_CHECK_JOB_ID,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$GOM_RECOVERY_PREFLIGHT_JOB_ID,GOM_PRODUCTION_SMOKE_JOB_ID=$GOM_RECOVERY_SMOKE_JOB_ID,GOM_PRODUCTION_FULL_JOB_ID=$GOM_RECOVERY_FULL_JOB_ID,GOM_PRODUCTION_VTU_JOB_ID=$vtu_job,GOM_PRODUCTION_TASKS=1:2:3:4:5:6:7" \
    "$sim_scripts/gom_step62_production_archive.sbatch"
archive_job="$submitted_job_id"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
receipt="$gom_root/submissions/gom_step62_production_recovery_${timestamp}.txt"
temporary="${receipt}.tmp.$$"
printf '%s\n' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "manifest=$GOM_PRODUCTION_MANIFEST" \
    "manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "original_simulation_repo=$GOM_RECOVERY_SIM_REPO" \
    "original_simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "original_full_job_id=$GOM_RECOVERY_FULL_JOB_ID" \
    "recovery_workflow_repo=$GOM_RECOVERY_WORKFLOW_REPO" \
    "recovery_workflow_commit=$workflow_commit" \
    "validator_sha256=$validator_sha256" \
    "recovery_preflight_job=$recovery_preflight_job" \
    "completed_cases_finalize_job=$completed_finalize_job" \
    "task5_resume_job=$resume_job" \
    "task5_finalize_job=$task5_finalize_job" \
    "vtu_array_job=$vtu_job" \
    "archive_job=$archive_job" \
    "array_throttle=none" \
    "production_qoi_mode=off" \
    > "$temporary"
mv -- "$temporary" "$receipt"

durable_receipt_dir="$GOM_PRODUCTION_ARCHIVE_ROOT/recovery_submissions/$campaign_key"
mkdir -p "$durable_receipt_dir"
durable_receipt="$durable_receipt_dir/$(basename "$receipt")"
durable_temporary="${durable_receipt}.tmp.$$"
cp -- "$receipt" "$durable_temporary"
mv -- "$durable_temporary" "$durable_receipt"

active_temporary="${active_state}.tmp.$$"
printf '%s\n' \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "original_full_job=$GOM_RECOVERY_FULL_JOB_ID" \
    "recovery_preflight_job=$recovery_preflight_job" \
    "completed_cases_finalize_job=$completed_finalize_job" \
    "task5_resume_job=$resume_job" \
    "task5_finalize_job=$task5_finalize_job" \
    "vtu_array_job=$vtu_job" \
    "archive_job=$archive_job" \
    "submission_receipt=$receipt" \
    "durable_submission_receipt=$durable_receipt" \
    > "$active_temporary"
mv -- "$active_temporary" "$active_state"

submission_complete=true
trap - EXIT
cat "$receipt"
printf 'submission_receipt=%s\n' "$receipt"
printf 'durable_submission_receipt=%s\n' "$durable_receipt"
