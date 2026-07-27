#!/bin/bash
# Submit the immutable seven-case Step62 pilot as one dependency DAG.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"

command -v sbatch >/dev/null
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$production_python" >/dev/null
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
scripts="$JUTULDARCY_COMBINED_REPO/scripts/engaging"
resolver="$scripts/gom_step62_production_manifest.py"
mkdir -p "$gom_root/logs" "$gom_root/submissions"

"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" validate

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if [ "$submission_complete" != true ] && [ "${#submitted_jobs[@]}" -gt 0 ]; then
        echo "Submission failed; cancelling partial DAG: ${submitted_jobs[*]}" >&2
        scancel "${submitted_jobs[@]}" || true
    fi
    return "$exit_code"
}
trap cancel_partial_dag EXIT

submit_job() {
    raw_id=$(sbatch --parsable "$@")
    job_id="${raw_id%%;*}"
    [[ "$job_id" =~ ^[0-9]+$ ]] ||
        { echo "Unexpected sbatch job ID: $raw_id" >&2; return 1; }
    submitted_jobs+=("$job_id")
    submitted_job_id="$job_id"
}

submit_job --kill-on-invalid-dep=yes --export=ALL \
    "$scripts/gom_step62_production_campaign_check.sbatch"
check_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$check_job" --export=ALL \
    "$scripts/gom_step62_production_preflight.sbatch"
preflight_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$preflight_job" --export=ALL \
    "$scripts/gom_step62_production_smoke.sbatch"
smoke_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$smoke_job" --export=ALL \
    "$scripts/gom_step62_production_full.sbatch"
full_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$full_job" \
    --export="ALL,GOM_PRODUCTION_FULL_JOB_ID=$full_job" \
    "$scripts/gom_step62_production_vtu.sbatch"
vtu_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu_job" \
    --export="ALL,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job,GOM_PRODUCTION_SMOKE_JOB_ID=$smoke_job,GOM_PRODUCTION_FULL_JOB_ID=$full_job,GOM_PRODUCTION_VTU_JOB_ID=$vtu_job" \
    "$scripts/gom_step62_production_archive.sbatch"
archive_job="$submitted_job_id"

receipt_dir="$gom_root/submissions"
mkdir -p "$receipt_dir"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
receipt="$receipt_dir/gom_step62_production_pilot_${timestamp}.txt"
temporary="${receipt}.tmp.$$"
manifest_sha256=$(sha256sum "$GOM_PRODUCTION_MANIFEST" | awk '{print $1}')
printf '%s\n' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "manifest=$GOM_PRODUCTION_MANIFEST" \
    "manifest_sha256=$manifest_sha256" \
    "jutuldarcy_repo=$JUTULDARCY_COMBINED_REPO" \
    "gom_grid_root=$gom_root" \
    "campaign_check_job=$check_job" \
    "preflight_array_job=$preflight_job" \
    "smoke_array_job=$smoke_job" \
    "full_array_job=$full_job" \
    "vtu_array_job=$vtu_job" \
    "archive_job=$archive_job" \
    > "$temporary"
mv -- "$temporary" "$receipt"

submission_complete=true
trap - EXIT
cat "$receipt"
printf 'submission_receipt=%s\n' "$receipt"
