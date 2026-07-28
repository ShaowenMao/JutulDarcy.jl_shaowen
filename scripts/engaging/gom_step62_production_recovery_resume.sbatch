#!/bin/bash
# Resume only an incomplete case in an existing immutable Step62 full-run tree.
# The recovery simulation continues with the original campaign-pinned runtime.
#SBATCH --job-name=gom_s62_recover_resume
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_RECOVERY_SIM_REPO:?Set the original campaign-pinned repository.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the original campaign manifest.}"
: "${GOM_RECOVERY_FULL_JOB_ID:?Set the original full-array job ID.}"
[[ "$GOM_RECOVERY_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_RECOVERY_FULL_JOB_ID must be numeric." >&2; exit 1; }
test "$SLURM_ARRAY_TASK_ID" -eq 5

export JUTULDARCY_COMBINED_REPO="$GOM_RECOVERY_SIM_REPO"
source \
    "$GOM_RECOVERY_SIM_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task
gom_production_export_locked_physics

test "$GOM_PRODUCTION_TASK" -eq 5
test "$GOM_PRODUCTION_CASE_KEY" = "s03_c001_case04"
export PRODUCTION_QOI_MODE=off
export RESTART_RUN=true
unset STOP_AFTER_REPORT_STEP

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_production_full_job${GOM_RECOVERY_FULL_JOB_ID}"
case_tag="gom_step62_production_${GOM_PRODUCTION_CASE_KEY}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_RECOVERY_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
case_dir="$full_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
row_dir="$summary_dir/rows"

test -d "$case_dir"
test -s "$case_dir/RUN_METADATA.txt"
test -s "$case_dir/exit_status.txt"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "Another writer already owns $case_dir." >&2
    exit 1
}

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/RECOVERY_RESUME_EXIT_STATUS.txt"
}
trap record_exit_status EXIT

write_recovery_completion() {
    local resumed_after="$1"
    local completion_tmp="$case_dir/RECOVERY_SIMULATION_COMPLETE.txt.tmp.$$"
    printf '%s\n' \
        "status=complete" \
        "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "original_full_job_id=$GOM_RECOVERY_FULL_JOB_ID" \
        "recovery_job_id=$SLURM_JOB_ID" \
        "resumed_after_step=$resumed_after" \
        "steps_completed=210" \
        "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$completion_tmp"
    mv -- "$completion_tmp" "$case_dir/RECOVERY_SIMULATION_COMPLETE.txt"
}

if test -s "$case_dir/PASS"; then
    test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
    test -s "$restart_dir/jutul_78.jld2"
    test -s "$restart_dir/jutul_210.jld2"
    test -s "$case_dir/RECOVERY_SIMULATION_COMPLETE.txt" ||
        write_recovery_completion already_complete
    echo "Case already has a verified PASS marker; no resume is needed."
    exit 0
fi
if test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"; then
    write_recovery_completion prior_recovery
    echo "Production output is already complete; no resume is needed."
    exit 0
fi

row_count="$(
    find "$row_dir" -maxdepth 1 -type f -name 'step_*.tsv' | wc -l
)"
latest_restart="$(
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\n' |
        sed -n 's/^jutul_\([0-9][0-9]*\)\.jld2$/\1/p' |
        awk -v max="$row_count" '$1 <= max' |
        sort -n | tail -1
)"
[[ "$latest_restart" =~ ^[0-9]+$ ]] ||
    { echo "No checkpoint backed by an atomic summary row was found." >&2; exit 1; }
test "$latest_restart" -ge 174
test "$latest_restart" -lt 210
test "$row_count" -ge "$latest_restart"
test -s "$restart_dir/jutul_${latest_restart}.jld2"
test -s \
    "$row_dir/step_$(printf '%06d' "$latest_restart").tsv"

# Jutul's integer restart value denotes the next report step. Production
# reconciliation therefore validates and loads checkpoint restart_step - 1.
export RESTART_STEP="$((latest_restart + 1))"
export REPO_ROOT="$GOM_RECOVERY_SIM_REPO"
export CASE_LABEL="$GOM_PRODUCTION_CASE_KEY"
export CASE_TAG="$case_tag"
export RUN_ROOT="$full_root"
export PRODUCTION_SUMMARY_DIR="$summary_dir"

metadata_tmp="$case_dir/RECOVERY_RESUME_METADATA.txt.tmp.$$"
gom_production_write_metadata "$metadata_tmp" recovery_resume
printf '%s\n' \
    "original_full_job_id=$GOM_RECOVERY_FULL_JOB_ID" \
    "original_exit_status_sha256=$(sha256sum "$case_dir/exit_status.txt" | awk '{print $1}')" \
    "rows_before_resume=$row_count" \
    "checkpoint_before_resume=$latest_restart" \
    "restart_step=$RESTART_STEP" \
    "checkpoint_sha256=$(sha256sum "$restart_dir/jutul_${latest_restart}.jld2" | awk '{print $1}')" \
    "resume_in_place=true" \
    >> "$metadata_tmp"
mv -- "$metadata_tmp" "$case_dir/RECOVERY_RESUME_METADATA.txt"

bash "$GOM_RECOVERY_SIM_REPO/scripts/engaging/gom_sampling_cases.sbatch"

test "$(
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' | wc -l
)" -eq 2
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test "$(
    find "$row_dir" -maxdepth 1 -type f -name 'step_*.tsv' | wc -l
)" -eq 210
test -s "$summary_dir/report_steps.tsv"
test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"

write_recovery_completion "$latest_restart"
