#!/bin/bash
# Submit the noncontiguous 24-case full-schedule acceptance DAG.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_ACCEPTANCE_SELECTION_DIR:?Set GOM_ACCEPTANCE_SELECTION_DIR.}"
: "${GOM_ACCEPTANCE_WORKFLOW_REPO:?Set GOM_ACCEPTANCE_WORKFLOW_REPO.}"
: "${JUTULDARCY_COMBINED_REPO:?Set immutable JUTULDARCY_COMBINED_REPO.}"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
selection="$GOM_ACCEPTANCE_SELECTION_DIR/acceptance_selection.tsv"
array_spec="$(tr -d '[:space:]' < "$GOM_ACCEPTANCE_SELECTION_DIR/acceptance_array_spec.txt")"
test -f "$GOM_ACCEPTANCE_SELECTION_DIR/PASS"
test -s "$selection"
test -n "$array_spec"
(
    cd "$GOM_ACCEPTANCE_SELECTION_DIR"
    sha256sum --check SHA256SUMS.txt
)

summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = phase1_2430
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430
test "$GOM_PRODUCTION_PHYSICS_PROFILE" = sandpc_effective_globalplateau_v1
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$GOM_ACCEPTANCE_SELECTION_DIR/SELECTION_METADATA.txt"

acceptance_id="${GOM_ACCEPTANCE_ID:-${GOM_PRODUCTION_CAMPAIGN_ID}_acceptance24_v1}"
[[ "$acceptance_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
mkdir -p "$gom_root/logs" "$gom_root/submissions" \
    "$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance_submissions"
receipt="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance_submissions/${acceptance_id}.txt"
test ! -e "$receipt" || {
    echo "Acceptance submission receipt already exists: $receipt" >&2
    exit 1
}
lock_file="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance_submissions/.${acceptance_id}.submit.lock"
exec 9>"$lock_file"
flock -n 9 || {
    echo "Another acceptance submission is active for $acceptance_id." >&2
    exit 1
}

observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT" || {
    echo "Immutable simulation checkout does not match the campaign commit." >&2
    exit 1
}
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)" || {
    echo "Immutable simulation checkout is not clean." >&2
    exit 1
}
workflow_commit="$(git -C "$GOM_ACCEPTANCE_WORKFLOW_REPO" rev-parse HEAD)"
test -z "$(git -C "$GOM_ACCEPTANCE_WORKFLOW_REPO" status --porcelain)" || {
    echo "Acceptance workflow checkout is not clean." >&2
    exit 1
}

# `summary` above performs the complete checksum audit once. Re-resolving each
# selected task through the resolver would repeat the 2,430-file hash scan 24
# times, so identity checks below deliberately parse the already-audited TOML.
"$production_python" - "$GOM_PRODUCTION_MANIFEST" "$selection" "$array_spec" <<'PY'
import csv
import sys
import tomllib

manifest_path, selection_path, array_spec = sys.argv[1:]
with open(manifest_path, "rb") as handle:
    campaign = tomllib.load(handle)
with open(selection_path, newline="", encoding="utf-8") as handle:
    selected = list(csv.DictReader(handle, delimiter="\t"))

if len(selected) != 24:
    raise SystemExit(f"acceptance selection has {len(selected)} rows, expected 24")
cases = campaign.get("cases", [])
selected_tasks = []
for row in selected:
    task = int(row["task"])
    if not 1 <= task <= len(cases):
        raise SystemExit(f"selected task {task} is outside the campaign")
    case = cases[task - 1]
    expected = {
        "case_key": str(case["case_key"]),
        "geology_id": str(case["geology_id"]),
        "realization_id": str(case["realization_id"]),
        "case_name": str(case["level3_case_name"]),
    }
    for field, value in expected.items():
        if row[field] != value:
            raise SystemExit(
                f"selected task {task} {field} mismatch: "
                f"selection={row[field]!r}, campaign={value!r}"
            )
    selected_tasks.append(task)

if len(set(selected_tasks)) != 24:
    raise SystemExit("acceptance selection contains duplicate tasks")
array_tasks = [int(value) for value in array_spec.split(",") if value]
if array_tasks != sorted(selected_tasks):
    raise SystemExit("acceptance array specification does not match selected tasks")
print("Acceptance identities validated against the checksum-audited campaign.")
PY

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if test "$submission_complete" != true && \
       test "${#submitted_jobs[@]}" -gt 0; then
        echo "Acceptance submission failed; cancelling partial DAG: ${submitted_jobs[*]}" >&2
        scancel "${submitted_jobs[@]}" || true
    fi
    return "$exit_code"
}
trap cancel_partial_dag EXIT

submit_job() {
    raw_id="$(sbatch --parsable "$@")"
    job_id="${raw_id%%;*}"
    [[ "$job_id" =~ ^[0-9]+$ ]]
    submitted_jobs+=("$job_id")
    submitted_job_id="$job_id"
}

common_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST"

submit_job --kill-on-invalid-dep=yes \
    --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_campaign_check.sbatch"
check_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$check_job" --array="$array_spec%24" \
    --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_preflight.sbatch"
preflight_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes \
    --dependency="aftercorr:$preflight_job" --array="$array_spec%24" \
    --time=4-00:00:00 \
    --export="$common_export,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_full.sbatch"
full_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes \
    --dependency="aftercorr:$full_job" --array="$array_spec%24" \
    --export="$common_export,GOM_PRODUCTION_FULL_JOB_ID=$full_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
vtu_job="$submitted_job_id"
finalize_export="$common_export,GOM_ACCEPTANCE_ID=$acceptance_id,GOM_ACCEPTANCE_SELECTION_DIR=$GOM_ACCEPTANCE_SELECTION_DIR,GOM_ACCEPTANCE_WORKFLOW_REPO=$GOM_ACCEPTANCE_WORKFLOW_REPO,GOM_ACCEPTANCE_CHECK_JOB_ID=$check_job,GOM_ACCEPTANCE_PREFLIGHT_JOB_ID=$preflight_job,GOM_ACCEPTANCE_FULL_JOB_ID=$full_job,GOM_ACCEPTANCE_VTU_JOB_ID=$vtu_job,GOM_ACCEPTANCE_WORKFLOW_COMMIT=$workflow_commit"
submit_job --kill-on-invalid-dep=yes \
    --dependency="afterok:$vtu_job" --export="$finalize_export" \
    "$GOM_ACCEPTANCE_WORKFLOW_REPO/scripts/engaging/gom_step62_phase1_2430_acceptance_finalize.sbatch"
finalize_job="$submitted_job_id"

printf '%s\n' \
    "status=submitted" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "acceptance_id=$acceptance_id" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest=$GOM_PRODUCTION_MANIFEST" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "selection_dir=$GOM_ACCEPTANCE_SELECTION_DIR" \
    "selection_count=24" \
    "array_spec=$array_spec" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "workflow_commit=$workflow_commit" \
    "campaign_check_job=$check_job" \
    "preflight_array_job=$preflight_job" \
    "full_array_job=$full_job" \
    "vtu_array_job=$vtu_job" \
    "finalize_job=$finalize_job" > "$receipt"
cp -- "$receipt" "$gom_root/submissions/${acceptance_id}.txt"
submission_complete=true
trap - EXIT
cat "$receipt"
