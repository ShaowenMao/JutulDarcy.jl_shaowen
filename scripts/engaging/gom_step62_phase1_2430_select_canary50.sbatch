#!/bin/bash
#SBATCH --job-name=gom_s62_can50_select
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_CANARY_WORKFLOW_REPO:?Set GOM_CANARY_WORKFLOW_REPO.}"
: "${GOM_CANARY_SELECTION_DIR:?Set GOM_CANARY_SELECTION_DIR.}"

script="$GOM_CANARY_WORKFLOW_REPO/scripts/engaging/gom_step62_phase1_2430_select_canary50.jl"
test -f "$script"
test -f "$GOM_PRODUCTION_MANIFEST"
workflow_commit="$(git -C "$GOM_CANARY_WORKFLOW_REPO" rev-parse HEAD)"
test -z "$(git -C "$GOM_CANARY_WORKFLOW_REPO" status --porcelain)" || {
    echo "Canary workflow checkout must be clean." >&2
    exit 1
}

final="$GOM_CANARY_SELECTION_DIR"
if test -e "$final"; then
    test -f "$final/PASS"
    (cd "$final" && sha256sum --check SHA256SUMS.txt)
    echo "Verified reusable-canary selection already exists: $final"
    exit 0
fi
incoming="${final}.incoming_job${SLURM_JOB_ID}"
test ! -e "$incoming"
mkdir -p "$incoming" "$(dirname -- "$final")"

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=1

julia --startup-file=no --project="$GOM_CANARY_WORKFLOW_REPO" \
    "$script" "$GOM_PRODUCTION_MANIFEST" "$incoming"

test "$(($(wc -l < "$incoming/canary50_selection.tsv") - 1))" -eq 50
test "$(($(wc -l < "$incoming/embedded24_selection.tsv") - 1))" -eq 24
test "$(($(wc -l < "$incoming/additional26_selection.tsv") - 1))" -eq 26
test "$(($(wc -l < "$incoming/taskset_plan.tsv") - 1))" -eq 49
test "$(find "$incoming/tasksets" -maxdepth 1 -type f -name 'taskset_*.tsv' | wc -l)" -eq 49
test "$(find "$incoming/tasksets" -maxdepth 1 -type f -name 'taskset_*.array.txt' | wc -l)" -eq 49
grep -Fxq 'selection_count=50' "$incoming/SELECTION_METADATA.txt"
grep -Fxq 'embedded_acceptance_count=24' "$incoming/SELECTION_METADATA.txt"
grep -Fxq 'additional_stratified_count=26' "$incoming/SELECTION_METADATA.txt"
grep -Fxq 'selection_uses_reservoir_outcomes=false' \
    "$incoming/SELECTION_METADATA.txt"
grep -Fxq 'campaign_tasks_covered_exactly_once=true' \
    "$incoming/SELECTION_METADATA.txt"
printf 'workflow_commit=%s\nselection_job_id=%s\n' \
    "$workflow_commit" "$SLURM_JOB_ID" >> "$incoming/SELECTION_METADATA.txt"
(
    cd "$incoming"
    find . -type f ! -name SHA256SUMS.txt ! -name PASS -print0 | \
        LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
printf 'PASS\n' > "$incoming/PASS"
mv -- "$incoming" "$final"
