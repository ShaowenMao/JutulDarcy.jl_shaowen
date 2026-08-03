#!/bin/bash
#SBATCH --job-name=gom_s62_roll_ctl
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Submit one bounded production wave, reconcile the completed campaign, or
# certify the rolling chain.  Each controller is dependency-gated by the
# previous wave finalizer, so only one scheduler-safe wave is submitted at a
# time.

set -euo pipefail

: "${GOM_PRODUCTION_ROLLING_WORKFLOW_REPO:?Missing workflow checkout.}"
step="$GOM_PRODUCTION_ROLLING_WORKFLOW_REPO/scripts/engaging/gom_step62_production_rolling_step.sh"
test -f "$step"

bash "$step"
