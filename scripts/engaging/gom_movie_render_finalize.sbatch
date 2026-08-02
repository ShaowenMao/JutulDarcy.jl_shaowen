#!/bin/bash
#SBATCH --job-name=gom_movie_render_final
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_MOVIE_VTU_ROOT:?Set the validated all-timestep VTU job root.}"
: "${GOM_MOVIE_RENDER_PARENT:?Set the durable movie render parent.}"
: "${GOM_MOVIE_RENDER_JOB_ID:?Set the completed render array job ID.}"
: "${GOM_MOVIE_ENV_ROOT:?Set the visualization environment.}"
: "${GOM_MOVIE_WORKFLOW_REPO:?Set the pinned visualization workflow checkout.}"

[[ "$GOM_MOVIE_RENDER_JOB_ID" =~ ^[0-9]+$ ]] || {
    echo "GOM_MOVIE_RENDER_JOB_ID must be numeric." >&2
    exit 1
}
mode="${GOM_MOVIE_RENDER_MODE:-full}"
case "$mode" in smoke|full) ;; *) exit 1 ;; esac

vtu_root="$(readlink -f -- "$GOM_MOVIE_VTU_ROOT")"
render_parent="$(readlink -f -- "$GOM_MOVIE_RENDER_PARENT")"
environment_root="$(readlink -f -- "$GOM_MOVIE_ENV_ROOT")"
workflow_repo="$(readlink -f -- "$GOM_MOVIE_WORKFLOW_REPO")"
if test "$mode" = smoke; then
    render_root="$render_parent/render_smoke_job${GOM_MOVIE_RENDER_JOB_ID}"
else
    render_root="$render_parent/render_job${GOM_MOVIE_RENDER_JOB_ID}"
fi
test -d "$render_root"
test -f "$environment_root/ENVIRONMENT_PASS"
python="$environment_root/python/bin/python"
validator="$workflow_repo/scripts/visualization/gom_movie_frames/validate_gom_movie_frames.py"
test -x "$python"
test -f "$validator"

"$python" "$validator" \
    --vtu-job-root "$vtu_root" \
    --render-root "$render_root" \
    --mode "$mode" \
    --workflow-repo "$workflow_repo"

test -f "$render_root/PASS"
echo "Validated movie render job: $render_root"
