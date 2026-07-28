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

During a full run, scratch holds the requested milestone checkpoint plus the
two newest restart-safe checkpoints. Every closed report step writes one
small, atomic TSV summary row before obsolete checkpoints are removed.

After successful report step 210, each case contains:

- exactly 210 per-step summary rows;
- one consolidated `report_steps.tsv`;
- `PRODUCTION_OUTPUT_COMPLETE.tsv`;
- restart `jutul_78.jld2` (50 years, end of injection); and
- restart `jutul_210.jld2` (1,000 years).

The final checker reads both retained states, verifies pressure, saturation,
`Rs`, and `MaxSaturations`, checks all 210 summary rows against the
consolidated table, and requires a nonempty final hysteresis scanning state.
It does not require the deleted intermediate restart files.

### Leakage-risk QoI time series

New split inputs generated with the exact `gom_qoi_semantics_v1` UCID block
should run with:

```bash
export PRODUCTION_QOI_MODE=required
```

`required` fails before simulation if the common input lacks the exact
primary-UCID partition or the paired specific input lacks Al/Ar
side/unit/facies labels. `auto` enables the logger only when both blocks are
present; `off` retains the legacy production-output behavior. The seven
already-frozen pilot inputs must remain `off` until they are regenerated.

The QoI logger writes one restart-safe bundle per report step and consolidates
it into:

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

At each report boundary, free-phase CO2 is divided using the active gas
relative-permeability table's critical gas saturation: gas below that
threshold is reported as `immobile_free`, and gas above it as `mobile_free`.
This is an operational mobility classification; it is not labeled
residually trapped during drainage. Dissolved CO2 uses the black-oil `Rs`,
shrinkage factors, fluid volume, and gas reference mass density. Regional
inventories are checked against the gas-component `TotalMasses` field.
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

Each smoke job stops first at report step 2 and resumes to report step 3. It
requires three atomic summary rows and exactly rolling restart checkpoints 2
and 3. Tasks 1 and 5 additionally run an uninterrupted three-step control and
compare all restart-state arrays at `rtol=1e-12`, covering one established
input and one newly added geology input.

## Standard VTU output

The VTU array resolves the exact full-result case directory from its case key
and full array job ID. It exports:

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
both retained production checkpoints.

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
