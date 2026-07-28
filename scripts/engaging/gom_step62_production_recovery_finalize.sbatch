#!/bin/bash
# Validate and finalize an existing Step62 full result without rerunning it.
#SBATCH --job-name=gom_s62_recover_finalize
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-7
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_RECOVERY_WORKFLOW_REPO:?Set the repository containing the fixed validator.}"
: "${GOM_RECOVERY_WORKFLOW_COMMIT:?Set the immutable recovery workflow commit.}"
: "${GOM_RECOVERY_SIM_REPO:?Set the original campaign-pinned repository.}"
: "${GOM_RECOVERY_VALIDATOR_SHA256:?Set the fixed validator SHA-256.}"
: "${GOM_PRODUCTION_MANIFEST:?Set the original campaign manifest.}"
: "${GOM_RECOVERY_FULL_JOB_ID:?Set the original full-array job ID.}"
[[ "$GOM_RECOVERY_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_RECOVERY_FULL_JOB_ID must be numeric." >&2; exit 1; }
[[ "$GOM_RECOVERY_VALIDATOR_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    { echo "GOM_RECOVERY_VALIDATOR_SHA256 must be lowercase SHA-256." >&2; exit 1; }

export JUTULDARCY_COMBINED_REPO="$GOM_RECOVERY_SIM_REPO"
source \
    "$GOM_RECOVERY_SIM_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task
export PRODUCTION_QOI_MODE=off

validator="$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_final_check.jl"
test -s "$validator"
test "$(git -C "$GOM_RECOVERY_WORKFLOW_REPO" rev-parse HEAD)" = \
    "$GOM_RECOVERY_WORKFLOW_COMMIT"
test "$(sha256sum "$validator" | awk '{print $1}')" = \
    "$GOM_RECOVERY_VALIDATOR_SHA256"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_production_full_job${GOM_RECOVERY_FULL_JOB_ID}"
case_tag="gom_step62_production_${GOM_PRODUCTION_CASE_KEY}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_RECOVERY_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
case_dir="$full_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"

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
        > "$case_dir/RECOVERY_FINALIZE_EXIT_STATUS.txt"
}
trap record_exit_status EXIT

test "$(
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' | wc -l
)" -eq 2
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test "$(
    find "$summary_dir/rows" -maxdepth 1 -type f \
        -name 'step_*.tsv' | wc -l
)" -eq 210
test -s "$summary_dir/report_steps.tsv"
test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1

final_summary_tmp="$case_dir/final_state_summary.txt.tmp.$$"
cd "$GOM_RECOVERY_SIM_REPO"
julia --startup-file=no --project=. "$validator" \
    "$restart_dir" "$summary_dir" "$final_summary_tmp" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"
mv -- "$final_summary_tmp" "$case_dir/final_state_summary.txt"

restart_sha_tmp="$case_dir/RETAINED_RESTART_SHA256.txt.tmp.$$"
summary_sha_tmp="$case_dir/PRODUCTION_SUMMARY_SHA256.txt.tmp.$$"
(
    cd "$case_dir"
    sha256sum restart/jutul_78.jld2 restart/jutul_210.jld2 \
        > "$restart_sha_tmp"
    sha256sum restart/production_output/report_steps.tsv \
        restart/production_output/PRODUCTION_OUTPUT_COMPLETE.tsv \
        > "$summary_sha_tmp"
)
mv -- "$restart_sha_tmp" "$case_dir/RETAINED_RESTART_SHA256.txt"
mv -- "$summary_sha_tmp" "$case_dir/PRODUCTION_SUMMARY_SHA256.txt"
(
    cd "$case_dir"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)

restart_manifest_tmp="$case_dir/RESTART_MANIFEST.tsv.tmp.$$"
{
    printf 'file\tbytes\n'
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\t%s\n' | sort -V
} > "$restart_manifest_tmp"
mv -- "$restart_manifest_tmp" "$case_dir/RESTART_MANIFEST.tsv"

workflow_commit="$GOM_RECOVERY_WORKFLOW_COMMIT"
original_exit_sha="$(
    sha256sum "$case_dir/exit_status.txt" | awk '{print $1}'
)"
recovery_action=validation_only
if test "$SLURM_ARRAY_TASK_ID" -eq 5; then
    test -s "$case_dir/RECOVERY_SIMULATION_COMPLETE.txt"
    recovery_action=resume_then_validation
fi

recovery_metadata_tmp="$case_dir/RECOVERY_FINALIZATION_METADATA.txt.tmp.$$"
printf '%s\n' \
    "status=pass" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "action=$recovery_action" \
    "original_full_job_id=$GOM_RECOVERY_FULL_JOB_ID" \
    "original_simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "original_exit_status_sha256=$original_exit_sha" \
    "recovery_workflow_commit=$workflow_commit" \
    "validator_sha256=$GOM_RECOVERY_VALIDATOR_SHA256" \
    "recovery_finalize_job_id=$SLURM_JOB_ID" \
    "validated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$recovery_metadata_tmp"
mv -- "$recovery_metadata_tmp" \
    "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"

production_summary_tmp="$case_dir/production_summary.txt.tmp.$$"
printf '%s\n' \
    "status=pass" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" \
    "realization_id=$GOM_PRODUCTION_REALIZATION_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
    "steps_completed=210" \
    "summary_rows=210" \
    "retained_restart_steps=78,210" \
    "schedule_end_years=1000" \
    "hysteresis_active=true" \
    "hysteresis_s_min=0.05" \
    "fault_hysteresis=drainage_equivalent" \
    "fault_pc_entry_treatment=plateau" \
    "nonpredict_pc_reference_contact_angle_deg=30" \
    "transmissibility_source=JutulDarcy_grid_and_rock" \
    "production_output_mode=true" \
    "production_qoi_mode=off" \
    "recovery_action=$recovery_action" \
    "recovery_validator_sha256=$GOM_RECOVERY_VALIDATOR_SHA256" \
    "result_dir=$case_dir" \
    > "$production_summary_tmp"
mv -- "$production_summary_tmp" "$case_dir/production_summary.txt"

recovery_pass_tmp="$case_dir/RECOVERY_PASS.tmp.$$"
pass_tmp="$case_dir/PASS.tmp.$$"
printf 'PASS\n' > "$recovery_pass_tmp"
printf 'PASS\n' > "$pass_tmp"
mv -- "$recovery_pass_tmp" "$case_dir/RECOVERY_PASS"
mv -- "$pass_tmp" "$case_dir/PASS"
