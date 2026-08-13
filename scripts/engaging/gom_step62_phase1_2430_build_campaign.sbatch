#!/bin/bash
# Build the immutable schema-3 campaign manifest after all input gates pass.
# This job creates control-plane metadata only; it never runs a simulation.
#SBATCH --job-name=gom_p1_build_campaign
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${JUTULDARCY_COMBINED_REPO:?Set the immutable JutulDarcy checkout.}"
: "${GOM_PRODUCTION_JUTULDARCY_COMMIT:?Set the exact JutulDarcy commit.}"
: "${GOM_PRODUCTION_JUTUL_MANIFEST_SHA256:?Set the pinned Manifest.toml SHA-256.}"
: "${GOM_MRST_INPUT_DIR:?Set the completed coordinate-audited MAT package.}"
: "${GOM_MRST_PREPARE_COMMIT:?Set the exact MRST preparation commit.}"
: "${GOM_SOURCE_INPUT_MANIFEST_SHA256:?Set the source-manifest SHA-256.}"
: "${GOM_CONTRACT_TEST_DIR:?Set the completed durable contract-test package.}"
: "${GOM_PRODUCTION_CAMPAIGN_ID:?Set the immutable campaign ID.}"

[[ "$GOM_PRODUCTION_JUTULDARCY_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$GOM_MRST_PREPARE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$GOM_SOURCE_INPUT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$GOM_PRODUCTION_CAMPAIGN_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]

archive_root="${GOM_PRODUCTION_ARCHIVE_ROOT:-/orcd/data/juanes/001/shaowen/gom_full_production}"
archive_root="$(realpath -m "$archive_root")"
input_dir="$(realpath "$GOM_MRST_INPUT_DIR")"
contract_dir="$(realpath "$GOM_CONTRACT_TEST_DIR")"
case "$input_dir" in "$archive_root"/inputs/*) ;; *) exit 2 ;; esac
case "$contract_dir" in "$archive_root"/tests/*) ;; *) exit 2 ;; esac

test -f "$input_dir/PASS"
test ! -e "$input_dir/INCOMPLETE"
test -f "$input_dir/derived_split_input_manifest.csv"
test -f "$input_dir/DERIVED_SHA256SUMS.txt"
test -f "$input_dir/PACKAGE_METADATA.txt"
(
    cd "$input_dir"
    sha256sum --check DERIVED_SHA256SUMS.txt
)
grep -Fxq "mrst_prepare_commit=$GOM_MRST_PREPARE_COMMIT" \
    "$input_dir/PACKAGE_METADATA.txt"
grep -Fxq "source_manifest_sha256=$GOM_SOURCE_INPUT_MANIFEST_SHA256" \
    "$input_dir/PACKAGE_METADATA.txt"
grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
    "$input_dir/PACKAGE_METADATA.txt"
grep -Fxq 'case_count=2430' "$input_dir/PACKAGE_METADATA.txt"
grep -Fxq 'mat_file_count=2431' "$input_dir/PACKAGE_METADATA.txt"
grep -Fxq 'transmissibility_exported=false' \
    "$input_dir/PACKAGE_METADATA.txt"

test -f "$contract_dir/PASS"
test ! -e "$contract_dir/INCOMPLETE"
(
    cd "$contract_dir"
    sha256sum --check TEST_SHA256SUMS.txt
)
grep -Fxq 'status=pass' "$contract_dir/TEST_METADATA.txt"
grep -Fxq "jutul_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "$contract_dir/TEST_METADATA.txt"
grep -Fxq \
    "julia_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    "$contract_dir/TEST_METADATA.txt"

observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
observed_manifest_sha256="$(sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}')"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
test "$observed_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain --untracked-files=no)"

python_exe="${GOM_PRODUCTION_PYTHON:-python3.12}"
builder="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_build_manifest.py"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
command -v "$python_exe" >/dev/null
test -f "$builder"
test -f "$resolver"

result_dir="$archive_root/campaign_manifests/$GOM_PRODUCTION_CAMPAIGN_ID"
incoming="$archive_root/.incoming/campaign_manifest_${GOM_PRODUCTION_CAMPAIGN_ID}_job${SLURM_JOB_ID}"
test ! -e "$result_dir" || {
    echo "Refusing to replace campaign manifest package: $result_dir" >&2
    exit 2
}
test ! -e "$incoming" || {
    echo "Refusing to replace incoming campaign package: $incoming" >&2
    exit 2
}
mkdir -p "$incoming"
printf 'job_id=%s\nstarted_utc=%s\n' \
    "$SLURM_JOB_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$incoming/INCOMPLETE"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$incoming/exit_status.txt"
}
trap record_exit_status EXIT

manifest="$incoming/campaign.toml"
"$python_exe" "$builder" \
    --derived-manifest "$input_dir/derived_split_input_manifest.csv" \
    --campaign-id "$GOM_PRODUCTION_CAMPAIGN_ID" \
    --archive-root "$archive_root" \
    --jutuldarcy-commit "$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    --jutul-manifest-sha256 "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    --mrst-prepare-commit "$GOM_MRST_PREPARE_COMMIT" \
    --source-input-manifest-sha256 "$GOM_SOURCE_INPUT_MANIFEST_SHA256" \
    --output "$manifest" \
    --schema-version 3 \
    --ensemble-kind phase1_2430 \
    --qoi-mode required \
    --physics-profile sandpc_effective_globalplateau_v1 \
    --archive-shard-size 50

"$python_exe" "$resolver" --manifest "$manifest" validate \
    > "$incoming/validation.txt"
"$python_exe" "$resolver" --manifest "$manifest" \
    summary --format json > "$incoming/manifest_summary.json"

manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
derived_manifest_sha256="$(sha256sum "$input_dir/derived_split_input_manifest.csv" | awk '{print $1}')"
input_metadata_sha256="$(sha256sum "$input_dir/PACKAGE_METADATA.txt" | awk '{print $1}')"
contract_metadata_sha256="$(sha256sum "$contract_dir/TEST_METADATA.txt" | awk '{print $1}')"
printf '%s\n' \
    "schema=gom_phase1_2430_campaign_manifest_package_v1" \
    "status=pass" \
    "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "job_id=$SLURM_JOB_ID" \
    "node=$SLURMD_NODENAME" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$manifest_sha256" \
    "case_count=2430" \
    "qoi_schema_version=4" \
    "qoi_mode=required" \
    "retained_states=initial,25,50,100,1000_years" \
    "rolling_restart_checkpoints=2" \
    "archive_shard_size=50" \
    "mrst_input_dir=$input_dir" \
    "derived_manifest_sha256=$derived_manifest_sha256" \
    "input_package_metadata_sha256=$input_metadata_sha256" \
    "source_input_manifest_sha256=$GOM_SOURCE_INPUT_MANIFEST_SHA256" \
    "mrst_prepare_commit=$GOM_MRST_PREPARE_COMMIT" \
    "contract_test_dir=$contract_dir" \
    "contract_test_metadata_sha256=$contract_metadata_sha256" \
    "jutuldarcy_repo=$JUTULDARCY_COMBINED_REPO" \
    "jutuldarcy_commit=$observed_commit" \
    "jutul_manifest_sha256=$observed_manifest_sha256" \
    > "$incoming/CAMPAIGN_BUILD_METADATA.txt"
(
    cd "$incoming"
    sha256sum campaign.toml campaign.toml.sha256 validation.txt \
        manifest_summary.json CAMPAIGN_BUILD_METADATA.txt \
        > CAMPAIGN_PACKAGE_SHA256SUMS.txt
    sha256sum --check CAMPAIGN_PACKAGE_SHA256SUMS.txt
)
rm -- "$incoming/INCOMPLETE"
printf 'PASS\n' > "$incoming/PASS"
mkdir -p "$(dirname "$result_dir")"
mv -- "$incoming" "$result_dir"
trap - EXIT
printf 'CAMPAIGN_MANIFEST_READY=%s/campaign.toml\n' "$result_dir"
