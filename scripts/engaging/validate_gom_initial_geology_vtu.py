#!/usr/bin/env python3
"""Validate Step62 initial-condition geology indicators through VTK readback."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import numpy as np
from vtkmodules.util.numpy_support import vtk_to_numpy
from vtkmodules.vtkIOXML import vtkXMLUnstructuredGridReader


EXPECTED_CELLS = 2_165_082
EXPECTED_FAULT_CELLS = 150_597
EXPECTED_STRATIGRAPHY_CELLS = 828_240
EXPECTED_ARRAYS = {
    "Pressure",
    "Saturations_1",
    "Saturations_2",
    "Porosity",
    "Permeability_1",
    "Permeability_2",
    "Permeability_3",
    "Permeability_4",
    "Permeability_5",
    "Permeability_6",
    "sat_region",
    "rock_region",
    "imbi_region",
    "fault_region_flag",
    "stratigraphy_region_flag",
    "stratigraphic_unit_id",
}
GEOLOGY_ARRAYS = (
    "fault_region_flag",
    "stratigraphy_region_flag",
    "stratigraphic_unit_id",
)


def read_summary(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def int32_sha256(values: np.ndarray) -> str:
    little_endian = np.asarray(values, dtype="<i4")
    return hashlib.sha256(little_endian.tobytes(order="C")).hexdigest()


def validate_case(case_dir: Path) -> None:
    vtu_paths = list((case_dir / "vtu").glob("*.vtu"))
    if len(vtu_paths) != 1:
        raise AssertionError(
            f"{case_dir}: expected one VTU, found {len(vtu_paths)}"
        )

    reader = vtkXMLUnstructuredGridReader()
    reader.SetFileName(str(vtu_paths[0]))
    reader.Update()
    grid = reader.GetOutput()
    if grid.GetNumberOfCells() != EXPECTED_CELLS:
        raise AssertionError(
            f"{case_dir}: found {grid.GetNumberOfCells()} cells"
        )

    cell_data = grid.GetCellData()
    names = {
        cell_data.GetArrayName(index)
        for index in range(cell_data.GetNumberOfArrays())
    }
    if names != EXPECTED_ARRAYS:
        raise AssertionError(
            f"{case_dir}: unexpected cell arrays: "
            f"missing={sorted(EXPECTED_ARRAYS - names)}, "
            f"extra={sorted(names - EXPECTED_ARRAYS)}"
        )
    if cell_data.GetNumberOfArrays() != len(EXPECTED_ARRAYS):
        raise AssertionError(f"{case_dir}: duplicate cell-array names")

    arrays: dict[str, np.ndarray] = {}
    for name in GEOLOGY_ARRAYS:
        vtk_array = cell_data.GetArray(name)
        if vtk_array.GetNumberOfComponents() != 1:
            raise AssertionError(f"{case_dir}: {name} is not scalar")
        values = vtk_to_numpy(vtk_array)
        if values.dtype != np.dtype("int32"):
            raise AssertionError(
                f"{case_dir}: {name} has dtype {values.dtype}, expected int32"
            )
        if values.shape != (EXPECTED_CELLS,):
            raise AssertionError(
                f"{case_dir}: {name} has shape {values.shape}"
            )
        arrays[name] = values

    fault = arrays["fault_region_flag"]
    stratigraphy = arrays["stratigraphy_region_flag"]
    unit = arrays["stratigraphic_unit_id"]
    if not np.all((fault == 0) | (fault == 1)):
        raise AssertionError(f"{case_dir}: fault flag is not binary")
    if not np.all((stratigraphy == 0) | (stratigraphy == 1)):
        raise AssertionError(f"{case_dir}: stratigraphy flag is not binary")
    if int(fault.sum()) != EXPECTED_FAULT_CELLS:
        raise AssertionError(f"{case_dir}: wrong fault-domain count")
    if int(stratigraphy.sum()) != EXPECTED_STRATIGRAPHY_CELLS:
        raise AssertionError(f"{case_dir}: wrong stratigraphy-domain count")
    if np.any((fault == 1) & (stratigraphy == 1)):
        raise AssertionError(f"{case_dir}: fault and stratigraphy overlap")
    if np.any(unit[stratigraphy == 0] != 0):
        raise AssertionError(f"{case_dir}: unit ID is nonzero outside stratigraphy")
    if set(np.unique(unit[stratigraphy == 1]).tolist()) != set(range(1, 22)):
        raise AssertionError(f"{case_dir}: expected stratigraphic unit IDs 1:21")

    summary = read_summary(case_dir / "export_summary.txt")
    digest_fields = {
        "fault_region_flag": "fault_region_flag_sha256",
        "stratigraphy_region_flag": "stratigraphy_region_flag_sha256",
        "stratigraphic_unit_id": "stratigraphic_unit_id_sha256",
    }
    for array_name, summary_name in digest_fields.items():
        actual = int32_sha256(arrays[array_name])
        if actual != summary[summary_name]:
            raise AssertionError(
                f"{case_dir}: decompressed {array_name} hash mismatch"
            )

    print(
        f"VTK_READBACK_PASS case={case_dir.name} "
        f"cells={EXPECTED_CELLS} arrays={len(EXPECTED_ARRAYS)} "
        f"fault_cells={int(fault.sum())} "
        f"stratigraphy_cells={int(stratigraphy.sum())}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_root", type=Path)
    args = parser.parse_args()
    for case_id in ("01", "03", "04", "07"):
        validate_case(args.result_root / f"case{case_id}")


if __name__ == "__main__":
    main()
