#!/bin/bash
#SBATCH --job-name=gom_s62_4geo_hp_full
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-4%2
#SBATCH --time=2-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
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
result_root="$gom_root/results/gom_step62_four_geology_hyst_plateau_full_job${SLURM_ARRAY_JOB_ID}"
case_label="gom_step62_s05c012_case${case_id}_hyst_faultpcplateau_full1000y"
case_tag="${case_label}_job${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
case_dir="$result_root/$case_tag"
restart_dir="$case_dir/restart"
final_check="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_four_geology_hyst_final_state_check.jl"

mkdir -p "$case_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -s "$common_path"
test -s "$specific_path"
test -f "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"
test -f "$final_check"

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
    "schedule_steps=210" \
    "schedule_end_years=1000" \
    "hysteresis=true" \
    "hysteresis_s_min=0.05" \
    "fault_hysteresis=drainage_equivalent" \
    "pc_curve_treatment=fault_plateau" \
    "pc_plateau_sg_max=1e-4" \
    "well_volume_fraction=1e-3" \
    "use_mrst_transmissibility=false" \
    "restart_cache_mode=evict" \
    "memory=32G" \
    "cpus=8" \
    > "$case_dir/RUN_METADATA.txt"

export REPO_ROOT="$JUTULDARCY_COMBINED_REPO"
export CASE_ID=all87_split
export CASE_LABEL="$case_label"
export CASE_TAG="$case_tag"
export COMMON_MATFILE_PATH="$common_path"
export SPECIFIC_MATFILE_PATH="$specific_path"
export MATFILE_PATH="$specific_path"
export RUN_ROOT="$result_root"

export RUN_MODE=simulate
export RESTART_RUN=false
unset RESTART_STEP STOP_AFTER_REPORT_STEP
export LOAD_STATES_AFTER_SIM=false
export LOAD_REPORTS_AFTER_SIM=false
export IN_MEMORY_REPORTS=1
export INFO_LEVEL=1
export REPORT_LEVEL=1

export JULIA_NUM_GC_THREADS=1
export HYPRE_THREADS="$SLURM_CPUS_PER_TASK"
export MAX_NONLINEAR_ITERATIONS=10
export MAX_TIMESTEP_CUTS=25
export NONLINEAR_RELAXATION=true
export TARGET_ITS=5
export TIMESTEP_MAX_INCREASE=1.25
export TARGET_DS=0.05
export DR_MAX=Inf
export WELL_VOLUME_FRACTION=1.0e-3

export DISABLE_HYSTERESIS=false
export HYSTERESIS_S_MIN=0.05
export USE_MRST_TRANSMISSIBILITY=false
export IGNORE_MRST_T=true
export FAULT_SATURATION_DOMAIN_MODE=input
export FAULT_PC_ENTRY_TREATMENT=plateau
export FAULT_PC_ENTRY_SG_MAX=1.0e-4
export EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
export ENABLE_DIFFUSION=false

export RESTART_CACHE_MODE=evict
export MEMORY_MONITOR_INTERVAL_SECONDS=30

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

restart_count=$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)
test "$restart_count" -eq 210
test -s "$restart_dir/jutul_210.jld2"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$final_check" \
    "$restart_dir" "$case_dir/final_state_summary.txt"

{
    printf 'file\tbytes\n'
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\t%s\n' | sort -V
} > "$case_dir/RESTART_MANIFEST.tsv"
sha256sum "$restart_dir/jutul_210.jld2" \
    > "$case_dir/FINAL_RESTART_SHA256.txt"

printf '%s\n' \
    "status=pass" \
    "case_id=$case_id" \
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
    "steps_completed=$restart_count" \
    "schedule_end_years=1000" \
    "hysteresis_active=true" \
    "hysteresis_s_min=0.05" \
    "fault_hysteresis=drainage_equivalent" \
    "fault_pc_entry_treatment=plateau" \
    "fault_pc_entry_sg_max=1e-4" \
    "well_volume_fraction=1e-3" \
    "transmissibility_source=JutulDarcy_grid_and_rock" \
    "result_dir=$case_dir" \
    > "$case_dir/production_summary.txt"
printf 'PASS\n' > "$case_dir/PASS"
