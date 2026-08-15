#!/bin/bash
#SBATCH --job-name=gom_s62_can50_audit
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_CANARY_WORKFLOW_REPO:?Set GOM_CANARY_WORKFLOW_REPO.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_CANARY_AUDIT_SELECTION:?Set GOM_CANARY_AUDIT_SELECTION.}"
: "${GOM_CANARY_AUDIT_SOURCE_MAP:?Set GOM_CANARY_AUDIT_SOURCE_MAP.}"
: "${GOM_CANARY_AUDIT_OUTPUT:?Set GOM_CANARY_AUDIT_OUTPUT.}"
: "${GOM_CANARY_AUDIT_EXPECTED_COUNT:?Set GOM_CANARY_AUDIT_EXPECTED_COUNT.}"
: "${GOM_CANARY_AUDIT_REQUIRED_ROLES:?Set GOM_CANARY_AUDIT_REQUIRED_ROLES.}"
: "${GOM_CANARY_SUBMISSION_RECEIPT:?Set GOM_CANARY_SUBMISSION_RECEIPT.}"

[[ "$GOM_CANARY_AUDIT_EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]]
test -s "$GOM_CANARY_AUDIT_SELECTION"
test -s "$GOM_CANARY_AUDIT_SOURCE_MAP"
test -s "$GOM_CANARY_SUBMISSION_RECEIPT"
test -f "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_canary_acceptance_audit.py"

if test -e "$GOM_CANARY_AUDIT_OUTPUT"; then
    test -f "$GOM_CANARY_AUDIT_OUTPUT/PASS"
    (cd "$GOM_CANARY_AUDIT_OUTPUT" && sha256sum --check SHA256SUMS.txt)
    echo "Verified existing canary audit: $GOM_CANARY_AUDIT_OUTPUT"
    exit 0
fi

campaign_sha256="$(sha256sum "$GOM_PRODUCTION_MANIFEST" | awk '{print $1}')"
selection_sha256="$(sha256sum "$GOM_CANARY_AUDIT_SELECTION" | awk '{print $1}')"
production_reusable=()
if test "${GOM_CANARY_AUDIT_PRODUCTION_REUSABLE:-false}" = true; then
    production_reusable+=(--production-reusable)
fi

python3.12 \
    "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_canary_acceptance_audit.py" \
    --campaign "$GOM_PRODUCTION_MANIFEST" \
    --campaign-sha256 "$campaign_sha256" \
    --selection "$GOM_CANARY_AUDIT_SELECTION" \
    --selection-sha256 "$selection_sha256" \
    --submission-receipt "$GOM_CANARY_SUBMISSION_RECEIPT" \
    --code-repo "$JUTULDARCY_COMBINED_REPO" \
    --source-map "$GOM_CANARY_AUDIT_SOURCE_MAP" \
    --expected-count "$GOM_CANARY_AUDIT_EXPECTED_COUNT" \
    --required-roles "$GOM_CANARY_AUDIT_REQUIRED_ROLES" \
    --output-dir "$GOM_CANARY_AUDIT_OUTPUT" \
    "${production_reusable[@]}"

test -f "$GOM_CANARY_AUDIT_OUTPUT/PASS"
test ! -e "$GOM_CANARY_AUDIT_OUTPUT/FAIL"
grep -Fxq 'status=pass' "$GOM_CANARY_AUDIT_OUTPUT/ACCEPTANCE_SUMMARY.txt"
grep -Fxq "case_count=$GOM_CANARY_AUDIT_EXPECTED_COUNT" \
    "$GOM_CANARY_AUDIT_OUTPUT/ACCEPTANCE_SUMMARY.txt"
(
    cd "$GOM_CANARY_AUDIT_OUTPUT"
    sha256sum --check SHA256SUMS.txt
)
