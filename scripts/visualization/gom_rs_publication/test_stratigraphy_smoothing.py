"""Regression tests for GOM stratigraphic smoothing domains."""

from __future__ import annotations

import unittest

import numpy as np
import pyvista as pv

import render_gom_rs_cross_section as renderer


def five_layer_section() -> pv.PolyData:
    """Return clay/sand/sand/sand/clay layers sharing exact interfaces."""
    points = []
    for z in range(6):
        points.extend(((0.0, 0.0, float(z)), (0.0, 1.0, float(z))))

    faces: list[int] = []
    for layer in range(5):
        lower_left = 2 * layer
        lower_right = lower_left + 1
        upper_left = lower_left + 2
        upper_right = lower_left + 3
        faces.extend(
            (
                4,
                lower_left,
                lower_right,
                upper_right,
                upper_left,
            )
        )

    section = pv.PolyData(np.asarray(points), np.asarray(faces))
    section.cell_data["Rs"] = np.linspace(0.1, 0.5, 5)
    section.cell_data["stratigraphic_unit_id"] = np.arange(1, 6)
    section.cell_data["stratigraphy_region_flag"] = np.asarray(
        [2, 1, 1, 1, 2]
    )
    section.cell_data["rock_region"] = np.asarray([2, 1, 1, 1, 2])
    section.cell_data["fault_region_flag"] = np.zeros(5, dtype=int)
    return section


class StratigraphySmoothingTests(unittest.TestCase):
    def test_lithology_mode_merges_only_connected_sand_units(self) -> None:
        components = renderer.connected_geological_components(
            five_layer_section(),
            "lithology_connected",
        )
        sand = [
            row for row in components
            if row["domain_type"] == "stratigraphic_sand"
        ]
        clay = [
            row for row in components
            if row["domain_type"] == "stratigraphic_clay"
        ]
        self.assertEqual(len(sand), 1)
        self.assertEqual(len(clay), 2)
        self.assertEqual(sand[0]["stratigraphic_unit_ids"], "2;3;4")
        self.assertEqual(
            sorted(row["stratigraphic_unit_ids"] for row in clay),
            ["1", "5"],
        )

    def test_unit_mode_remains_available_for_comparison(self) -> None:
        components = renderer.connected_geological_components(
            five_layer_section(),
            "unit",
        )
        self.assertEqual(len(components), 5)
        self.assertTrue(
            all(row["domain_type"] == "stratigraphic_unit" for row in components)
        )

    def test_default_is_lithology_connected(self) -> None:
        self.assertEqual(
            renderer.DEFAULT_STRATIGRAPHY_SMOOTHING_MODE,
            "lithology_connected",
        )

    def test_invalid_mode_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            renderer.geological_base_domains(
                five_layer_section(),
                "merge_everything",
            )


if __name__ == "__main__":
    unittest.main()
