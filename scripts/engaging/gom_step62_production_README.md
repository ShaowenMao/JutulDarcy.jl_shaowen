# Step62 seven-case production-output pilot

This workflow runs the canonical seven correlated geology cases with bounded
scratch output and immutable input provenance. It is a pilot for the later
production ensemble; it does not delete any scratch result.

## Locked scientific and numerical configuration

All seven tasks use:

```text
grid=Step62
slices=87
cells=2,165,082
schedule=210 report steps / 1,000 years
injection_end=report step 78 / 50 years
hysteresis=true
hysteresis_s_min=0.05
explicit_fault_hysteresis=drainage-equivalent
fault_pc_entry_treatment=plateau
fault_pc_entry_sg_max=1e-4
non-PREDICT Pc reference contact angle=30 degrees
transmissibility=calculated by JutulDarcy
well_volume_fraction=1e-3
production_output_mode=true
production_qoi_mode=off for legacy inputs; required for regenerated QoI inputs
```

The full array requests 8 CPUs and 18 GiB per task through the
`mit_amf_advanced_cpu` account/QoS. Slurm may run all eligible cases
concurrently.

## Canonical task identity

Task order is part of the manifest contract:

| Task | Case key | Geology ID | Realization |
|---:|---|---|---:|
| 1 | `s05_c012_case01` | `s05_c012` | 1 |
| 2 | `s05_c012_case03` | `s05_c012` | 3 |
| 3 | `s05_c012_case04` | `s05_c012` | 4 |
| 4 | `s05_c012_case07` | `s05_c012` | 7 |
| 5 | `s03_c001_case04` | `s03_c001` | 4 |
| 6 | `s03_c012_case08` | `s03_c012` | 8 |
| 7 | `s04_c024_case03` | `s04_c024` | 3 |

The full case key is always used in paths. Therefore, the two `case03` inputs
and the two `case04` inputs cannot be confused.

## Immutable manifest

The jobs accept prepared split-v3 Jutul inputs, not the raw PREDICT
`full_slice` packages. The paths should point to the frozen ORCD input area,
not a disposable scratch preparation directory. Create an absolute-path TOML
with this shape:

```toml
schema_version = 1
campaign_id = "step62_production_output_pilot_7case_v1"
archive_root = "/orcd/data/juanes/001/shaowen/gom_grid"
source_input_manifest_sha256 = "64-lowercase-hex-characters"
mrst_prepare_commit = "40-lowercase-hex-characters"
jutuldarcy_commit = "40-lowercase-hex-characters"
jutul_manifest_sha256 = "64-lowercase-hex-characters"

[common]
path = "/absolute/immutable/path/gom_step62_87slice_7case_common.mat"
sha256 = "64-lowercase-hex-characters"
bytes = 123456

[[cases]]
task = 1
case_key = "s05_c012_case01"
geology_id = "s05_c012"
geology_hash = "64-lowercase-hex-characters"
realization_id = 1
level3_case_name = "independent_draw_1"
specific_path = "/absolute/immutable/path/s05_c012_case01_specific.mat"
specific_sha256 = "64-lowercase-hex-characters"
specific_bytes = 123456

# Repeat [[cases]] in the exact table order above through task 7.
```

The safer route is to generate both the TOML and its companion directly from
the MRST-derived CSV:

```bash
python3.12 scripts/engaging/gom_step62_production_build_manifest.py \
  --derived-manifest /absolute/path/derived_split_input_manifest.csv \
  --campaign-id step62_production_output_pilot_7case_v1 \
  --archive-root /orcd/data/juanes/001/shaowen/gom_grid \
  --jutuldarcy-commit "$jutuldarcy_commit" \
  --jutul-manifest-sha256 "$jutul_manifest_sha256" \
  --mrst-prepare-commit "$mrst_prepare_commit" \
  --source-input-manifest-sha256 "$source_manifest_sha256" \
  --output /absolute/path/campaign.toml
```

The resolver rejects:

- a missing or mismatched companion SHA-256;
- a noncanonical, duplicated, or reordered case key;
- relative paths or paths containing glob characters;
- a missing common or specific MAT;
- any MAT whose SHA-256 differs from the manifest; and
- any MAT whose byte count differs from the manifest;
- a JutulDarcy checkout whose commit differs from the manifest; and
- a missing or altered Jutul `Manifest.toml`; and
- an archive root outside
  `/orcd/data/juanes/001/shaowen/gom_grid`.

Validate before submission:

```bash
python3.12 scripts/engaging/gom_step62_production_manifest.py \
  --manifest "$GOM_PRODUCTION_MANIFEST" validate --json
```

## Submission

On Engaging:

```bash
export GOM_PRODUCTION_MANIFEST=/absolute/path/campaign.toml
export JUTULDARCY_COMBINED_REPO=/absolute/path/JutulDarcy.jl_shaowen
export GOM_GRID_ROOT="$HOME/orcd/scratch/gom_grid"

bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_submit.sh"
```

The submitter creates one `afterok` DAG:

```text
campaign check
  -> 7-case preflight array
  -> 7-case three-step production-output smoke array
  -> 7-case 1,000-year full array
  -> 7-case initial/50-year/1,000-year VTU array
  -> atomic archive job
```

No array throttle is applied by default. A submission receipt containing all
job IDs is written below `gom_grid/submissions`.

For a deliberately selected subset, override each array at submission with
the same explicit task list and export that list to the archive job, for
example `--array=5,6,7` and `GOM_PRODUCTION_TASKS=5:6:7`. The archive then
validates and promotes only those cases while preserving their canonical
manifest task identities.

## Production-output contract

The current full-run profile retains exact report-boundary checkpoints at
25, 50, 100, and 1,000 years (steps 51, 78, 110, and 210). During a running
case, scratch holds every milestone already reached plus the two newest
restart-safe rolling checkpoints. The peak is therefore five JLD2 files per
active case after 100 years; completion removes the rolling files and leaves
exactly the four milestones. Every closed report step writes one small,
atomic TSV summary row before obsolete checkpoints are removed.

A Step62 restart is approximately 254 MB in the measured pilot outputs. Four
final checkpoints therefore require about 1.02 GB per case (approximately
1.65 TB for 1,620 archived cases), while the five-file running peak is about
1.27 GB per active case. Keeping the two additional milestones does not add
restart writes: Jutul already writes each report-step restart atomically and
the retention policy controls which files are deleted. It adds only two final
validation reads and does not impose a new array-concurrency limit.

## Recovering an interrupted immutable campaign

Use `gom_step62_production_recovery_submit.sh` only when an existing campaign
has complete or restart-safe full-run outputs but its downstream validation,
VTU, or archive stages did not finish. The recovery workflow preserves the
manifest-pinned simulation runtime, resumes only incomplete cases in place,
uses a separately checksum-pinned corrected validator, and writes recovery
metadata without replacing the original Slurm logs or exit status.
Submission is campaign-locked against duplicate active DAGs, and its receipt
is copied to durable campaign storage before the submission is considered
complete.

For the legacy r4 seven-case pilot, six cases are validation-only. Task 5
resumes from its latest explicitly selected valid checkpoint. VTU and archive
stages remain dependency-gated until all seven case directories contain
verified restart hashes, production summaries, and PASS markers.

The final checker reads the immutable `production_config.tsv` and supports
the legacy 50/1,000-year profile solely so those existing campaigns remain
recoverable. The current full-run script independently requires the new
four-checkpoint profile, so a new run cannot silently fall back to the legacy
contract.

For schema-2 shard recovery, the VTU array covers the complete affected shard
but the recovery-case array contains only explicitly selected incomplete
tasks. Selected tasks must carry a recovery-attempt `PASS` marker bound to the
recovery-plan SHA-256 before VTU export. Unselected tasks must have no recovery
attempt directory and are exported directly from their gate-validated original
result trees. This distinction prevents complete unchanged cases from being
rejected during mixed-shard postprocessing.

After successful report step 210, each current-profile case contains:

- exactly 210 per-step summary rows;
- one consolidated `report_steps.tsv`;
- `PRODUCTION_OUTPUT_COMPLETE.tsv`;
- restart `jutul_51.jld2` (25 years);
- restart `jutul_78.jld2` (50 years, end of injection);
- restart `jutul_110.jld2` (100 years); and
- restart `jutul_210.jld2` (1,000 years).

The final checker reads all retained states, verifies pressure, saturation,
`Rs`, and `MaxSaturations`, checks all 210 summary rows against the
consolidated table, and requires a nonempty final hysteresis scanning state.
It does not require the deleted intermediate restart files.

### Leakage-risk QoI time series

New split inputs generated with the exact `gom_qoi_semantics_v1` UCID block
should run with:

```bash
export PRODUCTION_QOI_MODE=required
```

The input-label schema `gom_qoi_semantics_v1` is independent of the tabular
QoI output schema version; the current output format is schema 3.

`required` fails before simulation if the common input lacks the exact
primary-UCID partition or the paired specific input lacks Al/Ar
side/unit/facies labels. `auto` enables the logger only when both blocks are
present; `off` retains the legacy production-output behavior. The seven
already-frozen pilot inputs must remain `off` until they are regenerated.

QoI output schema 3 writes one restart-safe bundle per report step and
consolidates it into:

- `leakage_global_steps.tsv`;
- `regional_co2_inventory_steps.tsv`;
- `interface_flux_steps.tsv`;
- `leakage_case_summary.tsv`;
- `qoi_region_manifest.tsv`; and
- `qoi_interface_manifest.tsv`.

The regional partition is UCID-based, exhaustive, and disjoint. It includes
storage LM2; each of Al1–Al21 and Ar1–Ar21; MM–UM; Younger; all nine fault
bands (including W1–W6); and the remaining AmphB complete seal. Aggregate
regions are exact unions of these atoms.

At each report boundary, free-phase CO2 is divided using the exact gas
relative-permeability branch evaluated by the simulator. For Killough
hysteresis, the logger combines the cell's drainage and imbibition endpoints
with its restart-safe historical maximum gas saturation (`MaxSaturations`) to
recover the local zero-mobility endpoint of the active scanning curve. The
same helper computes this endpoint for both the nonlinear solver and the QoI
logger.

The non-overlapping free-phase inventory is:

- `mobile_free`: gas saturation above the active zero-mobility endpoint;
- `drainage_critical_immobile_free`: immobile gas in cells that are currently
  on the drainage (non-history-dependent) branch; and
- `residual_trapped`: the complete immobile gas inventory in cells that are
  currently on an active Killough scanning or bounding imbibition branch.

Consequently, `immobile_free` is exactly
`drainage_critical_immobile_free + residual_trapped`, and `free_co2` is exactly
`mobile_free + immobile_free`. This branch-exclusive definition gives zero
residual-trapped mass before reversal, with hysteresis disabled, and whenever
the simulator evaluates the drainage branch. It reports the complete
zero-mobility gas represented by the active scanning/imbibition curve rather
than interpreting `Sg_max - Sg` as trapped gas.

`hysteresis_incremental_trapped` is retained as a separate, overlapping
diagnostic. It is the portion of `residual_trapped` above the drainage critical
saturation baseline. It therefore measures the incremental immobilization
introduced by hysteresis, is always less than or equal to `residual_trapped`,
and must not be added to the non-overlapping mass partition. In a
drainage-equivalent fault region it can be zero even when the cell is on a
history-dependent branch and its complete immobile inventory is classified as
`residual_trapped`.

Dissolved CO2 uses the black-oil `Rs`, shrinkage factors, fluid volume, and gas
reference mass density. Every regional and global row enforces
`total = free + dissolved`, and the domain inventory is checked against the
gas-component `TotalMasses` field.

Schema 3 also records mobile, immobile, drainage-critical, total residual, and
incremental hysteresis-trapped gas pore volumes; exact scanning/full-
imbibition branch counts; pore-volume-
weighted saturation, pressure, and capillary-pressure statistics; occupied
pore volume at `Sg >= 1e-4`, `1e-3`, and `1e-2`; and mass-weighted centroids
and spreads for free and dissolved CO2. These supplement the retained raw cell
counts and thresholded centroid bounds with less mesh-sensitive diagnostics.
Pressure changes use the exact initial pressure cell by cell. Plume bounds
use `Sg >= 1e-4`; counts are also written for `1e-3` and `1e-2`.
`net_domain_co2_change_kg` is the current domain inventory minus the initial
inventory. In this no-flow, injection-only setup it is also the actual net
injected mass inferred from conservation.

Interface rates use the simulator connection list and black-oil CO2 component
mass flux, including dissolved gas transported in the liquid phase. They are
instantaneous report-endpoint rates. They are not multiplied by a report
duration or presented as cumulative transfer because adaptive ministeps can
make that integration inaccurate.

`leakage_case_summary.tsv` stores interval-censored arrival bounds (the
preceding and first detected report), the final trapping partition, and peak
residual and overburden inventories. Schema 1 and 2 outputs remain valid
historical artifacts, but an older report prefix cannot be resumed with
schema-3 code; the immutable production configuration deliberately rejects
mixed schemas.

Each smoke job stops first at report step 2 and resumes to report step 3. It
requires three atomic summary rows and exactly rolling restart checkpoints 2
and 3. Tasks 1 and 5 additionally run an uninterrupted three-step control and
compare all restart-state arrays at `rtol=1e-12`, covering one established
input and one newly added geology input.

## Standard VTU output

The VTU array resolves the exact full-result case directory from its case key
and full array job ID. Retaining 25- and 100-year restarts does not expand the
default visualization output. The VTU stage continues to export:

- initial condition (0 years);
- retained report step 78 (50 years); and
- retained report step 210 (1,000 years).

The compact standard fields are retained, with the fault-region,
stratigraphy-region, and stratigraphic-unit indicators. Each task verifies
the four exact VTU/PVD output filenames and records their SHA-256 values.

## Atomic archive

The archive job first verifies all stage PASS markers and the retained
restart, production-summary, and VTU checksums. It copies the exact campaign
outputs into:

```text
/orcd/data/juanes/001/shaowen/gom_grid/.incoming/<unique-staging-name>
```

The three-step smoke summaries, per-step TSV evidence, metadata, and logs are
archived, but their disposable rolling JLD2 files are not. The full cases keep
all four retained production checkpoints.

It then writes one archive-wide `SHA256SUMS`, verifies every destination
file, and atomically renames the staging directory to:

```text
/orcd/data/juanes/001/shaowen/gom_grid/campaigns/
  <campaign-id>_fulljob<full-array-job-id>
```

Because promotion is a metadata-only rename within the same ORCD filesystem,
it does not reread the full archive after the verified staging directory is
promoted. This avoids a redundant high-volume storage pass. Scratch is
deliberately left intact for this seven-case validation pilot
(`scratch_removed=false`). Only after the pilot archive and restart behavior
are accepted should a separate, explicitly authorized cleanup policy be
enabled for production.
