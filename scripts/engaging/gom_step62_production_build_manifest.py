#!/usr/bin/env python3.12
"""Build an immutable Step62 split-input campaign contract."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile


CANONICAL_CASE_KEYS = (
    "s05_c012_case01",
    "s05_c012_case03",
    "s05_c012_case04",
    "s05_c012_case07",
    "s03_c001_case04",
    "s03_c012_case08",
    "s04_c024_case03",
)
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
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
GEOLOGY_ID_RE = re.compile(r"^s(?P<scenario>\d{2})_c(?P<geology>\d{3})$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def require_digest(value: str, label: str) -> str:
    value = value.strip().lower()
    if not SHA256_RE.fullmatch(value):
        raise ValueError(f"{label} is not a SHA-256 digest")
    return value


def require_commit(value: str, label: str) -> str:
    value = value.strip().lower()
    if not GIT_COMMIT_RE.fullmatch(value):
        raise ValueError(f"{label} is not a full 40-character Git commit")
    return value


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.tmp."
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-manifest", required=True)
    parser.add_argument("--campaign-id", required=True)
    parser.add_argument("--archive-root", required=True)
    parser.add_argument("--jutuldarcy-commit", required=True)
    parser.add_argument("--jutul-manifest-sha256", required=True)
    parser.add_argument("--mrst-prepare-commit", required=True)
    parser.add_argument("--source-input-manifest-sha256", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--schema-version", type=int, choices=(1, 2, 3), default=1
    )
    parser.add_argument(
        "--ensemble-kind",
        choices=("pilot_7", "subset", "full_1620", "phase1_2430"),
    )
    parser.add_argument(
        "--qoi-mode", choices=("off", "auto", "required"), default="required"
    )
    parser.add_argument(
        "--physics-profile",
        choices=(
            "legacy_fault_plateau_npctheta30",
            "sandpc_effective_globalplateau_v1",
        ),
    )
    parser.add_argument("--archive-shard-size", type=int, default=50)
    return parser.parse_args()


def integral_realization(row: dict[str, str]) -> int:
    realization_text = row["realizationId"].strip()
    realization = int(float(realization_text))
    if float(realization_text) != realization:
        raise ValueError(f"non-integral realization ID: {realization_text}")
    return realization


def validate_case_identity(
    row: dict[str, str], ensemble_kind: str
) -> tuple[int, int, int]:
    geology_id = row["geologyId"].strip()
    match = GEOLOGY_ID_RE.fullmatch(geology_id)
    if match is None:
        raise ValueError(f"invalid geology ID: {geology_id!r}")
    scenario = int(match.group("scenario"))
    geology = int(match.group("geology"))
    realization = integral_realization(row)
    allowed_ids = PHASE1_CASE_IDS if ensemble_kind == "phase1_2430" else range(1, 11)
    if realization not in allowed_ids:
        allowed_text = (
            "1:12,101:103" if ensemble_kind == "phase1_2430" else "1:10"
        )
        raise ValueError(
            f"{row['caseKey']} realization ID must be in {allowed_text}"
        )
    expected_key = f"{geology_id}_case{realization:02d}"
    if row["caseKey"] != expected_key:
        raise ValueError(
            f"case key {row['caseKey']!r} does not match {expected_key!r}"
        )
    return scenario, geology, realization


def case_order_sha256(case_rows: list[dict[str, str]]) -> str:
    payload = "".join(
        f"{task}\t{row['caseKey']}\n"
        for task, row in enumerate(case_rows, start=1)
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def main() -> int:
    arguments = parse_arguments()
    derived_path = Path(arguments.derived_manifest).resolve(strict=True)
    output_path = Path(arguments.output)
    if output_path.exists() or Path(str(output_path) + ".sha256").exists():
        raise ValueError("refusing to replace an existing immutable manifest")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", arguments.campaign_id):
        raise ValueError("campaign ID contains unsafe characters")
    archive_root = PurePosixPath(arguments.archive_root)
    if not archive_root.is_absolute():
        raise ValueError("archive root must be absolute")
    if arguments.archive_shard_size <= 0:
        raise ValueError("archive shard size must be positive")
    jutuldarcy_commit = require_commit(
        arguments.jutuldarcy_commit, "JutulDarcy commit"
    )
    mrst_prepare_commit = require_commit(
        arguments.mrst_prepare_commit, "MRST prepare commit"
    )
    source_sha256 = require_digest(
        arguments.source_input_manifest_sha256,
        "source input manifest SHA-256",
    )
    jutul_manifest_sha256 = require_digest(
        arguments.jutul_manifest_sha256,
        "Jutul Manifest.toml SHA-256",
    )

    with derived_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required_columns = {
        "artifactKind",
        "caseKey",
        "relativePath",
        "sha256",
        "geologyId",
        "geologyHash",
        "realizationId",
        "level3CaseName",
        "inputManifestSha256",
    }
    if not rows or not required_columns.issubset(rows[0]):
        raise ValueError("derived manifest has an unexpected schema")

    common_rows = [row for row in rows if row["artifactKind"] == "common"]
    case_rows = [
        row for row in rows if row["artifactKind"] == "geology_specific"
    ]
    if len(common_rows) != 1:
        raise ValueError("derived manifest must contain exactly one common row")
    if arguments.schema_version == 1:
        if arguments.ensemble_kind not in (None, "pilot_7"):
            raise ValueError("schema 1 supports only ensemble-kind pilot_7")
        ensemble_kind = "pilot_7"
        if arguments.physics_profile not in (
            None,
            "legacy_fault_plateau_npctheta30",
        ):
            raise ValueError("schema 1 supports only the legacy physics profile")
        physics_profile = "legacy_fault_plateau_npctheta30"
    elif arguments.schema_version == 2:
        if arguments.ensemble_kind is None:
            raise ValueError("schema 2 requires --ensemble-kind")
        ensemble_kind = arguments.ensemble_kind
        if arguments.physics_profile is None:
            raise ValueError("schema 2 requires --physics-profile")
        physics_profile = arguments.physics_profile
    else:
        if arguments.ensemble_kind != "phase1_2430":
            raise ValueError("schema 3 requires --ensemble-kind phase1_2430")
        ensemble_kind = arguments.ensemble_kind
        if arguments.physics_profile != "sandpc_effective_globalplateau_v1":
            raise ValueError(
                "schema 3 requires sandpc_effective_globalplateau_v1"
            )
        if arguments.qoi_mode != "required":
            raise ValueError("schema 3 requires --qoi-mode required")
        physics_profile = arguments.physics_profile

    case_keys = [row["caseKey"] for row in case_rows]
    if ensemble_kind == "pilot_7":
        if case_keys != list(CANONICAL_CASE_KEYS):
            raise ValueError(
                "derived manifest case order/identity is not the canonical pilot"
            )
    else:
        order_keys = [
            validate_case_identity(row, ensemble_kind) for row in case_rows
        ]
        if len(set(case_keys)) != len(case_keys):
            raise ValueError("derived manifest contains duplicate case keys")
        if order_keys != sorted(order_keys):
            raise ValueError(
                "schema 2 subset/full cases must use deterministic "
                "scenario/geology/realization order"
            )
        if ensemble_kind == "full_1620" and tuple(case_keys) != (
            FULL_ENSEMBLE_CASE_KEYS
        ):
            raise ValueError(
                "full_1620 must contain exactly s01..s06, c001..c027, "
                "and case01..case10 in canonical order"
            )
        if ensemble_kind == "phase1_2430" and tuple(case_keys) != (
            PHASE1_ENSEMBLE_CASE_KEYS
        ):
            raise ValueError(
                "phase1_2430 must contain exactly s01..s06, c001..c027, "
                "and case01..case12,case101..case103 in canonical order"
            )
    if not case_rows:
        raise ValueError("derived manifest contains no geology-specific rows")
    if any(
        require_digest(row["inputManifestSha256"], "embedded source digest")
        != source_sha256
        for row in rows
    ):
        raise ValueError("derived manifest source digest does not match")

    root = derived_path.parent

    def resolve_artifact(row: dict[str, str]) -> tuple[Path, str, int]:
        relative = row["relativePath"].strip()
        if any(character in relative for character in "*?[]{}"):
            raise ValueError(f"artifact path contains a wildcard: {relative}")
        path = (root / relative).resolve(strict=True)
        path.relative_to(root)
        expected = require_digest(row["sha256"], f"{relative} SHA-256")
        observed = sha256_file(path)
        if observed != expected:
            raise ValueError(
                f"{relative} SHA-256 mismatch: expected {expected}, "
                f"observed {observed}"
            )
        return path, expected, path.stat().st_size

    common_path, common_sha256, common_bytes = resolve_artifact(common_rows[0])
    artifacts = [resolve_artifact(row) for row in case_rows]

    lines = [
        f"schema_version = {arguments.schema_version}",
        f"campaign_id = {toml_string(arguments.campaign_id)}",
        f"archive_root = {toml_string(str(archive_root))}",
        f"source_input_manifest_sha256 = {toml_string(source_sha256)}",
        f"mrst_prepare_commit = {toml_string(mrst_prepare_commit)}",
        f"jutuldarcy_commit = {toml_string(jutuldarcy_commit)}",
        f"jutul_manifest_sha256 = "
        f"{toml_string(jutul_manifest_sha256)}",
    ]
    if arguments.schema_version >= 2:
        lines.extend(
            [
                f"ensemble_kind = {toml_string(ensemble_kind)}",
                f"case_count = {len(case_rows)}",
                f"case_order_sha256 = "
                f"{toml_string(case_order_sha256(case_rows))}",
                "",
                "[workflow]",
                f"physics_profile = {toml_string(physics_profile)}",
                f"qoi_mode = {toml_string(arguments.qoi_mode)}",
                *(
                    ["qoi_schema_version = 4"]
                    if arguments.schema_version == 3
                    else []
                ),
                "retain_years = [25, 50, 100, 1000]",
                "rolling_checkpoints = 2",
                f"archive_shard_size = {arguments.archive_shard_size}",
                "archive_compact_atomic_rows = true",
                "archive_remove_verified_scratch = true",
            ]
        )
    lines.extend(
        [
            "",
            "[common]",
            f"path = {toml_string(str(common_path))}",
            f"sha256 = {toml_string(common_sha256)}",
            f"bytes = {common_bytes}",
        ]
    )
    for task, (row, artifact) in enumerate(
        zip(case_rows, artifacts), start=1
    ):
        path, digest, byte_count = artifact
        realization = integral_realization(row)
        geology_hash = require_digest(
            row["geologyHash"], f"{row['caseKey']} geology hash"
        )
        lines.extend(
            [
                "",
                "[[cases]]",
                f"task = {task}",
                f"case_key = {toml_string(row['caseKey'])}",
                f"geology_id = {toml_string(row['geologyId'])}",
                f"geology_hash = {toml_string(geology_hash)}",
                f"realization_id = {realization}",
                f"level3_case_name = "
                f"{toml_string(row['level3CaseName'])}",
                f"specific_path = {toml_string(str(path))}",
                f"specific_sha256 = {toml_string(digest)}",
                f"specific_bytes = {byte_count}",
            ]
        )
    manifest_text = "\n".join(lines) + "\n"
    atomic_write(output_path, manifest_text)
    manifest_sha256 = sha256_file(output_path)
    companion_path = Path(str(output_path) + ".sha256")
    atomic_write(
        companion_path,
        f"{manifest_sha256}  {output_path.name}\n",
    )
    print(
        "MANIFEST_CREATED "
        f"path={output_path} cases={len(case_rows)} sha256={manifest_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
