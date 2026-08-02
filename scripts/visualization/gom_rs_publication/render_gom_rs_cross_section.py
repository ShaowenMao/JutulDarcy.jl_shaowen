"""Create a geology-aware publication cross-section of dissolved CO2 (Rs).

Cell-to-point interpolation and smoothing are performed independently inside
connected geological domains. The default mode joins adjacent same-lithology
stratigraphic units, while still preventing averaging across sand/clay,
host/fault, rock-region, or disconnected-component boundaries.
"""

from __future__ import annotations

import argparse
import csv
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import matplotlib.tri as mtri
import numpy as np
import pyvista as pv
from matplotlib.colors import LinearSegmentedColormap, Normalize
from matplotlib.path import Path as MplPath
from matplotlib.patches import PathPatch, Rectangle
from scipy.ndimage import distance_transform_edt, gaussian_filter


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
DEFAULT_OUTPUT_DIR = (
    REPO_ROOT / "output" / "visualization" / "gom_rs_publication"
)

DEFAULT_PRESET = SCRIPT_DIR / "csp11_icefire_white_zero_paraview.json"
DEFAULT_PNG = (
    DEFAULT_OUTPUT_DIR
    / (
        "gom_step62_case7_final_rs_publication_geology_aware_"
        "exact_clip_tight_latex_top_left_compact_time1000yr_"
        "10pt_topseal_black_aligned_quarter_margin.png"
    )
)
DEFAULT_SVG = (
    DEFAULT_OUTPUT_DIR
    / (
        "gom_step62_case7_final_rs_publication_geology_aware_"
        "exact_clip_tight_latex_top_left_compact_time1000yr_"
        "10pt_topseal_black_aligned_quarter_margin.svg"
    )
)
DEFAULT_PDF = (
    REPO_ROOT
    / "output"
    / "pdf"
    / "gom_rs_publication"
    / (
        "gom_step62_case7_final_rs_publication_geology_aware_"
        "exact_clip_tight_latex_top_left_compact_time1000yr_"
        "10pt_topseal_black_aligned_quarter_margin.pdf"
    )
)
DEFAULT_AUDIT_CSV = (
    DEFAULT_OUTPUT_DIR
    / (
        "gom_step62_case7_geology_aware_exact_clip_tight_latex_"
        "compact_time1000yr_10pt_topseal_black_aligned_"
        "quarter_margin_domains.csv"
    )
)

RS_ARRAY = "Rs"
STRATIGRAPHY_FLAG = "stratigraphy_region_flag"
FAULT_FLAG = "fault_region_flag"
INPUT_ARRAY_DESCRIPTION = "Rs"
COLORBAR_TICKS = (0.0, 6.0, 12.0, 18.0)
COLORBAR_TITLE = r"$R_s\;[\mathrm{Sm^3\,CO_2\,/\,Sm^3\,brine}]$"
MATCH_COLORBAR_TO_TITLE_WIDTH = True
METADATA_QUANTITY_NAME = "Rs"
METADATA_SHADING_NAME = "Rs"
METADATA_COLORBAR_DESCRIPTION = "matched to the title width"

SLICE_X = 22500.0
Y_LIMITS = (9000.0, 16500.0)
VIEW_Y_LIMITS = (9775.0, 15290.5)
Z_LIMITS = (0.0, 3350.0)
VIEW_Z_LIMITS = (-12.5, 3002.6)
RS_LIMITS = (0.0, 18.0)

# A journal-scale, double-column figure. The PDF and SVG remain vector.
FIGURE_SIZE_INCHES = (6.1, 3.33)
REGULAR_GRID_SHAPE = (335, 750)  # z, y
DISPLAY_CUTOFF = 0.015
STRATIGRAPHY_SMOOTHING_MODES = ("lithology_connected", "unit")
DEFAULT_STRATIGRAPHY_SMOOTHING_MODE = "lithology_connected"
COLORBAR_WIDTH = 0.38 * (5.0 / 9.0)
COLORBAR_POSITION = (0.055, 0.59, COLORBAR_WIDTH, 0.028)
COLORBAR_TITLE_POSITION = (0.055, 0.68)
TIME_LABEL_POSITION = (0.055, 0.79)
OUTPUT_PAD_INCHES = 0.03 / 4.0

# MRST's physical year is 365.2425 days. The report schedule uses exact
# hour/day times initially, then switches to explicit years. The displayed
# label follows those human time scales while TIME_YEARS and file metadata
# retain the exact PVD value.
MRST_DAYS_PER_YEAR = 365.2425
HOURS_PER_DAY = 24.0
DISPLAY_YEAR_START_DAYS = 365.0
TIME_BOUNDARY_ATOL_DAYS = 1.0e-8


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        type=Path,
        required=True,
        help=(
            f"Source GOM VTU containing {INPUT_ARRAY_DESCRIPTION} "
            "and geology indicator arrays."
        ),
    )
    parser.add_argument("--preset", type=Path, default=DEFAULT_PRESET)
    parser.add_argument("--png", type=Path, default=DEFAULT_PNG)
    parser.add_argument("--svg", type=Path, default=DEFAULT_SVG)
    parser.add_argument("--pdf", type=Path, default=DEFAULT_PDF)
    parser.add_argument("--audit-csv", type=Path, default=DEFAULT_AUDIT_CSV)
    parser.add_argument(
        "--no-svg",
        action="store_true",
        help="Skip SVG output (useful for dense temporal frame campaigns).",
    )
    parser.add_argument(
        "--no-pdf",
        action="store_true",
        help="Skip PDF output while retaining the high-resolution PNG.",
    )
    parser.add_argument(
        "--no-audit-csv",
        action="store_true",
        help="Skip the geological-domain audit CSV.",
    )
    parser.add_argument(
        "--pvd",
        type=Path,
        default=None,
        help=(
            "PVD collection that maps the input VTU to physical time. "
            "By default, the matching sibling PVD is discovered automatically."
        ),
    )
    parser.add_argument(
        "--time-years",
        type=float,
        default=None,
        help="Physical time in years. Overrides automatic PVD lookup.",
    )
    parser.add_argument("--slice-x", type=float, default=SLICE_X)
    parser.add_argument("--view-y-min", type=float, default=VIEW_Y_LIMITS[0])
    parser.add_argument("--view-y-max", type=float, default=VIEW_Y_LIMITS[1])
    parser.add_argument("--view-z-min", type=float, default=VIEW_Z_LIMITS[0])
    parser.add_argument("--view-z-max", type=float, default=VIEW_Z_LIMITS[1])
    parser.add_argument("--smooth-length-m", type=float, default=12.5)
    parser.add_argument(
        "--stratigraphy-smoothing-mode",
        choices=STRATIGRAPHY_SMOOTHING_MODES,
        default=DEFAULT_STRATIGRAPHY_SMOOTHING_MODE,
        help=(
            "Use connected sand/clay packets inside the non-fault "
            "stratigraphy (default), or preserve every stratigraphic unit "
            "as an independent smoothing domain."
        ),
    )
    parser.add_argument("--png-dpi", type=int, default=600)
    return parser.parse_args()


def read_key_value_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def infer_physical_time_years(
    source: Path,
    pvd_argument: Path | None,
    time_argument: float | None,
) -> tuple[float, Path | None]:
    if time_argument is not None:
        if not np.isfinite(time_argument) or time_argument < 0:
            raise ValueError("time-years must be a finite nonnegative value")
        return float(time_argument), None

    summary_path = source.parent / "export_summary.txt"
    if not summary_path.is_file():
        raise FileNotFoundError(
            "Automatic physical-time lookup requires the sibling "
            f"export summary: {summary_path}. Supply --time-years to override."
        )
    summary = read_key_value_file(summary_path)
    if summary.get("pvd_time_unit") != "years":
        raise ValueError(
            "The export summary does not declare pvd_time_unit=years: "
            f"{summary_path}"
        )

    if pvd_argument is not None:
        candidates = [pvd_argument.expanduser().resolve()]
    else:
        candidates = sorted(source.parent.glob("*.pvd"))
    if not candidates:
        raise FileNotFoundError(
            f"No sibling PVD collection was found for {source}"
        )

    matches: list[tuple[float, Path]] = []
    for pvd_path in candidates:
        if not pvd_path.is_file():
            raise FileNotFoundError(pvd_path)
        root = ET.parse(pvd_path).getroot()
        for dataset in root.findall(".//DataSet"):
            file_value = dataset.get("file")
            time_value = dataset.get("timestep")
            if file_value is None or time_value is None:
                continue
            dataset_name = Path(file_value.replace("\\", "/")).name
            if dataset_name == source.name:
                matches.append((float(time_value), pvd_path))

    if len(matches) != 1:
        raise ValueError(
            "Expected exactly one PVD time entry for "
            f"{source.name}, found {len(matches)}"
        )
    time_years, matched_pvd = matches[0]
    if not np.isfinite(time_years) or time_years < 0:
        raise ValueError(f"Invalid PVD timestep: {time_years}")
    return time_years, matched_pvd


class PhysicalTimeLabel(NamedTuple):
    value: str
    unit: str | None

    @property
    def plain(self) -> str:
        if self.unit is None:
            return self.value
        return f"{self.value} {self.unit}"

    @property
    def latex(self) -> str:
        if self.unit is None:
            return rf"$t = {self.value}$"
        return rf"$t = {self.value}\,\mathrm{{{self.unit}}}$"


def format_compact_number(value: float, decimal_places: int = 2) -> str:
    """Round for display and remove unnecessary trailing decimal zeros."""
    rounded = round(float(value), decimal_places)
    if rounded == 0:
        rounded = 0.0
    return f"{rounded:.{decimal_places}f}".rstrip("0").rstrip(".")


def format_physical_time_label(time_years: float) -> PhysicalTimeLabel:
    """Format a PVD time using compact hours, days, or years.

    Exact physical time remains available through ``time_years``. Only the
    visible annotation is rounded, to at most two decimal places, so all GOM
    cases sharing the 210-step report schedule receive identical labels.
    """
    time_years = float(time_years)
    if not np.isfinite(time_years) or time_years < 0:
        raise ValueError("time_years must be a finite nonnegative value")
    if np.isclose(time_years, 0.0, atol=1.0e-15, rtol=0.0):
        return PhysicalTimeLabel("0", None)

    time_days = time_years * MRST_DAYS_PER_YEAR
    if time_days < 1.0 - TIME_BOUNDARY_ATOL_DAYS:
        return PhysicalTimeLabel(
            format_compact_number(time_days * HOURS_PER_DAY),
            "h",
        )
    if time_days < DISPLAY_YEAR_START_DAYS - TIME_BOUNDARY_ATOL_DAYS:
        return PhysicalTimeLabel(
            format_compact_number(time_days),
            "d",
        )
    return PhysicalTimeLabel(format_compact_number(time_years), "yr")


def load_csp11_colormap(path: Path) -> LinearSegmentedColormap:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or not payload:
        raise ValueError(f"Invalid ParaView preset: {path}")
    flat_points = np.asarray(payload[0]["RGBPoints"], dtype=float)
    points = flat_points.reshape((-1, 4))
    return LinearSegmentedColormap.from_list(
        "CSP11 IceFire White Zero",
        [(float(row[0]), tuple(row[1:4])) for row in points],
        N=256,
    )


def triangle_connectivity(mesh: pv.PolyData) -> np.ndarray:
    faces = np.asarray(mesh.faces, dtype=np.int64)
    if faces.size == 0:
        raise ValueError("The sliced mesh contains no polygonal cells")
    packed = faces.reshape((-1, 4))
    if not np.all(packed[:, 0] == 3):
        raise ValueError("The publication mesh was not fully triangulated")
    triangles = packed[:, 1:4]

    # Remove duplicate and degenerate cells before Matplotlib triangulation.
    _, unique_indices = np.unique(
        np.sort(triangles, axis=1),
        axis=0,
        return_index=True,
    )
    triangles = triangles[np.sort(unique_indices)]
    return triangles


def extract_closed_boundary_loops(
    section: pv.PolyData,
    cell_mask: np.ndarray,
) -> list[np.ndarray]:
    selected_ids = np.flatnonzero(cell_mask)
    if selected_ids.size == 0:
        return []

    selected = (
        section.extract_cells(selected_ids)
        .extract_surface(algorithm="dataset_surface")
        .clean()
    )
    edges = selected.extract_feature_edges(
        boundary_edges=True,
        feature_edges=False,
        manifold_edges=False,
        non_manifold_edges=False,
    ).strip()

    loops: list[np.ndarray] = []
    packed = np.asarray(edges.lines, dtype=np.int64)
    cursor = 0
    while cursor < packed.size:
        count = int(packed[cursor])
        ids = packed[cursor + 1 : cursor + 1 + count]
        cursor += count + 1
        if count < 3:
            continue
        coordinates = np.asarray(edges.points[ids])[:, [1, 2]]
        if not np.allclose(coordinates[0], coordinates[-1]):
            coordinates = np.vstack((coordinates, coordinates[0]))
        loops.append(coordinates)
    return loops


def add_filled_loop(
    axes: plt.Axes,
    coordinates: np.ndarray,
    color: str,
    zorder: float,
) -> None:
    codes = np.full(coordinates.shape[0], MplPath.LINETO, dtype=np.uint8)
    codes[0] = MplPath.MOVETO
    codes[-1] = MplPath.CLOSEPOLY
    patch = PathPatch(
        MplPath(coordinates, codes),
        facecolor=color,
        edgecolor="none",
        linewidth=0.0,
        antialiased=True,
        zorder=zorder,
    )
    axes.add_patch(patch)


def add_exact_component_clip(
    axes: plt.Axes,
    component: pv.PolyData,
) -> PathPatch:
    """Add an invisible, exact vector clip path for one geological component."""
    loops = extract_closed_boundary_loops(
        component,
        np.ones(component.n_cells, dtype=bool),
    )
    if not loops:
        raise ValueError("A displayed geological component has no closed boundary")

    paths: list[MplPath] = []
    for coordinates in loops:
        codes = np.full(coordinates.shape[0], MplPath.LINETO, dtype=np.uint8)
        codes[0] = MplPath.MOVETO
        codes[-1] = MplPath.CLOSEPOLY
        paths.append(MplPath(coordinates, codes))

    compound_path = MplPath.make_compound_path(*paths)
    clip_patch = PathPatch(
        compound_path,
        transform=axes.transData,
        facecolor="none",
        edgecolor="none",
        linewidth=0.0,
        antialiased=False,
        zorder=2.0,
    )
    axes.add_patch(clip_patch)
    return clip_patch


def geological_base_domains(
    section: pv.PolyData,
    stratigraphy_smoothing_mode: str = DEFAULT_STRATIGRAPHY_SMOOTHING_MODE,
) -> list[tuple[str, int, np.ndarray]]:
    if stratigraphy_smoothing_mode not in STRATIGRAPHY_SMOOTHING_MODES:
        raise ValueError(
            "Unsupported stratigraphy smoothing mode: "
            f"{stratigraphy_smoothing_mode}"
        )

    unit_ids = np.asarray(section.cell_data["stratigraphic_unit_id"], dtype=int)
    stratigraphy_classes = np.asarray(
        section.cell_data[STRATIGRAPHY_FLAG],
        dtype=int,
    )
    rock_regions = np.asarray(section.cell_data["rock_region"], dtype=int)
    fault_flags = np.asarray(section.cell_data[FAULT_FLAG], dtype=int)
    domains: list[tuple[str, int, np.ndarray]] = []

    # Background host/storage cells are separated by rock class and then by
    # connectivity. Stratigraphic units and fault classes take precedence.
    background = (fault_flags == 0) & (unit_ids == 0)
    for rock_region in sorted(np.unique(rock_regions[background]).tolist()):
        mask = background & (rock_regions == rock_region)
        domains.append(("background_rock", int(rock_region), mask))

    nonfault_stratigraphy = (fault_flags == 0) & (unit_ids > 0)
    if stratigraphy_smoothing_mode == "unit":
        # Comparison mode: every Al/Ar unit is independent, including
        # adjacent units that share the same sand lithology.
        for unit_id in sorted(np.unique(unit_ids[nonfault_stratigraphy])):
            mask = nonfault_stratigraphy & (unit_ids == unit_id)
            domains.append(("stratigraphic_unit", int(unit_id), mask))
    else:
        # Default publication mode: adjacent units with the same sand/clay
        # class and rock region form one candidate material domain. The
        # connectivity pass below still separates fault-offset sides,
        # disconnected beds, pinch-outs, and spatial gaps. Sand and clay are
        # never included in the same interpolation or smoothing operation.
        material_pairs = sorted(
            set(
                zip(
                    stratigraphy_classes[nonfault_stratigraphy].tolist(),
                    rock_regions[nonfault_stratigraphy].tolist(),
                )
            )
        )
        for stratigraphy_class, rock_region in material_pairs:
            if stratigraphy_class not in (1, 2):
                raise ValueError(
                    "Non-fault stratigraphic cells must have sand/clay flag "
                    f"1 or 2, got {stratigraphy_class}."
                )
            mask = (
                nonfault_stratigraphy
                & (stratigraphy_classes == stratigraphy_class)
                & (rock_regions == rock_region)
            )
            lithology = "sand" if stratigraphy_class == 1 else "clay"
            domains.append(
                (
                    f"stratigraphic_{lithology}",
                    int(stratigraphy_class),
                    mask,
                )
            )

    # PREDICT and non-PREDICT fault cells are kept separate from host cells and
    # from one another.
    for fault_flag in sorted(np.unique(fault_flags[fault_flags > 0]).tolist()):
        mask = fault_flags == fault_flag
        domains.append(("fault", int(fault_flag), mask))

    coverage = np.zeros(section.n_cells, dtype=bool)
    for _, _, mask in domains:
        coverage |= mask
    if not np.all(coverage):
        missing = int(np.count_nonzero(~coverage))
        raise ValueError(f"{missing} cross-section cells lack a smoothing domain")
    return domains


def connected_geological_components(
    section: pv.PolyData,
    stratigraphy_smoothing_mode: str = DEFAULT_STRATIGRAPHY_SMOOTHING_MODE,
) -> list[dict[str, object]]:
    components: list[dict[str, object]] = []
    for domain_type, geology_id, mask in geological_base_domains(
        section,
        stratigraphy_smoothing_mode,
    ):
        selected = (
            section.extract_cells(np.flatnonzero(mask))
            .extract_surface(algorithm="dataset_surface")
            .clean()
        )
        connected = selected.connectivity(
            extraction_mode="all",
            label_regions=True,
        )
        region_ids = np.asarray(connected.cell_data["RegionId"], dtype=int)
        for component_id in sorted(np.unique(region_ids).tolist()):
            component = (
                connected.extract_cells(
                    np.flatnonzero(region_ids == component_id)
                )
                .extract_surface(algorithm="dataset_surface")
                .clean()
            )
            raw_rs = np.asarray(component.cell_data[RS_ARRAY], dtype=float)
            component_unit_ids = sorted(
                np.unique(
                    np.asarray(
                        component.cell_data["stratigraphic_unit_id"],
                        dtype=int,
                    )
                ).tolist()
            )
            component_unit_ids = [
                unit_id for unit_id in component_unit_ids if unit_id > 0
            ]
            stratigraphy_class = int(
                np.rint(
                    np.median(
                        np.asarray(
                            component.cell_data[STRATIGRAPHY_FLAG],
                            dtype=float,
                        )
                    )
                )
            )
            rock_region = int(
                np.rint(
                    np.median(
                        np.asarray(
                            component.cell_data["rock_region"],
                            dtype=float,
                        )
                    )
                )
            )
            fault_flag = int(
                np.rint(
                    np.median(
                        np.asarray(
                            component.cell_data[FAULT_FLAG],
                            dtype=float,
                        )
                    )
                )
            )
            components.append(
                {
                    "domain_type": domain_type,
                    "geology_id": geology_id,
                    "component_id": int(component_id),
                    "mesh": component,
                    "cell_count": int(component.n_cells),
                    "stratigraphic_unit_ids": ";".join(
                        str(unit_id) for unit_id in component_unit_ids
                    ),
                    "stratigraphy_class": stratigraphy_class,
                    "rock_region": rock_region,
                    "fault_flag": fault_flag,
                    "raw_rs_min": float(np.min(raw_rs)),
                    "raw_rs_max": float(np.max(raw_rs)),
                    "raw_rs_positive_cells": int(np.count_nonzero(raw_rs > 0)),
                    "raw_rs_above_cutoff_cells": int(
                        np.count_nonzero(raw_rs > DISPLAY_CUTOFF)
                    ),
                }
            )
    return components


def interpolate_component_to_regular_grid(
    component: pv.PolyData,
    y_grid: np.ndarray,
    z_grid: np.ndarray,
    smoothing_length_m: float,
) -> tuple[
    np.ndarray,
    np.ndarray,
    np.ndarray,
    int,
    int,
]:
    # Cell-to-point conversion occurs only after extracting one connected
    # geological component. Shared vertices therefore never mix regions.
    point_component = (
        component.cell_data_to_point_data(pass_cell_data=False)
        .triangulate()
        .clean(tolerance=1.0e-8, absolute=False)
    )
    points = np.asarray(point_component.points)
    y_points = points[:, 1]
    z_points = points[:, 2]
    values = np.asarray(point_component.point_data[RS_ARRAY], dtype=float)
    triangles = triangle_connectivity(point_component)

    p0 = points[triangles[:, 0]][:, [1, 2]]
    p1 = points[triangles[:, 1]][:, [1, 2]]
    p2 = points[triangles[:, 2]][:, [1, 2]]
    twice_area = np.abs(
        (p1[:, 0] - p0[:, 0]) * (p2[:, 1] - p0[:, 1])
        - (p1[:, 1] - p0[:, 1]) * (p2[:, 0] - p0[:, 0])
    )
    triangles = triangles[twice_area > 1.0e-8]
    if triangles.size == 0:
        raise ValueError("A geological component contains no valid triangles")

    triangulation = mtri.Triangulation(y_points, z_points, triangles)
    flat_mask = mtri.TriAnalyzer(triangulation).get_flat_tri_mask(
        min_circle_ratio=1.0e-5
    )
    triangulation.set_mask(flat_mask)
    interpolator = mtri.LinearTriInterpolator(triangulation, values)

    # Interpolate only over a compact local grid surrounding this component.
    # Padding gives the smoothing kernel complete boundary support.
    dy = float(np.mean(np.diff(y_grid)))
    dz = float(np.mean(np.diff(z_grid)))
    sigma_pixels = (
        smoothing_length_m / dz,
        smoothing_length_m / dy,
    )
    margin_y = int(np.ceil(4.0 * sigma_pixels[1])) + 2
    margin_z = int(np.ceil(4.0 * sigma_pixels[0])) + 2
    y_start = max(
        int(np.searchsorted(y_grid, np.min(y_points), side="left"))
        - margin_y,
        0,
    )
    y_stop = min(
        int(np.searchsorted(y_grid, np.max(y_points), side="right"))
        + margin_y,
        y_grid.size,
    )
    z_start = max(
        int(np.searchsorted(z_grid, np.min(z_points), side="left"))
        - margin_z,
        0,
    )
    z_stop = min(
        int(np.searchsorted(z_grid, np.max(z_points), side="right"))
        + margin_z,
        z_grid.size,
    )
    yy, zz = np.meshgrid(y_grid[y_start:y_stop], z_grid[z_start:z_stop])
    interpolated = interpolator(yy, zz)
    values_grid = np.asarray(interpolated.filled(np.nan), dtype=float)
    valid = np.isfinite(values_grid)

    # The normalized filter uses only points inside this exact component. It
    # cannot receive values from adjacent clay, sand, host, or fault domains.
    numerator = gaussian_filter(
        np.where(valid, values_grid, 0.0),
        sigma=sigma_pixels,
        mode="nearest",
    )
    denominator = gaussian_filter(
        valid.astype(float),
        sigma=sigma_pixels,
        mode="nearest",
    )
    smoothed = np.divide(
        numerator,
        denominator,
        out=np.full_like(numerator, np.nan),
        where=denominator > 1.0e-8,
    )
    smoothed = np.clip(smoothed, *RS_LIMITS)

    # Extend only the *display support* to the local bounding box using the
    # nearest value from inside this component. The vector artist is clipped
    # back to the exact geological polygon below. This removes stair-step gaps
    # caused by the regular-grid validity mask without allowing smoothing or
    # display across a geological boundary.
    nearest_inside = distance_transform_edt(
        ~valid,
        return_distances=False,
        return_indices=True,
    )
    extended = smoothed[tuple(nearest_inside)]
    return (
        yy,
        zz,
        extended,
        int(np.count_nonzero(valid)),
        int(
            np.count_nonzero(
                valid
                & np.isfinite(smoothed)
                & (smoothed > DISPLAY_CUTOFF)
            )
        ),
    )


def write_domain_audit(
    path: Path,
    rows: list[dict[str, object]],
) -> None:
    fieldnames = [
        "domain_type",
        "geology_id",
        "component_id",
        "cell_count",
        "stratigraphic_unit_ids",
        "stratigraphy_class",
        "rock_region",
        "fault_flag",
        "raw_rs_min",
        "raw_rs_max",
        "raw_rs_positive_cells",
        "raw_rs_above_cutoff_cells",
        "interpolated_valid_points",
        "displayed_points",
        "y_min",
        "y_max",
        "z_min",
        "z_max",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def configure_matplotlib() -> None:
    matplotlib.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Computer Modern Roman"],
            "font.size": 10.0,
            "text.color": "black",
            "axes.labelcolor": "black",
            "xtick.color": "black",
            "ytick.color": "black",
            "text.usetex": True,
            "axes.linewidth": 0.6,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "svg.fonttype": "none",
            "savefig.facecolor": "white",
            "savefig.edgecolor": "white",
        }
    )


def main() -> None:
    args = parse_args()
    source = args.input.expanduser().resolve()
    preset = args.preset.expanduser().resolve()
    png_path = args.png.expanduser().resolve()
    svg_path = None if args.no_svg else args.svg.expanduser().resolve()
    pdf_path = None if args.no_pdf else args.pdf.expanduser().resolve()
    audit_csv_path = (
        None if args.no_audit_csv else args.audit_csv.expanduser().resolve()
    )

    if not source.is_file():
        raise FileNotFoundError(source)
    if not preset.is_file():
        raise FileNotFoundError(preset)

    time_years, matched_pvd = infer_physical_time_years(
        source,
        args.pvd,
        args.time_years,
    )
    time_label = format_physical_time_label(time_years)

    if args.smooth_length_m < 0:
        raise ValueError("smooth-length-m must be nonnegative")
    if not Y_LIMITS[0] <= args.view_y_min < args.view_y_max <= Y_LIMITS[1]:
        raise ValueError(
            "The horizontal view must lie within the interpolation limits "
            f"{Y_LIMITS}"
        )
    if args.view_z_min >= args.view_z_max:
        raise ValueError("view-z-min must be smaller than view-z-max")

    output_paths = [png_path]
    output_paths.extend(
        path for path in (svg_path, pdf_path, audit_csv_path) if path is not None
    )
    for path in output_paths:
        path.parent.mkdir(parents=True, exist_ok=True)

    configure_matplotlib()
    colormap = load_csp11_colormap(preset)
    norm = Normalize(*RS_LIMITS)

    grid = pv.read(source)
    section = grid.slice(
        normal=(1.0, 0.0, 0.0),
        origin=(args.slice_x, 0.0, 0.0),
    )
    if section.n_cells == 0:
        raise ValueError(f"No cells intersect the x={args.slice_x:g} slice")

    stratigraphy_flag = np.asarray(section.cell_data[STRATIGRAPHY_FLAG])
    fault_flag = np.asarray(section.cell_data[FAULT_FLAG])
    clay_loops = extract_closed_boundary_loops(
        section,
        stratigraphy_flag == 2,
    )
    fault_loops = extract_closed_boundary_loops(
        section,
        fault_flag > 0,
    )
    geological_components = connected_geological_components(
        section,
        args.stratigraphy_smoothing_mode,
    )
    y_grid = np.linspace(*Y_LIMITS, REGULAR_GRID_SHAPE[1])
    z_grid = np.linspace(*Z_LIMITS, REGULAR_GRID_SHAPE[0])

    figure = plt.figure(figsize=FIGURE_SIZE_INCHES, facecolor="white")
    axes = figure.add_axes([0.008, 0.008, 0.984, 0.984])
    axes.set_facecolor("white")

    clay_color = "#b9b7b2"
    for loop in clay_loops:
        add_filled_loop(axes, loop, clay_color, zorder=1.0)

    audit_rows: list[dict[str, object]] = []
    displayed_domains = 0
    for component in geological_components:
        component_mesh = component["mesh"]
        if not isinstance(component_mesh, pv.PolyData):
            raise TypeError("Geological component is not PolyData")
        bounds = component_mesh.bounds
        row = {
            key: value
            for key, value in component.items()
            if key != "mesh"
        }
        row.update(
            {
                "y_min": float(bounds[2]),
                "y_max": float(bounds[3]),
                "z_min": float(bounds[4]),
                "z_max": float(bounds[5]),
                "interpolated_valid_points": 0,
                "displayed_points": 0,
            }
        )

        # A normalized nonnegative smoother cannot exceed the component's raw
        # maximum. Components entirely below the fixed cutoff are provably
        # invisible and need not be interpolated.
        if float(component["raw_rs_max"]) > DISPLAY_CUTOFF:
            yy, zz, smoothed_rs, valid_points, displayed_points = (
                interpolate_component_to_regular_grid(
                    component_mesh,
                    y_grid,
                    z_grid,
                    args.smooth_length_m,
                )
            )
            row["interpolated_valid_points"] = valid_points
            row["displayed_points"] = displayed_points
            if displayed_points > 0:
                # Each connected geological component becomes an independent
                # vector shading object. No scalar averaging occurs between
                # these layers.
                # The first filled-contour level is the unchanged physical
                # display cutoff. Unlike a hard regular-grid mask, contouring
                # interpolates that iso-line within each grid cell and removes
                # the blocky white notches around the plume boundary.
                plume_artist = axes.contourf(
                    yy,
                    zz,
                    smoothed_rs,
                    levels=np.linspace(
                        DISPLAY_CUTOFF,
                        RS_LIMITS[1],
                        257,
                    ),
                    cmap=colormap,
                    norm=norm,
                    antialiased=False,
                    zorder=2.0,
                )
                plume_artist.set_clip_path(
                    add_exact_component_clip(axes, component_mesh)
                )
                displayed_domains += 1
        audit_rows.append(row)

    if audit_csv_path is not None:
        write_domain_audit(audit_csv_path, audit_rows)

    fault_color = "#303030"
    for loop in fault_loops:
        axes.plot(
            loop[:, 0],
            loop[:, 1],
            color=fault_color,
            linewidth=0.65,
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=3.0,
        )

    axes.set_xlim(args.view_y_min, args.view_y_max)
    axes.set_ylim(args.view_z_max, args.view_z_min)
    axes.set_aspect("equal", adjustable="box")
    axes.set_axis_off()

    colorbar_axes = figure.add_axes(COLORBAR_POSITION)
    colorbar_axes.set_xlim(*RS_LIMITS)
    colorbar_axes.set_ylim(0.0, 1.0)
    colorbar_cells = 256
    colorbar_edges = np.linspace(*RS_LIMITS, colorbar_cells + 1)
    overlap = 0.003
    for index in range(colorbar_cells):
        left = colorbar_edges[index]
        right = colorbar_edges[index + 1]
        midpoint = 0.5 * (left + right)
        colorbar_axes.add_patch(
            Rectangle(
                (left, 0.0),
                right - left + overlap,
                1.0,
                facecolor=colormap(norm(midpoint)),
                edgecolor="none",
                linewidth=0.0,
                antialiased=False,
            )
        )
    colorbar_axes.set_yticks([])
    colorbar_axes.set_xticks(COLORBAR_TICKS)
    colorbar_axes.xaxis.set_ticks_position("top")
    colorbar_title = figure.text(
        *COLORBAR_TITLE_POSITION,
        COLORBAR_TITLE,
        ha="left",
        va="bottom",
        fontsize=10.0,
        color="black",
        zorder=10.0,
    )
    colorbar_axes.tick_params(
        axis="x",
        which="major",
        direction="out",
        length=3.0,
        width=0.55,
        pad=1.5,
        labelsize=10.0,
        colors="black",
    )
    for spine in colorbar_axes.spines.values():
        spine.set_visible(False)

    colorbar_width = COLORBAR_WIDTH
    if MATCH_COLORBAR_TO_TITLE_WIDTH:
        # Match the colorbar length to the exact rendered width of the LaTeX
        # title. This is measured after LaTeX layout rather than estimated from
        # characters.
        figure.canvas.draw()
        renderer = figure.canvas.get_renderer()
        title_bounds = colorbar_title.get_window_extent(
            renderer=renderer
        ).transformed(figure.transFigure.inverted())
        colorbar_position = colorbar_axes.get_position()
        colorbar_width = title_bounds.width
        colorbar_axes.set_position(
            [
                colorbar_position.x0,
                colorbar_position.y0,
                colorbar_width,
                colorbar_position.height,
            ]
        )
    tick_labels = colorbar_axes.get_xticklabels()
    tick_labels[0].set_ha("left")
    tick_labels[-1].set_ha("right")

    time_text = figure.text(
        *TIME_LABEL_POSITION,
        time_label.latex,
        ha="left",
        va="top",
        fontsize=10.0,
        color="black",
        zorder=10.0,
    )
    tight_bbox_artists = [colorbar_title, time_text]

    metadata = {
        "Title": (
            f"GOM {METADATA_QUANTITY_NAME} cross-section - "
            "geology-aware smoothing "
            "with exact boundary clipping, tight layout, LaTeX typography, "
            f"stratigraphy mode {args.stratigraphy_smoothing_mode}, "
            f"10-point annotation above the top seal, physical time "
            f"{time_label.plain} (exactly {time_years:.17g} years), black "
            "left-aligned text, and a colorbar "
            f"{METADATA_COLORBAR_DESCRIPTION}, with quarter-sized outer "
            "margins"
        ),
        "Subject": (
            f"Geology-aware vector {METADATA_SHADING_NAME} shading clipped "
            "to exact geological "
            "boundaries, with clay interbeds, fault edges, and physical-time "
            "annotation"
        ),
        "Author": f"Generated from {source.name}",
    }
    if pdf_path is not None:
        figure.savefig(
            pdf_path,
            format="pdf",
            metadata=metadata,
            bbox_inches="tight",
            bbox_extra_artists=tight_bbox_artists,
            pad_inches=OUTPUT_PAD_INCHES,
        )
    if svg_path is not None:
        figure.savefig(
            svg_path,
            format="svg",
            metadata={
                "Title": metadata["Title"],
                "Description": metadata["Subject"],
            },
            bbox_inches="tight",
            bbox_extra_artists=tight_bbox_artists,
            pad_inches=OUTPUT_PAD_INCHES,
        )
    figure.savefig(
        png_path,
        format="png",
        dpi=args.png_dpi,
        metadata={
            "Title": metadata["Title"],
            "Description": metadata["Subject"],
        },
        bbox_inches="tight",
        bbox_extra_artists=tight_bbox_artists,
        pad_inches=OUTPUT_PAD_INCHES,
    )
    plt.close(figure)

    print(f"INPUT={source}")
    print(f"SLICE_X={args.slice_x:g}")
    print(f"VIEW_Y_LIMITS={args.view_y_min:g},{args.view_y_max:g}")
    print(f"VIEW_Z_LIMITS={args.view_z_min:g},{args.view_z_max:g}")
    print(f"TIME_YEARS={time_years:g}")
    print(f"TIME_LABEL={time_label.plain}")
    print(f"TIME_SOURCE_PVD={matched_pvd if matched_pvd else 'command_line'}")
    print(
        "STRATIGRAPHY_SMOOTHING_MODE="
        f"{args.stratigraphy_smoothing_mode}"
    )
    print(f"COLORBAR_WIDTH_FIGURE_FRACTION={colorbar_width:.12g}")
    print(f"SECTION_CELLS={section.n_cells}")
    print(f"CLAY_LOOPS={len(clay_loops)}")
    print(f"FAULT_LOOPS={len(fault_loops)}")
    print(f"GEOLOGICAL_COMPONENTS={len(geological_components)}")
    print(
        "STRATIGRAPHY_SAND_COMPONENTS="
        f"{sum(row['domain_type'] == 'stratigraphic_sand' for row in geological_components)}"
    )
    print(
        "STRATIGRAPHY_CLAY_COMPONENTS="
        f"{sum(row['domain_type'] == 'stratigraphic_clay' for row in geological_components)}"
    )
    print(f"DISPLAYED_COMPONENTS={displayed_domains}")
    print(f"SMOOTH_LENGTH_M={args.smooth_length_m:g}")
    print(f"DISPLAY_CUTOFF={DISPLAY_CUTOFF:g}")
    print(f"AUDIT_CSV={audit_csv_path if audit_csv_path else 'SKIPPED'}")
    print(f"PDF={pdf_path if pdf_path else 'SKIPPED'}")
    print(f"SVG={svg_path if svg_path else 'SKIPPED'}")
    print(f"PNG={png_path}")


if __name__ == "__main__":
    main()
