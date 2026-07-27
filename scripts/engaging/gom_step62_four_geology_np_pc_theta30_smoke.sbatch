#!/bin/bash
#SBATCH --job-name=gom_s62_4geo_np30_s3
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-4%2
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=28G
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

test -s "$common_path"
test -s "$specific_path"
test -f "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

export REPO_ROOT="$JUTULDARCY_COMBINED_REPO"
export CASE_ID=all87_split
export CASE_LABEL="gom_step62_s05c012_case${case_id}_hyst_faultpcplateau_npctheta30_smoke3"
export CASE_TAG="${CASE_LABEL}_job${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
export COMMON_MATFILE_PATH="$common_path"
export SPECIFIC_MATFILE_PATH="$specific_path"
export MATFILE_PATH="$specific_path"
export RUN_ROOT="$gom_root/results/gom_step62_four_geology_np_pc_theta30_smoke_job${SLURM_ARRAY_JOB_ID}"

export RUN_MODE=simulate
export RESTART_RUN=false
export STOP_AFTER_REPORT_STEP=3
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

exec bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"
