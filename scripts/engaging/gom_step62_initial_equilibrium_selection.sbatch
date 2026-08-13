#!/bin/bash
# Rank candidate cases for the equilibrium controls without running a simulator.

#SBATCH --job-name=gom_s62_eq_select
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the checksum-pinned production manifest.}"
: "${JUTULDARCY_COMBINED_REPO:?Set the immutable production JutulDarcy repo.}"
: "${GOM_EQUILIBRIUM_DIAGNOSTIC_REPO:?Set the immutable diagnostic repo.}"
: "${GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT:?Set the diagnostic Git commit.}"
: "${GOM_EQUILIBRIUM_CANDIDATE_TASKS:?Set candidate tasks, ranges, or all.}"
: "${GOM_EQUILIBRIUM_SELECTION_OUTPUT:?Set the durable output TSV.}"

observed_commit="$(git -C "$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT"
test ! -e "$GOM_EQUILIBRIUM_SELECTION_OUTPUT" || {
    echo "Refusing to overwrite selection output: $GOM_EQUILIBRIUM_SELECTION_OUTPUT" >&2
    exit 1
}
mkdir -p "$(dirname "$GOM_EQUILIBRIUM_SELECTION_OUTPUT")"

module purge
module load community-modules
module load julia/1.10.4
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. \
    "$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO/scripts/engaging/gom_step62_initial_equilibrium_select.jl" \
    "$GOM_PRODUCTION_MANIFEST" \
    "$GOM_EQUILIBRIUM_CANDIDATE_TASKS" \
    "$GOM_EQUILIBRIUM_SELECTION_OUTPUT"
sha256sum "$GOM_EQUILIBRIUM_SELECTION_OUTPUT" \
    > "${GOM_EQUILIBRIUM_SELECTION_OUTPUT}.sha256"
