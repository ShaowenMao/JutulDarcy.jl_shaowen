#!/bin/bash
#SBATCH --job-name=gom_s62_pc0_audit
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-4
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
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
result_root="$gom_root/results/gom_step62_zero_pc_audit_job${SLURM_ARRAY_JOB_ID}"
result_dir="$result_root/case${case_id}"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/audit_gom_step62_zero_pc.jl"
summary_path="$result_dir/zero_pc_summary.txt"
detail_path="$result_dir/stratigraphy_pc_detail.tsv"

mkdir -p "$result_dir"

module purge
module load community-modules
module load julia/1.10.4

export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1

cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$script" \
    "$common_path" \
    "$specific_path" \
    "$summary_path" \
    "$detail_path"

test -s "$summary_path"
test -s "$detail_path"
grep -q '^status=pass$' "$summary_path"
printf 'PASS\n' > "$result_dir/PASS"
