#!/bin/bash
#SBATCH --job-name=gom_s62_4geo_np30_pf
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-4%2
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${GOM_FOUR_GEOLOGY_INPUT_DIR:?Set GOM_FOUR_GEOLOGY_INPUT_DIR.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"

case "$SLURM_ARRAY_TASK_ID" in
    1) case_id=01 ;;
    2) case_id=03 ;;
    3) case_id=04 ;;
    4) case_id=07 ;;
    *) echo "Unknown task $SLURM_ARRAY_TASK_ID"; exit 1 ;;
esac

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
common_path="$GOM_FOUR_GEOLOGY_INPUT_DIR/gom_step62_87slice_s05_c012_common.mat"
specific_path="$GOM_FOUR_GEOLOGY_INPUT_DIR/gom_step62_87slice_s05_c012_case${case_id}_full_slice_geology_specific.mat"
result_root="$gom_root/results/gom_step62_four_geology_np_pc_theta30_preflight_job${SLURM_ARRAY_JOB_ID}"
result_dir="$result_root/case${case_id}"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_four_geology_hyst_plateau_preflight.jl"

mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -s "$common_path"
test -s "$specific_path"
test -f "$script"

module purge
module load community-modules
module load julia/1.10.4

export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export CASE_JULIA_THREADS="$SLURM_CPUS_PER_TASK"
export HYPRE_THREADS="$SLURM_CPUS_PER_TASK"
export EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG=30

printf '%s\n' \
    "job_id=$SLURM_JOB_ID" \
    "array_job_id=$SLURM_ARRAY_JOB_ID" \
    "array_task_id=$SLURM_ARRAY_TASK_ID" \
    "node=$SLURMD_NODENAME" \
    "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "case_id=$case_id" \
    "geology_id=s05_c012" \
    "resolution_slices=87" \
    "cells=2165082" \
    "hysteresis=true" \
    "hysteresis_s_min=0.05" \
    "fault_hysteresis=drainage_equivalent" \
    "pc_curve_treatment=fault_plateau" \
    "pc_plateau_sg_max=1e-4" \
    "nonpredict_pc_reference_source_contact_angle_deg=70" \
    "nonpredict_pc_reference_contact_angle_deg=30" \
    "nonpredict_pc_reference_scale=2.532088886237956" \
    "use_mrst_transmissibility=false" \
    "memory=24G" \
    "cpus=8" \
    > "$result_dir/RUN_METADATA.txt"

cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$script" \
    "$common_path" "$specific_path" "$result_dir"

test -s "$result_dir/preflight_summary.txt"
grep -q '^status=pass$' "$result_dir/preflight_summary.txt"
grep -q '^hysteresis_active=true$' "$result_dir/preflight_summary.txt"
grep -q '^fault_hysteresis=drainage_equivalent$' "$result_dir/preflight_summary.txt"
grep -q '^pc_curve_treatment=fault_plateau$' "$result_dir/preflight_summary.txt"
grep -q '^pc_plateau_adjusted_tables=522$' "$result_dir/preflight_summary.txt"
grep -q '^pc_plateau_skipped_tables=0$' "$result_dir/preflight_summary.txt"
grep -q '^nonpredict_pc_reference_contact_angle_deg=30.0$' \
    "$result_dir/preflight_summary.txt"
grep -q '^mrst_transmissibility_present=false$' "$result_dir/preflight_summary.txt"
grep -q '^jutul_transmissibility=true$' "$result_dir/preflight_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
