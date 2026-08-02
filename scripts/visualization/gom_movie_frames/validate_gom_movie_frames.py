"""Validate and certify durable GOM movie-frame outputs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

from render_gom_movie_frames import (
    CASE_TASKS,
    QUANTITIES,
    discover_case,
    load_report_states,
    resolve_pdf_steps,
    validate_pdf,
    validate_png,
    write_json_atomic,
)


PDF_YEARS = (25.0, 50.0, 100.0, 1000.0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vtu-job-root", type=Path, required=True)
    parser.add_argument("--render-root", type=Path, required=True)
    parser.add_argument("--mode", choices=("smoke", "full"), required=True)
    parser.add_argument("--workflow-repo", type=Path, required=True)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_series(
    *,
    case_key: str,
    quantity: str,
    states: dict[int, tuple[Path, float]],
    render_root: Path,
    expected_steps: list[int],
    pdf_steps: dict[int, float],
    renderer: Path,
    renderer_sha256: str,
) -> tuple[list[dict[str, object]], list[Path]]:
    series_root = render_root / case_key / quantity
    rows: list[dict[str, object]] = []
    durable_files: list[Path] = []
    for step in expected_steps:
        source, time_years = states[step]
        stem = f"{case_key}_{quantity}_{step:04d}"
        png = series_root / "png" / f"{stem}.png"
        audit = series_root / "audit" / f"{stem}.csv"
        log = series_root / "logs" / f"{stem}.log"
        marker_path = series_root / "complete" / f"{stem}.json"
        pdf = series_root / "pdf" / f"{stem}.pdf" if step in pdf_steps else None
        width, height = validate_png(png)
        if audit.stat().st_size <= 0:
            raise ValueError(f"Empty audit CSV: {audit}")
        if not audit.read_text(encoding="utf-8").startswith(
            "domain_type,geology_id,component_id,"
        ):
            raise ValueError(f"Unexpected audit schema: {audit}")
        if log.stat().st_size <= 0:
            raise ValueError(f"Empty renderer log: {log}")
        log_text = log.read_text(encoding="utf-8")
        required_log_lines = (
            "STRATIGRAPHY_SMOOTHING_MODE=lithology_connected",
            "SMOOTH_LENGTH_M=12.5",
            "DISPLAY_CUTOFF=0.015",
            "SVG=SKIPPED",
        )
        if any(item not in log_text for item in required_log_lines):
            raise ValueError(f"Renderer contract mismatch in {log}")
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        expected_marker = {
            "status": "pass",
            "case_key": case_key,
            "quantity": quantity,
            "step": step,
            "source": str(source),
            "renderer": str(renderer),
            "renderer_sha256": renderer_sha256,
            "png": str(png),
            "audit_csv": str(audit),
            "pdf": str(pdf) if pdf is not None else None,
        }
        for key, value in expected_marker.items():
            if marker.get(key) != value:
                raise ValueError(
                    f"Marker mismatch for {marker_path}: {key}="
                    f"{marker.get(key)!r}, expected {value!r}"
                )
        if not math.isclose(
            float(marker["time_years"]), time_years, abs_tol=1.0e-12, rel_tol=0.0
        ):
            raise ValueError(f"Time mismatch in {marker_path}")
        if marker.get("png_width") != width or marker.get("png_height") != height:
            raise ValueError(f"PNG dimensions disagree with {marker_path}")
        command = marker.get("command")
        if not isinstance(command, list):
            raise ValueError(f"Missing command array in {marker_path}")
        if "--no-svg" not in command or "--png-dpi" not in command:
            raise ValueError(f"Output-selection flags missing in {marker_path}")
        dpi_index = command.index("--png-dpi")
        if command[dpi_index + 1] != "600":
            raise ValueError(f"Unexpected PNG DPI in {marker_path}")
        if (pdf is None) != ("--no-pdf" in command):
            raise ValueError(f"PDF selection mismatch in {marker_path}")
        if pdf is not None:
            validate_pdf(pdf)
        rows.append(
            {
                "step": step,
                "time_years": f"{time_years:.17g}",
                "source_vtu": str(source),
                "png": str(png),
                "pdf": str(pdf) if pdf is not None else "",
                "audit_csv": str(audit),
                "completion_marker": str(marker_path),
            }
        )
        durable_files.extend([png, audit, log, marker_path])
        if pdf is not None:
            durable_files.append(pdf)
    expected_stems = {
        f"{case_key}_{quantity}_{step:04d}" for step in expected_steps
    }
    observed = {
        path.stem for path in (series_root / "png").glob("*.png")
    }
    if observed != expected_stems:
        raise ValueError(f"PNG set mismatch in {series_root}")
    observed = {
        path.stem for path in (series_root / "audit").glob("*.csv")
    }
    if observed != expected_stems:
        raise ValueError(f"Audit set mismatch in {series_root}")
    observed = {
        path.stem for path in (series_root / "logs").glob("*.log")
    }
    if observed != expected_stems:
        raise ValueError(f"Log set mismatch in {series_root}")
    observed = {
        path.stem for path in (series_root / "complete").glob("*.json")
    }
    if observed != expected_stems:
        raise ValueError(f"Completion-marker set mismatch in {series_root}")
    expected_pdf_stems = {
        f"{case_key}_{quantity}_{step:04d}" for step in pdf_steps
        if step in expected_steps
    }
    observed = {
        path.stem for path in (series_root / "pdf").glob("*.pdf")
    }
    if observed != expected_pdf_stems:
        raise ValueError(f"PDF set mismatch in {series_root}")
    if any(series_root.rglob("*.svg")):
        raise ValueError(f"Unexpected SVG output in {series_root}")
    return rows, durable_files


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def main() -> None:
    args = parse_args()
    vtu_root = args.vtu_job_root.expanduser().resolve()
    render_root = args.render_root.expanduser().resolve()
    workflow_repo = args.workflow_repo.expanduser().resolve()
    if not (vtu_root / "PASS").is_file():
        raise FileNotFoundError(f"VTU job has no PASS marker: {vtu_root}")
    if not render_root.is_dir():
        raise FileNotFoundError(render_root)

    expected_case_tasks = CASE_TASKS if args.mode == "full" else (7,)
    expected_steps = list(range(1, 211)) if args.mode == "full" else [210]
    expected_chunk_ids = (
        set(range(1, 127)) if args.mode == "full" else {85, 106}
    )
    chunk_dir = render_root / "_chunks"
    observed_chunk_ids: set[int] = set()
    chunk_paths: list[Path] = []
    for path in sorted(chunk_dir.glob("task_*.json")):
        summary = json.loads(path.read_text(encoding="utf-8"))
        if summary.get("status") != "pass":
            raise ValueError(f"Chunk did not pass: {path}")
        observed_chunk_ids.add(int(summary["task_id"]))
        chunk_paths.append(path)
    if observed_chunk_ids != expected_chunk_ids:
        raise ValueError(
            f"Chunk IDs differ: observed {sorted(observed_chunk_ids)}, "
            f"expected {sorted(expected_chunk_ids)}"
        )

    all_durable_files: list[Path] = list(chunk_paths)
    series_count = 0
    manifest_rows = 0
    pdf_count = 0
    case_keys: list[str] = []
    for case_task in expected_case_tasks:
        case_dir = discover_case(vtu_root, case_task)
        case_key = case_dir.name
        case_keys.append(case_key)
        _, states = load_report_states(case_dir / "vtu")
        pdf_steps = resolve_pdf_steps(states, PDF_YEARS)
        if args.mode == "smoke":
            pdf_steps = {210: 1000.0}
        for quantity in QUANTITIES:
            renderer = (
                workflow_repo
                / "scripts"
                / "visualization"
                / (
                    "gom_rs_publication/render_gom_rs_cross_section.py"
                    if quantity == "rs"
                    else "gom_saturation_publication/"
                    "render_gom_saturation_cross_section.py"
                )
            ).resolve()
            renderer_sha256 = sha256_file(renderer)
            rows, durable_files = validate_series(
                case_key=case_key,
                quantity=quantity,
                states=states,
                render_root=render_root,
                expected_steps=expected_steps,
                pdf_steps=pdf_steps,
                renderer=renderer,
                renderer_sha256=renderer_sha256,
            )
            manifest_path = (
                render_root / case_key / quantity / "frame_manifest.csv"
            )
            write_csv(manifest_path, rows)
            all_durable_files.extend(durable_files)
            all_durable_files.append(manifest_path)
            series_count += 1
            manifest_rows += len(rows)
            pdf_count += sum(bool(row["pdf"]) for row in rows)

    checksum_path = render_root / "OUTPUT_SHA256.txt"
    with checksum_path.open("w", encoding="utf-8") as stream:
        for path in sorted(set(all_durable_files)):
            relative = path.relative_to(render_root)
            stream.write(f"{sha256_file(path)}  {relative.as_posix()}\n")
    summary = {
        "status": "pass",
        "mode": args.mode,
        "case_tasks": list(expected_case_tasks),
        "case_keys": case_keys,
        "quantities": list(QUANTITIES),
        "series_count": series_count,
        "report_frames_per_series": len(expected_steps),
        "png_files": manifest_rows,
        "audit_csv_files": manifest_rows,
        "pdf_files": pdf_count,
        "frame_manifest_rows": manifest_rows,
        "chunk_files": len(observed_chunk_ids),
        "output_sha256_files": len(set(all_durable_files)),
        "png_dpi": 600,
        "pdf_years": list(PDF_YEARS if args.mode == "full" else (1000.0,)),
        "stratigraphy_smoothing_mode": "lithology_connected",
        "rs_colorbar": "CSP11_IceFire_white_zero_0_18",
        "sg_colorbar": "inverted_black_body_0_0.6",
        "workflow_commit": subprocess_commit(workflow_repo),
    }
    write_json_atomic(render_root / "RENDER_JOB_SUMMARY.json", summary)
    (render_root / "PASS").write_text("PASS\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))


def subprocess_commit(repository: Path) -> str:
    import subprocess

    return subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


if __name__ == "__main__":
    main()
