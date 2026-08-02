# Step62 1,620-case production ensemble

This is the guarded production path for the complete GoM ensemble:

- 6 stratigraphic scenarios;
- 27 geology realizations per scenario;
- 10 fault-property realizations per geology; and
- 1,620 cases in deterministic
  `s01_c001_case01` through `s06_c027_case10` order.

The older seven-case workflow remains available for reproducing and
recovering its frozen campaigns. A full ensemble must use manifest schema 2
and cannot be submitted through this launcher until its acceptance and
canary gates have passed.

## Locked production contract

The schema-2 `full_1620` manifest requires:

```text
physics_profile=sandpc_effective_globalplateau_v1
production_qoi_mode=required
grid=Step62 / 87 slices / 2,165,082 cells
schedule=210 report steps / 1,000 years
injection_end=50 years
hysteresis=Killough, s_min=0.05
Pc mapping=entry-renormalized effective saturation
Pc reference=30-degree West Delta sand
host scaling=Leverett using vertical permeability
non-PREDICT scaling=Leverett using local kzz
Younger non-PREDICT local permeability=50/500/500 mD
Pc entry plateau=all active drainage regions
transmissibility=calculated by JutulDarcy
retained restart years=25,50,100,1000
rolling restart-safe checkpoints=2
QoI output schema=3
```

The profile is in the checksum-pinned manifest. Environment variables cannot
silently replace the manifest's physics profile, QoI mode, restart retention,
or archive policy.

## Required launch gates

Run the gates in order. A failed gate stops the sequence.

1. Merge and test the effective-Pc/global-plateau and branch-aware QoI code.
2. Generate one immutable common MAT and exactly 1,620 geology-specific MATs.
3. Validate every input path, byte count, SHA-256, case identity, and the
   deterministic case-order SHA-256.
4. Run a representative full-schedule acceptance set, including setup,
   restart equivalence, physics-contract checks, final QoI validation, and
   VTU export.
5. Run a 50-case canary through durable shard promotion and scratch cleanup.
6. Inspect convergence, nonlinear iterations, wall time, peak RSS, QoI mass
   closure, archive checksums, and scratch usage.
7. Only then authorize the complete 1,620-case submission.

The successful 50-case canary is the official first production shard, not a
disposable trial. When the later full selection covers tasks 1--1,620, the
launcher recognizes and reuses the verified tasks 1--50 shard and submits
only tasks 51--1,620.

The full launcher requires the explicit acknowledgement
`GOM_PRODUCTION_CONFIRM_FULL_1620=YES`. This is a safety interlock, not a
substitute for the gates above.

## Schema-2 manifest

Build the campaign from the MRST-derived split-input CSV:

```bash
python3.12 scripts/engaging/gom_step62_production_build_manifest.py \
  --derived-manifest /absolute/durable/path/derived_split_input_manifest.csv \
  --campaign-id step62_full1620_effective_globalplateau_v1 \
  --archive-root /orcd/data/juanes/001/shaowen/gom_full_production \
  --jutuldarcy-commit "$jutuldarcy_commit" \
  --jutul-manifest-sha256 "$jutul_manifest_sha256" \
  --mrst-prepare-commit "$mrst_prepare_commit" \
  --source-input-manifest-sha256 "$source_manifest_sha256" \
  --schema-version 2 \
  --ensemble-kind full_1620 \
  --physics-profile sandpc_effective_globalplateau_v1 \
  --qoi-mode required \
  --archive-shard-size 50 \
  --output /absolute/durable/path/campaign.toml
```

The resolver rejects any missing/reordered case, duplicate identity or path,
incorrect input digest/size, unsupported physics policy, non-production
archive root, or changed manifest companion:

```bash
python3.12 scripts/engaging/gom_step62_production_manifest.py \
  --manifest /absolute/durable/path/campaign.toml validate
```

## Sharded execution and storage

The launcher creates 33 task shards: 32 shards of 50 cases and one shard of
20. For each shard the dependency chain is:

```text
campaign checksum check
  -> per-case effective-Pc setup/preflight
  -> per-case 1,000-year simulation
  -> initial/50-year/1,000-year VTU export
  -> checksum, atomic durable promotion, exact scratch cleanup
```

Two shards are in flight by default. Shard `n+2` is released only after
shard `n` has been durably promoted and its exact case directories removed
from scratch. This bounds transient storage without imposing a two-case
simulation limit. With 8 CPUs per task, the Advanced QoS CPU ceiling permits
at most 64 concurrent simulations; the launcher therefore accepts at most
64 as its concurrency setting.

At completion, atomic per-step `rows`, `retention`, and `qoi/rows` directories
are preserved inside verified `tar.gz` files. Consolidated QoI TSVs remain
directly readable. Scratch deletion occurs only after the entire staged shard
has passed SHA-256 verification and has been atomically renamed on durable
storage. The deletion function resolves each target and proves it is a child
of the exact preflight, production, or VTU result root before removal.

Measured standard output is approximately 1.46 GB per case:

- about 1.02 GB for four retained JLD2 checkpoints;
- about 0.39 GB for three VTUs; and
- about 0.05 GB for consolidated and compressed temporal QoIs.

The 1,620-case durable estimate is about 2.37 TB. Reserve at least 3--4 TB
for campaign inputs, checksums, diagnostics, overhead, and recovery margin.
All-timestep JLD2 or VTU output is prohibited for the full ensemble and is
reserved for a few designated movie cases.

### Safe shard reuse

Before skipping any simulation, the launcher requires the existing durable
shard to match all of the following exactly:

- campaign ID and campaign-manifest SHA-256;
- locked physics profile and JutulDarcy commit;
- task interval, case count, deterministic case-order SHA-256, and every row
  of `CASE_INDEX.tsv`;
- the SHA-256 of the complete `SHA256SUMS` inventory; and
- fresh hashes of the small provenance/control files against that inventory.

The complete payload is checksummed once before its initial atomic promotion.
Later reuse rehashes the pinned control plane instead of rereading roughly
75 GB for a 50-case shard. This relies on the promoted project-storage shard
remaining immutable. An existing shard that fails any check aborts the
submission; it is never overwritten or silently rerun under the same
campaign identity.

Submission receipts distinguish `new` and `reused` shards. The finalizer
revalidates both classes, proves contiguous and unique task coverage, and
records the origin of each shard. A full campaign may create
`CAMPAIGN_COMPLETE` only after all 1,620 tasks are covered by that combined
verified set.

## Submission

For a canary or another contiguous subset, set the task limits and omit the
full-ensemble acknowledgement:

```bash
export GOM_PRODUCTION_MANIFEST=/absolute/durable/path/campaign.toml
export JUTULDARCY_COMBINED_REPO=/absolute/path/JutulDarcy.jl_shaowen
export GOM_GRID_ROOT="$HOME/orcd/scratch/gom_grid"
export GOM_PRODUCTION_SELECTION_START=1
export GOM_PRODUCTION_SELECTION_END=50
export GOM_PRODUCTION_MAX_CONCURRENT=64
export GOM_PRODUCTION_SHARD_WINDOW=2
bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_ensemble_submit.sh"
```

For the complete campaign, remove the subset variables and add the explicit
acknowledgement only after the gates pass:

```bash
unset GOM_PRODUCTION_SELECTION_START GOM_PRODUCTION_SELECTION_END
export GOM_PRODUCTION_CONFIRM_FULL_1620=YES
bash "$JUTULDARCY_COMBINED_REPO/scripts/engaging/gom_step62_production_ensemble_submit.sh"
```

Receipts are written both below scratch `gom_grid/submissions` and durable
`gom_full_production/submission_receipts`. The finalizer verifies contiguous,
unique task coverage across every atomically promoted shard. Only a complete
`full_1620` selection can create `CAMPAIGN_COMPLETE`.

## Failure behavior

- A setup or simulation failure blocks its correlated downstream task.
- A failed task blocks its shard archive and the later shard wave gated on
  that archive, preventing uncontrolled scratch accumulation.
- Two rolling checkpoints remain available during a running case, in
  addition to any milestone already reached.
- A shard archive is idempotent: an existing shard is accepted only after the
  full safe-reuse control-plane verification described above.
- Generic restart recovery must use the same immutable manifest and code
  commit. Failed tasks are recovered before their shard is promoted; a new
  physics profile or input requires a new campaign rather than restart reuse.

The archive retains logs, final validators, runtime diagnostics, four restart
states, three VTUs, consolidated QoIs, compressed atomic rows, input/campaign
manifests, code commit, and checksums. Because ORCD project storage currently
lacks guaranteed timely offsite disaster recovery, the small irreplaceable
provenance, code, manifests, and QoI tables should also be mirrored outside
the primary ORCD storage system.
