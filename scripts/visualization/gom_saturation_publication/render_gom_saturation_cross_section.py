"""Render a geology-aware publication cross-section of CO2 gas saturation.

This is the gas-saturation configuration of the shared GOM publication
renderer. It deliberately reuses the approved Rs implementation so the paired
figures have identical geological clipping, smoothing, layout, typography, and
physical-time handling.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
BASE_RENDERER = (
    SCRIPT_DIR.parent
    / "gom_rs_publication"
    / "render_gom_rs_cross_section.py"
)
DEFAULT_OUTPUT_DIR = (
    REPO_ROOT / "output" / "visualization" / "gom_saturation_publication"
)


def load_base_renderer() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "gom_publication_cross_section",
        BASE_RENDERER,
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load the shared renderer: {BASE_RENDERER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def configure_saturation_variant(renderer: ModuleType) -> None:
    output_stem = (
        "gom_step62_case7_final_saturation2_publication_geology_aware_"
        "inverted_black_body_time1000yr_10pt_topseal_black_aligned_"
        "quarter_margin"
    )
    audit_stem = (
        "gom_step62_case7_saturation2_geology_aware_inverted_black_body_"
        "time1000yr_10pt_topseal_black_aligned_quarter_margin_domains"
    )

    renderer.DEFAULT_OUTPUT_DIR = DEFAULT_OUTPUT_DIR
    renderer.DEFAULT_PRESET = (
        SCRIPT_DIR / "inverted_black_body_radiation_paraview.json"
    )
    renderer.DEFAULT_PNG = DEFAULT_OUTPUT_DIR / f"{output_stem}.png"
    renderer.DEFAULT_SVG = DEFAULT_OUTPUT_DIR / f"{output_stem}.svg"
    renderer.DEFAULT_PDF = (
        REPO_ROOT
        / "output"
        / "pdf"
        / "gom_saturation_publication"
        / f"{output_stem}.pdf"
    )
    renderer.DEFAULT_AUDIT_CSV = DEFAULT_OUTPUT_DIR / f"{audit_stem}.csv"

    renderer.RS_ARRAY = "Saturations_2"
    renderer.RS_LIMITS = (0.0, 0.6)
    renderer.INPUT_ARRAY_DESCRIPTION = "Saturations_2"
    renderer.COLORBAR_TICKS = (0.0, 0.2, 0.4, 0.6)
    renderer.COLORBAR_TITLE = r"$S_g\;[-]$"
    renderer.MATCH_COLORBAR_TO_TITLE_WIDTH = False
    # Preserve the approved paired-figure width used by the prototype.
    renderer.COLORBAR_WIDTH = 0.250321194832
    renderer.COLORBAR_POSITION = (
        renderer.COLORBAR_POSITION[0],
        renderer.COLORBAR_POSITION[1],
        renderer.COLORBAR_WIDTH,
        renderer.COLORBAR_POSITION[3],
    )
    renderer.METADATA_QUANTITY_NAME = "gas-saturation"
    renderer.METADATA_SHADING_NAME = "gas-saturation"
    renderer.METADATA_COLORBAR_DESCRIPTION = (
        "matching the approved Rs length"
    )


def main() -> None:
    renderer = load_base_renderer()
    configure_saturation_variant(renderer)
    renderer.main()


if __name__ == "__main__":
    main()
