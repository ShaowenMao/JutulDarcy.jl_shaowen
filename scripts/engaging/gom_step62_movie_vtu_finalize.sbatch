#!/bin/bash
#SBATCH --job-name=gom_s62_movie_vtu_final
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_MOVIE_ARCHIVE_ROOT:?Set the durable movie restart archive.}"
: "${GOM_MOVIE_VTU_JOB_ID:?Set the completed movie VTU array job ID.}"
[[ "$GOM_MOVIE_VTU_JOB_ID" =~ ^[0-9]+$ ]] || {
    echo "GOM_MOVIE_VTU_JOB_ID must be numeric." >&2
    exit 1
}

archive_root="$(readlink -f -- "$GOM_MOVIE_ARCHIVE_ROOT")"
campaign_root="$(dirname -- "$archive_root")"
vtu_root="$campaign_root/vtu_job${GOM_MOVIE_VTU_JOB_ID}"
test -d "$vtu_root"
if test -f "$vtu_root/PASS"; then
    grep -Fxq 'status=pass' "$vtu_root/VTU_JOB_SUMMARY.txt"
    grep -Fxq 'vtu_files=633' "$vtu_root/VTU_JOB_SUMMARY.txt"
    echo "Verified existing movie VTU finalization: $vtu_root"
    exit 0
fi

case_count=0
total_vtu_files=0
total_vtu_bytes=0
for task in 5 6 7; do
    matches=()
    while IFS= read -r -d '' path; do
        matches+=("$path")
    done < <(
        find "$vtu_root" -mindepth 1 -maxdepth 1 -type d -print0
    )
    case_dir=""
    for candidate in "${matches[@]}"; do
        metadata="$candidate/EXPORT_METADATA.txt"
        test -f "$metadata" || continue
        if grep -Fxq "array_task_id=$task" "$metadata"; then
            test -z "$case_dir" || {
                echo "Multiple VTU cases map to task $task." >&2
                exit 1
            }
            case_dir="$candidate"
        fi
    done
    test -n "$case_dir"
    test -f "$case_dir/PASS"
    test -f "$case_dir/exit_status.txt"
    grep -Fxq 'exit_code=0' "$case_dir/exit_status.txt"
    grep -Fxq 'status=pass' "$case_dir/export_summary.txt"
    grep -Fxq 'export_mode=all_report_steps' "$case_dir/export_summary.txt"
    grep -Fxq 'selected_steps=1:210' "$case_dir/export_summary.txt"
    grep -Fxq 'vtu_files=211' "$case_dir/export_summary.txt"
    grep -Fxq 'pvd_files=1' "$case_dir/export_summary.txt"
    grep -Fxq 'pvd_time_unit=years' "$case_dir/export_summary.txt"
    grep -Fxq 'geology_indicator_schema=gom_vtu_geology_indicators_v2' \
        "$case_dir/export_summary.txt"
    grep -Fxq \
        'fault_region_flag_values=0:outside_fault,1:predict_fault,2:nonpredict_fault' \
        "$case_dir/export_summary.txt"
    grep -Fxq \
        'stratigraphy_region_flag_values=0:outside_stratigraphy,1:sand,2:clay' \
        "$case_dir/export_summary.txt"
    test -f "$case_dir/vtu/export_summary.txt"
    cmp --silent "$case_dir/export_summary.txt" \
        "$case_dir/vtu/export_summary.txt"
    test "$(find "$case_dir/vtu" -maxdepth 1 -type f -name '*.vtu' | wc -l)" \
        -eq 211
    test "$(find "$case_dir/vtu" -maxdepth 1 -type f -name '*.pvd' | wc -l)" \
        -eq 1
    test "$(wc -l < "$case_dir/VTU_SHA256.txt")" -eq 212
    test "$(grep -c ': OK$' "$case_dir/VTU_CHECKSUM_VERIFICATION.log")" \
        -eq 212
    while read -r _ relative_path; do
        test -s "$case_dir/$relative_path"
    done < "$case_dir/VTU_SHA256.txt"
    case_vtu_bytes="$(
        find "$case_dir/vtu" -maxdepth 1 -type f \
            \( -name '*.vtu' -o -name '*.pvd' \) -printf '%s\n' |
            awk '{sum += $1} END {print sum + 0}'
    )"
    case_count=$((case_count + 1))
    total_vtu_files=$((total_vtu_files + 211))
    total_vtu_bytes=$((total_vtu_bytes + case_vtu_bytes))
done

test "$case_count" -eq 3
test "$total_vtu_files" -eq 633
printf '%s\n' \
    'status=pass' \
    "vtu_job_id=$GOM_MOVIE_VTU_JOB_ID" \
    'case_tasks=5,6,7' \
    "case_count=$case_count" \
    'report_steps_per_case=210' \
    'initial_vtu_per_case=1' \
    "vtu_files=$total_vtu_files" \
    'pvd_files=3' \
    "vtu_payload_bytes=$total_vtu_bytes" \
    'per_case_sha256_verified=true' \
    'output_storage=durable_disk' \
    "validated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$vtu_root/VTU_JOB_SUMMARY.txt"
printf 'PASS\n' > "$vtu_root/PASS"
echo "Validated movie VTU job: $vtu_root"
