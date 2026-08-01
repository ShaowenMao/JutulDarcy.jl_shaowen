# Step62 effective-Pc/global-plateau comparison workflow

This is a new, opt-in workflow for canonical manifest tasks 5–7 and the
independent task-1 add-on. It does not modify or reuse the accepted
`gom_step62_sandpc_ycap50_*` workflow, input directories, result directories,
or restart files.

The canonical MRST physics profile is:

```text
sandpc_effective_globalplateau_v1
```

Use a campaign ID containing every identifying token, for example:

```text
step62_new3_sandpc_ycap50_effective_globalplateau_v1
```

## Locked physics

- Step62 grid, 87 slices, 2,165,082 cells.
- Hysteresis remains enabled with `S_min=0.05`.
- PREDICT fault imbibition tables remain drainage-equivalent.
- JutulDarcy computes transmissibility from the grid and rock.
- The 30-degree sand reference is mapped through effective gas saturation.
- Pc mapping schema is `gom_effective_saturation_pc_v1`.
- Mapping method is `entry_renormalized_analytic_brooks_corey`.
- Reference `Swi=0.05`; host target `Swi=0.3092`; non-PREDICT target
  `Swi=0.3696`.
- The 1.1 MPa cap is applied to the reference curve before Leverett scaling.
- The effective-Pc tail uses 36 log-spaced effective-water nodes, a 1% dense
  relative-error contract, and an adjacent-Pc ratio limit of 2.
- Non-PREDICT Younger keeps the independently versioned
  `[50,500,500] mD` local tensor asset:
  `faultPermSGR_Gupper87lyr_predictMesh_youngerkxx50_effective_globalplateau_v1.mat`.

MRST exports unplateaued curves. Jutul applies
`FAULT_PC_ENTRY_TREATMENT=plateau_all_active` to all 530 active drainage
tables. For every table, Pc is held at its first strictly positive entry value
from `Sg=0` through the entry node. All later Pc nodes, every Sg/Kr column,
and all eight shared/base imbibition tables remain unchanged. This profile has
530 nonzero-entry tables, so preflight requires:

```text
active=530
nonzero_entry=530
adjusted=530
already_plateaued=0
true_zero=0
skipped=0
```

The 522 explicit PREDICT imbibition tables are mirrored after the plateau so
they remain exact drainage duplicates. Preflight records deterministic
SHA-256 contracts for input/output drainage tables, Sg/Kr, the preserved Pc
tails, and base imbibition.

## Input preparation

Preparation must still produce the full canonical seven-row derived manifest.
Simulation submission is restricted to canonical tasks 1, 5, 6, and 7, with
an explicit task-set selector.

```bash
export MRST_ROOT=/path/to/mrst
export MRST_PREP_REPO=/path/to/mrst_predict_sim_grid_dev
export JUTULDARCY_COMBINED_REPO=/path/to/JutulDarcy
export GOM_EFFECTIVE_PC_SOURCE_MANIFEST=/absolute/path/source_manifest.csv
export GOM_EFFECTIVE_PC_CAMPAIGN_ID=step62_new3_sandpc_ycap50_effective_globalplateau_v1
export GOM_PRODUCTION_ARCHIVE_ROOT=/orcd/data/juanes/001/shaowen/gom_grid
export GOM_EFFECTIVE_PC_DERIVED_DIR="$GOM_PRODUCTION_ARCHIVE_ROOT/inputs/$GOM_EFFECTIVE_PC_CAMPAIGN_ID"
export GOM_EFFECTIVE_PC_CAMPAIGN_DIR="$GOM_PRODUCTION_ARCHIVE_ROOT/campaign_manifests/$GOM_EFFECTIVE_PC_CAMPAIGN_ID"

sbatch \
  "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_input_prepare.sbatch"
```

Preparation refuses existing derived/campaign directories, requires clean
pinned MRST and JutulDarcy repositories, verifies every generated checksum,
and builds the normal immutable seven-case campaign manifest. Both generated
input and campaign directories must be beneath the durable archive root, so
later scratch cleanup cannot invalidate the archived manifest.

## Submission

For an unattended prepare-then-submit workflow, capture the preparation job
ID and submit the fail-closed launcher with an `afterok` dependency:

```bash
prepare_job=$(sbatch --parsable \
  "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_input_prepare.sbatch")
prepare_job=${prepare_job%%;*}
sbatch --dependency="afterok:$prepare_job" \
  --export="ALL,GOM_EFFECTIVE_PC_INPUT_PREPARE_JOB_ID=$prepare_job" \
  "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_submit_after_prepare.sbatch"
```

The launcher verifies the durable preparation PASS marker and immutable
campaign manifest before submitting the simulation dependency graph.

For a manual launch after preparation has already passed:

```bash
export GOM_PRODUCTION_MANIFEST=/absolute/path/campaign/campaign.toml
export JUTULDARCY_COMBINED_REPO=/path/to/pinned/JutulDarcy

bash \
  "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_submit.sh"
```

The submitted dependency graph is:

```text
campaign check
  -> preflight [selected tasks]
  -> three-step smoke/restart check [selected tasks]
  -> full 1000-year run [selected tasks]
  -> compact VTU export [selected tasks]
  -> atomic archive
```

The default remains canonical tasks `5:6:7`. Set
`GOM_EFFECTIVE_PC_TASK_SET=1` for the independently archived task-1 add-on,
or `GOM_EFFECTIVE_PC_TASK_SET=1:5:6:7` for a fresh combined four-case
campaign. No other task sets are accepted. Canonical task 1 is
`s05_c012_case01`.

There is no array concurrency limit. Full runs request 8 CPUs and 18 GiB.
The default walltime is 24 hours. `GOM_EFFECTIVE_PC_FULL_WALLTIME` may
increase it, but the submission script rejects any value below 24 hours.
This protects the historically slow case 5, which previously required about
14 h 41 min.

Every smoke and full directory is new. Full runs force
`RESTART_RUN=false`; no checkpoint from an older physics profile is eligible.
The smoke-stage resume is internal to the same new three-step smoke case and
is checked against an uninterrupted control for task 5.

## Outputs and diagnostics

The production-output/QoI schema and masks remain unchanged: 55 atomic
regions, 69 reporting regions, and 193 interfaces.

In addition to the existing QoI files, this workflow records:

- total ministeps, Newton iterations, and linear iterations;
- failed/rejected ministeps and wasted iterations;
- smallest report step;
- maximum gas saturation in host regions and non-PREDICT fault regions;
- maximum piecewise Pc slope;
- explicit `unavailable` markers where production-output v1 does not retain
  accepted ministep sizes or cellwise cap-onset interval counts.

Only restart steps 78 and 210 are retained. Compact VTUs contain the same
established simulation arrays as the accepted workflow. Their two categorical
geology indicators use schema `gom_vtu_geology_indicators_v2`:

- `stratigraphy_region_flag`: `0` outside Al/Ar, `1` sand, `2` clay;
- `fault_region_flag`: `0` outside the fault, `1` PREDICT, `2` non-PREDICT.

The facies and fault classifications come from exact split-input metadata and
are cross-checked against primary UCIDs and assembled masks. They are not
inferred from permeability, saturation-region numbers, or coordinates.
Archive promotion is staged, checksum-verified, and atomic. Scratch results
are not deleted automatically.

For a completed campaign whose immutable simulation commit predates indicator
schema v2, use
`gom_step62_effective_pc_global_plateau_vtu_reexport.sbatch`. It keeps the
original repository as the manifest and Julia-project authority, requires a
separate clean and commit-pinned export repository, verifies that both
repositories have identical simulation source trees and manifests, and writes
to a new result directory. It never modifies or reruns the simulation.

## Validation-only recovery

The versioned recovery entry points are:

```text
gom_step62_effective_pc_global_plateau_recovery_preflight.sbatch
gom_step62_effective_pc_global_plateau_recovery_finalize.sbatch
```

They recover only a fully completed simulation that exited after the known
Julia multiline-range parse error in the final validator. They require all
210 production/QoI bundles, both completion markers, restart steps 78 and
210, the effective-Pc preflight contract, the exact original error signature,
and the original failed exit status. Any numerical failure or incomplete
output therefore fails closed. Neither script invokes the simulator.
New campaigns are protected earlier: the campaign check parses every
Engaging Julia entry point with the pinned Julia 1.10.4 runtime before any
smoke or full simulation becomes eligible.

Keep the original simulation repository separate from a clean immutable
recovery repository:

```bash
export GOM_EFFECTIVE_PC_SIMULATION_REPO=/path/to/original/manifest-pinned/repo
export GOM_EFFECTIVE_PC_RECOVERY_REPO=/path/to/fixed/immutable/repo
export GOM_EFFECTIVE_PC_RECOVERY_COMMIT=$(git \
  -C "$GOM_EFFECTIVE_PC_RECOVERY_REPO" rev-parse HEAD)
export GOM_PRODUCTION_MANIFEST=/path/to/original/campaign.toml
export GOM_PRODUCTION_FULL_JOB_ID=123456
export GOM_EFFECTIVE_PC_TASK_SET=5:6:7

preflight_job=$(sbatch --parsable \
  --array=5-7 \
  --dependency="afterany:$GOM_PRODUCTION_FULL_JOB_ID" \
  "$GOM_EFFECTIVE_PC_RECOVERY_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_recovery_preflight.sbatch")
preflight_job=${preflight_job%%;*}

finalize_job=$(sbatch --parsable \
  --array=5-7 \
  --dependency="afterok:$preflight_job" \
  --export="ALL,GOM_EFFECTIVE_PC_RECOVERY_PREFLIGHT_JOB_ID=$preflight_job" \
  "$GOM_EFFECTIVE_PC_RECOVERY_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_recovery_finalize.sbatch")
finalize_job=${finalize_job%%;*}
```

For the independent task-1 campaign, set
`GOM_EFFECTIVE_PC_TASK_SET=1` and override both arrays with `--array=1`.
The original repository remains the Julia project and manifest authority.
The recovery repository supplies only the corrected validator and recovery
workflow; both commits and all relevant script/source hashes are recorded.

The preflight hashes the complete restart/QoI tree and
`PREFLIGHT_PC_TABLE_CONTRACT.txt`. The finalizer rechecks those hashes under
the case lock, runs the corrected validator and the original runtime
diagnostics, reconstructs the exact effective-Pc summary/hash contract, and
atomically promotes `RECOVERY_PASS` and `PASS` last. It is idempotent after a
fully verified promotion.

Pending VTU elements may be redirected to depend on the successful recovery
finalizer, preserving their original VTU result root and archive dependency:

```bash
scontrol update JobId=VTU_ARRAY_ID_5 Dependency=afterok:$finalize_job
scontrol update JobId=VTU_ARRAY_ID_6 Dependency=afterok:$finalize_job
scontrol update JobId=VTU_ARRAY_ID_7 Dependency=afterok:$finalize_job
```

Use only `_1` for a task-1 VTU array. Verify every updated dependency with
`scontrol show job`. If per-element dependency updates are unavailable,
cancel only the blocked VTU/archive stages and submit replacements after the
recovery finalizer; do not resubmit the simulation.

## Checkpoint continuation for an incomplete task 5

`gom_step62_effective_pc_global_plateau_continuation.sbatch` is the
simulation-resume path for a full task 5 that stopped at its walltime before
report step 210. It is separate from the validation-only recovery above.

The continuation fails closed unless scalar and QOI row bundles are
contiguous and have equal counts. It selects the newest checkpoint no later
than that common row count, resumes at the following report step, preserves
`PRODUCTION_QOI_MODE=required`, and writes into the original case directory
under its production-output lock. The original campaign repository remains
the simulation and Julia-project authority. The continuation repository
provides only the commit-pinned wrapper and corrected final validator.

After reaching step 210, the same job checks both output-completion markers,
validates the final state and runtime diagnostics, rebuilds retained-restart
and summary checksums, and promotes `CONTINUATION_PASS` and `PASS` last. A
retry after a verified `PASS` is an idempotent no-op.

Continuation finalization writes validator products into a new atomic staging
directory. Before Julia starts, the wrapper copies the original case
`RUN_METADATA.txt` beside the staged validator output and byte-compares it
against the source. This is required because the effective-Pc validator
resolves its immutable run contract relative to the output path. The staged
metadata SHA-256 is recorded in
`CONTINUATION_FINALIZATION_METADATA.txt`, preventing a completed future
continuation from failing only because its validator context is incomplete.

Set `GOM_EFFECTIVE_PC_CONTINUATION_PREFLIGHT_ONLY=true` for a read-only
checkpoint/QOI audit. It validates and hashes the selected checkpoint but
does not invoke the simulator or modify the source case.

Example:

```bash
export GOM_PRODUCTION_MANIFEST=/path/to/original/campaign.toml
export GOM_EFFECTIVE_PC_FULL_JOB_ID=123456
export GOM_EFFECTIVE_PC_TASK_SET=5:6:7
export GOM_EFFECTIVE_PC_SIMULATION_REPO=/path/to/original/immutable/repo
export GOM_EFFECTIVE_PC_CONTINUATION_REPO=/path/to/continuation/repo
export GOM_EFFECTIVE_PC_CONTINUATION_COMMIT=$(git \
  -C "$GOM_EFFECTIVE_PC_CONTINUATION_REPO" rev-parse HEAD)

sbatch --array=5 \
  "$GOM_EFFECTIVE_PC_CONTINUATION_REPO/scripts/engaging/gom_step62_effective_pc_global_plateau_continuation.sbatch"
```
