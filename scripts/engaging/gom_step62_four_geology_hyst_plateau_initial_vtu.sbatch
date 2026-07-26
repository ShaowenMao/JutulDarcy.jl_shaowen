#!/bin/bash
#SBATCH --job-name=gom_s62_4geo_hp_vtu0
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
result_root="$gom_root/results/gom_step62_four_geology_hyst_plateau_initial_vtu_job${SLURM_ARRAY_JOB_ID}"
case_dir="$result_root/case${case_id}"
vtu_dir="$case_dir/vtu"
prefix="gom_step62_s05c012_case${case_id}_hyst_faultpcplateau_initial_regions"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_four_geology_hyst_plateau_initial_vtu.jl"

mkdir -p "$vtu_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
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
export OPENBLAS_NUM_THREADS=1

printf '%s\n' \
    "job_id=$SLURM_JOB_ID" \
    "array_job_id=$SLURM_ARRAY_JOB_ID" \
    "array_task_id=$SLURM_ARRAY_TASK_ID" \
    "node=$SLURMD_NODENAME" \
    "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "case_id=$case_id" \
    "geology_id=s05_c012" \
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
    "initial_state=true" \
    "time_years=0" \
    "parameter_set=standard_compact_plus_geology_indicators" \
    "additional_parameters=geology_indicators_only" \
    "hysteresis=true" \
    "hysteresis_s_min=0.05" \
    "fault_hysteresis=drainage_equivalent" \
    "pc_curve_treatment=fault_plateau" \
    "use_mrst_transmissibility=false" \
    "memory=24G" \
    "cpus=8" \
    > "$case_dir/EXPORT_METADATA.txt"

cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$script" \
    "$common_path" "$specific_path" "$vtu_dir" "$prefix" \
    "$case_dir/export_summary.txt" "$case_id" \
    > "$case_dir/export.out" 2> "$case_dir/export.err"

grep -q '^status=pass$' "$case_dir/export_summary.txt"
grep -q '^initial_state=true$' "$case_dir/export_summary.txt"
grep -q '^additional_parameters=geology_indicators_only$' \
    "$case_dir/export_summary.txt"
grep -q '^fault_region_cells=150597$' \
    "$case_dir/export_summary.txt"
grep -q '^specific_fault_cells=32190$' \
    "$case_dir/export_summary.txt"
grep -q '^stratigraphy_region_cells=828240$' \
    "$case_dir/export_summary.txt"
grep -q '^stratigraphic_unit_ids=1:21$' \
    "$case_dir/export_summary.txt"
grep -q '^fault_pc_adjusted_tables=522$' "$case_dir/export_summary.txt"
vtu_count=$(find "$vtu_dir" -maxdepth 1 -type f -name '*.vtu' | wc -l)
pvd_count=$(find "$vtu_dir" -maxdepth 1 -type f -name '*.pvd' | wc -l)
test "$vtu_count" -eq 1
test "$pvd_count" -eq 1

(
    cd "$vtu_dir"
    find . -maxdepth 1 -type f \( -name '*.vtu' -o -name '*.pvd' \) \
        -print0 |
        sort -z |
        xargs -0 sha256sum > VTU_SHA256SUMS.txt
    sha256sum --check VTU_SHA256SUMS.txt
)
printf 'PASS\n' > "$case_dir/PASS"
