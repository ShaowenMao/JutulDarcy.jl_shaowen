#!/bin/bash
# Shared fail-closed contract for schema-2 Step62 checkpoint recovery.

set -euo pipefail

: "${GOM_RECOVERY_WORKFLOW_REPO:?Set GOM_RECOVERY_WORKFLOW_REPO.}"
: "${GOM_RECOVERY_WORKFLOW_COMMIT:?Set GOM_RECOVERY_WORKFLOW_COMMIT.}"
: "${GOM_RECOVERY_PLAN:?Set GOM_RECOVERY_PLAN.}"
: "${GOM_RECOVERY_PLAN_SHA256:?Set GOM_RECOVERY_PLAN_SHA256.}"

recovery_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
recovery_plan_tool="$GOM_RECOVERY_WORKFLOW_REPO/scripts/engaging/gom_step62_production_schema2_recovery_plan.py"
command -v "$recovery_python" >/dev/null
test -f "$recovery_plan_tool"
[[ "$GOM_RECOVERY_WORKFLOW_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$GOM_RECOVERY_PLAN_SHA256" =~ ^[0-9a-f]{64}$ ]]
expected_recovery_workflow_commit="$GOM_RECOVERY_WORKFLOW_COMMIT"
expected_recovery_plan_sha256="$GOM_RECOVERY_PLAN_SHA256"
expected_recovery_plan_path="$(realpath "$GOM_RECOVERY_PLAN")"

"$recovery_python" "$recovery_plan_tool" validate \
    --plan "$GOM_RECOVERY_PLAN" >/dev/null
recovery_plan_summary="$(
    "$recovery_python" "$recovery_plan_tool" summary \
        --plan "$GOM_RECOVERY_PLAN" --format shell
)"
eval "$recovery_plan_summary"
test "$GOM_RECOVERY_PLAN_SHA256" = "$expected_recovery_plan_sha256"
test "$GOM_RECOVERY_WORKFLOW_COMMIT" = \
    "$expected_recovery_workflow_commit"
test "$(realpath "$GOM_RECOVERY_PLAN_PATH")" = \
    "$expected_recovery_plan_path"

recovery_workflow_repo="$(realpath "$GOM_RECOVERY_WORKFLOW_REPO")"
recovery_sim_repo="$(realpath "$GOM_RECOVERY_SIMULATION_REPO")"
test -z "$(git -C "$recovery_workflow_repo" status --porcelain)"
test -z "$(git -C "$recovery_sim_repo" status --porcelain)"
test "$(git -C "$recovery_workflow_repo" rev-parse HEAD)" = \
    "$GOM_RECOVERY_WORKFLOW_COMMIT"
test "$(git -C "$recovery_sim_repo" rev-parse HEAD)" = \
    "$GOM_RECOVERY_SIMULATION_COMMIT"
test "$(git -C "$recovery_workflow_repo" rev-parse HEAD:src)" = \
    "$(git -C "$recovery_sim_repo" rev-parse HEAD:src)"
cmp -s "$recovery_workflow_repo/Project.toml" \
    "$recovery_sim_repo/Project.toml"
cmp -s "$recovery_workflow_repo/Manifest.toml" \
    "$recovery_sim_repo/Manifest.toml"
test "$(sha256sum "$recovery_sim_repo/Manifest.toml" | awk '{print $1}')" = \
    "$(
        awk -F= '/^jutul_manifest_sha256 = / {
            gsub(/[ \"]/, "", $2); print $2; exit
        }' "$GOM_RECOVERY_CAMPAIGN_MANIFEST"
    )"

gom_recovery_resolve_plan_task() {
    local task="$1"
    local resolved
    resolved="$(
        "$recovery_python" "$recovery_plan_tool" resolve \
            --plan "$GOM_RECOVERY_PLAN" --task "$task" --format shell
    )"
    eval "$resolved"
    test "$GOM_RECOVERY_TASK" -eq "$task"
}

gom_recovery_load_simulation_task() {
    local task="$1"
    gom_recovery_resolve_plan_task "$task"
    export GOM_PRODUCTION_MANIFEST="$GOM_RECOVERY_CAMPAIGN_MANIFEST"
    export JUTULDARCY_COMBINED_REPO="$recovery_sim_repo"
    source \
        "$recovery_sim_repo/scripts/engaging/gom_step62_effective_pc_global_plateau_common.sh"
    gom_effective_pc_resolve_task
    gom_effective_pc_export_locked_physics
    test "$GOM_PRODUCTION_TASK" -eq "$task"
    test "$GOM_PRODUCTION_CASE_KEY" = "$GOM_RECOVERY_CASE_KEY"
    test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2
    test "$GOM_PRODUCTION_MANIFEST_SHA256" = \
        "$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256"
    test "$GOM_PRODUCTION_JUTULDARCY_COMMIT" = \
        "$GOM_RECOVERY_SIMULATION_COMMIT"
    test "$GOM_PRODUCTION_PHYSICS_PROFILE" = \
        sandpc_effective_globalplateau_v1
    test "$GOM_PRODUCTION_QOI_MODE" = required
}

gom_recovery_set_case_paths() {
    local task="$1"
    local case_key="$2"
    local source_preflight_job="$3"
    local source_full_job="$4"
    local gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
    GOM_RECOVERY_PREFLIGHT_CASE="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${source_preflight_job}/${case_key}"
    GOM_RECOVERY_FULL_ROOT="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${source_full_job}"
    GOM_RECOVERY_FULL_TAG="gom_step62_effective_pc_global_plateau_${case_key}_sandpc_effective_globalplateau_v1_full1000y_job${source_full_job}_${task}"
    GOM_RECOVERY_CASE_DIR="$GOM_RECOVERY_FULL_ROOT/$GOM_RECOVERY_FULL_TAG"
    GOM_RECOVERY_RESTART_DIR="$GOM_RECOVERY_CASE_DIR/restart"
    GOM_RECOVERY_SUMMARY_DIR="$GOM_RECOVERY_RESTART_DIR/production_output"
}

gom_recovery_validate_preflight() {
    local preflight_case="$1"
    test -f "$preflight_case/PASS"
    test -s "$preflight_case/preflight_summary.txt"
    grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
    grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq \
        "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_entry_treatment=plateau_all_active' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_plateau_active_tables=530' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_plateau_adjusted_tables=530' \
        "$preflight_case/preflight_summary.txt"
    grep -Fxq 'pc_plateau_true_zero_tables=0' \
        "$preflight_case/preflight_summary.txt"
}

gom_recovery_validate_complete_case() {
    local case_dir="$1"
    local case_key="$2"
    local restart_dir="$case_dir/restart"
    local summary_dir="$restart_dir/production_output"
    test -f "$case_dir/PASS"
    test -s "$case_dir/production_summary.txt"
    test -s "$case_dir/final_state_summary.txt"
    test -s "$case_dir/runtime_diagnostics.txt"
    test -s "$case_dir/RUN_METADATA.txt"
    test -s "$case_dir/PREFLIGHT_PC_TABLE_CONTRACT.txt"
    test -s "$case_dir/campaign.toml"
    cmp -s "$GOM_RECOVERY_CAMPAIGN_MANIFEST" "$case_dir/campaign.toml"
    grep -Fxq 'status=pass' "$case_dir/production_summary.txt"
    grep -Fxq 'physics_profile=sandpc_effective_globalplateau_v1' \
        "$case_dir/production_summary.txt"
    grep -Fxq "case_key=$case_key" "$case_dir/production_summary.txt"
    grep -Fxq \
        "campaign_manifest_sha256=$GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256" \
        "$case_dir/production_summary.txt"
    grep -Fxq 'steps_completed=210' "$case_dir/production_summary.txt"
    grep -Fxq 'summary_rows=210' "$case_dir/production_summary.txt"
    grep -Fxq 'qoi_global_rows=210' "$case_dir/production_summary.txt"
    grep -Fxq 'qoi_region_rows=14490' "$case_dir/production_summary.txt"
    grep -Fxq 'qoi_interface_rows=40530' "$case_dir/production_summary.txt"
    grep -Fxq 'retained_restart_steps=51,78,110,210' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'production_qoi_mode=required' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
        "$case_dir/production_summary.txt"
    grep -Eq '^pc_output_drainage_sha256=[0-9a-f]{64}$' \
        "$case_dir/production_summary.txt"
    grep -Fxq 'status=pass' "$case_dir/final_state_summary.txt"
    grep -Fxq 'production_qoi_mode=required' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_global_rows=210' "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_region_rows=14490' "$case_dir/final_state_summary.txt"
    grep -Fxq 'qoi_interface_rows=40530' \
        "$case_dir/final_state_summary.txt"
    grep -Fxq 'status=pass' "$case_dir/runtime_diagnostics.txt"
    test -s "$restart_dir/jutul_51.jld2"
    test -s "$restart_dir/jutul_78.jld2"
    test -s "$restart_dir/jutul_110.jld2"
    test -s "$restart_dir/jutul_210.jld2"
    test -s "$summary_dir/PRODUCTION_OUTPUT_COMPLETE.tsv"
    test -s "$summary_dir/QOI_OUTPUT_COMPLETE.tsv"
    (
        cd "$case_dir"
        sha256sum --check RETAINED_RESTART_SHA256.txt
        sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
    )
}

gom_recovery_restart_indices() {
    local restart_dir="$1"
    test -d "$restart_dir" || return 0
    find "$restart_dir" -maxdepth 1 -type f \
        -name 'jutul_*.jld2' -printf '%f\n' |
        sed -n 's/^jutul_\([0-9][0-9]*\)\.jld2$/\1/p' |
        sort -n
}

gom_recovery_named_tsv_value() {
    local path="$1"
    local requested="$2"
    awk -F '\t' -v requested="$requested" '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == requested) {
                    column = i
                    matches++
                }
            }
            next
        }
        NR == 2 {
            value = $column
            next
        }
        { extra = 1 }
        END {
            if (NR != 2 || matches != 1 || extra) exit 1
            print value
        }
    ' "$path"
}

gom_recovery_contiguous_prefix() {
    local directory="$1"
    local expected=1
    local name step
    test -d "$directory" || {
        printf '0\n'
        return 0
    }
    while IFS= read -r name; do
        step="${name#step_}"
        step="${step%.tsv}"
        step="$((10#$step))"
        test "$step" -eq "$expected" || {
            echo "Non-contiguous recovery rows in $directory:" \
                "expected $expected, observed $step." >&2
            return 1
        }
        expected=$((expected + 1))
    done < <(
        find "$directory" -maxdepth 1 -type f \
            -name 'step_[0-9][0-9][0-9][0-9][0-9][0-9].tsv' \
            -printf '%f\n' | sort
    )
    printf '%s\n' "$((expected - 1))"
}
