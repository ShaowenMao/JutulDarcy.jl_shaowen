#!/bin/bash
#SBATCH --job-name=gom_s62_epc_pf
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics
export PRODUCTION_QOI_MODE=required

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${SLURM_ARRAY_JOB_ID}"
result_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_preflight.jl"
test ! -e "$result_dir" || {
    echo "Refusing to reuse existing preflight directory: $result_dir" >&2
    exit 1
}
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export CASE_JULIA_THREADS="$SLURM_CPUS_PER_TASK"
export HYPRE_THREADS="$SLURM_CPUS_PER_TASK"

gom_effective_pc_write_metadata "$result_dir/RUN_METADATA.txt" preflight
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$result_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$result_dir/campaign.toml.sha256.original"

cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. "$script" \
    "$GOM_PRODUCTION_COMMON_MAT" "$GOM_PRODUCTION_SPECIFIC_MAT" \
    "$result_dir" "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_GEOLOGY_ID" \
    "$GOM_PRODUCTION_REALIZATION_ID" "$GOM_PRODUCTION_GEOLOGY_HASH" \
    "$GOM_PRODUCTION_LEVEL3_CASE_NAME" "$GOM_PRODUCTION_MANIFEST_SHA256"

summary="$result_dir/preflight_summary.txt"
test -s "$summary"
grep -Fxq 'status=pass' "$summary"
grep -Fxq "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" "$summary"
grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" "$summary"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$summary"
grep -Fxq 'base_saturation_regions=8' "$summary"
grep -Fxq 'explicit_predict_regions=522' "$summary"
grep -Fxq 'drainage_saturation_regions=530' "$summary"
grep -Fxq 'total_sgof_tables=1060' "$summary"
grep -Fxq 'hysteresis_active=true' "$summary"
grep -Fxq 'pc_mapping_schema=gom_effective_saturation_pc_v1' "$summary"
grep -Fxq \
    'pc_mapping_method=entry_renormalized_analytic_brooks_corey' "$summary"
grep -Fxq 'pc_mapping_digest_count=113' "$summary"
grep -Fxq 'pc_entry_treatment=plateau_all_active' "$summary"
grep -Fxq 'pc_entry_scope=all_active_drainage' "$summary"
grep -Fxq 'pc_entry_rule=first_strictly_positive_pc_node' "$summary"
grep -Fxq 'pc_plateau_active_tables=530' "$summary"
grep -Fxq 'pc_plateau_nonzero_entry_tables=530' "$summary"
grep -Fxq 'pc_plateau_adjusted_tables=530' "$summary"
grep -Fxq 'pc_plateau_already_plateaued_tables=0' "$summary"
grep -Fxq 'pc_plateau_true_zero_tables=0' "$summary"
grep -Fxq 'pc_plateau_skipped_tables=0' "$summary"
grep -Fxq 'pc_plateau_mirrored_explicit_tables=522' "$summary"
grep -Eq '^pc_input_drainage_sha256=[0-9a-f]{64}$' "$summary"
grep -Eq '^pc_output_drainage_sha256=[0-9a-f]{64}$' "$summary"
grep -Eq '^pc_kr_sha256=[0-9a-f]{64}$' "$summary"
grep -Eq '^pc_tail_sha256=[0-9a-f]{64}$' "$summary"
grep -Eq '^base_imbibition_sha256=[0-9a-f]{64}$' "$summary"
grep -Fxq 'pc_kr_unchanged=true' "$summary"
grep -Fxq 'pc_at_and_above_entry_unchanged=true' "$summary"
grep -Fxq 'base_imbibition_unchanged=true' "$summary"
grep -Fxq 'pc_reference=sand_theta30' "$summary"
grep -Fxq 'pc_saturation_coordinate=effective_gas_saturation' "$summary"
grep -Fxq 'host_pc_scaling=leverett_kv' "$summary"
grep -Fxq 'nonpredict_pc_scaling=leverett_local_kzz' "$summary"
grep -Fxq 'younger_nonpredict_cells=10701' "$summary"
grep -Fxq 'mrst_transmissibility_present=false' "$summary"
grep -Fxq 'jutul_transmissibility=true' "$summary"
grep -Fxq 'qoi_atomic_regions=55' "$summary"
grep -Fxq 'qoi_reporting_regions=69' "$summary"
grep -Fxq 'qoi_interfaces=193' "$summary"
printf 'PASS\n' > "$result_dir/PASS"
