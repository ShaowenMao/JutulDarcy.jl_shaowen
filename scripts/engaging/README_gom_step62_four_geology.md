# Step62 four-geology JutulDarcy baseline

This document freezes the JutulDarcy side of the production workflow used for
the four correlated `s05_c012` geology cases. It records the state before any
new changes to the zero-capillary-pressure reservoir regions.

## Repository pairing

- JutulDarcy repository:
  `ShaowenMao/JutulDarcy.jl_shaowen`
- JutulDarcy branch:
  `co2_blackoil_fieldcase_GoM_clean_backup`
- MRST input-preparation repository:
  `ShaowenMao/mrst_predict_sim`
- MRST integration branch:
  `codex/grid-dev-main-sync`
- Protected Step62 grid tag:
  `grid-step62-protected`
- Protected grid commit:
  `d4ad85b`
- Step62 integration-smoke base commit:
  `39e39dd`

The protected grid lives at:

```text
setup_shaowen_resolution/grid_candidates/
  step_62_matched_upper_lower_transition
```

The MRST preparation workflow must pass this directory through `GridDir`.
It must not depend on the mutable top-level copies of
`nodes_coordinates.dat`, `t.mat`, or `ucids_sc2_2D.mat`.

## Split-input contract

The reusable common input is:

```text
gom_step62_87slice_s05_c012_common.mat
```

The four correlated specific inputs are:

```text
gom_step62_87slice_s05_c012_case01_full_slice_geology_specific.mat
gom_step62_87slice_s05_c012_case03_full_slice_geology_specific.mat
gom_step62_87slice_s05_c012_case04_full_slice_geology_specific.mat
gom_step62_87slice_s05_c012_case07_full_slice_geology_specific.mat
```

The specific files use schema `gom_jutul_split_specific_v3`. Each one combines
the PREDICT fault realization with the Al/Ar stratigraphy carrying the same
geology ID and SHA-256 pairing hash. The common file leaves both
geology-specific property domains blank. JutulDarcy overlays stratigraphy
first and then expands the explicit fault saturation tables.

The accepted common geology hash is:

```text
c6bc59de0651bed2739f7a2b9f3c9c2d76c132e4be765d8833c0748050c511fd
```

Expected assembled invariants:

| Quantity | Expected value |
|---|---:|
| Along-strike slices | 87 |
| Active 2-D footprints | 24,886 |
| Total 3-D cells | 2,165,082 |
| Complete fault-domain cells | 150,597 |
| Geology-specific PREDICT fault cells | 32,190 |
| Geology-specific Al/Ar cells | 828,240 |
| Drainage saturation regions | 527 |
| Total drainage plus imbibition SGOF tables | 1,054 |
| Schedule steps | 210 |
| Schedule duration | 1,000 years |
| Injection duration | 50 years |

The MAT inputs intentionally omit MRST transmissibility. JutulDarcy computes
transmissibility from the assembled grid and global permeability tensor.

## Runtime policy

The accepted production settings are:

```text
DISABLE_HYSTERESIS=false
HYSTERESIS_S_MIN=0.05
FAULT_SATURATION_DOMAIN_MODE=input
FAULT_PC_ENTRY_TREATMENT=plateau
FAULT_PC_ENTRY_SG_MAX=1e-4
EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir
USE_MRST_TRANSMISSIBILITY=false
IGNORE_MRST_T=true
WELL_VOLUME_FRACTION=1e-3
TARGET_DS=0.05
ENABLE_DIFFUSION=false
```

`EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir` keeps reservoir hysteresis active
but duplicates each explicit fault drainage table into its imbibition partner,
so fault relative permeability remains drainage-equivalent.

The current entry-pressure plateau is applied only to the 522 explicit
geology-specific fault tables. It does not change the shared base reservoir,
seal, or three non-PREDICT fault-band tables.

## Submission sequence

Set the immutable input and deployed-repository locations:

```bash
export GOM_FOUR_GEOLOGY_INPUT_DIR=/path/to/jutul_split
export JUTULDARCY_COMBINED_REPO=/path/to/JutulDarcy.jl_shaowen
export GOM_GRID_ROOT=/path/to/gom_grid
```

Then submit in this order:

```bash
sbatch scripts/engaging/gom_step62_four_geology_hyst_plateau_preflight.sbatch
sbatch scripts/engaging/gom_step62_four_geology_hyst_plateau_smoke.sbatch
sbatch scripts/engaging/gom_step62_four_geology_hyst_plateau_full.sbatch
sbatch scripts/engaging/gom_step62_four_geology_hyst_plateau_standard_vtu.sbatch
```

The scripts use Slurm array tasks for cases `01`, `03`, `04`, and `07`.
The full run writes 210 restart checkpoints and validates the final state.
The standard VTU export writes the initial state, 50-year state, and
1,000-year state with compact simulation arrays plus:

- `fault_region_flag`
- `stratigraphy_region_flag`
- `stratigraphic_unit_id`

Use the read-only Pc audit after assembly:

```bash
sbatch scripts/engaging/audit_gom_step62_zero_pc.sbatch
```

## Completed baseline evidence

The following Engaging jobs passed against the current workflow:

| Purpose | Job ID | Result |
|---|---:|---|
| Four-case MRST input preparation | 18866122 | PASS |
| Four-case 1,000-year production run | 18873423 | 4/4 PASS, 210/210 steps |
| Standard VTU export and readback | 18903178 | 12 VTUs and 4 PVDs PASS |
| Four-case assembled zero-Pc audit | 18909534 | 4/4 PASS |
| Focused split-input/restart unit tests | 18911134 | 39/39 PASS |

The completed production result root was:

```text
gom_step62_four_geology_hyst_plateau_full_job18873423
```

The standard VTU result root was:

```text
gom_step62_four_geology_hyst_plateau_standard_vtu_job18903178
```

Scratch locations are operational provenance, not durable version control.
Keep run metadata, logs, summaries, PASS markers, and selected final
checkpoints. Generated MAT, JLD2, VTU, PVD, `output/`, and `tmp/` content must
not be committed.

## Zero-Pc baseline

Before the next Pc change, the assembled four cases contain exactly one
all-zero drainage curve and one paired all-zero imbibition curve:

```text
SATNUM 1
IMBNUM 528
```

They cover 1,542,945 cells:

| Physical group | Porosity | Kh (mD) | Kv (mD) | Cells |
|---|---:|---:|---:|---:|
| LM2 storage reservoir | 0.265 | 150 | 30 | 513,474 |
| Al/Ar permeable sand | 0.273245722 | 175 | 58.3333 | 394,545 |
| MM-UM outside the fault | 0.279918622 | 200 | 66.6667 | 447,615 |
| Younger outside the fault | 0.35 | 500 | 500 | 187,311 |

No fault cell uses the all-zero curve. Any future Pc redesign must start from
a new commit and explicitly decide whether these four physical groups remain
one saturation region or become separate Pc regions. Relative permeability
must remain unchanged unless a separate Kr change is deliberately requested.
