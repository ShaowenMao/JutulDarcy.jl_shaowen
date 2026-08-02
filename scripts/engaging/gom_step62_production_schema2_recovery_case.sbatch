#!/bin/bash
#SBATCH --job-name=gom_s62_s2_recover_case
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=4-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

# Resume or finalize one explicitly selected task in its original result tree.

set -euo pipefail
umask 027

: "${GOM_RECOVERY_GATE_JOB_ID:?Set GOM_RECOVERY_GATE_JOB_ID.}"
[[ "$GOM_RECOVERY_GATE_JOB_ID" =~ ^[0-9]+$ ]]
source \
    "$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_common.sh"
gom_recovery_load_simulation_task "$SLURM_ARRAY_TASK_ID"
test "$GOM_RECOVERY_TASK_SELECTED" = true
gom_recovery_set_case_paths \
    "$GOM_RECOVERY_TASK" "$GOM_RECOVERY_CASE_KEY" \
    "$GOM_RECOVERY_SOURCE_PREFLIGHT_JOB" \
    "$GOM_RECOVERY_SOURCE_FULL_JOB"
gom_recovery_validate_preflight "$GOM_RECOVERY_PREFLIGHT_CASE"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
gate_dir="$gom_root/results/gom_step62_schema2_recovery_gate_job${GOM_RECOVERY_GATE_JOB_ID}"
test -f "$gate_dir/PASS"
grep -Fxq 'status=pass' "$gate_dir/gate_summary.txt"
grep -Fxq "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "$gate_dir/gate_summary.txt"
awk -F '\t' -v task="$GOM_RECOVERY_TASK" \
    'NR > 1 && $1 == task && $3 == "true" { found++ }
     END { exit(found == 1 ? 0 : 1) }' "$gate_dir/task_audit.tsv"

attempt_root="$gom_root/results/gom_step62_schema2_recovery_case_job${SLURM_ARRAY_JOB_ID}"
attempt_dir="$attempt_root/$GOM_RECOVERY_CASE_KEY"
test ! -e "$attempt_dir"
mkdir -p "$attempt_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$attempt_dir/exit_status.txt"
    if test -d "$GOM_RECOVERY_CASE_DIR"; then
        status_path="$GOM_RECOVERY_CASE_DIR/RECOVERY_EXIT_STATUS_${GOM_RECOVERY_ID}.txt"
        status_tmp="${status_path}.tmp.${SLURM_JOB_ID}"
        printf 'exit_code=%s\nfinished_utc=%s\n' \
            "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$status_tmp"
        mv -- "$status_tmp" "$status_path"
    fi
}
trap record_exit_status EXIT

mkdir -p "$GOM_RECOVERY_CASE_DIR"
exec 9> "$GOM_RECOVERY_CASE_DIR/.production-output.lock"
flock -n 9 || {
    echo "Another writer owns $GOM_RECOVERY_CASE_DIR." >&2
    exit 1
}

export REPO_ROOT="$recovery_sim_repo"
export CASE_LABEL="$GOM_RECOVERY_CASE_KEY"
export CASE_TAG="$GOM_RECOVERY_FULL_TAG"
export RUN_ROOT="$GOM_RECOVERY_FULL_ROOT"
export PRODUCTION_SUMMARY_DIR="$GOM_RECOVERY_SUMMARY_DIR"
export PRODUCTION_QOI_MODE=required
unset STOP_AFTER_REPORT_STEP RESTART_STEP

ensure_original_case_contract() {
    if ! test -s "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"; then
        metadata_tmp="$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt.tmp.$SLURM_JOB_ID"
        gom_effective_pc_write_metadata "$metadata_tmp" full1000y
        printf 'allocated_walltime=%s\n' \
            "$(squeue -h -j "$SLURM_JOB_ID" -o '%l' | head -n 1)" \
            >> "$metadata_tmp"
        mv -- "$metadata_tmp" "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
    fi
    if ! test -s "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"; then
        contract_tmp="$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt.tmp.$SLURM_JOB_ID"
        cp -- "$GOM_RECOVERY_PREFLIGHT_CASE/preflight_summary.txt" \
            "$contract_tmp"
        mv -- "$contract_tmp" \
            "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
    fi
    if ! test -s "$GOM_RECOVERY_CASE_DIR/campaign.toml"; then
        campaign_tmp="$GOM_RECOVERY_CASE_DIR/campaign.toml.tmp.$SLURM_JOB_ID"
        cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$campaign_tmp"
        mv -- "$campaign_tmp" "$GOM_RECOVERY_CASE_DIR/campaign.toml"
    fi
    if ! test -s \
        "$GOM_RECOVERY_CASE_DIR/campaign.toml.sha256.original"; then
        companion_tmp="$GOM_RECOVERY_CASE_DIR/campaign.toml.sha256.original.tmp.$SLURM_JOB_ID"
        cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" "$companion_tmp"
        mv -- "$companion_tmp" \
            "$GOM_RECOVERY_CASE_DIR/campaign.toml.sha256.original"
    fi
}

ensure_original_case_contract
grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
grep -Fxq "case_key=$GOM_RECOVERY_CASE_KEY" \
    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
grep -Fxq \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
grep -Fxq "jutuldarcy_commit=$GOM_RECOVERY_SIMULATION_COMMIT" \
    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
grep -Fxq 'production_qoi_mode=required' \
    "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt"
test -s "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
cmp -s "$GOM_RECOVERY_PREFLIGHT_CASE/preflight_summary.txt" \
    "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
cmp -s "$GOM_RECOVERY_CAMPAIGN_MANIFEST" \
    "$GOM_RECOVERY_CASE_DIR/campaign.toml"
cmp -s "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$GOM_RECOVERY_CASE_DIR/campaign.toml.sha256.original"

if test -f "$GOM_RECOVERY_CASE_DIR/PASS"; then
    gom_recovery_validate_complete_case \
        "$GOM_RECOVERY_CASE_DIR" "$GOM_RECOVERY_CASE_KEY"
    printf '%s\n' \
        'status=pass' \
        'operation=schema2_recovery_noop' \
        "recovery_id=$GOM_RECOVERY_ID" \
        "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
        "task=$GOM_RECOVERY_TASK" \
        "case_key=$GOM_RECOVERY_CASE_KEY" \
        'reason=source_case_already_verified' \
        > "$attempt_dir/recovery_summary.txt"
    printf 'PASS\n' > "$attempt_dir/PASS"
    exit 0
fi

row_prefix="$(gom_recovery_contiguous_prefix \
    "$GOM_RECOVERY_SUMMARY_DIR/rows")"
qoi_prefix="$(gom_recovery_contiguous_prefix \
    "$GOM_RECOVERY_SUMMARY_DIR/qoi/rows")"
test "$row_prefix" -le 210
test "$qoi_prefix" -le 210
completion_markers_valid() {
    local production_marker="$GOM_RECOVERY_SUMMARY_DIR/PRODUCTION_OUTPUT_COMPLETE.tsv"
    local qoi_marker="$GOM_RECOVERY_SUMMARY_DIR/QOI_OUTPUT_COMPLETE.tsv"
    local name
    for name in \
        report_steps.tsv qoi_region_manifest.tsv qoi_interface_manifest.tsv \
        leakage_global_steps.tsv regional_co2_inventory_steps.tsv \
        interface_flux_steps.tsv leakage_case_summary.tsv
    do
        test -s "$GOM_RECOVERY_SUMMARY_DIR/$name" || return 1
    done
    test -s "$production_marker" && test -s "$qoi_marker" &&
        test "$(gom_recovery_named_tsv_value "$production_marker" status)" = complete &&
        test "$(gom_recovery_named_tsv_value "$production_marker" case_key)" = \
            "$GOM_RECOVERY_CASE_KEY" &&
        test "$(gom_recovery_named_tsv_value "$production_marker" campaign_manifest_sha256)" = \
            "$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" &&
        test "$(gom_recovery_named_tsv_value "$production_marker" schedule_steps)" -eq 210 &&
        test "$(gom_recovery_named_tsv_value "$qoi_marker" status)" = complete &&
        test "$(gom_recovery_named_tsv_value "$qoi_marker" case_key)" = \
            "$GOM_RECOVERY_CASE_KEY" &&
        test "$(gom_recovery_named_tsv_value "$qoi_marker" schedule_steps)" -eq 210
}
production_complete=false
if test "$row_prefix" -eq 210 && test "$qoi_prefix" -eq 210 && \
   completion_markers_valid; then
    production_complete=true
fi

candidate=none
candidate_sha256=not_applicable
recovery_action=finalize_only
quarantine_dir="$GOM_RECOVERY_SUMMARY_DIR/recovery_quarantine/$GOM_RECOVERY_ID"
quarantine_manifest="$attempt_dir/recovery_quarantine.tsv"
printf 'restart_step\tsha256\tdestination\treason\n' \
    > "$quarantine_manifest"

if test "$production_complete" != true; then
    mapfile -t restart_steps < <(
        gom_recovery_restart_indices "$GOM_RECOVERY_RESTART_DIR" |
            sort -nr
    )
    for step in "${restart_steps[@]}"; do
        test "$step" -lt 210 || continue
        test "$step" -le "$((row_prefix + 1))" || continue
        if test "$qoi_prefix" -ge "$step" || \
           { test "$step" -eq "$((qoi_prefix + 1))" && \
             test -s "$GOM_RECOVERY_SUMMARY_DIR/qoi/ready/step_$(printf '%06d' "$step").tsv"; }; then
            candidate="$step"
            break
        fi
    done

    if test "$candidate" = none; then
        test "$row_prefix" -eq 0
        test "$qoi_prefix" -eq 0
        recovery_action=fresh_restart
        export RESTART_RUN=false
    else
        recovery_action=checkpoint_resume
        candidate_sha256="$(
            sha256sum "$GOM_RECOVERY_RESTART_DIR/jutul_${candidate}.jld2" |
                awk '{print $1}'
        )"
        export RESTART_RUN=true
    fi

    mkdir -p "$quarantine_dir"
    for step in "${restart_steps[@]}"; do
        if test "$candidate" != none && test "$step" -le "$candidate"; then
            continue
        fi
        source_restart="$GOM_RECOVERY_RESTART_DIR/jutul_${step}.jld2"
        test -f "$source_restart" || continue
        destination="$quarantine_dir/jutul_${step}.jld2.ineligible"
        test ! -e "$destination"
        digest="$(sha256sum "$source_restart" | awk '{print $1}')"
        mv -- "$source_restart" "$destination"
        printf '%s\t%s\t%s\t%s\n' \
            "$step" "$digest" "$destination" \
            'not_backed_by_recoverable_scalar_and_qoi_prefix' \
            >> "$quarantine_manifest"
    done

    metadata="$GOM_RECOVERY_CASE_DIR/RECOVERY_ATTEMPT_${GOM_RECOVERY_ID}_${SLURM_JOB_ID}.txt"
    test ! -e "$metadata"
    printf '%s\n' \
        'status=started' \
        "recovery_id=$GOM_RECOVERY_ID" \
        "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
        "recovery_workflow_commit=$GOM_RECOVERY_WORKFLOW_COMMIT" \
        "simulation_commit=$GOM_RECOVERY_SIMULATION_COMMIT" \
        "source_submission_id=$GOM_RECOVERY_SOURCE_SUBMISSION_ID" \
        "source_full_job_id=$GOM_RECOVERY_SOURCE_FULL_JOB" \
        "task=$GOM_RECOVERY_TASK" \
        "case_key=$GOM_RECOVERY_CASE_KEY" \
        "action=$recovery_action" \
        "scalar_rows_before=$row_prefix" \
        "qoi_rows_before=$qoi_prefix" \
        "candidate_checkpoint=$candidate" \
        "candidate_checkpoint_sha256=$candidate_sha256" \
        'automatic_checkpoint_validation_and_fallback=true' \
        "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$metadata"

    bash "$recovery_sim_repo/scripts/engaging/gom_sampling_cases.sbatch"
fi

test "$(find "$GOM_RECOVERY_RESTART_DIR" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 4
for step in 51 78 110 210; do
    test -s "$GOM_RECOVERY_RESTART_DIR/jutul_${step}.jld2"
done
test "$(gom_recovery_contiguous_prefix \
    "$GOM_RECOVERY_SUMMARY_DIR/rows")" -eq 210
test "$(gom_recovery_contiguous_prefix \
    "$GOM_RECOVERY_SUMMARY_DIR/qoi/rows")" -eq 210
for name in \
    report_steps.tsv PRODUCTION_OUTPUT_COMPLETE.tsv \
    qoi_region_manifest.tsv qoi_interface_manifest.tsv \
    leakage_global_steps.tsv regional_co2_inventory_steps.tsv \
    interface_flux_steps.tsv leakage_case_summary.tsv \
    QOI_OUTPUT_COMPLETE.tsv
do
    test -s "$GOM_RECOVERY_SUMMARY_DIR/$name"
done

final_check="$recovery_sim_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_final_check.jl"
diagnostics_script="$recovery_sim_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl"
module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1
final_summary_tmp="$attempt_dir/final_state_summary.txt"
diagnostics_tmp="$attempt_dir/runtime_diagnostics.txt"
cp -- "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt" \
    "$attempt_dir/RUN_METADATA.txt"
cmp -s "$GOM_RECOVERY_CASE_DIR/RUN_METADATA.txt" \
    "$attempt_dir/RUN_METADATA.txt"
cd "$recovery_sim_repo"
julia --startup-file=no --project=. "$final_check" \
    "$GOM_RECOVERY_RESTART_DIR" "$GOM_RECOVERY_SUMMARY_DIR" \
    "$final_summary_tmp" "$GOM_RECOVERY_CASE_KEY" \
    "$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256"
julia --startup-file=no --project=. "$diagnostics_script" \
    "$GOM_RECOVERY_SUMMARY_DIR" "$diagnostics_tmp" 210 \
    "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt"
grep -Fxq 'status=pass' "$final_summary_tmp"
grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
    "$final_summary_tmp"
grep -Fxq 'production_qoi_mode=required' "$final_summary_tmp"
grep -Fxq 'qoi_global_rows=210' "$final_summary_tmp"
grep -Fxq 'qoi_region_rows=14490' "$final_summary_tmp"
grep -Fxq 'qoi_interface_rows=40530' "$final_summary_tmp"
grep -Fxq 'status=pass' "$diagnostics_tmp"

cp -- "$final_summary_tmp" "$GOM_RECOVERY_CASE_DIR/final_state_summary.txt.tmp.$SLURM_JOB_ID"
mv -- "$GOM_RECOVERY_CASE_DIR/final_state_summary.txt.tmp.$SLURM_JOB_ID" \
    "$GOM_RECOVERY_CASE_DIR/final_state_summary.txt"
cp -- "$diagnostics_tmp" "$GOM_RECOVERY_CASE_DIR/runtime_diagnostics.txt.tmp.$SLURM_JOB_ID"
mv -- "$GOM_RECOVERY_CASE_DIR/runtime_diagnostics.txt.tmp.$SLURM_JOB_ID" \
    "$GOM_RECOVERY_CASE_DIR/runtime_diagnostics.txt"

(
    cd "$GOM_RECOVERY_CASE_DIR"
    sha256sum restart/jutul_51.jld2 restart/jutul_78.jld2 \
        restart/jutul_110.jld2 restart/jutul_210.jld2 \
        > RETAINED_RESTART_SHA256.txt.tmp.$SLURM_JOB_ID
    mv -- RETAINED_RESTART_SHA256.txt.tmp.$SLURM_JOB_ID \
        RETAINED_RESTART_SHA256.txt
    sha256sum \
        restart/production_output/report_steps.tsv \
        restart/production_output/PRODUCTION_OUTPUT_COMPLETE.tsv \
        restart/production_output/qoi_region_manifest.tsv \
        restart/production_output/qoi_interface_manifest.tsv \
        restart/production_output/leakage_global_steps.tsv \
        restart/production_output/regional_co2_inventory_steps.tsv \
        restart/production_output/interface_flux_steps.tsv \
        restart/production_output/leakage_case_summary.tsv \
        restart/production_output/QOI_OUTPUT_COMPLETE.tsv \
        PREFLIGHT_PC_TABLE_CONTRACT.txt runtime_diagnostics.txt \
        > PRODUCTION_SUMMARY_SHA256.txt.tmp.$SLURM_JOB_ID
    mv -- PRODUCTION_SUMMARY_SHA256.txt.tmp.$SLURM_JOB_ID \
        PRODUCTION_SUMMARY_SHA256.txt
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)
{
    printf 'file\tbytes\n'
    find "$GOM_RECOVERY_RESTART_DIR" -maxdepth 1 -type f \
        -name 'jutul_*.jld2' -printf '%f\t%s\n' | sort -V
} > "$GOM_RECOVERY_CASE_DIR/RESTART_MANIFEST.tsv.tmp.$SLURM_JOB_ID"
mv -- "$GOM_RECOVERY_CASE_DIR/RESTART_MANIFEST.tsv.tmp.$SLURM_JOB_ID" \
    "$GOM_RECOVERY_CASE_DIR/RESTART_MANIFEST.tsv"

recovery_metadata_tmp="$GOM_RECOVERY_CASE_DIR/RECOVERY_FINALIZATION_METADATA.txt.tmp.$SLURM_JOB_ID"
printf '%s\n' \
    'status=pass' \
    "recovery_id=$GOM_RECOVERY_ID" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "recovery_workflow_commit=$GOM_RECOVERY_WORKFLOW_COMMIT" \
    "simulation_commit=$GOM_RECOVERY_SIMULATION_COMMIT" \
    "source_submission_id=$GOM_RECOVERY_SOURCE_SUBMISSION_ID" \
    "source_full_job_id=$GOM_RECOVERY_SOURCE_FULL_JOB" \
    "recovery_job_id=$SLURM_JOB_ID" \
    "task=$GOM_RECOVERY_TASK" \
    "case_key=$GOM_RECOVERY_CASE_KEY" \
    "action=$recovery_action" \
    "scalar_rows_before=$row_prefix" \
    "qoi_rows_before=$qoi_prefix" \
    "candidate_checkpoint=$candidate" \
    "candidate_checkpoint_sha256=$candidate_sha256" \
    'automatic_checkpoint_validation_and_fallback=true' \
    'steps_completed=210' \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$recovery_metadata_tmp"
mv -- "$recovery_metadata_tmp" \
    "$GOM_RECOVERY_CASE_DIR/RECOVERY_FINALIZATION_METADATA.txt"

production_summary_tmp="$GOM_RECOVERY_CASE_DIR/production_summary.txt.tmp.$SLURM_JOB_ID"
printf '%s\n' \
    'status=pass' \
    'physics_profile=sandpc_effective_globalplateau_v1' \
    "case_key=$GOM_RECOVERY_CASE_KEY" \
    "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" \
    "realization_id=$GOM_PRODUCTION_REALIZATION_ID" \
    "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
    'grid=step62' \
    'resolution_slices=87' \
    'cells=2165082' \
    'steps_completed=210' \
    'summary_rows=210' \
    'qoi_global_rows=210' \
    'qoi_region_rows=14490' \
    'qoi_interface_rows=40530' \
    'retained_restart_steps=51,78,110,210' \
    'schedule_end_years=1000' \
    'hysteresis_active=true' \
    'fault_pc_entry_treatment=plateau_all_active' \
    'pc_entry_scope=all_active_drainage' \
    'pc_entry_rule=first_strictly_positive_pc_node' \
    'pc_mapping_schema=gom_effective_saturation_pc_v1' \
    'pc_mapping_method=entry_renormalized_analytic_brooks_corey' \
    'pc_reference=sand_theta30' \
    'host_pc_scaling=leverett_kv' \
    'nonpredict_pc_scaling=leverett_local_kzz' \
    'younger_nonpredict_local_perm_md=50,500,500' \
    'transmissibility_source=JutulDarcy_grid_and_rock' \
    'production_output_mode=true' \
    'production_qoi_mode=required' \
    'old_restart_reuse=false' \
    'restart_recovery=true' \
    "recovery_action=$recovery_action" \
    "recovery_control_commit=$GOM_RECOVERY_WORKFLOW_COMMIT" \
    "recovery_plan_sha256=$GOM_RECOVERY_PLAN_SHA256" \
    "result_dir=$GOM_RECOVERY_CASE_DIR" \
    > "$production_summary_tmp"
grep -E \
    '^(pc_(input|output)_drainage_sha256|pc_kr_sha256|pc_tail_sha256|base_imbibition_sha256|pc_kr_unchanged|pc_at_and_above_entry_unchanged|base_imbibition_unchanged)=' \
    "$GOM_RECOVERY_CASE_DIR/PREFLIGHT_PC_TABLE_CONTRACT.txt" \
    >> "$production_summary_tmp"
grep -v '^status=' "$GOM_RECOVERY_CASE_DIR/runtime_diagnostics.txt" \
    >> "$production_summary_tmp"
mv -- "$production_summary_tmp" \
    "$GOM_RECOVERY_CASE_DIR/production_summary.txt"

printf 'PASS\n' > "$GOM_RECOVERY_CASE_DIR/PASS.tmp.$SLURM_JOB_ID"
mv -- "$GOM_RECOVERY_CASE_DIR/PASS.tmp.$SLURM_JOB_ID" \
    "$GOM_RECOVERY_CASE_DIR/PASS"
gom_recovery_validate_complete_case \
    "$GOM_RECOVERY_CASE_DIR" "$GOM_RECOVERY_CASE_KEY"
cp -- "$GOM_RECOVERY_CASE_DIR/RECOVERY_FINALIZATION_METADATA.txt" \
    "$attempt_dir/recovery_summary.txt"
printf 'PASS\n' > "$attempt_dir/PASS"
