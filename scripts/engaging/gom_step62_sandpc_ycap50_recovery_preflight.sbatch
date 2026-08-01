#!/bin/bash
# Audit a completed sandpc_ycap50_v1 run before validator-only recovery.
#SBATCH --job-name=gom_s62_spc_recover_check
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
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set the original full array job ID.}"
: "${GOM_SANDPC_SIMULATION_REPO:?Set the original simulation repository.}"
: "${GOM_SANDPC_RECOVERY_REPO:?Set the clean validator-hotfix repository.}"
: "${GOM_SANDPC_RECOVERY_COMMIT:?Set the exact validator-hotfix commit.}"

[[ "$GOM_PRODUCTION_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_PRODUCTION_FULL_JOB_ID must be numeric." >&2; exit 1; }
[[ "$GOM_SANDPC_RECOVERY_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "GOM_SANDPC_RECOVERY_COMMIT must be a full SHA-1." >&2; exit 1; }

simulation_repo="$(realpath "$GOM_SANDPC_SIMULATION_REPO")"
recovery_repo="$(realpath "$GOM_SANDPC_RECOVERY_REPO")"
test -z "$(git -C "$simulation_repo" status --porcelain)"
test -z "$(git -C "$recovery_repo" status --porcelain)"
test "$(git -C "$recovery_repo" rev-parse HEAD)" = \
    "$GOM_SANDPC_RECOVERY_COMMIT"
test -s "$recovery_repo/Manifest.toml"

# Resolve and verify the immutable inputs against the original simulation
# commit. The hotfix repository is checked independently above.
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
error_log="$gom_root/logs/gom_s62_spc_full-${GOM_PRODUCTION_FULL_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"
result_root="$gom_root/results/gom_step62_sandpc_ycap50_recovery_preflight_job${SLURM_ARRAY_JOB_ID}"
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
    RETAINED_RESTART_SHA256.txt \
    PRODUCTION_SUMMARY_SHA256.txt \
    RESTART_MANIFEST.tsv
do
    test ! -e "$case_dir/$unexpected"
done
test -s "$case_dir/exit_status.txt"
grep -Fxq 'exit_code=1' "$case_dir/exit_status.txt"
test -s "$error_log"
grep -Fq \
    'no method matching enumerate(::Vector{String}; start::Int64)' \
    "$error_log"
grep -Fq 'gom_step62_sandpc_ycap50_final_check.jl:48' "$error_log"

grep -Eq '^job_id=[0-9]+$' "$case_dir/RUN_METADATA.txt"
for expected_metadata in \
    "array_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "array_task_id=$SLURM_ARRAY_TASK_ID" \
    'phase=full1000y' \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    'physics_profile=sandpc_ycap50_v1' \
    'production_output_mode=true' \
    'production_qoi_mode=required'
do
    grep -Fxq "$expected_metadata" "$case_dir/RUN_METADATA.txt"
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
test -z "$(find "$summary_dir/qoi/ready" -mindepth 1 -maxdepth 1 -print -quit)"
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
validator_sha256="$(
    sha256sum \
        "$recovery_repo/scripts/engaging/gom_step62_sandpc_ycap50_final_check.jl" |
        awk '{print $1}'
)"
source_artifact_manifest="$result_dir/SOURCE_ARTIFACTS_SHA256.txt"
(
    cd "$case_dir"
    find restart -type f -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum > "$source_artifact_manifest"
    sha256sum --check "$source_artifact_manifest"
)
source_artifact_manifest_sha256="$(
    sha256sum "$source_artifact_manifest" | awk '{print $1}'
)"
printf '%s\n' \
    "status=pass" \
    "operation=validator_only_recovery_preflight" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "source_case=$case_dir" \
    "simulation_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "recovery_commit=$GOM_SANDPC_RECOVERY_COMMIT" \
    "recovery_manifest_sha256=$recovery_manifest_sha256" \
    "validator_sha256=$validator_sha256" \
    "source_artifact_manifest=$source_artifact_manifest" \
    "source_artifact_manifest_sha256=$source_artifact_manifest_sha256" \
    "original_exit_status_sha256=$original_exit_sha256" \
    "original_error_log=$error_log" \
    "original_error_sha256=$original_error_sha256" \
    "error_signature_matched=true" \
    "simulation_complete=true" \
    "production_rows=210" \
    "qoi_bundles=210" \
    "retained_restart_steps=78,210" \
    "simulation_resubmission_required=false" \
    > "$result_dir/recovery_preflight_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
