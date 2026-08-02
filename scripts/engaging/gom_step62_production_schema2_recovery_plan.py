#!/usr/bin/env python3
"""Build and resolve immutable recovery plans for schema-2 Step62 runs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys
import tempfile
import tomllib
from typing import Any

from gom_step62_production_manifest import (
    ManifestError,
    load_and_validate,
    task_case,
)


SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
SAFE_ID_RE = re.compile(r"[a-z0-9][a-z0-9_.-]*")
TASK_SELECTOR_RE = re.compile(r"[0-9]+(?:-[0-9]+)?")
SOURCE_SHARD_FIELDS = [
    "shard_index",
    "task_start",
    "task_end",
    "mode",
    "preflight_job",
    "full_job",
    "vtu_job",
    "archive_job",
    "wave_gate_archive_job",
    "archive_path",
]


class RecoveryPlanError(RuntimeError):
    """Raised when recovery provenance or task coverage is unsafe."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def exact_file(name: str, label: str) -> Path:
    path = Path(name).expanduser().resolve(strict=True)
    if not path.is_file():
        raise RecoveryPlanError(f"{label} is not a file: {path}")
    return path


def parse_key_values(path: Path, label: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw.strip()
        if not line:
            continue
        if "=" not in line:
            raise RecoveryPlanError(f"{label} line {number} is not key=value")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise RecoveryPlanError(f"{label} has duplicate/empty key {key!r}")
        values[key] = value
    return values


def require_value(
    values: dict[str, str], key: str, expected: str, label: str
) -> None:
    observed = values.get(key)
    if observed != expected:
        raise RecoveryPlanError(
            f"{label}.{key} mismatch: expected {expected!r}, "
            f"observed {observed!r}"
        )


def require_integer(text: str, label: str, minimum: int = 0) -> int:
    if not re.fullmatch(r"[0-9]+", text):
        raise RecoveryPlanError(f"{label} must be an integer")
    value = int(text)
    if value < minimum:
        raise RecoveryPlanError(f"{label} must be at least {minimum}")
    return value


def require_job(text: str, label: str) -> int:
    return require_integer(text, label, minimum=1)


def parse_task_selector(selector: str, case_count: int) -> list[int]:
    if not selector or selector.strip() != selector:
        raise RecoveryPlanError("task selector must be nonempty without spaces")
    tasks: list[int] = []
    seen: set[int] = set()
    for token in selector.split(","):
        if TASK_SELECTOR_RE.fullmatch(token) is None:
            raise RecoveryPlanError(f"invalid task selector token: {token!r}")
        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start, end = int(start_text), int(end_text)
        else:
            start = end = int(token)
        if start < 1 or end < start or end > case_count:
            raise RecoveryPlanError(
                f"task selector range {start}-{end} is outside 1:{case_count}"
            )
        for task in range(start, end + 1):
            if task in seen:
                raise RecoveryPlanError(f"duplicate selected task: {task}")
            seen.add(task)
            tasks.append(task)
    if tasks != sorted(tasks):
        raise RecoveryPlanError("selected tasks must be in increasing order")
    return tasks


def compact_task_spec(tasks: list[int]) -> str:
    if not tasks:
        raise RecoveryPlanError("cannot compact an empty task set")
    tokens: list[str] = []
    start = previous = tasks[0]
    for task in tasks[1:]:
        if task == previous + 1:
            previous = task
            continue
        tokens.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = task
    tokens.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(tokens)


def parse_source_shards(path: Path) -> list[dict[str, Any]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != SOURCE_SHARD_FIELDS:
            raise RecoveryPlanError("source shard receipt has the wrong header")
        raw_rows = list(reader)
    if not raw_rows:
        raise RecoveryPlanError("source shard receipt is empty")
    rows: list[dict[str, Any]] = []
    previous_end: int | None = None
    for expected_index, row in enumerate(raw_rows, start=1):
        index = require_integer(row["shard_index"], "shard_index", 1)
        if index != expected_index:
            raise RecoveryPlanError("source shard indexes are not contiguous")
        start = require_integer(row["task_start"], "task_start", 1)
        end = require_integer(row["task_end"], "task_end", 1)
        if end < start:
            raise RecoveryPlanError("source shard task range is reversed")
        if previous_end is not None and start != previous_end + 1:
            raise RecoveryPlanError("source shard task coverage is not contiguous")
        mode = row["mode"]
        if mode not in ("new", "reused"):
            raise RecoveryPlanError(f"invalid source shard mode: {mode!r}")
        jobs: dict[str, int | None] = {}
        for key in ("preflight_job", "full_job", "vtu_job", "archive_job"):
            value = row[key]
            jobs[key] = None if value == "none" else require_job(value, key)
        if mode == "new" and any(value is None for value in jobs.values()):
            raise RecoveryPlanError("new source shard has a missing job ID")
        if mode == "reused" and any(value is not None for value in jobs.values()):
            raise RecoveryPlanError("reused source shard unexpectedly has job IDs")
        archive_path = str(Path(row["archive_path"]).expanduser().resolve())
        rows.append(
            {
                "index": index,
                "task_start": start,
                "task_end": end,
                "mode": mode,
                **jobs,
                "archive_path": archive_path,
            }
        )
        previous_end = end
    return rows


def find_shard(shards: list[dict[str, Any]], task: int) -> dict[str, Any]:
    matches = [
        shard
        for shard in shards
        if shard["task_start"] <= task <= shard["task_end"]
    ]
    if len(matches) != 1:
        raise RecoveryPlanError(f"task {task} is not in exactly one source shard")
    return matches[0]


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        temporary = Path(handle.name)
        handle.write(text)
        handle.flush()
    try:
        temporary.replace(path)
    finally:
        temporary.exists() and temporary.unlink()


def build_plan(arguments: argparse.Namespace) -> dict[str, Any]:
    manifest = load_and_validate(arguments.manifest, verify_files=False)
    if manifest["schema_version"] != 2:
        raise RecoveryPlanError("recovery requires manifest schema 2")
    if manifest["workflow"]["physics_profile"] != (
        "sandpc_effective_globalplateau_v1"
    ):
        raise RecoveryPlanError("unsupported recovery physics profile")
    if manifest["workflow"]["qoi_mode"] != "required":
        raise RecoveryPlanError("schema-2 recovery requires QoI mode required")
    if SAFE_ID_RE.fullmatch(arguments.recovery_id) is None:
        raise RecoveryPlanError("unsafe recovery ID")
    if COMMIT_RE.fullmatch(arguments.workflow_commit) is None:
        raise RecoveryPlanError("workflow commit must be a full SHA-1")

    receipt_path = exact_file(arguments.source_receipt, "source receipt")
    shards_path = exact_file(arguments.source_shards, "source shard receipt")
    receipt = parse_key_values(receipt_path, "source receipt")
    require_value(receipt, "status", "submitted", "source receipt")
    require_value(
        receipt, "campaign_id", manifest["campaign_id"], "source receipt"
    )
    require_value(
        receipt,
        "manifest_sha256",
        manifest["manifest_sha256"],
        "source receipt",
    )
    require_value(
        receipt,
        "case_order_sha256",
        manifest["case_order_sha256"],
        "source receipt",
    )
    require_value(
        receipt,
        "ensemble_kind",
        manifest["ensemble_kind"],
        "source receipt",
    )
    require_value(
        receipt,
        "physics_profile",
        manifest["workflow"]["physics_profile"],
        "source receipt",
    )
    require_value(
        receipt, "qoi_mode", manifest["workflow"]["qoi_mode"], "source receipt"
    )
    source_submission_id = receipt.get("submission_id", "")
    if SAFE_ID_RE.fullmatch(source_submission_id) is None:
        raise RecoveryPlanError("source receipt has an unsafe submission ID")
    selection_start = require_integer(
        receipt.get("selection_start", ""), "selection_start", 1
    )
    selection_end = require_integer(
        receipt.get("selection_end", ""), "selection_end", 1
    )
    if selection_end < selection_start:
        raise RecoveryPlanError("source selection is reversed")
    if selection_end > len(manifest["cases"]):
        raise RecoveryPlanError("source selection exceeds the campaign")
    require_value(
        receipt,
        "selection_count",
        str(selection_end - selection_start + 1),
        "source receipt",
    )
    require_value(
        receipt,
        "archive_shard_size",
        str(manifest["workflow"]["archive_shard_size"]),
        "source receipt",
    )
    source_check_job = require_job(
        receipt.get("campaign_check_job", ""), "campaign_check_job"
    )
    source_finalize_job = require_job(
        receipt.get("finalize_job", ""), "finalize_job"
    )

    source_shards = parse_source_shards(shards_path)
    if source_shards[0]["task_start"] != selection_start or (
        source_shards[-1]["task_end"] != selection_end
    ):
        raise RecoveryPlanError("source shard coverage differs from receipt")
    declared_shards = require_integer(
        receipt.get("shard_count", ""), "shard_count", 1
    )
    if len(source_shards) != declared_shards:
        raise RecoveryPlanError("source shard count differs from receipt")
    new_count = sum(shard["mode"] == "new" for shard in source_shards)
    reused_count = len(source_shards) - new_count
    require_value(
        receipt, "new_shard_count", str(new_count), "source receipt"
    )
    require_value(
        receipt, "reused_shard_count", str(reused_count), "source receipt"
    )

    selected_tasks = parse_task_selector(
        arguments.tasks, len(manifest["cases"])
    )
    if selected_tasks[0] < selection_start or selected_tasks[-1] > selection_end:
        raise RecoveryPlanError("selected tasks are outside source submission")
    affected_indexes = sorted(
        {find_shard(source_shards, task)["index"] for task in selected_tasks}
    )
    affected_shards = [source_shards[index - 1] for index in affected_indexes]
    for shard in affected_shards:
        if shard["mode"] != "new":
            raise RecoveryPlanError(
                "cannot recover a source shard already marked reused"
            )
        expected_size = shard["task_end"] - shard["task_start"] + 1
        if expected_size > manifest["workflow"]["archive_shard_size"]:
            raise RecoveryPlanError("source shard exceeds manifest shard size")
        expected_archive = (
            Path(manifest["archive_root"])
            / "campaigns"
            / manifest["campaign_id"]
            / "shards"
            / f"shard_{shard['task_start']:04d}_{shard['task_end']:04d}"
        ).resolve()
        if Path(shard["archive_path"]) != expected_archive:
            raise RecoveryPlanError("source shard archive path is not canonical")

    coverage_tasks = [
        task
        for shard in affected_shards
        for task in range(shard["task_start"], shard["task_end"] + 1)
    ]
    selected_cases = []
    for task in selected_tasks:
        case = task_case(manifest, task)
        shard = find_shard(affected_shards, task)
        selected_cases.append(
            {
                "task": task,
                "case_key": case["case_key"],
                "shard_index": shard["index"],
            }
        )

    simulation_repo = Path(arguments.simulation_repo).expanduser().resolve()
    output = Path(arguments.output).expanduser().resolve()
    if output.exists() or Path(str(output) + ".sha256").exists():
        raise RecoveryPlanError(f"refusing to overwrite recovery plan: {output}")

    lines = [
        "schema_version = 1",
        f"recovery_id = {toml_string(arguments.recovery_id)}",
        f"campaign_id = {toml_string(manifest['campaign_id'])}",
        f"campaign_manifest = {toml_string(manifest['manifest_path'])}",
        f"campaign_manifest_sha256 = {toml_string(manifest['manifest_sha256'])}",
        f"physics_profile = {toml_string(manifest['workflow']['physics_profile'])}",
        f"qoi_mode = {toml_string(manifest['workflow']['qoi_mode'])}",
        f"simulation_repo = {toml_string(str(simulation_repo))}",
        f"simulation_commit = {toml_string(manifest['jutuldarcy_commit'])}",
        f"workflow_commit = {toml_string(arguments.workflow_commit)}",
        f"source_submission_id = {toml_string(source_submission_id)}",
        f"source_receipt = {toml_string(str(receipt_path))}",
        f"source_receipt_sha256 = {toml_string(sha256_file(receipt_path))}",
        f"source_shards = {toml_string(str(shards_path))}",
        f"source_shards_sha256 = {toml_string(sha256_file(shards_path))}",
        f"source_campaign_check_job = {source_check_job}",
        f"source_finalize_job = {source_finalize_job}",
        f"source_selection_start = {selection_start}",
        f"source_selection_end = {selection_end}",
        f"selected_task_spec = {toml_string(compact_task_spec(selected_tasks))}",
        "selected_tasks = [" + ", ".join(map(str, selected_tasks)) + "]",
        f"coverage_task_spec = {toml_string(compact_task_spec(coverage_tasks))}",
        "coverage_tasks = [" + ", ".join(map(str, coverage_tasks)) + "]",
        f"selected_case_count = {len(selected_tasks)}",
        f"coverage_case_count = {len(coverage_tasks)}",
        f"affected_shard_count = {len(affected_shards)}",
    ]
    for shard in affected_shards:
        lines.extend(
            [
                "",
                "[[shards]]",
                f"source_index = {shard['index']}",
                f"task_start = {shard['task_start']}",
                f"task_end = {shard['task_end']}",
                f"source_preflight_job = {shard['preflight_job']}",
                f"source_full_job = {shard['full_job']}",
                f"source_vtu_job = {shard['vtu_job']}",
                f"source_archive_job = {shard['archive_job']}",
                f"archive_path = {toml_string(shard['archive_path'])}",
            ]
        )
    for case in selected_cases:
        lines.extend(
            [
                "",
                "[[selected_cases]]",
                f"task = {case['task']}",
                f"case_key = {toml_string(case['case_key'])}",
                f"source_shard_index = {case['shard_index']}",
            ]
        )
    atomic_write(output, "\n".join(lines) + "\n")
    digest = sha256_file(output)
    atomic_write(
        Path(str(output) + ".sha256"), f"{digest}  {output.name}\n"
    )
    return load_plan(str(output))


def require_plan_string(data: dict[str, Any], key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise RecoveryPlanError(f"plan.{key} must be a nonempty string")
    return value


def require_plan_integer(data: dict[str, Any], key: str, minimum: int = 1) -> int:
    value = data.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise RecoveryPlanError(f"plan.{key} must be an integer >= {minimum}")
    return value


def validate_companion(path: Path) -> str:
    companion = exact_file(str(path) + ".sha256", "plan companion")
    lines = companion.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1:
        raise RecoveryPlanError("plan companion must contain exactly one line")
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", lines[0])
    if match is None or match.group(2) != path.name:
        raise RecoveryPlanError("invalid plan companion")
    observed = sha256_file(path)
    if observed != match.group(1):
        raise RecoveryPlanError("recovery plan SHA-256 mismatch")
    return observed


def load_plan(name: str) -> dict[str, Any]:
    path = exact_file(name, "recovery plan")
    plan_sha = validate_companion(path)
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        raise RecoveryPlanError(f"invalid recovery plan TOML: {error}") from error
    if data.get("schema_version") != 1:
        raise RecoveryPlanError("recovery plan schema_version must be 1")
    recovery_id = require_plan_string(data, "recovery_id")
    if SAFE_ID_RE.fullmatch(recovery_id) is None:
        raise RecoveryPlanError("unsafe recovery plan ID")
    for key in (
        "campaign_manifest_sha256",
        "source_receipt_sha256",
        "source_shards_sha256",
    ):
        if SHA256_RE.fullmatch(require_plan_string(data, key)) is None:
            raise RecoveryPlanError(f"plan.{key} is not SHA-256")
    for key in ("simulation_commit", "workflow_commit"):
        if COMMIT_RE.fullmatch(require_plan_string(data, key)) is None:
            raise RecoveryPlanError(f"plan.{key} is not a full commit")

    manifest = load_and_validate(
        require_plan_string(data, "campaign_manifest"), verify_files=False
    )
    require_value(
        {"value": manifest["manifest_sha256"]},
        "value",
        data["campaign_manifest_sha256"],
        "campaign manifest",
    )
    if manifest["campaign_id"] != require_plan_string(data, "campaign_id"):
        raise RecoveryPlanError("plan campaign ID mismatch")
    if manifest["jutuldarcy_commit"] != data["simulation_commit"]:
        raise RecoveryPlanError("plan simulation commit mismatch")
    if manifest["workflow"]["physics_profile"] != data["physics_profile"]:
        raise RecoveryPlanError("plan physics profile mismatch")
    if manifest["workflow"]["qoi_mode"] != data["qoi_mode"]:
        raise RecoveryPlanError("plan QoI mode mismatch")
    if data["physics_profile"] != "sandpc_effective_globalplateau_v1":
        raise RecoveryPlanError("unsupported recovery plan physics profile")
    if data["qoi_mode"] != "required":
        raise RecoveryPlanError("recovery plan must require QoI output")

    require_plan_integer(data, "source_campaign_check_job")
    require_plan_integer(data, "source_finalize_job")
    source_start = require_plan_integer(data, "source_selection_start")
    source_end = require_plan_integer(data, "source_selection_end")
    if source_end < source_start or source_end > len(manifest["cases"]):
        raise RecoveryPlanError("plan source selection is invalid")

    receipt = exact_file(require_plan_string(data, "source_receipt"), "source receipt")
    shards_path = exact_file(require_plan_string(data, "source_shards"), "source shards")
    if sha256_file(receipt) != data["source_receipt_sha256"]:
        raise RecoveryPlanError("source receipt changed after plan creation")
    if sha256_file(shards_path) != data["source_shards_sha256"]:
        raise RecoveryPlanError("source shard receipt changed after plan creation")
    receipt_values = parse_key_values(receipt, "source receipt")
    require_value(receipt_values, "status", "submitted", "source receipt")
    require_value(
        receipt_values,
        "submission_id",
        require_plan_string(data, "source_submission_id"),
        "source receipt",
    )
    require_value(
        receipt_values,
        "campaign_id",
        manifest["campaign_id"],
        "source receipt",
    )
    require_value(
        receipt_values,
        "manifest_sha256",
        manifest["manifest_sha256"],
        "source receipt",
    )
    require_value(
        receipt_values,
        "case_order_sha256",
        manifest["case_order_sha256"],
        "source receipt",
    )
    require_value(
        receipt_values,
        "ensemble_kind",
        manifest["ensemble_kind"],
        "source receipt",
    )
    require_value(
        receipt_values,
        "campaign_check_job",
        str(data["source_campaign_check_job"]),
        "source receipt",
    )
    require_value(
        receipt_values,
        "finalize_job",
        str(data["source_finalize_job"]),
        "source receipt",
    )
    require_value(
        receipt_values,
        "selection_start",
        str(source_start),
        "source receipt",
    )
    require_value(
        receipt_values,
        "selection_end",
        str(source_end),
        "source receipt",
    )
    require_value(
        receipt_values,
        "selection_count",
        str(source_end - source_start + 1),
        "source receipt",
    )
    source_shards = parse_source_shards(shards_path)
    require_value(
        receipt_values,
        "shard_count",
        str(len(source_shards)),
        "source receipt",
    )
    if source_shards[0]["task_start"] != source_start or (
        source_shards[-1]["task_end"] != source_end
    ):
        raise RecoveryPlanError("source receipt and shard coverage differ")
    new_count = sum(shard["mode"] == "new" for shard in source_shards)
    reused_count = len(source_shards) - new_count
    require_value(
        receipt_values, "new_shard_count", str(new_count), "source receipt"
    )
    require_value(
        receipt_values,
        "reused_shard_count",
        str(reused_count),
        "source receipt",
    )

    selected_tasks = data.get("selected_tasks")
    coverage_tasks = data.get("coverage_tasks")
    if not isinstance(selected_tasks, list) or not selected_tasks:
        raise RecoveryPlanError("plan selected_tasks is empty")
    if not isinstance(coverage_tasks, list) or not coverage_tasks:
        raise RecoveryPlanError("plan coverage_tasks is empty")
    if any(isinstance(task, bool) or not isinstance(task, int) for task in selected_tasks):
        raise RecoveryPlanError("plan selected_tasks must contain integers")
    if any(isinstance(task, bool) or not isinstance(task, int) for task in coverage_tasks):
        raise RecoveryPlanError("plan coverage_tasks must contain integers")
    if selected_tasks != sorted(set(selected_tasks)):
        raise RecoveryPlanError("plan selected_tasks is not sorted and unique")
    if coverage_tasks != sorted(set(coverage_tasks)):
        raise RecoveryPlanError("plan coverage_tasks is not sorted and unique")
    if not set(selected_tasks).issubset(coverage_tasks):
        raise RecoveryPlanError("selected tasks are outside coverage")
    if selected_tasks[0] < source_start or selected_tasks[-1] > source_end:
        raise RecoveryPlanError("selected tasks are outside source selection")
    if coverage_tasks[0] < source_start or coverage_tasks[-1] > source_end:
        raise RecoveryPlanError("coverage tasks are outside source selection")
    if compact_task_spec(selected_tasks) != data["selected_task_spec"]:
        raise RecoveryPlanError("selected task spec mismatch")
    if compact_task_spec(coverage_tasks) != data["coverage_task_spec"]:
        raise RecoveryPlanError("coverage task spec mismatch")
    if require_plan_integer(data, "selected_case_count") != len(selected_tasks):
        raise RecoveryPlanError("selected case count mismatch")
    if require_plan_integer(data, "coverage_case_count") != len(coverage_tasks):
        raise RecoveryPlanError("coverage case count mismatch")

    shards = data.get("shards")
    if not isinstance(shards, list) or not shards:
        raise RecoveryPlanError("plan has no shards")
    if require_plan_integer(data, "affected_shard_count") != len(shards):
        raise RecoveryPlanError("affected shard count mismatch")
    observed_coverage: list[int] = []
    previous_end: int | None = None
    previous_source_index: int | None = None
    normalized_shards: list[dict[str, Any]] = []
    for shard in shards:
        if not isinstance(shard, dict):
            raise RecoveryPlanError("invalid plan shard")
        start = require_plan_integer(shard, "task_start")
        end = require_plan_integer(shard, "task_end")
        source_index = require_plan_integer(shard, "source_index")
        if end < start:
            raise RecoveryPlanError("plan shard range is reversed")
        if previous_end is not None and start <= previous_end:
            raise RecoveryPlanError("plan shard ranges overlap or are unsorted")
        previous_end = end
        if previous_source_index is not None and source_index <= previous_source_index:
            raise RecoveryPlanError("plan source shard indexes are not increasing")
        if source_index > len(source_shards):
            raise RecoveryPlanError("plan source shard index is out of range")
        previous_source_index = source_index
        for key in (
            "source_preflight_job",
            "source_full_job",
            "source_vtu_job",
            "source_archive_job",
        ):
            require_plan_integer(shard, key)
        archive_path = str(
            Path(require_plan_string(shard, "archive_path")).expanduser().resolve()
        )
        normalized = dict(shard)
        normalized["archive_path"] = archive_path
        source_shard = source_shards[source_index - 1]
        if source_shard["mode"] != "new":
            raise RecoveryPlanError("recovery plan references a reused shard")
        canonical_archive = (
            Path(manifest["archive_root"])
            / "campaigns"
            / manifest["campaign_id"]
            / "shards"
            / f"shard_{start:04d}_{end:04d}"
        ).resolve()
        if Path(archive_path) != canonical_archive:
            raise RecoveryPlanError("plan shard archive path is not canonical")
        expected_source = {
            "task_start": source_shard["task_start"],
            "task_end": source_shard["task_end"],
            "source_preflight_job": source_shard["preflight_job"],
            "source_full_job": source_shard["full_job"],
            "source_vtu_job": source_shard["vtu_job"],
            "source_archive_job": source_shard["archive_job"],
            "archive_path": source_shard["archive_path"],
        }
        for key, expected in expected_source.items():
            if normalized.get(key) != expected:
                raise RecoveryPlanError(
                    f"plan shard {source_index} differs from source receipt: {key}"
                )
        normalized_shards.append(normalized)
        observed_coverage.extend(range(start, end + 1))
    if observed_coverage != coverage_tasks:
        raise RecoveryPlanError("plan shard coverage mismatch")
    simulation_repo = str(
        Path(require_plan_string(data, "simulation_repo")).expanduser().resolve()
    )
    if simulation_repo != data["simulation_repo"]:
        raise RecoveryPlanError("plan simulation repository is not canonical")

    selected_cases = data.get("selected_cases")
    if not isinstance(selected_cases, list) or len(selected_cases) != len(selected_tasks):
        raise RecoveryPlanError("plan selected case rows mismatch")
    for expected_task, case_row in zip(selected_tasks, selected_cases):
        if not isinstance(case_row, dict) or case_row.get("task") != expected_task:
            raise RecoveryPlanError("plan selected case task mismatch")
        expected_case = task_case(manifest, expected_task)
        if case_row.get("case_key") != expected_case["case_key"]:
            raise RecoveryPlanError("plan selected case identity mismatch")
        shard = plan_shard({"shards": normalized_shards}, expected_task)
        if case_row.get("source_shard_index") != shard.get("source_index"):
            raise RecoveryPlanError("plan selected case shard identity mismatch")

    return {
        **data,
        "plan_path": str(path),
        "plan_companion_path": str(path) + ".sha256",
        "plan_sha256": plan_sha,
        "manifest": manifest,
        "shards": normalized_shards,
    }


def plan_shard(plan: dict[str, Any], task: int) -> dict[str, Any]:
    return find_shard(plan["shards"], task)


def shell_lines(values: dict[str, Any]) -> str:
    return "\n".join(
        f"{key}={shlex.quote(str(value))}" for key, value in values.items()
    )


def summary_values(plan: dict[str, Any]) -> dict[str, Any]:
    return {
        "GOM_RECOVERY_PLAN_PATH": plan["plan_path"],
        "GOM_RECOVERY_PLAN_COMPANION_PATH": plan["plan_companion_path"],
        "GOM_RECOVERY_PLAN_SHA256": plan["plan_sha256"],
        "GOM_RECOVERY_ID": plan["recovery_id"],
        "GOM_RECOVERY_CAMPAIGN_ID": plan["campaign_id"],
        "GOM_RECOVERY_CAMPAIGN_MANIFEST": plan["campaign_manifest"],
        "GOM_RECOVERY_CAMPAIGN_MANIFEST_SHA256": plan[
            "campaign_manifest_sha256"
        ],
        "GOM_RECOVERY_SIMULATION_REPO": plan["simulation_repo"],
        "GOM_RECOVERY_SIMULATION_COMMIT": plan["simulation_commit"],
        "GOM_RECOVERY_WORKFLOW_COMMIT": plan["workflow_commit"],
        "GOM_RECOVERY_SOURCE_SUBMISSION_ID": plan["source_submission_id"],
        "GOM_RECOVERY_SOURCE_RECEIPT": plan["source_receipt"],
        "GOM_RECOVERY_SOURCE_SHARDS": plan["source_shards"],
        "GOM_RECOVERY_SOURCE_CHECK_JOB": plan["source_campaign_check_job"],
        "GOM_RECOVERY_SOURCE_FINALIZE_JOB": plan["source_finalize_job"],
        "GOM_RECOVERY_SELECTED_TASK_SPEC": plan["selected_task_spec"],
        "GOM_RECOVERY_COVERAGE_TASK_SPEC": plan["coverage_task_spec"],
        "GOM_RECOVERY_SELECTED_CASE_COUNT": plan["selected_case_count"],
        "GOM_RECOVERY_COVERAGE_CASE_COUNT": plan["coverage_case_count"],
        "GOM_RECOVERY_AFFECTED_SHARD_COUNT": plan["affected_shard_count"],
    }


def resolve_values(plan: dict[str, Any], task: int) -> dict[str, Any]:
    if task not in plan["coverage_tasks"]:
        raise RecoveryPlanError(f"task {task} is outside recovery coverage")
    case = task_case(plan["manifest"], task)
    shard = plan_shard(plan, task)
    return {
        "GOM_RECOVERY_TASK": task,
        "GOM_RECOVERY_CASE_KEY": case["case_key"],
        "GOM_RECOVERY_TASK_SELECTED": str(task in plan["selected_tasks"]).lower(),
        "GOM_RECOVERY_SHARD_START": shard["task_start"],
        "GOM_RECOVERY_SHARD_END": shard["task_end"],
        "GOM_RECOVERY_SOURCE_PREFLIGHT_JOB": shard["source_preflight_job"],
        "GOM_RECOVERY_SOURCE_FULL_JOB": shard["source_full_job"],
        "GOM_RECOVERY_SOURCE_VTU_JOB": shard["source_vtu_job"],
        "GOM_RECOVERY_SOURCE_ARCHIVE_JOB": shard["source_archive_job"],
        "GOM_RECOVERY_ARCHIVE_PATH": shard["archive_path"],
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--manifest", required=True)
    build.add_argument("--source-receipt", required=True)
    build.add_argument("--source-shards", required=True)
    build.add_argument("--tasks", required=True)
    build.add_argument("--recovery-id", required=True)
    build.add_argument("--workflow-commit", required=True)
    build.add_argument("--simulation-repo", required=True)
    build.add_argument("--output", required=True)
    for command in ("validate", "summary", "resolve", "tasks", "shards"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--plan", required=True)
        if command == "summary":
            subparser.add_argument("--format", choices=("shell", "json"), default="shell")
        elif command == "resolve":
            subparser.add_argument("--task", type=int, required=True)
            subparser.add_argument("--format", choices=("shell", "json"), default="shell")
        elif command == "tasks":
            subparser.add_argument("--scope", choices=("selected", "coverage"), required=True)
        elif command == "shards":
            subparser.add_argument("--format", choices=("tsv", "json"), default="tsv")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "build":
        plan = build_plan(arguments)
        print(
            "RECOVERY_PLAN_CREATED "
            f"path={plan['plan_path']} "
            f"selected={plan['selected_case_count']} "
            f"coverage={plan['coverage_case_count']} "
            f"shards={plan['affected_shard_count']} "
            f"sha256={plan['plan_sha256']}"
        )
        return 0
    plan = load_plan(arguments.plan)
    if arguments.command == "validate":
        print(
            "RECOVERY_PLAN_VALID "
            f"id={plan['recovery_id']} "
            f"selected={plan['selected_case_count']} "
            f"coverage={plan['coverage_case_count']} "
            f"shards={plan['affected_shard_count']} "
            f"sha256={plan['plan_sha256']}"
        )
    elif arguments.command == "summary":
        values = summary_values(plan)
        print(
            shell_lines(values)
            if arguments.format == "shell"
            else json.dumps(values, indent=2, sort_keys=True)
        )
    elif arguments.command == "resolve":
        values = resolve_values(plan, arguments.task)
        print(
            shell_lines(values)
            if arguments.format == "shell"
            else json.dumps(values, indent=2, sort_keys=True)
        )
    elif arguments.command == "tasks":
        for task in plan[f"{arguments.scope}_tasks"]:
            print(task)
    elif arguments.command == "shards":
        if arguments.format == "json":
            print(json.dumps(plan["shards"], indent=2, sort_keys=True))
        else:
            print(
                "task_start\ttask_end\tsource_preflight_job\t"
                "source_full_job\tsource_vtu_job\tsource_archive_job\t"
                "archive_path"
            )
            for shard in plan["shards"]:
                print(
                    "\t".join(
                        str(shard[key])
                        for key in (
                            "task_start",
                            "task_end",
                            "source_preflight_job",
                            "source_full_job",
                            "source_vtu_job",
                            "source_archive_job",
                            "archive_path",
                        )
                    )
                )
    else:
        raise AssertionError(arguments.command)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ManifestError, OSError, ValueError, RecoveryPlanError) as error:
        print(f"RECOVERY_PLAN_ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
