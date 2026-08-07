#!/bin/bash
#SBATCH --job-name=gom_s62_s2_recover_vtu
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

# Re-export the complete affected shard coverage from the original simulation
# trees. Each task can map to a different source full-array job.

set -euo pipefail
umask 027

: "${GOM_RECOVERY_CASE_JOB_ID:?Set GOM_RECOVERY_CASE_JOB_ID.}"
[[ "$GOM_RECOVERY_CASE_JOB_ID" =~ ^[0-9]+$ ]]
source \
    "$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_common.sh"
gom_recovery_resolve_plan_task "$SLURM_ARRAY_TASK_ID"
gom_recovery_set_case_paths \
    "$GOM_RECOVERY_TASK" "$GOM_RECOVERY_CASE_KEY" \
    "$GOM_RECOVERY_SOURCE_PREFLIGHT_JOB" \
    "$GOM_RECOVERY_SOURCE_FULL_JOB"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
recovery_case_dir="$gom_root/results/gom_step62_schema2_recovery_case_job${GOM_RECOVERY_CASE_JOB_ID}/$GOM_RECOVERY_CASE_KEY"
case "$GOM_RECOVERY_TASK_SELECTED" in
    true)
        # Selected tasks were handled by the recovery-case array. Require its
        # plan-bound provenance marker before exporting the repaired source
        # tree.
        test -f "$recovery_case_dir/PASS"
        grep -Fxq "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
            "$recovery_case_dir/recovery_summary.txt"
        ;;
    false)
        # Complete source cases are intentionally absent from the recovery-
        # case array. Their original result trees were already validated by
        # the full-coverage gate, so requiring a recovery attempt here would
        # reject every unchanged case in a mixed recovery shard.
        test ! -e "$recovery_case_dir"
        ;;
    *)
        echo "Invalid GOM_RECOVERY_TASK_SELECTED value: $GOM_RECOVERY_TASK_SELECTED" >&2
        exit 1
        ;;
esac
gom_recovery_validate_complete_case \
    "$GOM_RECOVERY_CASE_DIR" "$GOM_RECOVERY_CASE_KEY"

export JUTULDARCY_COMBINED_REPO="$recovery_sim_repo"
export GOM_PRODUCTION_MANIFEST="$GOM_RECOVERY_CAMPAIGN_MANIFEST"
export GOM_PRODUCTION_FULL_JOB_ID="$GOM_RECOVERY_SOURCE_FULL_JOB"
bash \
    "$recovery_sim_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
