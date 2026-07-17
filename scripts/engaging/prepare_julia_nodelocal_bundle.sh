#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J julia_bundle
#SBATCH -c 1
#SBATCH --mem=8G
#SBATCH -t 01:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%j.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%j.err

set -euo pipefail

module purge
module load community-modules
module load julia/1.10.4

BUNDLE_ROOT=${BUNDLE_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/immutable_bundles}
BUNDLE_TAG=${BUNDLE_TAG:-julia-1.10.4_$(date +%Y%m%dT%H%M%S)}
DEPOT_SOURCE=${DEPOT_SOURCE:-$HOME/.julia}
SOURCE_REPO_ROOT=${SOURCE_REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
MANIFEST_SOURCE=${MANIFEST_SOURCE:-$SOURCE_REPO_ROOT/Manifest.toml}
BUNDLE_DIR="$BUNDLE_ROOT/$BUNDLE_TAG"
RUNTIME_ARCHIVE="$BUNDLE_DIR/julia-runtime.tar"
DEPOT_ARCHIVE="$BUNDLE_DIR/julia-depot.tar"
BUNDLE_MANIFEST="$BUNDLE_DIR/Manifest.toml"

if [ -e "$BUNDLE_DIR" ]; then
    echo "Refusing to replace existing bundle directory: $BUNDLE_DIR"
    exit 1
fi
if [ ! -d "$DEPOT_SOURCE" ]; then
    echo "Julia depot does not exist: $DEPOT_SOURCE"
    exit 1
fi
if [ ! -f "$MANIFEST_SOURCE" ]; then
    echo "Project manifest does not exist: $MANIFEST_SOURCE"
    exit 1
fi

JULIA_BIN=$(readlink -f "$(command -v julia)")
JULIA_ROOT=$(dirname "$(dirname "$JULIA_BIN")")
if [ ! -x "$JULIA_ROOT/bin/julia" ]; then
    echo "Could not determine the Julia runtime root from $JULIA_BIN"
    exit 1
fi

mkdir -p "$BUNDLE_DIR"

LOG_DIR="$BUNDLE_DIR/logs"
mkdir -p "$LOG_DIR"
STDOUT_PATH="$LOG_DIR/slurm-${SLURM_JOB_NAME:-julia_bundle}-${SLURM_JOB_ID:-manual}.out"
STDERR_PATH="$LOG_DIR/slurm-${SLURM_JOB_NAME:-julia_bundle}-${SLURM_JOB_ID:-manual}.err"
BOOTSTRAP_STDOUT="$BUNDLE_ROOT/../slurm-bootstrap-${SLURM_JOB_NAME:-julia_bundle}-${SLURM_JOB_ID:-manual}.out"
BOOTSTRAP_STDERR="$BUNDLE_ROOT/../slurm-bootstrap-${SLURM_JOB_NAME:-julia_bundle}-${SLURM_JOB_ID:-manual}.err"
exec > "$STDOUT_PATH" 2> "$STDERR_PATH"
for bootstrap_path in "$BOOTSTRAP_STDOUT" "$BOOTSTRAP_STDERR"; do
    if [ -f "$bootstrap_path" ]; then
        mv -f "$bootstrap_path" "$LOG_DIR/"
    fi
done

echo "===== NODE-LOCAL JULIA BUNDLE ====="
echo "hostname=$(hostname)"
echo "date=$(date --iso-8601=seconds)"
echo "JULIA_BIN=$JULIA_BIN"
echo "JULIA_ROOT=$JULIA_ROOT"
echo "DEPOT_SOURCE=$DEPOT_SOURCE"
echo "MANIFEST_SOURCE=$MANIFEST_SOURCE"
echo "BUNDLE_DIR=$BUNDLE_DIR"
df -h "$BUNDLE_ROOT"
echo "==================================="

tar -cf "$RUNTIME_ARCHIVE" -C "$JULIA_ROOT" .
tar -cf "$DEPOT_ARCHIVE" -C "$DEPOT_SOURCE" .
cp -p "$MANIFEST_SOURCE" "$BUNDLE_MANIFEST"

(
    cd "$BUNDLE_DIR"
    sha256sum "$(basename "$RUNTIME_ARCHIVE")" > "$(basename "$RUNTIME_ARCHIVE").sha256"
    sha256sum "$(basename "$DEPOT_ARCHIVE")" > "$(basename "$DEPOT_ARCHIVE").sha256"
    sha256sum "$(basename "$BUNDLE_MANIFEST")" > "$(basename "$BUNDLE_MANIFEST").sha256"
    sha256sum -c "$(basename "$RUNTIME_ARCHIVE").sha256"
    sha256sum -c "$(basename "$DEPOT_ARCHIVE").sha256"
    sha256sum -c "$(basename "$BUNDLE_MANIFEST").sha256"
)

chmod 0444 "$RUNTIME_ARCHIVE" "$RUNTIME_ARCHIVE.sha256" "$DEPOT_ARCHIVE" "$DEPOT_ARCHIVE.sha256" "$BUNDLE_MANIFEST" "$BUNDLE_MANIFEST.sha256"

du -sh "$BUNDLE_DIR"
echo "JULIA_RUNTIME_ARCHIVE=$RUNTIME_ARCHIVE"
echo "JULIA_DEPOT_ARCHIVE=$DEPOT_ARCHIVE"
echo "BUNDLE_MANIFEST=$BUNDLE_MANIFEST"
