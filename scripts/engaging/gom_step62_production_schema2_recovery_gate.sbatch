#!/bin/bash
#SBATCH --job-name=gom_s62_s2_recover_gate
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Audit the entire affected shard coverage before any recovery task writes.

set -euo pipefail
umask 027

source \
    "$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_common.sh"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_dir="$gom_root/results/gom_step62_schema2_recovery_gate_job${SLURM_JOB_ID}"
test ! -e "$result_dir"
mkdir -p "$result_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_RECOVERY_SOURCE_CHECK_JOB}"
campaign_check_verifier="$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_verify_campaign_check.sh"
bash "$campaign_check_verifier" \
    "$check_root" "$GOM_RECOVERY_CAMPAIGN_MANIFEST" \
    "$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    sandpc_effective_globalplateau_v1

declare -A source_jobs_checked=()
require_source_job_settled() {
    local job_id="$1"
    test -n "$job_id"
    if test -n "${source_jobs_checked[$job_id]+present}"; then
        return 0
    fi
    if test -n "$(squeue -h -j "$job_id" -o '%i' 2>/dev/null || true)"; then
        echo "Source job $job_id is still active; recovery must wait for the" \
            "original DAG to settle." >&2
        return 1
    fi
    source_jobs_checked["$job_id"]=true
}

printf 'task\tcase_key\tselected\tstate\tsource_full_job\trows\tqoi_rows\tlatest_restart\n' \
    > "$result_dir/task_audit.tsv"
complete_count=0
selected_partial_count=0
selected_fresh_count=0
selected_complete_count=0

while IFS= read -r task; do
    gom_recovery_resolve_plan_task "$task"
    gom_recovery_set_case_paths \
        "$task" "$GOM_RECOVERY_CASE_KEY" \
        "$GOM_RECOVERY_SOURCE_PREFLIGHT_JOB" \
        "$GOM_RECOVERY_SOURCE_FULL_JOB"
    require_source_job_settled "$GOM_RECOVERY_SOURCE_PREFLIGHT_JOB"
    require_source_job_settled "$GOM_RECOVERY_SOURCE_FULL_JOB"
    require_source_job_settled "$GOM_RECOVERY_SOURCE_VTU_JOB"
    require_source_job_settled "$GOM_RECOVERY_SOURCE_ARCHIVE_JOB"
    require_source_job_settled "$GOM_RECOVERY_SOURCE_FINALIZE_JOB"
    test ! -e "$GOM_RECOVERY_ARCHIVE_PATH" || {
        echo "Affected shard is already durable and may not be recovered:" \
            "$GOM_RECOVERY_ARCHIVE_PATH" >&2
        exit 1
    }
    gom_recovery_validate_preflight "$GOM_RECOVERY_PREFLIGHT_CASE"

    state=complete
    rows=0
    qoi_rows=0
    latest_restart=none
    if test -f "$GOM_RECOVERY_CASE_DIR/PASS"; then
        gom_recovery_validate_complete_case \
            "$GOM_RECOVERY_CASE_DIR" "$GOM_RECOVERY_CASE_KEY"
        if test "$GOM_RECOVERY_TASK_SELECTED" = true; then
            state=selected_complete
            selected_complete_count=$((selected_complete_count + 1))
        else
            complete_count=$((complete_count + 1))
        fi
        rows=210
        qoi_rows=210
        latest_restart=210
    else
        test "$GOM_RECOVERY_TASK_SELECTED" = true || {
            echo "Unselected task $task is incomplete; every incomplete task" \
                "in an affected shard must be explicitly selected." >&2
            exit 1
        }
        if test -d "$GOM_RECOVERY_CASE_DIR"; then
            exec {case_lock_fd}>"$GOM_RECOVERY_CASE_DIR/.production-output.lock"
            flock -n "$case_lock_fd" || {
                echo "Another writer owns $GOM_RECOVERY_CASE_DIR." >&2
                exit 1
            }
            metadata_present=false
            if test -s "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"; then
                metadata_present=true
                grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
                    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
                grep -Fxq "case_key=$GOM_RECOVERY_CASE_KEY" \
                    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
                grep -Fxq \
                    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
                    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
                grep -Fxq \
                    "jutuldarcy_commit=$GOM_RECOVERY_SIMULATION_COMMIT" \
                    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
                grep -Fxq 'production_qoi_mode=required' \
                    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
                test -s \
                    "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
                cmp -s "$GOM_RECOVERY_CAMPAIGN_MANIFEST" \
                    "$GOM_RECOVERY_CASE_DIR/campaign.toml"
            fi
            if test -e "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"; then
                cmp -s \
                    "$GOM_RECOVERY_PREFLIGHT_CASE/preflight_summary.txt" \
                    "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
            fi
            if test -e "$GOM_RECOVERY_CASE_DIR/campaign.toml"; then
                cmp -s "$GOM_RECOVERY_CAMPAIGN_MANIFEST" \
                    "$GOM_RECOVERY_CASE_DIR/campaign.toml"
            fi
            rows="$(gom_recovery_contiguous_prefix \
                "$GOM_RECOVERY_SUMMARY_DIR/rows")"
            qoi_rows="$(gom_recovery_contiguous_prefix \
                "$GOM_RECOVERY_SUMMARY_DIR/qoi/rows")"
            latest_restart="$(
                gom_recovery_restart_indices "$GOM_RECOVERY_RESTART_DIR" |
                    tail -1
            )"
            latest_restart="${latest_restart:-none}"
            if test "$metadata_present" != true && \
               { test "$rows" -ne 0 || test "$qoi_rows" -ne 0 || \
                 test "$latest_restart" != none; }; then
                echo "Task $task has scientific outputs but no RUN_METADATA.txt;" \
                    "its provenance cannot be recovered safely." >&2
                exit 1
            fi
            flock -u "$case_lock_fd"
            exec {case_lock_fd}>&-
        fi
        if test "$rows" -eq 0 && test "$qoi_rows" -eq 0 && \
           test "$latest_restart" = none; then
            state=selected_fresh
            selected_fresh_count=$((selected_fresh_count + 1))
        else
            test "$rows" -le 210
            test "$qoi_rows" -le 210
            state=selected_partial
            selected_partial_count=$((selected_partial_count + 1))
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$task" "$GOM_RECOVERY_CASE_KEY" \
        "$GOM_RECOVERY_TASK_SELECTED" "$state" \
        "$GOM_RECOVERY_SOURCE_FULL_JOB" "$rows" "$qoi_rows" \
        "$latest_restart" >> "$result_dir/task_audit.tsv"
done < <(
    "$recovery_python" "$recovery_plan_tool" tasks \
        --plan "$GOM_RECOVERY_PLAN" --scope coverage
)

test "$(( $(wc -l < "$result_dir/task_audit.tsv") - 1 ))" -eq \
    "$GOM_RECOVERY_COVERAGE_CASE_COUNT"
test "$((selected_partial_count + selected_fresh_count + selected_complete_count))" \
    -eq "$GOM_RECOVERY_SELECTED_CASE_COUNT"
printf '%s\n' \
    'status=pass' \
    "recovery_id=$GOM_RECOVERY_ID" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    "source_submission_id=$GOM_RECOVERY_SOURCE_SUBMISSION_ID" \
    "selected_case_count=$GOM_RECOVERY_SELECTED_CASE_COUNT" \
    "coverage_case_count=$GOM_RECOVERY_COVERAGE_CASE_COUNT" \
    "complete_unselected_count=$complete_count" \
    "selected_complete_count=$selected_complete_count" \
    "selected_partial_count=$selected_partial_count" \
    "selected_fresh_count=$selected_fresh_count" \
    'all_source_jobs_settled=true' \
    'all_unselected_coverage_cases_complete=true' \
    'no_affected_shard_already_promoted=true' \
    "validated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/gate_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
