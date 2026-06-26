#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_vtu
#SBATCH -c 2
#SBATCH --mem=64G
#SBATCH -t 08:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

# Export VTU files from the eight existing GoM sampling simulation folders:
#   - hysteresis-on simulations from HYST_JOB_ID
#   - no-hysteresis simulations from NOHYST_JOB_ID
#
# The heavy lifting stays in gom_sampling_cases.sbatch. This wrapper only maps
# array task ids to CASE_ID, CASE_TAG, and DISABLE_HYSTERESIS.

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
HYST_JOB_ID=${HYST_JOB_ID:-16482723}
NOHYST_JOB_ID=${NOHYST_JOB_ID:-16536683}

TASK_ID=${SLURM_ARRAY_TASK_ID:-1}

case "$TASK_ID" in
    1)
        export CASE_ID=all87_whole_cuts25
        export CASE_TAG="all87_whole_cuts25_job${HYST_JOB_ID}"
        export DISABLE_HYSTERESIS=false
        ;;
    2)
        export CASE_ID=all87_split_cuts25
        export CASE_TAG="all87_split_cuts25_job${HYST_JOB_ID}"
        export DISABLE_HYSTERESIS=false
        ;;
    3)
        export CASE_ID=old86_whole_cuts25
        export CASE_TAG="old86_whole_cuts25_job${HYST_JOB_ID}"
        export DISABLE_HYSTERESIS=false
        ;;
    4)
        export CASE_ID=old86_split_cuts25
        export CASE_TAG="old86_split_cuts25_job${HYST_JOB_ID}"
        export DISABLE_HYSTERESIS=false
        ;;
    5)
        export CASE_ID=all87_whole_cuts25
        export CASE_TAG="all87_whole_cuts25_nohyst_job${NOHYST_JOB_ID}"
        export DISABLE_HYSTERESIS=true
        ;;
    6)
        export CASE_ID=all87_split_cuts25
        export CASE_TAG="all87_split_cuts25_nohyst_job${NOHYST_JOB_ID}"
        export DISABLE_HYSTERESIS=true
        ;;
    7)
        export CASE_ID=old86_whole_cuts25
        export CASE_TAG="old86_whole_cuts25_nohyst_job${NOHYST_JOB_ID}"
        export DISABLE_HYSTERESIS=true
        ;;
    8)
        export CASE_ID=old86_split_cuts25
        export CASE_TAG="old86_split_cuts25_nohyst_job${NOHYST_JOB_ID}"
        export DISABLE_HYSTERESIS=true
        ;;
    *)
        echo "Unknown SLURM_ARRAY_TASK_ID=$TASK_ID"
        echo "Valid values: 1-8"
        exit 1
        ;;
esac

export RUN_MODE=vtu
export WRITE_INCON_VTU=${WRITE_INCON_VTU:-true}
export WRITE_STATE_VTU=${WRITE_STATE_VTU:-true}
export HYPRE_THREADS=${HYPRE_THREADS:-1}
export VTU_PREFIX=${VTU_PREFIX:-$CASE_TAG}

echo "Submitting VTU export task $TASK_ID"
echo "CASE_ID=$CASE_ID"
echo "CASE_TAG=$CASE_TAG"
echo "DISABLE_HYSTERESIS=$DISABLE_HYSTERESIS"
echo "REPO_ROOT=$REPO_ROOT"
echo "HYST_JOB_ID=$HYST_JOB_ID"
echo "NOHYST_JOB_ID=$NOHYST_JOB_ID"

bash "$REPO_ROOT/scripts/engaging/gom_sampling_cases.sbatch"
