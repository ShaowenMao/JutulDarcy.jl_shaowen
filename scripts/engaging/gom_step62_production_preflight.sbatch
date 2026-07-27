#!/bin/bash
#SBATCH --job-name=gom_s62_prod_pf
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-7%2
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_root="$gom_root/results/gom_step62_production_preflight_job${SLURM_ARRAY_JOB_ID}"
result_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_preflight.jl"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$script"
module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export CASE_JULIA_THREADS="$SLURM_CPUS_PER_TASK"
export HYPRE_THREADS="$SLURM_CPUS_PER_TASK"
export EXPECTED_NONPREDICT_PC_CONTACT_ANGLE_DEG=30

gom_production_write_metadata "$result_dir/RUN_METADATA.txt" preflight
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
grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" "$summary"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$summary"
grep -Fxq 'common_name=gom_step62_87slice_7case_common' "$summary"
grep -Fxq "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" "$summary"
grep -Fxq "geology_hash=$GOM_PRODUCTION_GEOLOGY_HASH" "$summary"
grep -Fxq "realization_id=$GOM_PRODUCTION_REALIZATION_ID" "$summary"
grep -Fxq "level3_case_name=$GOM_PRODUCTION_LEVEL3_CASE_NAME" "$summary"
grep -Fxq 'hysteresis_active=true' "$summary"
grep -Fxq 'hysteresis_s_min=0.05' "$summary"
grep -Fxq 'fault_hysteresis=drainage_equivalent' "$summary"
grep -Fxq 'pc_curve_treatment=fault_plateau' "$summary"
grep -Fxq 'pc_plateau_adjusted_tables=522' "$summary"
grep -Fxq 'pc_plateau_skipped_tables=0' "$summary"
grep -Fxq 'nonpredict_pc_reference_contact_angle_deg=30.0' "$summary"
grep -Fxq 'mrst_transmissibility_present=false' "$summary"
grep -Fxq 'jutul_transmissibility=true' "$summary"
printf 'PASS\n' > "$result_dir/PASS"
