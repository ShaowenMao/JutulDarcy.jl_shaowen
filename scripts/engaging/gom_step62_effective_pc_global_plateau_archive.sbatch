#!/bin/bash
#SBATCH --job-name=gom_s62_epc_archive
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
: "${GOM_PRODUCTION_CHECK_JOB_ID:?Set check job ID.}"
: "${GOM_PRODUCTION_PREFLIGHT_JOB_ID:?Set preflight job ID.}"
: "${GOM_PRODUCTION_SMOKE_JOB_ID:?Set smoke job ID.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set full job ID.}"
: "${GOM_PRODUCTION_VTU_JOB_ID:?Set VTU job ID.}"
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

source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
result_dir="$gom_root/results/gom_step62_effective_pc_global_plateau_archive_job${SLURM_JOB_ID}"
test ! -e "$result_dir"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

resolved_case="$(
    "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
        resolve --task 5 --format shell
)"
eval "$resolved_case"
gom_effective_pc_validate_campaign
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

check_root="$gom_root/results/gom_step62_effective_pc_global_plateau_campaign_check_job${GOM_PRODUCTION_CHECK_JOB_ID}"
preflight_root="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}"
smoke_root="$gom_root/results/gom_step62_effective_pc_global_plateau_smoke_job${GOM_PRODUCTION_SMOKE_JOB_ID}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
vtu_root="$gom_root/results/gom_step62_effective_pc_global_plateau_vtu_job${GOM_PRODUCTION_VTU_JOB_ID}"

test -f "$check_root/PASS"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
grep -Fxq 'case_tasks=5:6:7' "$check_root/campaign_check_summary.txt"
cp -a -- "$check_root" "$incoming/payload/stages/campaign_check"

copy_log_if_present() {
    path="$1"
    [ ! -f "$path" ] || cp -- "$path" "$incoming/payload/slurm_logs/"
}

for task in 5 6 7; do
    resolved_case="$(
        "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell
    )"
    eval "$resolved_case"
    case_key="$GOM_PRODUCTION_CASE_KEY"
    full_tag="$(
        SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        SLURM_ARRAY_TASK_ID="$task" \
            gom_effective_pc_case_tag full1000y
    )"
    smoke_tag="$(
        SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_SMOKE_JOB_ID" \
        SLURM_ARRAY_TASK_ID="$task" \
            gom_effective_pc_case_tag smoke3
    )"
    preflight_case="$preflight_root/$case_key"
    smoke_case="$smoke_root/$smoke_tag"
    full_case="$full_root/$full_tag"
    vtu_case="$vtu_root/$case_key"

    for path in \
        "$preflight_case/PASS" \
        "$smoke_case/PASS" \
        "$full_case/PASS" \
        "$vtu_case/PASS"
    do
        test -f "$path"
    done
    grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_entry_treatment=plateau_all_active' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_plateau_adjusted_tables=530' \
        "$preflight_case/preflight_summary.txt"
    grep -Eq '^pc_input_drainage_sha256=[0-9a-f]{64}$' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'status=pass' "$smoke_case/smoke_summary.txt"
    grep -Fxq 'pc_entry_treatment=plateau_all_active' \
        "$smoke_case/smoke_summary.txt"
    grep -Eq '^total_ministeps=[0-9]+$' "$smoke_case/smoke_summary.txt"
    grep -Fxq 'status=pass' "$full_case/production_summary.txt"
    grep -Fxq 'production_qoi_mode=required' \
        "$full_case/production_summary.txt"
    grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
        "$full_case/production_summary.txt"
    grep -Eq '^pc_output_drainage_sha256=[0-9a-f]{64}$' \
        "$full_case/production_summary.txt"
    grep -Eq '^total_ministeps=[0-9]+$' \
        "$full_case/production_summary.txt"
    grep -Fxq 'status=pass' "$vtu_case/export_summary.txt"
    grep -Fxq 'pc_entry_treatment=plateau_all_active' \
        "$vtu_case/export_summary.txt"
    (
        cd "$full_case"
        sha256sum --check RETAINED_RESTART_SHA256.txt
        sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
    )
    (
        cd "$vtu_case"
        sha256sum --check VTU_SHA256.txt
    )

    case_archive="$incoming/payload/cases/$case_key"
    mkdir -p "$case_archive"
    cp -a -- "$preflight_case" "$case_archive/preflight"
    archived_smoke="$case_archive/smoke"
    mkdir -p "$archived_smoke/restart"
    cp -- \
        "$smoke_case/RUN_METADATA.txt" \
        "$smoke_case/PREFLIGHT_PC_TABLE_CONTRACT.txt" \
        "$smoke_case/runtime_diagnostics.txt" \
        "$smoke_case/smoke_summary.txt" \
        "$smoke_case/exit_status.txt" \
        "$smoke_case/PASS" \
        "$smoke_case/campaign.toml" \
        "$smoke_case/campaign.toml.sha256.original" \
        "$archived_smoke/"
    cp -a -- "$smoke_case/restart/production_output" \
        "$archived_smoke/restart/production_output"
    [ ! -d "$smoke_case/logs" ] ||
        cp -a -- "$smoke_case/logs" "$archived_smoke/logs"
    cp -a -- "$full_case" "$case_archive/production"
    cp -a -- "$vtu_case" "$case_archive/vtu"

    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_pf-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_pf-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_smoke-${GOM_PRODUCTION_SMOKE_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_smoke-${GOM_PRODUCTION_SMOKE_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.err"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_vtu-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.out"
    copy_log_if_present \
        "$gom_root/logs/gom_s62_epc_vtu-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.err"
done

copy_log_if_present \
    "$gom_root/logs/gom_s62_epc_check-${GOM_PRODUCTION_CHECK_JOB_ID}.out"
copy_log_if_present \
    "$gom_root/logs/gom_s62_epc_check-${GOM_PRODUCTION_CHECK_JOB_ID}.err"
cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$incoming/campaign.toml.sha256.original"
cp -- \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/README_gom_step62_effective_pc_global_plateau.md" \
    "$incoming/WORKFLOW_README.md"
git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD \
    > "$incoming/JUTULDARCY_COMMIT.txt"
printf '%s\n' \
    "status=ready_for_promotion" \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "campaign_id=$campaign_id" \
    "campaign_manifest_sha256=$manifest_sha256" \
    "case_count=3" \
    "case_tasks=5:6:7" \
    "pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "production_qoi_mode=required" \
    "smoke_restart_binaries_archived=false" \
    "check_job_id=$GOM_PRODUCTION_CHECK_JOB_ID" \
    "preflight_job_id=$GOM_PRODUCTION_PREFLIGHT_JOB_ID" \
    "smoke_job_id=$GOM_PRODUCTION_SMOKE_JOB_ID" \
    "full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "vtu_job_id=$GOM_PRODUCTION_VTU_JOB_ID" \
    "archive_job_id=$SLURM_JOB_ID" \
    > "$incoming/ARCHIVE_METADATA.txt"

(
    cd "$incoming"
    find . -type f ! -name SHA256SUMS -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum > SHA256SUMS
    sha256sum --check SHA256SUMS
)
mv -- "$incoming" "$final"

printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "campaign_id=$campaign_id" \
    "campaign_manifest_sha256=$manifest_sha256" \
    "case_count=3" \
    "case_tasks=5:6:7" \
    "pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "archive_path=$final" \
    "all_staged_archive_sha256_verified_before_atomic_promote=true" \
    "scratch_removed=false" \
    > "$result_dir/archive_summary.txt"
printf 'archive_path=%s\ncampaign_manifest_sha256=%s\n' \
    "$final" "$manifest_sha256" > "$result_dir/ARCHIVE_POINTER.txt"
printf 'PASS\n' > "$result_dir/PASS"
