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
6. Run a bounded official canary and validate its durable shard.
7. Only then authorize the full campaign with
   `GOM_PRODUCTION_CONFIRM_PHASE1_2430=YES`.

The shard-level sliding controller supports restartable production with at
most two active shard lanes. Completed checksum-verified shards are reused;
the controller never silently overwrites a durable shard. Full-campaign
completion is recorded only after all 2,430 ordered tasks are covered by
verified durable shards.

Legacy schema-1 pilots and schema-2 `full_1620` campaigns retain their
existing behavior. The schema-2 recovery and older rolling controllers remain
schema-2-only; the phase-1 campaign uses the sliding controller.
