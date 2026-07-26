#!/usr/bin/env python3
"""Validate compact Step62 time-series VTUs through ParaView/VTK readback."""

from __future__ import annotations

import argparse
import gc
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
from vtkmodules.util.numpy_support import vtk_to_numpy
from vtkmodules.vtkIOXML import vtkXMLUnstructuredGridReader


EXPECTED_CELLS = 2_165_082
EXPECTED_FAULT_CELLS = 150_597
EXPECTED_STRATIGRAPHY_CELLS = 828_240
INITIAL_ARRAYS = {
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
STATE_ARRAYS = {
    "Pressure",
    "dP",
    "Saturations_1",
    "Saturations_2",
    "Rs",
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


def read_grid(path: Path):
    reader = vtkXMLUnstructuredGridReader()
    reader.SetFileName(str(path))
    reader.Update()
    return reader, reader.GetOutput()


def array_names(grid) -> set[str]:
    cell_data = grid.GetCellData()
    return {
        cell_data.GetArrayName(index)
        for index in range(cell_data.GetNumberOfArrays())
    }


def numpy_array(grid, name: str) -> np.ndarray:
    array = grid.GetCellData().GetArray(name)
    if array is None:
        raise AssertionError(f"missing array {name}")
    return vtk_to_numpy(array)


def validate_geology(grid, summary: dict[str, str], label: str) -> None:
    arrays: dict[str, np.ndarray] = {}
    for name in GEOLOGY_ARRAYS:
        vtk_array = grid.GetCellData().GetArray(name)
        if vtk_array.GetNumberOfComponents() != 1:
            raise AssertionError(f"{label}: {name} is not scalar")
        values = vtk_to_numpy(vtk_array)
        if values.dtype != np.dtype("int32"):
            raise AssertionError(
                f"{label}: {name} has dtype {values.dtype}, expected int32"
            )
        if values.shape != (EXPECTED_CELLS,):
            raise AssertionError(f"{label}: {name} has shape {values.shape}")
        arrays[name] = values

    fault = arrays["fault_region_flag"]
    stratigraphy = arrays["stratigraphy_region_flag"]
    unit = arrays["stratigraphic_unit_id"]
    if not np.all((fault == 0) | (fault == 1)):
        raise AssertionError(f"{label}: fault flag is not binary")
    if not np.all((stratigraphy == 0) | (stratigraphy == 1)):
        raise AssertionError(f"{label}: stratigraphy flag is not binary")
    if int(fault.sum()) != EXPECTED_FAULT_CELLS:
        raise AssertionError(f"{label}: wrong fault-domain count")
    if int(stratigraphy.sum()) != EXPECTED_STRATIGRAPHY_CELLS:
        raise AssertionError(f"{label}: wrong stratigraphy-domain count")
    if np.any((fault == 1) & (stratigraphy == 1)):
        raise AssertionError(f"{label}: fault and stratigraphy overlap")
    if np.any(unit[stratigraphy == 0] != 0):
        raise AssertionError(f"{label}: unit ID is nonzero outside stratigraphy")
    if set(np.unique(unit[stratigraphy == 1]).tolist()) != set(range(1, 22)):
        raise AssertionError(f"{label}: expected stratigraphic unit IDs 1:21")

    digest_fields = {
        "fault_region_flag": "fault_region_flag_sha256",
        "stratigraphy_region_flag": "stratigraphy_region_flag_sha256",
        "stratigraphic_unit_id": "stratigraphic_unit_id_sha256",
    }
    for array_name, summary_name in digest_fields.items():
        if int32_sha256(arrays[array_name]) != summary[summary_name]:
            raise AssertionError(
                f"{label}: decompressed {array_name} hash mismatch"
            )


def validate_saturations(grid, label: str) -> None:
    water = numpy_array(grid, "Saturations_1")
    gas = numpy_array(grid, "Saturations_2")
    if not np.all(np.isfinite(water)) or not np.all(np.isfinite(gas)):
        raise AssertionError(f"{label}: nonfinite saturation")
    if np.min(water) < -1.0e-8 or np.max(water) > 1.0 + 1.0e-8:
        raise AssertionError(f"{label}: water saturation outside [0, 1]")
    if np.min(gas) < -1.0e-8 or np.max(gas) > 1.0 + 1.0e-8:
        raise AssertionError(f"{label}: gas saturation outside [0, 1]")
    if np.max(np.abs(water + gas - 1.0)) > 1.0e-8:
        raise AssertionError(f"{label}: saturation sum differs from one")


def validate_initial(
    path: Path, summary: dict[str, str]
) -> np.ndarray:
    reader, grid = read_grid(path)
    label = str(path)
    if grid.GetNumberOfCells() != EXPECTED_CELLS:
        raise AssertionError(f"{label}: wrong cell count")
    names = array_names(grid)
    if names != INITIAL_ARRAYS:
        raise AssertionError(
            f"{label}: missing={sorted(INITIAL_ARRAYS - names)}, "
            f"extra={sorted(names - INITIAL_ARRAYS)}"
        )
    if grid.GetCellData().GetNumberOfArrays() != len(INITIAL_ARRAYS):
        raise AssertionError(f"{label}: duplicate cell-array names")
    validate_geology(grid, summary, label)
    validate_saturations(grid, label)

    pressure = numpy_array(grid, "Pressure")
    porosity = numpy_array(grid, "Porosity")
    if not np.all(np.isfinite(pressure)) or np.min(pressure) <= 0:
        raise AssertionError(f"{label}: invalid pressure")
    if (
        not np.all(np.isfinite(porosity))
        or np.min(porosity) <= 0
        or np.max(porosity) >= 1
    ):
        raise AssertionError(f"{label}: invalid porosity")
    for index in range(1, 7):
        permeability = numpy_array(grid, f"Permeability_{index}")
        if not np.all(np.isfinite(permeability)):
            raise AssertionError(f"{label}: nonfinite permeability component")
        if index in (1, 4, 6) and np.min(permeability) <= 0:
            raise AssertionError(f"{label}: nonpositive diagonal permeability")

    initial_pressure = np.array(pressure, copy=True)
    del grid, reader
    gc.collect()
    return initial_pressure


def validate_state(
    path: Path,
    summary: dict[str, str],
    initial_pressure: np.ndarray,
) -> tuple[float, float, float]:
    reader, grid = read_grid(path)
    label = str(path)
    if grid.GetNumberOfCells() != EXPECTED_CELLS:
        raise AssertionError(f"{label}: wrong cell count")
    names = array_names(grid)
    if names != STATE_ARRAYS:
        raise AssertionError(
            f"{label}: missing={sorted(STATE_ARRAYS - names)}, "
            f"extra={sorted(names - STATE_ARRAYS)}"
        )
    if grid.GetCellData().GetNumberOfArrays() != len(STATE_ARRAYS):
        raise AssertionError(f"{label}: duplicate cell-array names")
    validate_geology(grid, summary, label)
    validate_saturations(grid, label)

    pressure = numpy_array(grid, "Pressure")
    pressure_change = numpy_array(grid, "dP")
    dissolved_ratio = numpy_array(grid, "Rs")
    gas = numpy_array(grid, "Saturations_2")
    if not np.all(np.isfinite(pressure)) or np.min(pressure) <= 0:
        raise AssertionError(f"{label}: invalid pressure")
    if not np.all(np.isfinite(pressure_change)):
        raise AssertionError(f"{label}: invalid pressure change")
    if not np.all(np.isfinite(dissolved_ratio)) or np.min(dissolved_ratio) < 0:
        raise AssertionError(f"{label}: invalid dissolved-gas ratio")
    dp_error = float(
        np.max(np.abs((pressure - initial_pressure) - pressure_change))
    )
    if dp_error > 1.0e-8:
        raise AssertionError(f"{label}: dP mismatch {dp_error}")

    result = (
        float(np.max(gas)),
        float(np.min(pressure_change)),
        float(np.max(pressure_change)),
    )
    del grid, reader
    gc.collect()
    return result


def validate_pvd(case_dir: Path, vtu_paths: list[Path]) -> None:
    pvd_paths = list((case_dir / "vtu").glob("*.pvd"))
    if len(pvd_paths) != 1:
        raise AssertionError(f"{case_dir}: expected one PVD")
    root = ET.parse(pvd_paths[0]).getroot()
    datasets = root.findall("./Collection/DataSet")
    if len(datasets) != 3:
        raise AssertionError(f"{case_dir}: expected three PVD datasets")
    times = [float(item.attrib["timestep"]) for item in datasets]
    files = [item.attrib["file"] for item in datasets]
    if times != [0.0, 50.0, 1000.0]:
        raise AssertionError(f"{case_dir}: unexpected PVD times {times}")
    if files != [path.name for path in vtu_paths]:
        raise AssertionError(f"{case_dir}: unexpected PVD file order")


def validate_case(case_dir: Path) -> None:
    summary = read_summary(case_dir / "export_summary.txt")
    vtu_dir = case_dir / "vtu"
    initial_paths = list(vtu_dir.glob("*_incon_0001.vtu"))
    step78_paths = list(vtu_dir.glob("*_0078.vtu"))
    step210_paths = list(vtu_dir.glob("*_0210.vtu"))
    if not (
        len(initial_paths) == len(step78_paths) == len(step210_paths) == 1
    ):
        raise AssertionError(f"{case_dir}: expected one VTU at each key state")

    paths = [initial_paths[0], step78_paths[0], step210_paths[0]]
    validate_pvd(case_dir, paths)
    initial_pressure = validate_initial(paths[0], summary)
    end_injection = validate_state(paths[1], summary, initial_pressure)
    final = validate_state(paths[2], summary, initial_pressure)
    print(
        f"VTK_SERIES_READBACK_PASS case={case_dir.name} "
        f"cells={EXPECTED_CELLS} times_years=0,50,1000 "
        f"sg_max_50y={end_injection[0]:.8g} "
        f"sg_max_1000y={final[0]:.8g} "
        f"dp_1000y_Pa=[{final[1]:.8g},{final[2]:.8g}]"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_root", type=Path)
    args = parser.parse_args()
    for case_id in ("01", "03", "04", "07"):
        validate_case(args.result_root / f"case{case_id}")


if __name__ == "__main__":
    main()
