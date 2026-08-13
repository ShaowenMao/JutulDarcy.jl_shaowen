#!/bin/bash
#SBATCH --job-name=gom_s62_epc_check
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
result_dir="$gom_root/results/gom_step62_effective_pc_global_plateau_campaign_check_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

command -v "$production_python" >/dev/null
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
    validate --json > "$result_dir/validated_manifest.json"
"$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" validate \
    > "$result_dir/validation.txt"
declare -A legacy_expected_case_keys=(
    [1]=s05_c012_case01
    [5]=s03_c001_case04
    [6]=s03_c012_case08
    [7]=s04_c024_case03
)
task_set="$(gom_effective_pc_task_set)"
selected_case_count="$(gom_effective_pc_selected_case_count)"
durable_input_root=""
while IFS= read -r task; do
    resolved_case="$(
        "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell
    )"
    eval "$resolved_case"
    gom_effective_pc_validate_campaign
    if [ "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 1 ]; then
        test "$GOM_PRODUCTION_CASE_COUNT" -eq 7
        expected_case_key="${legacy_expected_case_keys[$task]}"
    else
        # Production acceptance tasks are canonical manifest positions, not
        # positions in the legacy seven-case pilot.
        zero_based_task=$((task - 1))
        campaign_identity="$GOM_PRODUCTION_SCHEMA_VERSION:$GOM_PRODUCTION_ENSEMBLE_KIND:$GOM_PRODUCTION_CASE_COUNT"
        case "$campaign_identity" in
            2:full_1620:1620)
                scenario=$((zero_based_task / 270 + 1))
                within_scenario=$((zero_based_task % 270))
                geology=$((within_scenario / 10 + 1))
                realization=$((within_scenario % 10 + 1))
                ;;
            3:phase1_2430:2430)
                phase1_case_ids=(1 2 3 4 5 6 7 8 9 10 11 12 101 102 103)
                scenario=$((zero_based_task / 405 + 1))
                within_scenario=$((zero_based_task % 405))
                geology=$((within_scenario / 15 + 1))
                realization="${phase1_case_ids[$((within_scenario % 15))]}"
                test "$GOM_PRODUCTION_QOI_SCHEMA_VERSION" -eq 4
                ;;
            *)
                echo "Unsupported production campaign identity." >&2
                exit 1
                ;;
        esac
        printf -v expected_case_key 's%02d_c%03d_case%02d' \
            "$scenario" "$geology" "$realization"
    fi
    test "$GOM_PRODUCTION_CASE_KEY" = "$expected_case_key"
    archive_root="$(realpath -m "$GOM_PRODUCTION_ARCHIVE_ROOT")"
    for input_path in \
        "$GOM_PRODUCTION_COMMON_MAT" \
        "$GOM_PRODUCTION_SPECIFIC_MAT"
    do
        durable_input="$(realpath "$input_path")"
        case "$durable_input" in
            "$archive_root"/*) ;;
            *)
                echo "Campaign input is not on durable storage:" \
                    "$durable_input" >&2
                exit 1
                ;;
        esac
    done
    if [[ -z "$durable_input_root" ]]; then
        durable_input_root="$(dirname "$GOM_PRODUCTION_COMMON_MAT")"
    else
        test "$(dirname "$GOM_PRODUCTION_COMMON_MAT")" = \
            "$durable_input_root"
    fi
done < <(gom_effective_pc_selected_tasks)
observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT"
observed_manifest_sha256="$(
    sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" | awk '{print $1}'
)"
test "$observed_manifest_sha256" = \
    "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256"

# Parse every Engaging Julia entry point with the exact production runtime
# before an expensive simulation is eligible to start.
module purge
module load community-modules
module load julia/1.10.4
julia --version > "$result_dir/julia_version.txt"
grep -Fxq 'julia version 1.10.4' "$result_dir/julia_version.txt"
cd "$JUTULDARCY_COMBINED_REPO"
julia --startup-file=no --project=. test/engaging_script_compat.jl \
    > "$result_dir/engaging_script_compatibility_test.txt"

cp -- "$GOM_PRODUCTION_MANIFEST" "$result_dir/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$result_dir/campaign.toml.sha256.original"
(
    cd "$result_dir"
    sha256sum campaign.toml > campaign.toml.sha256
    sha256sum --check campaign.toml.sha256
)
printf '%s\n' \
    "status=pass" \
    "physics_profile=$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "manifest_case_count=$GOM_PRODUCTION_CASE_COUNT" \
    "selected_case_count=$selected_case_count" \
    "case_tasks=$task_set" \
    "durable_input_root=$durable_input_root" \
    "durable_input_paths_verified=true" \
    "pc_mapping_schema=gom_effective_saturation_pc_v1" \
    "pc_entry_treatment=plateau_all_active" \
    "pc_entry_scope=all_active_drainage" \
    "pc_entry_rule=first_strictly_positive_pc_node" \
    "exact_paths=true" \
    "wildcards=false" \
    "all_input_sha256_verified=true" \
    "cluster_julia_version=1.10.4" \
    "engaging_script_compatibility_test=pass" \
    "old_restart_reuse=false" \
    "source_input_manifest_sha256=$GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256" \
    "mrst_prepare_commit=$GOM_PRODUCTION_MRST_PREPARE_COMMIT" \
    "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
    "jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
    > "$result_dir/campaign_check_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
