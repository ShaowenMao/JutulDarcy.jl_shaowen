#!/bin/bash
# Submit the reusable 50-case canary with an embedded 24-case acceptance gate.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_CANARY_SELECTION_DIR:?Set GOM_CANARY_SELECTION_DIR.}"
: "${GOM_CANARY_WORKFLOW_REPO:?Set GOM_CANARY_WORKFLOW_REPO.}"
: "${JUTULDARCY_COMBINED_REPO:?Set immutable JUTULDARCY_COMBINED_REPO.}"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
selection24="$GOM_CANARY_SELECTION_DIR/embedded24_selection.tsv"
selection26="$GOM_CANARY_SELECTION_DIR/additional26_selection.tsv"
selection50="$GOM_CANARY_SELECTION_DIR/canary50_selection.tsv"
taskset_selection="$GOM_CANARY_SELECTION_DIR/tasksets/taskset_0001.tsv"
array24="$(tr -d '[:space:]' < "$GOM_CANARY_SELECTION_DIR/embedded24_array_spec.txt")"
array26="$(tr -d '[:space:]' < "$GOM_CANARY_SELECTION_DIR/additional26_array_spec.txt")"

test -f "$GOM_CANARY_SELECTION_DIR/PASS"
test -n "$array24"
test -n "$array26"
for path in "$selection24" "$selection26" "$selection50" "$taskset_selection"; do
    test -s "$path"
done
(
    cd "$GOM_CANARY_SELECTION_DIR"
    sha256sum --check SHA256SUMS.txt
)

summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = phase1_2430
test "$GOM_PRODUCTION_CASE_COUNT" -eq 2430
test "$GOM_PRODUCTION_PHYSICS_PROFILE" = sandpc_effective_globalplateau_v1
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$GOM_CANARY_SELECTION_DIR/SELECTION_METADATA.txt"

observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
test -z "$(git -C "$JUTULDARCY_COMBINED_REPO" status --porcelain)"
workflow_commit="$(git -C "$GOM_CANARY_WORKFLOW_REPO" rev-parse HEAD)"
test -z "$(git -C "$GOM_CANARY_WORKFLOW_REPO" status --porcelain)"

canary_id="${GOM_CANARY_ID:-${GOM_PRODUCTION_CAMPAIGN_ID}_reusable_canary50_v1}"
[[ "$canary_id" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]
production_lane_count="${GOM_PRODUCTION_LANE_COUNT:-2}"
[[ "$production_lane_count" =~ ^[0-9]+$ ]]
test "$production_lane_count" -ge 2
test "$production_lane_count" -le 48
submission_parent="$GOM_PRODUCTION_ARCHIVE_ROOT/canary_submissions"
submission_dir="$submission_parent/$canary_id"
receipt="$submission_dir/submission_receipt.txt"
test ! -e "$submission_dir" || {
    echo "Canary submission already exists: $submission_dir" >&2
    exit 1
}
mkdir -p "$submission_parent" "$gom_root/logs" "$gom_root/submissions"
lock_file="$submission_parent/.${canary_id}.submit.lock"
exec 9>"$lock_file"
flock -n 9 || {
    echo "Another canary submission is active for $canary_id." >&2
    exit 1
}
mkdir "$submission_dir"
cp -- "$selection24" "$selection26" "$selection50" \
    "$taskset_selection" "$GOM_CANARY_SELECTION_DIR/SELECTION_METADATA.txt" \
    "$submission_dir/"

# Verify task counts, disjoint gates, and campaign identities without repeating
# the campaign-wide MAT checksum scan already performed by `summary`.
"$production_python" - \
    "$GOM_PRODUCTION_MANIFEST" "$selection24" "$selection26" "$selection50" \
    "$array24" "$array26" <<'PY'
import csv
import sys
import tomllib

manifest_path, path24, path26, path50, array24, array26 = sys.argv[1:]
with open(manifest_path, "rb") as handle:
    campaign = tomllib.load(handle)

def read(path):
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))

rows24, rows26, rows50 = read(path24), read(path26), read(path50)
if (len(rows24), len(rows26), len(rows50)) != (24, 26, 50):
    raise SystemExit("canary gate row counts are not 24, 26, and 50")
tasks24 = [int(row["task"]) for row in rows24]
tasks26 = [int(row["task"]) for row in rows26]
tasks50 = [int(row["task"]) for row in rows50]
if set(tasks24) & set(tasks26) or tasks50 != tasks24 + tasks26:
    raise SystemExit("canary gates overlap or do not concatenate to the 50 cases")
if len(set(tasks50)) != 50:
    raise SystemExit("canary selection contains duplicate tasks")
if sorted(tasks24) != [int(value) for value in array24.split(",")]:
    raise SystemExit("embedded-24 array specification mismatch")
if sorted(tasks26) != [int(value) for value in array26.split(",")]:
    raise SystemExit("additional-26 array specification mismatch")
for row in rows50:
    task = int(row["task"])
    case = campaign["cases"][task - 1]
    expected = {
        "case_key": str(case["case_key"]),
        "geology_id": str(case["geology_id"]),
        "realization_id": str(case["realization_id"]),
        "case_name": str(case["level3_case_name"]),
    }
    if {key: row[key] for key in expected} != expected:
        raise SystemExit(f"campaign identity mismatch for selected task {task}")
print("Reusable canary identities validated against the audited campaign.")
PY

submitted_jobs=()
submission_complete=false
cancel_partial_dag() {
    exit_code=$?
    if test "$submission_complete" != true && test "${#submitted_jobs[@]}" -gt 0; then
        echo "Canary submission failed; cancelling partial DAG: ${submitted_jobs[*]}" >&2
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

write_source_map() {
    output="$1"
    first_selection="$2"
    first_preflight="$3"
    first_full="$4"
    first_vtu="$5"
    second_selection="${6:-}"
    second_preflight="${7:-}"
    second_full="${8:-}"
    second_vtu="${9:-}"
    "$production_python" - \
        "$gom_root" "$output" \
        "$first_selection" "$first_preflight" "$first_full" "$first_vtu" \
        "$second_selection" "$second_preflight" "$second_full" "$second_vtu" <<'PY'
import csv
import pathlib
import sys

root, output, *values = sys.argv[1:]
root = pathlib.Path(root)
groups = [values[:4], values[4:8]]
rows = []
for selection, preflight, full, vtu in groups:
    if not selection:
        continue
    with open(selection, newline="", encoding="utf-8") as handle:
        selected = list(csv.DictReader(handle, delimiter="\t"))
    for row in selected:
        rows.append({
            "task": row["task"],
            "preflight_root": str(root / "results" / f"gom_step62_effective_pc_global_plateau_preflight_job{preflight}"),
            "full_root": str(root / "results" / f"gom_step62_effective_pc_global_plateau_full_job{full}"),
            "vtu_root": str(root / "results" / f"gom_step62_effective_pc_global_plateau_vtu_job{vtu}"),
            "preflight_job": preflight,
            "full_job": full,
            "vtu_job": vtu,
        })
fields = ["task", "preflight_root", "full_root", "vtu_root", "preflight_job", "full_job", "vtu_job"]
with open(output, "x", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
PY
}

common_export="ALL,GOM_GRID_ROOT=$gom_root,JUTULDARCY_COMBINED_REPO=$JUTULDARCY_COMBINED_REPO,GOM_PRODUCTION_MANIFEST=$GOM_PRODUCTION_MANIFEST"
submit_job --kill-on-invalid-dep=yes --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_campaign_check.sbatch"
check_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes --dependency="afterok:$check_job" \
    --array="$array24%24" --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_preflight.sbatch"
preflight24_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$preflight24_job" \
    --array="$array24%24" --time=4-00:00:00 \
    --export="$common_export,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight24_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_full.sbatch"
full24_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$full24_job" \
    --array="$array24%24" \
    --export="$common_export,GOM_PRODUCTION_FULL_JOB_ID=$full24_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
vtu24_job="$submitted_job_id"

source24="$submission_dir/source_map_embedded24.tsv"
write_source_map "$source24" "$selection24" "$preflight24_job" "$full24_job" "$vtu24_job"
audit24="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance/${canary_id}_embedded24"
roles24="central_medoid|barrier_stress|conduit_stress|heterogeneous_independent"
audit24_export="$common_export,GOM_CANARY_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_CANARY_AUDIT_SELECTION=$selection24,GOM_CANARY_AUDIT_SOURCE_MAP=$source24,GOM_CANARY_AUDIT_OUTPUT=$audit24,GOM_CANARY_AUDIT_EXPECTED_COUNT=24,GOM_CANARY_AUDIT_REQUIRED_ROLES=$roles24,GOM_CANARY_SUBMISSION_RECEIPT=$receipt"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu24_job" \
    --export="$audit24_export" \
    "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_phase1_2430_canary_audit.sbatch"
audit24_job="$submitted_job_id"

submit_job --kill-on-invalid-dep=yes --dependency="afterok:$audit24_job" \
    --array="$array26%26" --export="$common_export" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_preflight.sbatch"
preflight26_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$preflight26_job" \
    --array="$array26%26" --time=4-00:00:00 \
    --export="$common_export,GOM_PRODUCTION_PREFLIGHT_JOB_ID=$preflight26_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_full.sbatch"
full26_job="$submitted_job_id"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$full26_job" \
    --array="$array26%26" \
    --export="$common_export,GOM_PRODUCTION_FULL_JOB_ID=$full26_job" \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
vtu26_job="$submitted_job_id"

source50="$submission_dir/source_map_canary50.tsv"
write_source_map \
    "$source50" \
    "$selection24" "$preflight24_job" "$full24_job" "$vtu24_job" \
    "$selection26" "$preflight26_job" "$full26_job" "$vtu26_job"
audit50="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance/${canary_id}_full50"
roles50="$roles24|stratified_low_state|stratified_high_state|stratified_independent|stratified_independent_extra"
audit50_export="$common_export,GOM_CANARY_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_CANARY_AUDIT_SELECTION=$selection50,GOM_CANARY_AUDIT_SOURCE_MAP=$source50,GOM_CANARY_AUDIT_OUTPUT=$audit50,GOM_CANARY_AUDIT_EXPECTED_COUNT=50,GOM_CANARY_AUDIT_REQUIRED_ROLES=$roles50,GOM_CANARY_AUDIT_PRODUCTION_REUSABLE=true,GOM_CANARY_SUBMISSION_RECEIPT=$receipt"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$vtu26_job" \
    --export="$audit50_export" \
    "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_phase1_2430_canary_audit.sbatch"
audit50_job="$submitted_job_id"

taskset_id=taskset_0001
archive_export="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_TASKSET_ID=$taskset_id,GOM_PRODUCTION_TASKSET_SELECTION=$taskset_selection,GOM_PRODUCTION_SOURCE_MAP=$source50,GOM_PRODUCTION_SUBMISSION_ID=$canary_id,GOM_PRODUCTION_TASKSET_AUDIT_DIR=$audit50"
submit_job --kill-on-invalid-dep=yes --dependency="afterok:$audit50_job" \
    --export="$archive_export" \
    "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_archive.sbatch"
archive50_job="$submitted_job_id"

controller_jobs=()
if test "${GOM_CANARY_AUTO_CONTINUE_PRODUCTION:-true}" = true; then
    controller_common="$common_export,GOM_TASKSET_WORKFLOW_REPO=$GOM_CANARY_WORKFLOW_REPO,GOM_PRODUCTION_CHECK_JOB_ID=$check_job,GOM_PRODUCTION_TASKSET_PLAN=$GOM_CANARY_SELECTION_DIR/taskset_plan.tsv,GOM_PRODUCTION_TASKSET_SELECTION_DIR=$GOM_CANARY_SELECTION_DIR/tasksets,GOM_PRODUCTION_CANARY_TASKSET=$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID/tasksets/taskset_0001,GOM_PRODUCTION_PARENT_SUBMISSION_ID=$canary_id,GOM_PRODUCTION_TASKSET_STRIDE=$production_lane_count,GOM_PRODUCTION_LANE_COUNT=$production_lane_count"
    for ((lane_index = 1; lane_index <= production_lane_count; lane_index++)); do
        lane_start_index=$((lane_index + 1))
        controller_export="$controller_common,GOM_PRODUCTION_LANE_INDEX=$lane_index,GOM_PRODUCTION_LANE_START_INDEX=$lane_start_index,GOM_PRODUCTION_NEXT_TASKSET_INDEX=$lane_start_index"
        submit_job --kill-on-invalid-dep=yes --dependency="afterok:$archive50_job" \
            --export="$controller_export" \
            "$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_taskset_controller.sbatch"
        controller_jobs+=("$submitted_job_id")
    done
fi
controller_jobs_csv=none
if test "${#controller_jobs[@]}" -gt 0; then
    controller_jobs_csv="$(IFS=,; echo "${controller_jobs[*]}")"
fi

printf '%s\n' \
    "status=submitted" \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "canary_id=$canary_id" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest=$GOM_PRODUCTION_MANIFEST" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "selection_dir=$GOM_CANARY_SELECTION_DIR" \
    "selection_count=50" \
    "embedded_acceptance_count=24" \
    "additional_stratified_count=26" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "workflow_commit=$workflow_commit" \
    "campaign_check_job=$check_job" \
    "embedded24_preflight_job=$preflight24_job" \
    "embedded24_full_job=$full24_job" \
    "embedded24_vtu_job=$vtu24_job" \
    "embedded24_audit_job=$audit24_job" \
    "additional26_preflight_job=$preflight26_job" \
    "additional26_full_job=$full26_job" \
    "additional26_vtu_job=$vtu26_job" \
    "full50_audit_job=$audit50_job" \
    "full50_archive_job=$archive50_job" \
    "production_lane_count=$production_lane_count" \
    "remaining_production_controller_jobs=$controller_jobs_csv" \
    "canary_results_count_as_production=true" \
    "remaining_production_starts_only_after_full50_pass=true" \
    > "$receipt"
cp -- "$receipt" "$gom_root/submissions/${canary_id}.txt"
(
    cd "$submission_dir"
    sha256sum ./*.tsv ./*.txt > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
submission_complete=true
trap - EXIT
cat "$receipt"
