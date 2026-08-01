#!/bin/bash
#SBATCH --job-name=gom_s62_epc_full
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=4-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_PRODUCTION_PREFLIGHT_JOB_ID:?Missing preflight array job ID.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${SLURM_ARRAY_JOB_ID}"
case_tag="$(gom_effective_pc_case_tag full1000y)"
case_dir="$result_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
preflight_summary="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}/$GOM_PRODUCTION_CASE_KEY/preflight_summary.txt"
final_check="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_final_check.jl"
diagnostics_script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl"
test ! -e "$case_dir" || {
    echo "Refusing to reuse any prior full-run directory: $case_dir" >&2
    exit 1
}
mkdir -p "$case_dir"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || exit 1

test -s "$preflight_summary"
grep -Fxq 'status=pass' "$preflight_summary"
grep -Fxq "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "$preflight_summary"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$preflight_summary"
grep -Fxq 'pc_entry_treatment=plateau_all_active' "$preflight_summary"
grep -Fxq 'pc_plateau_active_tables=530' "$preflight_summary"
grep -Fxq 'pc_plateau_adjusted_tables=530' "$preflight_summary"
grep -Fxq 'pc_plateau_true_zero_tables=0' "$preflight_summary"
cp -- "$preflight_summary" "$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"

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

gom_effective_pc_write_metadata "$case_dir/RUN_METADATA.txt" full1000y
printf 'allocated_walltime=%s\n' \
    "$(squeue -h -j "$SLURM_JOB_ID" -o '%l' | head -n 1)" \
    >> "$case_dir/RUN_METADATA.txt"
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

test "$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 4
test -s "$restart_dir/jutul_51.jld2"
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_110.jld2"
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
julia --startup-file=no --project=. "$diagnostics_script" \
    "$summary_dir" "$case_dir/runtime_diagnostics.txt" 210 \
    "$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"

grep -Fxq 'status=pass' "$case_dir/final_state_summary.txt"
grep -Fxq "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "$case_dir/final_state_summary.txt"
grep -Fxq 'production_qoi_mode=required' \
    "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_global_rows=210' "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_region_rows=14490' "$case_dir/final_state_summary.txt"
grep -Fxq 'qoi_interface_rows=40530' \
    "$case_dir/final_state_summary.txt"
grep -Fxq 'status=pass' "$case_dir/runtime_diagnostics.txt"

(
    cd "$case_dir"
    sha256sum restart/jutul_51.jld2 restart/jutul_78.jld2 \
        restart/jutul_110.jld2 restart/jutul_210.jld2 \
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
        PREFLIGHT_PC_TABLE_CONTRACT.txt \
        runtime_diagnostics.txt \
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
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
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
    "retained_restart_steps=51,78,110,210" \
    "schedule_end_years=1000" \
    "hysteresis_active=true" \
    "fault_pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "pc_entry_rule=first_strictly_positive_pc_node" \
    "pc_mapping_schema=gom_effective_saturation_pc_v1" \
    "pc_mapping_method=entry_renormalized_analytic_brooks_corey" \
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
grep -E \
    '^(pc_(input|output)_drainage_sha256|pc_kr_sha256|pc_tail_sha256|base_imbibition_sha256|pc_kr_unchanged|pc_at_and_above_entry_unchanged|base_imbibition_unchanged)=' \
    "$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt" \
    >> "$case_dir/production_summary.txt"
grep -v '^status=' "$case_dir/runtime_diagnostics.txt" \
    >> "$case_dir/production_summary.txt"
printf 'PASS\n' > "$case_dir/PASS"
