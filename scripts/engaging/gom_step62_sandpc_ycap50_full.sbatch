#!/bin/bash
#SBATCH --job-name=gom_s62_spc_full
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_sandpc_ycap50_common.sh"
gom_sandpc_resolve_task
gom_sandpc_export_locked_physics

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_root="$gom_root/results/gom_step62_sandpc_ycap50_full_job${SLURM_ARRAY_JOB_ID}"
case_tag="$(gom_sandpc_case_tag full1000y)"
case_dir="$result_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
final_check="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_sandpc_ycap50_final_check.jl"
test ! -e "$case_dir" || {
    echo "Refusing to reuse any prior full-run directory: $case_dir" >&2
    exit 1
}
mkdir -p "$case_dir"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || exit 1

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

export REPO_ROOT="$JUTULDARCY_COMBINED_REPO"
export CASE_LABEL="$GOM_PRODUCTION_CASE_KEY"
export CASE_TAG="$case_tag"
export RUN_ROOT="$result_root"
export PRODUCTION_SUMMARY_DIR="$summary_dir"
export RESTART_RUN=false
unset STOP_AFTER_REPORT_STEP RESTART_STEP

gom_sandpc_write_metadata "$case_dir/RUN_METADATA.txt" full1000y
printf 'allocated_walltime=%s\n' \
    "$(squeue -h -j "$SLURM_JOB_ID" -o '%l' | head -n 1)" \
    >> "$case_dir/RUN_METADATA.txt"
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

test "$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 2
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 210
test "$(find "$summary_dir/qoi/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 210
test -s "$summary_dir/report_steps.tsv"
test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
test -s "$summary_dir/qoi_region_manifest.tsv"
test -s "$summary_dir/qoi_interface_manifest.tsv"
test -s "$summary_dir/leakage_global_steps.tsv"
test -s "$summary_dir/regional_co2_inventory_steps.tsv"
test -s "$summary_dir/interface_flux_steps.tsv"
test -s "$summary_dir/leakage_case_summary.tsv"
test -s "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$final_check" \
    "$restart_dir" "$summary_dir" "$case_dir/final_state_summary.txt" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"

grep -Fxq 'status=pass' "$case_dir/final_state_summary.txt"
grep -Fxq "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "$case_dir/final_state_summary.txt"
grep -Fxq 'production_qoi_mode=required' \
    "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_global_rows=210' "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_region_rows=14490' "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_interface_rows=40530' \
    "$case_dir/final_state_summary.txt"

(
    cd "$case_dir"
    sha256sum restart/jutul_78.jld2 restart/jutul_210.jld2 \
        > RETAINED_RESTART_SHA256.txt
    sha256sum \
        restart/production_output/report_steps.tsv \
        restart/production_output/PRODUCTION_OUTPUT_COMPLETE.tsv \
        restart/production_output/qoi_region_manifest.tsv \
        restart/production_output/qoi_interface_manifest.tsv \
        restart/production_output/leakage_global_steps.tsv \
        restart/production_output/regional_co2_inventory_steps.tsv \
        restart/production_output/interface_flux_steps.tsv \
        restart/production_output/leakage_case_summary.tsv \
        restart/production_output/QOI_OUTPUT_COMPLETE.tsv \
        > PRODUCTION_SUMMARY_SHA256.txt
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)
{
    printf 'file\tbytes\n'
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\t%s\n' | sort -V
} > "$case_dir/RESTART_MANIFEST.tsv"

printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" \
    "realization_id=$GOM_PRODUCTION_REALIZATION_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
    "steps_completed=210" \
    "summary_rows=210" \
    "qoi_global_rows=210" \
    "qoi_region_rows=14490" \
    "qoi_interface_rows=40530" \
    "retained_restart_steps=78,210" \
    "schedule_end_years=1000" \
    "hysteresis_active=true" \
    "fault_pc_entry_treatment=predict_plateau_only" \
    "pc_reference=sand_theta30" \
    "host_pc_scaling=leverett_kv" \
    "nonpredict_pc_scaling=leverett_local_kzz" \
    "younger_nonpredict_local_perm_md=50,500,500" \
    "transmissibility_source=JutulDarcy_grid_and_rock" \
    "production_output_mode=true" \
    "production_qoi_mode=required" \
    "old_restart_reuse=false" \
    "result_dir=$case_dir" \
    > "$case_dir/production_summary.txt"
printf 'PASS\n' > "$case_dir/PASS"
