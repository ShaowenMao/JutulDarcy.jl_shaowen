# GOM gas-saturation publication renderer

This directory contains the reproducible gas-saturation variant of the
publication-quality Gulf of Mexico cross-section renderer. It produces PNG,
SVG, PDF, and a domain-audit CSV from a three-dimensional VTU result.

The saturation variant deliberately shares the approved geology-aware
rendering engine with the dissolved-CO2 (`Rs`) figure. The paired figures
therefore use the same:

- vertical slice at reservoir \(x=22{,}500\) m;
- connected-geology-domain interpolation and smoothing;
- exact clipping at geological boundaries;
- gray interbedded clay layers and dark fault-region feature edges;
- fixed \(0.015\) display threshold;
- physical-time lookup from the companion PVD collection;
- black, left-aligned, 10 pt LaTeX annotations; and
- tight publication layout and vector PDF/SVG output.

The saturation-specific choices are:

- `Saturations_2`, the CO2-rich gas-phase saturation, as the scalar array;
- \(S_g=0\)--\(0.6\) with ticks at 0, 0.2, 0.4, and 0.6;
- the inverted ParaView Black-Body Radiation color map; and
- the same colorbar length as the approved paired \(R_s\) figure.

## Input contract

The VTU must contain these cell arrays:

| Array | Use |
| --- | --- |
| `Saturations_2` | CO2-rich gas-phase saturation |
| `stratigraphy_region_flag` | `2` identifies interbedded clay |
| `fault_region_flag` | Values greater than zero identify fault cells |
| `stratigraphic_unit_id` | Prevents smoothing across stratigraphic units |
| `rock_region` | Prevents smoothing across rock-property regions |

Automatic time annotation requires a sibling PVD collection containing the
VTU filename and `export_summary.txt` containing `pvd_time_unit=years`.
`--time-years VALUE` is available only as an explicit fallback.

## Environment

Use the same Python environment as the shared renderer:

```powershell
python -m pip install -r `
  scripts/visualization/gom_rs_publication/requirements.txt
```

A working LaTeX installation is required because all annotations use
Matplotlib's `text.usetex=True`.

## Reproduce the approved Case 7 final-state figure

From the repository root:

```powershell
python scripts/visualization/gom_saturation_publication/render_gom_saturation_cross_section.py `
  --input "D:\codex_gom\step62_effective_pc_global_plateau\case7_s04_c024_case03_geology_v2\gom_step62_effective_pc_global_plateau_s04_c024_case03_geology_v2_0210.vtu"
```

Default outputs are written under:

- `output/visualization/gom_saturation_publication/` for PNG, SVG, and the
  domain-audit CSV; and
- `output/pdf/gom_saturation_publication/` for the vector PDF.

These output directories remain Git-ignored. Reproducible source,
documentation, and the required color preset are version controlled.

## Validation reference

For the approved Case 7 final frame, the renderer should report:

```text
TIME_YEARS=1000
SECTION_CELLS=24886
CLAY_LOOPS=12
FAULT_LOOPS=1
GEOLOGICAL_COMPONENTS=51
COLORBAR_WIDTH_FIGURE_FRACTION=0.250321194832
```

The PDF and SVG preserve the plume shading as vector contour objects. The
domain-audit CSV records the independent geological components used during
interpolation and makes boundary-isolation behavior reviewable.
