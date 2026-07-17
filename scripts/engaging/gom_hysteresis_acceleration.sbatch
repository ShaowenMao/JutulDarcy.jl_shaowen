#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_hyst_accel
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 4-00:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

SHARED_REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
REPO_ROOT=$SHARED_REPO_ROOT
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
export RUN_ROOT=${RUN_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs/hysteresis_acceleration}
HYST_ACCEL_STAGE=${HYST_ACCEL_STAGE:-checkpoint}

export CASE_ID=all87_split
export CASE_NAME=GOM_LARGE
export COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat}
export SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_slices_s05_c012_case01_specific.mat}
export MATFILE_PATH=$SPECIFIC_MATFILE_PATH

# Physical model settings match job 18022197_3 exactly.
export DISABLE_HYSTERESIS=false
export HYSTERESIS_S_MIN=0.05
export USE_MRST_TRANSMISSIBILITY=true
export IGNORE_MRST_T=false
export FAULT_SATURATION_DOMAIN_MODE=input
export FAULT_PC_ENTRY_TREATMENT=plateau
export FAULT_PC_ENTRY_SG_MAX=1.0e-4
export EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
export ENABLE_DIFFUSION=false

export RUN_MODE=simulate
export RESTART_RUN=false
export LOAD_STATES_AFTER_SIM=false
export LOAD_REPORTS_AFTER_SIM=false
export IN_MEMORY_REPORTS=1
export INFO_LEVEL=1
export REPORT_LEVEL=1
export HYPRE_THREADS=8
export MAX_NONLINEAR_ITERATIONS=10
export MAX_TIMESTEP_CUTS=25
export NONLINEAR_RELAXATION=true
export TIMESTEP_MAX_INCREASE=1.25
export DR_MAX=Inf
export CPR_UPDATE_INTERVAL_PARTIAL=iteration
unset CPR_PARTIAL_UPDATE

JOB_LABEL=${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}

case "$HYST_ACCEL_STAGE" in
    continuation|final_validation)
        NODE_LOCAL_STAGE=${NODE_LOCAL_STAGE:-true}
        case "${NODE_LOCAL_STAGE,,}" in
            1|true|yes|y)
                NODE_LOCAL_STAGE=true
                STAGE_TAG=nodelocal
                ;;
            0|false|no|n)
                NODE_LOCAL_STAGE=false
                STAGE_TAG=sharedfs
                ;;
            *)
                echo "Unknown NODE_LOCAL_STAGE=$NODE_LOCAL_STAGE. Valid values: true/false."
                exit 1
                ;;
        esac
        ;;
    *)
        NODE_LOCAL_STAGE=false
        STAGE_TAG=sharedfs
        ;;
esac

link_restart_source() {
    local source_restart_path=$1
    local source_step=$2
    local target_restart_dir
    local target_restart_file

    SOURCE_RESTART_PATH=$source_restart_path
    SOURCE_RESTART_FILE="$SOURCE_RESTART_PATH/jutul_${source_step}.jld2"
    target_restart_dir="$RUN_ROOT/$CASE_TAG/restart"
    target_restart_file="$target_restart_dir/jutul_${source_step}.jld2"
    if [ ! -f "$SOURCE_RESTART_FILE" ]; then
        echo "Checkpoint file does not exist: $SOURCE_RESTART_FILE"
        exit 1
    fi
    mkdir -p "$target_restart_dir"
    if [ -e "$target_restart_file" ] || [ -L "$target_restart_file" ]; then
        echo "Refusing to replace existing restart file: $target_restart_file"
        exit 1
    fi
    ln -s "$SOURCE_RESTART_FILE" "$target_restart_file"
}

case "$HYST_ACCEL_STAGE" in
    checkpoint)
        if [ -n "${SLURM_ARRAY_TASK_ID:-}" ]; then
            echo "Submit the checkpoint stage as a single job, not an array."
            exit 1
        fi
        export CASE_TAG="all87_split_hyst_checkpoint_step120_job${JOB_LABEL}"
        export TARGET_ITS=5
        export TARGET_DS=0.05
        export CPR_UPDATE_INTERVAL=iteration
        export STOP_AFTER_REPORT_STEP=120
        unset RESTART_STEP
        ;;
    continuation)
        ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:?Submit continuation as a Slurm array.}
        SOURCE_RESTART_PATH=${SOURCE_RESTART_PATH:?Set SOURCE_RESTART_PATH to the validated checkpoint restart directory.}
        case "$ARRAY_TASK_ID" in
            1)
                SOLVER_VARIANT=restart_validation
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export CPR_UPDATE_INTERVAL=iteration
                export JULIA_NUM_GC_THREADS=1
                ;;
            2)
                SOLVER_VARIANT=cpr_once
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export CPR_UPDATE_INTERVAL=once
                export JULIA_NUM_GC_THREADS=1
                ;;
            3)
                SOLVER_VARIANT=dt_ds0p10_its7
                export TARGET_ITS=7
                export TARGET_DS=0.10
                export CPR_UPDATE_INTERVAL=iteration
                export JULIA_NUM_GC_THREADS=1
                ;;
            4)
                SOLVER_VARIANT=combined_ds0p10_its7_cpr_once
                export TARGET_ITS=7
                export TARGET_DS=0.10
                export CPR_UPDATE_INTERVAL=once
                export JULIA_NUM_GC_THREADS=1
                ;;
            5)
                SOLVER_VARIANT=restart_validation
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export CPR_UPDATE_INTERVAL=iteration
                export JULIA_NUM_GC_THREADS=4
                ;;
            *)
                echo "Unknown continuation task $ARRAY_TASK_ID. Valid tasks are 1-5."
                exit 1
                ;;
        esac

        export CASE_TAG="all87_split_hyst_step121to145_${SOLVER_VARIANT}_gc${JULIA_NUM_GC_THREADS}_${STAGE_TAG}_job${JOB_LABEL}"
        export RESTART_STEP=121
        export STOP_AFTER_REPORT_STEP=145
        link_restart_source "$SOURCE_RESTART_PATH" 120
        ;;
    final_validation)
        ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:?Submit final_validation as a Slurm array.}
        export CPR_UPDATE_INTERVAL=iteration
        export JULIA_NUM_GC_THREADS=1
        export STOP_AFTER_REPORT_STEP=210

        case "$ARRAY_TASK_ID" in
            1)
                SOLVER_VARIANT=baseline_ds0p05_its5
                export TARGET_ITS=5
                export TARGET_DS=0.05
                export RESTART_STEP=146
                export CASE_TAG="all87_split_hyst_step146to210_${SOLVER_VARIANT}_gc1_${STAGE_TAG}_job${JOB_LABEL}"
                BASELINE_SOURCE_RESTART_PATH=${BASELINE_SOURCE_RESTART_PATH:?Set BASELINE_SOURCE_RESTART_PATH to the task-1 step-145 restart directory.}
                link_restart_source "$BASELINE_SOURCE_RESTART_PATH" 145
                ;;
            2)
                SOLVER_VARIANT=dt_ds0p10_its7
                export TARGET_ITS=7
                export TARGET_DS=0.10
                export RESTART_STEP=146
                export CASE_TAG="all87_split_hyst_step146to210_${SOLVER_VARIANT}_gc1_${STAGE_TAG}_job${JOB_LABEL}"
                DT_SOURCE_RESTART_PATH=${DT_SOURCE_RESTART_PATH:?Set DT_SOURCE_RESTART_PATH to the task-3 step-145 restart directory.}
                link_restart_source "$DT_SOURCE_RESTART_PATH" 145
                ;;
            3)
                SOLVER_VARIANT=uninterrupted_baseline_ds0p05_its5
                export TARGET_ITS=5
                export TARGET_DS=0.05
                unset RESTART_STEP SOURCE_RESTART_PATH SOURCE_RESTART_FILE
                export CASE_TAG="all87_split_hyst_step001to210_${SOLVER_VARIANT}_gc1_${STAGE_TAG}_job${JOB_LABEL}"
                ;;
            *)
                echo "Unknown final_validation task $ARRAY_TASK_ID. Valid tasks are 1-3."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unknown HYST_ACCEL_STAGE=$HYST_ACCEL_STAGE"
        echo "Valid values: checkpoint, continuation, final_validation"
        exit 1
        ;;
esac

NODE_LOCAL_ROOT=
if [ "$NODE_LOCAL_STAGE" = "true" ]; then
    SOURCE_COMMIT=${SOURCE_COMMIT:?Set SOURCE_COMMIT to the exact Git commit to stage.}
    JULIA_RUNTIME_ARCHIVE=${JULIA_RUNTIME_ARCHIVE:?Set JULIA_RUNTIME_ARCHIVE to an immutable Julia runtime tar file.}
    JULIA_DEPOT_ARCHIVE=${JULIA_DEPOT_ARCHIVE:?Set JULIA_DEPOT_ARCHIVE to an immutable Julia depot tar file.}
    BUNDLE_MANIFEST=${BUNDLE_MANIFEST:-$(dirname "$JULIA_RUNTIME_ARCHIVE")/Manifest.toml}

    CASE_LOG_DIR="$RUN_ROOT/$CASE_TAG/logs"
    mkdir -p "$CASE_LOG_DIR"
    WRAPPER_STDOUT_PATH="$CASE_LOG_DIR/slurm-wrapper-${SLURM_JOB_NAME:-gom_hyst_accel}-${JOB_LABEL}_${SLURM_ARRAY_TASK_ID:-0}.out"
    WRAPPER_STDERR_PATH="$CASE_LOG_DIR/slurm-wrapper-${SLURM_JOB_NAME:-gom_hyst_accel}-${JOB_LABEL}_${SLURM_ARRAY_TASK_ID:-0}.err"
    BOOTSTRAP_STDOUT_PATH="$RUN_ROOT/slurm-bootstrap-${SLURM_JOB_NAME:-gom_hyst_accel}-${JOB_LABEL}_${SLURM_ARRAY_TASK_ID:-4294967294}.out"
    BOOTSTRAP_STDERR_PATH="$RUN_ROOT/slurm-bootstrap-${SLURM_JOB_NAME:-gom_hyst_accel}-${JOB_LABEL}_${SLURM_ARRAY_TASK_ID:-4294967294}.err"
    exec > "$WRAPPER_STDOUT_PATH" 2> "$WRAPPER_STDERR_PATH"
    for bootstrap_path in "$BOOTSTRAP_STDOUT_PATH" "$BOOTSTRAP_STDERR_PATH"; do
        if [ -f "$bootstrap_path" ]; then
            mv -f "$bootstrap_path" "$CASE_LOG_DIR/"
        fi
    done

    required_paths=(
        "$SHARED_REPO_ROOT/.git"
        "$JULIA_RUNTIME_ARCHIVE"
        "$JULIA_RUNTIME_ARCHIVE.sha256"
        "$JULIA_DEPOT_ARCHIVE"
        "$JULIA_DEPOT_ARCHIVE.sha256"
        "$BUNDLE_MANIFEST"
        "$BUNDLE_MANIFEST.sha256"
        "$COMMON_MATFILE_PATH"
        "$SPECIFIC_MATFILE_PATH"
    )
    if [ -n "${SOURCE_RESTART_FILE:-}" ]; then
        required_paths+=("$SOURCE_RESTART_FILE")
    fi
    for required_path in "${required_paths[@]}"; do
        if [ ! -e "$required_path" ]; then
            echo "Required staging input does not exist: $required_path"
            exit 1
        fi
    done

    STAGING_LOG="$CASE_LOG_DIR/node-local-staging.log"
    : > "$STAGING_LOG"

    stage_log() {
        printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$STAGING_LOG"
    }

    NODE_LOCAL_PARENT=${SLURM_TMPDIR:-/tmp/$USER}
    if [[ "$NODE_LOCAL_PARENT" != /* ]] || [ "$NODE_LOCAL_PARENT" = "/" ]; then
        echo "Unsafe node-local parent: $NODE_LOCAL_PARENT"
        exit 1
    fi
    NODE_LOCAL_PARENT=${NODE_LOCAL_PARENT%/}
    NODE_LOCAL_PREFIX="$NODE_LOCAL_PARENT/jutuldarcy-hyst-"
    NODE_LOCAL_ROOT="${NODE_LOCAL_PREFIX}${SLURM_JOB_ID}"

    cleanup_node_local() {
        status=$?
        if [ -n "${NODE_LOCAL_ROOT:-}" ]; then
            case "$NODE_LOCAL_ROOT" in
                "$NODE_LOCAL_PREFIX"*)
                    stage_log "Removing node-local staging directory: $NODE_LOCAL_ROOT"
                    rm -rf -- "$NODE_LOCAL_ROOT"
                    ;;
                *)
                    stage_log "Refusing to remove unexpected node-local path: $NODE_LOCAL_ROOT"
                    ;;
            esac
        fi
        return "$status"
    }
    trap cleanup_node_local EXIT

    LOCAL_REPO_ROOT="$NODE_LOCAL_ROOT/repo"
    LOCAL_JULIA_ROOT="$NODE_LOCAL_ROOT/julia"
    LOCAL_DEPOT_ROOT="$NODE_LOCAL_ROOT/depot"
    LOCAL_INPUT_ROOT="$NODE_LOCAL_ROOT/inputs"
    mkdir -p "$LOCAL_REPO_ROOT" "$LOCAL_JULIA_ROOT" "$LOCAL_DEPOT_ROOT" "$LOCAL_INPUT_ROOT"

    RESOLVED_SOURCE_COMMIT=$(git -C "$SHARED_REPO_ROOT" rev-parse --verify "${SOURCE_COMMIT}^{commit}")
    RUNTIME_ARCHIVE_SHA=$(awk 'NF { print $1; exit }' "$JULIA_RUNTIME_ARCHIVE.sha256")
    DEPOT_ARCHIVE_SHA=$(awk 'NF { print $1; exit }' "$JULIA_DEPOT_ARCHIVE.sha256")
    MANIFEST_SHA=$(awk 'NF { print $1; exit }' "$BUNDLE_MANIFEST.sha256")
    if [ -n "${SOURCE_RESTART_FILE:-}" ]; then
        CHECKPOINT_SHA=$(sha256sum "$SOURCE_RESTART_FILE" | awk '{ print $1 }')
    else
        CHECKPOINT_SHA=none
    fi

    stage_log "Host: $(hostname)"
    stage_log "Node-local root: $NODE_LOCAL_ROOT"
    stage_log "Source commit: $RESOLVED_SOURCE_COMMIT"
    stage_log "Julia runtime archive: $JULIA_RUNTIME_ARCHIVE"
    stage_log "Julia runtime archive SHA256: $RUNTIME_ARCHIVE_SHA"
    stage_log "Julia depot archive: $JULIA_DEPOT_ARCHIVE"
    stage_log "Julia depot archive SHA256: $DEPOT_ARCHIVE_SHA"
    stage_log "Project manifest: $BUNDLE_MANIFEST"
    stage_log "Project manifest SHA256: $MANIFEST_SHA"
    stage_log "Checkpoint SHA256: $CHECKPOINT_SHA"
    df -h "$NODE_LOCAL_PARENT" | tee -a "$STAGING_LOG"

    stage_log "Extracting immutable Git commit."
    git -C "$SHARED_REPO_ROOT" archive --format=tar "$RESOLVED_SOURCE_COMMIT" |
        tar -xf - -C "$LOCAL_REPO_ROOT"
    stage_log "Extracting node-local Julia runtime."
    tar -xf "$JULIA_RUNTIME_ARCHIVE" -C "$LOCAL_JULIA_ROOT"
    stage_log "Extracting node-local Julia depot."
    tar -xf "$JULIA_DEPOT_ARCHIVE" -C "$LOCAL_DEPOT_ROOT"

    copy_and_verify() {
        local source_path=$1
        local target_path=$2
        local label=$3
        local source_sha
        local target_sha
        source_sha=$(sha256sum "$source_path" | awk '{ print $1 }')
        cp -p "$source_path" "$target_path"
        target_sha=$(sha256sum "$target_path" | awk '{ print $1 }')
        if [ "$source_sha" != "$target_sha" ]; then
            echo "$label checksum mismatch after node-local copy."
            exit 1
        fi
        stage_log "$label SHA256: $source_sha"
    }

    LOCAL_COMMON_MATFILE_PATH="$LOCAL_INPUT_ROOT/$(basename "$COMMON_MATFILE_PATH")"
    LOCAL_SPECIFIC_MATFILE_PATH="$LOCAL_INPUT_ROOT/$(basename "$SPECIFIC_MATFILE_PATH")"
    copy_and_verify "$BUNDLE_MANIFEST" "$LOCAL_REPO_ROOT/Manifest.toml" "Project Manifest"
    copy_and_verify "$COMMON_MATFILE_PATH" "$LOCAL_COMMON_MATFILE_PATH" "Common MAT"
    copy_and_verify "$SPECIFIC_MATFILE_PATH" "$LOCAL_SPECIFIC_MATFILE_PATH" "Specific MAT"

    export REPO_ROOT="$LOCAL_REPO_ROOT"
    export COMMON_MATFILE_PATH="$LOCAL_COMMON_MATFILE_PATH"
    export SPECIFIC_MATFILE_PATH="$LOCAL_SPECIFIC_MATFILE_PATH"
    export MATFILE_PATH="$LOCAL_SPECIFIC_MATFILE_PATH"
    export JULIA_CMD="$LOCAL_JULIA_ROOT/bin/julia"
    export JULIA_DEPOT_PATH="$LOCAL_DEPOT_ROOT"
    export JULIA_PKG_PRECOMPILE_AUTO=0
    export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
    export CASE_JULIA_THREADS=${SLURM_CPUS_PER_TASK:-8}

    if [ ! -x "$JULIA_CMD" ]; then
        echo "Staged Julia executable is missing: $JULIA_CMD"
        exit 1
    fi

    stage_log "Validating staged Julia, JutulDarcy, and HYPRE."
    "$JULIA_CMD" --startup-file=no --project="$LOCAL_REPO_ROOT" -e 'using JutulDarcy, HYPRE; HYPRE.Init(nthreads = 8); println("Sys.BINDIR=", Sys.BINDIR); println("threads=", Threads.nthreads()); println("gc_threads=", Threads.ngcthreads()); println("hypre_threads=", HYPRE.NumThreads()); println("DEPOT_PATH=", join(DEPOT_PATH, ":"))' |
        tee -a "$STAGING_LOG"
    stage_log "Node-local staging complete."

    case "${STAGING_ONLY:-false}" in
        1|true|yes|y)
            stage_log "STAGING_ONLY requested; preflight completed without starting the simulation."
            exit 0
            ;;
        0|false|no|n)
            ;;
        *)
            echo "Unknown STAGING_ONLY=${STAGING_ONLY}. Valid values: true/false."
            exit 1
            ;;
    esac
fi

echo "===== HYSTERESIS ACCELERATION ====="
echo "HYST_ACCEL_STAGE=$HYST_ACCEL_STAGE"
echo "CASE_TAG=$CASE_TAG"
echo "TARGET_ITS=$TARGET_ITS"
echo "TARGET_DS=$TARGET_DS"
echo "CPR_UPDATE_INTERVAL=$CPR_UPDATE_INTERVAL"
echo "CPR_UPDATE_INTERVAL_PARTIAL=$CPR_UPDATE_INTERVAL_PARTIAL"
echo "RESTART_STEP=${RESTART_STEP:-}"
echo "STOP_AFTER_REPORT_STEP=$STOP_AFTER_REPORT_STEP"
echo "SOURCE_RESTART_PATH=${SOURCE_RESTART_PATH:-}"
echo "NODE_LOCAL_STAGE=${NODE_LOCAL_STAGE:-false}"
echo "NODE_LOCAL_ROOT=${NODE_LOCAL_ROOT:-}"
echo "SOURCE_COMMIT=${RESOLVED_SOURCE_COMMIT:-}"
echo "JULIA_NUM_GC_THREADS=${JULIA_NUM_GC_THREADS:-automatic}"
echo "JULIA_CMD=${JULIA_CMD:-julia}"
echo "JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH:-default}"
echo "==================================="

bash "$REPO_ROOT/scripts/engaging/gom_sampling_cases.sbatch"
