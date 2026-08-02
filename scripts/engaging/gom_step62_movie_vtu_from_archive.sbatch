#!/bin/bash
#SBATCH --job-name=gom_s62_movie_vtu
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=5-7
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${GOM_MOVIE_ARCHIVE_ROOT:?Set the durable movie restart archive.}"
: "${GOM_MOVIE_SOURCE_JOB_ID:?Set the source simulation array job ID.}"
: "${GOM_MOVIE_SCIENCE_REPO:?Set the checksum-pinned simulation checkout.}"
: "${GOM_MOVIE_WORKFLOW_DIR:?Set the directory containing the movie VTU scripts.}"

[[ "$GOM_MOVIE_SOURCE_JOB_ID" =~ ^[0-9]+$ ]] || {
    echo "GOM_MOVIE_SOURCE_JOB_ID must be numeric." >&2
    exit 1
}
case "$SLURM_ARRAY_TASK_ID" in
    5|6|7) ;;
    *)
        echo "Movie VTU export permits only tasks 5, 6, and 7." >&2
        exit 1
        ;;
esac

archive_root="$(readlink -f -- "$GOM_MOVIE_ARCHIVE_ROOT")"
science_repo="$(readlink -f -- "$GOM_MOVIE_SCIENCE_REPO")"
workflow_dir="$(readlink -f -- "$GOM_MOVIE_WORKFLOW_DIR")"
test -f "$archive_root/ARCHIVE_COMPLETE"
test -f "$archive_root/SOURCE_REMOVED.txt"
test -f "$archive_root/SOURCE_SHA256.txt"

matches=()
while IFS= read -r -d '' path; do
    matches+=("$path")
done < <(
    find "$archive_root/payload" -mindepth 1 -maxdepth 1 -type d \
        -name "*_job${GOM_MOVIE_SOURCE_JOB_ID}_${SLURM_ARRAY_TASK_ID}" \
        -print0
)
test "${#matches[@]}" -eq 1 || {
    echo "Expected one archived source case; found ${#matches[@]}." >&2
    exit 1
}
source_case="${matches[0]}"
restart_dir="$source_case/restart"
test -f "$source_case/PASS"
grep -Fxq 'status=pass' "$source_case/movie_simulation_summary.txt"
grep -Fxq 'steps_completed=210' "$source_case/movie_simulation_summary.txt"
grep -Fxq 'retained_restart_steps=1:210' \
    "$source_case/movie_simulation_summary.txt"
test "$(find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' | wc -l)" \
    -eq 210

while IFS=$'\t' read -r step file bytes; do
    test "$step" = step && continue
    [[ "$step" =~ ^[1-9][0-9]*$ ]]
    [[ "$bytes" =~ ^[1-9][0-9]*$ ]]
    restart_path="$restart_dir/$file"
    test -s "$restart_path"
    test "$(stat -c %s "$restart_path")" -eq "$bytes"
done < "$source_case/RESTART_MANIFEST.tsv"
test "$(tail -n +2 "$source_case/RESTART_MANIFEST.tsv" | wc -l)" -eq 210

export JUTULDARCY_COMBINED_REPO="$science_repo"
export GOM_PRODUCTION_MANIFEST="$source_case/campaign.toml"
export PRODUCTION_QOI_MODE=required
source \
    "$science_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics
export PRODUCTION_QOI_MODE=required

grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "$source_case/movie_simulation_summary.txt"
test "$(sha256sum "$source_case/campaign.toml" | awk '{print $1}')" = \
    "$GOM_PRODUCTION_MANIFEST_SHA256"

campaign_root="$(dirname -- "$archive_root")"
result_root="$campaign_root/vtu_job${SLURM_ARRAY_JOB_ID}"
final_case="$result_root/$GOM_PRODUCTION_CASE_KEY"
incoming_parent="$result_root/.incoming"
incoming_case="$incoming_parent/$GOM_PRODUCTION_CASE_KEY"
vtu_dir="$incoming_case/vtu"
prefix="gom_step62_effective_pc_global_plateau_${GOM_PRODUCTION_CASE_KEY}"
script="$workflow_dir/gom_step62_effective_pc_global_plateau_vtu.jl"
test -f "$script"
contract_script="$workflow_dir/gom_step62_effective_pc_global_plateau_contract.jl"
indicator_script="$workflow_dir/gom_step62_vtu_geology_indicators.jl"
test -f "$contract_script"
test -f "$indicator_script"

if test -d "$final_case"; then
    test -f "$final_case/PASS"
    grep -Fxq 'status=pass' "$final_case/export_summary.txt"
    grep -Fxq 'export_mode=all_report_steps' "$final_case/export_summary.txt"
    grep -Fxq 'vtu_files=211' "$final_case/export_summary.txt"
    (
        cd "$final_case"
        sha256sum --check VTU_SHA256.txt >/dev/null
    )
    echo "Verified existing movie VTU case: $final_case"
    exit 0
fi

mkdir -p -- "$vtu_dir"
status_target="$incoming_case"
record_exit_status() {
    exit_code=$?
    mkdir -p -- "$status_target"
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$status_target/exit_status.txt"
}
trap record_exit_status EXIT

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export OPENBLAS_NUM_THREADS=1

gom_effective_pc_write_metadata "$incoming_case/EXPORT_METADATA.txt" movie_vtu
printf '%s\n' \
    "source_simulation_job_id=$GOM_MOVIE_SOURCE_JOB_ID" \
    "source_archive=$archive_root" \
    "source_case=$source_case" \
    'source_storage=durable_disk' \
    'output_storage=durable_disk' \
    'export_mode=all_report_steps' \
    "workflow_vtu_sha256=$(sha256sum "$script" | awk '{print $1}')" \
    "workflow_contract_sha256=$(sha256sum "$contract_script" | awk '{print $1}')" \
    "workflow_indicators_sha256=$(sha256sum "$indicator_script" | awk '{print $1}')" \
    >> "$incoming_case/EXPORT_METADATA.txt"
mkdir -p -- "$incoming_case/workflow"
cp -- "$script" "$contract_script" "$indicator_script" \
    "$incoming_case/workflow/"
cp -- "$source_case/campaign.toml" "$incoming_case/campaign.toml"
cp -- "$source_case/campaign.toml.sha256.original" \
    "$incoming_case/campaign.toml.sha256.original"

cd "$science_repo"
julia --startup-file=no --project=. "$script" \
    "$GOM_PRODUCTION_COMMON_MAT" "$GOM_PRODUCTION_SPECIFIC_MAT" \
    "$restart_dir" "$vtu_dir" "$prefix" \
    "$incoming_case/export_summary.txt" "$GOM_PRODUCTION_CASE_KEY" \
    all_report_steps \
    > "$incoming_case/export.out" 2> "$incoming_case/export.err"

grep -Fxq 'status=pass' "$incoming_case/export_summary.txt"
grep -Fxq 'export_mode=all_report_steps' \
    "$incoming_case/export_summary.txt"
grep -Fxq 'selected_steps=1:210' "$incoming_case/export_summary.txt"
grep -Fxq 'vtu_files=211' "$incoming_case/export_summary.txt"
grep -Fxq 'pvd_files=1' "$incoming_case/export_summary.txt"
grep -Fxq 'additional_parameters=geology_indicators_only' \
    "$incoming_case/export_summary.txt"
grep -Fxq 'geology_indicator_schema=gom_vtu_geology_indicators_v2' \
    "$incoming_case/export_summary.txt"
grep -Fxq \
    'fault_region_flag_values=0:outside_fault,1:predict_fault,2:nonpredict_fault' \
    "$incoming_case/export_summary.txt"
grep -Fxq \
    'stratigraphy_region_flag_values=0:outside_stratigraphy,1:sand,2:clay' \
    "$incoming_case/export_summary.txt"
grep -Fxq 'pc_entry_treatment=plateau_all_active' \
    "$incoming_case/export_summary.txt"

test "$(find "$vtu_dir" -maxdepth 1 -type f -name '*.vtu' | wc -l)" -eq 211
test "$(find "$vtu_dir" -maxdepth 1 -type f -name '*.pvd' | wc -l)" -eq 1
test -s "$vtu_dir/${prefix}_incon_0001.vtu"
for step in $(seq 1 210); do
    printf -v step_text '%04d' "$step"
    test -s "$vtu_dir/${prefix}_${step_text}.vtu"
done
test -s "$vtu_dir/${prefix}.pvd"

(
    cd "$incoming_case"
    find vtu -maxdepth 1 -type f \
        \( -name '*.vtu' -o -name '*.pvd' \) -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum > VTU_SHA256.txt
    sha256sum --check VTU_SHA256.txt > VTU_CHECKSUM_VERIFICATION.log
)
test "$(grep -c ': OK$' "$incoming_case/VTU_CHECKSUM_VERIFICATION.log")" \
    -eq 212
printf 'PASS\n' > "$incoming_case/PASS"
record_exit_status

mkdir -p -- "$result_root"
test ! -e "$final_case"
mv -- "$incoming_case" "$final_case"
status_target="$final_case"
rmdir -- "$incoming_parent" 2>/dev/null || true
test -f "$final_case/PASS"
trap - EXIT
echo "Movie VTU export completed: $final_case"
