#!/bin/bash
#SBATCH --job-name=gom_s62_prod_vtu
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-7%2
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set GOM_PRODUCTION_FULL_JOB_ID.}"
[[ "$GOM_PRODUCTION_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_PRODUCTION_FULL_JOB_ID must be numeric." >&2; exit 1; }
source "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_production_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="gom_step62_production_${GOM_PRODUCTION_CASE_KEY}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_PRODUCTION_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
source_case="$full_root/$full_tag"
restart_dir="$source_case/restart"
result_root="$gom_root/results/gom_step62_production_vtu_job${SLURM_ARRAY_JOB_ID}"
case_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
vtu_dir="$case_dir/vtu"
prefix="gom_step62_production_${GOM_PRODUCTION_CASE_KEY}_hyst_faultpcplateau_npctheta30"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_four_geology_hyst_plateau_standard_vtu.jl"
mkdir -p "$vtu_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$source_case/PASS"
test -s "$source_case/production_summary.txt"
grep -Fxq 'status=pass' "$source_case/production_summary.txt"
grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "$source_case/production_summary.txt"
grep -Fxq 'steps_completed=210' "$source_case/production_summary.txt"
grep -Fxq 'summary_rows=210' "$source_case/production_summary.txt"
grep -Fxq 'retained_restart_steps=78,210' \
    "$source_case/production_summary.txt"
grep -Fxq 'production_output_mode=true' \
    "$source_case/production_summary.txt"
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
(
    cd "$source_case"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)
test -f "$script"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export OPENBLAS_NUM_THREADS=1

gom_production_write_metadata "$case_dir/EXPORT_METADATA.txt" vtu
printf 'source_full_job_id=%s\nsource_case=%s\n' \
    "$GOM_PRODUCTION_FULL_JOB_ID" "$source_case" \
    >> "$case_dir/EXPORT_METADATA.txt"
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$script" \
    "$GOM_PRODUCTION_COMMON_MAT" "$GOM_PRODUCTION_SPECIFIC_MAT" \
    "$restart_dir" "$vtu_dir" "$prefix" "$case_dir/export_summary.txt" \
    "$GOM_PRODUCTION_CASE_KEY" \
    > "$case_dir/export.out" 2> "$case_dir/export.err"

grep -Fxq 'status=pass' "$case_dir/export_summary.txt"
grep -Fxq "case_id=$GOM_PRODUCTION_CASE_KEY" \
    "$case_dir/export_summary.txt"
grep -Fxq 'vtu_files=3' "$case_dir/export_summary.txt"
grep -Fxq 'pvd_files=1' "$case_dir/export_summary.txt"
grep -Fxq 'selected_steps=78,210' "$case_dir/export_summary.txt"
grep -Fxq 'selected_times_years=50.0,1000.0' \
    "$case_dir/export_summary.txt"
grep -Fxq 'additional_parameters=geology_indicators_only' \
    "$case_dir/export_summary.txt"
grep -Fxq 'fault_region_cells=150597' "$case_dir/export_summary.txt"
grep -Fxq 'stratigraphy_region_cells=828240' \
    "$case_dir/export_summary.txt"
test -s "$vtu_dir/${prefix}_incon_0001.vtu"
test -s "$vtu_dir/${prefix}_0078.vtu"
test -s "$vtu_dir/${prefix}_0210.vtu"
test -s "$vtu_dir/${prefix}.pvd"
(
    cd "$case_dir"
    sha256sum \
        "vtu/${prefix}_incon_0001.vtu" \
        "vtu/${prefix}_0078.vtu" \
        "vtu/${prefix}_0210.vtu" \
        "vtu/${prefix}.pvd" \
        > VTU_SHA256.txt
    sha256sum --check VTU_SHA256.txt
)
printf 'PASS\n' > "$case_dir/PASS"
