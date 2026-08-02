#!/usr/bin/env python3
"""Verify the immutable control plane for a promoted Step62 shard.

The archive job performs a full payload checksum before atomic promotion. A
later production submission uses this verifier to prove that the promoted
shard belongs to the exact campaign and task range without rereading tens of
gigabytes of restart and VTU payload. The SHA256SUMS inventory itself is
pinned by SHARD_COMPLETE, and all small identity/provenance files are hashed
again against that inventory.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any

from gom_step62_production_manifest import ManifestError, load_and_validate


SHA256_RE = re.compile(r"[0-9a-f]{64}")
SUM_LINE_RE = re.compile(r"^([0-9a-f]{64}) [ *](.+)$")
CONTROL_FILES = (
    "CASE_INDEX.tsv",
    "campaign.toml",
    "campaign.toml.sha256.original",
    "JUTULDARCY_COMMIT.txt",
    "SHARD_METADATA.txt",
)


class ShardError(RuntimeError):
    """Raised when a durable shard cannot be safely reused."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_key_values(path: Path, label: str) -> dict[str, str]:
    if not path.is_file():
        raise ShardError(f"missing {label}: {path}")
    values: dict[str, str] = {}
    for line_number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw.strip()
        if not line:
            continue
        if "=" not in line:
            raise ShardError(f"{label} line {line_number} is not key=value")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise ShardError(f"{label} has an empty or duplicate key: {key!r}")
        values[key] = value
    return values


def require_value(values: dict[str, str], key: str, expected: str, label: str) -> None:
    observed = values.get(key)
    if observed != expected:
        raise ShardError(
            f"{label}.{key} mismatch: expected {expected!r}, observed {observed!r}"
        )


def parse_checksum_inventory(path: Path) -> dict[str, str]:
    if not path.is_file() or path.stat().st_size == 0:
        raise ShardError(f"missing or empty checksum inventory: {path}")
    entries: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = SUM_LINE_RE.fullmatch(line)
        if match is None:
            raise ShardError(f"invalid SHA256SUMS line {line_number}")
        digest, raw_name = match.groups()
        name = raw_name[2:] if raw_name.startswith("./") else raw_name
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise ShardError(f"unsafe SHA256SUMS path: {raw_name!r}")
        normalized = relative.as_posix()
        if normalized in entries:
            raise ShardError(f"duplicate SHA256SUMS path: {normalized}")
        entries[normalized] = digest
    return entries


def verify_control_file(shard: Path, entries: dict[str, str], name: str) -> str:
    expected = entries.get(name)
    if expected is None:
        raise ShardError(f"SHA256SUMS does not contain {name}")
    path = shard / name
    if not path.is_file():
        raise ShardError(f"missing shard control file: {path}")
    observed = sha256_file(path)
    if observed != expected:
        raise ShardError(
            f"{name} SHA-256 mismatch: expected {expected}, observed {observed}"
        )
    return observed


def verify_case_index(
    path: Path, manifest: dict[str, Any], start: int, end: int
) -> None:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        expected_fields = ["task", "case_key", "geology_id", "realization_id"]
        if reader.fieldnames != expected_fields:
            raise ShardError("CASE_INDEX.tsv has the wrong header")
        rows = list(reader)
    if len(rows) != end - start + 1:
        raise ShardError("CASE_INDEX.tsv has the wrong row count")
    for task, row in zip(range(start, end + 1), rows):
        case = manifest["cases"][task - 1]
        expected = {
            "task": str(task),
            "case_key": case["case_key"],
            "geology_id": case["geology_id"],
            "realization_id": str(case["realization_id"]),
        }
        if row != expected:
            raise ShardError(
                f"CASE_INDEX.tsv task {task} mismatch: expected {expected}, got {row}"
            )


def verify_shard(
    manifest_path: str, shard_path: str, start: int, end: int
) -> dict[str, Any]:
    # The caller performs the campaign-wide input checksum gate once. Reuse
    # verification needs manifest identity/order but deliberately avoids a
    # second read of all 1,621 input MATs.
    manifest = load_and_validate(manifest_path, verify_files=False)
    if start < 1 or end < start or end > len(manifest["cases"]):
        raise ShardError(f"invalid task range {start}:{end}")
    shard = Path(shard_path).expanduser().resolve(strict=True)
    if not shard.is_dir():
        raise ShardError(f"shard is not a directory: {shard}")

    count = end - start + 1
    marker = parse_key_values(shard / "SHARD_COMPLETE", "SHARD_COMPLETE")
    require_value(marker, "status", "pass", "SHARD_COMPLETE")
    require_value(
        marker, "campaign_id", manifest["campaign_id"], "SHARD_COMPLETE"
    )
    require_value(
        marker,
        "campaign_manifest_sha256",
        manifest["manifest_sha256"],
        "SHARD_COMPLETE",
    )
    require_value(
        marker,
        "physics_profile",
        manifest["workflow"]["physics_profile"],
        "SHARD_COMPLETE",
    )
    require_value(marker, "task_start", str(start), "SHARD_COMPLETE")
    require_value(marker, "task_end", str(end), "SHARD_COMPLETE")
    require_value(marker, "case_count", str(count), "SHARD_COMPLETE")
    require_value(
        marker,
        "all_payload_sha256_verified_before_atomic_promote",
        "true",
        "SHARD_COMPLETE",
    )

    sums_path = shard / "SHA256SUMS"
    sums_digest = sha256_file(sums_path)
    recorded_sums_digest = marker.get("sha256sums_sha256", "")
    if not SHA256_RE.fullmatch(recorded_sums_digest):
        raise ShardError("SHARD_COMPLETE has no valid sha256sums_sha256")
    if sums_digest != recorded_sums_digest:
        raise ShardError(
            "SHA256SUMS digest mismatch: "
            f"expected {recorded_sums_digest}, observed {sums_digest}"
        )
    entries = parse_checksum_inventory(sums_path)
    control_digests = {
        name: verify_control_file(shard, entries, name) for name in CONTROL_FILES
    }
    if control_digests["campaign.toml"] != manifest["manifest_sha256"]:
        raise ShardError("archived campaign.toml is not the selected manifest")
    commit = (shard / "JUTULDARCY_COMMIT.txt").read_text(
        encoding="utf-8"
    ).strip()
    if commit != manifest["jutuldarcy_commit"]:
        raise ShardError("archived JutulDarcy commit does not match the manifest")

    metadata = parse_key_values(shard / "SHARD_METADATA.txt", "SHARD_METADATA")
    require_value(metadata, "status", "ready_for_promotion", "SHARD_METADATA")
    require_value(
        metadata, "campaign_id", manifest["campaign_id"], "SHARD_METADATA"
    )
    require_value(
        metadata,
        "campaign_manifest_sha256",
        manifest["manifest_sha256"],
        "SHARD_METADATA",
    )
    require_value(
        metadata,
        "case_order_sha256",
        manifest["case_order_sha256"],
        "SHARD_METADATA",
    )
    require_value(
        metadata,
        "physics_profile",
        manifest["workflow"]["physics_profile"],
        "SHARD_METADATA",
    )
    require_value(metadata, "task_start", str(start), "SHARD_METADATA")
    require_value(metadata, "task_end", str(end), "SHARD_METADATA")
    require_value(metadata, "case_count", str(count), "SHARD_METADATA")
    verify_case_index(shard / "CASE_INDEX.tsv", manifest, start, end)

    return {
        "status": "reusable",
        "campaign_id": manifest["campaign_id"],
        "campaign_manifest_sha256": manifest["manifest_sha256"],
        "physics_profile": manifest["workflow"]["physics_profile"],
        "task_start": start,
        "task_end": end,
        "case_count": count,
        "shard": str(shard),
        "sha256sums_sha256": sums_digest,
        "control_files_rehashed": len(CONTROL_FILES),
        "payload_reread": False,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--shard", required=True)
    parser.add_argument("--start", type=int, required=True)
    parser.add_argument("--end", type=int, required=True)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    result = verify_shard(
        arguments.manifest, arguments.shard, arguments.start, arguments.end
    )
    if arguments.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            "SHARD_REUSABLE "
            f"tasks={result['task_start']}:{result['task_end']} "
            f"cases={result['case_count']} "
            f"sha256sums={result['sha256sums_sha256']} "
            f"path={result['shard']}"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ManifestError, OSError, ValueError, IndexError, ShardError) as error:
        print(f"SHARD_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
