#!/usr/bin/env python3.12
"""Build the immutable TOML contract for the Step62 seven-case pilot."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
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
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


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
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    derived_path = Path(arguments.derived_manifest).resolve(strict=True)
    output_path = Path(arguments.output)
    if output_path.exists() or Path(str(output_path) + ".sha256").exists():
        raise ValueError("refusing to replace an existing immutable manifest")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", arguments.campaign_id):
        raise ValueError("campaign ID contains unsafe characters")
    archive_root = Path(arguments.archive_root)
    if not archive_root.is_absolute():
        raise ValueError("archive root must be absolute")
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
    if [row["caseKey"] for row in case_rows] != list(CANONICAL_CASE_KEYS):
        raise ValueError("derived manifest case order/identity is not canonical")
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
        "schema_version = 1",
        f"campaign_id = {toml_string(arguments.campaign_id)}",
        f"archive_root = {toml_string(str(archive_root))}",
        f"source_input_manifest_sha256 = {toml_string(source_sha256)}",
        f"mrst_prepare_commit = {toml_string(mrst_prepare_commit)}",
        f"jutuldarcy_commit = {toml_string(jutuldarcy_commit)}",
        f"jutul_manifest_sha256 = "
        f"{toml_string(jutul_manifest_sha256)}",
        "",
        "[common]",
        f"path = {toml_string(str(common_path))}",
        f"sha256 = {toml_string(common_sha256)}",
        f"bytes = {common_bytes}",
    ]
    for task, (row, artifact) in enumerate(
        zip(case_rows, artifacts), start=1
    ):
        path, digest, byte_count = artifact
        realization_text = row["realizationId"].strip()
        realization = int(float(realization_text))
        if float(realization_text) != realization:
            raise ValueError(f"non-integral realization ID: {realization_text}")
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
