#!/bin/bash
#SBATCH --job-name=gom_s62_prod_archive
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_PRODUCTION_CHECK_JOB_ID:?Set GOM_PRODUCTION_CHECK_JOB_ID.}"
: "${GOM_PRODUCTION_PREFLIGHT_JOB_ID:?Set GOM_PRODUCTION_PREFLIGHT_JOB_ID.}"
: "${GOM_PRODUCTION_SMOKE_JOB_ID:?Set GOM_PRODUCTION_SMOKE_JOB_ID.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set GOM_PRODUCTION_FULL_JOB_ID.}"
: "${GOM_PRODUCTION_VTU_JOB_ID:?Set GOM_PRODUCTION_VTU_JOB_ID.}"
for job_id in \
    "$GOM_PRODUCTION_CHECK_JOB_ID" \
    "$GOM_PRODUCTION_PREFLIGHT_JOB_ID" \
    "$GOM_PRODUCTION_SMOKE_JOB_ID" \
    "$GOM_PRODUCTION_FULL_JOB_ID" \
    "$GOM_PRODUCTION_VTU_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]] ||
        { echo "Production job IDs must be numeric." >&2; exit 1; }
done

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
result_dir="$gom_root/results/gom_step62_production_archive_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

command -v "$production_python" >/dev/null
task_list="${GOM_PRODUCTION_TASKS:-1:2:3:4:5:6:7}"
IFS=':' read -r -a archive_tasks <<< "$task_list"
test "${#archive_tasks[@]}" -gt 0
declare -A observed_tasks=()
for task in "${archive_tasks[@]}"; do
    [[ "$task" =~ ^[1-7]$ ]] ||
        { echo "GOM_PRODUCTION_TASKS contains invalid task '$task'." >&2; exit 1; }
    test -z "${observed_tasks[$task]:-}" ||
        { echo "GOM_PRODUCTION_TASKS contains duplicate task '$task'." >&2; exit 1; }
    observed_tasks[$task]=1
done
case_count="${#archive_tasks[@]}"

resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 1 --format shell
)"
eval "$resolved_case"
archive_root="$GOM_PRODUCTION_ARCHIVE_ROOT"
campaign_id="$GOM_PRODUCTION_CAMPAIGN_ID"
manifest_sha256="$GOM_PRODUCTION_MANIFEST_SHA256"
incoming_parent="$archive_root/.incoming"
campaign_parent="$archive_root/campaigns"
incoming="$incoming_parent/${campaign_id}_fulljob${GOM_PRODUCTION_FULL_JOB_ID}_archivejob${SLURM_JOB_ID}"
final="$campaign_parent/${campaign_id}_fulljob${GOM_PRODUCTION_FULL_JOB_ID}"

mkdir -p "$incoming_parent" "$campaign_parent"
test ! -e "$incoming"
test ! -e "$final"
mkdir -p \
    "$incoming/payload/stages" \
    "$incoming/payload/cases" \
    "$incoming/payload/slurm_logs"

copy_log_if_present() {
    path="$1"
    if [ -f "$path" ]; then
        cp -- "$path" "$incoming/payload/slurm_logs/"
    fi
}

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_PRODUCTION_CHECK_JOB_ID}"
preflight_root="$gom_root/results/gom_step62_production_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}"
smoke_root="$gom_root/results/gom_step62_production_smoke_job${GOM_PRODUCTION_SMOKE_JOB_ID}"
full_root="$gom_root/results/gom_step62_production_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
vtu_root="$gom_root/results/gom_step62_production_vtu_job${GOM_PRODUCTION_VTU_JOB_ID}"

test -f "$check_root/PASS"
test -s "$check_root/campaign_check_summary.txt"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
cp -a -- "$check_root" "$incoming/payload/stages/campaign_check"
copy_log_if_present \
    "$gom_root/logs/gom_s62_prod_check-${GOM_PRODUCTION_CHECK_JOB_ID}.out"
copy_log_if_present \
    "$gom_root/logs/gom_s62_prod_check-${GOM_PRODUCTION_CHECK_JOB_ID}.err"

for task in "${archive_tasks[@]}"; do
    resolved_case="$(
        "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell
    )"
    eval "$resolved_case"
    case_key="$GOM_PRODUCTION_CASE_KEY"
    full_tag="gom_step62_production_${case_key}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_PRODUCTION_FULL_JOB_ID}_${task}"
    preflight_case="$preflight_root/$case_key"
    smoke_tag="gom_step62_production_${case_key}_hyst_faultpcplateau_npctheta30_smoke3_job${GOM_PRODUCTION_SMOKE_JOB_ID}_${task}"
    smoke_case="$smoke_root/$smoke_tag"
    full_case="$full_root/$full_tag"
    vtu_case="$vtu_root/$case_key"

    test -f "$preflight_case/PASS"
    test -f "$smoke_case/PASS"
    test -f "$full_case/PASS"
    test -f "$vtu_case/PASS"
    grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
    grep -Fxq 'status=pass' "$smoke_case/smoke_summary.txt"
    grep -Fxq 'status=pass' "$full_case/production_summary.txt"
    grep -Fxq 'status=pass' "$vtu_case/export_summary.txt"
    grep -Fxq 'retained_restart_steps=78,210' \
        "$full_case/production_summary.txt"
    (
        cd "$full_case"
        sha256sum --check RETAINED_RESTART_SHA256.txt
        sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
    )
    (
        cd "$vtu_case"
        sha256sum --check VTU_SHA256.txt
    )

    mkdir -p "$incoming/payload/cases/$case_key"
    cp -a -- "$preflight_case" \
        "$incoming/payload/cases/$case_key/preflight"
    archived_smoke="$incoming/payload/cases/$case_key/smoke"
    mkdir -p "$archived_smoke/restart"
    cp -- \
        "$smoke_case/RUN_METADATA.txt" \
        "$smoke_case/smoke_summary.txt" \
        "$smoke_case/exit_status.txt" \
        "$smoke_case/PASS" \
        "$smoke_case/campaign.toml" \
        "$smoke_case/campaign.toml.sha256.original" \
        "$archived_smoke/"
    cp -a -- "$smoke_case/restart/production_output" \
        "$archived_smoke/restart/production_output"
    if [ -d "$smoke_case/logs" ]; then
        cp -a -- "$smoke_case/logs" "$archived_smoke/logs"
    fi
    cp -a -- "$full_case" \
        "$incoming/payload/cases/$case_key/production"
    cp -a -- "$vtu_case" \
        "$incoming/payload/cases/$case_key/vtu"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_pf-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_pf-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_smoke-${GOM_PRODUCTION_SMOKE_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_smoke-${GOM_PRODUCTION_SMOKE_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_full-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_full-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_vtu-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_prod_vtu-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.err"
done

cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$incoming/campaign.toml.sha256.original"
cp -- "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_README.md" \
    "$incoming/WORKFLOW_README.md"
git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD \
    > "$incoming/JUTULDARCY_COMMIT.txt"
printf '%s\n' \
    "status=ready_for_promotion" \
    "campaign_id=$campaign_id" \
    "campaign_manifest_sha256=$manifest_sha256" \
    "source_input_manifest_sha256=$GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256" \
    "mrst_prepare_commit=$GOM_PRODUCTION_MRST_PREPARE_COMMIT" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    "case_count=$case_count" \
    "case_tasks=$task_list" \
    "smoke_restart_binaries_archived=false" \
    "check_job_id=$GOM_PRODUCTION_CHECK_JOB_ID" \
    "preflight_job_id=$GOM_PRODUCTION_PREFLIGHT_JOB_ID" \
    "smoke_job_id=$GOM_PRODUCTION_SMOKE_JOB_ID" \
    "full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "vtu_job_id=$GOM_PRODUCTION_VTU_JOB_ID" \
    "archive_job_id=$SLURM_JOB_ID" \
    "archive_started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$incoming/ARCHIVE_METADATA.txt"

(
    cd "$incoming"
    find . -type f ! -name SHA256SUMS -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum > SHA256SUMS
    test -s SHA256SUMS
    sha256sum --check SHA256SUMS
)
mv -- "$incoming" "$final"

printf '%s\n' \
    "status=pass" \
    "campaign_id=$campaign_id" \
    "campaign_manifest_sha256=$manifest_sha256" \
    "case_count=$case_count" \
    "case_tasks=$task_list" \
    "archive_path=$final" \
    "atomic_staging_parent=$incoming_parent" \
    "all_staged_archive_sha256_verified_before_atomic_promote=true" \
    "scratch_removed=false" \
    "promoted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/archive_summary.txt"
printf '%s\n' \
    "archive_path=$final" \
    "campaign_manifest_sha256=$manifest_sha256" \
    > "$result_dir/ARCHIVE_POINTER.txt"
printf 'PASS\n' > "$result_dir/PASS"
