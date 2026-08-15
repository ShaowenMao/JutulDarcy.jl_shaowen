# Step62 phase-1 2,430-case production contract

This campaign propagates the revised full-fault sampling design into the
field-scale GoM reservoir model without changing the accepted simulator
physics. It contains 162 geologies and exactly 15 cases per geology:

- independent full-fault cases `1:12`;
- representative medoid case `101`;
- low-state stress case `102`; and
- high-state stress case `103`.

The canonical order is scenario `1:6`, geology `1:27`, and case IDs
`1:12,101:103`, for 2,430 cases. Production manifest schema 3 accepts only
this complete ordered identity set. It also requires the effective/global Pc
plateau physics profile, QoI schema 4 in required mode, retained states at the
initial condition and 25, 50, 100, and 1,000 years, two rolling restart
checkpoints, 50-case archive shards, atomic-row compaction, and verified
scratch cleanup.

## Input provenance

Each case uses one checksum-pinned common MAT and one checksum-pinned
geology-specific MAT produced by the coordinate-audited MRST preparation
workflow. The geology-specific contract accepts the manifest-backed source
schema `gom_step62_phase1_2430_input_manifest_v1`. The PREDICT permeability
tensor is transformed from fault-local coordinates to reservoir-grid
coordinates by the MRST preparation workflow; JutulDarcy validates the
resulting tensor and pairing metadata but does not repeat or alter that
transformation.

## Fail-closed gates

Advance the campaign only after each preceding gate passes:

Run `scripts/engaging/gom_step62_phase1_2430_contract_tests.sbatch` from the
immutable production checkout before accepting campaign inputs. The job pins
the source commit and `Manifest.toml` SHA-256, records all Python and Julia
contract-test outputs, and writes `PASS` only after every test succeeds.

1. Verify the 162 stratigraphy companions and all 2,430 fault/stratigraphy
   pairings.
2. Build and checksum the immutable source manifest.
3. Generate the common MAT, 2,430 specific MATs, and the derived MRST
   manifest from a clean pinned MRST checkout.
4. Run `gom_step62_phase1_2430_build_campaign.sbatch` to build production
   manifest schema 3 atomically from the completed MAT and contract-test
   packages. The manifest pins the MRST commit, JutulDarcy commit, Julia
   manifest SHA-256, source-manifest SHA-256, case order, and every input MAT
   SHA-256.
5. Pass local tests, Engaging script compatibility, campaign validation,
   preflight, and restart smoke tests.
6. Select and run the 24-case, full-schedule acceptance cohort. The cohort
   contains four input-driven cases from each thickness scenario: a central
   medoid, a barrier-state benchmark, a conduit-state benchmark, and the most
   heterogeneous independent realization. These noncontiguous diagnostic
   runs do not count as production shards.
7. Run the official contiguous 50-case canary and validate its durable shard.
   A passing canary is the first reusable production shard.
8. Only then authorize the full campaign with
   `GOM_PRODUCTION_CONFIRM_PHASE1_2430=YES`.

The shard-level sliding controller supports restartable production with at
most two active shard lanes. Completed checksum-verified shards are reused;
the controller never silently overwrites a durable shard. Full-campaign
completion is recorded only after all 2,430 ordered tasks are covered by
verified durable shards.

Legacy schema-1 pilots and schema-2 `full_1620` campaigns retain their
existing behavior. The schema-2 recovery and older rolling controllers remain
schema-2-only; the phase-1 campaign uses the sliding controller.

The official canary is released with
`gom_step62_phase1_2430_canary_release.sh`. The wrapper requires the completed
24-case acceptance archive, verifies its checksums and all 24 case statuses,
and requires the explicit `GOM_ACCEPTANCE_MANUAL_REVIEW=YES` approval. It then
submits exactly tasks `1:50` as one normal durable production shard, so a
passing canary is reused by the subsequent full campaign.

## Corrected-importer qualification record

Before the full 24-case acceptance cohort, three deliberately difficult cases
qualify the corrected liquid-reference pressure importer over the complete
1,000-year schedule:

- task `580`, `s02_c012_case10`: heterogeneous independent realization;
- task `840`, `s03_c002_case103`: high-state conduit stress; and
- task `1259`, `s04_c003_case102`: low-state barrier stress.

All three cases complete preflight, simulation, QoI schema-4 export, restart
retention, and VTU export. The immutable audit contains 73 passing checks and
no failures. Its accepted provenance is:

- campaign ID:
  `step62_phase1_2430_independent_full_fault_v1_effective_globalplateau_qoi4_coordfix_pressurefix_20260814`;
- campaign manifest SHA-256:
  `adf73c15b1c4edc4b4721c7666a2c2b56aaf800088fff3599a5541dce0ed3dde`;
- simulation commit:
  `ed81af8e88fcd2a7720f26872eef1d16d63469f5`.

Use `scripts/engaging/gom_step62_canary_acceptance_audit.py` to reproduce the
read-only audit bundle. These diagnostic outputs do not count as production
and do not replace the required 24-case acceptance cohort or the reusable
50-case production canary.
