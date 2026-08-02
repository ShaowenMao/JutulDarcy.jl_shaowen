#!/bin/bash
#SBATCH --job-name=gom_movie_frames
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%A_%a.err

set -euo pipefail

: "${GOM_MOVIE_VTU_ROOT:?Set the validated all-timestep VTU job root.}"
: "${GOM_MOVIE_RENDER_PARENT:?Set the durable movie render parent.}"
: "${GOM_MOVIE_ENV_ROOT:?Set the validated visualization environment.}"
: "${GOM_MOVIE_WORKFLOW_REPO:?Set the pinned visualization workflow checkout.}"
: "${SLURM_ARRAY_TASK_ID:?This must run as a Slurm array task.}"

mode="${GOM_MOVIE_RENDER_MODE:-full}"
case "$mode" in
    smoke|full) ;;
    *)
        echo "GOM_MOVIE_RENDER_MODE must be smoke or full." >&2
        exit 1
        ;;
esac

vtu_root="$(readlink -f -- "$GOM_MOVIE_VTU_ROOT")"
render_parent="$(readlink -m -- "$GOM_MOVIE_RENDER_PARENT")"
environment_root="$(readlink -f -- "$GOM_MOVIE_ENV_ROOT")"
workflow_repo="$(readlink -f -- "$GOM_MOVIE_WORKFLOW_REPO")"
durable_prefix="/orcd/data/juanes/001/shaowen/gom_grid/movie_runs"
case "$vtu_root/" in "$durable_prefix/"*) ;; *) exit 1 ;; esac
case "$render_parent/" in "$durable_prefix/"*) ;; *) exit 1 ;; esac
test -f "$vtu_root/PASS"
test -f "$environment_root/ENVIRONMENT_PASS"

python="$environment_root/python/bin/python"
tex_bin="$(
    find "$environment_root/tex/.TinyTeX/bin" \
        -mindepth 1 -maxdepth 1 -type d | head -1
)"
test -x "$python"
test -x "$tex_bin/latex"
test -x "$tex_bin/dvipng"
driver="$workflow_repo/scripts/visualization/gom_movie_frames/render_gom_movie_frames.py"
test -f "$driver"

if test "$mode" = smoke; then
    case "$SLURM_ARRAY_TASK_ID" in
        1) driver_task=85 ;;
        2) driver_task=106 ;;
        *)
            echo "Smoke mode requires array tasks 1-2." >&2
            exit 1
            ;;
    esac
    output_root="$render_parent/render_smoke_job${SLURM_ARRAY_JOB_ID}"
    step_arguments=(--step-override 210)
else
    [[ "$SLURM_ARRAY_TASK_ID" =~ ^[1-9][0-9]*$ ]]
    test "$SLURM_ARRAY_TASK_ID" -le 126
    driver_task="$SLURM_ARRAY_TASK_ID"
    output_root="$render_parent/render_job${SLURM_ARRAY_JOB_ID}"
    step_arguments=()
fi

mkdir -p -- "$output_root"
export PATH="$tex_bin:$PATH"
export MPLBACKEND=Agg
export MPLCONFIGDIR="${SLURM_TMPDIR:-/tmp}/matplotlib-${SLURM_JOB_ID}"
export XDG_CACHE_HOME="${SLURM_TMPDIR:-/tmp}/cache-${SLURM_JOB_ID}"
export PYVISTA_OFF_SCREEN=true
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
mkdir -p -- "$MPLCONFIGDIR" "$XDG_CACHE_HOME"

"$python" "$driver" \
    --vtu-job-root "$vtu_root" \
    --output-root "$output_root" \
    --task-id "$driver_task" \
    --chunk-size 10 \
    --pdf-years 25,50,100,1000 \
    --png-dpi 600 \
    --python "$python" \
    --repo-root "$workflow_repo" \
    "${step_arguments[@]}"
