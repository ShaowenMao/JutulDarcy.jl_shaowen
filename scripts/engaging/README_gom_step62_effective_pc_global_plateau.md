# Step62 effective-Pc/global-plateau comparison workflow

This is a new, opt-in workflow for canonical manifest tasks 5–7. It does not
modify or reuse the accepted `gom_step62_sandpc_ycap50_*` workflow, input
directories, result directories, or restart files.

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
Only simulation submission is restricted to tasks 5–7.

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
  -> preflight [5-7]
  -> three-step smoke/restart check [5-7]
  -> full 1000-year run [5-7]
  -> compact VTU export [5-7]
  -> atomic archive
```

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
established arrays as the accepted workflow; no extra simulation fields are
added. Archive promotion is staged, checksum-verified, and atomic. Scratch
results are not deleted automatically.
