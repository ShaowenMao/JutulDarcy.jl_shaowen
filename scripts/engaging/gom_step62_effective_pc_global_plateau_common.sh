#!/bin/bash
# Opt-in Step62 effective-saturation Pc / global-entry-plateau workflow.
# The accepted seven-case production functions are sourced, never replaced.

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_common.sh"

readonly GOM_EFFECTIVE_PC_PHYSICS_PROFILE=sandpc_effective_globalplateau_v1
readonly GOM_EFFECTIVE_PC_RESULT_PREFIX=gom_step62_effective_pc_global_plateau

gom_effective_pc_task_set() {
    local task_set="${GOM_EFFECTIVE_PC_TASK_SET:-5:6:7}"
    case "$task_set" in
        1|5:6:7|1:5:6:7)
            printf '%s\n' "$task_set"
            ;;
        *)
            echo "GOM_EFFECTIVE_PC_TASK_SET must be 1, 5:6:7, or" \
                "1:5:6:7; got '$task_set'." >&2
            return 1
            ;;
    esac
}

gom_effective_pc_selected_tasks() {
    case "$(gom_effective_pc_task_set)" in
        1) printf '%s\n' 1 ;;
        5:6:7) printf '%s\n' 5 6 7 ;;
        1:5:6:7) printf '%s\n' 1 5 6 7 ;;
    esac
}

gom_effective_pc_slurm_array_spec() {
    case "$(gom_effective_pc_task_set)" in
        1) printf '%s\n' 1 ;;
        5:6:7) printf '%s\n' 5-7 ;;
        1:5:6:7) printf '%s\n' 1,5-7 ;;
    esac
}

gom_effective_pc_selected_case_count() {
    case "$(gom_effective_pc_task_set)" in
        1) printf '%s\n' 1 ;;
        5:6:7) printf '%s\n' 3 ;;
        1:5:6:7) printf '%s\n' 4 ;;
    esac
}

gom_effective_pc_first_task() {
    case "$(gom_effective_pc_task_set)" in
        1|1:5:6:7) printf '%s\n' 1 ;;
        5:6:7) printf '%s\n' 5 ;;
    esac
}

gom_effective_pc_task_is_selected() {
    local requested="$1"
    local task_set
    task_set="$(gom_effective_pc_task_set)"
    case "$task_set:$requested" in
        1:1|5:6:7:5|5:6:7:6|5:6:7:7|\
        1:5:6:7:1|1:5:6:7:5|1:5:6:7:6|1:5:6:7:7)
            return 0
            ;;
        *)
            echo "Task $requested is not selected by" \
                "GOM_EFFECTIVE_PC_TASK_SET='$task_set'." >&2
            return 1
            ;;
    esac
}

gom_effective_pc_validate_campaign() {
    if test "${GOM_PRODUCTION_SCHEMA_VERSION:-1}" -eq 2; then
        test "$GOM_PRODUCTION_PHYSICS_PROFILE" = \
            "$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" || {
            echo "Schema-2 campaign selected the wrong physics profile:" \
                "$GOM_PRODUCTION_PHYSICS_PROFILE" >&2
            return 1
        }
        return 0
    fi
    case "$GOM_PRODUCTION_CAMPAIGN_ID" in
        *sandpc*ycap50*effective*globalplateau*) ;;
        *)
            echo "Campaign ID must contain sandpc, ycap50, effective, and" \
                "globalplateau; got" \
                "'$GOM_PRODUCTION_CAMPAIGN_ID'." >&2
            return 1
            ;;
    esac
}

gom_effective_pc_resolve_task() {
    gom_production_resolve_task
    gom_effective_pc_validate_campaign
    if test "$GOM_PRODUCTION_SCHEMA_VERSION" -eq 2; then
        return 0
    fi
    case "$GOM_PRODUCTION_TASK" in
        1|5|6|7) ;;
        *)
            echo "This workflow intentionally permits only canonical tasks" \
                "1, 5, 6, and 7." >&2
            return 1
            ;;
    esac
    gom_effective_pc_task_is_selected "$GOM_PRODUCTION_TASK"
}

gom_effective_pc_export_locked_physics() {
    # Legacy schema-1 effective-Pc campaigns predate a manifest-level profile
    # field. Promote the specialized workflow identity before importing the
    # shared settings; schema-2 manifests already resolve to this same value.
    export GOM_PRODUCTION_PHYSICS_PROFILE="$GOM_EFFECTIVE_PC_PHYSICS_PROFILE"
    gom_production_export_locked_physics
    # Override the accepted PREDICT-only treatment after importing the
    # locked production defaults. The new mode covers every active drainage
    # saturation region and does not use FAULT_PC_ENTRY_SG_MAX.
    export FAULT_PC_ENTRY_TREATMENT=plateau_all_active
    unset FAULT_PC_ENTRY_SG_MAX
    export PRODUCTION_QOI_MODE=required
}

gom_effective_pc_case_tag() {
    phase="$1"
    printf '%s_%s_%s_%s_job%s_%s' \
        "$GOM_EFFECTIVE_PC_RESULT_PREFIX" \
        "$GOM_PRODUCTION_CASE_KEY" \
        "$GOM_EFFECTIVE_PC_PHYSICS_PROFILE" \
        "$phase" \
        "$SLURM_ARRAY_JOB_ID" \
        "$SLURM_ARRAY_TASK_ID"
}

gom_effective_pc_write_metadata() {
    destination="$1"
    phase="$2"
    gom_production_write_metadata "$destination" "$phase"
    # Replace the two inherited PREDICT-only keys instead of appending
    # duplicate keys. Downstream metadata readers intentionally reject
    # duplicates.
    sed -i \
        -e 's/^fault_pc_entry_treatment=.*/fault_pc_entry_treatment=plateau_all_active/' \
        -e '/^fault_pc_entry_sg_max=/d' \
        "$destination"
    printf '%s\n' \
        "physics_workflow=effective_pc_global_plateau_v1" \
        "pc_mapping_schema=gom_effective_saturation_pc_v1" \
        "pc_mapping_method=entry_renormalized_analytic_brooks_corey" \
        "pc_saturation_coordinate=effective_gas_saturation" \
        "pc_reference_swi=0.05" \
        "pc_host_target_swi=0.3092" \
        "pc_nonpredict_target_swi=0.3696" \
        "pc_reference_prescale_cap_Pa=1100000" \
        "pc_reference_cap_order=reference_before_leverett" \
        "pc_entry_scope=all_active_drainage" \
        "pc_entry_rule=first_strictly_positive_pc_node" \
        "pc_entry_expected_active_tables=530" \
        "pc_entry_expected_adjusted_tables=530" \
        "pc_entry_expected_true_zero_tables=0" \
        "pc_reference=sand_theta30" \
        "host_pc_scaling=leverett_kv" \
        "nonpredict_pc_scaling=leverett_local_kzz" \
        "younger_nonpredict_local_perm_md=50,500,500" \
        "base_saturation_regions=8" \
        "explicit_predict_regions=522" \
        "drainage_saturation_regions=530" \
        "total_sgof_tables=1060" \
        "old_restart_reuse=false" \
        >> "$destination"
}
