#!/bin/bash
# Submit one immutable, non-destructive equilibrium-control array.

set -euo pipefail
umask 027

: "${GOM_PRODUCTION_MANIFEST:?Set the checksum-pinned production manifest.}"
: "${JUTULDARCY_COMBINED_REPO:?Set the immutable production JutulDarcy repo.}"
: "${GOM_EQUILIBRIUM_DIAGNOSTIC_REPO:?Set the immutable diagnostic repo.}"
: "${GOM_EQUILIBRIUM_RESULT_ROOT:?Set the durable diagnostic result root.}"
: "${GOM_EQUILIBRIUM_RUN_ID:?Set a unique diagnostic run ID.}"
: "${GOM_EQUILIBRIUM_ARRAY_SPEC:?Set a Slurm array such as 17 or 17,60,134.}"

command -v sbatch >/dev/null
diagnostic_commit="$(git -C "$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO" rev-parse HEAD)"
test -n "$diagnostic_commit"
test -z "$(git -C "$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO" status --porcelain)" || {
    echo "Diagnostic repository must be clean before submission." >&2
    exit 1
}
test ! -e "$GOM_EQUILIBRIUM_RESULT_ROOT/$GOM_EQUILIBRIUM_RUN_ID" || {
    echo "Run ID already exists: $GOM_EQUILIBRIUM_RUN_ID" >&2
    exit 1
}

scripts="$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO/scripts/engaging"
mkdir -p "$GOM_EQUILIBRIUM_RESULT_ROOT/submissions"
export GOM_EQUILIBRIUM_DIAGNOSTIC_COMMIT="$diagnostic_commit"
job_id="$(
    sbatch --parsable \
        --array="$GOM_EQUILIBRIUM_ARRAY_SPEC" \
        --export=ALL \
        "$scripts/gom_step62_initial_equilibrium.sbatch"
)"
job_id="${job_id%%;*}"
[[ "$job_id" =~ ^[0-9]+$ ]] || {
    echo "Unexpected Slurm job ID: $job_id" >&2
    exit 1
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
receipt="$GOM_EQUILIBRIUM_RESULT_ROOT/submissions/${GOM_EQUILIBRIUM_RUN_ID}_${timestamp}.txt"
cat > "$receipt" <<EOF
submitted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
job_id=$job_id
run_id=$GOM_EQUILIBRIUM_RUN_ID
array_spec=$GOM_EQUILIBRIUM_ARRAY_SPEC
report_years=${GOM_EQUILIBRIUM_REPORT_YEARS:-default}
initial_pressure_mode=${GOM_EQUILIBRIUM_PRESSURE_MODE:-imported}
campaign_manifest=$GOM_PRODUCTION_MANIFEST
campaign_manifest_sha256=$(sha256sum "$GOM_PRODUCTION_MANIFEST" | awk '{print $1}')
production_repo=$JUTULDARCY_COMBINED_REPO
production_commit=$(git -C "$JUTULDARCY_COMBINED_REPO" rev-parse HEAD)
diagnostic_repo=$GOM_EQUILIBRIUM_DIAGNOSTIC_REPO
diagnostic_commit=$diagnostic_commit
result_root=$GOM_EQUILIBRIUM_RESULT_ROOT
EOF
echo "EQUILIBRIUM_JOB_ID=$job_id"
echo "EQUILIBRIUM_RECEIPT=$receipt"
