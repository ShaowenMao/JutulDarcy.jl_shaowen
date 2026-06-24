#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -J gom_sampling
#SBATCH -c 8
#SBATCH --mem=128G
#SBATCH -t 12:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

module purge
module load community-modules
module load julia/1.10.4

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
RUN_ROOT=${RUN_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs}

CASE_ID=${CASE_ID:-${SLURM_ARRAY_TASK_ID:-all87_split}}

unset COMMON_MATFILE_PATH
unset SPECIFIC_MATFILE_PATH

case "$CASE_ID" in
    1|all87_whole)
        CASE_KEY=all87_whole
        export MATFILE_PATH="$INPUT_ROOT/all87/jutul/lluis_field_case_87_all87_whole.mat"
        ;;
    2|all87_split)
        CASE_KEY=all87_split
        export COMMON_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat"
        export SPECIFIC_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_realization_0001_specific.mat"
        export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
        ;;
    3|old86_whole)
        CASE_KEY=old86_whole
        export MATFILE_PATH="$INPUT_ROOT/old86/jutul/lluis_field_case_87_old86_whole.mat"
        ;;
    4|old86_split)
        CASE_KEY=old86_split
        export COMMON_MATFILE_PATH="$INPUT_ROOT/old86/jutul_split/lluis_field_case_87_old86_common.mat"
        export SPECIFIC_MATFILE_PATH="$INPUT_ROOT/old86/jutul_split/lluis_field_case_87_old86_realization_0001_specific.mat"
        export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
        ;;
    *)
        echo "Unknown CASE_ID=$CASE_ID"
        echo "Valid values: 1/all87_whole, 2/all87_split, 3/old86_whole, 4/old86_split"
        exit 1
        ;;
esac

export CASE_NAME=GOM_LARGE
export CASE_TAG=${CASE_TAG:-$CASE_KEY}
export RUN_MODE=${RUN_MODE:-simulate}
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export CASE_JULIA_THREADS=${SLURM_CPUS_PER_TASK:-8}
export VTU_PREFIX=${VTU_PREFIX:-$CASE_KEY}

export RESTART_OUTPUT_PATH="$RUN_ROOT/$CASE_TAG/restart"
export VTU_PATH="$RUN_ROOT/$CASE_TAG/vtu"
export CASE_LOG_DIR="$RUN_ROOT/$CASE_TAG/logs"
mkdir -p "$CASE_LOG_DIR"

JOB_LABEL=${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-manual}}
TASK_LABEL=${SLURM_ARRAY_TASK_ID:-0}
LOG_BASENAME="slurm-${SLURM_JOB_NAME:-gom_sampling}-${JOB_LABEL}_${TASK_LABEL}"
export CASE_STDOUT_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.out"
export CASE_STDERR_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.err"

exec > "$CASE_STDOUT_PATH" 2> "$CASE_STDERR_PATH"

cd "$REPO_ROOT"

echo "===== JOB ENV INFO ====="
hostname
date
pwd
which julia
julia --version
module list
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-}"
echo "SLURM_ARRAY_JOB_ID=${SLURM_ARRAY_JOB_ID:-}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-}"
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-}"
echo "CASE_STDOUT_PATH=$CASE_STDOUT_PATH"
echo "CASE_STDERR_PATH=$CASE_STDERR_PATH"
echo "========================"

if [ "$RUN_MODE" = "simulate" ] || [ "$RUN_MODE" = "sim" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-8}
    export RESTART_RUN=${RESTART_RUN:-false}
    export LOAD_STATES_AFTER_SIM=${LOAD_STATES_AFTER_SIM:-false}
    export WRITE_INCON_VTU=false
    export WRITE_STATE_VTU=false
    mkdir -p "$RESTART_OUTPUT_PATH"
elif [ "$RUN_MODE" = "vtu" ] || [ "$RUN_MODE" = "postprocess" ] || [ "$RUN_MODE" = "export" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-1}
    export WRITE_INCON_VTU=${WRITE_INCON_VTU:-true}
    export WRITE_STATE_VTU=${WRITE_STATE_VTU:-true}
    mkdir -p "$VTU_PATH"
elif [ "$RUN_MODE" = "both" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-8}
    export RESTART_RUN=${RESTART_RUN:-false}
    export LOAD_STATES_AFTER_SIM=${LOAD_STATES_AFTER_SIM:-true}
    mkdir -p "$RESTART_OUTPUT_PATH" "$VTU_PATH"
else
    echo "Unknown RUN_MODE=$RUN_MODE"
    echo "Valid values: simulate, vtu, both"
    exit 1
fi

echo "===== CASE INFO ====="
echo "CASE_ID=$CASE_ID"
echo "CASE_KEY=$CASE_KEY"
echo "CASE_TAG=$CASE_TAG"
echo "RUN_MODE=$RUN_MODE"
echo "MATFILE_PATH=$MATFILE_PATH"
echo "COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-}"
echo "SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-}"
echo "RESTART_OUTPUT_PATH=$RESTART_OUTPUT_PATH"
echo "VTU_PATH=$VTU_PATH"
echo "JULIA_NUM_THREADS=$JULIA_NUM_THREADS"
echo "CASE_JULIA_THREADS=$CASE_JULIA_THREADS"
echo "HYPRE_THREADS=$HYPRE_THREADS"
echo "====================="

if [ ! -f "$MATFILE_PATH" ]; then
    echo "MATFILE_PATH does not exist: $MATFILE_PATH"
    exit 1
fi
if [ -n "${COMMON_MATFILE_PATH:-}" ] && [ ! -f "$COMMON_MATFILE_PATH" ]; then
    echo "COMMON_MATFILE_PATH does not exist: $COMMON_MATFILE_PATH"
    exit 1
fi
if [ -n "${SPECIFIC_MATFILE_PATH:-}" ] && [ ! -f "$SPECIFIC_MATFILE_PATH" ]; then
    echo "SPECIFIC_MATFILE_PATH does not exist: $SPECIFIC_MATFILE_PATH"
    exit 1
fi

julia --startup-file=no --project=. src/input_simulation/co2_blackoil_gom.jl
