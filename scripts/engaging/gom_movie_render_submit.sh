#!/bin/bash

set -euo pipefail

: "${GOM_MOVIE_ARCHIVE_JOB_ID:?Set the running/completed restart archive job ID.}"
: "${GOM_MOVIE_ARCHIVE_ROOT:?Set the durable movie restart archive.}"
: "${GOM_MOVIE_SOURCE_JOB_ID:?Set the source simulation array job ID.}"
: "${GOM_MOVIE_SCIENCE_REPO:?Set the checksum-pinned simulation checkout.}"
: "${GOM_MOVIE_WORKFLOW_REPO:?Set the pinned movie workflow checkout.}"

for value in "$GOM_MOVIE_ARCHIVE_JOB_ID" "$GOM_MOVIE_SOURCE_JOB_ID"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "Archive/source job IDs must be numeric." >&2
        exit 1
    }
done

archive_root="$(readlink -m -- "$GOM_MOVIE_ARCHIVE_ROOT")"
science_repo="$(readlink -f -- "$GOM_MOVIE_SCIENCE_REPO")"
workflow_repo="$(readlink -f -- "$GOM_MOVIE_WORKFLOW_REPO")"
render_parent="${GOM_MOVIE_RENDER_PARENT:-$(dirname -- "$archive_root")}"
render_parent="$(readlink -m -- "$render_parent")"
environment_root="${GOM_MOVIE_ENV_ROOT:-/orcd/data/juanes/001/shaowen/gom_grid/software/gom_movie_visualization_v1}"
environment_root="$(readlink -m -- "$environment_root")"
durable_prefix="/orcd/data/juanes/001/shaowen/gom_grid/movie_runs"
case "$archive_root/" in "$durable_prefix/"*) ;; *) exit 1 ;; esac
case "$render_parent/" in "$durable_prefix/"*) ;; *) exit 1 ;; esac
test "$(git -C "$science_repo" rev-parse HEAD)" = \
    7283ae565f3b1bb9d74e69700204f16f1e3ce40c
workflow_commit="$(git -C "$workflow_repo" rev-parse HEAD)"
test -z "$(git -C "$workflow_repo" status --short)"

engaging="$workflow_repo/scripts/engaging"
environment_script="$engaging/gom_movie_visualization_environment.sbatch"
vtu_script="$engaging/gom_step62_movie_vtu_from_archive.sbatch"
vtu_finalize_script="$engaging/gom_step62_movie_vtu_finalize.sbatch"
render_script="$engaging/gom_movie_render_frames.sbatch"
render_finalize_script="$engaging/gom_movie_render_finalize.sbatch"
for script in \
    "$environment_script" "$vtu_script" "$vtu_finalize_script" \
    "$render_script" "$render_finalize_script"
do
    test -f "$script"
done

mkdir -p -- "$render_parent/submission_receipts"

if test -n "${GOM_MOVIE_EXISTING_ENV_JOB_ID:-}"; then
    [[ "$GOM_MOVIE_EXISTING_ENV_JOB_ID" =~ ^[0-9]+$ ]]
    environment_job="$GOM_MOVIE_EXISTING_ENV_JOB_ID"
else
    environment_job="$(
        sbatch --parsable \
            --export="ALL,GOM_MOVIE_ENV_ROOT=$environment_root,GOM_MOVIE_WORKFLOW_REPO=$workflow_repo" \
            "$environment_script"
    )"
fi
archive_dependency=()
if ! test -f "$archive_root/ARCHIVE_COMPLETE" || \
    ! test -f "$archive_root/SOURCE_REMOVED.txt"
then
    archive_dependency=(--dependency="afterok:$GOM_MOVIE_ARCHIVE_JOB_ID")
fi
vtu_job="$(
    sbatch --parsable "${archive_dependency[@]}" \
        --export="ALL,GOM_MOVIE_ARCHIVE_ROOT=$archive_root,GOM_MOVIE_SOURCE_JOB_ID=$GOM_MOVIE_SOURCE_JOB_ID,GOM_MOVIE_SCIENCE_REPO=$science_repo,GOM_MOVIE_WORKFLOW_DIR=$engaging" \
        "$vtu_script"
)"
vtu_root="$render_parent/vtu_job${vtu_job}"
vtu_finalize_job="$(
    sbatch --parsable --dependency="afterok:$vtu_job" \
        --export="ALL,GOM_MOVIE_ARCHIVE_ROOT=$archive_root,GOM_MOVIE_VTU_JOB_ID=$vtu_job" \
        "$vtu_finalize_script"
)"
smoke_job="$(
    sbatch --parsable --array=1-2 --time=04:00:00 \
        --dependency="afterok:$environment_job:$vtu_finalize_job" \
        --export="ALL,GOM_MOVIE_VTU_ROOT=$vtu_root,GOM_MOVIE_RENDER_PARENT=$render_parent,GOM_MOVIE_ENV_ROOT=$environment_root,GOM_MOVIE_WORKFLOW_REPO=$workflow_repo,GOM_MOVIE_RENDER_MODE=smoke" \
        "$render_script"
)"
smoke_finalize_job="$(
    sbatch --parsable --time=01:00:00 --dependency="afterok:$smoke_job" \
        --export="ALL,GOM_MOVIE_VTU_ROOT=$vtu_root,GOM_MOVIE_RENDER_PARENT=$render_parent,GOM_MOVIE_RENDER_JOB_ID=$smoke_job,GOM_MOVIE_ENV_ROOT=$environment_root,GOM_MOVIE_WORKFLOW_REPO=$workflow_repo,GOM_MOVIE_RENDER_MODE=smoke" \
        "$render_finalize_script"
)"
full_render_job="$(
    sbatch --parsable --array=1-126 \
        --dependency="afterok:$smoke_finalize_job" \
        --export="ALL,GOM_MOVIE_VTU_ROOT=$vtu_root,GOM_MOVIE_RENDER_PARENT=$render_parent,GOM_MOVIE_ENV_ROOT=$environment_root,GOM_MOVIE_WORKFLOW_REPO=$workflow_repo,GOM_MOVIE_RENDER_MODE=full" \
        "$render_script"
)"
full_finalize_job="$(
    sbatch --parsable --dependency="afterok:$full_render_job" \
        --export="ALL,GOM_MOVIE_VTU_ROOT=$vtu_root,GOM_MOVIE_RENDER_PARENT=$render_parent,GOM_MOVIE_RENDER_JOB_ID=$full_render_job,GOM_MOVIE_ENV_ROOT=$environment_root,GOM_MOVIE_WORKFLOW_REPO=$workflow_repo,GOM_MOVIE_RENDER_MODE=full" \
        "$render_finalize_script"
)"

receipt="$render_parent/submission_receipts/movie_render_${workflow_commit:0:8}_$(date -u +%Y%m%dT%H%M%SZ).txt"
printf '%s\n' \
    'status=submitted' \
    "submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "workflow_repo=$workflow_repo" \
    "workflow_commit=$workflow_commit" \
    "science_repo=$science_repo" \
    "archive_job_id=$GOM_MOVIE_ARCHIVE_JOB_ID" \
    "archive_root=$archive_root" \
    "environment_job_id=$environment_job" \
    "environment_root=$environment_root" \
    "vtu_job_id=$vtu_job" \
    "vtu_root=$vtu_root" \
    "vtu_finalize_job_id=$vtu_finalize_job" \
    "smoke_job_id=$smoke_job" \
    "smoke_finalize_job_id=$smoke_finalize_job" \
    "full_render_job_id=$full_render_job" \
    "full_finalize_job_id=$full_finalize_job" \
    'case_tasks=5,6,7' \
    'quantities=rs,sg' \
    'report_steps=1:210' \
    'full_render_array=1-126' \
    'png_dpi=600' \
    'pdf_years=25,50,100,1000' \
    'all_large_outputs=durable_disk' \
    > "$receipt"
cat "$receipt"
echo "receipt=$receipt"
