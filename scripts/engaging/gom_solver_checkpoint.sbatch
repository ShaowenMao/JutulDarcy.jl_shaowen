#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_solver_ckpt
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 1-00:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/solver_checkpoints/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/solver_checkpoints/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

module purge
module load community-modules
module load julia/1.10.4

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
CHECKPOINT_ROOT=${CHECKPOINT_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs/solver_checkpoints}
SOURCE_RESTART_PATH=${SOURCE_RESTART_PATH:?Set SOURCE_RESTART_PATH to the original restart directory.}
CHECKPOINT_EXPERIMENT=${CHECKPOINT_EXPERIMENT:-solver_matrix}
ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:?Submit this script as a Slurm array.}

export COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat}
export SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_slices_s05_c012_case01_specific.mat}
export MATFILE_PATH=$SPECIFIC_MATFILE_PATH

case "$CHECKPOINT_EXPERIMENT" in
    solver_matrix)
        TARGET_REPORT_STEP=${TARGET_REPORT_STEP:-63}
        EXPERIMENT_MAX_NONLINEAR_ITERATIONS=20
        case "$ARRAY_TASK_ID" in
            1)
                SOLVER_VARIANT=reference
                export NONLINEAR_RELAXATION=false
                export TARGET_ITS=8
                export TARGET_DS=Inf
                export TIMESTEP_MAX_INCREASE=10.0
                ;;
            2)
                SOLVER_VARIANT=relaxation
                export NONLINEAR_RELAXATION=true
                export TARGET_ITS=8
                export TARGET_DS=Inf
                export TIMESTEP_MAX_INCREASE=10.0
                ;;
            3)
                SOLVER_VARIANT=conservative_dt
                export NONLINEAR_RELAXATION=false
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export TIMESTEP_MAX_INCREASE=1.25
                ;;
            4)
                SOLVER_VARIANT=relaxation_conservative_dt
                export NONLINEAR_RELAXATION=true
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export TIMESTEP_MAX_INCREASE=1.25
                ;;
            *)
                echo "Unknown solver_matrix task $ARRAY_TASK_ID. Valid tasks are 1-4."
                exit 1
                ;;
        esac
        ;;
    timestep_refinement)
        EXPERIMENT_MAX_NONLINEAR_ITERATIONS=10
        export NONLINEAR_RELAXATION=true
        export TARGET_ITS=5
        export TIMESTEP_MAX_INCREASE=1.25
        case "$ARRAY_TASK_ID" in
            1)
                TARGET_REPORT_STEP=63
                SOLVER_VARIANT=relaxation_ds0p02
                export TARGET_DS=0.02
                ;;
            2)
                TARGET_REPORT_STEP=63
                SOLVER_VARIANT=relaxation_ds0p01
                export TARGET_DS=0.01
                ;;
            3)
                TARGET_REPORT_STEP=105
                SOLVER_VARIANT=relaxation_dsinf
                export TARGET_DS=Inf
                ;;
            4)
                TARGET_REPORT_STEP=105
                SOLVER_VARIANT=relaxation_ds0p05
                export TARGET_DS=0.05
                ;;
            5)
                TARGET_REPORT_STEP=105
                SOLVER_VARIANT=relaxation_ds0p02
                export TARGET_DS=0.02
                ;;
            6)
                TARGET_REPORT_STEP=105
                SOLVER_VARIANT=relaxation_ds0p01
                export TARGET_DS=0.01
                ;;
            *)
                echo "Unknown timestep_refinement task $ARRAY_TASK_ID. Valid tasks are 1-6."
                exit 1
                ;;
        esac
        ;;
    timestep_reference)
        EXPERIMENT_MAX_NONLINEAR_ITERATIONS=10
        export NONLINEAR_RELAXATION=true
        export TARGET_ITS=5
        export TIMESTEP_MAX_INCREASE=1.25
        case "$ARRAY_TASK_ID" in
            1)
                TARGET_REPORT_STEP=105
                SOLVER_VARIANT=relaxation_ds0p005
                export TARGET_DS=0.005
                ;;
            *)
                echo "Unknown timestep_reference task $ARRAY_TASK_ID. Valid task is 1."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unknown CHECKPOINT_EXPERIMENT=$CHECKPOINT_EXPERIMENT."
        echo "Valid values: solver_matrix, timestep_refinement, timestep_reference"
        exit 1
        ;;
esac

PREVIOUS_REPORT_STEP=$((TARGET_REPORT_STEP - 1))
if [ "$PREVIOUS_REPORT_STEP" -lt 1 ]; then
    echo "TARGET_REPORT_STEP must be at least 2 for a checkpoint restart."
    exit 1
fi

SOURCE_RESTART_FILE="$SOURCE_RESTART_PATH/jutul_${PREVIOUS_REPORT_STEP}.jld2"
if [ ! -f "$SOURCE_RESTART_FILE" ]; then
    echo "Source checkpoint does not exist: $SOURCE_RESTART_FILE"
    exit 1
fi
if [ ! -f "$COMMON_MATFILE_PATH" ] || [ ! -f "$SPECIFIC_MATFILE_PATH" ]; then
    echo "The common or specific MAT input does not exist."
    echo "COMMON_MATFILE_PATH=$COMMON_MATFILE_PATH"
    echo "SPECIFIC_MATFILE_PATH=$SPECIFIC_MATFILE_PATH"
    exit 1
fi

JOB_LABEL=${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}
TASK_LABEL=${SLURM_ARRAY_TASK_ID}
export CASE_TAG="all87_split_s05_c012_case01_step${TARGET_REPORT_STEP}_${SOLVER_VARIANT}_job${JOB_LABEL}"
export CASE_NAME=GOM_LARGE
export RUN_MODE=simulate
export RESTART_OUTPUT_PATH="$CHECKPOINT_ROOT/$CASE_TAG/restart"
export VTU_PATH="$CHECKPOINT_ROOT/$CASE_TAG/vtu"
CASE_LOG_DIR="$CHECKPOINT_ROOT/$CASE_TAG/logs"
mkdir -p "$RESTART_OUTPUT_PATH" "$CASE_LOG_DIR"

ln -s "$SOURCE_RESTART_FILE" "$RESTART_OUTPUT_PATH/jutul_${PREVIOUS_REPORT_STEP}.jld2"

LOG_BASENAME="slurm-${SLURM_JOB_NAME}-${JOB_LABEL}_${TASK_LABEL}"
export CASE_STDOUT_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.out"
export CASE_STDERR_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.err"
BOOTSTRAP_STDOUT_PATH="$CHECKPOINT_ROOT/slurm-bootstrap-${SLURM_JOB_NAME}-${JOB_LABEL}_${TASK_LABEL}.out"
BOOTSTRAP_STDERR_PATH="$CHECKPOINT_ROOT/slurm-bootstrap-${SLURM_JOB_NAME}-${JOB_LABEL}_${TASK_LABEL}.err"

exec > "$CASE_STDOUT_PATH" 2> "$CASE_STDERR_PATH"

for bootstrap_path in "$BOOTSTRAP_STDOUT_PATH" "$BOOTSTRAP_STDERR_PATH"; do
    if [ -f "$bootstrap_path" ]; then
        mv -f "$bootstrap_path" "$CASE_LOG_DIR/"
    fi
done

export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export CASE_JULIA_THREADS=${SLURM_CPUS_PER_TASK:-8}
export HYPRE_THREADS=${HYPRE_THREADS:-8}
export MAX_NONLINEAR_ITERATIONS=${MAX_NONLINEAR_ITERATIONS:-$EXPERIMENT_MAX_NONLINEAR_ITERATIONS}
export MAX_TIMESTEP_CUTS=${MAX_TIMESTEP_CUTS:-25}
export DR_MAX=${DR_MAX:-Inf}
export RESTART_RUN=false
export RESTART_STEP=$TARGET_REPORT_STEP
export STOP_AFTER_REPORT_STEP=$TARGET_REPORT_STEP
export LOAD_STATES_AFTER_SIM=false
export LOAD_REPORTS_AFTER_SIM=false
export IN_MEMORY_REPORTS=1
export WRITE_INCON_VTU=false
export WRITE_STATE_VTU=false

# Physical model controls are fixed across every checkpoint experiment.
export DISABLE_HYSTERESIS=true
export HYSTERESIS_S_MIN=
export USE_MRST_TRANSMISSIBILITY=true
export IGNORE_MRST_T=false
export FAULT_SATURATION_DOMAIN_MODE=input
export FAULT_PC_ENTRY_TREATMENT=plateau
export FAULT_PC_ENTRY_SG_MAX=1.0e-4
export EXPLICIT_FAULT_HYSTERESIS_MODE=disable
export ENABLE_DIFFUSION=false

cd "$REPO_ROOT"

echo "===== CHECKPOINT EXPERIMENT ====="
echo "hostname=$(hostname)"
echo "date=$(date)"
echo "SLURM_JOB_ID=$SLURM_JOB_ID"
echo "SLURM_ARRAY_JOB_ID=${SLURM_ARRAY_JOB_ID:-}"
echo "SLURM_ARRAY_TASK_ID=$SLURM_ARRAY_TASK_ID"
echo "CHECKPOINT_EXPERIMENT=$CHECKPOINT_EXPERIMENT"
echo "CASE_TAG=$CASE_TAG"
echo "SOLVER_VARIANT=$SOLVER_VARIANT"
echo "SOURCE_RESTART_FILE=$SOURCE_RESTART_FILE"
echo "TARGET_REPORT_STEP=$TARGET_REPORT_STEP"
echo "COMMON_MATFILE_PATH=$COMMON_MATFILE_PATH"
echo "SPECIFIC_MATFILE_PATH=$SPECIFIC_MATFILE_PATH"
echo "NONLINEAR_RELAXATION=$NONLINEAR_RELAXATION"
echo "TARGET_ITS=$TARGET_ITS"
echo "TARGET_DS=$TARGET_DS"
echo "TIMESTEP_MAX_INCREASE=$TIMESTEP_MAX_INCREASE"
echo "DR_MAX=$DR_MAX"
echo "MAX_NONLINEAR_ITERATIONS=$MAX_NONLINEAR_ITERATIONS"
echo "MAX_TIMESTEP_CUTS=$MAX_TIMESTEP_CUTS"
echo "JULIA_NUM_THREADS=$JULIA_NUM_THREADS"
echo "HYPRE_THREADS=$HYPRE_THREADS"
echo "RESTART_OUTPUT_PATH=$RESTART_OUTPUT_PATH"
echo "CASE_STDOUT_PATH=$CASE_STDOUT_PATH"
echo "CASE_STDERR_PATH=$CASE_STDERR_PATH"
echo "================================="

julia --startup-file=no --project=. src/input_simulation/co2_blackoil_gom.jl
