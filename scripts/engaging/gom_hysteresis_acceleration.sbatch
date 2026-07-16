#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_hyst_accel
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 4-00:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
export RUN_ROOT=${RUN_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration}
HYST_ACCEL_STAGE=${HYST_ACCEL_STAGE:-checkpoint}

export CASE_ID=all87_split
export CASE_NAME=GOM_LARGE
export COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat}
export SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_slices_s05_c012_case01_specific.mat}
export MATFILE_PATH=$SPECIFIC_MATFILE_PATH

# Physical model settings match job 18022197_3 exactly.
export DISABLE_HYSTERESIS=false
export HYSTERESIS_S_MIN=0.05
export USE_MRST_TRANSMISSIBILITY=true
export IGNORE_MRST_T=false
export FAULT_SATURATION_DOMAIN_MODE=input
export FAULT_PC_ENTRY_TREATMENT=plateau
export FAULT_PC_ENTRY_SG_MAX=1.0e-4
export EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
export ENABLE_DIFFUSION=false

export RUN_MODE=simulate
export RESTART_RUN=false
export LOAD_STATES_AFTER_SIM=false
export LOAD_REPORTS_AFTER_SIM=false
export IN_MEMORY_REPORTS=1
export INFO_LEVEL=1
export REPORT_LEVEL=1
export HYPRE_THREADS=8
export MAX_NONLINEAR_ITERATIONS=10
export MAX_TIMESTEP_CUTS=25
export NONLINEAR_RELAXATION=true
export TIMESTEP_MAX_INCREASE=1.25
export DR_MAX=Inf
export CPR_UPDATE_INTERVAL_PARTIAL=iteration
unset CPR_PARTIAL_UPDATE

JOB_LABEL=${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}

case "$HYST_ACCEL_STAGE" in
    checkpoint)
        if [ -n "${SLURM_ARRAY_TASK_ID:-}" ]; then
            echo "Submit the checkpoint stage as a single job, not an array."
            exit 1
        fi
        export CASE_TAG="all87_split_hyst_checkpoint_step120_job${JOB_LABEL}"
        export TARGET_ITS=5
        export TARGET_DS=0.05
        export CPR_UPDATE_INTERVAL=iteration
        export STOP_AFTER_REPORT_STEP=120
        unset RESTART_STEP
        ;;
    continuation)
        ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:?Submit continuation as a Slurm array.}
        SOURCE_RESTART_PATH=${SOURCE_RESTART_PATH:?Set SOURCE_RESTART_PATH to the validated checkpoint restart directory.}
        case "$ARRAY_TASK_ID" in
            1)
                SOLVER_VARIANT=restart_validation
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export CPR_UPDATE_INTERVAL=iteration
                ;;
            2)
                SOLVER_VARIANT=cpr_once
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export CPR_UPDATE_INTERVAL=once
                ;;
            3)
                SOLVER_VARIANT=dt_ds0p10_its7
                export TARGET_ITS=7
                export TARGET_DS=0.10
                export CPR_UPDATE_INTERVAL=iteration
                ;;
            4)
                SOLVER_VARIANT=combined_ds0p10_its7_cpr_once
                export TARGET_ITS=7
                export TARGET_DS=0.10
                export CPR_UPDATE_INTERVAL=once
                ;;
            *)
                echo "Unknown continuation task $ARRAY_TASK_ID. Valid tasks are 1-4."
                exit 1
                ;;
        esac

        export CASE_TAG="all87_split_hyst_step121to145_${SOLVER_VARIANT}_job${JOB_LABEL}"
        export RESTART_STEP=121
        export STOP_AFTER_REPORT_STEP=145

        SOURCE_RESTART_FILE="$SOURCE_RESTART_PATH/jutul_120.jld2"
        TARGET_RESTART_DIR="$RUN_ROOT/$CASE_TAG/restart"
        TARGET_RESTART_FILE="$TARGET_RESTART_DIR/jutul_120.jld2"
        if [ ! -f "$SOURCE_RESTART_FILE" ]; then
            echo "Checkpoint file does not exist: $SOURCE_RESTART_FILE"
            exit 1
        fi
        mkdir -p "$TARGET_RESTART_DIR"
        if [ -e "$TARGET_RESTART_FILE" ] || [ -L "$TARGET_RESTART_FILE" ]; then
            echo "Refusing to replace existing restart file: $TARGET_RESTART_FILE"
            exit 1
        fi
        ln -s "$SOURCE_RESTART_FILE" "$TARGET_RESTART_FILE"
        ;;
    *)
        echo "Unknown HYST_ACCEL_STAGE=$HYST_ACCEL_STAGE"
        echo "Valid values: checkpoint, continuation"
        exit 1
        ;;
esac

echo "===== HYSTERESIS ACCELERATION ====="
echo "HYST_ACCEL_STAGE=$HYST_ACCEL_STAGE"
echo "CASE_TAG=$CASE_TAG"
echo "TARGET_ITS=$TARGET_ITS"
echo "TARGET_DS=$TARGET_DS"
echo "CPR_UPDATE_INTERVAL=$CPR_UPDATE_INTERVAL"
echo "CPR_UPDATE_INTERVAL_PARTIAL=$CPR_UPDATE_INTERVAL_PARTIAL"
echo "RESTART_STEP=${RESTART_STEP:-}"
echo "STOP_AFTER_REPORT_STEP=$STOP_AFTER_REPORT_STEP"
echo "SOURCE_RESTART_PATH=${SOURCE_RESTART_PATH:-}"
echo "==================================="

exec bash "$REPO_ROOT/scripts/engaging/gom_sampling_cases.sbatch"
