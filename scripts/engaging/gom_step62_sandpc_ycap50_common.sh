#!/bin/bash
# Opt-in Step62 sand-Pc / non-PREDICT Younger-cap50 workflow.
# The accepted seven-case production functions are sourced, never replaced.

set -euo pipefail

: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
source \
    "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_common.sh"

readonly GOM_SANDPC_PHYSICS_PROFILE=sandpc_ycap50_v1
readonly GOM_SANDPC_RESULT_PREFIX=gom_step62_sandpc_ycap50

gom_sandpc_validate_campaign() {
    case "$GOM_PRODUCTION_CAMPAIGN_ID" in
        *sandpc*ycap50*) ;;
        *)
            echo "Campaign ID must explicitly contain sandpc and ycap50; got" \
                "'$GOM_PRODUCTION_CAMPAIGN_ID'." >&2
            return 1
            ;;
    esac
}

gom_sandpc_resolve_task() {
    gom_production_resolve_task
    gom_sandpc_validate_campaign
    case "$GOM_PRODUCTION_TASK" in
        5|6|7) ;;
        *)
            echo "This campaign intentionally permits only tasks 5, 6, and 7." >&2
            return 1
            ;;
    esac
}

gom_sandpc_export_locked_physics() {
    gom_production_export_locked_physics
    export PRODUCTION_QOI_MODE=required
}

gom_sandpc_case_tag() {
    phase="$1"
    printf '%s_%s_%s_%s_job%s_%s' \
        "$GOM_SANDPC_RESULT_PREFIX" \
        "$GOM_PRODUCTION_CASE_KEY" \
        "$GOM_SANDPC_PHYSICS_PROFILE" \
        "$phase" \
        "$SLURM_ARRAY_JOB_ID" \
        "$SLURM_ARRAY_TASK_ID"
}

gom_sandpc_write_metadata() {
    destination="$1"
    phase="$2"
    gom_production_write_metadata "$destination" "$phase"
    printf '%s\n' \
        "physics_profile=$GOM_SANDPC_PHYSICS_PROFILE" \
        "pc_reference=sand_theta30" \
        "host_pc_scaling=leverett_kv" \
        "nonpredict_pc_scaling=leverett_local_kzz" \
        "younger_nonpredict_local_perm_md=50,500,500" \
        "base_saturation_regions=8" \
        "explicit_predict_regions=522" \
        "drainage_saturation_regions=530" \
        "total_sgof_tables=1060" \
        >> "$destination"
}
