#!/bin/bash
#SBATCH --job-name=gom_s62_epc_smoke
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=04:00:00
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
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_smoke_job${SLURM_ARRAY_JOB_ID}"
case_tag="$(gom_effective_pc_case_tag smoke3)"
case_dir="$result_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
preflight_summary="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}/$GOM_PRODUCTION_CASE_KEY/preflight_summary.txt"
diagnostics_script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl"
test ! -e "$case_dir" || {
    echo "Refusing to reuse an existing smoke directory: $case_dir" >&2
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
grep -Fxq 'pc_plateau_active_tables=530' "$preflight_summary"
grep -Fxq 'pc_plateau_adjusted_tables=530' "$preflight_summary"
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
export STOP_AFTER_REPORT_STEP=2
unset RESTART_STEP

gom_effective_pc_write_metadata "$case_dir/RUN_METADATA.txt" smoke3
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"
test -s "$restart_dir/jutul_1.jld2"
test -s "$restart_dir/jutul_2.jld2"
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 2
test "$(find "$summary_dir/qoi/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 2
test -s "$summary_dir/qoi_region_manifest.tsv"
test -s "$summary_dir/qoi_interface_manifest.tsv"

export RESTART_RUN=true
export STOP_AFTER_REPORT_STEP=3
SLURM_JOB_NAME="${SLURM_JOB_NAME}_resume" \
    bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

mapfile -t restart_names < <(
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\n' | sort -V
)
test "${#restart_names[@]}" -eq 2
test "${restart_names[0]}" = jutul_2.jld2
test "${restart_names[1]}" = jutul_3.jld2
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 3
test "$(find "$summary_dir/qoi/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 3
test "$(wc -l < "$summary_dir/report_steps.tsv")" -eq 4
test "$(wc -l < "$summary_dir/leakage_global_steps.tsv")" -eq 4
test "$(wc -l < "$summary_dir/regional_co2_inventory_steps.tsv")" \
    -eq $((1 + 3*69))
test "$(wc -l < "$summary_dir/interface_flux_steps.tsv")" \
    -eq $((1 + 3*193))
test "$(wc -l < "$summary_dir/leakage_case_summary.tsv")" -eq 2
test ! -e "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
test ! -e "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"

# Prove restart equivalence for both the established task-1 cohort and the
# slowest historical member, task 5. This matches the production-output
# contract documented for the acceptance workflow.
restart_equivalence=not_selected
if [ "$SLURM_ARRAY_TASK_ID" -eq 1 ] || \
   [ "$SLURM_ARRAY_TASK_ID" -eq 5 ]; then
    control_tag="$(gom_effective_pc_case_tag smoke3_control)"
    control_dir="$result_root/$control_tag"
    control_restart_dir="$control_dir/restart"
    test ! -e "$control_dir"
    export CASE_TAG="$control_tag"
    export PRODUCTION_SUMMARY_DIR="$control_restart_dir/production_output"
    export RESTART_RUN=false
    export STOP_AFTER_REPORT_STEP=3
    SLURM_JOB_NAME="${SLURM_JOB_NAME}_control" \
        bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"
    test -s "$control_restart_dir/jutul_3.jld2"
    compare_script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_restart_compare.jl"
    module purge
    module load community-modules
    module load julia/1.10.4
    cd "$JUTULDARCY_COMBINED_REPO"
    julia --startup-file=no --project=. "$compare_script" \
        "$restart_dir" "$control_restart_dir" 3 \
        "$case_dir/restart_equivalence_summary.txt"
    grep -Fxq 'status=pass' \
        "$case_dir/restart_equivalence_summary.txt"
    restart_equivalence=pass
fi

module purge
module load community-modules
module load julia/1.10.4
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$diagnostics_script" \
    "$summary_dir" "$case_dir/runtime_diagnostics.txt" 3 \
    "$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"
grep -Fxq 'status=pass' "$case_dir/runtime_diagnostics.txt"

printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "reports_completed=3" \
    "summary_rows=3" \
    "qoi_global_rows=3" \
    "qoi_region_rows=$((3*69))" \
    "qoi_interface_rows=$((3*193))" \
    "rolling_checkpoints=2,3" \
    "restart_equivalence=$restart_equivalence" \
    "production_output_mode=true" \
    "production_qoi_mode=required" \
    "old_restart_reuse=false" \
    "pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    > "$case_dir/smoke_summary.txt"
grep -v '^status=' "$case_dir/runtime_diagnostics.txt" \
    >> "$case_dir/smoke_summary.txt"
printf 'PASS\n' > "$case_dir/PASS"
