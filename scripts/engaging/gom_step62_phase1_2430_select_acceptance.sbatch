#!/bin/bash
#SBATCH --job-name=gom_s62_acc_select
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=06:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${GOM_ACCEPTANCE_WORKFLOW_REPO:?Set GOM_ACCEPTANCE_WORKFLOW_REPO.}"
: "${GOM_ACCEPTANCE_SELECTION_DIR:?Set GOM_ACCEPTANCE_SELECTION_DIR.}"

script="$GOM_ACCEPTANCE_WORKFLOW_REPO/scripts/engaging/gom_step62_phase1_2430_select_acceptance.jl"
test -f "$script"
test -f "$GOM_PRODUCTION_MANIFEST"
workflow_commit="$(git -C "$GOM_ACCEPTANCE_WORKFLOW_REPO" rev-parse HEAD)"
test -z "$(git -C "$GOM_ACCEPTANCE_WORKFLOW_REPO" status --porcelain)" || {
    echo "Acceptance workflow checkout must be clean." >&2
    exit 1
}

final="$GOM_ACCEPTANCE_SELECTION_DIR"
if test -e "$final"; then
    test -f "$final/PASS"
    (cd "$final" && sha256sum --check SHA256SUMS.txt)
    echo "Verified acceptance selection already exists: $final"
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

julia --startup-file=no --project="$GOM_ACCEPTANCE_WORKFLOW_REPO" \
    "$script" "$GOM_PRODUCTION_MANIFEST" "$incoming"

test "$(($(wc -l < "$incoming/acceptance_selection.tsv") - 1))" -eq 24
test "$(tr ',' '\n' < "$incoming/acceptance_array_spec.txt" | sed '/^$/d' | wc -l)" -eq 24
grep -Fxq 'selection_count=24' "$incoming/SELECTION_METADATA.txt"
grep -Fxq 'selection_uses_reservoir_outcomes=false' \
    "$incoming/SELECTION_METADATA.txt"
printf 'workflow_commit=%s\nselection_job_id=%s\n' \
    "$workflow_commit" "$SLURM_JOB_ID" >> "$incoming/SELECTION_METADATA.txt"
(
    cd "$incoming"
    sha256sum acceptance_selection.tsv acceptance_array_spec.txt \
        all_case_input_metrics.tsv SELECTION_METADATA.txt > SHA256SUMS.txt
    sha256sum --check SHA256SUMS.txt
)
printf 'PASS\n' > "$incoming/PASS"
mv -- "$incoming" "$final"
