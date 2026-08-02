from __future__ import annotations

import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from render_gom_movie_frames import (
    absolute_path_preserving_symlinks,
    load_report_states,
    map_task,
    parse_pdf_years,
    resolve_pdf_steps,
)


class ExecutablePathTest(unittest.TestCase):
    def test_virtual_environment_path_is_not_resolved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_python = root / "system-python"
            real_python.write_bytes(b"python")
            venv_python = root / "venv" / "bin" / "python"
            venv_python.parent.mkdir(parents=True)
            try:
                venv_python.symlink_to(real_python)
            except OSError as error:
                self.skipTest(f"File symlinks are unavailable: {error}")
            self.assertEqual(
                absolute_path_preserving_symlinks(venv_python),
                venv_python.absolute(),
            )
            self.assertNotEqual(
                absolute_path_preserving_symlinks(venv_python),
                real_python.resolve(),
            )


class TaskMappingTest(unittest.TestCase):
    def test_default_mapping_covers_three_cases_and_two_quantities(self) -> None:
        first = map_task(1, 10)
        self.assertEqual(
            (first.case_task, first.quantity, first.first_step, first.last_step),
            (5, "rs", 1, 10),
        )
        self.assertEqual(
            (map_task(21, 10).case_task, map_task(21, 10).quantity),
            (5, "rs"),
        )
        self.assertEqual(
            (map_task(21, 10).first_step, map_task(21, 10).last_step),
            (201, 210),
        )
        self.assertEqual(
            (map_task(22, 10).case_task, map_task(22, 10).quantity),
            (5, "sg"),
        )
        self.assertEqual(
            (map_task(43, 10).case_task, map_task(43, 10).quantity),
            (6, "rs"),
        )
        final = map_task(126, 10)
        self.assertEqual(
            (final.case_task, final.quantity, final.first_step, final.last_step),
            (7, "sg", 201, 210),
        )
        self.assertEqual(final.total_task_count, 126)

    def test_invalid_task_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            map_task(0, 10)
        with self.assertRaises(ValueError):
            map_task(127, 10)


class PvdContractTest(unittest.TestCase):
    def test_all_report_steps_and_selected_pdf_years(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = "case"
            collection = ET.Element("VTKFile")
            datasets = ET.SubElement(collection, "Collection")
            initial = root / f"{prefix}_incon_0001.vtu"
            initial.write_bytes(b"initial")
            ET.SubElement(
                datasets,
                "DataSet",
                timestep="0",
                file=initial.name,
            )
            selected_times = {25: 25.0, 78: 50.0, 100: 100.0, 210: 1000.0}
            previous = 0.0
            for step in range(1, 211):
                years = selected_times.get(step, previous + 0.1)
                if step == 78:
                    years = 50.0
                elif step == 210:
                    years = 1000.0
                if years <= previous:
                    years = previous + 0.1
                source = root / f"{prefix}_{step:04d}.vtu"
                source.write_bytes(b"state")
                ET.SubElement(
                    datasets,
                    "DataSet",
                    timestep=f"{years:.12g}",
                    file=source.name,
                )
                previous = years
            # Restore exact publication anchors after generating a strictly
            # increasing synthetic schedule.
            entries = datasets.findall("DataSet")
            entries[78].set("timestep", "50")
            entries[100].set("timestep", "100")
            entries[210].set("timestep", "1000")
            pvd = root / f"{prefix}.pvd"
            ET.ElementTree(collection).write(pvd, encoding="utf-8")

            _, states = load_report_states(root)
            self.assertEqual(len(states), 210)
            self.assertEqual(states[78][1], 50.0)
            self.assertEqual(states[210][1], 1000.0)
            pdf_steps = resolve_pdf_steps(
                states,
                parse_pdf_years("25,50,100,1000"),
            )
            self.assertEqual(pdf_steps, {25: 25.0, 78: 50.0, 100: 100.0, 210: 1000.0})


if __name__ == "__main__":
    unittest.main()
