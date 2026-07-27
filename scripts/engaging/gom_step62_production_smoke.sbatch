#!/bin/bash
#SBATCH --job-name=gom_s62_prod_smoke
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --array=1-7%2
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=18G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_common.sh"
gom_production_resolve_task
gom_production_export_locked_physics

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
result_root="$gom_root/results/gom_step62_production_smoke_job${SLURM_ARRAY_JOB_ID}"
case_tag="$(gom_production_case_tag smoke3)"
case_dir="$result_root/$case_tag"
restart_dir="$case_dir/restart"
summary_dir="$restart_dir/production_output"
mkdir -p "$case_dir"
exec 9> "$case_dir/.production-output.lock"
flock -n 9 || {
    echo "Another writer already owns $case_dir." >&2
    exit 1
}

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$case_dir/exit_status.txt"
}
trap record_exit_status EXIT

export REPO_ROOT="$JUTULDARCY_COMBINED_REPO"
export CASE_LABEL="$GOM_PRODUCTION_CASE_KEY"
export CASE_TAG="$case_tag"
export RUN_ROOT="$result_root"
export PRODUCTION_SUMMARY_DIR="$summary_dir"
export STOP_AFTER_REPORT_STEP=2
unset RESTART_STEP

gom_production_write_metadata "$case_dir/RUN_METADATA.txt" smoke3
cp -- "$GOM_PRODUCTION_MANIFEST_PATH" "$case_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST_COMPANION_PATH" \
    "$case_dir/campaign.toml.sha256.original"

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

test -s "$restart_dir/jutul_1.jld2"
test -s "$restart_dir/jutul_2.jld2"
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 2

export RESTART_RUN=true
export STOP_AFTER_REPORT_STEP=3
SLURM_JOB_NAME="${SLURM_JOB_NAME}_resume" \
    bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"

mapfile -t restart_names < <(
    find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' \
        -printf '%f\n' | sort -V
)
test "${#restart_names[@]}" -eq 2
test "${restart_names[0]}" = jutul_2.jld2
test "${restart_names[1]}" = jutul_3.jld2
test "$(find "$summary_dir/rows" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 3
test "$(find "$summary_dir/retention" -maxdepth 1 -type f \
    -name 'step_*.tsv' | wc -l)" -eq 3
test -s "$summary_dir/rows/step_000001.tsv"
test -s "$summary_dir/rows/step_000002.tsv"
test -s "$summary_dir/rows/step_000003.tsv"
test ! -e "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
test -s "$summary_dir/report_steps.tsv"
test "$(wc -l < "$summary_dir/report_steps.tsv")" -eq 4

# One established case and one newly added case also receive an independent,
# uninterrupted three-step control. Array tasks 1 and 5 therefore prove that
# interruption/restart is numerically equivalent on both input cohorts.
restart_equivalence=not_selected
if [ "$SLURM_ARRAY_TASK_ID" -eq 1 ] || \
   [ "$SLURM_ARRAY_TASK_ID" -eq 5 ]; then
    control_tag="$(gom_production_case_tag smoke3_control)"
    control_dir="$result_root/$control_tag"
    control_restart_dir="$control_dir/restart"
    export CASE_TAG="$control_tag"
    export PRODUCTION_SUMMARY_DIR="$control_restart_dir/production_output"
    export RESTART_RUN=false
    export STOP_AFTER_REPORT_STEP=3
    SLURM_JOB_NAME="${SLURM_JOB_NAME}_control" \
        bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_sampling_cases.sbatch"
    test -s "$control_restart_dir/jutul_3.jld2"
    compare_script="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_restart_compare.jl"
    test -f "$compare_script"
    module purge
    module load community-modules
    module load julia/1.10.4
    cd "$JUTULDARCY_COMBINED_REPO"
    julia --startup-file=no --project=. "$compare_script" \
        "$restart_dir" "$control_restart_dir" 3 \
        "$case_dir/restart_equivalence_summary.txt"
    grep -Fxq 'status=pass' \
        "$case_dir/restart_equivalence_summary.txt"
    restart_equivalence=pass
fi

printf '%s\n' \
    "status=pass" \
    "case_key=$GOM_PRODUCTION_CASE_KEY" \
    "reports_completed=3" \
    "summary_rows=3" \
    "consolidated_summary_rows=3" \
    "rolling_checkpoints=2,3" \
    "restart_equivalence=$restart_equivalence" \
    "production_output_mode=true" \
    > "$case_dir/smoke_summary.txt"
printf 'PASS\n' > "$case_dir/PASS"
