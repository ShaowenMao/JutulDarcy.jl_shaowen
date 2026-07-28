#!/bin/bash
# Shared, immutable configuration for the Step62 seven-case pilot.

set -euo pipefail

gom_production_resolve_task() {
    : "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST to the immutable TOML.}"
    : "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
    : "${SLURM_ARRAY_TASK_ID:?This script must run as a Slurm array task.}"

    resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
    production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
    test -f "$resolver"
    command -v "$production_python" >/dev/null
    resolved_case="$(
        "$production_python" "$resolver" --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$SLURM_ARRAY_TASK_ID" --format shell
    )"
    eval "$resolved_case"
    export GOM_PRODUCTION_CAMPAIGN_ID
    export GOM_PRODUCTION_MANIFEST_PATH
    export GOM_PRODUCTION_MANIFEST_COMPANION_PATH
    export GOM_PRODUCTION_MANIFEST_SHA256
    export GOM_PRODUCTION_ARCHIVE_ROOT
    export GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256
    export GOM_PRODUCTION_MRST_PREPARE_COMMIT
    export GOM_PRODUCTION_JUTULDARCY_COMMIT
    export GOM_PRODUCTION_JUTUL_MANIFEST_SHA256
    export GOM_PRODUCTION_CASE_COUNT
    export GOM_PRODUCTION_TASK
    export GOM_PRODUCTION_CASE_KEY
    export GOM_PRODUCTION_GEOLOGY_ID
    export GOM_PRODUCTION_REALIZATION_ID
    export GOM_PRODUCTION_COMMON_MAT
    export GOM_PRODUCTION_COMMON_SHA256
    export GOM_PRODUCTION_COMMON_BYTES
    export GOM_PRODUCTION_SPECIFIC_MAT
    export GOM_PRODUCTION_SPECIFIC_SHA256
    export GOM_PRODUCTION_SPECIFIC_BYTES
    export GOM_PRODUCTION_GEOLOGY_HASH
    export GOM_PRODUCTION_LEVEL3_CASE_NAME

    observed_commit="$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)"
    test "$observed_commit" = "$GOM_PRODUCTION_JUTULDARCY_COMMIT" || {
        echo "JutulDarcy commit mismatch: expected " \
            "$GOM_PRODUCTION_JUTULDARCY_COMMIT, observed $observed_commit" >&2
        return 1
    }
    test -s "$JUTULDARCY_COMBINED_REPO/Manifest.toml" || {
        echo "Pinned Jutul Manifest.toml is missing." >&2
        return 1
    }
    observed_manifest_sha256="$(
        sha256sum "$JUTULDARCY_COMBINED_REPO/Manifest.toml" |
            awk '{print $1}'
    )"
    test "$observed_manifest_sha256" = \
        "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" || {
        echo "Jutul Manifest.toml SHA-256 mismatch: expected " \
            "$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256, observed " \
            "$observed_manifest_sha256" >&2
        return 1
    }
}

gom_production_export_locked_physics() {
    export CASE_ID=external_split
    export EXTERNAL_CASE_KEY="$GOM_PRODUCTION_CASE_KEY"
    export COMMON_MATFILE_PATH="$GOM_PRODUCTION_COMMON_MAT"
    export SPECIFIC_MATFILE_PATH="$GOM_PRODUCTION_SPECIFIC_MAT"
    export MATFILE_PATH="$GOM_PRODUCTION_SPECIFIC_MAT"

    export RUN_MODE=simulate
    export RESTART_RUN=false
    export LOAD_STATES_AFTER_SIM=false
    export LOAD_REPORTS_AFTER_SIM=false
    export IN_MEMORY_REPORTS=1
    export INFO_LEVEL=1
    export REPORT_LEVEL=1

    export JULIA_NUM_GC_THREADS=1
    export HYPRE_THREADS="${SLURM_CPUS_PER_TASK:-8}"
    export MAX_NONLINEAR_ITERATIONS=10
    export MAX_TIMESTEP_CUTS=25
    export NONLINEAR_RELAXATION=true
    export TARGET_ITS=5
    export TIMESTEP_MAX_INCREASE=1.25
    export TARGET_DS=0.05
    export DR_MAX=Inf
    export WELL_VOLUME_FRACTION=1.0e-3

    export DISABLE_HYSTERESIS=false
    export HYSTERESIS_S_MIN=0.05
    export USE_MRST_TRANSMISSIBILITY=false
    export IGNORE_MRST_T=true
    export FAULT_SATURATION_DOMAIN_MODE=input
    export FAULT_PC_ENTRY_TREATMENT=plateau
    export FAULT_PC_ENTRY_SG_MAX=1.0e-4
    export EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
    export ENABLE_DIFFUSION=false

    export PRODUCTION_OUTPUT_MODE=true
    # Existing frozen pilot inputs predate exact QoI semantics, so this
    # remains off unless a regenerated campaign explicitly requires it.
    export PRODUCTION_QOI_MODE="${PRODUCTION_QOI_MODE:-off}"
    export PRODUCTION_RETAIN_YEARS=50,1000
    export PRODUCTION_ROLLING_CHECKPOINTS=2
    export PRODUCTION_CASE_KEY="$GOM_PRODUCTION_CASE_KEY"
    export PRODUCTION_CAMPAIGN_MANIFEST_SHA256="$GOM_PRODUCTION_MANIFEST_SHA256"
    export RESTART_CACHE_MODE=off
    export MEMORY_MONITOR_INTERVAL_SECONDS=30
}

gom_production_case_tag() {
    phase="$1"
    printf 'gom_step62_production_%s_hyst_faultpcplateau_npctheta30_%s_job%s_%s' \
        "$GOM_PRODUCTION_CASE_KEY" "$phase" \
        "$SLURM_ARRAY_JOB_ID" "$SLURM_ARRAY_TASK_ID"
}

gom_production_write_metadata() {
    destination="$1"
    phase="$2"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' \
        "job_id=$SLURM_JOB_ID" \
        "array_job_id=$SLURM_ARRAY_JOB_ID" \
        "array_task_id=$SLURM_ARRAY_TASK_ID" \
        "node=$SLURMD_NODENAME" \
        "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "phase=$phase" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest=$GOM_PRODUCTION_MANIFEST_PATH" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "source_input_manifest_sha256=$GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256" \
        "mrst_prepare_commit=$GOM_PRODUCTION_MRST_PREPARE_COMMIT" \
        "jutuldarcy_commit=$GOM_PRODUCTION_JUTULDARCY_COMMIT" \
        "jutul_manifest_sha256=$GOM_PRODUCTION_JUTUL_MANIFEST_SHA256" \
        "case_key=$GOM_PRODUCTION_CASE_KEY" \
        "geology_id=$GOM_PRODUCTION_GEOLOGY_ID" \
        "geology_hash=$GOM_PRODUCTION_GEOLOGY_HASH" \
        "realization_id=$GOM_PRODUCTION_REALIZATION_ID" \
        "level3_case_name=$GOM_PRODUCTION_LEVEL3_CASE_NAME" \
        "common_mat=$GOM_PRODUCTION_COMMON_MAT" \
        "common_mat_sha256=$GOM_PRODUCTION_COMMON_SHA256" \
        "common_mat_bytes=$GOM_PRODUCTION_COMMON_BYTES" \
        "specific_mat=$GOM_PRODUCTION_SPECIFIC_MAT" \
        "specific_mat_sha256=$GOM_PRODUCTION_SPECIFIC_SHA256" \
        "specific_mat_bytes=$GOM_PRODUCTION_SPECIFIC_BYTES" \
        "grid=step62" \
        "resolution_slices=87" \
        "cells=2165082" \
        "schedule_steps=210" \
        "schedule_end_years=1000" \
        "injection_end_years=50" \
        "hysteresis=true" \
        "hysteresis_s_min=0.05" \
        "fault_hysteresis=drainage_equivalent" \
        "fault_pc_entry_treatment=plateau" \
        "fault_pc_entry_sg_max=1e-4" \
        "nonpredict_pc_reference_contact_angle_deg=30" \
        "transmissibility_source=JutulDarcy_grid_and_rock" \
        "well_volume_fraction=1e-3" \
        "production_output_mode=true" \
        "production_qoi_mode=$PRODUCTION_QOI_MODE" \
        "production_retain_years=50,1000" \
        "production_rolling_checkpoints=2" \
        "memory=${SLURM_MEM_PER_NODE:-unknown}" \
        "cpus=${SLURM_CPUS_PER_TASK:-unknown}" \
        > "$destination"
}
