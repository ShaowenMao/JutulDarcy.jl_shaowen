# GOM dissolved-CO2 publication renderer

This directory contains the reproducible renderer for the publication-quality
Gulf of Mexico dissolved-CO2 cross-section. It produces PNG, SVG, PDF, and a
domain-audit CSV from a three-dimensional VTU result.

The committed renderer corresponds to the approved Case 7 design:

- a vertical slice at reservoir \(x=22{,}500\) m;
- dissolved-CO2 ratio \(R_s\) plotted over 0-18;
- CSP11 IceFire coloring with white at zero;
- gray interbedded clay layers and dark fault-region feature edges;
- interpolation and smoothing performed independently within each connected
  geological domain;
- exact clipping at geological boundaries;
- a fixed \(R_s=0.015\) display threshold;
- black, left-aligned, 10 pt LaTeX annotations;
- physical time read from the companion PVD collection;
- a colorbar whose rendered length exactly matches its LaTeX title; and
- quarter-sized physical and page-export margins.

## Input contract

The VTU must contain these cell arrays:

| Array | Use |
| --- | --- |
| `Rs` | Dissolved-CO2 ratio |
| `stratigraphy_region_flag` | `2` identifies interbedded clay |
| `fault_region_flag` | Values greater than zero identify fault cells |
| `stratigraphic_unit_id` | Prevents smoothing across stratigraphic units |
| `rock_region` | Prevents smoothing across rock-property regions |

Automatic time annotation requires two sibling files beside the VTU:

1. a PVD collection containing the VTU filename and its physical timestep; and
2. `export_summary.txt` containing `pvd_time_unit=years`.

Use `--time-years VALUE` only when those provenance files are unavailable. The
Case 7 PVD maps the initial state to 0 yr, report step 78 to 50 yr, and report
step 210 to 1000 yr.

## Known-good environment

Install the versions recorded in `requirements.txt`. A working LaTeX
installation is also required because Matplotlib renders all annotations with
`text.usetex=True`. The validated Windows environment used MiKTeX.

```powershell
python -m pip install -r `
  scripts/visualization/gom_rs_publication/requirements.txt
```

## Reproduce the approved Case 7 figure

From the repository root:

```powershell
python scripts/visualization/gom_rs_publication/render_gom_rs_cross_section.py `
  --input "D:\codex_gom\step62_effective_pc_global_plateau\case7_s04_c024_case03_geology_v2\gom_step62_effective_pc_global_plateau_s04_c024_case03_geology_v2_0210.vtu"
```

Default outputs are written under:

- `output/visualization/gom_rs_publication/` for PNG, SVG, and the audit CSV;
- `output/pdf/gom_rs_publication/` for the vector PDF.

The output directories remain Git-ignored. Only reproducible source,
documentation, and the required color preset are version controlled.

## Temporal frames

For a movie, invoke the renderer once per VTU and provide unique `--png`,
`--svg`, `--pdf`, and `--audit-csv` paths. Keep the slice, view limits,
color limits, cutoff, smoothing length, and figure size fixed across frames.
The renderer obtains each frame time from the PVD mapping, which keeps the
annotation synchronized with physical simulation time rather than report-step
number.

## Validation reference

For the approved Case 7 final frame, the renderer reports:

```text
TIME_YEARS=1000
SECTION_CELLS=24886
CLAY_LOOPS=12
FAULT_LOOPS=1
GEOLOGICAL_COMPONENTS=51
DISPLAYED_COMPONENTS=6
COLORBAR_WIDTH_FIGURE_FRACTION=0.250321194832
```

The validated PDF has one page, contains no embedded raster-image objects, and
uses Computer Modern Type 1 fonts. The final PDF and SVG therefore remain
vector graphics.

## Color-map provenance

`csp11_icefire_white_zero_paraview.json` follows the CSP11 visualization
convention: Seaborn's IceFire lookup table with pure white prepended at the
zero end.

- CSP11 implementation:
  <https://github.com/moyner/CSP11Visualizer.jl/blob/main/CSP11Visualizer/src/dense.jl>
- Seaborn IceFire palette:
  <https://github.com/mwaskom/seaborn>
