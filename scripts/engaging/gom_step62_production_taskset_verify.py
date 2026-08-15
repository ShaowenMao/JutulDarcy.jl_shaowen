#!/usr/bin/env python3
"""Verify the immutable control plane of a noncontiguous production task set."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any

from gom_step62_production_manifest import load_and_validate


SUM_LINE_RE = re.compile(r"^([0-9a-f]{64}) [ *](.+)$")
CONTROL_FILES = (
    "CASE_INDEX.tsv",
    "TASKSET_SELECTION.tsv",
    "campaign.toml",
    "campaign.toml.sha256.original",
    "JUTULDARCY_COMMIT.txt",
    "TASKSET_METADATA.txt",
)


class TasksetError(RuntimeError):
    """Raised when a durable task set is not safe to reuse."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_key_values(path: Path, label: str) -> dict[str, str]:
    if not path.is_file():
        raise TasksetError(f"missing {label}: {path}")
    values: dict[str, str] = {}
    for line_number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw:
            continue
        if "=" not in raw:
            raise TasksetError(f"{label} line {line_number} is not key=value")
        key, value = raw.split("=", 1)
        if not key or key in values:
            raise TasksetError(f"{label} has an empty or duplicate key: {key!r}")
        values[key] = value
    return values


def require_value(
    values: dict[str, str], key: str, expected: str, label: str
) -> None:
    observed = values.get(key)
    if observed != expected:
        raise TasksetError(
            f"{label}.{key} mismatch: expected {expected!r}, observed {observed!r}"
        )


def parse_checksum_inventory(path: Path) -> dict[str, str]:
    if not path.is_file() or path.stat().st_size == 0:
        raise TasksetError(f"missing or empty checksum inventory: {path}")
    entries: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = SUM_LINE_RE.fullmatch(line)
        if match is None:
            raise TasksetError(f"invalid SHA256SUMS line {line_number}")
        digest, raw_name = match.groups()
        name = raw_name[2:] if raw_name.startswith("./") else raw_name
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise TasksetError(f"unsafe SHA256SUMS path: {raw_name!r}")
        normalized = relative.as_posix()
        if normalized in entries:
            raise TasksetError(f"duplicate SHA256SUMS path: {normalized}")
        entries[normalized] = digest
    return entries


def read_selection(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"task", "case_key", "geology_id", "realization_id"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise TasksetError("task-set selection has the wrong header")
        rows = list(reader)
    if not rows:
        raise TasksetError("task-set selection is empty")
    tasks = [int(row["task"]) for row in rows]
    if len(set(tasks)) != len(tasks):
        raise TasksetError("task-set selection contains duplicate tasks")
    return rows


def verify_taskset(
    manifest_path: str, taskset_path: str, selection_path: str
) -> dict[str, Any]:
    manifest = load_and_validate(manifest_path, verify_files=False)
    taskset = Path(taskset_path).expanduser().resolve(strict=True)
    selection = Path(selection_path).expanduser().resolve(strict=True)
    if not taskset.is_dir():
        raise TasksetError(f"task set is not a directory: {taskset}")
    selected = read_selection(selection)
    selected_tasks = [int(row["task"]) for row in selected]
    count = len(selected)

    for row in selected:
        task = int(row["task"])
        if not 1 <= task <= len(manifest["cases"]):
            raise TasksetError(f"selected task {task} is outside the campaign")
        case = manifest["cases"][task - 1]
        expected = {
            "case_key": str(case["case_key"]),
            "geology_id": str(case["geology_id"]),
            "realization_id": str(case["realization_id"]),
        }
        observed = {field: row[field] for field in expected}
        if observed != expected:
            raise TasksetError(
                f"selection task {task} mismatch: expected {expected}, got {observed}"
            )

    marker = parse_key_values(taskset / "TASKSET_COMPLETE", "TASKSET_COMPLETE")
    require_value(marker, "status", "pass", "TASKSET_COMPLETE")
    require_value(marker, "campaign_id", manifest["campaign_id"], "TASKSET_COMPLETE")
    require_value(
        marker,
        "campaign_manifest_sha256",
        manifest["manifest_sha256"],
        "TASKSET_COMPLETE",
    )
    require_value(marker, "case_count", str(count), "TASKSET_COMPLETE")
    require_value(
        marker,
        "taskset_selection_sha256",
        sha256_file(selection),
        "TASKSET_COMPLETE",
    )
    require_value(
        marker,
        "all_payload_sha256_verified_before_atomic_promote",
        "true",
        "TASKSET_COMPLETE",
    )

    inventory = taskset / "SHA256SUMS"
    entries = parse_checksum_inventory(inventory)
    require_value(
        marker,
        "sha256sums_sha256",
        sha256_file(inventory),
        "TASKSET_COMPLETE",
    )
    control_hashes: dict[str, str] = {}
    for name in CONTROL_FILES:
        expected = entries.get(name)
        path = taskset / name
        if expected is None or not path.is_file():
            raise TasksetError(f"missing checksummed control file {name}")
        observed = sha256_file(path)
        if observed != expected:
            raise TasksetError(f"{name} SHA-256 mismatch")
        control_hashes[name] = observed

    archived_selection = read_selection(taskset / "TASKSET_SELECTION.tsv")
    if archived_selection != selected:
        raise TasksetError("archived task-set selection differs from the pinned selection")
    with (taskset / "CASE_INDEX.tsv").open(newline="", encoding="utf-8") as handle:
        case_index = list(csv.DictReader(handle, delimiter="\t"))
    expected_index = [
        {
            "task": row["task"],
            "case_key": row["case_key"],
            "geology_id": row["geology_id"],
            "realization_id": row["realization_id"],
        }
        for row in selected
    ]
    if case_index != expected_index:
        raise TasksetError("CASE_INDEX.tsv differs from the selected campaign cases")

    metadata = parse_key_values(taskset / "TASKSET_METADATA.txt", "TASKSET_METADATA")
    require_value(metadata, "campaign_id", manifest["campaign_id"], "TASKSET_METADATA")
    require_value(
        metadata,
        "campaign_manifest_sha256",
        manifest["manifest_sha256"],
        "TASKSET_METADATA",
    )
    require_value(metadata, "case_count", str(count), "TASKSET_METADATA")
    require_value(
        metadata,
        "taskset_selection_sha256",
        sha256_file(selection),
        "TASKSET_METADATA",
    )
    observed_commit = (taskset / "JUTULDARCY_COMMIT.txt").read_text(
        encoding="utf-8"
    ).strip()
    if observed_commit != manifest["jutuldarcy_commit"]:
        raise TasksetError("task-set simulation commit differs from the campaign")

    return {
        "status": "reusable",
        "campaign_id": manifest["campaign_id"],
        "campaign_manifest_sha256": manifest["manifest_sha256"],
        "taskset": str(taskset),
        "case_count": count,
        "tasks": selected_tasks,
        "taskset_selection_sha256": sha256_file(selection),
        "sha256sums_sha256": sha256_file(inventory),
        "control_sha256": control_hashes,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--taskset", required=True)
    parser.add_argument("--selection", required=True)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = verify_taskset(args.manifest, args.taskset, args.selection)
    except (OSError, ValueError, TasksetError) as error:
        print(f"TASKSET_INVALID: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, sort_keys=True, indent=2))
    else:
        print(
            "TASKSET_REUSABLE "
            f"cases={result['case_count']} "
            f"selection_sha256={result['taskset_selection_sha256']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
