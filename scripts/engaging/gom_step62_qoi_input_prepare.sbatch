#!/bin/bash
#SBATCH --job-name=gom_s62_qoi_prepare
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=48G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${MRST_ROOT:?Set MRST_ROOT.}"
: "${MRST_PREP_REPO:?Set MRST_PREP_REPO.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_QOI_SOURCE_MANIFEST:?Set GOM_QOI_SOURCE_MANIFEST.}"
: "${GOM_QOI_DERIVED_DIR:?Set GOM_QOI_DERIVED_DIR.}"
: "${GOM_QOI_CAMPAIGN_DIR:?Set GOM_QOI_CAMPAIGN_DIR.}"
: "${GOM_QOI_CAMPAIGN_ID:?Set GOM_QOI_CAMPAIGN_ID.}"
: "${GOM_PRODUCTION_ARCHIVE_ROOT:?Set GOM_PRODUCTION_ARCHIVE_ROOT.}"

test -f "$MRST_ROOT/startup.m"
test -f \
    "$MRST_PREP_REPO/setup_shaowen_resolution/grid_tools/prepare_step62_87slice_7case_manifest_inputs.m"
test -f "$GOM_QOI_SOURCE_MANIFEST"
test -f \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_build_manifest.py"
test -f \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
test ! -e "$GOM_QOI_DERIVED_DIR"
test ! -e "$GOM_QOI_CAMPAIGN_DIR"

mkdir -p \
    "$(dirname "$GOM_QOI_DERIVED_DIR")" \
    "$(dirname "$GOM_QOI_CAMPAIGN_DIR")"

mrst_commit="$(git -C "$MRST_PREP_REPO" rev-parse HEAD)"
jutul_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test -z "$(git -C "$MRST_PREP_REPO" status --porcelain)"
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)"

module purge
module load community-modules
module load matlab/matlab-2024a

export GOM_QOI_MATLAB_DIARY="$GOM_QOI_DERIVED_DIR/matlab_diary.log"
matlab -batch \
    "repo=getenv('MRST_PREP_REPO'); addpath(fullfile(repo,'setup_shaowen_resolution','grid_tools')); prepare_step62_87slice_7case_manifest_inputs(getenv('MRST_ROOT'),getenv('GOM_QOI_SOURCE_MANIFEST'),getenv('GOM_QOI_DERIVED_DIR'),getenv('GOM_QOI_MATLAB_DIARY'));"

derived_manifest="$GOM_QOI_DERIVED_DIR/derived_split_input_manifest.csv"
test -s "$derived_manifest"
test -s "$GOM_QOI_DERIVED_DIR/prepare_summary.json"
test -s "$GOM_QOI_DERIVED_DIR/DERIVED_SHA256SUMS.txt"

mkdir "$GOM_QOI_CAMPAIGN_DIR"
source_manifest_sha256="$(
    sha256sum "$GOM_QOI_SOURCE_MANIFEST" | awk '{print $1}'
)"
jutul_manifest_sha256="$(
    sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}'
)"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
"$production_python" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_build_manifest.py" \
    --derived-manifest "$derived_manifest" \
    --campaign-id "$GOM_QOI_CAMPAIGN_ID" \
    --archive-root "$GOM_PRODUCTION_ARCHIVE_ROOT" \
    --jutuldarcy-commit "$jutul_commit" \
    --jutul-manifest-sha256 "$jutul_manifest_sha256" \
    --mrst-prepare-commit "$mrst_commit" \
    --source-input-manifest-sha256 "$source_manifest_sha256" \
    --output "$GOM_QOI_CAMPAIGN_DIR/campaign.toml"

"$production_python" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py" \
    --manifest "$GOM_QOI_CAMPAIGN_DIR/campaign.toml" validate

printf '%s\n' \
    "status=pass" \
    "campaign_id=$GOM_QOI_CAMPAIGN_ID" \
    "campaign_manifest=$GOM_QOI_CAMPAIGN_DIR/campaign.toml" \
    "mrst_prepare_commit=$mrst_commit" \
    "jutuldarcy_commit=$jutul_commit" \
    "jutul_manifest_sha256=$jutul_manifest_sha256" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$GOM_QOI_CAMPAIGN_DIR/PREPARE_QOI_INPUTS_COMPLETE.txt"
printf 'PASS\n' > "$GOM_QOI_CAMPAIGN_DIR/PASS"
