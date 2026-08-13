#!/bin/bash
# Diagnose whether the imported all-brine state is a discrete Jutul equilibrium.
# This is intentionally separate from all production and restart workflows.

#SBATCH --job-name=gom_s62_equilibrium
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the checksum-pinned production manifest.}"
: "${JUTULDARCY_COMBINED_REPO:?Set the immutable production JutulDarcy repo.}"
: "${GOM_EQUILIBRIUM_DIAGNOSTIC_REPO:?Set the immutable diagnostic repo.}"
: "${GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT:?Set the diagnostic Git commit.}"
: "${GOM_EQUILIBRIUM_RESULT_ROOT:?Set the durable diagnostic result root.}"
: "${GOM_EQUILIBRIUM_RUN_ID:?Set a unique diagnostic run ID.}"
: "${SLURM_ARRAY_TASK_ID:?Submit this file as a Slurm array.}"

production_common="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
diagnostic_script="$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO/scripts/engaging/gom_step62_initial_equilibrium_audit.jl"
simulation_repo="${GOM_EQUILIBRIUM_SIMULATION_REPO:-$JUTULDARCY_COMBINED_REPO}"
test -f "$production_common"
test -f "$diagnostic_script"
test -f "$simulation_repo/Project.toml"
test -f "$simulation_repo/Manifest.toml"

observed_diagnostic_commit="$(
    git -C "$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO" rev-parse HEAD
)"
test "$observed_diagnostic_commit" = "$GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT" || {
    echo "Diagnostic commit mismatch: expected $GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT, observed $observed_diagnostic_commit" >&2
    exit 1
}

simulation_commit="$(git -C "$simulation_repo" rev-parse HEAD)"
test -z "$(git -C "$simulation_repo" status --porcelain --untracked-files=no)" || {
    echo "Simulation repository tracked files must be clean." >&2
    exit 1
}

source "$production_common"
gom_effective_pc_resolve_task
gom_effective_pc_export_locked_physics

simulation_manifest_sha256="$(sha256sum "$simulation_repo/Manifest.toml" | awk '{print $1}')"
test "$simulation_manifest_sha256" = "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" || {
    echo "Simulation Manifest.toml differs from the checksum-pinned production environment." >&2
    exit 1
}

final_dir="$GOM_EQUILIBRIUM_RESULT_ROOT/$GOM_EQUILIBRIUM_RUN_ID/$GOM_PRODUCTION_CASE_KEY"
test ! -e "$final_dir" || {
    echo "Refusing to overwrite an equilibrium result: $final_dir" >&2
    exit 1
}
mkdir -p "$(dirname "$final_dir")"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/gom-equilibrium-${SLURM_JOB_ID}-${SLURM_ARRAY_TASK_ID}-XXXXXX")"
stage_result="$stage_root/result"
publish_partial="${final_dir}.partial.${SLURM_JOB_ID}"
cleanup() {
    exit_code=$?
    rm -rf -- "$stage_root"
    if test "$exit_code" -ne 0; then
        rm -rf -- "$publish_partial"
    fi
    exit "$exit_code"
}
trap cleanup EXIT
mkdir -p "$stage_result"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
export JULIA_NUM_GC_THREADS=1
export HYPRE_THREADS="${SLURM_CPUS_PER_TASK:-8}"

started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cd "$simulation_repo"
julia --startup-file=no --project=. "$diagnostic_script" \
    "$GOM_PRODUCTION_COMMON_MAT" \
    "$GOM_PRODUCTION_SPECIFIC_MAT" \
    "$stage_result" \
    "$GOM_PRODUCTION_CASE_KEY" \
    "$GOM_PRODUCTION_GEOLOGY_ID" \
    "$GOM_PRODUCTION_REALIZATION_ID" \
    "$GOM_PRODUCTION_GEOLOGY_HASH" \
    "$GOM_PRODUCTION_LEVEL3_CASE_NAME" \
    "$GOM_PRODUCTION_MANIFEST_SHA256" \
    "$GOM_PRODUCTION_COMMON_SHA256" \
    "$GOM_PRODUCTION_SPECIFIC_SHA256"

test -s "$stage_result/COMPLETE"
test -s "$stage_result/equilibrium_summary.txt"
test -s "$stage_result/initial_import_pressure_audit.tsv"
test -s "$stage_result/liquid_face_equilibrium.tsv"
test -s "$stage_result/zero_injection_state_evolution.tsv"

cat > "$stage_result/RUN_METADATA.txt" <<EOF
status=complete
started_utc=$started_utc
finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
job_id=$SLURM_JOB_ID
array_job_id=$SLURM_ARRAY_JOB_ID
array_task_id=$SLURM_ARRAY_TASK_ID
node=$SLURMD_NODENAME
campaign_manifest=$GOM_PRODUCTION_MANIFEST_PATH
campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256
production_jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT
production_jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256
simulation_repo=$simulation_repo
simulation_commit=$simulation_commit
simulation_manifest_sha256=$simulation_manifest_sha256
diagnostic_commit=$GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT
case_key=$GOM_PRODUCTION_CASE_KEY
geology_id=$GOM_PRODUCTION_GEOLOGY_ID
geology_hash=$GOM_PRODUCTION_GEOLOGY_HASH
realization_id=$GOM_PRODUCTION_REALIZATION_ID
level3_case_name=$GOM_PRODUCTION_LEVEL3_CASE_NAME
common_mat_sha256=$GOM_PRODUCTION_COMMON_SHA256
specific_mat_sha256=$GOM_PRODUCTION_SPECIFIC_SHA256
report_years=${GOM_EQUILIBRIUM_REPORT_YEARS:-default}
initial_pressure_mode=${GOM_EQUILIBRIUM_PRESSURE_MODE:-imported}
cpus=${SLURM_CPUS_PER_TASK:-unknown}
memory=${SLURM_MEM_PER_NODE:-unknown}
EOF

(
    cd "$stage_result"
    sha256sum \
        COMPLETE \
        RUN_METADATA.txt \
        equilibrium_summary.txt \
        initial_import_pressure_audit.tsv \
        liquid_face_equilibrium.tsv \
        zero_injection_state_evolution.tsv \
        > SHA256SUMS
    sha256sum --check SHA256SUMS
)

test ! -e "$publish_partial"
mkdir -p "$publish_partial"
cp -a "$stage_result/." "$publish_partial/"
(
    cd "$publish_partial"
    sha256sum --check SHA256SUMS
)
mv -- "$publish_partial" "$final_dir"
echo "GOM_STEP62_EQUILIBRIUM_PUBLISHED=$final_dir"
