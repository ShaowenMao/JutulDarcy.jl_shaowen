#!/bin/bash
# Resume an incomplete effective-Pc/global-plateau task 5 in place.
# The original campaign repository remains the simulation/project authority.
# A newer commit-pinned repository supplies this wrapper and the corrected
# final validator only.
#SBATCH --job-name=gom_s62_epc_continue
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the original immutable campaign manifest.}"
: "${GOM_EFFECTIVE_PC_FULL_JOB_ID:?Set the original full-array job ID.}"
: "${GOM_EFFECTIVE_PC_TASK_SET:?Set the exact original task set.}"
: "${GOM_EFFECTIVE_PC_SIMULATION_REPO:?Set the original simulation repository.}"
: "${GOM_EFFECTIVE_PC_CONTINUATION_REPO:?Set the clean continuation repository.}"
: "${GOM_EFFECTIVE_PC_CONTINUATION_COMMIT:?Set the continuation commit.}"
continuation_preflight_only="$(
    printf '%s' \
        "${GOM_EFFECTIVE_PC_CONTINUATION_PREFLIGHT_ONLY:-false}" |
        tr '[:upper:]' '[:lower:]'
)"
case "$continuation_preflight_only" in
    true|false) ;;
    *)
        echo "GOM_EFFECTIVE_PC_CONTINUATION_PREFLIGHT_ONLY must be true or false." >&2
        exit 1
        ;;
esac

[[ "$GOM_EFFECTIVE_PC_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    {
        echo "GOM_EFFECTIVE_PC_FULL_JOB_ID must be numeric." >&2
        exit 1
    }
[[ "$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    {
        echo "GOM_EFFECTIVE_PC_CONTINUATION_COMMIT must be a full SHA-1." >&2
        exit 1
    }
test "$SLURM_ARRAY_TASK_ID" -eq 5

simulation_repo="$(realpath "$GOM_EFFECTIVE_PC_SIMULATION_REPO")"
continuation_repo="$(realpath "$GOM_EFFECTIVE_PC_CONTINUATION_REPO")"
test -z "$(git -C "$simulation_repo" status --porcelain)"
test -z "$(git -C "$continuation_repo" status --porcelain)"
test "$(git -C "$continuation_repo" rev-parse HEAD)" = \
    "$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT"
test -s "$simulation_repo/Manifest.toml"
test -s "$continuation_repo/Manifest.toml"
cmp -s "$simulation_repo/Project.toml" "$continuation_repo/Project.toml"
cmp -s "$simulation_repo/Manifest.toml" "$continuation_repo/Manifest.toml"
test "$(git -C "$simulation_repo" rev-parse HEAD:src)" = \
    "$(git -C "$continuation_repo" rev-parse HEAD:src)"

export JUTULDARCY_COMBINED_REPO="$simulation_repo"
source \
    "$simulation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics
test "$GOM_PRODUCTION_TASK" -eq 5
test "$GOM_PRODUCTION_CASE_KEY" = s03_c001_case04
test "$PRODUCTION_QOI_MODE" = required

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_EFFECTIVE_PC_FULL_JOB_ID}"
case_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        gom_effective_pc_case_tag full1000y
)"
case_dir="$full_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
row_dir="$summary_dir/rows"
qoi_row_dir="$summary_dir/qoi/rows"
pc_contract="$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"
attempt_root="$gom_root/results/gom_step62_effective_pc_global_plateau_continuation_job${SLURM_ARRAY_JOB_ID}"
attempt_dir="$attempt_root/$GOM_PRODUCTION_CASE_KEY"
stage_dir="$attempt_dir/staged"

test ! -e "$attempt_dir" || {
    echo "Refusing to reuse a continuation attempt: $attempt_dir" >&2
    exit 1
}
mkdir -p "$stage_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$attempt_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -d "$case_dir"
test -s "$case_dir/RUN_METADATA.txt"
test -s "$case_dir/exit_status.txt"
test -s "$pc_contract"
grep -Fxq \
    'physics_profile=sandpc_effective_globalplateau_v1' \
    "$case_dir/RUN_METADATA.txt"
grep -Fxq 'case_key=s03_c001_case04' "$case_dir/RUN_METADATA.txt"
grep -Fxq 'grid=step62' "$case_dir/RUN_METADATA.txt"
grep -Fxq 'resolution_slices=87' "$case_dir/RUN_METADATA.txt"
grep -Fxq 'cells=2165082' "$case_dir/RUN_METADATA.txt"
grep -Fxq 'production_qoi_mode=required' "$case_dir/RUN_METADATA.txt"
grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
    "$case_dir/RUN_METADATA.txt"
grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$case_dir/RUN_METADATA.txt"
grep -Fxq "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "$case_dir/RUN_METADATA.txt"
grep -Fxq 'pc_entry_treatment=plateau_all_active' "$pc_contract"
grep -Fxq 'pc_plateau_active_tables=530' "$pc_contract"
grep -Fxq 'pc_plateau_adjusted_tables=530' "$pc_contract"
grep -Fxq 'pc_plateau_true_zero_tables=0' "$pc_contract"

exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "Another writer already owns $case_dir." >&2
    exit 1
}

if test -f "$case_dir/PASS"; then
    grep -Fxq 'PASS' "$case_dir/PASS"
    grep -Fxq 'status=pass' "$case_dir/production_summary.txt"
    grep -Fxq 'steps_completed=210' "$case_dir/production_summary.txt"
    grep -Fxq 'production_qoi_mode=required' \
        "$case_dir/production_summary.txt"
    printf '%s\n' \
        'status=pass' \
        'operation=effective_pc_continuation_noop' \
        "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "source_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        'reason=source_case_already_verified' \
        > "$attempt_dir/continuation_summary.txt"
    printf 'PASS\n' > "$attempt_dir/PASS"
    exit 0
fi

count_rows() {
    directory="$1"
    find "$directory" -maxdepth 1 -type f -name 'step_*.tsv' |
        wc -l
}

assert_contiguous_rows() {
    directory="$1"
    expected_count="$2"
    step=1
    while test "$step" -le "$expected_count"; do
        test -s "$directory/step_$(printf '%06d' "$step").tsv"
        step="$((step + 1))"
    done
}

rows_before="$(count_rows "$row_dir")"
qoi_rows_before="$(count_rows "$qoi_row_dir")"
test "$rows_before" -eq "$qoi_rows_before"
test "$rows_before" -ge 1
test "$rows_before" -le 210
assert_contiguous_rows "$row_dir" "$rows_before"
assert_contiguous_rows "$qoi_row_dir" "$qoi_rows_before"

finish_preflight_only() {
    printf '%s\n' \
        'status=pass' \
        'operation=effective_pc_checkpoint_continuation_preflight' \
        "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
        "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "source_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        "source_case=$case_dir" \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "continuation_commit=$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" \
        "rows_before_resume=$rows_before" \
        "qoi_rows_before_resume=$qoi_rows_before" \
        "resumed_after_step=$resumed_after" \
        "restart_step=$restart_step" \
        "checkpoint_sha256=$checkpoint_sha256" \
        'production_qoi_mode=required' \
        'source_case_modified=false' \
        > "$attempt_dir/continuation_summary.txt"
    printf 'PASS\n' > "$attempt_dir/PASS"
}

resumed_after=already_complete
checkpoint_sha256=not_applicable
restart_step=not_applicable
simulation_was_resumed=false
simulation_complete_marker="$case_dir/CONTINUATION_SIMULATION_COMPLETE.txt"

if test "$rows_before" -eq 210 && test -s "$simulation_complete_marker"; then
    grep -Fxq 'status=complete' "$simulation_complete_marker"
    grep -Fxq 'case_key=s03_c001_case04' "$simulation_complete_marker"
    grep -Fxq 'steps_completed=210' "$simulation_complete_marker"
    grep -Fxq 'production_qoi_mode=required' "$simulation_complete_marker"
    resumed_after="$(
        awk -F= '/^resumed_after_step=/{print $2}' \
            "$simulation_complete_marker"
    )"
    restart_step="$(
        awk -F= '/^restart_step=/{print $2}' \
            "$simulation_complete_marker"
    )"
    checkpoint_sha256="$(
        awk -F= '/^checkpoint_sha256=/{print $2}' \
            "$simulation_complete_marker"
    )"
    simulation_was_resumed="$(
        awk -F= '/^simulation_was_resumed=/{print $2}' \
            "$simulation_complete_marker"
    )"
fi

if test "$rows_before" -lt 210; then
    test ! -e "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
    test ! -e "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"
    latest_restart="$(
        find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
            -printf '%f\n' |
            sed -n 's/^jutul_\([0-9][0-9]*\)\.jld2$/\1/p' |
            awk -v max="$rows_before" '$1 <= max' |
            sort -n | tail -1
    )"
    [[ "$latest_restart" =~ ^[0-9]+$ ]] ||
        {
            echo "No checkpoint backed by complete scalar/QOI rows." >&2
            exit 1
        }
    test "$latest_restart" -ge 1
    test "$latest_restart" -lt 210
    test -s "$restart_dir/jutul_${latest_restart}.jld2"
    test -s \
        "$row_dir/step_$(printf '%06d' "$latest_restart").tsv"
    test -s \
        "$qoi_row_dir/step_$(printf '%06d' "$latest_restart").tsv"

    resumed_after="$latest_restart"
    restart_step="$((latest_restart + 1))"
    checkpoint_sha256="$(
        sha256sum "$restart_dir/jutul_${latest_restart}.jld2" |
            awk '{print $1}'
    )"
    simulation_was_resumed=true

    export REPO_ROOT="$simulation_repo"
    export CASE_LABEL="$GOM_PRODUCTION_CASE_KEY"
    export CASE_TAG="$case_tag"
    export RUN_ROOT="$full_root"
    export PRODUCTION_SUMMARY_DIR="$summary_dir"
    export PRODUCTION_QOI_MODE=required
    export RESTART_RUN=true
    export RESTART_STEP="$restart_step"
    unset STOP_AFTER_REPORT_STEP

    gom_effective_pc_write_metadata \
        "$attempt_dir/CONTINUATION_METADATA.txt" continuation
    printf '%s\n' \
        "source_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        "source_case=$case_dir" \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "continuation_commit=$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" \
        "original_exit_status_sha256=$(sha256sum "$case_dir/exit_status.txt" | awk '{print $1}')" \
        "rows_before_resume=$rows_before" \
        "qoi_rows_before_resume=$qoi_rows_before" \
        "checkpoint_before_resume=$latest_restart" \
        "restart_step=$restart_step" \
        "checkpoint_sha256=$checkpoint_sha256" \
        'resume_in_place=true' \
        >> "$attempt_dir/CONTINUATION_METADATA.txt"

    if test "$continuation_preflight_only" = true; then
        finish_preflight_only
        exit 0
    fi
    bash "$simulation_repo/scripts/engaging/gom_sampling_cases.sbatch"
else
    gom_effective_pc_write_metadata \
        "$attempt_dir/CONTINUATION_METADATA.txt" continuation_finalize_only
    printf '%s\n' \
        "source_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        "source_case=$case_dir" \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "continuation_commit=$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" \
        "rows_before_resume=$rows_before" \
        "qoi_rows_before_resume=$qoi_rows_before" \
        'resume_in_place=false' \
        >> "$attempt_dir/CONTINUATION_METADATA.txt"
    if test "$continuation_preflight_only" = true; then
        finish_preflight_only
        exit 0
    fi
fi

test "$(count_rows "$row_dir")" -eq 210
test "$(count_rows "$qoi_row_dir")" -eq 210
assert_contiguous_rows "$row_dir" 210
assert_contiguous_rows "$qoi_row_dir" 210
test "$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 2
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test -s "$summary_dir/report_steps.tsv"
test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
test -s "$summary_dir/qoi_region_manifest.tsv"
test -s "$summary_dir/qoi_interface_manifest.tsv"
test -s "$summary_dir/leakage_global_steps.tsv"
test -s "$summary_dir/regional_co2_inventory_steps.tsv"
test -s "$summary_dir/interface_flux_steps.tsv"
test -s "$summary_dir/leakage_case_summary.tsv"
test -s "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"

if ! test -e "$simulation_complete_marker"; then
    simulation_complete_tmp="$simulation_complete_marker.tmp.$SLURM_JOB_ID"
    printf '%s\n' \
        'status=complete' \
        "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "original_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
        "continuation_job_id=$SLURM_JOB_ID" \
        "simulation_was_resumed=$simulation_was_resumed" \
        "resumed_after_step=$resumed_after" \
        "restart_step=$restart_step" \
        "checkpoint_sha256=$checkpoint_sha256" \
        'steps_completed=210' \
        'production_qoi_mode=required' \
        "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$simulation_complete_tmp"
    mv -- "$simulation_complete_tmp" "$simulation_complete_marker"
fi

final_check="$continuation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_final_check.jl"
diagnostics_script="$simulation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl"
test -s "$final_check"
test -s "$diagnostics_script"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1

final_summary_stage="$stage_dir/final_state_summary.txt"
runtime_diagnostics_stage="$stage_dir/runtime_diagnostics.txt"
# The effective-Pc validator deliberately resolves RUN_METADATA.txt beside its
# output path. Because continuation finalization writes into an atomic staging
# directory, stage and byte-verify the immutable source metadata before
# invoking Julia. This mirrors the validated recovery-finalizer contract.
run_metadata_stage="$stage_dir/RUN_METADATA.txt"
cp -- "$case_dir/RUN_METADATA.txt" "$run_metadata_stage"
test -s "$run_metadata_stage"
cmp -s "$case_dir/RUN_METADATA.txt" "$run_metadata_stage"
cd "$continuation_repo"
julia --startup-file=no --project="$simulation_repo" "$final_check" \
    "$restart_dir" "$summary_dir" "$final_summary_stage" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"
julia --startup-file=no --project="$simulation_repo" "$diagnostics_script" \
    "$summary_dir" "$runtime_diagnostics_stage" 210 "$pc_contract"

grep -Fxq 'status=pass' "$final_summary_stage"
grep -Fxq \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "$final_summary_stage"
grep -Fxq 'production_qoi_mode=required' "$final_summary_stage"
grep -Fxq 'qoi_global_rows=210' "$final_summary_stage"
grep -Fxq 'qoi_region_rows=14490' "$final_summary_stage"
grep -Fxq 'qoi_interface_rows=40530' "$final_summary_stage"
grep -Fxq 'status=pass' "$runtime_diagnostics_stage"

(
    cd "$case_dir"
    sha256sum restart/jutul_78.jld2 restart/jutul_210.jld2 \
        > "$stage_dir/RETAINED_RESTART_SHA256.txt"
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
        PREFLIGHT_PC_TABLE_CONTRACT.txt \
        > "$stage_dir/PRODUCTION_SUMMARY_SHA256.txt"
)
runtime_diagnostics_output_sha256="$(
    sha256sum "$runtime_diagnostics_stage" | awk '{print $1}'
)"
printf '%s  %s\n' \
    "$runtime_diagnostics_output_sha256" runtime_diagnostics.txt \
    >> "$stage_dir/PRODUCTION_SUMMARY_SHA256.txt"
{
    printf 'file\tbytes\n'
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\t%s\n' | sort -V
} > "$stage_dir/RESTART_MANIFEST.tsv"

printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" \
    "realization_id=$GOM_PRODUCTION_REALIZATION_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    'grid=step62' \
    'resolution_slices=87' \
    'cells=2165082' \
    'steps_completed=210' \
    'summary_rows=210' \
    'qoi_global_rows=210' \
    'qoi_region_rows=14490' \
    'qoi_interface_rows=40530' \
    'retained_restart_steps=78,210' \
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
    'restart_continuation=true' \
    "continuation_from_step=$resumed_after" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "continuation_commit=$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" \
    "result_dir=$case_dir" \
    > "$stage_dir/production_summary.txt"
grep -E \
    '^(pc_(input|output)_drainage_sha256|pc_kr_sha256|pc_tail_sha256|base_imbibition_sha256|pc_kr_unchanged|pc_at_and_above_entry_unchanged|base_imbibition_unchanged)=' \
    "$pc_contract" >> "$stage_dir/production_summary.txt"
grep -v '^status=' "$runtime_diagnostics_stage" \
    >> "$stage_dir/production_summary.txt"

printf '%s\n' \
    'status=pass' \
    'operation=effective_pc_checkpoint_continuation' \
    "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_EFFECTIVE_PC_FULL_JOB_ID" \
    "source_case=$case_dir" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "continuation_commit=$GOM_EFFECTIVE_PC_CONTINUATION_COMMIT" \
    "rows_before_resume=$rows_before" \
    "qoi_rows_before_resume=$qoi_rows_before" \
    "simulation_was_resumed=$simulation_was_resumed" \
    "resumed_after_step=$resumed_after" \
    "restart_step=$restart_step" \
    "checkpoint_sha256=$checkpoint_sha256" \
    "run_metadata_sha256=$(sha256sum "$run_metadata_stage" | awk '{print $1}')" \
    'steps_completed=210' \
    'production_qoi_mode=required' \
    "runtime_diagnostics_output_sha256=$runtime_diagnostics_output_sha256" \
    > "$stage_dir/CONTINUATION_FINALIZATION_METADATA.txt"

promote_artifact() {
    name="$1"
    source_path="$stage_dir/$name"
    destination="$case_dir/$name"
    test -s "$source_path"
    if test -e "$destination"; then
        cmp -s "$source_path" "$destination" || {
            echo "Existing artifact differs: $destination" >&2
            return 1
        }
        return 0
    fi
    temporary="$destination.tmp.$SLURM_JOB_ID"
    test ! -e "$temporary"
    cp -- "$source_path" "$temporary"
    mv -- "$temporary" "$destination"
}

for artifact in \
    final_state_summary.txt \
    runtime_diagnostics.txt \
    RETAINED_RESTART_SHA256.txt \
    PRODUCTION_SUMMARY_SHA256.txt \
    RESTART_MANIFEST.tsv \
    production_summary.txt \
    CONTINUATION_FINALIZATION_METADATA.txt
do
    promote_artifact "$artifact"
done
(
    cd "$case_dir"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)
cp -- "$case_dir/CONTINUATION_FINALIZATION_METADATA.txt" \
    "$attempt_dir/continuation_summary.txt"

continuation_pass_tmp="$case_dir/CONTINUATION_PASS.tmp.$SLURM_JOB_ID"
printf 'PASS\n' > "$continuation_pass_tmp"
mv -- "$continuation_pass_tmp" "$case_dir/CONTINUATION_PASS"
pass_tmp="$case_dir/PASS.tmp.$SLURM_JOB_ID"
printf 'PASS\n' > "$pass_tmp"
mv -- "$pass_tmp" "$case_dir/PASS"
printf 'PASS\n' > "$attempt_dir/PASS"
