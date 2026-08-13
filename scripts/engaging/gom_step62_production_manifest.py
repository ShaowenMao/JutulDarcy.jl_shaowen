#!/usr/bin/env python3.12
"""Validate and resolve immutable Step62 production campaign manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import shlex
import sys
import tomllib
from typing import Any


SUPPORTED_SCHEMA_VERSIONS = (1, 2, 3)
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
FULL_ENSEMBLE_CASE_KEYS = tuple(
    f"s{scenario:02d}_c{geology:03d}_case{realization:02d}"
    for scenario in range(1, 7)
    for geology in range(1, 28)
    for realization in range(1, 11)
)
PHASE1_CASE_IDS = tuple(range(1, 13)) + (101, 102, 103)
PHASE1_ENSEMBLE_CASE_KEYS = tuple(
    f"s{scenario:02d}_c{geology:03d}_case{realization:02d}"
    for scenario in range(1, 7)
    for geology in range(1, 28)
    for realization in PHASE1_CASE_IDS
)
FULL_CAMPAIGN_ENSEMBLES = ("full_1620", "phase1_2430")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
GEOLOGY_ID_RE = re.compile(r"^s(?P<scenario>\d{2})_c(?P<geology>\d{3})$")
GLOB_CHARACTERS = set("*?[]{}")
LEGACY_ARCHIVE_ROOT = PurePosixPath(
    "/orcd/data/juanes/001/shaowen/gom_grid"
)
PRODUCTION_ARCHIVE_ROOT = PurePosixPath(
    "/orcd/data/juanes/001/shaowen/gom_full_production"
)


class ManifestError(RuntimeError):
    """Raised when the immutable campaign contract is not satisfied."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def case_order_sha256(case_keys: list[str]) -> str:
    payload = "".join(
        f"{task}\t{case_key}\n"
        for task, case_key in enumerate(case_keys, start=1)
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


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
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ManifestError(f"{key} must be a non-negative integer")
    return value


def require_positive_int(table: dict[str, Any], key: str) -> int:
    value = require_nonnegative_int(table, key)
    if value == 0:
        raise ManifestError(f"{key} must be positive")
    return value


def require_boolean(table: dict[str, Any], key: str) -> bool:
    value = table.get(key)
    if not isinstance(value, bool):
        raise ManifestError(f"{key} must be a Boolean")
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


def validate_archive_root(value: str, ensemble_kind: str, schema: int) -> str:
    archive_root = PurePosixPath(value)
    if not archive_root.is_absolute() or ".." in archive_root.parts:
        raise ManifestError("archive_root must be an absolute normalized path")
    allowed_roots = (LEGACY_ARCHIVE_ROOT, PRODUCTION_ARCHIVE_ROOT)
    if schema == 1:
        allowed_roots = (LEGACY_ARCHIVE_ROOT,)
    if ensemble_kind in FULL_CAMPAIGN_ENSEMBLES:
        allowed_roots = (PRODUCTION_ARCHIVE_ROOT,)
    if not any(
        archive_root == root or root in archive_root.parents
        for root in allowed_roots
    ):
        allowed_text = " or ".join(str(root) for root in allowed_roots)
        raise ManifestError(f"archive_root must be within {allowed_text}")
    return str(archive_root)


def validate_case_identity(
    case_key: str,
    geology_id: str,
    realization_id: int,
    ensemble_kind: str,
) -> tuple[int, int, int]:
    match = GEOLOGY_ID_RE.fullmatch(geology_id)
    if match is None:
        raise ManifestError(f"invalid geology_id: {geology_id!r}")
    allowed_ids = PHASE1_CASE_IDS if ensemble_kind == "phase1_2430" else range(1, 11)
    if realization_id not in allowed_ids:
        allowed_text = (
            "1:12,101:103" if ensemble_kind == "phase1_2430" else "1:10"
        )
        raise ManifestError(
            f"{case_key} realization_id must be in {allowed_text}"
        )
    expected_key = f"{geology_id}_case{realization_id:02d}"
    if case_key != expected_key:
        raise ManifestError(
            f"case_key {case_key!r} does not match {expected_key!r}"
        )
    return (
        int(match.group("scenario")),
        int(match.group("geology")),
        realization_id,
    )


def normalize_workflow(
    data: dict[str, Any], schema: int, ensemble_kind: str, case_count: int
) -> dict[str, Any]:
    if schema == 1:
        return {
            "physics_profile": "legacy_fault_plateau_npctheta30",
            "qoi_mode": "off",
            "qoi_schema_version": 3,
            "retain_years": [25, 50, 100, 1000],
            "rolling_checkpoints": 2,
            "archive_shard_size": case_count,
            "archive_compact_atomic_rows": False,
            "archive_remove_verified_scratch": False,
        }
    workflow = data.get("workflow")
    if not isinstance(workflow, dict):
        raise ManifestError("[workflow] table is required for schema 2 or 3")
    physics_profile = require_string(workflow, "physics_profile")
    if physics_profile not in (
        "legacy_fault_plateau_npctheta30",
        "sandpc_effective_globalplateau_v1",
    ):
        raise ManifestError("workflow.physics_profile is not supported")
    if ensemble_kind in FULL_CAMPAIGN_ENSEMBLES and physics_profile != (
        "sandpc_effective_globalplateau_v1"
    ):
        raise ManifestError(
            f"{ensemble_kind} requires sandpc_effective_globalplateau_v1"
        )
    qoi_mode = require_string(workflow, "qoi_mode")
    if qoi_mode not in ("off", "auto", "required"):
        raise ManifestError("workflow.qoi_mode must be off, auto, or required")
    if ensemble_kind in FULL_CAMPAIGN_ENSEMBLES and qoi_mode != "required":
        raise ManifestError(
            f"{ensemble_kind} requires workflow.qoi_mode='required'"
        )
    qoi_schema_version = workflow.get(
        "qoi_schema_version", 4 if qoi_mode == "required" else 3
    )
    if not isinstance(qoi_schema_version, int) or isinstance(
        qoi_schema_version, bool
    ):
        raise ManifestError("workflow.qoi_schema_version must be an integer")
    if schema == 3 and qoi_schema_version != 4:
        raise ManifestError("schema 3 requires workflow.qoi_schema_version=4")
    retain_years = workflow.get("retain_years")
    if retain_years != [25, 50, 100, 1000]:
        raise ManifestError(
            "workflow.retain_years must be [25, 50, 100, 1000]"
        )
    rolling_checkpoints = require_positive_int(
        workflow, "rolling_checkpoints"
    )
    if rolling_checkpoints != 2:
        raise ManifestError("workflow.rolling_checkpoints must equal 2")
    shard_size = require_positive_int(workflow, "archive_shard_size")
    if shard_size > case_count:
        raise ManifestError(
            "workflow.archive_shard_size cannot exceed the case count"
        )
    compact = require_boolean(workflow, "archive_compact_atomic_rows")
    remove = require_boolean(workflow, "archive_remove_verified_scratch")
    if ensemble_kind in FULL_CAMPAIGN_ENSEMBLES and (not compact or not remove):
        raise ManifestError(
            f"{ensemble_kind} requires row compaction and verified scratch removal"
        )
    return {
        "physics_profile": physics_profile,
        "qoi_mode": qoi_mode,
        "qoi_schema_version": qoi_schema_version,
        "retain_years": retain_years,
        "rolling_checkpoints": rolling_checkpoints,
        "archive_shard_size": shard_size,
        "archive_compact_atomic_rows": compact,
        "archive_remove_verified_scratch": remove,
    }


def load_and_validate(
    manifest_name: str, *, verify_files: bool = True
) -> dict[str, Any]:
    manifest_path = require_exact_file(manifest_name, "manifest")
    manifest_sha256 = validate_companion(manifest_path)
    try:
        with manifest_path.open("rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        raise ManifestError(f"invalid TOML in {manifest_path}: {error}") from error

    schema = data.get("schema_version")
    if schema not in SUPPORTED_SCHEMA_VERSIONS:
        raise ManifestError(
            "schema_version must be one of "
            f"{SUPPORTED_SCHEMA_VERSIONS}, got {schema!r}"
        )
    campaign_id = require_string(data, "campaign_id")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", campaign_id):
        raise ManifestError(f"unsafe campaign_id: {campaign_id!r}")
    source_input_manifest_sha256 = require_sha256(
        data, "source_input_manifest_sha256"
    )
    mrst_prepare_commit = require_git_commit(data, "mrst_prepare_commit")
    jutuldarcy_commit = require_git_commit(data, "jutuldarcy_commit")
    jutul_manifest_sha256 = require_sha256(data, "jutul_manifest_sha256")

    ensemble_kind = "pilot_7"
    declared_case_count: int | None = None
    declared_order_sha256: str | None = None
    if schema >= 2:
        ensemble_kind = require_string(data, "ensemble_kind")
        supported_ensembles = (
            ("phase1_2430",)
            if schema == 3
            else ("pilot_7", "subset", "full_1620")
        )
        if ensemble_kind not in supported_ensembles:
            raise ManifestError(
                f"schema {schema} ensemble_kind must be one of "
                f"{supported_ensembles}"
            )
        declared_case_count = require_positive_int(data, "case_count")
        declared_order_sha256 = require_sha256(data, "case_order_sha256")

    archive_root = validate_archive_root(
        require_string(data, "archive_root"), ensemble_kind, schema
    )

    common = data.get("common")
    if not isinstance(common, dict):
        raise ManifestError("[common] table is required")
    common_path = require_exact_file(require_string(common, "path"), "common.path")
    if common_path.suffix.lower() != ".mat":
        raise ManifestError("common.path must name a .mat file")
    if schema == 1 and common_path.name != "gom_step62_87slice_7case_common.mat":
        raise ManifestError(
            "schema 1 common.path must name "
            "gom_step62_87slice_7case_common.mat"
        )
    common_sha256 = require_sha256(common, "sha256")
    common_bytes = require_positive_int(common, "bytes")

    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ManifestError("one or more [[cases]] tables are required")
    if schema == 1 and len(cases) != len(CANONICAL_CASE_KEYS):
        raise ManifestError(
            f"expected {len(CANONICAL_CASE_KEYS)} cases, got {len(cases)}"
        )
    if declared_case_count is not None and len(cases) != declared_case_count:
        raise ManifestError(
            f"case_count declares {declared_case_count}, got {len(cases)} tables"
        )

    observed_keys: list[str] = []
    identity_order: list[tuple[int, int, int]] = []
    normalized_cases: list[dict[str, Any]] = []
    seen_paths: set[Path] = {common_path}
    for index, case in enumerate(cases, start=1):
        if not isinstance(case, dict):
            raise ManifestError(f"cases[{index}] must be a table")
        if case.get("task") != index:
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
        if schema == 1:
            expected = CANONICAL_CASES[index - 1]
            if (case_key, geology_id, realization_id) != expected:
                raise ManifestError(
                    f"cases[{index}] identity must be "
                    f"{expected[0]}/{expected[1]}/{expected[2]}"
                )
        else:
            identity_order.append(
                validate_case_identity(
                    case_key, geology_id, realization_id, ensemble_kind
                )
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
        specific_bytes = require_positive_int(case, "specific_bytes")
        geology_hash = require_sha256(case, "geology_hash")
        level3_case_name = require_string(case, "level3_case_name")
        if specific_path in seen_paths:
            raise ManifestError(f"duplicate input path: {specific_path}")
        seen_paths.add(specific_path)
        observed_keys.append(case_key)
        normalized_cases.append(
            {
                "task": index,
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

    if len(set(observed_keys)) != len(observed_keys):
        raise ManifestError("case keys are not unique")
    if schema == 1 and tuple(observed_keys) != CANONICAL_CASE_KEYS:
        raise ManifestError("case keys/order do not match the canonical pilot")
    if schema >= 2:
        if ensemble_kind == "pilot_7" and tuple(observed_keys) != (
            CANONICAL_CASE_KEYS
        ):
            raise ManifestError("schema 2 pilot_7 identities are not canonical")
        if ensemble_kind != "pilot_7" and identity_order != sorted(identity_order):
            raise ManifestError(
                "schema 2 subset/full cases are not in deterministic order"
            )
        if ensemble_kind == "full_1620" and tuple(observed_keys) != (
            FULL_ENSEMBLE_CASE_KEYS
        ):
            raise ManifestError(
                "full_1620 does not contain the exact canonical 1,620 cases"
            )
        if ensemble_kind == "phase1_2430" and tuple(observed_keys) != (
            PHASE1_ENSEMBLE_CASE_KEYS
        ):
            raise ManifestError(
                "phase1_2430 does not contain the exact canonical 2,430 cases"
            )
        observed_order_sha256 = case_order_sha256(observed_keys)
        if observed_order_sha256 != declared_order_sha256:
            raise ManifestError(
                "case_order_sha256 mismatch: expected "
                f"{declared_order_sha256}, observed {observed_order_sha256}"
            )

    workflow = normalize_workflow(data, schema, ensemble_kind, len(cases))

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
            case_path = Path(case["specific_path"])
            observed = sha256_file(case_path)
            if observed != case["specific_sha256"]:
                raise ManifestError(
                    f"{case['case_key']} specific MAT SHA-256 mismatch: "
                    f"expected {case['specific_sha256']}, observed {observed}"
                )
            observed_bytes = case_path.stat().st_size
            if observed_bytes != case["specific_bytes"]:
                raise ManifestError(
                    f"{case['case_key']} specific MAT byte-size mismatch: "
                    f"expected {case['specific_bytes']}, observed {observed_bytes}"
                )

    return {
        "schema_version": schema,
        "manifest_path": str(manifest_path),
        "manifest_companion_path": str(manifest_path) + ".sha256",
        "manifest_sha256": manifest_sha256,
        "campaign_id": campaign_id,
        "ensemble_kind": ensemble_kind,
        "case_order_sha256": case_order_sha256(observed_keys),
        "source_input_manifest_sha256": source_input_manifest_sha256,
        "mrst_prepare_commit": mrst_prepare_commit,
        "jutuldarcy_commit": jutuldarcy_commit,
        "jutul_manifest_sha256": jutul_manifest_sha256,
        "archive_root": archive_root,
        "common_path": str(common_path),
        "common_sha256": common_sha256,
        "common_bytes": common_bytes,
        "workflow": workflow,
        "cases": normalized_cases,
    }


def task_case(manifest: dict[str, Any], task: int) -> dict[str, Any]:
    if not 1 <= task <= len(manifest["cases"]):
        raise ManifestError(f"task must be in 1:{len(manifest['cases'])}")
    return manifest["cases"][task - 1]


def base_shell_values(manifest: dict[str, Any]) -> dict[str, Any]:
    workflow = manifest["workflow"]
    case_count = len(manifest["cases"])
    return {
        "GOM_PRODUCTION_SCHEMA_VERSION": manifest["schema_version"],
        "GOM_PRODUCTION_CAMPAIGN_ID": manifest["campaign_id"],
        "GOM_PRODUCTION_ENSEMBLE_KIND": manifest["ensemble_kind"],
        "GOM_PRODUCTION_MANIFEST_PATH": manifest["manifest_path"],
        "GOM_PRODUCTION_MANIFEST_COMPANION_PATH": (
            manifest["manifest_companion_path"]
        ),
        "GOM_PRODUCTION_MANIFEST_SHA256": manifest["manifest_sha256"],
        "GOM_PRODUCTION_CASE_ORDER_SHA256": manifest["case_order_sha256"],
        "GOM_PRODUCTION_ARCHIVE_ROOT": manifest["archive_root"],
        "GOM_PRODUCTION_SOURCE_INPUT_MANIFEST_SHA256": (
            manifest["source_input_manifest_sha256"]
        ),
        "GOM_PRODUCTION_MRST_PREPARE_COMMIT": manifest["mrst_prepare_commit"],
        "GOM_PRODUCTION_JUTULDARCY_COMMIT": manifest["jutuldarcy_commit"],
        "GOM_PRODUCTION_JUTUL_MANIFEST_SHA256": (
            manifest["jutul_manifest_sha256"]
        ),
        "GOM_PRODUCTION_CASE_COUNT": case_count,
        "GOM_PRODUCTION_PHYSICS_PROFILE": workflow["physics_profile"],
        "GOM_PRODUCTION_QOI_MODE": workflow["qoi_mode"],
        "GOM_PRODUCTION_QOI_SCHEMA_VERSION": workflow["qoi_schema_version"],
        "GOM_PRODUCTION_RETAIN_YEARS": ",".join(
            str(year) for year in workflow["retain_years"]
        ),
        "GOM_PRODUCTION_ROLLING_CHECKPOINTS": workflow[
            "rolling_checkpoints"
        ],
        "GOM_PRODUCTION_ARCHIVE_SHARD_SIZE": workflow["archive_shard_size"],
        "GOM_PRODUCTION_ARCHIVE_SHARD_COUNT": math.ceil(
            case_count / workflow["archive_shard_size"]
        ),
        "GOM_PRODUCTION_ARCHIVE_COMPACT_ATOMIC_ROWS": str(
            workflow["archive_compact_atomic_rows"]
        ).lower(),
        "GOM_PRODUCTION_ARCHIVE_REMOVE_VERIFIED_SCRATCH": str(
            workflow["archive_remove_verified_scratch"]
        ).lower(),
    }


def shell_lines(values: dict[str, Any]) -> str:
    return "\n".join(
        f"{key}={shlex.quote(str(value))}" for key, value in values.items()
    )


def shell_assignments(manifest: dict[str, Any], task: int) -> str:
    case = task_case(manifest, task)
    values = base_shell_values(manifest)
    values.update(
        {
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
    )
    return shell_lines(values)


def summary_values(manifest: dict[str, Any]) -> dict[str, Any]:
    values = base_shell_values(manifest)
    values["GOM_PRODUCTION_ARRAY_SPEC"] = f"1-{len(manifest['cases'])}"
    return values


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--json", action="store_true")
    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--task", type=int, required=True)
    resolve.add_argument("--format", choices=("shell", "json"), default="shell")
    summary = subparsers.add_parser("summary")
    summary.add_argument("--format", choices=("shell", "json"), default="shell")
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
                f"schema={manifest['schema_version']} "
                f"ensemble={manifest['ensemble_kind']} "
                f"cases={len(manifest['cases'])} "
                f"sha256={manifest['manifest_sha256']}"
            )
        return 0
    if arguments.command == "resolve":
        case = task_case(manifest, arguments.task)
        if arguments.format == "shell":
            print(shell_assignments(manifest, arguments.task))
        else:
            print(json.dumps(case, indent=2, sort_keys=True))
        return 0
    if arguments.command == "summary":
        values = summary_values(manifest)
        if arguments.format == "shell":
            print(shell_lines(values))
        else:
            print(json.dumps(values, indent=2, sort_keys=True))
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"MANIFEST_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
