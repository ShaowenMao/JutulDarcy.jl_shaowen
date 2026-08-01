#!/bin/bash
#SBATCH --job-name=gom_s62_epc_launch
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_EFFECTIVE_PC_CAMPAIGN_DIR:?Set GOM_EFFECTIVE_PC_CAMPAIGN_DIR.}"
: "${GOM_EFFECTIVE_PC_INPUT_PREPARE_JOB_ID:?Set input-prepare job ID.}"

[[ "$GOM_EFFECTIVE_PC_INPUT_PREPARE_JOB_ID" =~ ^[0-9]+$ ]] || {
    echo "Input-prepare job ID must be numeric." >&2
    exit 1
}
campaign_dir="$(realpath "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR")"
manifest="$campaign_dir/campaign.toml"
test -f "$campaign_dir/PASS"
test -s "$campaign_dir/PREPARE_EFFECTIVE_PC_INPUTS_COMPLETE.txt"
grep -Fxq 'status=pass' \
    "$campaign_dir/PREPARE_EFFECTIVE_PC_INPUTS_COMPLETE.txt"
grep -Fxq \
    "input_prepare_job_id=$GOM_EFFECTIVE_PC_INPUT_PREPARE_JOB_ID" \
    "$campaign_dir/PREPARE_EFFECTIVE_PC_INPUTS_COMPLETE.txt"
grep -Fxq 'case_tasks=5:6:7' \
    "$campaign_dir/PREPARE_EFFECTIVE_PC_INPUTS_COMPLETE.txt"
test -s "$manifest"
test -s "$manifest.sha256"

export GOM_PRODUCTION_MANIFEST="$manifest"
launcher_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}/submissions"
mkdir -p "$launcher_root"
launcher_receipt="$launcher_root/gom_step62_effective_pc_global_plateau_launcher_job${SLURM_JOB_ID}.txt"

{
    printf '%s\n' \
        "launcher_job_id=$SLURM_JOB_ID" \
        "input_prepare_job_id=$GOM_EFFECTIVE_PC_INPUT_PREPARE_JOB_ID" \
        "campaign_manifest=$manifest" \
        "launch_started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bash \
        "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_submit.sh"
    printf '%s\n' \
        "status=pass" \
        "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$launcher_receipt"

cat "$launcher_receipt"
