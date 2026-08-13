#!/bin/bash
# Validate the phase-1 2,430-case production contract on Engaging.
# This job runs test fixtures only; it does not read production cases or run simulations.
#SBATCH --job-name=gom_p1_contract_tests
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=12G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail
umask 027

: "${GOM_JUTUL_REPO:?Set the immutable JutulDarcy checkout.}"
: "${GOM_JUTUL_COMMIT:?Set its exact 40-character commit.}"
: "${GOM_JUTUL_MANIFEST_SHA256:?Set the pinned Julia Manifest.toml SHA-256.}"

[[ "$GOM_JUTUL_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$GOM_JUTUL_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
test -f "$GOM_JUTUL_REPO/Project.toml"
test -f "$GOM_JUTUL_REPO/Manifest.toml"

observed_commit="$(git -C "$GOM_JUTUL_REPO" rev-parse HEAD)"
observed_manifest_sha256="$(sha256sum "$GOM_JUTUL_REPO/Manifest.toml" | awk '{print $1}')"
test "$observed_commit" = "$GOM_JUTUL_COMMIT" || {
    echo "JutulDarcy checkout does not match GOM_JUTUL_COMMIT." >&2
    exit 2
}
test "$observed_manifest_sha256" = "$GOM_JUTUL_MANIFEST_SHA256" || {
    echo "Manifest.toml does not match GOM_JUTUL_MANIFEST_SHA256." >&2
    exit 2
}
test -z "$(git -C "$GOM_JUTUL_REPO" status --porcelain --untracked-files=no)" || {
    echo "JutulDarcy tracked checkout must be clean." >&2
    exit 2
}

result_dir="${GOM_CONTRACT_TEST_RESULT_DIR:-$HOME/orcd/scratch/gom_grid/contract_tests/phase1_2430_job${SLURM_JOB_ID}}"
test ! -e "$result_dir" || {
    echo "Refusing to replace contract-test result: $result_dir" >&2
    exit 2
}
mkdir -p "$result_dir"
printf 'job_id=%s\nstarted_utc=%s\n' \
    "$SLURM_JOB_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$result_dir/INCOMPLETE"

record_exit_status() {
    exit_code=$?
    printf 'exit_code=%s\nfinished_utc=%s\n' \
        "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$result_dir/exit_status.txt"
}
trap record_exit_status EXIT

module purge
module load community-modules
module load julia/1.10.4
export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
python_exe="${GOM_PRODUCTION_PYTHON:-python3.12}"
command -v "$python_exe" >/dev/null

cd "$GOM_JUTUL_REPO"
"$python_exe" test/production_manifest.py \
    > "$result_dir/production_manifest.txt" 2>&1
"$python_exe" test/production_sliding_launcher.py \
    > "$result_dir/production_sliding_launcher.txt" 2>&1
julia --startup-file=no --project=. test/engaging_script_compat.jl \
    > "$result_dir/engaging_script_compat.txt" 2>&1
julia --startup-file=no --project=. test/mrst_input_contract.jl \
    > "$result_dir/mrst_input_contract.txt" 2>&1

printf '%s\n' \
    "schema=gom_phase1_2430_contract_test_v1" \
    "status=pass" \
    "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "job_id=$SLURM_JOB_ID" \
    "node=$SLURMD_NODENAME" \
    "jutul_repo=$GOM_JUTUL_REPO" \
    "jutul_commit=$observed_commit" \
    "julia_manifest_sha256=$observed_manifest_sha256" \
    "julia_version=$(julia --startup-file=no -e 'print(VERSION)')" \
    "python_version=$($python_exe --version 2>&1)" \
    > "$result_dir/TEST_METADATA.txt"
(
    cd "$result_dir"
    sha256sum production_manifest.txt production_sliding_launcher.txt \
        engaging_script_compat.txt mrst_input_contract.txt \
        TEST_METADATA.txt > TEST_SHA256SUMS.txt
    sha256sum --check TEST_SHA256SUMS.txt
)
rm -- "$result_dir/INCOMPLETE"
printf 'PASS\n' > "$result_dir/PASS"
printf 'CONTRACT_TESTS_READY=%s\n' "$result_dir"
