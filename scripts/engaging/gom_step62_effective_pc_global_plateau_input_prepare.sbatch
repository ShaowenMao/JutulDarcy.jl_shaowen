#!/bin/bash
#SBATCH --job-name=gom_s62_epc_prepare
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
: "${GOM_EFFECTIVE_PC_SOURCE_MANIFEST:?Set GOM_EFFECTIVE_PC_SOURCE_MANIFEST.}"
: "${GOM_EFFECTIVE_PC_DERIVED_DIR:?Set GOM_EFFECTIVE_PC_DERIVED_DIR.}"
: "${GOM_EFFECTIVE_PC_CAMPAIGN_DIR:?Set GOM_EFFECTIVE_PC_CAMPAIGN_DIR.}"
: "${GOM_EFFECTIVE_PC_CAMPAIGN_ID:?Set GOM_EFFECTIVE_PC_CAMPAIGN_ID.}"
: "${GOM_PRODUCTION_ARCHIVE_ROOT:?Set GOM_PRODUCTION_ARCHIVE_ROOT.}"

case "$GOM_EFFECTIVE_PC_CAMPAIGN_ID" in
    *sandpc*ycap50*effective*globalplateau*) ;;
    *)
        echo "Campaign ID must contain sandpc, ycap50, effective, and globalplateau." >&2
        exit 1
        ;;
esac

prepare_function="$MRST_PREP_REPO/setup_shaowen_resolution/grid_tools/prepare_step62_87slice_7case_manifest_inputs.m"
builder="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_build_manifest.py"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
physics_asset_name=faultPermSGR_Gupper87lyr_predictMesh_youngerkxx50_effective_globalplateau_v1.mat

test -f "$MRST_ROOT/startup.m"
test -f "$prepare_function"
test -f "$GOM_EFFECTIVE_PC_SOURCE_MANIFEST"
test -f "$builder"
test -f "$resolver"
test ! -e "$GOM_EFFECTIVE_PC_DERIVED_DIR"
test ! -e "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR"
archive_root="$(realpath -m "$GOM_PRODUCTION_ARCHIVE_ROOT")"
derived_dir="$(realpath -m "$GOM_EFFECTIVE_PC_DERIVED_DIR")"
campaign_dir="$(realpath -m "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR")"
for durable_path in "$derived_dir" "$campaign_dir"; do
    case "$durable_path" in
        "$archive_root"/*) ;;
        *)
            echo "Generated inputs and campaign metadata must be under" \
                "$archive_root; got $durable_path." >&2
            exit 1
            ;;
    esac
done
GOM_EFFECTIVE_PC_DERIVED_DIR="$derived_dir"
GOM_EFFECTIVE_PC_CAMPAIGN_DIR="$campaign_dir"
export GOM_EFFECTIVE_PC_DERIVED_DIR GOM_EFFECTIVE_PC_CAMPAIGN_DIR
mkdir -p \
    "$(dirname "$GOM_EFFECTIVE_PC_DERIVED_DIR")" \
    "$(dirname "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR")"

mrst_commit="$(git -C "$MRST_PREP_REPO" rev-parse HEAD)"
jutul_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test -z "$(git -C "$MRST_PREP_REPO" status --porcelain)"
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)"

module purge
module load community-modules
module load matlab/matlab-2024a

export GOM_EFFECTIVE_PC_MATLAB_DIARY="$GOM_EFFECTIVE_PC_DERIVED_DIR/matlab_diary.log"
matlab -batch \
    "repo=getenv('MRST_PREP_REPO'); addpath(fullfile(repo,'setup_shaowen_resolution','grid_tools')); prepare_step62_87slice_7case_manifest_inputs(getenv('MRST_ROOT'),getenv('GOM_EFFECTIVE_PC_SOURCE_MANIFEST'),getenv('GOM_EFFECTIVE_PC_DERIVED_DIR'),getenv('GOM_EFFECTIVE_PC_MATLAB_DIARY'),'PhysicsProfile','sandpc_effective_globalplateau_v1');"

derived_manifest="$GOM_EFFECTIVE_PC_DERIVED_DIR/derived_split_input_manifest.csv"
prepare_summary="$GOM_EFFECTIVE_PC_DERIVED_DIR/prepare_summary.json"
derived_checksums="$GOM_EFFECTIVE_PC_DERIVED_DIR/DERIVED_SHA256SUMS.txt"
physics_asset="$GOM_EFFECTIVE_PC_DERIVED_DIR/physics_assets/$physics_asset_name"
test -s "$derived_manifest"
test -s "$prepare_summary"
test -s "$derived_checksums"
test -s "$physics_asset"
grep -Fq 'sandpc_effective_globalplateau_v1' "$prepare_summary"
grep -Fq 'gom_effective_saturation_pc_v1' "$prepare_summary"
grep -Fq 'entry_renormalized_analytic_brooks_corey' "$prepare_summary"
grep -Fq "$physics_asset_name" "$derived_checksums"
(
    cd "$GOM_EFFECTIVE_PC_DERIVED_DIR"
    sha256sum --check DERIVED_SHA256SUMS.txt
)

mkdir "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR"
source_manifest_sha256="$(
    sha256sum "$GOM_EFFECTIVE_PC_SOURCE_MANIFEST" | awk '{print $1}'
)"
jutul_manifest_sha256="$(
    sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}'
)"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
"$production_python" "$builder" \
    --derived-manifest "$derived_manifest" \
    --campaign-id "$GOM_EFFECTIVE_PC_CAMPAIGN_ID" \
    --archive-root "$GOM_PRODUCTION_ARCHIVE_ROOT" \
    --jutuldarcy-commit "$jutul_commit" \
    --jutul-manifest-sha256 "$jutul_manifest_sha256" \
    --mrst-prepare-commit "$mrst_commit" \
    --source-input-manifest-sha256 "$source_manifest_sha256" \
    --output "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR/campaign.toml"
"$production_python" "$resolver" \
    --manifest "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR/campaign.toml" validate

physics_asset_sha256="$(sha256sum "$physics_asset" | awk '{print $1}')"
printf '%s\n' \
    "status=pass" \
    "input_prepare_job_id=$SLURM_JOB_ID" \
    "physics_profile=sandpc_effective_globalplateau_v1" \
    "physics_workflow=effective_pc_global_plateau_v1" \
    "pc_mapping_schema=gom_effective_saturation_pc_v1" \
    "pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "old_restart_reuse=false" \
    "physics_asset=$physics_asset" \
    "physics_asset_sha256=$physics_asset_sha256" \
    "campaign_id=$GOM_EFFECTIVE_PC_CAMPAIGN_ID" \
    "campaign_manifest=$GOM_EFFECTIVE_PC_CAMPAIGN_DIR/campaign.toml" \
    "case_tasks=5:6:7" \
    "mrst_prepare_commit=$mrst_commit" \
    "jutuldarcy_commit=$jutul_commit" \
    "jutul_manifest_sha256=$jutul_manifest_sha256" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR/PREPARE_EFFECTIVE_PC_INPUTS_COMPLETE.txt"
printf 'PASS\n' > "$GOM_EFFECTIVE_PC_CAMPAIGN_DIR/PASS"
