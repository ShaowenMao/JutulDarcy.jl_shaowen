#!/bin/bash
#SBATCH --job-name=gom_s62_spc_vtu
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
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
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_sandpc_ycap50_common.sh"
gom_sandpc_resolve_task
export PRODUCTION_QOI_MODE=required

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_sandpc_ycap50_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        gom_sandpc_case_tag full1000y
)"
source_case="$full_root/$full_tag"
restart_dir="$source_case/restart"
result_root="$gom_root/results/gom_step62_sandpc_ycap50_vtu_job${SLURM_ARRAY_JOB_ID}"
case_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
vtu_dir="$case_dir/vtu"
prefix="gom_step62_sandpc_ycap50_${GOM_PRODUCTION_CASE_KEY}"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_sandpc_ycap50_vtu.jl"
test ! -e "$case_dir" || {
    echo "Refusing to reuse an existing VTU directory: $case_dir" >&2
    exit 1
}
mkdir -p "$vtu_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$source_case/PASS"
grep -Fxq 'status=pass' "$source_case/production_summary.txt"
grep -Fxq "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "$source_case/production_summary.txt"
grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "$source_case/production_summary.txt"
grep -Fxq 'steps_completed=210' "$source_case/production_summary.txt"
grep -Fxq 'production_qoi_mode=required' \
    "$source_case/production_summary.txt"
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
(
    cd "$source_case"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export OPENBLAS_NUM_THREADS=1

gom_sandpc_write_metadata "$case_dir/EXPORT_METADATA.txt" vtu
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
grep -Fxq "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "$case_dir/export_summary.txt"
grep -Fxq "case_id=$GOM_PRODUCTION_CASE_KEY" \
    "$case_dir/export_summary.txt"
grep -Fxq 'vtu_files=3' "$case_dir/export_summary.txt"
grep -Fxq 'selected_steps=78,210' "$case_dir/export_summary.txt"
grep -Fxq 'additional_parameters=geology_indicators_only' \
    "$case_dir/export_summary.txt"
grep -Fxq 'base_saturation_regions=8' "$case_dir/export_summary.txt"
grep -Fxq 'explicit_predict_regions=522' "$case_dir/export_summary.txt"
grep -Fxq 'drainage_saturation_regions=530' "$case_dir/export_summary.txt"
grep -Fxq 'total_sgof_tables=1060' "$case_dir/export_summary.txt"
grep -Fxq 'geology_indicator_schema=gom_vtu_geology_indicators_v2' \
    "$case_dir/export_summary.txt"
grep -Fxq \
    'fault_region_flag_values=0:outside_fault,1:predict_fault,2:nonpredict_fault' \
    "$case_dir/export_summary.txt"
grep -Fxq \
    'stratigraphy_region_flag_values=0:outside_stratigraphy,1:sand,2:clay' \
    "$case_dir/export_summary.txt"
grep -Fxq 'fault_region_cells=150597' "$case_dir/export_summary.txt"
grep -Fxq 'specific_fault_cells=32190' "$case_dir/export_summary.txt"
grep -Fxq 'predict_fault_cells=32190' "$case_dir/export_summary.txt"
grep -Fxq 'nonpredict_fault_cells=118407' "$case_dir/export_summary.txt"
grep -Fxq 'stratigraphy_region_cells=828240' \
    "$case_dir/export_summary.txt"
stratigraphy_sand_cells="$(
    awk -F= '/^stratigraphy_sand_cells=/{print $2}' \
        "$case_dir/export_summary.txt"
)"
stratigraphy_clay_cells="$(
    awk -F= '/^stratigraphy_clay_cells=/{print $2}' \
        "$case_dir/export_summary.txt"
)"
[[ "$stratigraphy_sand_cells" =~ ^[1-9][0-9]*$ ]]
[[ "$stratigraphy_clay_cells" =~ ^[1-9][0-9]*$ ]]
test "$((stratigraphy_sand_cells + stratigraphy_clay_cells))" -eq 828240
grep -Eq '^fault_region_flag_sha256=[0-9a-f]{64}$' \
    "$case_dir/export_summary.txt"
grep -Eq '^stratigraphy_region_flag_sha256=[0-9a-f]{64}$' \
    "$case_dir/export_summary.txt"
grep -Fxq 'fault_pc_adjusted_tables=522' \
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
