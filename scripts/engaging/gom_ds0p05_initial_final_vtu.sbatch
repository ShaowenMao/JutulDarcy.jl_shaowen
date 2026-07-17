#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_final_vtu
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 08:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%j.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%j.err

set -euo pipefail

module purge
module load community-modules
module load julia/1.10.4

JULIA_CMD=${JULIA_CMD:-julia}
REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
RUN_ROOT=${RUN_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs}
SOURCE_CASE_TAG=${SOURCE_CASE_TAG:-all87_split_s05_c012_case01_relaxation_ds0p05_cuts25_nohyst_pcplateau_job17992883}
SOURCE_CASE_PATH=${SOURCE_CASE_PATH:-$RUN_ROOT/$SOURCE_CASE_TAG}
SOURCE_RESTART_PATH="$SOURCE_CASE_PATH/restart"

if [ ! -d "$SOURCE_RESTART_PATH" ]; then
    echo "Source restart directory does not exist: $SOURCE_RESTART_PATH"
    exit 1
fi

LATEST_RESTART_NAME=$(find "$SOURCE_RESTART_PATH" -maxdepth 1 -type f -name 'jutul_*.jld2' -printf '%f\n' | sort -V | tail -1)
if [ -z "$LATEST_RESTART_NAME" ]; then
    echo "No restart files found in $SOURCE_RESTART_PATH"
    exit 1
fi

DETECTED_FINAL_STEP=${LATEST_RESTART_NAME#jutul_}
DETECTED_FINAL_STEP=${DETECTED_FINAL_STEP%.jld2}
FINAL_STEP=${FINAL_STEP:-$DETECTED_FINAL_STEP}
FINAL_RESTART_FILE="$SOURCE_RESTART_PATH/jutul_${FINAL_STEP}.jld2"
if [ ! -f "$FINAL_RESTART_FILE" ]; then
    echo "Final restart file does not exist: $FINAL_RESTART_FILE"
    exit 1
fi

JOB_LABEL=${SLURM_JOB_ID:-manual}
export VTU_PATH="$SOURCE_CASE_PATH/vtu_initial_final_job${JOB_LABEL}"
FINAL_ONLY_RESTART_PATH="$VTU_PATH/restart_final_only"
CASE_LOG_DIR="$VTU_PATH/logs"
mkdir -p "$FINAL_ONLY_RESTART_PATH" "$CASE_LOG_DIR"
ln -s "$FINAL_RESTART_FILE" "$FINAL_ONLY_RESTART_PATH/jutul_${FINAL_STEP}.jld2"

LOG_BASENAME="slurm-${SLURM_JOB_NAME:-gom_final_vtu}-${JOB_LABEL}"
CASE_STDOUT_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.out"
CASE_STDERR_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.err"
BOOTSTRAP_STDOUT_PATH="$RUN_ROOT/slurm-bootstrap-${SLURM_JOB_NAME:-gom_final_vtu}-${JOB_LABEL}.out"
BOOTSTRAP_STDERR_PATH="$RUN_ROOT/slurm-bootstrap-${SLURM_JOB_NAME:-gom_final_vtu}-${JOB_LABEL}.err"

exec > "$CASE_STDOUT_PATH" 2> "$CASE_STDERR_PATH"

for bootstrap_path in "$BOOTSTRAP_STDOUT_PATH" "$BOOTSTRAP_STDERR_PATH"; do
    if [ -f "$bootstrap_path" ]; then
        mv -f "$bootstrap_path" "$CASE_LOG_DIR/"
    fi
done

export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export CASE_JULIA_THREADS=${SLURM_CPUS_PER_TASK:-8}
export HYPRE_THREADS=1
export CASE_NAME=GOM_LARGE
export RUN_MODE=vtu
export COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat}
export SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_slices_s05_c012_case01_specific.mat}
export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
export RESTART_OUTPUT_PATH="$FINAL_ONLY_RESTART_PATH"
export VTU_PREFIX=${VTU_PREFIX:-GoM_ds0p05}
export WRITE_INCON_VTU=true
export WRITE_STATE_VTU=true

# Reconstruct the exact physical model used by the completed source run.
export DISABLE_HYSTERESIS=${DISABLE_HYSTERESIS:-true}
export HYSTERESIS_S_MIN=${HYSTERESIS_S_MIN:-}
export USE_MRST_TRANSMISSIBILITY=${USE_MRST_TRANSMISSIBILITY:-true}
export IGNORE_MRST_T=${IGNORE_MRST_T:-false}
export FAULT_SATURATION_DOMAIN_MODE=${FAULT_SATURATION_DOMAIN_MODE:-input}
export FAULT_PC_ENTRY_TREATMENT=${FAULT_PC_ENTRY_TREATMENT:-plateau}
export FAULT_PC_ENTRY_SG_MAX=${FAULT_PC_ENTRY_SG_MAX:-1.0e-4}
export EXPLICIT_FAULT_HYSTERESIS_MODE=${EXPLICIT_FAULT_HYSTERESIS_MODE:-disable}
export ENABLE_DIFFUSION=${ENABLE_DIFFUSION:-false}

cd "$REPO_ROOT"

echo "===== INITIAL/FINAL VTU EXPORT ====="
echo "hostname=$(hostname)"
echo "date=$(date)"
echo "SOURCE_CASE_TAG=$SOURCE_CASE_TAG"
echo "FINAL_STEP=$FINAL_STEP"
echo "FINAL_RESTART_FILE=$FINAL_RESTART_FILE"
echo "FINAL_ONLY_RESTART_PATH=$FINAL_ONLY_RESTART_PATH"
echo "VTU_PATH=$VTU_PATH"
echo "JULIA_CMD=$JULIA_CMD"
echo "JULIA_NUM_THREADS=$JULIA_NUM_THREADS"
echo "WRITE_INCON_VTU=$WRITE_INCON_VTU"
echo "WRITE_STATE_VTU=$WRITE_STATE_VTU"
echo "DISABLE_HYSTERESIS=$DISABLE_HYSTERESIS"
echo "HYSTERESIS_S_MIN=$HYSTERESIS_S_MIN"
echo "EXPLICIT_FAULT_HYSTERESIS_MODE=$EXPLICIT_FAULT_HYSTERESIS_MODE"
echo "===================================="

"$JULIA_CMD" --startup-file=no --project=. src/input_simulation/co2_blackoil_gom.jl

echo "===== GENERATED VTU FILES ====="
find "$VTU_PATH" -maxdepth 1 -type f \( -name '*.vtu' -o -name '*.pvd' \) -printf '%f %s bytes\n' | sort
echo "==============================="
