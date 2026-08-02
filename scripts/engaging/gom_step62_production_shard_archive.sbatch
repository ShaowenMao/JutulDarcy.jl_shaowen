#!/bin/bash
#SBATCH --job-name=gom_s62_prod_shard
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Promote one verified task range to durable storage, then remove only those
# exact production and VTU case directories from scratch. The durable payload
# is atomically renamed into place only after every copied file is checksummed.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_PRODUCTION_CHECK_JOB_ID:?Set GOM_PRODUCTION_CHECK_JOB_ID.}"
: "${GOM_PRODUCTION_PREFLIGHT_JOB_ID:?Set GOM_PRODUCTION_PREFLIGHT_JOB_ID.}"
: "${GOM_PRODUCTION_FULL_JOB_ID:?Set GOM_PRODUCTION_FULL_JOB_ID.}"
: "${GOM_PRODUCTION_VTU_JOB_ID:?Set GOM_PRODUCTION_VTU_JOB_ID.}"
: "${GOM_PRODUCTION_TASK_START:?Set GOM_PRODUCTION_TASK_START.}"
: "${GOM_PRODUCTION_TASK_END:?Set GOM_PRODUCTION_TASK_END.}"
: "${GOM_PRODUCTION_SUBMISSION_ID:?Set GOM_PRODUCTION_SUBMISSION_ID.}"

for job_id in \
    "$GOM_PRODUCTION_CHECK_JOB_ID" \
    "$GOM_PRODUCTION_PREFLIGHT_JOB_ID" \
    "$GOM_PRODUCTION_FULL_JOB_ID" \
    "$GOM_PRODUCTION_VTU_JOB_ID"
do
    [[ "$job_id" =~ ^[0-9]+$ ]] || {
        echo "Production job IDs must be numeric." >&2
        exit 1
    }
done
[[ "$GOM_PRODUCTION_TASK_START" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_TASK_END" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_SUBMISSION_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
shard_verifier="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_shard_verify.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$production_python" >/dev/null
test -f "$shard_verifier"

summary="$($production_python "$resolver" \
    --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"
start="$GOM_PRODUCTION_TASK_START"
end="$GOM_PRODUCTION_TASK_END"
test "$start" -ge 1
test "$end" -ge "$start"
test "$end" -le "$GOM_PRODUCTION_CASE_COUNT"
shard_case_count=$((end - start + 1))
test "$shard_case_count" -le "$GOM_PRODUCTION_ARCHIVE_SHARD_SIZE"

result_dir="$gom_root/results/gom_step62_production_shard_archive_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

archive_root="$GOM_PRODUCTION_ARCHIVE_ROOT"
campaign_parent="$archive_root/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
incoming_parent="$archive_root/.incoming"
shard_name="shard_$(printf '%04d' "$start")_$(printf '%04d' "$end")"
incoming="$incoming_parent/${GOM_PRODUCTION_CAMPAIGN_ID}_${shard_name}_archivejob${SLURM_JOB_ID}"
final="$campaign_parent/shards/$shard_name"
mkdir -p "$incoming_parent" "$campaign_parent/shards" \
    "$campaign_parent/submissions"

check_root="$gom_root/results/gom_step62_production_campaign_check_job${GOM_PRODUCTION_CHECK_JOB_ID}"
case "$GOM_PRODUCTION_PHYSICS_PROFILE" in
    legacy_fault_plateau_npctheta30)
        preflight_root="$gom_root/results/gom_step62_production_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}"
        full_root="$gom_root/results/gom_step62_production_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
        vtu_root="$gom_root/results/gom_step62_production_vtu_job${GOM_PRODUCTION_VTU_JOB_ID}"
        preflight_log_prefix=gom_s62_prod_pf
        full_log_prefix=gom_s62_prod_full
        vtu_log_prefix=gom_s62_prod_vtu
        ;;
    sandpc_effective_globalplateau_v1)
        preflight_root="$gom_root/results/gom_step62_effective_pc_global_plateau_preflight_job${GOM_PRODUCTION_PREFLIGHT_JOB_ID}"
        full_root="$gom_root/results/gom_step62_effective_pc_global_plateau_full_job${GOM_PRODUCTION_FULL_JOB_ID}"
        vtu_root="$gom_root/results/gom_step62_effective_pc_global_plateau_vtu_job${GOM_PRODUCTION_VTU_JOB_ID}"
        preflight_log_prefix=gom_s62_epc_pf
        full_log_prefix=gom_s62_epc_full
        vtu_log_prefix=gom_s62_epc_vtu
        ;;
    *)
        echo "Unsupported physics profile: $GOM_PRODUCTION_PHYSICS_PROFILE" >&2
        exit 1
        ;;
esac
test -f "$check_root/PASS"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
grep -Fxq "case_count=$GOM_PRODUCTION_CASE_COUNT" \
    "$check_root/campaign_check_summary.txt"
grep -Fxq "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
    "$check_root/campaign_check_summary.txt"

copy_log_if_present() {
    path="$1"
    destination="$2"
    if test -f "$path"; then
        cp -- "$path" "$destination/"
    fi
}

set_case_paths() {
    task="$1"
    case_key="$2"
    preflight_case="$preflight_root/$case_key"
    case "$GOM_PRODUCTION_PHYSICS_PROFILE" in
        legacy_fault_plateau_npctheta30)
            full_tag="gom_step62_production_${case_key}_hyst_faultpcplateau_npctheta30_full1000y_job${GOM_PRODUCTION_FULL_JOB_ID}_${task}"
            ;;
        sandpc_effective_globalplateau_v1)
            full_tag="gom_step62_effective_pc_global_plateau_${case_key}_sandpc_effective_globalplateau_v1_full1000y_job${GOM_PRODUCTION_FULL_JOB_ID}_${task}"
            ;;
    esac
    full_case="$full_root/$full_tag"
    vtu_case="$vtu_root/$case_key"
}

compact_atomic_rows() {
    production_dir="$1"
    inventory="$production_dir/ATOMIC_ROW_ARCHIVES.tsv"
    printf 'source_directory\tfile_count\tarchive\tarchive_bytes\n' > "$inventory"
    for relative in rows retention qoi/rows; do
        source_dir="$production_dir/$relative"
        test -d "$source_dir" || continue
        file_count="$(find "$source_dir" -maxdepth 1 -type f \
            -name 'step_*.tsv' | wc -l)"
        test "$file_count" -eq 210
        archive_name="${relative//\//_}.tar.gz"
        archive_path="$production_dir/$archive_name"
        parent="$(dirname -- "$source_dir")"
        base="$(basename -- "$source_dir")"
        tar -czf "$archive_path" -C "$parent" "$base"
        archived_count="$(tar -tzf "$archive_path" | \
            grep -c '/step_[0-9][0-9]*\.tsv$')"
        test "$archived_count" -eq "$file_count"
        printf '%s\t%s\t%s\t%s\n' \
            "$relative" "$file_count" "$archive_name" \
            "$(stat -c '%s' "$archive_path")" >> "$inventory"
        resolved_source="$(realpath -- "$source_dir")"
        resolved_production="$(realpath -- "$production_dir")"
        case "$resolved_source" in
            "$resolved_production"/*) ;;
            *)
                echo "Refusing unsafe staged-row removal: $resolved_source" >&2
                exit 1
                ;;
        esac
        rm -rf -- "$resolved_source"
    done
}

verify_shard_control() {
    shard_path="$1"
    output_path="$2"
    "$production_python" "$shard_verifier" \
        --manifest "$GOM_PRODUCTION_MANIFEST" \
        --shard "$shard_path" --start "$start" --end "$end" --json \
        > "$output_path"
}

archive_already_present=false
if test -e "$final"; then
    verify_shard_control \
        "$final" "$result_dir/existing_shard_control_verification.json"
    archive_already_present=true
else
    test ! -e "$incoming"
    mkdir -p "$incoming/payload/cases" \
        "$incoming/payload/stages/campaign_check" \
        "$incoming/payload/slurm_logs"
    cp -- "$check_root/campaign_check_summary.txt" \
        "$check_root/validation.txt" \
        "$check_root/PASS" \
        "$incoming/payload/stages/campaign_check/"

    printf 'task\tcase_key\tgeology_id\trealization_id\n' \
        > "$incoming/CASE_INDEX.tsv"
    for task in $(seq "$start" "$end"); do
        resolved_case="$($production_python "$resolver" \
            --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell)"
        eval "$resolved_case"
        case_key="$GOM_PRODUCTION_CASE_KEY"
        set_case_paths "$task" "$case_key"

        test -f "$preflight_case/PASS"
        test -f "$full_case/PASS"
        test -f "$vtu_case/PASS"
        grep -Fxq 'status=pass' "$preflight_case/preflight_summary.txt"
        if test "$GOM_PRODUCTION_PHYSICS_PROFILE" = \
            sandpc_effective_globalplateau_v1; then
            grep -Fxq "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
                "$preflight_case/preflight_summary.txt"
        fi
        grep -Fxq 'status=pass' "$full_case/production_summary.txt"
        grep -Fxq "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
            "$full_case/production_summary.txt"
        grep -Fxq "case_key=$case_key" "$full_case/production_summary.txt"
        grep -Fxq 'steps_completed=210' "$full_case/production_summary.txt"
        grep -Fxq 'retained_restart_steps=51,78,110,210' \
            "$full_case/production_summary.txt"
        grep -Fxq "production_qoi_mode=$GOM_PRODUCTION_QOI_MODE" \
            "$full_case/production_summary.txt"
        case "$GOM_PRODUCTION_PHYSICS_PROFILE" in
            legacy_fault_plateau_npctheta30)
                grep -Fxq 'fault_pc_entry_treatment=plateau' \
                    "$full_case/production_summary.txt"
                ;;
            sandpc_effective_globalplateau_v1)
                grep -Fxq 'fault_pc_entry_treatment=plateau_all_active' \
                    "$full_case/production_summary.txt"
                ;;
        esac
        grep -Fxq 'status=pass' "$vtu_case/export_summary.txt"
        (
            cd "$full_case"
            sha256sum --check RETAINED_RESTART_SHA256.txt
            sha256sum --check PRODUCTION_SUMMARY_SHA256.txt
        )
        (
            cd "$vtu_case"
            sha256sum --check VTU_SHA256.txt
        )

        destination="$incoming/payload/cases/$case_key"
        mkdir -p "$destination"
        cp -a -- "$preflight_case" "$destination/preflight"
        cp -a -- "$full_case" "$destination/production"
        cp -a -- "$vtu_case" "$destination/vtu"
        if test "$GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS" = true; then
            compact_atomic_rows \
                "$destination/production/restart/production_output"
        fi
        printf '%s\t%s\t%s\t%s\n' \
            "$task" "$case_key" "$GOM_PRODUCTION_GEOLOGY_ID" \
            "$GOM_PRODUCTION_REALIZATION_ID" >> "$incoming/CASE_INDEX.tsv"

        copy_log_if_present \
            "$gom_root/logs/${preflight_log_prefix}-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.out" \
            "$incoming/payload/slurm_logs"
        copy_log_if_present \
            "$gom_root/logs/${preflight_log_prefix}-${GOM_PRODUCTION_PREFLIGHT_JOB_ID}_${task}.err" \
            "$incoming/payload/slurm_logs"
        copy_log_if_present \
            "$gom_root/logs/${full_log_prefix}-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.out" \
            "$incoming/payload/slurm_logs"
        copy_log_if_present \
            "$gom_root/logs/${full_log_prefix}-${GOM_PRODUCTION_FULL_JOB_ID}_${task}.err" \
            "$incoming/payload/slurm_logs"
        copy_log_if_present \
            "$gom_root/logs/${vtu_log_prefix}-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.out" \
            "$incoming/payload/slurm_logs"
        copy_log_if_present \
            "$gom_root/logs/${vtu_log_prefix}-${GOM_PRODUCTION_VTU_JOB_ID}_${task}.err" \
            "$incoming/payload/slurm_logs"
    done

    cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
    cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
        "$incoming/campaign.toml.sha256.original"
    git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD \
        > "$incoming/JUTULDARCY_COMMIT.txt"
    printf '%s\n' \
        "status=ready_for_promotion" \
        "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
        "task_start=$start" \
        "task_end=$end" \
        "case_count=$shard_case_count" \
        "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
        "preflight_job_id=$GOM_PRODUCTION_PREFLIGHT_JOB_ID" \
        "full_job_id=$GOM_PRODUCTION_FULL_JOB_ID" \
        "vtu_job_id=$GOM_PRODUCTION_VTU_JOB_ID" \
        "archive_job_id=$SLURM_JOB_ID" \
        "atomic_rows_compacted=$GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS" \
        "archive_started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$incoming/SHARD_METADATA.txt"

    (
        cd "$incoming"
        find . -type f ! -name SHA256SUMS ! -name SHARD_COMPLETE -print0 |
            LC_ALL=C sort -z |
            xargs -0 sha256sum > SHA256SUMS
        test -s SHA256SUMS
        sha256sum --check SHA256SUMS
    )
    sha256sums_sha256="$(sha256sum "$incoming/SHA256SUMS" | awk '{print $1}')"
    printf '%s\n' \
        "status=pass" \
        "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "physics_profile=$GOM_PRODUCTION_PHYSICS_PROFILE" \
        "task_start=$start" \
        "task_end=$end" \
        "case_count=$shard_case_count" \
        "all_payload_sha256_verified_before_atomic_promote=true" \
        "sha256sums_sha256=$sha256sums_sha256" \
        "promoted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$incoming/SHARD_COMPLETE"
    verify_shard_control \
        "$incoming" "$result_dir/staged_shard_control_verification.json"
    mv -- "$incoming" "$final"
    verify_shard_control \
        "$final" "$result_dir/promoted_shard_control_verification.json"
fi

scratch_removed=false
if test "$GOM_PRODUCTION_ARCHIVE_REMOVE_VERIFIED_SCRATCH" = true; then
    for task in $(seq "$start" "$end"); do
        resolved_case="$($production_python "$resolver" \
            --manifest "$GOM_PRODUCTION_MANIFEST" \
            resolve --task "$task" --format shell)"
        eval "$resolved_case"
        case_key="$GOM_PRODUCTION_CASE_KEY"
        set_case_paths "$task" "$case_key"
        for target_and_root in \
            "$preflight_case|$preflight_root" \
            "$full_case|$full_root" \
            "$vtu_case|$vtu_root"
        do
            target="${target_and_root%%|*}"
            allowed_root="${target_and_root#*|}"
            test -d "$target" || continue
            test -f "$target/PASS"
            resolved_target="$(realpath -- "$target")"
            resolved_allowed="$(realpath -- "$allowed_root")"
            case "$resolved_target" in
                "$resolved_allowed"/*) ;;
                *)
                    echo "Refusing unsafe scratch removal: $resolved_target" >&2
                    exit 1
                    ;;
            esac
            rm -rf -- "$resolved_target"
        done
    done
    scratch_removed=true
fi

printf '%s\n' \
    "status=pass" \
    "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "task_start=$start" \
    "task_end=$end" \
    "case_count=$shard_case_count" \
    "archive_path=$final" \
    "archive_already_present=$archive_already_present" \
    "atomic_rows_compacted=$GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS" \
    "sha256sums_sha256=$(sha256sum "$final/SHA256SUMS" | awk '{print $1}')" \
    "scratch_removed=$scratch_removed" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/archive_summary.txt"
printf '%s\n' \
    "archive_path=$final" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    > "$result_dir/ARCHIVE_POINTER.txt"
printf 'PASS\n' > "$result_dir/PASS"
