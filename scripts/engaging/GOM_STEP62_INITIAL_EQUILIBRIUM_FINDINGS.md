# Step62 Initial-Pressure Equilibrium Findings

## Decision

The pressure stored in the Step62 common MAT is hydrostatic liquid pressure
and is already a discrete equilibrium for the production grid, fluid, gravity,
and no-flow boundaries. The Jutul model uses liquid as its reference phase, so
the importer must preserve this pressure exactly. Do not run a separate
case-by-case pre-equilibration simulation.

The production preflight must continue to require all of the following:

- the Jutul reference phase is liquid (`reference_phase_index = 1`);
- imported pressure matches the immutable common-MAT pressure within `1e-6 Pa`;
- the geology ID, hashes, units, dimensions, and fault-property mappings pass
  the existing reservoir-input contract;
- the simulation and production checkouts use the checksum-pinned Manifest.

## Root cause

Commit `f1dc227b8` added capillary pressure to MRST liquid pressure when the
two-phase model used vapor as its reference phase. That conversion was correct
for the reference-phase convention at that time. Commit `e83244450` later
unified reference-phase handling, and the current liquid-vapor model selects
liquid as the reference phase. The MRST importer retained the old unconditional
capillary-pressure addition, which shifted the liquid pressure even though no
conversion was needed.

The fix in `src/input_simulation/mrst_input.jl`:

1. copies the MRST pressure array so import does not mutate the assembled MAT;
2. queries the model's actual reference phase;
3. leaves MRST liquid pressure unchanged for a liquid-reference model; and
4. adds capillary pressure only for a vapor-reference model.

This is an importer correction. The common and case-specific MAT files do not
need regeneration for this pressure issue.

This finding is separate from the earlier fault-local to reservoir-coordinate
permeability-tensor correction. That coordinate correction belongs to MAT
generation; the initial-pressure correction belongs only to the Jutul MRST
importer. The pressure fix does not alter permeability, porosity, Pc, Kr,
stratigraphy, or any reservoir-input hash.

## Validation evidence

All full-grid controls use the exact 2,165,082-cell production model with
32,190 fault cells, six windows, 87 slices, gravity enabled, all wells disabled,
no sources, and no boundary conditions.

| Case | Selection purpose | Old initial head residual (Pa) | Fixed residual (Pa) | Old 1-year pressure change (Pa) | Fixed change (Pa) |
| --- | --- | ---: | ---: | ---: | ---: |
| `s04_c003_case102` | low permeability | 1,091,047 | 6.296 | 1,084,373 | 3.396 |
| `s03_c002_case103` | high permeability | 107,487 | 6.296 | 95,897 | 3.408 |
| `s02_c012_case10` | heterogeneous entry pressure | 1,152,198 | 6.296 | 1,070,119 | 3.397 |

For all three fixed-importer controls:

- imported pressure differs from the raw common-MAT pressure by `0.0 Pa`;
- maximum initial all-face liquid flux is `9.22265e-6 m3/s`;
- maximum initial fault-interface potential residual is approximately
  `5.52e-6 Pa`, with flux of order `1e-12 m3/s`;
- no gas appears during the control;
- no nonlinear ministeps fail; and
- one-year relative total-mass drift is below `2e-13`.

The low-permeability case was additionally advanced through 1,000 years with
the manually restored raw liquid-reference pressure. The run completed with
1,027 successful ministeps and no failed ministeps. Its maximum domain pressure
change remains bounded at `3.409 Pa`, gas saturation remains exactly zero,
the saturation-sum error remains zero, and relative total-mass drift is
`1.44e-13`. Thus, the few-Pascal discrete residual does not grow into a
long-term hydrostatic redistribution.

The fixed importer also reproduces the independent manual
`raw_liquid_reference` A/B controls to numerical precision. The production
preflight imports the exact common-MAT pressure (`0.0 Pa` maximum difference)
while retaining all existing Pc, Kr, hysteresis, QOI, tensor, stratigraphy, and
hash-contract checks.

## Immutable provenance

- Production baseline commit:
  `01e689416715df3d785535692ce03d547707a3e7`
- Validated candidate commit:
  `96f995a929c907dc36d6d8ff8c6726d852844aae`
- Production campaign manifest SHA-256:
  `fbe8cdb7a2f3933dc7a0bfdd69233ab050b96f70846ccdb7a7def6693cc51a77`
- Candidate Engaging checkout:
  `/home/shaowen/orcd/scratch/gom_grid/code/immutable/JutulDarcy_96f995a9`
- Cross-case fixed-importer controls:
  `/orcd/data/juanes/001/shaowen/gom_full_production/diagnostics/initial_equilibrium/paired_tasks580_840_fixed_importer_r1_20260813`
- Low-permeability fixed-importer control:
  `/orcd/data/juanes/001/shaowen/gom_full_production/diagnostics/initial_equilibrium/task1259_fixed_importer_imported_r1_20260813`
- Low-permeability 1,000-year control:
  `/orcd/data/juanes/001/shaowen/gom_full_production/diagnostics/initial_equilibrium/long_task1259_raw_liquid_r1_20260813`
- Exact production preflight:
  `/orcd/data/juanes/001/shaowen/gom_full_production/diagnostics/initial_equilibrium/production_preflight_96f995a9_task1259_20260813`
- Engaging contract tests:
  `/orcd/data/juanes/001/shaowen/gom_full_production/diagnostics/initial_equilibrium/contract_cfadf0c2_20260813`

Each durable diagnostic directory contains checksums and a `COMPLETE` marker.

## Production implication

Reservoir simulations imported with the previous unconditional pressure shift
start from an artificial capillary-pressure perturbation and should be rerun
with a final immutable checkout containing this fix. Do not cancel or alter an
active campaign without an explicit campaign transition decision. Build a new
manifest, run contract tests and the exact production preflight, and then
submit the replacement reservoir campaign under a new campaign ID.

The all-brine initial fluid state should otherwise remain common across cases.
Differences in porosity imply different initial pore volume and brine mass;
differences in permeability control response rates. They do not justify
case-specific hydrostatic pressure equilibration.
