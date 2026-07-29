#!/bin/bash
# Submit only canonical manifest tasks 5:7 for sandpc_effective_globalplateau_v1.

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
full_walltime="${GOM_EFFECTIVE_PC_FULL_WALLTIME:-1-00:00:00}"
if [[ "$full_walltime" =~ ^([0-9]+-)?([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
    full_days="${BASH_REMATCH[1]%-}"
    full_days="${full_days:-0}"
    full_hours="${BASH_REMATCH[2]}"
    full_minutes="${BASH_REMATCH[3]}"
    full_seconds="${BASH_REMATCH[4]}"
    full_walltime_seconds=$((
        (10#$full_days)*86400 +
        (10#$full_hours)*3600 +
        (10#$full_minutes)*60 +
        (10#$full_seconds)
    ))
else
    echo "Invalid GOM_EFFECTIVE_PC_FULL_WALLTIME: $full_walltime" >&2
    exit 1
fi
if (( full_walltime_seconds < 86400 )); then
    echo "GOM_EFFECTIVE_PC_FULL_WALLTIME must be at least 24 hours;" \
        "case 5 previously required about 14 h 41 min." >&2
    exit 1
fi
mkdir -p "$gom_root/logs" "$gom_root/submissions"

"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" validate
resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 5 --format shell
)"
eval "$resolved_case"
case "$GOM_PRODUCTION_CAMPAIGN_ID" in
    *sandpc*ycap50*effective*globalplateau*) ;;
    *)
        echo "Campaign ID must contain sandpc, ycap50, effective, and globalplateau." >&2
        exit 1
        ;;
esac

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if [ "$submission_complete" != true ] &&
            [ "${#submitted_jobs[@]}" -gt 0 ]; then
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

common_exports="ALL,PRODUCTION_QOI_MODE=required"
submit_job --kill-on-invalid-dep=yes --export="$common_exports" \
    "$scripts/gom_step62_effective_pc_global_plateau_campaign_check.sbatch"
check_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$check_job" \
    --array=5-7 --export="$common_exports" \
    "$scripts/gom_step62_effective_pc_global_plateau_preflight.sbatch"
preflight_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$preflight_job" \
    --array=5-7 \
    --export="$common_exports,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job" \
    "$scripts/gom_step62_effective_pc_global_plateau_smoke.sbatch"
smoke_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$smoke_job" \
    --array=5-7 --time="$full_walltime" \
    --export="$common_exports,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job" \
    "$scripts/gom_step62_effective_pc_global_plateau_full.sbatch"
full_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$full_job" \
    --array=5-7 \
    --export="$common_exports,GOM_PRODUCTION_FULL_JOB_ID=$full_job" \
    "$scripts/gom_step62_effective_pc_global_plateau_vtu.sbatch"
vtu_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu_job" \
    --export="$common_exports,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job,GOM_PRODUCTION_SMOKE_JOB_ID=$smoke_job,GOM_PRODUCTION_FULL_JOB_ID=$full_job,GOM_PRODUCTION_VTU_JOB_ID=$vtu_job" \
    "$scripts/gom_step62_effective_pc_global_plateau_archive.sbatch"
archive_job="$submitted_job_id"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
receipt="$gom_root/submissions/gom_step62_effective_pc_global_plateau_${timestamp}.txt"
temporary="${receipt}.tmp.$$"
manifest_sha256=$(sha256sum "$GOM_PRODUCTION_MANIFEST" | awk '{print $1}')
printf '%s\n' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "physics_profile=sandpc_effective_globalplateau_v1" \
    "manifest=$GOM_PRODUCTION_MANIFEST" \
    "manifest_sha256=$manifest_sha256" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "jutuldarcy_repo=$JUTULDARCY_COMBINED_REPO" \
    "gom_grid_root=$gom_root" \
    "case_tasks=5:6:7" \
    "array_limit=none" \
    "old_restart_reuse=false" \
    "fault_pc_entry_treatment=plateau_all_active" \
    "fault_pc_entry_scope=all_active_drainage" \
    "production_qoi_mode=required" \
    "full_walltime=$full_walltime" \
    "full_cpus_per_task=8" \
    "full_memory=18G" \
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
