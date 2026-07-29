#!/bin/bash
# Audit a completed effective-Pc/global-plateau run before validation-only
# recovery. This job never invokes the simulator or writes into the source
# case directory.
#SBATCH --job-name=gom_s62_epc_recover_check
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
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

[[ "$GOM_PRODUCTION_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_PRODUCTION_FULL_JOB_ID must be numeric." >&2; exit 1; }
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

# Resolve the immutable campaign against its original repository. The
# recovery repository is deliberately not used for manifest resolution:
# campaigns pin the exact commit that performed the simulation.
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
original_validator_sha256="$(
    sha256sum "$original_validator" | awk '{print $1}'
)"
recovery_validator_sha256="$(
    sha256sum "$recovery_validator" | awk '{print $1}'
)"
test "$original_validator_sha256" != "$recovery_validator_sha256"
base_validator_sha256="$(
    sha256sum "$original_base_validator" | awk '{print $1}'
)"
diagnostics_sha256="$(
    sha256sum "$original_diagnostics" | awk '{print $1}'
)"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        gom_effective_pc_case_tag full1000y
)"
case_dir="$full_root/$full_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
error_log="$gom_root/logs/gom_s62_epc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_recovery_preflight_job${SLURM_ARRAY_JOB_ID}"
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

test -d "$case_dir"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "The source simulation directory is still locked: $case_dir" >&2
    exit 1
}
for unexpected in \
    PASS \
    RECOVERY_PASS \
    RECOVERY_FINALIZATION_METADATA.txt \
    production_summary.txt \
    final_state_summary.txt \
    runtime_diagnostics.txt \
    RETAINED_RESTART_SHA256.txt \
    PRODUCTION_SUMMARY_SHA256.txt \
    RESTART_MANIFEST.tsv
do
    test ! -e "$case_dir/$unexpected"
done

test -s "$case_dir/exit_status.txt"
grep -Fxq 'exit_code=1' "$case_dir/exit_status.txt"
test -s "$error_log"
grep -Fq 'ParseError:' "$error_log"
grep -Fq \
    'gom_step62_effective_pc_global_plateau_final_check.jl:219:50' \
    "$error_log"
grep -Fq 'line break after `:` in range expression' "$error_log"

grep -Eq '^job_id=[0-9]+$' "$case_dir/RUN_METADATA.txt"
for expected_metadata in \
    "array_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "array_task_id=$SLURM_ARRAY_TASK_ID" \
    'phase=full1000y' \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    'physics_profile=sandpc_effective_globalplateau_v1' \
    'fault_pc_entry_treatment=plateau_all_active' \
    'pc_entry_scope=all_active_drainage' \
    'pc_mapping_schema=gom_effective_saturation_pc_v1' \
    'pc_mapping_method=entry_renormalized_analytic_brooks_corey' \
    'production_output_mode=true' \
    'production_qoi_mode=required' \
    'old_restart_reuse=false'
do
    grep -Fxq "$expected_metadata" "$case_dir/RUN_METADATA.txt"
done

pc_contract="$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"
test -s "$pc_contract"
for expected_pc_contract in \
    'status=pass' \
    'physics_profile=sandpc_effective_globalplateau_v1' \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    'pc_entry_treatment=plateau_all_active' \
    'pc_plateau_active_tables=530' \
    'pc_plateau_adjusted_tables=530' \
    'pc_plateau_true_zero_tables=0' \
    'pc_kr_unchanged=true' \
    'pc_at_and_above_entry_unchanged=true' \
    'base_imbibition_unchanged=true'
do
    grep -Fxq "$expected_pc_contract" "$pc_contract"
done
for digest_name in \
    pc_input_drainage_sha256 \
    pc_output_drainage_sha256 \
    pc_kr_sha256 \
    pc_tail_sha256 \
    base_imbibition_sha256
do
    grep -Eq "^${digest_name}=[0-9a-f]{64}$" "$pc_contract"
done

test "$(find "$restart_dir" -maxdepth 1 -type f \
    -name 'jutul_*.jld2' | wc -l)" -eq 2
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 210
test "$(find "$summary_dir/qoi/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 210
test -d "$summary_dir/qoi/ready"
test -z "$(
    find "$summary_dir/qoi/ready" -mindepth 1 -maxdepth 1 -print -quit
)"
for required in \
    report_steps.tsv \
    PRODUCTION_OUTPUT_COMPLETE.tsv \
    qoi_region_manifest.tsv \
    qoi_interface_manifest.tsv \
    leakage_global_steps.tsv \
    regional_co2_inventory_steps.tsv \
    interface_flux_steps.tsv \
    leakage_case_summary.tsv \
    QOI_OUTPUT_COMPLETE.tsv
do
    test -s "$summary_dir/$required"
done
grep -Fq $'1\tcomplete\t'"$GOM_PRODUCTION_CASE_KEY"$'\t' \
    "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
grep -Fq $'1\tcomplete\t'"$GOM_PRODUCTION_CASE_KEY"$'\t210\t' \
    "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"

original_exit_sha256="$(
    sha256sum "$case_dir/exit_status.txt" | awk '{print $1}'
)"
original_error_sha256="$(sha256sum "$error_log" | awk '{print $1}')"
pc_contract_sha256="$(sha256sum "$pc_contract" | awk '{print $1}')"
source_artifact_manifest="$result_dir/SOURCE_ARTIFACTS_SHA256.txt"
(
    cd "$case_dir"
    {
        find restart -type f -print0
        printf '%s\0' PREFLIGHT_PC_TABLE_CONTRACT.txt
    } |
        LC_ALL=C sort -z |
        xargs -0 sha256sum > "$source_artifact_manifest"
    sha256sum --check "$source_artifact_manifest"
)
source_artifact_manifest_sha256="$(
    sha256sum "$source_artifact_manifest" | awk '{print $1}'
)"
printf '%s\n' \
    "status=pass" \
    "operation=effective_pc_validation_only_recovery_preflight" \
    "task_set=$GOM_EFFECTIVE_PC_TASK_SET" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "source_case=$case_dir" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_EFFECTIVE_PC_RECOVERY_COMMIT" \
    "recovery_manifest_sha256=$recovery_manifest_sha256" \
    "original_validator_sha256=$original_validator_sha256" \
    "recovery_validator_sha256=$recovery_validator_sha256" \
    "base_validator_sha256=$base_validator_sha256" \
    "runtime_diagnostics_sha256=$diagnostics_sha256" \
    "pc_contract_sha256=$pc_contract_sha256" \
    "source_artifact_manifest=$source_artifact_manifest" \
    "source_artifact_manifest_sha256=$source_artifact_manifest_sha256" \
    "original_exit_status_sha256=$original_exit_sha256" \
    "original_error_log=$error_log" \
    "original_error_sha256=$original_error_sha256" \
    "error_signature=parse_error_multiline_range" \
    "error_signature_matched=true" \
    "simulation_complete=true" \
    "production_rows=210" \
    "qoi_bundles=210" \
    "retained_restart_steps=78,210" \
    "simulation_resubmission_required=false" \
    > "$result_dir/recovery_preflight_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
