#!/bin/bash
#SBATCH --job-name=gom_s62_movie_archive
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_MOVIE_SOURCE_ROOT:?Set the completed movie simulation root.}"
: "${GOM_MOVIE_ARCHIVE_ROOT:?Set the durable archive destination.}"
: "${GOM_MOVIE_SOURCE_JOB_ID:?Set the source simulation array job ID.}"

[[ "$GOM_MOVIE_SOURCE_JOB_ID" =~ ^[0-9]+$ ]] || {
    echo "GOM_MOVIE_SOURCE_JOB_ID must be numeric." >&2
    exit 1
}

tasks="${GOM_MOVIE_TASKS:-5 6 7}"
expected_steps="${GOM_MOVIE_EXPECTED_STEPS:-210}"
remove_source="${GOM_MOVIE_REMOVE_SOURCE:-false}"
read -r -a task_array <<< "$tasks"
task_count="${#task_array[@]}"
test "$task_count" -gt 0 || {
    echo "GOM_MOVIE_TASKS must contain at least one task." >&2
    exit 1
}
[[ "$expected_steps" =~ ^[1-9][0-9]*$ ]] || {
    echo "GOM_MOVIE_EXPECTED_STEPS must be a positive integer." >&2
    exit 1
}
case "$remove_source" in
    true|false) ;;
    *)
        echo "GOM_MOVIE_REMOVE_SOURCE must be true or false." >&2
        exit 1
        ;;
esac

scratch_results="$(readlink -f -- "$HOME/orcd/scratch/gom_grid/results")"
source_root="$(readlink -f -- "$GOM_MOVIE_SOURCE_ROOT")"
archive_root="$(readlink -m -- "$GOM_MOVIE_ARCHIVE_ROOT")"
archive_parent="$(dirname -- "$archive_root")"
archive_incoming="${archive_root}.incoming"
durable_prefix="/orcd/data/juanes/001/shaowen/gom_grid/movie_runs"

case "$source_root/" in
    "$scratch_results/"*) ;;
    *)
        echo "Source is outside the approved scratch results tree: $source_root" >&2
        exit 1
        ;;
esac
case "$archive_root/" in
    "$durable_prefix/"*) ;;
    *)
        echo "Archive is outside the approved durable movie tree: $archive_root" >&2
        exit 1
        ;;
esac
test "$source_root" != "$scratch_results"
test "$archive_root" != "$durable_prefix"
test "$(basename -- "$source_root")" = \
    "gom_step62_effective_pc_global_plateau_movie_allsteps_job${GOM_MOVIE_SOURCE_JOB_ID}" || {
        echo "Source basename does not match the declared job ID." >&2
        exit 1
    }

mkdir -p -- "$archive_parent"
exec 9>"${archive_root}.transfer.lock"
flock -n 9 || {
    echo "Another transfer owns ${archive_root}.transfer.lock." >&2
    exit 1
}

active_jobs="$(squeue -h -j "$GOM_MOVIE_SOURCE_JOB_ID" 2>/dev/null || true)"
test -z "$active_jobs" || {
    echo "Source job $GOM_MOVIE_SOURCE_JOB_ID is still active." >&2
    exit 1
}

validate_case_tree() {
    root="$1"
    for task in $tasks; do
        [[ "$task" =~ ^[1-9][0-9]*$ ]] || {
            echo "Invalid task in GOM_MOVIE_TASKS: $task" >&2
            return 1
        }
        matches=()
        while IFS= read -r -d '' path; do
            matches+=("$path")
        done < <(
            find "$root" -mindepth 1 -maxdepth 1 -type d \
                -name "*_job${GOM_MOVIE_SOURCE_JOB_ID}_${task}" -print0
        )
        test "${#matches[@]}" -eq 1 || {
            echo "Expected one case directory for task $task; found ${#matches[@]}." >&2
            return 1
        }
        case_dir="${matches[0]}"
        test -f "$case_dir/PASS"
        grep -Fxq 'status=pass' "$case_dir/movie_simulation_summary.txt"
        grep -Fxq "steps_completed=$expected_steps" \
            "$case_dir/movie_simulation_summary.txt"
        grep -Fxq "retained_restart_steps=1:$expected_steps" \
            "$case_dir/movie_simulation_summary.txt"
        restart_dir="$case_dir/restart"
        restart_count="$(
            find "$restart_dir" -maxdepth 1 -type f -name 'jutul_*.jld2' |
                wc -l
        )"
        test "$restart_count" -eq "$expected_steps" || {
            echo "Task $task has $restart_count restart files; expected $expected_steps." >&2
            return 1
        }
        for step in $(seq 1 "$expected_steps"); do
            test -s "$restart_dir/jutul_${step}.jld2" || {
                echo "Task $task is missing nonempty restart step $step." >&2
                return 1
            }
        done
    done
}

finish_source_removal() {
    test "$remove_source" = true || return 0
    test -d "$source_root" || return 0
    validate_case_tree "$source_root"
    (
        cd "$source_root"
        sha256sum --check "$archive_root/SOURCE_SHA256.txt" >/dev/null
    )
    active_jobs="$(squeue -h -j "$GOM_MOVIE_SOURCE_JOB_ID" 2>/dev/null || true)"
    test -z "$active_jobs"
    rm -rf --one-file-system -- "$source_root"
    test ! -e "$source_root"
    printf 'source_removed=true\nsource_removed_utc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$archive_root/SOURCE_REMOVED.txt"
}

if test -d "$archive_root"; then
    test -f "$archive_root/ARCHIVE_COMPLETE"
    test -f "$archive_root/SOURCE_SHA256.txt"
    validate_case_tree "$archive_root/payload"
    (
        cd "$archive_root/payload"
        sha256sum --check "$archive_root/SOURCE_SHA256.txt" >/dev/null
    )
    finish_source_removal
    echo "Verified existing archive: $archive_root"
    exit 0
fi

test -d "$source_root"
validate_case_tree "$source_root"
mkdir -p -- "$archive_incoming/payload"

manifest_tmp="${SLURM_TMPDIR:-/tmp}/gom_movie_source_${SLURM_JOB_ID}.sha256"
(
    cd "$source_root"
    find . -type f -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum
) > "$manifest_tmp"
test -s "$manifest_tmp"

rsync -a --partial --info=stats2 -- "$source_root/" \
    "$archive_incoming/payload/"
cp -- "$manifest_tmp" "$archive_incoming/SOURCE_SHA256.txt"

validate_case_tree "$archive_incoming/payload"
(
    cd "$archive_incoming/payload"
    sha256sum --check "$archive_incoming/SOURCE_SHA256.txt" \
        > "$archive_incoming/CHECKSUM_VERIFICATION.log"
)
verified_count="$(grep -c ': OK$' "$archive_incoming/CHECKSUM_VERIFICATION.log")"
manifest_count="$(wc -l < "$archive_incoming/SOURCE_SHA256.txt")"
test "$verified_count" -eq "$manifest_count"

source_bytes="$(du -sb "$source_root" | awk '{print $1}')"
payload_bytes="$(du -sb "$archive_incoming/payload" | awk '{print $1}')"
printf '%s\n' \
    'status=pass' \
    "source_job_id=$GOM_MOVIE_SOURCE_JOB_ID" \
    "source_root=$source_root" \
    "archive_root=$archive_root" \
    "tasks=$tasks" \
    "expected_restart_steps=$expected_steps" \
    "restart_file_count=$((expected_steps * task_count))" \
    "source_bytes=$source_bytes" \
    "payload_bytes=$payload_bytes" \
    "checksum_file_count=$manifest_count" \
    'checksum_verification=sha256_all_files' \
    "archive_job_id=$SLURM_JOB_ID" \
    "archived_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$archive_incoming/ARCHIVE_METADATA.txt"
printf 'PASS\n' > "$archive_incoming/ARCHIVE_COMPLETE"

mv -- "$archive_incoming" "$archive_root"
test -f "$archive_root/ARCHIVE_COMPLETE"
finish_source_removal

echo "Movie restart archive completed: $archive_root"
