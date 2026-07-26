#!/bin/bash
#SBATCH --job-name=gom_s62_4geo_hp_vtu
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-4%4
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${GOM_FOUR_GEOLOGY_INPUT_DIR:?Set GOM_FOUR_GEOLOGY_INPUT_DIR.}"
: "${GOM_FOUR_GEOLOGY_FULL_RESULT:?Set GOM_FOUR_GEOLOGY_FULL_RESULT.}"
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
source_candidates=()
while IFS= read -r path; do
    source_candidates+=("$path")
done < <(
    find "$GOM_FOUR_GEOLOGY_FULL_RESULT" -mindepth 1 -maxdepth 1 \
        -type d -name "*case${case_id}*" -print
)
test "${#source_candidates[@]}" -eq 1
source_case="${source_candidates[0]}"
restart_dir="$source_case/restart"
result_root="$gom_root/results/gom_step62_four_geology_hyst_plateau_standard_vtu_job${SLURM_ARRAY_JOB_ID}"
case_dir="$result_root/case${case_id}"
vtu_dir="$case_dir/vtu"
prefix="gom_step62_s05c012_case${case_id}_hyst_faultpcplateau"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_four_geology_hyst_plateau_standard_vtu.jl"

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
test -f "$source_case/PASS"
test -f "$source_case/production_summary.txt"
grep -q '^status=pass$' "$source_case/production_summary.txt"
grep -q '^steps_completed=210$' "$source_case/production_summary.txt"
grep -q '^hysteresis_active=true$' "$source_case/production_summary.txt"
grep -q '^fault_pc_entry_treatment=plateau$' \
    "$source_case/production_summary.txt"
grep -q '^transmissibility_source=JutulDarcy_grid_and_rock$' \
    "$source_case/production_summary.txt"
test "$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 210
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test -f "$script"
(
    cd "$source_case"
    sha256sum --check FINAL_RESTART_SHA256.txt
)

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
    "source_case=$source_case" \
    "source_steps=0,78,210" \
    "source_times_years=0,50,1000" \
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
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
    "$common_path" "$specific_path" "$restart_dir" "$vtu_dir" "$prefix" \
    "$case_dir/export_summary.txt" "$case_id" \
    > "$case_dir/export.out" 2> "$case_dir/export.err"

grep -q '^status=pass$' "$case_dir/export_summary.txt"
grep -q '^selected_steps=78,210$' "$case_dir/export_summary.txt"
grep -q '^selected_times_years=50.0,1000.0$' \
    "$case_dir/export_summary.txt"
grep -q '^additional_parameters=geology_indicators_only$' \
    "$case_dir/export_summary.txt"
grep -q '^fault_region_cells=150597$' \
    "$case_dir/export_summary.txt"
grep -q '^stratigraphy_region_cells=828240$' \
    "$case_dir/export_summary.txt"
grep -q '^fault_pc_adjusted_tables=522$' \
    "$case_dir/export_summary.txt"
vtu_count=$(find "$vtu_dir" -maxdepth 1 -type f -name '*.vtu' | wc -l)
pvd_count=$(find "$vtu_dir" -maxdepth 1 -type f -name '*.pvd' | wc -l)
test "$vtu_count" -eq 3
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
