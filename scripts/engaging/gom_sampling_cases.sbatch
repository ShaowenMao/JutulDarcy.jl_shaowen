#!/bin/bash
#SBATCH -p mit_normal
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH -J gom_sampling
#SBATCH -c 8
#SBATCH --mem=64G
#SBATCH -t 4-00:00:00
#SBATCH -o /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.out
#SBATCH -e /home/%u/orcd/scratch/jutuldarcy_case/gom_sampling_runs/slurm-bootstrap-%x-%A_%a.err

set -euo pipefail

module purge
module load community-modules
module load julia/1.10.4

# An absolute command lets controlled jobs run a node-local Julia copy while
# ordinary submissions continue to use the module-provided executable.
JULIA_CMD=${JULIA_CMD:-julia}
RESTART_CACHE_MODE=${RESTART_CACHE_MODE:-off}
MEMORY_MONITOR_INTERVAL_SECONDS=${MEMORY_MONITOR_INTERVAL_SECONDS:-15}

REPO_ROOT=${REPO_ROOT:-/home/$USER/projects/JutulDarcy.jl_shaowen}
INPUT_ROOT=${INPUT_ROOT:-/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs}
RUN_ROOT=${RUN_ROOT:-/home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs}

CASE_ID=${CASE_ID:-${SLURM_ARRAY_TASK_ID:-all87_split}}

USER_COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-}
USER_SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-}
USER_MATFILE_PATH=${MATFILE_PATH:-}
unset COMMON_MATFILE_PATH
unset SPECIFIC_MATFILE_PATH
unset MATFILE_PATH

case "$CASE_ID" in
    1|all87_whole|all87_whole_cut25|all87_whole_cuts25)
        INPUT_CASE_ID=all87_whole
        CASE_TIMESTEP_CUTS=25
        ;;
    2|all87_split|all87_split_cut25|all87_split_cuts25)
        INPUT_CASE_ID=all87_split
        CASE_TIMESTEP_CUTS=25
        ;;
    external_split|external_split_cut25|external_split_cuts25)
        INPUT_CASE_ID=external_split
        CASE_TIMESTEP_CUTS=25
        ;;
    3|old86_whole|old86_whole_cut25|old86_whole_cuts25)
        INPUT_CASE_ID=old86_whole
        CASE_TIMESTEP_CUTS=25
        ;;
    4|old86_split|old86_split_cut25|old86_split_cuts25)
        INPUT_CASE_ID=old86_split
        CASE_TIMESTEP_CUTS=25
        ;;
    all87_whole_cut8|all87_whole_cuts8)
        INPUT_CASE_ID=all87_whole
        CASE_TIMESTEP_CUTS=8
        ;;
    all87_split_cut8|all87_split_cuts8)
        INPUT_CASE_ID=all87_split
        CASE_TIMESTEP_CUTS=8
        ;;
    old86_whole_cut8|old86_whole_cuts8)
        INPUT_CASE_ID=old86_whole
        CASE_TIMESTEP_CUTS=8
        ;;
    old86_split_cut8|old86_split_cuts8)
        INPUT_CASE_ID=old86_split
        CASE_TIMESTEP_CUTS=8
        ;;
    gom_large_hys_control|gom_large_hys_control_cut25|gom_large_hys_control_cuts25)
        INPUT_CASE_ID=gom_large_hys_control
        CASE_TIMESTEP_CUTS=25
        ;;
    gom_large_hys_control_cut8|gom_large_hys_control_cuts8)
        INPUT_CASE_ID=gom_large_hys_control
        CASE_TIMESTEP_CUTS=8
        ;;
    *)
        echo "Unknown CASE_ID=$CASE_ID"
        echo "Valid numeric values: 1-4"
        echo "Default names use MAX_TIMESTEP_CUTS=25: all87_whole, all87_split, old86_whole, old86_split,"
        echo "             all87_whole_cuts25, all87_split_cuts25, old86_whole_cuts25, old86_split_cuts25,"
        echo "             gom_large_hys_control, gom_large_hys_control_cuts25, external_split"
        echo "Legacy comparison names use MAX_TIMESTEP_CUTS=8: all87_whole_cuts8, all87_split_cuts8,"
        echo "             old86_whole_cuts8, old86_split_cuts8, gom_large_hys_control_cuts8"
        exit 1
        ;;
esac

case "$INPUT_CASE_ID" in
    gom_large_hys_control)
        CASE_KEY=gom_large_hys_control
        export MATFILE_PATH="${GOM_LARGE_HYS_MATFILE_PATH:-/home/$USER/orcd/pool/jutuldarcy_case/gom_inputs/lluis_field_case.mat}"
        ;;
    all87_whole)
        CASE_KEY=all87_whole
        export MATFILE_PATH="$INPUT_ROOT/all87/jutul/lluis_field_case_87_all87_whole.mat"
        ;;
    all87_split)
        CASE_KEY=all87_split
        export COMMON_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_common.mat"
        export SPECIFIC_MATFILE_PATH="$INPUT_ROOT/all87/jutul_split/lluis_field_case_87_all87_realization_0001_specific.mat"
        export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
        ;;
    external_split)
        CASE_KEY=${EXTERNAL_CASE_KEY:-external_split}
        if [ -z "$USER_COMMON_MATFILE_PATH" ] || \
           [ -z "$USER_SPECIFIC_MATFILE_PATH" ]; then
            echo "external_split requires exact COMMON_MATFILE_PATH and SPECIFIC_MATFILE_PATH."
            exit 1
        fi
        export COMMON_MATFILE_PATH="$USER_COMMON_MATFILE_PATH"
        export SPECIFIC_MATFILE_PATH="$USER_SPECIFIC_MATFILE_PATH"
        export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
        ;;
    old86_whole)
        CASE_KEY=old86_whole
        export MATFILE_PATH="$INPUT_ROOT/old86/jutul/lluis_field_case_87_old86_whole.mat"
        ;;
    old86_split)
        CASE_KEY=old86_split
        export COMMON_MATFILE_PATH="$INPUT_ROOT/old86/jutul_split/lluis_field_case_87_old86_common.mat"
        export SPECIFIC_MATFILE_PATH="$INPUT_ROOT/old86/jutul_split/lluis_field_case_87_old86_realization_0001_specific.mat"
        export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
        ;;
    *)
        echo "Internal error: unknown INPUT_CASE_ID=$INPUT_CASE_ID from CASE_ID=$CASE_ID"
        exit 1
        ;;
esac

if [ -n "$USER_COMMON_MATFILE_PATH" ]; then
    export COMMON_MATFILE_PATH="$USER_COMMON_MATFILE_PATH"
fi
if [ -n "$USER_SPECIFIC_MATFILE_PATH" ]; then
    export SPECIFIC_MATFILE_PATH="$USER_SPECIFIC_MATFILE_PATH"
    export MATFILE_PATH="$SPECIFIC_MATFILE_PATH"
elif [ -n "$USER_MATFILE_PATH" ]; then
    export MATFILE_PATH="$USER_MATFILE_PATH"
fi

export CASE_NAME=GOM_LARGE
export MAX_TIMESTEP_CUTS=${MAX_TIMESTEP_CUTS:-$CASE_TIMESTEP_CUTS}
export DISABLE_HYSTERESIS=${DISABLE_HYSTERESIS:-false}
DISABLE_HYSTERESIS_LC=$(echo "$DISABLE_HYSTERESIS" | tr '[:upper:]' '[:lower:]')
case "$DISABLE_HYSTERESIS_LC" in
    1|true|yes|y)
        export DISABLE_HYSTERESIS=true
        HYSTERESIS_TAG="_nohyst"
        ;;
    0|false|no|n)
        export DISABLE_HYSTERESIS=false
        HYSTERESIS_TAG=""
        ;;
    *)
        echo "Unknown DISABLE_HYSTERESIS=$DISABLE_HYSTERESIS"
        echo "Valid values: true/false, yes/no, 1/0"
        exit 1
        ;;
esac
export HYSTERESIS_S_MIN=${HYSTERESIS_S_MIN:-}
if [ -n "$HYSTERESIS_S_MIN" ]; then
    HYSTERESIS_S_MIN_SAFE=${HYSTERESIS_S_MIN//-/m}
    HYSTERESIS_S_MIN_SAFE=${HYSTERESIS_S_MIN_SAFE//+/}
    HYSTERESIS_S_MIN_SAFE=${HYSTERESIS_S_MIN_SAFE//./p}
    HYSTERESIS_S_MIN_SAFE=${HYSTERESIS_S_MIN_SAFE//E/e}
    HYSTERESIS_S_MIN_TAG="_smin${HYSTERESIS_S_MIN_SAFE}"
else
    HYSTERESIS_S_MIN_TAG=""
fi
export USE_MRST_TRANSMISSIBILITY=${USE_MRST_TRANSMISSIBILITY:-true}
export IGNORE_MRST_T=${IGNORE_MRST_T:-false}
IGNORE_MRST_T_LC=$(echo "$IGNORE_MRST_T" | tr '[:upper:]' '[:lower:]')
case "$IGNORE_MRST_T_LC" in
    1|true|yes|y)
        export IGNORE_MRST_T=true
        export USE_MRST_TRANSMISSIBILITY=false
        TRANSMISSIBILITY_TAG="_jutult"
        ;;
    0|false|no|n)
        export IGNORE_MRST_T=false
        USE_MRST_TRANSMISSIBILITY_LC=$(echo "$USE_MRST_TRANSMISSIBILITY" | tr '[:upper:]' '[:lower:]')
        case "$USE_MRST_TRANSMISSIBILITY_LC" in
            1|true|yes|y)
                export USE_MRST_TRANSMISSIBILITY=true
                TRANSMISSIBILITY_TAG=""
                ;;
            0|false|no|n)
                export USE_MRST_TRANSMISSIBILITY=false
                TRANSMISSIBILITY_TAG="_jutult"
                ;;
            *)
                echo "Unknown USE_MRST_TRANSMISSIBILITY=$USE_MRST_TRANSMISSIBILITY"
                echo "Valid values: true/false, yes/no, 1/0"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unknown IGNORE_MRST_T=$IGNORE_MRST_T"
        echo "Valid values: true/false, yes/no, 1/0"
        exit 1
        ;;
esac

export FAULT_SATURATION_DOMAIN_MODE=${FAULT_SATURATION_DOMAIN_MODE:-input}
FAULT_SATURATION_DOMAIN_MODE_LC=$(echo "$FAULT_SATURATION_DOMAIN_MODE" | tr '[:upper:]' '[:lower:]')
case "$FAULT_SATURATION_DOMAIN_MODE_LC" in
    ""|input|default|none|off|false|0)
        export FAULT_SATURATION_DOMAIN_MODE=input
        SAT_DOMAIN_TAG=""
        ;;
    predict_sample|predict_samples|predict_sample_522|sample|samples)
        export FAULT_SATURATION_DOMAIN_MODE=predict_sample
        SAT_DOMAIN_TAG="_satpredict"
        ;;
    *)
        echo "Unknown FAULT_SATURATION_DOMAIN_MODE=$FAULT_SATURATION_DOMAIN_MODE"
        echo "Valid values: input, predict_sample"
        exit 1
        ;;
esac

export FAULT_PC_ENTRY_TREATMENT=${FAULT_PC_ENTRY_TREATMENT:-none}
FAULT_PC_ENTRY_TREATMENT_LC=$(echo "$FAULT_PC_ENTRY_TREATMENT" | tr '[:upper:]' '[:lower:]')
case "$FAULT_PC_ENTRY_TREATMENT_LC" in
    ""|none|off|false|0)
        export FAULT_PC_ENTRY_TREATMENT=none
        PC_ENTRY_TAG=""
        ;;
    plateau|entry_plateau|pc_plateau)
        export FAULT_PC_ENTRY_TREATMENT=plateau
        PC_ENTRY_TAG="_pcplateau"
        ;;
    *)
        echo "Unknown FAULT_PC_ENTRY_TREATMENT=$FAULT_PC_ENTRY_TREATMENT"
        echo "Valid values: none, plateau"
        exit 1
        ;;
esac
export FAULT_PC_ENTRY_SG_MAX=${FAULT_PC_ENTRY_SG_MAX:-1.0e-4}

export EXPLICIT_FAULT_HYSTERESIS_MODE=${EXPLICIT_FAULT_HYSTERESIS_MODE:-disable}
EXPLICIT_FAULT_HYSTERESIS_MODE_LC=$(echo "$EXPLICIT_FAULT_HYSTERESIS_MODE" | tr '[:upper:]' '[:lower:]')
case "$EXPLICIT_FAULT_HYSTERESIS_MODE_LC" in
    ""|disable|disabled|none|off|false|0)
        export EXPLICIT_FAULT_HYSTERESIS_MODE=disable
        EXPLICIT_FAULT_HYSTERESIS_TAG=""
        ;;
    reservoir|reservoir_only|reservoir-only)
        export EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
        EXPLICIT_FAULT_HYSTERESIS_TAG="_reshyst"
        ;;
    *)
        echo "Unknown EXPLICIT_FAULT_HYSTERESIS_MODE=$EXPLICIT_FAULT_HYSTERESIS_MODE"
        echo "Valid values: disable, reservoir"
        exit 1
        ;;
esac

export PRODUCTION_OUTPUT_MODE=${PRODUCTION_OUTPUT_MODE:-false}
PRODUCTION_OUTPUT_MODE_LC=$(echo "$PRODUCTION_OUTPUT_MODE" | tr '[:upper:]' '[:lower:]')
case "$PRODUCTION_OUTPUT_MODE_LC" in
    1|true|yes|y)
        export PRODUCTION_OUTPUT_MODE=true
        export IN_MEMORY_REPORTS=1
        export LOAD_STATES_AFTER_SIM=false
        export LOAD_REPORTS_AFTER_SIM=false
        if [ "$RESTART_CACHE_MODE" != "off" ]; then
            echo "PRODUCTION_OUTPUT_MODE requires RESTART_CACHE_MODE=off."
            exit 1
        fi
        ;;
    0|false|no|n)
        export PRODUCTION_OUTPUT_MODE=false
        ;;
    *)
        echo "Unknown PRODUCTION_OUTPUT_MODE=$PRODUCTION_OUTPUT_MODE"
        echo "Valid values: true/false, yes/no, 1/0"
        exit 1
        ;;
esac

JOB_LABEL=${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-manual}}
TASK_LABEL=${SLURM_ARRAY_TASK_ID:-0}
BOOTSTRAP_TASK_LABEL=${SLURM_ARRAY_TASK_ID:-4294967294}
CASE_LABEL=${CASE_LABEL:-$CASE_KEY}
export CASE_TAG=${CASE_TAG:-${CASE_LABEL}_cuts${MAX_TIMESTEP_CUTS}${HYSTERESIS_TAG}${HYSTERESIS_S_MIN_TAG}${SAT_DOMAIN_TAG}${TRANSMISSIBILITY_TAG}${PC_ENTRY_TAG}${EXPLICIT_FAULT_HYSTERESIS_TAG}_job${JOB_LABEL}}
export RUN_MODE=${RUN_MODE:-simulate}
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export CASE_JULIA_THREADS=${SLURM_CPUS_PER_TASK:-8}
export VTU_PREFIX=${VTU_PREFIX:-$CASE_TAG}

export RESTART_OUTPUT_PATH="$RUN_ROOT/$CASE_TAG/restart"
export VTU_PATH="$RUN_ROOT/$CASE_TAG/vtu"
export CASE_LOG_DIR="$RUN_ROOT/$CASE_TAG/logs"
mkdir -p "$CASE_LOG_DIR"

LOG_BASENAME="slurm-${SLURM_JOB_NAME:-gom_sampling}-${JOB_LABEL}_${TASK_LABEL}"
BOOTSTRAP_LOG_BASENAME="slurm-bootstrap-${SLURM_JOB_NAME:-gom_sampling}-${JOB_LABEL}_${BOOTSTRAP_TASK_LABEL}"
export CASE_STDOUT_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.out"
export CASE_STDERR_PATH="$CASE_LOG_DIR/${LOG_BASENAME}.err"
BOOTSTRAP_STDOUT_PATH="$RUN_ROOT/${BOOTSTRAP_LOG_BASENAME}.out"
BOOTSTRAP_STDERR_PATH="$RUN_ROOT/${BOOTSTRAP_LOG_BASENAME}.err"

exec > "$CASE_STDOUT_PATH" 2> "$CASE_STDERR_PATH"

for bootstrap_path in "$BOOTSTRAP_STDOUT_PATH" "$BOOTSTRAP_STDERR_PATH"; do
    if [ -f "$bootstrap_path" ]; then
        mv -f "$bootstrap_path" "$CASE_LOG_DIR/"
    fi
done

cd "$REPO_ROOT"

echo "===== JOB ENV INFO ====="
hostname
date
pwd
echo "JULIA_CMD=$JULIA_CMD"
command -v "$JULIA_CMD"
"$JULIA_CMD" --version
module list
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-}"
echo "SLURM_ARRAY_JOB_ID=${SLURM_ARRAY_JOB_ID:-}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-}"
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-}"
echo "CASE_STDOUT_PATH=$CASE_STDOUT_PATH"
echo "CASE_STDERR_PATH=$CASE_STDERR_PATH"
echo "BOOTSTRAP_STDOUT_PATH=$CASE_LOG_DIR/$(basename "$BOOTSTRAP_STDOUT_PATH")"
echo "BOOTSTRAP_STDERR_PATH=$CASE_LOG_DIR/$(basename "$BOOTSTRAP_STDERR_PATH")"
echo "========================"

if [ "$RUN_MODE" = "simulate" ] || [ "$RUN_MODE" = "sim" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-8}
    export RESTART_RUN=${RESTART_RUN:-false}
    export LOAD_STATES_AFTER_SIM=${LOAD_STATES_AFTER_SIM:-false}
    export WRITE_INCON_VTU=false
    export WRITE_STATE_VTU=false
    mkdir -p "$RESTART_OUTPUT_PATH"
elif [ "$RUN_MODE" = "vtu" ] || [ "$RUN_MODE" = "postprocess" ] || [ "$RUN_MODE" = "export" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-1}
    export WRITE_INCON_VTU=${WRITE_INCON_VTU:-true}
    export WRITE_STATE_VTU=${WRITE_STATE_VTU:-true}
    mkdir -p "$VTU_PATH"
elif [ "$RUN_MODE" = "both" ]; then
    export HYPRE_THREADS=${HYPRE_THREADS:-8}
    export RESTART_RUN=${RESTART_RUN:-false}
    export LOAD_STATES_AFTER_SIM=${LOAD_STATES_AFTER_SIM:-true}
    mkdir -p "$RESTART_OUTPUT_PATH" "$VTU_PATH"
else
    echo "Unknown RUN_MODE=$RUN_MODE"
    echo "Valid values: simulate, vtu, both"
    exit 1
fi

echo "===== CASE INFO ====="
echo "CASE_ID=$CASE_ID"
echo "INPUT_CASE_ID=$INPUT_CASE_ID"
echo "CASE_KEY=$CASE_KEY"
echo "CASE_TAG=$CASE_TAG"
echo "RUN_MODE=$RUN_MODE"
echo "MAX_TIMESTEP_CUTS=$MAX_TIMESTEP_CUTS"
echo "DISABLE_HYSTERESIS=$DISABLE_HYSTERESIS"
echo "HYSTERESIS_S_MIN=$HYSTERESIS_S_MIN"
echo "USE_MRST_TRANSMISSIBILITY=$USE_MRST_TRANSMISSIBILITY"
echo "IGNORE_MRST_T=$IGNORE_MRST_T"
echo "FAULT_SATURATION_DOMAIN_MODE=$FAULT_SATURATION_DOMAIN_MODE"
echo "FAULT_PC_ENTRY_TREATMENT=$FAULT_PC_ENTRY_TREATMENT"
echo "FAULT_PC_ENTRY_SG_MAX=$FAULT_PC_ENTRY_SG_MAX"
echo "EXPLICIT_FAULT_HYSTERESIS_MODE=$EXPLICIT_FAULT_HYSTERESIS_MODE"
echo "MATFILE_PATH=$MATFILE_PATH"
echo "COMMON_MATFILE_PATH=${COMMON_MATFILE_PATH:-}"
echo "SPECIFIC_MATFILE_PATH=${SPECIFIC_MATFILE_PATH:-}"
echo "RESTART_OUTPUT_PATH=$RESTART_OUTPUT_PATH"
echo "VTU_PATH=$VTU_PATH"
echo "JULIA_NUM_THREADS=$JULIA_NUM_THREADS"
echo "JULIA_NUM_GC_THREADS=${JULIA_NUM_GC_THREADS:-automatic}"
echo "JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH:-default}"
echo "CASE_JULIA_THREADS=$CASE_JULIA_THREADS"
echo "HYPRE_THREADS=$HYPRE_THREADS"
echo "CPR_UPDATE_INTERVAL=${CPR_UPDATE_INTERVAL:-iteration}"
echo "CPR_UPDATE_INTERVAL_PARTIAL=${CPR_UPDATE_INTERVAL_PARTIAL:-iteration}"
echo "CPR_PARTIAL_UPDATE=${CPR_PARTIAL_UPDATE:-automatic}"
echo "RESTART_CACHE_MODE=$RESTART_CACHE_MODE"
echo "PRODUCTION_OUTPUT_MODE=$PRODUCTION_OUTPUT_MODE"
echo "PRODUCTION_SUMMARY_DIR=${PRODUCTION_SUMMARY_DIR:-default}"
echo "PRODUCTION_RETAIN_YEARS=${PRODUCTION_RETAIN_YEARS:-50,1000}"
echo "PRODUCTION_ROLLING_CHECKPOINTS=${PRODUCTION_ROLLING_CHECKPOINTS:-2}"
echo "PRODUCTION_CASE_KEY=${PRODUCTION_CASE_KEY:-}"
echo "PRODUCTION_CAMPAIGN_MANIFEST_SHA256=${PRODUCTION_CAMPAIGN_MANIFEST_SHA256:-}"
echo "MEMORY_MONITOR_INTERVAL_SECONDS=$MEMORY_MONITOR_INTERVAL_SECONDS"
echo "====================="

if [ ! -f "$MATFILE_PATH" ]; then
    echo "MATFILE_PATH does not exist: $MATFILE_PATH"
    exit 1
fi
if [ -n "${COMMON_MATFILE_PATH:-}" ] && [ ! -f "$COMMON_MATFILE_PATH" ]; then
    echo "COMMON_MATFILE_PATH does not exist: $COMMON_MATFILE_PATH"
    exit 1
fi
if [ -n "${SPECIFIC_MATFILE_PATH:-}" ] && [ ! -f "$SPECIFIC_MATFILE_PATH" ]; then
    echo "SPECIFIC_MATFILE_PATH does not exist: $SPECIFIC_MATFILE_PATH"
    exit 1
fi

case "$RESTART_CACHE_MODE" in
    off|monitor|evict)
        ;;
    *)
        echo "Unknown RESTART_CACHE_MODE=$RESTART_CACHE_MODE"
        echo "Valid values: off, monitor, evict"
        exit 1
        ;;
esac

JULIA_ARGS=(--startup-file=no --project=. src/input_simulation/co2_blackoil_gom.jl)
if { [ "$RUN_MODE" = "simulate" ] || [ "$RUN_MODE" = "sim" ]; } && [ "$RESTART_CACHE_MODE" != "off" ]; then
    CACHE_GUARD="$REPO_ROOT/scripts/engaging/restart_cache_guard.py"
    MEMORY_CACHE_LOG="$CASE_LOG_DIR/memory-cache-${JOB_LABEL}_${TASK_LABEL}.csv"
    if [ ! -f "$CACHE_GUARD" ]; then
        echo "Restart cache guard does not exist: $CACHE_GUARD"
        exit 1
    fi
    command -v python3

    "$JULIA_CMD" "${JULIA_ARGS[@]}" &
    JULIA_PID=$!
    python3 "$CACHE_GUARD" \
        --pid "$JULIA_PID" \
        --restart-dir "$RESTART_OUTPUT_PATH" \
        --log "$MEMORY_CACHE_LOG" \
        --mode "$RESTART_CACHE_MODE" \
        --interval "$MEMORY_MONITOR_INTERVAL_SECONDS" &
    CACHE_GUARD_PID=$!

    set +e
    wait "$JULIA_PID"
    JULIA_STATUS=$?
    wait "$CACHE_GUARD_PID"
    CACHE_GUARD_STATUS=$?
    set -e

    echo "JULIA_EXIT_STATUS=$JULIA_STATUS"
    echo "CACHE_GUARD_EXIT_STATUS=$CACHE_GUARD_STATUS"
    echo "MEMORY_CACHE_LOG=$MEMORY_CACHE_LOG"
    if [ "$JULIA_STATUS" -ne 0 ]; then
        exit "$JULIA_STATUS"
    fi
    if [ "$CACHE_GUARD_STATUS" -ne 0 ]; then
        exit "$CACHE_GUARD_STATUS"
    fi
else
    "$JULIA_CMD" "${JULIA_ARGS[@]}"
fi
