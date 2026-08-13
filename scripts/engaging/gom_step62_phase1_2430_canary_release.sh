#!/bin/bash
# Release the official reusable 50-case canary after acceptance review.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set immutable JUTULDARCY_COMBINED_REPO.}"
: "${GOM_ACCEPTANCE_ARCHIVE:?Set the completed 24-case acceptance archive.}"

test "${GOM_ACCEPTANCE_MANUAL_REVIEW:-}" = YES || {
    echo "Set GOM_ACCEPTANCE_MANUAL_REVIEW=YES only after reviewing the 24-case acceptance evidence." >&2
    exit 1
}
test -f "$GOM_ACCEPTANCE_ARCHIVE/PASS"
test -f "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
test -f "$GOM_ACCEPTANCE_ARCHIVE/acceptance_status.tsv"
(
    cd "$GOM_ACCEPTANCE_ARCHIVE"
    sha256sum --check SHA256SUMS.txt
)
grep -Fxq 'status=pass' "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
grep -Fxq 'case_count=24' "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
grep -Fxq 'full_schedule_years=1000' "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
grep -Fxq 'qoi_schema_version=4' "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
grep -Fxq 'acceptance_results_count_as_production=false' \
    "$GOM_ACCEPTANCE_ARCHIVE/ACCEPTANCE_SUMMARY.txt"
test "$(($(wc -l < "$GOM_ACCEPTANCE_ARCHIVE/acceptance_status.tsv") - 1))" -eq 24
test "$(awk -F '\t' 'NR > 1 && $4 == "pass" {count++} END {print count + 0}' \
    "$GOM_ACCEPTANCE_ARCHIVE/acceptance_status.tsv")" -eq 24

submission_id="${GOM_CANARY_SUBMISSION_ID:-step62_phase1_2430_official_canary_0001_0050_v1}"
[[ "$submission_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
test ! -e "$gom_root/submissions/${submission_id}.txt" || {
    echo "Canary submission receipt already exists for $submission_id." >&2
    exit 1
}

export GOM_PRODUCTION_SELECTION_START=1
export GOM_PRODUCTION_SELECTION_END=50
export GOM_PRODUCTION_MAX_CONCURRENT="${GOM_CANARY_MAX_CONCURRENT:-50}"
export GOM_PRODUCTION_SHARD_WINDOW=1
export GOM_PRODUCTION_SUBMISSION_ID="$submission_id"
export GOM_GRID_ROOT="$gom_root"

exec bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_ensemble_submit.sh"
