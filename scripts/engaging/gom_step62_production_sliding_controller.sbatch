#!/bin/bash
#SBATCH --job-name=gom_s62_slide_ctl
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Advance one independent shard lane.  The step script atomically claims the
# next unsubmitted shard and schedules this controller again only after that
# shard has been validated and archived.

set -euo pipefail

: "${GOM_PRODUCTION_SLIDING_WORKFLOW_REPO:?Missing workflow checkout.}"
step="$GOM_PRODUCTION_SLIDING_WORKFLOW_REPO/scripts/engaging/gom_step62_production_sliding_step.sh"
test -f "$step"

bash "$step"
