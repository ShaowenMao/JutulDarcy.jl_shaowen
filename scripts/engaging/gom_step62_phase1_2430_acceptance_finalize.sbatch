#!/bin/bash
#SBATCH --job-name=gom_s62_acc_final
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_ACCEPTANCE_ID:?Set GOM_ACCEPTANCE_ID.}"
: "${GOM_ACCEPTANCE_SELECTION_DIR:?Set GOM_ACCEPTANCE_SELECTION_DIR.}"
: "${GOM_ACCEPTANCE_CHECK_JOB_ID:?Set GOM_ACCEPTANCE_CHECK_JOB_ID.}"
: "${GOM_ACCEPTANCE_PREFLIGHT_JOB_ID:?Set GOM_ACCEPTANCE_PREFLIGHT_JOB_ID.}"
: "${GOM_ACCEPTANCE_FULL_JOB_ID:?Set GOM_ACCEPTANCE_FULL_JOB_ID.}"
: "${GOM_ACCEPTANCE_VTU_JOB_ID:?Set GOM_ACCEPTANCE_VTU_JOB_ID.}"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
summary="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 3
test "$GOM_PRODUCTION_ENSEMBLE_KIND" = phase1_2430

final="$GOM_PRODUCTION_ARCHIVE_ROOT/acceptance/$GOM_ACCEPTANCE_ID"
test ! -e "$final"
incoming="$GOM_PRODUCTION_ARCHIVE_ROOT/.incoming/${GOM_ACCEPTANCE_ID}_finalizejob${SLURM_JOB_ID}"
test ! -e "$incoming"
mkdir -p "$incoming/cases" "$(dirname -- "$final")"
cp -- "$GOM_ACCEPTANCE_SELECTION_DIR/acceptance_selection.tsv" \
    "$GOM_ACCEPTANCE_SELECTION_DIR/SELECTION_METADATA.txt" \
    "$GOM_ACCEPTANCE_SELECTION_DIR/SHA256SUMS.txt" "$incoming/"

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_ACCEPTANCE_CHECK_JOB_ID}"
preflight_root="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${GOM_ACCEPTANCE_PREFLIGHT_JOB_ID}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_ACCEPTANCE_FULL_JOB_ID}"
vtu_root="$gom_root/results/gom_step62_effective_pc_global_plateau_vtu_job${GOM_ACCEPTANCE_VTU_JOB_ID}"
test -f "$check_root/PASS"

printf 'task\tcase_key\tacceptance_role\tstatus\n' > "$incoming/acceptance_status.tsv"
case_count=0
while IFS=$'\t' read -r task case_key scenario geology_id realization_id case_name acceptance_role rest; do
    test "$task" != task || continue
    resolved="$($production_python "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" resolve --task "$task" --format shell)"
    eval "$resolved"
    test "$GOM_PRODUCTION_CASE_KEY" = "$case_key"
    test "$GOM_PRODUCTION_GEOLOGY_ID" = "$geology_id"
    test "$GOM_PRODUCTION_REALIZATION_ID" = "$realization_id"

    preflight_case="$preflight_root/$case_key"
    full_tag="gom_step62_effective_pc_global_plateau_${case_key}_sandpc_effective_globalplateau_v1_full1000y_job${GOM_ACCEPTANCE_FULL_JOB_ID}_${task}"
    full_case="$full_root/$full_tag"
    vtu_case="$vtu_root/$case_key"
    test -f "$preflight_case/PASS"
    test -f "$full_case/PASS"
    test -f "$vtu_case/PASS"
    grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
    grep -Fxq 'status=pass' "$full_case/production_summary.txt"
    grep -Fxq 'steps_completed=210' "$full_case/production_summary.txt"
    grep -Fxq 'retained_restart_steps=51,78,110,210' "$full_case/production_summary.txt"
    grep -Fxq 'production_qoi_mode=required' "$full_case/production_summary.txt"
    grep -Fxq 'production_qoi_schema4_mode=required' "$full_case/production_summary.txt"
    grep -Fxq 'qoi_schema4_validated=true' "$full_case/final_state_summary.txt"
    grep -Fxq 'status=pass' "$vtu_case/export_summary.txt"
    grep -Fxq 'vtu_files=3' "$vtu_case/export_summary.txt"
    (
        cd "$full_case"
        sha256sum --check RETAINED_RESTART_SHA256.txt
        sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
    )
    (
        cd "$vtu_case"
        sha256sum --check VTU_SHA256.txt
    )

    destination="$incoming/cases/$case_key"
    mkdir -p "$destination"
    cp -- "$preflight_case/preflight_summary.txt" \
        "$full_case/production_summary.txt" \
        "$full_case/final_state_summary.txt" \
        "$full_case/runtime_diagnostics.txt" \
        "$full_case/restart/production_output/leakage_case_summary.tsv" \
        "$vtu_case/export_summary.txt" "$destination/"
    printf '%s\t%s\t%s\tpass\n' "$task" "$case_key" "$acceptance_role" \
        >> "$incoming/acceptance_status.tsv"
    case_count=$((case_count + 1))
done < "$GOM_ACCEPTANCE_SELECTION_DIR/acceptance_selection.tsv"
test "$case_count" -eq 24

sacct -X -j "$GOM_ACCEPTANCE_PREFLIGHT_JOB_ID,$GOM_ACCEPTANCE_FULL_JOB_ID,$GOM_ACCEPTANCE_VTU_JOB_ID" \
    -o JobIDRaw,JobName%32,State,ExitCode,Elapsed,MaxRSS,AllocCPUS \
    > "$incoming/slurm_accounting.txt"
printf '%s\n' \
    "status=pass" \
    "acceptance_id=$GOM_ACCEPTANCE_ID" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_count=24" \
    "full_schedule_years=1000" \
    "report_steps=210" \
    "qoi_schema_version=4" \
    "retained_restart_steps=51,78,110,210" \
    "acceptance_results_count_as_production=false" \
    "acceptance_scratch_preserved_for_manual_review=true" \
    "workflow_commit=${GOM_ACCEPTANCE_WORKFLOW_COMMIT:-unknown}" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    > "$incoming/ACCEPTANCE_SUMMARY.txt"
(
    cd "$incoming"
    find . -type f ! -name SHA256SUMS.txt ! -name PASS -print0 | \
        sort -z | xargs -0 sha256sum > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
printf 'PASS\n' > "$incoming/PASS"
mv -- "$incoming" "$final"
