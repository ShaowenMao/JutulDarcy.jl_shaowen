#!/bin/bash
#SBATCH --job-name=gom_s62_spc_check
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_sandpc_ycap50_common.sh"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
result_dir="$gom_root/results/gom_step62_sandpc_ycap50_campaign_check_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

command -v "$production_python" >/dev/null
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
    validate --json > "$result_dir/validated_manifest.json"
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" validate \
    > "$result_dir/validation.txt"
resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 5 --format shell
)"
eval "$resolved_case"
gom_sandpc_validate_campaign
test "$GOM_PRODUCTION_CASE_COUNT" -eq 7
test "$GOM_PRODUCTION_CASE_KEY" = s03_c001_case04
observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
observed_manifest_sha256="$(
    sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}'
)"
test "$observed_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"

# Fail before any expensive simulation if an Engaging Julia script uses an
# API unsupported by the pinned cluster runtime.
module purge
module load community-modules
module load julia/1.10.4
julia --version > "$result_dir/julia_version.txt"
grep -Fxq 'julia version 1.10.4' "$result_dir/julia_version.txt"
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. test/engaging_script_compat.jl \
    > "$result_dir/engaging_script_compatibility_test.txt"

cp -- "$GOM_PRODUCTION_MANIFEST" "$result_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$result_dir/campaign.toml.sha256.original"
(
    cd "$result_dir"
    sha256sum campaign.toml > campaign.toml.sha256
    sha256sum --check campaign.toml.sha256
)
printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "manifest_case_count=7" \
    "selected_case_count=3" \
    "case_tasks=5:6:7" \
    "exact_paths=true" \
    "wildcards=false" \
    "all_input_sha256_verified=true" \
    "cluster_julia_version=1.10.4" \
    "engaging_script_compatibility_test=pass" \
    "old_restart_reuse=false" \
    "source_input_manifest_sha256=$GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256" \
    "mrst_prepare_commit=$GOM_PRODUCTION_MRST_PREPARE_COMMIT" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    > "$result_dir/campaign_check_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
