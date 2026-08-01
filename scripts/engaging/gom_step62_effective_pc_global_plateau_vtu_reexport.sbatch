#!/bin/bash
# Visualization-only re-export for a completed immutable campaign. The
# simulation repository remains the manifest/project authority; a newer,
# separately pinned repository supplies only the VTU exporter.
#SBATCH --job-name=gom_s62_epc_vtu_v2
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=7
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the original immutable campaign manifest.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set the original full-array job ID.}"
: "${GOM_EFFECTIVE_PC_TASK_SET:?Set the exact original task set.}"
: "${GOM_EFFECTIVE_PC_SIMULATION_REPO:?Set the original simulation repository.}"
: "${GOM_EFFECTIVE_PC_VTU_REPO:?Set the clean VTU-export repository.}"
: "${GOM_EFFECTIVE_PC_VTU_COMMIT:?Set the exact VTU-export commit.}"

[[ "$GOM_PRODUCTION_FULL_JOB_ID" =~ ^[0-9]+$ ]] ||
    { echo "GOM_PRODUCTION_FULL_JOB_ID must be numeric." >&2; exit 1; }
[[ "$GOM_EFFECTIVE_PC_VTU_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    {
        echo "GOM_EFFECTIVE_PC_VTU_COMMIT must be a full SHA-1." >&2
        exit 1
    }

simulation_repo="$(realpath "$GOM_EFFECTIVE_PC_SIMULATION_REPO")"
vtu_repo="$(realpath "$GOM_EFFECTIVE_PC_VTU_REPO")"
test -z "$(git -C "$simulation_repo" status --porcelain)"
test -z "$(git -C "$vtu_repo" status --porcelain)"
test "$(git -C "$vtu_repo" rev-parse HEAD)" = \
    "$GOM_EFFECTIVE_PC_VTU_COMMIT"
test -s "$simulation_repo/Manifest.toml"
test -s "$vtu_repo/Manifest.toml"
cmp -s "$simulation_repo/Project.toml" "$vtu_repo/Project.toml"
cmp -s "$simulation_repo/Manifest.toml" "$vtu_repo/Manifest.toml"

# Re-exporting must not silently change simulation code or the locked
# effective-Pc contract.
simulation_commit="$(git -C "$simulation_repo" rev-parse HEAD)"
test "$(git -C "$simulation_repo" rev-parse "$simulation_commit:src")" = \
    "$(git -C "$vtu_repo" rev-parse "$GOM_EFFECTIVE_PC_VTU_COMMIT:src")"
cmp -s \
    "$simulation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_contract.jl" \
    "$vtu_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_contract.jl"

export JUTULDARCY_COMBINED_REPO="$simulation_repo"
source \
    "$simulation_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
gom_effective_pc_resolve_task
export PRODUCTION_QOI_MODE=required

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
full_tag="$(
    SLURM_ARRAY_JOB_ID="$GOM_PRODUCTION_FULL_JOB_ID" \
        gom_effective_pc_case_tag full1000y
)"
source_case="$full_root/$full_tag"
restart_dir="$source_case/restart"
result_root="$gom_root/results/gom_step62_effective_pc_global_plateau_vtu_geology_v2_job${SLURM_ARRAY_JOB_ID}"
case_dir="$result_root/$GOM_PRODUCTION_CASE_KEY"
vtu_dir="$case_dir/vtu"
prefix="gom_step62_effective_pc_global_plateau_${GOM_PRODUCTION_CASE_KEY}_geology_v2"
script="$vtu_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.jl"
test ! -e "$case_dir" || {
    echo "Refusing to reuse an existing VTU directory: $case_dir" >&2
    exit 1
}
mkdir -p "$vtu_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

test -f "$source_case/PASS"
grep -Fxq 'status=pass' "$source_case/production_summary.txt"
grep -Fxq "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "$source_case/production_summary.txt"
grep -Fxq "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "$source_case/production_summary.txt"
grep -Fxq 'steps_completed=210' "$source_case/production_summary.txt"
grep -Fxq 'production_qoi_mode=required' \
    "$source_case/production_summary.txt"
grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
    "$source_case/production_summary.txt"
test -s "$restart_dir/jutul_78.jld2"
test -s "$restart_dir/jutul_210.jld2"
(
    cd "$source_case"
    sha256sum --check RETAINED_RESTART_SHA256.txt
    sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
)

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
export JULIA_NUM_GC_THREADS=1
export OPENBLAS_NUM_THREADS=1

cd "$vtu_repo"
julia --startup-file=no test/engaging_script_compat.jl \
    > "$case_dir/engaging_script_compatibility_test.txt"
gom_effective_pc_write_metadata "$case_dir/EXPORT_METADATA.txt" vtu_reexport
printf '%s\n' \
    "source_full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
    "source_case=$source_case" \
    "simulation_commit=$simulation_commit" \
    "vtu_export_commit=$GOM_EFFECTIVE_PC_VTU_COMMIT" \
    "geology_indicator_schema=gom_vtu_geology_indicators_v2" \
    >> "$case_dir/EXPORT_METADATA.txt"
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

julia --startup-file=no --project="$simulation_repo" "$script" \
    "$GOM_PRODUCTION_COMMON_MAT" "$GOM_PRODUCTION_SPECIFIC_MAT" \
    "$restart_dir" "$vtu_dir" "$prefix" "$case_dir/export_summary.txt" \
    "$GOM_PRODUCTION_CASE_KEY" \
    > "$case_dir/export.out" 2> "$case_dir/export.err"

summary="$case_dir/export_summary.txt"
grep -Fxq 'status=pass' "$summary"
grep -Fxq "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" "$summary"
grep -Fxq "case_id=$GOM_PRODUCTION_CASE_KEY" "$summary"
grep -Fxq 'vtu_files=3' "$summary"
grep -Fxq 'selected_steps=78,210' "$summary"
grep -Fxq 'geology_indicator_schema=gom_vtu_geology_indicators_v2' "$summary"
grep -Fxq \
    'fault_region_flag_values=0:outside_fault,1:predict_fault,2:nonpredict_fault' \
    "$summary"
grep -Fxq \
    'stratigraphy_region_flag_values=0:outside_stratigraphy,1:sand,2:clay' \
    "$summary"
grep -Fxq 'fault_region_cells=150597' "$summary"
grep -Fxq 'specific_fault_cells=32190' "$summary"
grep -Fxq 'predict_fault_cells=32190' "$summary"
grep -Fxq 'nonpredict_fault_cells=118407' "$summary"
grep -Fxq 'stratigraphy_region_cells=828240' "$summary"
sand_cells="$(awk -F= '/^stratigraphy_sand_cells=/{print $2}' "$summary")"
clay_cells="$(awk -F= '/^stratigraphy_clay_cells=/{print $2}' "$summary")"
[[ "$sand_cells" =~ ^[1-9][0-9]*$ ]]
[[ "$clay_cells" =~ ^[1-9][0-9]*$ ]]
test "$((sand_cells + clay_cells))" -eq 828240
grep -Eq '^fault_region_flag_sha256=[0-9a-f]{64}$' "$summary"
grep -Eq '^stratigraphy_region_flag_sha256=[0-9a-f]{64}$' "$summary"
grep -Fxq 'pc_entry_treatment=plateau_all_active' "$summary"
grep -Fxq 'pc_entry_scope=all_active_drainage' "$summary"

test -s "$vtu_dir/${prefix}_incon_0001.vtu"
test -s "$vtu_dir/${prefix}_0078.vtu"
test -s "$vtu_dir/${prefix}_0210.vtu"
test -s "$vtu_dir/${prefix}.pvd"
(
    cd "$case_dir"
    sha256sum \
        "vtu/${prefix}_incon_0001.vtu" \
        "vtu/${prefix}_0078.vtu" \
        "vtu/${prefix}_0210.vtu" \
        "vtu/${prefix}.pvd" \
        > VTU_SHA256.txt
    sha256sum --check VTU_SHA256.txt
)
printf 'PASS\n' > "$case_dir/PASS"
