#!/usr/bin/env python3.12
"""Validate and resolve the immutable Step62 seven-case pilot manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import sys
import tomllib
from typing import Any


SCHEMA_VERSION = 1
CANONICAL_CASES = (
    ("s05_c012_case01", "s05_c012", 1),
    ("s05_c012_case03", "s05_c012", 3),
    ("s05_c012_case04", "s05_c012", 4),
    ("s05_c012_case07", "s05_c012", 7),
    ("s03_c001_case04", "s03_c001", 4),
    ("s03_c012_case08", "s03_c012", 8),
    ("s04_c024_case03", "s04_c024", 3),
)
CANONICAL_CASE_KEYS = tuple(case[0] for case in CANONICAL_CASES)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
GLOB_CHARACTERS = set("*?[]{}")


class ManifestError(RuntimeError):
    """Raised when the immutable campaign contract is not satisfied."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_string(table: dict[str, Any], key: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value:
        raise ManifestError(f"{key} must be a non-empty string")
    return value


def require_sha256(table: dict[str, Any], key: str) -> str:
    value = require_string(table, key).lower()
    if not SHA256_RE.fullmatch(value):
        raise ManifestError(f"{key} must be a lowercase 64-character SHA-256")
    return value


def require_git_commit(table: dict[str, Any], key: str) -> str:
    value = require_string(table, key).lower()
    if not GIT_COMMIT_RE.fullmatch(value):
        raise ManifestError(f"{key} must be a lowercase 40-character Git commit")
    return value


def require_nonnegative_int(table: dict[str, Any], key: str) -> int:
    value = table.get(key)
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 0
    ):
        raise ManifestError(f"{key} must be a non-negative integer")
    return value


def require_exact_file(value: str, label: str) -> Path:
    if any(character in value for character in GLOB_CHARACTERS):
        raise ManifestError(f"{label} contains a wildcard: {value}")
    path = Path(value)
    if not path.is_absolute():
        raise ManifestError(f"{label} must be an absolute path: {value}")
    if not path.is_file():
        raise ManifestError(f"{label} does not exist or is not a file: {value}")
    return path.resolve(strict=True)


def validate_companion(manifest_path: Path) -> str:
    companion = Path(str(manifest_path) + ".sha256")
    if not companion.is_file():
        raise ManifestError(f"missing manifest companion: {companion}")
    lines = [
        line.strip()
        for line in companion.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if len(lines) != 1:
        raise ManifestError(f"{companion} must contain exactly one checksum line")
    parts = lines[0].split(maxsplit=1)
    if len(parts) != 2:
        raise ManifestError(f"invalid sha256sum line in {companion}")
    expected = parts[0].lower()
    if not SHA256_RE.fullmatch(expected):
        raise ManifestError(f"invalid SHA-256 in {companion}")
    recorded_name = parts[1].lstrip("*")
    if Path(recorded_name).name != manifest_path.name:
        raise ManifestError(
            f"{companion} names {recorded_name!r}, expected {manifest_path.name!r}"
        )
    observed = sha256_file(manifest_path)
    if observed != expected:
        raise ManifestError(
            f"manifest SHA-256 mismatch: expected {expected}, observed {observed}"
        )
    return observed


def load_and_validate(manifest_name: str, *, verify_files: bool = True) -> dict[str, Any]:
    manifest_path = require_exact_file(manifest_name, "manifest")
    manifest_sha256 = validate_companion(manifest_path)
    try:
        with manifest_path.open("rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        raise ManifestError(f"invalid TOML in {manifest_path}: {error}") from error

    if data.get("schema_version") != SCHEMA_VERSION:
        raise ManifestError(
            f"schema_version must be {SCHEMA_VERSION}, got "
            f"{data.get('schema_version')!r}"
        )
    campaign_id = require_string(data, "campaign_id")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", campaign_id):
        raise ManifestError(f"unsafe campaign_id: {campaign_id!r}")
    source_input_manifest_sha256 = require_sha256(
        data, "source_input_manifest_sha256"
    )
    mrst_prepare_commit = require_git_commit(data, "mrst_prepare_commit")
    jutuldarcy_commit = require_git_commit(data, "jutuldarcy_commit")

    archive_root = PurePosixPath(require_string(data, "archive_root"))
    if not archive_root.is_absolute():
        raise ManifestError("archive_root must be absolute")
    required_archive_root = PurePosixPath(
        "/orcd/data/juanes/001/shaowen/gom_grid"
    )
    try:
        archive_root.relative_to(required_archive_root)
    except ValueError as error:
        raise ManifestError(
            f"archive_root must be within {required_archive_root}"
        ) from error

    common = data.get("common")
    if not isinstance(common, dict):
        raise ManifestError("[common] table is required")
    common_path = require_exact_file(
        require_string(common, "path"), "common.path"
    )
    if common_path.suffix.lower() != ".mat":
        raise ManifestError("common.path must name a .mat file")
    if common_path.name != "gom_step62_87slice_7case_common.mat":
        raise ManifestError(
            "common.path must name gom_step62_87slice_7case_common.mat"
        )
    common_sha256 = require_sha256(common, "sha256")
    common_bytes = require_nonnegative_int(common, "bytes")
    if common_bytes == 0:
        raise ManifestError("common.bytes must be positive")

    cases = data.get("cases")
    if not isinstance(cases, list):
        raise ManifestError("seven [[cases]] tables are required")
    if len(cases) != len(CANONICAL_CASE_KEYS):
        raise ManifestError(
            f"expected {len(CANONICAL_CASE_KEYS)} cases, got {len(cases)}"
        )

    observed_keys: list[str] = []
    normalized_cases: list[dict[str, Any]] = []
    seen_paths: set[Path] = set()
    for index, case in enumerate(cases, start=1):
        if not isinstance(case, dict):
            raise ManifestError(f"cases[{index}] must be a table")
        task = case.get("task")
        if task != index:
            raise ManifestError(
                f"cases[{index}].task must equal its one-based position {index}"
            )
        case_key = require_string(case, "case_key")
        geology_id = require_string(case, "geology_id")
        realization_id = case.get("realization_id")
        if not isinstance(realization_id, int) or isinstance(realization_id, bool):
            raise ManifestError(
                f"cases[{index}].realization_id must be an integer"
            )
        expected_key, expected_geology, expected_realization = (
            CANONICAL_CASES[index - 1]
        )
        if (
            case_key,
            geology_id,
            realization_id,
        ) != (
            expected_key,
            expected_geology,
            expected_realization,
        ):
            raise ManifestError(
                f"cases[{index}] identity must be "
                f"{expected_key}/{expected_geology}/{expected_realization}"
            )
        specific_path = require_exact_file(
            require_string(case, "specific_path"),
            f"cases[{index}].specific_path",
        )
        if specific_path.suffix.lower() != ".mat":
            raise ManifestError(
                f"cases[{index}].specific_path must name a .mat file"
            )
        specific_sha256 = require_sha256(case, "specific_sha256")
        specific_bytes = require_nonnegative_int(case, "specific_bytes")
        if specific_bytes == 0:
            raise ManifestError(
                f"cases[{index}].specific_bytes must be positive"
            )
        geology_hash = require_sha256(case, "geology_hash")
        level3_case_name = require_string(case, "level3_case_name")
        if specific_path in seen_paths:
            raise ManifestError(f"duplicate specific path: {specific_path}")
        seen_paths.add(specific_path)
        observed_keys.append(case_key)
        normalized_cases.append(
            {
                "task": task,
                "case_key": case_key,
                "geology_id": geology_id,
                "realization_id": realization_id,
                "specific_path": str(specific_path),
                "specific_sha256": specific_sha256,
                "specific_bytes": specific_bytes,
                "geology_hash": geology_hash,
                "level3_case_name": level3_case_name,
            }
        )

    if tuple(observed_keys) != CANONICAL_CASE_KEYS:
        raise ManifestError(
            "case keys/order do not match the canonical seven-case pilot: "
            + ", ".join(CANONICAL_CASE_KEYS)
        )
    if len(set(observed_keys)) != len(observed_keys):
        raise ManifestError("case keys are not unique")

    if verify_files:
        observed_common_sha256 = sha256_file(common_path)
        if observed_common_sha256 != common_sha256:
            raise ManifestError(
                "common MAT SHA-256 mismatch: "
                f"expected {common_sha256}, observed {observed_common_sha256}"
            )
        if common_path.stat().st_size != common_bytes:
            raise ManifestError(
                "common MAT byte-size mismatch: "
                f"expected {common_bytes}, observed {common_path.stat().st_size}"
            )
        for case in normalized_cases:
            observed = sha256_file(Path(case["specific_path"]))
            if observed != case["specific_sha256"]:
                raise ManifestError(
                    f"{case['case_key']} specific MAT SHA-256 mismatch: "
                    f"expected {case['specific_sha256']}, observed {observed}"
                )
            observed_bytes = Path(case["specific_path"]).stat().st_size
            if observed_bytes != case["specific_bytes"]:
                raise ManifestError(
                    f"{case['case_key']} specific MAT byte-size mismatch: "
                    f"expected {case['specific_bytes']}, observed "
                    f"{observed_bytes}"
                )

    return {
        "schema_version": SCHEMA_VERSION,
        "manifest_path": str(manifest_path),
        "manifest_companion_path": str(manifest_path) + ".sha256",
        "manifest_sha256": manifest_sha256,
        "campaign_id": campaign_id,
        "source_input_manifest_sha256": source_input_manifest_sha256,
        "mrst_prepare_commit": mrst_prepare_commit,
        "jutuldarcy_commit": jutuldarcy_commit,
        "archive_root": str(archive_root),
        "common_path": str(common_path),
        "common_sha256": common_sha256,
        "common_bytes": common_bytes,
        "cases": normalized_cases,
    }


def shell_assignments(manifest: dict[str, Any], task: int) -> str:
    if not 1 <= task <= len(manifest["cases"]):
        raise ManifestError(f"task must be in 1:{len(manifest['cases'])}")
    case = manifest["cases"][task - 1]
    values = {
        "GOM_PRODUCTION_CAMPAIGN_ID": manifest["campaign_id"],
        "GOM_PRODUCTION_MANIFEST_PATH": manifest["manifest_path"],
        "GOM_PRODUCTION_MANIFEST_COMPANION_PATH": (
            manifest["manifest_companion_path"]
        ),
        "GOM_PRODUCTION_MANIFEST_SHA256": manifest["manifest_sha256"],
        "GOM_PRODUCTION_ARCHIVE_ROOT": manifest["archive_root"],
        "GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256": (
            manifest["source_input_manifest_sha256"]
        ),
        "GOM_PRODUCTION_MRST_PREPARE_COMMIT": manifest["mrst_prepare_commit"],
        "GOM_PRODUCTION_JUTULDARCY_COMMIT": manifest["jutuldarcy_commit"],
        "GOM_PRODUCTION_CASE_COUNT": len(manifest["cases"]),
        "GOM_PRODUCTION_TASK": task,
        "GOM_PRODUCTION_CASE_KEY": case["case_key"],
        "GOM_PRODUCTION_GEOLOGY_ID": case["geology_id"],
        "GOM_PRODUCTION_REALIZATION_ID": case["realization_id"],
        "GOM_PRODUCTION_COMMON_MAT": manifest["common_path"],
        "GOM_PRODUCTION_COMMON_SHA256": manifest["common_sha256"],
        "GOM_PRODUCTION_COMMON_BYTES": manifest["common_bytes"],
        "GOM_PRODUCTION_SPECIFIC_MAT": case["specific_path"],
        "GOM_PRODUCTION_SPECIFIC_SHA256": case["specific_sha256"],
        "GOM_PRODUCTION_SPECIFIC_BYTES": case["specific_bytes"],
        "GOM_PRODUCTION_GEOLOGY_HASH": case["geology_hash"],
        "GOM_PRODUCTION_LEVEL3_CASE_NAME": case["level3_case_name"],
    }
    return "\n".join(
        f"{key}={shlex.quote(str(value))}" for key, value in values.items()
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--json", action="store_true")
    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--task", type=int, required=True)
    resolve.add_argument("--format", choices=("shell", "json"), default="shell")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    manifest = load_and_validate(arguments.manifest)
    if arguments.command == "validate":
        if arguments.json:
            print(json.dumps(manifest, indent=2, sort_keys=True))
        else:
            print(
                "MANIFEST_VALID "
                f"campaign={manifest['campaign_id']} "
                f"cases={len(manifest['cases'])} "
                f"sha256={manifest['manifest_sha256']}"
            )
        return 0
    if arguments.command == "resolve":
        if arguments.format == "shell":
            print(shell_assignments(manifest, arguments.task))
        else:
            case = manifest["cases"][arguments.task - 1]
            print(json.dumps(case, indent=2, sort_keys=True))
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"MANIFEST_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
