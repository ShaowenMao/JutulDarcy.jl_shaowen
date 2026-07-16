#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_solver_full
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 4-00:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:?Submit this script as a Slurm array.}

case "$ARRAY_TASK_ID" in
    1)
        SOLVER_VARIANT=relaxation_ds0p05
        export TARGET_DS=0.05
        CASE_DISABLE_HYSTERESIS=true
        CASE_HYSTERESIS_S_MIN=
        CASE_EXPLICIT_FAULT_HYSTERESIS_MODE=disable
        ;;
    2)
        SOLVER_VARIANT=relaxation_ds0p02
        export TARGET_DS=0.02
        CASE_DISABLE_HYSTERESIS=true
        CASE_HYSTERESIS_S_MIN=
        CASE_EXPLICIT_FAULT_HYSTERESIS_MODE=disable
        ;;
    3)
        SOLVER_VARIANT=relaxation_ds0p05
        export TARGET_DS=0.05
        CASE_DISABLE_HYSTERESIS=false
        CASE_HYSTERESIS_S_MIN=0.05
        CASE_EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
        ;;
    *)
        echo "Unknown full-run solver task $ARRAY_TASK_ID. Valid tasks are 1-3."
        exit 1
        ;;
esac

# All tasks use the same physical realization. Tasks 1-2 compare TARGET_DS;
# task 3 is the reservoir-hysteresis counterpart of task 1.
export CASE_ID=all87_split
export CASE_LABEL="all87_split_s05_c012_case01_${SOLVER_VARIANT}"
export COMMON_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat"
export SPECIFIC_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_slices_s05_c012_case01_specific.mat"
export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"

export RUN_MODE=simulate
export RESTART_RUN=false
unset CASE_TAG RESTART_STEP STOP_AFTER_REPORT_STEP
export LOAD_STATES_AFTER_SIM=false
export LOAD_REPORTS_AFTER_SIM=false
export IN_MEMORY_REPORTS=1
export INFO_LEVEL=1
export REPORT_LEVEL=1

export HYPRE_THREADS=8
export MAX_NONLINEAR_ITERATIONS=10
export MAX_TIMESTEP_CUTS=25
export NONLINEAR_RELAXATION=true
export TARGET_ITS=5
export TIMESTEP_MAX_INCREASE=1.25
export DR_MAX=Inf

export DISABLE_HYSTERESIS=$CASE_DISABLE_HYSTERESIS
export HYSTERESIS_S_MIN=$CASE_HYSTERESIS_S_MIN
export USE_MRST_TRANSMISSIBILITY=true
export IGNORE_MRST_T=false
export FAULT_SATURATION_DOMAIN_MODE=input
export FAULT_PC_ENTRY_TREATMENT=plateau
export FAULT_PC_ENTRY_SG_MAX=1.0e-4
export EXPLICIT_FAULT_HYSTERESIS_MODE=$CASE_EXPLICIT_FAULT_HYSTERESIS_MODE
export ENABLE_DIFFUSION=false

exec bash "$REPO_ROOT/scripts/engaging/gom_sampling_cases.sbatch"
