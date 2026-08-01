#!/bin/bash
#SBATCH --job-name=gom_s62_prod_finalize
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

# Validate complete shard coverage for one submission without rereading the
# multi-terabyte payload. Each shard was checksummed before its atomic rename;
# this stage verifies those immutable markers, task ranges, and case indexes.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set GOM_PRODUCTION_MANIFEST.}"
: "${JUTULDARCY_COMBINED_REPO:?Set JUTULDARCY_COMBINED_REPO.}"
: "${GOM_PRODUCTION_SELECTION_START:?Set GOM_PRODUCTION_SELECTION_START.}"
: "${GOM_PRODUCTION_SELECTION_END:?Set GOM_PRODUCTION_SELECTION_END.}"
: "${GOM_PRODUCTION_SUBMISSION_ID:?Set GOM_PRODUCTION_SUBMISSION_ID.}"
: "${GOM_PRODUCTION_ARCHIVE_JOB_IDS:?Set GOM_PRODUCTION_ARCHIVE_JOB_IDS.}"

[[ "$GOM_PRODUCTION_SELECTION_START" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_SELECTION_END" =~ ^[0-9]+$ ]]
[[ "$GOM_PRODUCTION_SUBMISSION_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]

gom_root="${GOM_GRID_ROOT:-$HOME/orcd/scratch/gom_grid}"
resolver="$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_manifest.py"
production_python="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$production_python" >/dev/null
summary="$($production_python "$resolver" \
    --manifest "$GOM_PRODUCTION_MANIFEST" summary --format shell)"
eval "$summary"

start="$GOM_PRODUCTION_SELECTION_START"
end="$GOM_PRODUCTION_SELECTION_END"
test "$start" -ge 1
test "$end" -ge "$start"
test "$end" -le "$GOM_PRODUCTION_CASE_COUNT"
selection_count=$((end - start + 1))
expected_shards=$(((selection_count + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1) / GOM_PRODUCTION_ARCHIVE_SHARD_SIZE))

IFS=':' read -r -a archive_job_ids <<< "$GOM_PRODUCTION_ARCHIVE_JOB_IDS"
test "${#archive_job_ids[@]}" -eq "$expected_shards"
for job_id in "${archive_job_ids[@]}"; do
    [[ "$job_id" =~ ^[0-9]+$ ]]
done

result_dir="$gom_root/results/gom_step62_production_finalize_job${SLURM_JOB_ID}"
mkdir -p "$result_dir"
record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

campaign_root="$GOM_PRODUCTION_ARCHIVE_ROOT/campaigns/$GOM_PRODUCTION_CAMPAIGN_ID"
submission_parent="$campaign_root/submissions"
incoming="$submission_parent/.${GOM_PRODUCTION_SUBMISSION_ID}.tmp.${SLURM_JOB_ID}"
final="$submission_parent/$GOM_PRODUCTION_SUBMISSION_ID"
test -d "$campaign_root/shards"
test ! -e "$incoming"
test ! -e "$final"
mkdir -p "$incoming"

printf 'task\tcase_key\tgeology_id\trealization_id\n' \
    > "$incoming/CASE_INDEX.tsv"
printf 'shard\ttask_start\ttask_end\tcase_count\tsha256sums_sha256\n' \
    > "$incoming/SHARD_INDEX.tsv"

cursor="$start"
while test "$cursor" -le "$end"; do
    shard_end=$((cursor + GOM_PRODUCTION_ARCHIVE_SHARD_SIZE - 1))
    if test "$shard_end" -gt "$end"; then
        shard_end="$end"
    fi
    shard_case_count=$((shard_end - cursor + 1))
    shard_name="shard_$(printf '%04d' "$cursor")_$(printf '%04d' "$shard_end")"
    shard="$campaign_root/shards/$shard_name"
    test -d "$shard"
    test -s "$shard/SHA256SUMS"
    test -s "$shard/CASE_INDEX.tsv"
    grep -Fxq 'status=pass' "$shard/SHARD_COMPLETE"
    grep -Fxq "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "$shard/SHARD_COMPLETE"
    grep -Fxq "task_start=$cursor" "$shard/SHARD_COMPLETE"
    grep -Fxq "task_end=$shard_end" "$shard/SHARD_COMPLETE"
    grep -Fxq "case_count=$shard_case_count" "$shard/SHARD_COMPLETE"
    test "$(( $(wc -l < "$shard/CASE_INDEX.tsv") - 1 ))" \
        -eq "$shard_case_count"
    tail -n +2 "$shard/CASE_INDEX.tsv" >> "$incoming/CASE_INDEX.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$shard_name" "$cursor" "$shard_end" "$shard_case_count" \
        "$(sha256sum "$shard/SHA256SUMS" | awk '{print $1}')" \
        >> "$incoming/SHARD_INDEX.tsv"
    cursor=$((shard_end + 1))
done

test "$(( $(wc -l < "$incoming/CASE_INDEX.tsv") - 1 ))" \
    -eq "$selection_count"
awk -F '\t' -v start="$start" -v end="$end" '
    NR == 1 { next }
    {
        expected = start + NR - 2
        if ($1 != expected) exit 1
        if ($2 == "" || seen[$2]++) exit 1
    }
    END {
        if (NR - 1 != end - start + 1) exit 1
    }
' "$incoming/CASE_INDEX.tsv"

cp -- "$GOM_PRODUCTION_MANIFEST" "$incoming/campaign.toml"
cp -- "$GOM_PRODUCTION_MANIFEST.sha256" \
    "$incoming/campaign.toml.sha256.original"
printf '%s\n' \
    "status=pass" \
    "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
    "selection_start=$start" \
    "selection_end=$end" \
    "case_count=$selection_count" \
    "shard_count=$expected_shards" \
    "archive_job_ids=$GOM_PRODUCTION_ARCHIVE_JOB_IDS" \
    "all_shard_markers_validated=true" \
    "all_case_tasks_contiguous_and_unique=true" \
    "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$incoming/SUBMISSION_COMPLETE"
(
    cd "$incoming"
    sha256sum campaign.toml CASE_INDEX.tsv SHARD_INDEX.tsv \
        SUBMISSION_COMPLETE > RECEIPT_SHA256SUMS
    sha256sum --check RECEIPT_SHA256SUMS
)
mv -- "$incoming" "$final"

campaign_complete=false
if test "$start" -eq 1 && \
   test "$end" -eq "$GOM_PRODUCTION_CASE_COUNT" && \
   test "$GOM_PRODUCTION_ENSEMBLE_KIND" = full_1620; then
    campaign_marker="$campaign_root/CAMPAIGN_COMPLETE"
    test ! -e "$campaign_marker"
    temporary="${campaign_marker}.tmp.${SLURM_JOB_ID}"
    printf '%s\n' \
        "status=pass" \
        "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
        "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
        "case_order_sha256=$GOM_PRODUCTION_CASE_ORDER_SHA256" \
        "case_count=$GOM_PRODUCTION_CASE_COUNT" \
        "shard_count=$expected_shards" \
        "submission_receipt=$final" \
        "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$temporary"
    mv -- "$temporary" "$campaign_marker"
    campaign_complete=true
fi

printf '%s\n' \
    "status=pass" \
    "submission_id=$GOM_PRODUCTION_SUBMISSION_ID" \
    "campaign_id=$GOM_PRODUCTION_CAMPAIGN_ID" \
    "campaign_manifest_sha256=$GOM_PRODUCTION_MANIFEST_SHA256" \
    "selection_start=$start" \
    "selection_end=$end" \
    "case_count=$selection_count" \
    "shard_count=$expected_shards" \
    "submission_receipt=$final" \
    "campaign_complete=$campaign_complete" \
    > "$result_dir/finalize_summary.txt"
printf 'PASS\n' > "$result_dir/PASS"
