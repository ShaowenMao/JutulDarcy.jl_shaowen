#!/bin/bash
# Prove that the corrected validator can read an original completed result
# before any recovery job writes into the old campaign tree.
#SBATCH --job-name=gom_s62_recover_check
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1
#SBATCH --time=01:00:00
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
test "$SLURM_ARRAY_TASK_ID" -eq 1

export JUTULDARCY_COMBINED_REPO="$GOM_RECOVERY_SIM_REPO"
source \
    "$GOM_RECOVERY_SIM_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task

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
result_dir="$gom_root/results/gom_step62_production_recovery_preflight_job${SLURM_ARRAY_JOB_ID}"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -d "$case_dir"
test -s "$case_dir/exit_status.txt"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "Another writer already owns $case_dir." >&2
    exit 1
}

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1

cd "$GOM_RECOVERY_SIM_REPO"
julia --startup-file=no --project=. "$validator" \
    "$restart_dir" "$summary_dir" \
    "$result_dir/final_state_summary.txt" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"
grep -Fxq 'status=pass' "$result_dir/final_state_summary.txt"
grep -Fxq 'report_steps=210' "$result_dir/final_state_summary.txt"
grep -Fxq 'retained_restart_steps=78,210' \
    "$result_dir/final_state_summary.txt"

task5_dir="$full_root/gom_step62_production_s03_c001_case04_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_RECOVERY_FULL_JOB_ID}_5"
test -d "$task5_dir"
test -s "$task5_dir/exit_status.txt"
exec 8> "$task5_dir/.production-output.lock"
flock -n 8 || {
    echo "Another writer already owns $task5_dir." >&2
    exit 1
}
task5_rows="$(
    find "$task5_dir/restart/production_output/rows" -maxdepth 1 \
        -type f -name 'step_*.tsv' | wc -l
)"
task5_latest="$(
    find "$task5_dir/restart" -maxdepth 1 -type f \
        -name 'jutul_*.jld2' -printf '%f\n' |
        sed -n 's/^jutul_\([0-9][0-9]*\)\.jld2$/\1/p' |
        awk -v max="$task5_rows" '$1 <= max' |
        sort -n | tail -1
)"
[[ "$task5_latest" =~ ^[0-9]+$ ]] ||
    { echo "Task 5 has no checkpoint backed by an atomic summary row." >&2; exit 1; }
test -s "$task5_dir/restart/jutul_${task5_latest}.jld2"
test -s \
    "$task5_dir/restart/production_output/rows/step_$(printf '%06d' "$task5_latest").tsv"
if test -s \
        "$task5_dir/restart/production_output/PRODUCTION_OUTPUT_COMPLETE.tsv"; then
    test "$task5_rows" -eq 210
    test "$task5_latest" -eq 210
    task5_status=complete
else
    test "$task5_latest" -ge 174
    test "$task5_latest" -lt 210
    test "$task5_rows" -ge "$task5_latest"
    task5_status=restart_safe
fi

printf '%s\n' \
    "status=pass" \
    "original_full_job_id=$GOM_RECOVERY_FULL_JOB_ID" \
    "validator_case=$GOM_PRODUCTION_CASE_KEY" \
    "validator_sha256=$GOM_RECOVERY_VALIDATOR_SHA256" \
    "task5_status=$task5_status" \
    "task5_checkpoint=$task5_latest" \
    "task5_rows=$task5_rows" \
    "validated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/recovery_preflight_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
