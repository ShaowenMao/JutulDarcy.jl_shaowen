"""Render a resumable chunk of publication-quality GOM movie frames."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, replace
from pathlib import Path


CASE_TASKS = (5, 6, 7)
QUANTITIES = ("rs", "sg")
EXPECTED_REPORT_STEPS = 210
DEFAULT_CHUNK_SIZE = 10
DEFAULT_PDF_YEARS = (25.0, 50.0, 100.0, 1000.0)
STATE_FILE_PATTERN = re.compile(r"_(\d{4})\.vtu$")


@dataclass(frozen=True)
class WorkItem:
    case_task: int
    quantity: str
    chunk_index: int
    first_step: int
    last_step: int
    chunk_count: int
    total_task_count: int


def read_key_value_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key in values:
            raise ValueError(f"Duplicate key {key!r} in {path}")
        values[key] = value.strip()
    return values


def parse_pdf_years(value: str) -> tuple[float, ...]:
    years = tuple(float(item.strip()) for item in value.split(",") if item.strip())
    if not years or any(not math.isfinite(item) or item < 0 for item in years):
        raise argparse.ArgumentTypeError(
            "pdf-years must contain finite nonnegative comma-separated values"
        )
    if tuple(sorted(set(years))) != years:
        raise argparse.ArgumentTypeError(
            "pdf-years must be unique and strictly increasing"
        )
    return years


def absolute_path_preserving_symlinks(path: Path) -> Path:
    """Return a lexical absolute path without dereferencing a venv executable."""
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vtu-job-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--task-id", type=int, required=True)
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    parser.add_argument(
        "--pdf-years",
        type=parse_pdf_years,
        default=DEFAULT_PDF_YEARS,
        help="Physical years receiving vector PDFs; PNGs are always rendered.",
    )
    parser.add_argument("--png-dpi", type=int, default=600)
    parser.add_argument(
        "--step-override",
        type=int,
        default=None,
        help="Render one report step from the mapped case/quantity (smoke tests).",
    )
    parser.add_argument("--python", type=Path, default=Path(sys.executable))
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def map_task(task_id: int, chunk_size: int) -> WorkItem:
    if chunk_size <= 0:
        raise ValueError("chunk-size must be positive")
    chunk_count = math.ceil(EXPECTED_REPORT_STEPS / chunk_size)
    tasks_per_case = len(QUANTITIES) * chunk_count
    total_task_count = len(CASE_TASKS) * tasks_per_case
    if not 1 <= task_id <= total_task_count:
        raise ValueError(
            f"task-id must be in 1:{total_task_count} for chunk-size {chunk_size}"
        )
    zero_based = task_id - 1
    case_index, within_case = divmod(zero_based, tasks_per_case)
    quantity_index, chunk_index = divmod(within_case, chunk_count)
    first_step = chunk_index * chunk_size + 1
    last_step = min(first_step + chunk_size - 1, EXPECTED_REPORT_STEPS)
    return WorkItem(
        case_task=CASE_TASKS[case_index],
        quantity=QUANTITIES[quantity_index],
        chunk_index=chunk_index,
        first_step=first_step,
        last_step=last_step,
        chunk_count=chunk_count,
        total_task_count=total_task_count,
    )


def discover_case(vtu_job_root: Path, case_task: int) -> Path:
    matches: list[Path] = []
    for candidate in sorted(vtu_job_root.iterdir()):
        if not candidate.is_dir() or candidate.name.startswith("."):
            continue
        metadata_path = candidate / "EXPORT_METADATA.txt"
        if not metadata_path.is_file():
            continue
        metadata = read_key_value_file(metadata_path)
        if metadata.get("array_task_id") == str(case_task):
            matches.append(candidate)
    if len(matches) != 1:
        raise ValueError(
            f"Expected one VTU case for source task {case_task}; found {matches}"
        )
    case_dir = matches[0]
    if not (case_dir / "PASS").is_file():
        raise FileNotFoundError(f"VTU case has no PASS marker: {case_dir}")
    summary = read_key_value_file(case_dir / "export_summary.txt")
    expected = {
        "status": "pass",
        "export_mode": "all_report_steps",
        "selected_steps": "1:210",
        "vtu_files": "211",
        "pvd_files": "1",
        "pvd_time_unit": "years",
        "geology_indicator_schema": "gom_vtu_geology_indicators_v2",
    }
    for key, value in expected.items():
        if summary.get(key) != value:
            raise ValueError(
                f"Unexpected {key} in {case_dir / 'export_summary.txt'}: "
                f"{summary.get(key)!r}; expected {value!r}"
            )
    return case_dir


def load_report_states(vtu_dir: Path) -> tuple[Path, dict[int, tuple[Path, float]]]:
    pvd_candidates = sorted(vtu_dir.glob("*.pvd"))
    if len(pvd_candidates) != 1:
        raise ValueError(f"Expected one PVD in {vtu_dir}; found {pvd_candidates}")
    pvd_path = pvd_candidates[0]
    states: dict[int, tuple[Path, float]] = {}
    initial_entries = 0
    root = ET.parse(pvd_path).getroot()
    for dataset in root.findall(".//DataSet"):
        file_value = dataset.get("file")
        time_value = dataset.get("timestep")
        if file_value is None or time_value is None:
            continue
        file_name = Path(file_value.replace("\\", "/")).name
        if "_incon_" in file_name:
            initial_entries += 1
            continue
        match = STATE_FILE_PATTERN.search(file_name)
        if match is None:
            raise ValueError(f"Unrecognized state filename in {pvd_path}: {file_name}")
        step = int(match.group(1))
        if step in states:
            raise ValueError(f"Duplicate report step {step} in {pvd_path}")
        source = vtu_dir / file_name
        if not source.is_file() or source.stat().st_size <= 0:
            raise FileNotFoundError(source)
        states[step] = (source, float(time_value))
    if initial_entries != 1:
        raise ValueError(f"Expected one initial PVD entry; found {initial_entries}")
    if sorted(states) != list(range(1, EXPECTED_REPORT_STEPS + 1)):
        raise ValueError("PVD does not contain exactly report steps 1:210")
    times = [states[step][1] for step in range(1, EXPECTED_REPORT_STEPS + 1)]
    if any(not math.isfinite(item) or item <= 0 for item in times):
        raise ValueError("Report times must be finite and positive")
    if any(right <= left for left, right in zip(times, times[1:])):
        raise ValueError("Report times must be strictly increasing")
    if not math.isclose(states[78][1], 50.0, abs_tol=1.0e-10):
        raise ValueError("Report step 78 must equal 50 years")
    if not math.isclose(states[210][1], 1000.0, abs_tol=1.0e-10):
        raise ValueError("Report step 210 must equal 1000 years")
    return pvd_path, states


def resolve_pdf_steps(
    states: dict[int, tuple[Path, float]],
    requested_years: tuple[float, ...],
) -> dict[int, float]:
    result: dict[int, float] = {}
    for requested in requested_years:
        matches = [
            step
            for step, (_, years) in states.items()
            if math.isclose(years, requested, abs_tol=1.0e-9, rel_tol=0.0)
        ]
        if len(matches) != 1:
            raise ValueError(
                f"Expected one report time at {requested:g} years; found {matches}"
            )
        result[matches[0]] = requested
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_png(path: Path) -> tuple[int, int]:
    from PIL import Image

    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        width, height = image.size
    if width < 3000 or height < 1500:
        raise ValueError(f"PNG is unexpectedly small ({width}x{height}): {path}")
    return width, height


def validate_pdf(path: Path) -> None:
    if path.stat().st_size < 1024:
        raise ValueError(f"PDF is unexpectedly small: {path}")
    if not path.read_bytes()[:5] == b"%PDF-":
        raise ValueError(f"Invalid PDF header: {path}")


def marker_is_current(
    marker_path: Path,
    source: Path,
    png_path: Path,
    audit_path: Path,
    pdf_path: Path | None,
) -> bool:
    if not marker_path.is_file():
        return False
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        source_stat = source.stat()
        if marker.get("source_bytes") != source_stat.st_size:
            return False
        if marker.get("source_mtime_ns") != source_stat.st_mtime_ns:
            return False
        validate_png(png_path)
        if audit_path.stat().st_size <= 0:
            return False
        if pdf_path is not None:
            validate_pdf(pdf_path)
    except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
        return False
    return True


def write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def render_frame(
    *,
    python: Path,
    renderer: Path,
    source: Path,
    pvd_path: Path,
    case_key: str,
    quantity: str,
    step: int,
    time_years: float,
    output_root: Path,
    png_dpi: int,
    make_pdf: bool,
    force: bool,
    dry_run: bool,
) -> dict[str, object]:
    quantity_root = output_root / case_key / quantity
    stem = f"{case_key}_{quantity}_{step:04d}"
    png_path = quantity_root / "png" / f"{stem}.png"
    audit_path = quantity_root / "audit" / f"{stem}.csv"
    pdf_path = quantity_root / "pdf" / f"{stem}.pdf" if make_pdf else None
    log_path = quantity_root / "logs" / f"{stem}.log"
    marker_path = quantity_root / "complete" / f"{stem}.json"
    if not force and marker_is_current(
        marker_path, source, png_path, audit_path, pdf_path
    ):
        return {"step": step, "status": "skipped", "time_years": time_years}

    for path in (png_path, audit_path, log_path, marker_path):
        path.parent.mkdir(parents=True, exist_ok=True)
    if pdf_path is not None:
        pdf_path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        str(python),
        str(renderer),
        "--input",
        str(source),
        "--pvd",
        str(pvd_path),
        "--png",
        str(png_path),
        "--audit-csv",
        str(audit_path),
        "--png-dpi",
        str(png_dpi),
        "--no-svg",
    ]
    if make_pdf:
        assert pdf_path is not None
        command.extend(["--pdf", str(pdf_path)])
    else:
        command.append("--no-pdf")
    if dry_run:
        return {
            "step": step,
            "status": "dry-run",
            "time_years": time_years,
            "command": command,
        }

    environment = os.environ.copy()
    environment.update(
        {
            "MPLBACKEND": "Agg",
            "PYVISTA_OFF_SCREEN": "true",
            "OMP_NUM_THREADS": "1",
            "OPENBLAS_NUM_THREADS": "1",
            "MKL_NUM_THREADS": "1",
        }
    )
    completed = subprocess.run(
        command,
        text=True,
        capture_output=True,
        env=environment,
        check=False,
    )
    log_path.write_text(
        "COMMAND=" + json.dumps(command) + "\n\nSTDOUT\n" + completed.stdout
        + "\nSTDERR\n" + completed.stderr,
        encoding="utf-8",
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Renderer failed for {case_key} {quantity} step {step}; "
            f"see {log_path}"
        )
    width, height = validate_png(png_path)
    if audit_path.stat().st_size <= 0:
        raise ValueError(f"Empty audit CSV: {audit_path}")
    if pdf_path is not None:
        validate_pdf(pdf_path)
    source_stat = source.stat()
    marker = {
        "status": "pass",
        "case_key": case_key,
        "quantity": quantity,
        "step": step,
        "time_years": time_years,
        "source": str(source),
        "source_bytes": source_stat.st_size,
        "source_mtime_ns": source_stat.st_mtime_ns,
        "renderer": str(renderer),
        "renderer_sha256": sha256_file(renderer),
        "png": str(png_path),
        "png_bytes": png_path.stat().st_size,
        "png_width": width,
        "png_height": height,
        "audit_csv": str(audit_path),
        "audit_csv_bytes": audit_path.stat().st_size,
        "pdf": str(pdf_path) if pdf_path is not None else None,
        "pdf_bytes": pdf_path.stat().st_size if pdf_path is not None else 0,
        "command": command,
    }
    write_json_atomic(marker_path, marker)
    return {"step": step, "status": "rendered", "time_years": time_years}


def main() -> None:
    args = parse_args()
    if args.png_dpi < 300:
        raise ValueError("png-dpi must be at least 300 for publication frames")
    work = map_task(args.task_id, args.chunk_size)
    if args.step_override is not None:
        if not 1 <= args.step_override <= EXPECTED_REPORT_STEPS:
            raise ValueError("step-override must be in 1:210")
        work = replace(
            work,
            first_step=args.step_override,
            last_step=args.step_override,
        )
    vtu_job_root = args.vtu_job_root.expanduser().resolve()
    output_root = args.output_root.expanduser().resolve()
    repo_root = args.repo_root.expanduser().resolve()
    python = absolute_path_preserving_symlinks(args.python)
    if not python.is_file():
        raise FileNotFoundError(python)
    if not (vtu_job_root / "PASS").is_file():
        raise FileNotFoundError(f"VTU job has no final PASS marker: {vtu_job_root}")
    case_dir = discover_case(vtu_job_root, work.case_task)
    case_key = case_dir.name
    vtu_dir = case_dir / "vtu"
    if not (vtu_dir / "export_summary.txt").is_file():
        raise FileNotFoundError(vtu_dir / "export_summary.txt")
    pvd_path, states = load_report_states(vtu_dir)
    pdf_steps = resolve_pdf_steps(states, args.pdf_years)
    renderer = (
        repo_root
        / "scripts"
        / "visualization"
        / (
            "gom_rs_publication/render_gom_rs_cross_section.py"
            if work.quantity == "rs"
            else "gom_saturation_publication/render_gom_saturation_cross_section.py"
        )
    )
    if not renderer.is_file():
        raise FileNotFoundError(renderer)

    results: list[dict[str, object]] = []
    for step in range(work.first_step, work.last_step + 1):
        source, time_years = states[step]
        results.append(
            render_frame(
                python=python,
                renderer=renderer,
                source=source,
                pvd_path=pvd_path,
                case_key=case_key,
                quantity=work.quantity,
                step=step,
                time_years=time_years,
                output_root=output_root,
                png_dpi=args.png_dpi,
                make_pdf=step in pdf_steps,
                force=args.force,
                dry_run=args.dry_run,
            )
        )

    summary = {
        "status": "dry-run" if args.dry_run else "pass",
        "task_id": args.task_id,
        "total_task_count": work.total_task_count,
        "case_task": work.case_task,
        "case_key": case_key,
        "quantity": work.quantity,
        "chunk_index": work.chunk_index,
        "chunk_count": work.chunk_count,
        "first_step": work.first_step,
        "last_step": work.last_step,
        "png_dpi": args.png_dpi,
        "pdf_years": list(args.pdf_years),
        "renderer": str(renderer),
        "renderer_sha256": sha256_file(renderer),
        "results": results,
    }
    chunk_path = output_root / "_chunks" / f"task_{args.task_id:04d}.json"
    if not args.dry_run:
        write_json_atomic(chunk_path, summary)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
