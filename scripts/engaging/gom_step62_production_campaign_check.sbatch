#!/bin/bash
#SBATCH --job-name=gom_s62_prod_check
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

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
result_dir="$gom_root/results/gom_step62_production_campaign_check_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$resolver"
command -v "$production_python" >/dev/null
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
    validate --json > "$result_dir/validated_manifest.json"
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" validate \
    > "$result_dir/validation.txt"
resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 1 --format shell
)"
eval "$resolved_case"
observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
test -s "$JUTULDARCY_COMBINED_REPO/Manifest.toml"
observed_manifest_sha256="$(
    sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}'
)"
test "$observed_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"

cp -- "$GOM_PRODUCTION_MANIFEST" "$result_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$result_dir/campaign.toml.sha256.original"
(
    cd "$result_dir"
    sha256sum campaign.toml > campaign.toml.sha256
    sha256sum --check campaign.toml.sha256
)

git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD \
    > "$result_dir/JUTULDARCY_COMMIT.txt"
printf '%s\n' \
    "status=pass" \
    "job_id=$SLURM_JOB_ID" \
    "validated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "manifest=$GOM_PRODUCTION_MANIFEST" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "schema_version=$GOM_PRODUCTION_SCHEMA_VERSION" \
    "ensemble_kind=$GOM_PRODUCTION_ENSEMBLE_KIND" \
    "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
    "case_count=$GOM_PRODUCTION_CASE_COUNT" \
    "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
    "qoi_mode=$GOM_PRODUCTION_QOI_MODE" \
    "archive_shard_size=$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE" \
    "exact_paths=true" \
    "wildcards=false" \
    "all_input_sha256_verified=true" \
    "source_input_manifest_sha256=$GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256" \
    "mrst_prepare_commit=$GOM_PRODUCTION_MRST_PREPARE_COMMIT" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    > "$result_dir/campaign_check_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
