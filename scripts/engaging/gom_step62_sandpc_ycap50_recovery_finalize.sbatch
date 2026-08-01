#!/bin/bash
# Finalize an already completed sandpc_ycap50_v1 run after a validator-only
# failure. This stage never invokes the simulator.
#SBATCH --job-name=gom_s62_spc_recover_finalize
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
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set the original full array job ID.}"
: "${GOM_SANDPC_SIMULATION_REPO:?Set the original simulation repository.}"
: "${GOM_SANDPC_RECOVERY_REPO:?Set the clean validator-hotfix repository.}"
: "${GOM_SANDPC_RECOVERY_COMMIT:?Set the exact validator-hotfix commit.}"
: "${GOM_SANDPC_RECOVERY_PREFLIGHT_JOB_ID:?Set the recovery preflight job ID.}"

for job_id in \
    "$GOM_PRODUCTION_FULL_JOB_ID" \
    "$GOM_SANDPC_RECOVERY_PREFLIGHT_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]] ||
        { echo "Recovery job IDs must be numeric." >&2; exit 1; }
done
[[ "$GOM_SANDPC_RECOVERY_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "GOM_SANDPC_RECOVERY_COMMIT must be a full SHA-1." >&2; exit 1; }

simulation_repo="$(realpath "$GOM_SANDPC_SIMULATION_REPO")"
recovery_repo="$(realpath "$GOM_SANDPC_RECOVERY_REPO")"
test -z "$(git -C "$simulation_repo" status --porcelain)"
test -z "$(git -C "$recovery_repo" status --porcelain)"
test "$(git -C "$recovery_repo" rev-parse HEAD)" = \
    "$GOM_SANDPC_RECOVERY_COMMIT"
test -s "$recovery_repo/Manifest.toml"

export JUTULDARCY_COMBINED_REPO="$simulation_repo"
source \
    "$simulation_repo/scripts/engaging/gom_step62_sandpc_ycap50_common.sh"
gom_sandpc_resolve_task
gom_sandpc_export_locked_physics

recovery_manifest_sha256="$(
    sha256sum "$recovery_repo/Manifest.toml" | awk '{print $1}'
)"
test "$recovery_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_sandpc_ycap50_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        gom_sandpc_case_tag full1000y
)"
case_dir="$full_root/$full_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
preflight_dir="$gom_root/results/gom_step62_sandpc_ycap50_recovery_preflight_job${GOM_SANDPC_RECOVERY_PREFLIGHT_JOB_ID}/$GOM_PRODUCTION_CASE_KEY"
result_root="$gom_root/results/gom_step62_sandpc_ycap50_recovery_finalize_job${SLURM_ARRAY_JOB_ID}"
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
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
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
error_log="$gom_root/logs/gom_s62_spc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"
expected_exit_sha256="$(
    awk -F= '/^original_exit_status_sha256=/{print $2}' "$preflight_summary"
)"
expected_error_sha256="$(
    awk -F= '/^original_error_sha256=/{print $2}' "$preflight_summary"
)"
expected_validator_sha256="$(
    awk -F= '/^validator_sha256=/{print $2}' "$preflight_summary"
)"
expected_source_manifest_sha256="$(
    awk -F= '/^source_artifact_manifest_sha256=/{print $2}' \
        "$preflight_summary"
)"
source_artifact_manifest="$preflight_dir/SOURCE_ARTIFACTS_SHA256.txt"
[[ "$expected_exit_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$expected_error_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$expected_validator_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$expected_source_manifest_sha256" =~ ^[0-9a-f]{64}$ ]]
test "$(sha256sum "$case_dir/exit_status.txt" | awk '{print $1}')" = \
    "$expected_exit_sha256"
test "$(sha256sum "$error_log" | awk '{print $1}')" = \
    "$expected_error_sha256"
test "$(
    sha256sum \
        "$recovery_repo/scripts/engaging/gom_step62_sandpc_ycap50_final_check.jl" |
        awk '{print $1}'
)" = "$expected_validator_sha256"
test "$(sha256sum "$source_artifact_manifest" | awk '{print $1}')" = \
    "$expected_source_manifest_sha256"
(
    cd "$case_dir"
    sha256sum --check "$source_artifact_manifest"
)

# A replacement finalizer may start after an earlier attempt promoted every
# source artifact and PASS, but died before recording success in its own result
# directory. Treat that fully verified state as an idempotent success.
if test -f "$case_dir/PASS"; then
    grep -Fxq 'PASS' "$case_dir/PASS"
    grep -Fxq 'PASS' "$case_dir/RECOVERY_PASS"
    for artifact in \
        final_state_summary.txt \
        RETAINED_RESTART_SHA256.txt \
        PRODUCTION_SUMMARY_SHA256.txt \
        RESTART_MANIFEST.tsv \
        production_summary.txt \
        RECOVERY_FINALIZATION_METADATA.txt
    do
        test -s "$case_dir/$artifact"
    done
    grep -Fxq 'status=pass' "$case_dir/production_summary.txt"
    grep -Fxq 'validation_recovered=true' \
        "$case_dir/production_summary.txt"
    grep -Fxq \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "$case_dir/production_summary.txt"
    grep -Fxq "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
        "$case_dir/production_summary.txt"
    grep -Fxq 'status=pass' \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq 'operation=validation_only_no_simulation_rerun' \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq \
        "source_artifact_manifest_sha256=$expected_source_manifest_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "original_exit_status_sha256=$expected_exit_sha256" \
        "$case_dir/RECOVERY_FINALIZATION_METADATA.txt"
    grep -Fxq "original_error_sha256=$expected_error_sha256" \
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
cd "$recovery_repo"
julia --startup-file=no --project="$simulation_repo" \
    "$recovery_repo/scripts/engaging/gom_step62_sandpc_ycap50_final_check.jl" \
    "$restart_dir" "$summary_dir" "$final_summary_stage" \
    "$GOM_PRODUCTION_CASE_KEY" "$GOM_PRODUCTION_MANIFEST_SHA256"

grep -Fxq 'status=pass' "$final_summary_stage"
grep -Fxq "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
    "$final_summary_stage"
grep -Fxq 'production_qoi_mode=required' "$final_summary_stage"
grep -Fxq 'qoi_global_rows=210' "$final_summary_stage"
grep -Fxq 'qoi_region_rows=14490' "$final_summary_stage"
grep -Fxq 'qoi_interface_rows=40530' "$final_summary_stage"

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
        > "$stage_dir/PRODUCTION_SUMMARY_SHA256.txt"
    sha256sum --check "$stage_dir/RETAINED_RESTART_SHA256.txt"
    sha256sum --check "$stage_dir/PRODUCTION_SUMMARY_SHA256.txt"
)
{
    printf 'file\tbytes\n'
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\t%s\n' | sort -V
} > "$stage_dir/RESTART_MANIFEST.tsv"

printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
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
    "fault_pc_entry_treatment=predict_plateau_only" \
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
    "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
    "result_dir=$case_dir" \
    > "$stage_dir/production_summary.txt"

original_exit_sha256="$expected_exit_sha256"
original_error_sha256="$(sha256sum "$error_log" | awk '{print $1}')"
validator_sha256="$expected_validator_sha256"
printf '%s\n' \
    "status=pass" \
    "operation=validation_only_no_simulation_rerun" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "source_case=$case_dir" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
    "recovery_manifest_sha256=$recovery_manifest_sha256" \
    "validator_sha256=$validator_sha256" \
    "source_artifact_manifest_sha256=$expected_source_manifest_sha256" \
    "original_exit_status_sha256=$original_exit_sha256" \
    "original_error_log=$error_log" \
    "original_error_sha256=$original_error_sha256" \
    "recovery_preflight_job_id=$GOM_SANDPC_RECOVERY_PREFLIGHT_JOB_ID" \
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
