#!/bin/bash
# Finalize an already completed effective-Pc/global-plateau run after the
# known validator parse failure. This stage never invokes the simulator.
#SBATCH --job-name=gom_s62_epc_recover_finalize
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the original immutable campaign manifest.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set the original full-array job ID.}"
: "${GOM_EFFECTIVE_PC_TASK_SET:?Set the exact original task set.}"
: "${GOM_EFFECTIVE_PC_SIMULATION_REPO:?Set the original simulation repository.}"
: "${GOM_EFFECTIVE_PC_RECOVERY_REPO:?Set the clean validator-hotfix repository.}"
: "${GOM_EFFECTIVE_PC_RECOVERY_COMMIT:?Set the exact validator-hotfix commit.}"
: "${GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID:?Set the recovery preflight job ID.}"

for job_id in \
    "$GOM_PRODUCTION_FULL_JOB_ID" \
    "$GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]] ||
        { echo "Recovery job IDs must be numeric." >&2; exit 1; }
done
[[ "$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    {
        echo "GOM_EFFECTIVE_PC_RECOVERY_COMMIT must be a full SHA-1." >&2
        exit 1
    }
case "$GOM_EFFECTIVE_PC_TASK_SET:$SLURM_ARRAY_TASK_ID" in
    1:1|5:6:7:5|5:6:7:6|5:6:7:7|\
    1:5:6:7:1|1:5:6:7:5|1:5:6:7:6|1:5:6:7:7) ;;
    *)
        echo "Task $SLURM_ARRAY_TASK_ID is not in explicit task set" \
            "$GOM_EFFECTIVE_PC_TASK_SET." >&2
        exit 1
        ;;
esac

simulation_repo="$(realpath "$GOM_EFFECTIVE_PC_SIMULATION_REPO")"
recovery_repo="$(realpath "$GOM_EFFECTIVE_PC_RECOVERY_REPO")"
test -z "$(git -C "$simulation_repo" status --porcelain)"
test -z "$(git -C "$recovery_repo" status --porcelain)"
test "$(git -C "$recovery_repo" rev-parse HEAD)" = \
    "$GOM_EFFECTIVE_PC_RECOVERY_COMMIT"
test -s "$recovery_repo/Manifest.toml"

export JUTULDARCY_COMBINED_REPO="$simulation_repo"
source \
    "$simulation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics

recovery_manifest_sha256="$(
    sha256sum "$recovery_repo/Manifest.toml" | awk '{print $1}'
)"
test "$recovery_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"

validator_name=gom_step62_effective_pc_global_plateau_final_check.jl
base_validator_name=gom_step62_production_final_check.jl
contract_name=gom_step62_effective_pc_global_plateau_contract.jl
diagnostics_name=gom_step62_effective_pc_global_plateau_runtime_diagnostics.jl
original_validator="$simulation_repo/scripts/engaging/$validator_name"
recovery_validator="$recovery_repo/scripts/engaging/$validator_name"
original_base_validator="$simulation_repo/scripts/engaging/$base_validator_name"
recovery_base_validator="$recovery_repo/scripts/engaging/$base_validator_name"
original_contract="$simulation_repo/scripts/engaging/$contract_name"
recovery_contract="$recovery_repo/scripts/engaging/$contract_name"
original_diagnostics="$simulation_repo/scripts/engaging/$diagnostics_name"
recovery_diagnostics="$recovery_repo/scripts/engaging/$diagnostics_name"
for required_script in \
    "$original_validator" \
    "$recovery_validator" \
    "$original_base_validator" \
    "$recovery_base_validator" \
    "$original_contract" \
    "$recovery_contract" \
    "$original_diagnostics" \
    "$recovery_diagnostics"
do
    test -s "$required_script"
done
cmp -s "$original_base_validator" "$recovery_base_validator"
cmp -s "$original_contract" "$recovery_contract"
cmp -s "$original_diagnostics" "$recovery_diagnostics"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        gom_effective_pc_case_tag full1000y
)"
case_dir="$full_root/$full_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
pc_contract="$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"
preflight_dir="$gom_root/results/gom_step62_effective_pc_global_plateau_recovery_preflight_job${GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID}/$GOM_PRODUCTION_CASE_KEY"
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_recovery_finalize_job${SLURM_ARRAY_JOB_ID}"
result_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
test ! -e "$result_dir"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$preflight_dir/PASS"
preflight_summary="$preflight_dir/recovery_preflight_summary.txt"
for expected_preflight in \
    'status=pass' \
    'operation=effective_pc_validation_only_recovery_preflight' \
    "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
    'error_signature=parse_error_multiline_range' \
    'error_signature_matched=true' \
    'simulation_complete=true' \
    'production_rows=210' \
    'qoi_bundles=210' \
    'retained_restart_steps=78,210' \
    'simulation_resubmission_required=false'
do
    grep -Fxq "$expected_preflight" "$preflight_summary"
done

test -d "$case_dir"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "The source simulation directory is still locked: $case_dir" >&2
    exit 1
}
test -s "$case_dir/exit_status.txt"
grep -Fxq 'exit_code=1' "$case_dir/exit_status.txt"
error_log="$gom_root/logs/gom_s62_epc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"
expected_exit_sha256="$(
    awk -F= '/^original_exit_status_sha256=/{print $2}' "$preflight_summary"
)"
expected_error_sha256="$(
    awk -F= '/^original_error_sha256=/{print $2}' "$preflight_summary"
)"
expected_original_validator_sha256="$(
    awk -F= '/^original_validator_sha256=/{print $2}' "$preflight_summary"
)"
expected_recovery_validator_sha256="$(
    awk -F= '/^recovery_validator_sha256=/{print $2}' "$preflight_summary"
)"
expected_base_validator_sha256="$(
    awk -F= '/^base_validator_sha256=/{print $2}' "$preflight_summary"
)"
expected_diagnostics_sha256="$(
    awk -F= '/^runtime_diagnostics_sha256=/{print $2}' "$preflight_summary"
)"
expected_pc_contract_sha256="$(
    awk -F= '/^pc_contract_sha256=/{print $2}' "$preflight_summary"
)"
expected_source_manifest_sha256="$(
    awk -F= '/^source_artifact_manifest_sha256=/{print $2}' \
        "$preflight_summary"
)"
for digest in \
    "$expected_exit_sha256" \
    "$expected_error_sha256" \
    "$expected_original_validator_sha256" \
    "$expected_recovery_validator_sha256" \
    "$expected_base_validator_sha256" \
    "$expected_diagnostics_sha256" \
    "$expected_pc_contract_sha256" \
    "$expected_source_manifest_sha256"
do
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
done

source_artifact_manifest="$preflight_dir/SOURCE_ARTIFACTS_SHA256.txt"
test "$(sha256sum "$case_dir/exit_status.txt" | awk '{print $1}')" = \
    "$expected_exit_sha256"
test "$(sha256sum "$error_log" | awk '{print $1}')" = \
    "$expected_error_sha256"
test "$(sha256sum "$original_validator" | awk '{print $1}')" = \
    "$expected_original_validator_sha256"
test "$(sha256sum "$recovery_validator" | awk '{print $1}')" = \
    "$expected_recovery_validator_sha256"
test "$(sha256sum "$original_base_validator" | awk '{print $1}')" = \
    "$expected_base_validator_sha256"
test "$(sha256sum "$recovery_base_validator" | awk '{print $1}')" = \
    "$expected_base_validator_sha256"
test "$(sha256sum "$original_diagnostics" | awk '{print $1}')" = \
    "$expected_diagnostics_sha256"
test "$(sha256sum "$pc_contract" | awk '{print $1}')" = \
    "$expected_pc_contract_sha256"
test "$(sha256sum "$source_artifact_manifest" | awk '{print $1}')" = \
    "$expected_source_manifest_sha256"
(
    cd "$case_dir"
    sha256sum --check "$source_artifact_manifest"
)

# A retry after complete promotion is a validation-only idempotent success.
if test -f "$case_dir/PASS"; then
    grep -Fxq 'PASS' "$case_dir/PASS"
    grep -Fxq 'PASS' "$case_dir/RECOVERY_PASS"
    for artifact in \
        final_state_summary.txt \
        runtime_diagnostics.txt \
        RETAINED_RESTART_SHA256.txt \
        PRODUCTION_SUMMARY_SHA256.txt \
        RESTART_MANIFEST.tsv \
        production_summary.txt \
        RECOVERY_FINALIZATION_METADATA.txt
    do
        test -s "$case_dir/$artifact"
    done
    grep -Fxq 'status=pass' "$case_dir/production_summary.txt"
    grep -Fxq \
        'physics_profile=sandpc_effective_globalplateau_v1' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'pc_entry_scope=all_active_drainage' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'validation_recovered=true' \
        "$case_dir/production_summary.txt"
    grep -Fxq \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "$case_dir/production_summary.txt"
    grep -Fxq "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
        "$case_dir/production_summary.txt"
    grep -Fxq 'status=pass' "$case_dir/final_state_summary.txt"
    grep -Fxq \
        'physics_profile=sandpc_effective_globalplateau_v1' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'production_qoi_mode=required' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_global_rows=210' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_region_rows=14490' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_interface_rows=40530' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'status=pass' "$case_dir/runtime_diagnostics.txt"
    grep -Fxq 'status=pass' \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        'operation=effective_pc_validation_only_no_simulation_rerun' \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "recovery_manifest_sha256=$recovery_manifest_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "original_validator_sha256=$expected_original_validator_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "recovery_validator_sha256=$expected_recovery_validator_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "base_validator_sha256=$expected_base_validator_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "runtime_diagnostics_script_sha256=$expected_diagnostics_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    runtime_diagnostics_output_sha256="$(
        sha256sum "$case_dir/runtime_diagnostics.txt" | awk '{print $1}'
    )"
    grep -Fxq \
        "runtime_diagnostics_output_sha256=$runtime_diagnostics_output_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "pc_contract_sha256=$expected_pc_contract_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "source_artifact_manifest_sha256=$expected_source_manifest_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "original_exit_status_sha256=$expected_exit_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "original_error_sha256=$expected_error_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "recovery_preflight_job_id=$GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    (
        cd "$case_dir"
        sha256sum --check RETAINED_RESTART_SHA256.txt
        sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
    )
    cp -- "$case_dir/RECOVERY_FINALIZATION_METADATA.txt" \
        "$result_dir/recovery_finalization_summary.txt"
    printf 'PASS\n' > "$result_dir/PASS"
    exit 0
fi

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1
stage_dir="$result_dir/staged"
mkdir "$stage_dir"
cp -- "$case_dir/RUN_METADATA.txt" "$stage_dir/RUN_METADATA.txt"
final_summary_stage="$stage_dir/final_state_summary.txt"
runtime_diagnostics_stage="$stage_dir/runtime_diagnostics.txt"

cd "$recovery_repo"
julia --startup-file=no --project="$simulation_repo" \
    "$recovery_validator" \
    "$restart_dir" "$summary_dir" "$final_summary_stage" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"
julia --startup-file=no --project="$simulation_repo" \
    "$original_diagnostics" \
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
grep -Eq '^total_ministeps=[0-9]+$' "$runtime_diagnostics_stage"
grep -Eq '^newton_iterations=[0-9]+$' \
    "$runtime_diagnostics_stage"
grep -Eq '^linear_iterations=[0-9]+$' \
    "$runtime_diagnostics_stage"

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
    "grid=step62" \
    "resolution_slices=87" \
    "cells=2165082" \
    "steps_completed=210" \
    "summary_rows=210" \
    "qoi_global_rows=210" \
    "qoi_region_rows=14490" \
    "qoi_interface_rows=40530" \
    "retained_restart_steps=78,210" \
    "schedule_end_years=1000" \
    "hysteresis_active=true" \
    "fault_pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "pc_entry_rule=first_strictly_positive_pc_node" \
    "pc_mapping_schema=gom_effective_saturation_pc_v1" \
    "pc_mapping_method=entry_renormalized_analytic_brooks_corey" \
    "pc_reference=sand_theta30" \
    "host_pc_scaling=leverett_kv" \
    "nonpredict_pc_scaling=leverett_local_kzz" \
    "younger_nonpredict_local_perm_md=50,500,500" \
    "transmissibility_source=JutulDarcy_grid_and_rock" \
    "production_output_mode=true" \
    "production_qoi_mode=required" \
    "old_restart_reuse=false" \
    "validation_recovered=true" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
    "result_dir=$case_dir" \
    > "$stage_dir/production_summary.txt"
grep -E \
    '^(pc_(input|output)_drainage_sha256|pc_kr_sha256|pc_tail_sha256|base_imbibition_sha256|pc_kr_unchanged|pc_at_and_above_entry_unchanged|base_imbibition_unchanged)=' \
    "$pc_contract" >> "$stage_dir/production_summary.txt"
grep -v '^status=' "$runtime_diagnostics_stage" \
    >> "$stage_dir/production_summary.txt"

printf '%s\n' \
    "status=pass" \
    "operation=effective_pc_validation_only_no_simulation_rerun" \
    "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "source_case=$case_dir" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
    "recovery_manifest_sha256=$recovery_manifest_sha256" \
    "original_validator_sha256=$expected_original_validator_sha256" \
    "recovery_validator_sha256=$expected_recovery_validator_sha256" \
    "base_validator_sha256=$expected_base_validator_sha256" \
    "runtime_diagnostics_script_sha256=$expected_diagnostics_sha256" \
    "runtime_diagnostics_output_sha256=$runtime_diagnostics_output_sha256" \
    "pc_contract_sha256=$expected_pc_contract_sha256" \
    "source_artifact_manifest_sha256=$expected_source_manifest_sha256" \
    "original_exit_status_sha256=$expected_exit_sha256" \
    "original_error_log=$error_log" \
    "original_error_sha256=$expected_error_sha256" \
    "recovery_preflight_job_id=$GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID" \
    > "$stage_dir/RECOVERY_FINALIZATION_METADATA.txt"

promote_artifact() {
    name="$1"
    source_path="$stage_dir/$name"
    destination="$case_dir/$name"
    test -s "$source_path"
    if test -e "$destination"; then
        cmp -s "$source_path" "$destination" || {
            echo "Existing recovery artifact differs: $destination" >&2
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
    RECOVERY_FINALIZATION_METADATA.txt
do
    promote_artifact "$artifact"
done
(
    cd "$case_dir"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)
cp -- "$case_dir/RECOVERY_FINALIZATION_METADATA.txt" \
    "$result_dir/recovery_finalization_summary.txt"

recovery_pass_tmp="$case_dir/RECOVERY_PASS.tmp.$SLURM_JOB_ID"
printf 'PASS\n' > "$recovery_pass_tmp"
mv -- "$recovery_pass_tmp" "$case_dir/RECOVERY_PASS"
pass_tmp="$case_dir/PASS.tmp.$SLURM_JOB_ID"
printf 'PASS\n' > "$pass_tmp"
mv -- "$pass_tmp" "$case_dir/PASS"
printf 'PASS\n' > "$result_dir/PASS"
