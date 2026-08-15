#!/usr/bin/env python3
"""Audit a completed Step-62 canary set and create an immutable evidence bundle.

The audit verifies campaign provenance, selected input hashes, preflight import
contracts, full-schedule outputs, restart and VTU checksums, schema-3/schema-4
QoI completeness, basic physical bounds, and early PREDICT-fault pressure
behavior. Simulation outputs are read-only; only the requested audit bundle is
created.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tomllib


EXPECTED_ROLES = {
    "heterogeneous_independent",
    "conduit_stress",
    "barrier_stress",
}
EXPECTED_RESTART_STEPS = (51, 78, 110, 210)
EXPECTED_RESTART_YEARS = (25.0, 50.0, 100.0, 1000.0)
EXPECTED_QOI_RECORD_COUNTS = {"global": 1, "region": 69, "interface": 193}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign", required=True, type=Path)
    parser.add_argument("--campaign-sha256", required=True)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--selection-sha256", required=True)
    parser.add_argument("--submission-receipt", required=True, type=Path)
    parser.add_argument("--code-repo", required=True, type=Path)
    parser.add_argument("--preflight-root", type=Path)
    parser.add_argument("--full-root", type=Path)
    parser.add_argument("--vtu-root", type=Path)
    parser.add_argument("--preflight-job")
    parser.add_argument("--smoke-job")
    parser.add_argument("--full-job")
    parser.add_argument("--vtu-job")
    parser.add_argument(
        "--source-map",
        type=Path,
        help=(
            "Optional task-indexed TSV containing preflight_root, full_root, "
            "vtu_root, and stage job IDs. This supports a reusable canary "
            "assembled from more than one dependency stage."
        ),
    )
    parser.add_argument("--expected-count", type=int, default=3)
    parser.add_argument(
        "--required-roles",
        default=",".join(sorted(EXPECTED_ROLES)),
        help="Comma-separated roles that must occur in the selection.",
    )
    parser.add_argument(
        "--production-reusable",
        action="store_true",
        help="Mark a passing audit as eligible for immutable production promotion.",
    )
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--first-hour-predict-pressure-rms-limit-pa",
        type=float,
        default=1.0e4,
        help="Acceptance ceiling for the PREDICT-fault PV-weighted RMS pressure change.",
    )
    parser.add_argument(
        "--final-mass-balance-relative-limit",
        type=float,
        default=1.0e-3,
    )
    return parser.parse_args()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(8 * 1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def parse_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def load_source_map(
    args: argparse.Namespace, selection: list[dict[str, str]]
) -> tuple[dict[int, dict[str, str]], list[str]]:
    """Resolve one output-root/job mapping for every selected campaign task."""

    if args.source_map is not None:
        rows = read_tsv(args.source_map)
        required = {
            "task",
            "preflight_root",
            "full_root",
            "vtu_root",
            "preflight_job",
            "full_job",
            "vtu_job",
        }
        if not rows or not required.issubset(rows[0]):
            raise RuntimeError("source map has an unexpected schema")
        mapping: dict[int, dict[str, str]] = {}
        for row in rows:
            task = int(row["task"])
            if task in mapping:
                raise RuntimeError(f"source map contains duplicate task {task}")
            for field in ("preflight_job", "full_job", "vtu_job"):
                if not row[field].isdigit():
                    raise RuntimeError(f"source map {field} is not numeric for task {task}")
            mapping[task] = row
        selected_tasks = {int(row["task"]) for row in selection}
        if set(mapping) != selected_tasks:
            raise RuntimeError("source-map tasks do not exactly match the selection")
        jobs = sorted(
            {
                row[field]
                for row in rows
                for field in ("preflight_job", "full_job", "vtu_job")
            },
            key=int,
        )
        return mapping, jobs

    required_values = (
        args.preflight_root,
        args.full_root,
        args.vtu_root,
        args.preflight_job,
        args.full_job,
        args.vtu_job,
    )
    if any(value is None for value in required_values):
        raise RuntimeError(
            "provide --source-map or all legacy output roots and job IDs"
        )
    mapping = {
        int(row["task"]): {
            "task": row["task"],
            "preflight_root": str(args.preflight_root),
            "full_root": str(args.full_root),
            "vtu_root": str(args.vtu_root),
            "preflight_job": str(args.preflight_job),
            "full_job": str(args.full_job),
            "vtu_job": str(args.vtu_job),
        }
        for row in selection
    }
    jobs = [str(args.preflight_job), str(args.full_job), str(args.vtu_job)]
    if args.smoke_job is not None:
        jobs.append(str(args.smoke_job))
    return mapping, sorted(set(jobs), key=int)


def as_float(value: str) -> float:
    return float(value)


def finite(value: str) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def is_true(value: str) -> bool:
    return value.strip().lower() == "true"


def ensure_file(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def verify_sha_manifest(root: Path, manifest: Path) -> tuple[bool, str]:
    checked = 0
    total_bytes = 0
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        expected, relative = raw.split(None, 1)
        target = root / relative.strip()
        if not ensure_file(target):
            return False, f"missing or empty {target}"
        actual = sha256_file(target)
        if actual != expected:
            return False, f"checksum mismatch for {target}"
        checked += 1
        total_bytes += target.stat().st_size
    return True, f"{checked} files, {total_bytes} bytes"


class Audit:
    """Collect individual checks while allowing every case to be inspected."""

    def __init__(self) -> None:
        self.rows: list[dict[str, str]] = []
        self.failures: list[str] = []

    def check(self, scope: str, category: str, name: str, passed: bool, detail: str) -> None:
        status = "pass" if passed else "fail"
        self.rows.append(
            {
                "scope": scope,
                "category": category,
                "check": name,
                "status": status,
                "detail": detail,
            }
        )
        if not passed:
            self.failures.append(f"{scope}: {name}: {detail}")


def copy_evidence(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def find_full_case(root: Path, case_key: str, full_job: str, task: str) -> Path:
    matches = sorted(root.glob(f"*_{case_key}_*_job{full_job}_{task}"))
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one full-run directory for {case_key}, found {len(matches)}"
        )
    return matches[0]


def write_tsv(path: Path, rows: list[dict[str, object]], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, delimiter="\t", fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def scan_schema3_rows(
    audit: Audit,
    scope: str,
    qoi_rows_dir: Path,
    case_key: str,
    campaign_sha: str,
) -> dict[str, float]:
    first_predict: dict[str, str] | None = None
    previous_time = -math.inf
    saturation_fields = (
        "gas_saturation_mean",
        "gas_saturation_pv_weighted_mean",
        "gas_saturation_max",
        "historical_gas_saturation_max",
        "active_gas_critical_saturation_pv_weighted_mean",
        "active_gas_critical_saturation_max",
    )
    mass_fields = (
        "free_co2_mass_kg",
        "mobile_free_co2_mass_kg",
        "immobile_free_co2_mass_kg",
        "drainage_critical_immobile_free_co2_mass_kg",
        "residual_trapped_co2_mass_kg",
        "hysteresis_incremental_trapped_co2_mass_kg",
        "dissolved_co2_mass_kg",
        "total_co2_mass_kg",
    )
    all_ok = True
    detail = ""
    for step in range(1, 211):
        path = qoi_rows_dir / f"step_{step:06d}.tsv"
        if not ensure_file(path):
            all_ok = False
            detail = f"missing {path.name}"
            break
        rows = read_tsv(path)
        counts = {key: 0 for key in EXPECTED_QOI_RECORD_COUNTS}
        for row in rows:
            record_type = row["record_type"]
            if record_type in counts:
                counts[record_type] += 1
            if row["case_key"] != case_key or row["campaign_manifest_sha256"] != campaign_sha:
                all_ok = False
                detail = f"identity mismatch in {path.name}"
                break
            if int(row["step"]) != step:
                all_ok = False
                detail = f"step mismatch in {path.name}"
                break
            if record_type == "region":
                for field in saturation_fields:
                    value = row[field]
                    if value and value.lower() != "nan":
                        number = float(value)
                        if not math.isfinite(number) or number < -1.0e-12 or number > 1.0 + 1.0e-12:
                            all_ok = False
                            detail = f"invalid {field} in {path.name}"
                            break
                for field in mass_fields:
                    value = row[field]
                    if value and value.lower() != "nan" and float(value) < -1.0e-6:
                        all_ok = False
                        detail = f"negative {field} in {path.name}"
                        break
                if row["region_id"] == "fault_predict_all" and step == 1:
                    first_predict = row
            elif record_type == "interface":
                for field in (
                    "free_co2_forward_rate_kg_s",
                    "free_co2_reverse_rate_kg_s",
                    "dissolved_co2_forward_rate_kg_s",
                    "dissolved_co2_reverse_rate_kg_s",
                    "total_co2_forward_rate_kg_s",
                    "total_co2_reverse_rate_kg_s",
                ):
                    if not finite(row[field]) or float(row[field]) < -1.0e-12:
                        all_ok = False
                        detail = f"invalid {field} in {path.name}"
                        break
            if not all_ok:
                break
        if not all_ok:
            break
        if counts != EXPECTED_QOI_RECORD_COUNTS:
            all_ok = False
            detail = f"record counts {counts} in {path.name}"
            break
        current_time = float(rows[0]["time_seconds"])
        if not current_time > previous_time:
            all_ok = False
            detail = f"non-increasing time in {path.name}"
            break
        previous_time = current_time
    audit.check(
        scope,
        "qoi_schema3",
        "all_210_qoi_files_complete_and_bounded",
        all_ok,
        detail or "210 files; each has 1 global, 69 region, and 193 interface records",
    )
    if first_predict is None:
        audit.check(scope, "initialization", "first_hour_predict_fault_record", False, "record missing")
        return {}
    metrics = {
        "first_hour_predict_pressure_mean_pa": float(first_predict["pressure_change_mean_pa"]),
        "first_hour_predict_pressure_pv_mean_pa": float(
            first_predict["pressure_change_pv_weighted_mean_pa"]
        ),
        "first_hour_predict_pressure_pv_rms_pa": float(
            first_predict["pressure_change_pv_weighted_rms_pa"]
        ),
        "first_hour_predict_pressure_abs_max_pa": float(first_predict["pressure_change_abs_max_pa"]),
    }
    audit.check(
        scope,
        "initialization",
        "first_hour_predict_fault_record",
        True,
        "fault_predict_all found at step 1",
    )
    return metrics


def scan_schema4(
    audit: Audit,
    scope: str,
    schema4_dir: Path,
    case_key: str,
    campaign_sha: str,
    final_mass_limit: float,
) -> dict[str, float]:
    complete_path = schema4_dir / "QOI_SCHEMA4_COMPLETE.tsv"
    rows_path = schema4_dir / "qoi_schema4_steps.tsv"
    spatial_index_path = schema4_dir / "spatial_history_index.tsv"
    if not all(ensure_file(path) for path in (complete_path, rows_path, spatial_index_path)):
        audit.check(scope, "qoi_schema4", "completion_files", False, "one or more files missing")
        return {}
    complete = read_tsv(complete_path)[0]
    rows = read_tsv(rows_path)
    spatial_index = read_tsv(spatial_index_path)
    audit.check(
        scope,
        "qoi_schema4",
        "completion_marker",
        complete["status"] == "complete"
        and complete["case_key"] == case_key
        and complete["schedule_steps"] == "210"
        and is_true(complete["storage_budget_passed"]),
        f"status={complete['status']}; steps={complete['schedule_steps']}; storage_budget={complete['storage_budget_passed']}",
    )
    identity_ok = len(rows) == 210 and len(spatial_index) == 210
    previous_time = -math.inf
    max_scaled_mass_residual = 0.0
    final_injected = float(rows[-1]["cumulative_injected_co2_kg"]) if rows else math.nan
    spatial_ok = True
    spatial_detail = ""
    required_finite = (
        "accepted_ministep_count",
        "accepted_seconds",
        "actual_co2_rate_kg_s",
        "total_well_mass_rate_kg_s",
        "injector_bhp_pa",
        "cumulative_injected_co2_kg",
        "cumulative_produced_co2_kg",
        "cumulative_boundary_out_co2_kg",
        "cumulative_boundary_in_co2_kg",
        "domain_co2_mass_kg",
        "expected_domain_co2_mass_kg",
        "mass_balance_residual_kg",
        "mass_balance_relative_residual",
    )
    for index, row in enumerate(rows, start=1):
        if (
            row["schema_version"] != "4"
            or row["base_qoi_schema_version"] != "3"
            or row["case_key"] != case_key
            or row["campaign_manifest_sha256"] != campaign_sha
            or int(row["step"]) != index
        ):
            identity_ok = False
            break
        time_seconds = float(row["time_seconds"])
        if time_seconds <= previous_time or any(not finite(row[field]) for field in required_finite):
            identity_ok = False
            break
        previous_time = time_seconds
        for field in (
            "cumulative_injected_co2_kg",
            "cumulative_produced_co2_kg",
            "cumulative_boundary_out_co2_kg",
            "cumulative_boundary_in_co2_kg",
            "domain_co2_mass_kg",
            "expected_domain_co2_mass_kg",
        ):
            if float(row[field]) < -1.0e-6:
                identity_ok = False
                break
        if not identity_ok:
            break
        if math.isfinite(final_injected) and final_injected > 0.0:
            max_scaled_mass_residual = max(
                max_scaled_mass_residual,
                abs(float(row["mass_balance_residual_kg"])) / final_injected,
            )
        binary_path = schema4_dir / "spatial_rows" / row["spatial_binary_file"]
        expected_bytes = int(row["spatial_binary_bytes"])
        if (
            not ensure_file(binary_path)
            or binary_path.stat().st_size != expected_bytes
            or sha256_file(binary_path) != row["spatial_binary_sha256"]
        ):
            spatial_ok = False
            spatial_detail = f"invalid spatial payload at step {index}"
            break
    final_years = float(rows[-1]["time_years"]) if rows else math.nan
    audit.check(
        scope,
        "qoi_schema4",
        "all_210_scalar_rows_complete",
        identity_ok and abs(final_years - 1000.0) < 1.0e-8,
        f"rows={len(rows)}; final_years={final_years:.12g}",
    )
    audit.check(
        scope,
        "qoi_schema4",
        "all_210_spatial_payloads_match_size_and_sha256",
        spatial_ok and len(spatial_index) == 210,
        spatial_detail or f"rows={len(spatial_index)}; bytes={complete['total_spatial_bytes']}",
    )
    final_relative = abs(float(rows[-1]["mass_balance_relative_residual"])) if rows else math.inf
    audit.check(
        scope,
        "mass_balance",
        "final_relative_residual",
        final_relative <= final_mass_limit,
        f"abs(relative residual)={final_relative:.6g}; limit={final_mass_limit:.6g}",
    )
    audit.check(
        scope,
        "mass_balance",
        "maximum_residual_scaled_by_final_injected_mass",
        max_scaled_mass_residual <= final_mass_limit,
        f"maximum={max_scaled_mass_residual:.6g}; limit={final_mass_limit:.6g}",
    )
    return {
        "final_mass_balance_relative_residual": final_relative,
        "max_mass_residual_over_final_injected": max_scaled_mass_residual,
        "final_cumulative_injected_co2_kg": final_injected,
        "schema4_accepted_ministeps": float(complete["accepted_ministep_count"]),
        "schema4_spatial_bytes": float(complete["total_spatial_bytes"]),
    }


def git_head(repo: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()


def capture_slurm(path: Path, job_ids: list[str]) -> None:
    command = [
        "sacct",
        "-X",
        "-j",
        ",".join(job_ids),
        "-o",
        "JobIDRaw,JobName%36,State,ExitCode,Elapsed,MaxRSS,AllocCPUS,NodeList",
    ]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    path.write_text(result.stdout, encoding="utf-8")


def main() -> int:
    args = parse_args()
    audit = Audit()
    final_dir = args.output_dir.resolve()
    if final_dir.exists():
        raise RuntimeError(f"refusing to overwrite existing audit bundle: {final_dir}")
    incoming = final_dir.parent / f".{final_dir.name}.incoming-{os.getpid()}"
    if incoming.exists():
        raise RuntimeError(f"staging directory already exists: {incoming}")
    incoming.mkdir(parents=True)

    campaign_sha = sha256_file(args.campaign)
    selection_sha = sha256_file(args.selection)
    audit.check("campaign", "provenance", "campaign_sha256", campaign_sha == args.campaign_sha256, campaign_sha)
    audit.check("campaign", "provenance", "selection_sha256", selection_sha == args.selection_sha256, selection_sha)
    with args.campaign.open("rb") as stream:
        campaign = tomllib.load(stream)
    audit.check("campaign", "configuration", "schema_version", campaign.get("schema_version") == 3, str(campaign.get("schema_version")))
    audit.check("campaign", "configuration", "ensemble_kind", campaign.get("ensemble_kind") == "phase1_2430", str(campaign.get("ensemble_kind")))
    audit.check("campaign", "configuration", "case_count", campaign.get("case_count") == 2430, str(campaign.get("case_count")))
    workflow = campaign.get("workflow", {})
    audit.check("campaign", "configuration", "qoi_schema_version", workflow.get("qoi_schema_version") == 4, str(workflow.get("qoi_schema_version")))
    audit.check("campaign", "configuration", "retained_years", tuple(float(x) for x in workflow.get("retain_years", [])) == EXPECTED_RESTART_YEARS, str(workflow.get("retain_years")))
    expected_commit = campaign["jutuldarcy_commit"]
    actual_commit = git_head(args.code_repo)
    audit.check("campaign", "provenance", "simulation_code_commit", actual_commit == expected_commit, actual_commit)

    common = campaign["common"]
    common_path = Path(common["path"])
    common_ok = (
        ensure_file(common_path)
        and common_path.stat().st_size == int(common["bytes"])
        and sha256_file(common_path) == common["sha256"]
    )
    audit.check("campaign", "inputs", "common_mat_size_and_sha256", common_ok, str(common_path))

    selection = read_tsv(args.selection)
    roles = {row["acceptance_role"] for row in selection}
    # The pipe delimiter is safe inside Slurm's comma-delimited --export list;
    # retain comma support for direct and historical command-line invocations.
    required_roles = {
        role.strip()
        for group in args.required_roles.split("|")
        for role in group.split(",")
        if role.strip()
    }
    audit.check(
        "campaign",
        "selection",
        "expected_case_count",
        len(selection) == args.expected_count,
        f"observed={len(selection)}; expected={args.expected_count}",
    )
    audit.check(
        "campaign",
        "selection",
        "required_acceptance_roles",
        required_roles.issubset(roles),
        f"required={','.join(sorted(required_roles))}; observed={','.join(sorted(roles))}",
    )
    source_map, source_jobs = load_source_map(args, selection)
    cases_by_task = {int(case["task"]): case for case in campaign["cases"]}
    case_metrics: list[dict[str, object]] = []
    acceptance_rows: list[dict[str, object]] = []

    for selected in selection:
        task = int(selected["task"])
        task_text = str(task)
        case_key = selected["case_key"]
        scope = case_key
        expected = cases_by_task.get(task)
        audit.check(scope, "pairing", "task_exists_in_campaign", expected is not None, f"task={task}")
        if expected is None:
            continue
        pairing_ok = (
            expected["case_key"] == case_key
            and expected["geology_id"] == selected["geology_id"]
            and int(expected["realization_id"]) == int(selected["realization_id"])
            and expected["level3_case_name"] == selected["case_name"]
        )
        audit.check(scope, "pairing", "selection_matches_campaign", pairing_ok, f"task={task}; geology={expected['geology_id']}; realization={expected['realization_id']}")
        specific_path = Path(expected["specific_path"])
        specific_ok = (
            ensure_file(specific_path)
            and specific_path.stat().st_size == int(expected["specific_bytes"])
            and sha256_file(specific_path) == expected["specific_sha256"]
        )
        audit.check(scope, "inputs", "specific_mat_size_and_sha256", specific_ok, str(specific_path))

        source = source_map[task]
        preflight_dir = Path(source["preflight_root"]) / case_key
        try:
            full_dir = find_full_case(
                Path(source["full_root"]),
                case_key,
                source["full_job"],
                task_text,
            )
        except RuntimeError as error:
            audit.check(scope, "outputs", "full_run_directory", False, str(error))
            continue
        vtu_dir = Path(source["vtu_root"]) / case_key
        preflight_summary_path = preflight_dir / "preflight_summary.txt"
        production_summary_path = full_dir / "production_summary.txt"
        final_summary_path = full_dir / "final_state_summary.txt"
        required_files = (
            preflight_dir / "PASS",
            preflight_summary_path,
            full_dir / "PASS",
            production_summary_path,
            final_summary_path,
            full_dir / "runtime_diagnostics.txt",
            vtu_dir / "PASS",
            vtu_dir / "export_summary.txt",
        )
        files_ok = all(ensure_file(path) for path in required_files)
        audit.check(scope, "outputs", "pass_markers_and_summaries", files_ok, f"preflight={preflight_dir}; full={full_dir}; vtu={vtu_dir}")
        if not files_ok:
            continue

        preflight = parse_key_values(preflight_summary_path)
        production = parse_key_values(production_summary_path)
        final = parse_key_values(final_summary_path)
        export = parse_key_values(vtu_dir / "export_summary.txt")
        preflight_ok = (
            preflight.get("status") == "pass"
            and preflight.get("case_key") == case_key
            and preflight.get("campaign_manifest_sha256") == campaign_sha
            and preflight.get("geology_id") == selected["geology_id"]
            and preflight.get("geology_hash") == expected["geology_hash"]
            and int(preflight.get("realization_id", "-1")) == int(selected["realization_id"])
            and preflight.get("level3_case_name") == selected["case_name"]
        )
        audit.check(scope, "preflight", "identity_and_geology_pairing", preflight_ok, f"geology_hash={preflight.get('geology_hash')}")
        geometry_ok = (
            preflight.get("resolution_slices") == "87"
            and preflight.get("fault_cells") == "32190"
            and preflight.get("explicit_predict_regions") == "522"
            and preflight.get("drainage_saturation_regions") == "530"
            and preflight.get("total_sgof_tables") == "1060"
        )
        audit.check(scope, "preflight", "six_by_87_fault_coverage", geometry_ok, f"slices={preflight.get('resolution_slices')}; regions={preflight.get('explicit_predict_regions')}")
        import_ok = (
            preflight.get("schema") == "gom_jutul_split_specific_v4"
            and preflight.get("initial_pressure_convention") == "liquid_reference"
            and float(preflight.get("initial_pressure_max_abs_difference_from_common_pa", "inf")) == 0.0
            and is_true(preflight.get("hysteresis_active", "false"))
            and float(preflight.get("permeability_tensor_min_determinant", "nan")) > 0.0
            and float(preflight.get("transmissibility_min", "nan")) > 0.0
            and preflight.get("schedule_steps") == "210"
            and abs(float(preflight.get("schedule_end_years", "nan")) - 1000.0) < 1.0e-8
        )
        audit.check(scope, "preflight", "corrected_import_and_physics_contract", import_ok, f"schema={preflight.get('schema')}; min_det={preflight.get('permeability_tensor_min_determinant')}; initial_dp={preflight.get('initial_pressure_max_abs_difference_from_common_pa')} Pa")

        production_ok = (
            production.get("status") == "pass"
            and production.get("case_key") == case_key
            and production.get("geology_id") == selected["geology_id"]
            and int(production.get("realization_id", "-1")) == int(selected["realization_id"])
            and production.get("campaign_manifest_sha256") == campaign_sha
            and production.get("steps_completed") == "210"
            and production.get("summary_rows") == "210"
            and production.get("qoi_global_rows") == "210"
            and production.get("qoi_region_rows") == "14490"
            and production.get("qoi_interface_rows") == "40530"
            and production.get("retained_restart_steps") == "51,78,110,210"
            and production.get("schedule_end_years") == "1000"
            and is_true(production.get("pc_kr_unchanged", "false"))
            and is_true(production.get("pc_at_and_above_entry_unchanged", "false"))
            and is_true(production.get("base_imbibition_unchanged", "false"))
        )
        audit.check(scope, "simulation", "full_1000_year_completion", production_ok, f"steps={production.get('steps_completed')}; qoi_regions={production.get('qoi_region_rows')}; qoi_interfaces={production.get('qoi_interface_rows')}")
        final_ok = (
            final.get("status") == "pass"
            and final.get("case_key") == case_key
            and final.get("campaign_manifest_sha256") == campaign_sha
            and final.get("report_steps") == "210"
            and final.get("qoi_schema4_version") == "4"
            and is_true(final.get("qoi_schema4_validated", "false"))
            and 0.0 <= float(final.get("final_gas_saturation_min", "nan")) <= 1.0
            and 0.0 <= float(final.get("final_gas_saturation_max", "nan")) <= 1.0
            and 0.0 <= float(final.get("final_maximum_historical_gas_saturation", "nan")) <= 1.0
            and float(final.get("final_pressure_min_Pa", "nan")) > 0.0
            and float(final.get("final_pressure_max_Pa", "nan")) > 0.0
            and float(final.get("final_rs_min", "nan")) >= 0.0
            and float(final.get("final_rs_max", "nan")) >= 0.0
        )
        audit.check(scope, "simulation", "final_state_physical_bounds", final_ok, f"pressure=[{final.get('final_pressure_min_Pa')},{final.get('final_pressure_max_Pa')}]; Sg=[{final.get('final_gas_saturation_min')},{final.get('final_gas_saturation_max')}]; Rs=[{final.get('final_rs_min')},{final.get('final_rs_max')}]")

        restart_ok, restart_detail = verify_sha_manifest(full_dir, full_dir / "RETAINED_RESTART_SHA256.txt")
        restart_manifest = read_tsv(full_dir / "RESTART_MANIFEST.tsv")
        restart_steps = tuple(int(Path(row["file"]).stem.split("_")[-1]) for row in restart_manifest)
        restart_sizes_ok = all((full_dir / "restart" / row["file"]).stat().st_size == int(row["bytes"]) for row in restart_manifest)
        audit.check(scope, "restart", "retained_restart_size_and_sha256", restart_ok and restart_sizes_ok and restart_steps == EXPECTED_RESTART_STEPS, f"steps={restart_steps}; {restart_detail}")
        summary_ok, summary_detail = verify_sha_manifest(full_dir, full_dir / "PRODUCTION_SUMMARY_SHA256.txt")
        audit.check(scope, "outputs", "production_summary_checksums", summary_ok, summary_detail)
        vtu_ok, vtu_detail = verify_sha_manifest(vtu_dir, vtu_dir / "VTU_SHA256.txt")
        export_ok = (
            export.get("status") == "pass"
            and export.get("case_id") == case_key
            and export.get("vtu_files") == "3"
            and export.get("pvd_files") == "1"
            and export.get("initial_state") == "true"
            and export.get("selected_steps") == "78,210"
            and export.get("cells_per_vtu") == "2165082"
        )
        audit.check(scope, "visualization", "vtu_export_and_checksums", vtu_ok and export_ok, f"{vtu_detail}; steps={export.get('selected_steps')}")

        schema3_metrics = scan_schema3_rows(
            audit,
            scope,
            full_dir / "restart" / "production_output" / "qoi" / "rows",
            case_key,
            campaign_sha,
        )
        pressure_rms = schema3_metrics.get("first_hour_predict_pressure_pv_rms_pa", math.inf)
        audit.check(scope, "initialization", "first_hour_predict_fault_pressure_rms", pressure_rms <= args.first_hour_predict_pressure_rms_limit_pa, f"RMS={pressure_rms:.6g} Pa; limit={args.first_hour_predict_pressure_rms_limit_pa:.6g} Pa")
        schema4_metrics = scan_schema4(
            audit,
            scope,
            full_dir / "restart" / "production_output" / "qoi_schema4",
            case_key,
            campaign_sha,
            args.final_mass_balance_relative_limit,
        )
        accepted = int(float(schema4_metrics.get("schema4_accepted_ministeps", -1)))
        expected_accepted = int(production["total_ministeps"]) - int(production["rejected_or_cut_ministeps"])
        audit.check(scope, "solver", "accepted_ministep_accounting", accepted == expected_accepted, f"schema4={accepted}; total-rejected={expected_accepted}")

        leakage_path = full_dir / "restart" / "production_output" / "leakage_case_summary.tsv"
        leakage = read_tsv(leakage_path)[0]
        metrics: dict[str, object] = {
            "task": task,
            "case_key": case_key,
            "acceptance_role": selected["acceptance_role"],
            "geology_id": selected["geology_id"],
            "realization_id": selected["realization_id"],
            "case_name": selected["case_name"],
            "runtime_hours": float(final["total_report_solve_seconds"]) / 3600.0,
            "total_ministeps": production["total_ministeps"],
            "rejected_or_cut_ministeps": production["rejected_or_cut_ministeps"],
            "newton_iterations": production["newton_iterations"],
            "linear_iterations": production["linear_iterations"],
            "first_top_seal_arrival_years": leakage["first_top_seal_arrival_years"],
            "first_overburden_arrival_years": leakage["first_overburden_arrival_years"],
            "final_fault_co2_mass_kg": leakage["final_fault_total_co2_mass_kg"],
            "final_top_seal_co2_mass_kg": leakage["final_top_seal_total_co2_mass_kg"],
            "final_overburden_co2_mass_kg": leakage["final_overburden_total_co2_mass_kg"],
            "final_gas_saturation_max": final["final_gas_saturation_max"],
            **schema3_metrics,
            **schema4_metrics,
        }
        case_metrics.append(metrics)
        case_failed = any(row["status"] == "fail" and row["scope"] == scope for row in audit.rows)
        acceptance_rows.append(
            {
                "task": task,
                "case_key": case_key,
                "acceptance_role": selected["acceptance_role"],
                "status": "fail" if case_failed else "pass",
            }
        )

        evidence = incoming / "cases" / case_key
        for source, relative in (
            (preflight_summary_path, "preflight/preflight_summary.txt"),
            (preflight_dir / "RUN_METADATA.txt", "preflight/RUN_METADATA.txt"),
            (production_summary_path, "simulation/production_summary.txt"),
            (final_summary_path, "simulation/final_state_summary.txt"),
            (full_dir / "runtime_diagnostics.txt", "simulation/runtime_diagnostics.txt"),
            (full_dir / "RESTART_MANIFEST.tsv", "simulation/RESTART_MANIFEST.tsv"),
            (full_dir / "RETAINED_RESTART_SHA256.txt", "simulation/RETAINED_RESTART_SHA256.txt"),
            (full_dir / "PRODUCTION_SUMMARY_SHA256.txt", "simulation/PRODUCTION_SUMMARY_SHA256.txt"),
            (leakage_path, "simulation/leakage_case_summary.tsv"),
            (full_dir / "restart" / "production_output" / "PRODUCTION_OUTPUT_COMPLETE.tsv", "simulation/PRODUCTION_OUTPUT_COMPLETE.tsv"),
            (full_dir / "restart" / "production_output" / "QOI_OUTPUT_COMPLETE.tsv", "simulation/QOI_OUTPUT_COMPLETE.tsv"),
            (full_dir / "restart" / "production_output" / "qoi_schema4" / "QOI_SCHEMA4_COMPLETE.tsv", "simulation/QOI_SCHEMA4_COMPLETE.tsv"),
            (vtu_dir / "export_summary.txt", "vtu/export_summary.txt"),
            (vtu_dir / "VTU_SHA256.txt", "vtu/VTU_SHA256.txt"),
        ):
            copy_evidence(source, evidence / relative)

    write_tsv(incoming / "audit_checks.tsv", audit.rows, ["scope", "category", "check", "status", "detail"])
    write_tsv(incoming / "acceptance_status.tsv", acceptance_rows, ["task", "case_key", "acceptance_role", "status"])
    metric_fields = list(case_metrics[0].keys()) if case_metrics else ["task", "case_key"]
    write_tsv(incoming / "case_metrics.tsv", case_metrics, metric_fields)
    copy_evidence(args.campaign, incoming / "campaign.toml")
    copy_evidence(args.selection, incoming / "canary_selection.tsv")
    copy_evidence(args.submission_receipt, incoming / "submission_receipt.txt")
    if args.source_map is not None:
        copy_evidence(args.source_map, incoming / "source_map.tsv")
    copy_evidence(Path(__file__), incoming / "gom_step62_canary_acceptance_audit.py")
    capture_slurm(
        incoming / "slurm_accounting.txt",
        source_jobs,
    )

    overall = "fail" if audit.failures else "pass"
    summary_lines = [
        f"status={overall}",
        f"completed_utc={utc_now()}",
        f"campaign_id={campaign['campaign_id']}",
        f"campaign_manifest_sha256={campaign_sha}",
        f"selection_sha256={selection_sha}",
        f"simulation_commit={actual_commit}",
        f"case_count={len(selection)}",
        "acceptance_roles=" + ",".join(sorted(roles)),
        "full_schedule_years=1000",
        "report_steps=210",
        "fault_property_coverage=6x87",
        "qoi_schema_version=4",
        "retained_restart_steps=51,78,110,210",
        f"first_hour_predict_pressure_rms_limit_pa={args.first_hour_predict_pressure_rms_limit_pa:.12g}",
        f"final_mass_balance_relative_limit={args.final_mass_balance_relative_limit:.12g}",
        "acceptance_results_count_as_production=" +
        ("true" if args.production_reusable else "false"),
        "simulation_outputs_modified=false",
        "scratch_outputs_preserved=true",
        f"failed_check_count={len(audit.failures)}",
    ]
    (incoming / "ACCEPTANCE_SUMMARY.txt").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    if audit.failures:
        (incoming / "FAILURES.txt").write_text("\n".join(audit.failures) + "\n", encoding="utf-8")

    checksum_lines: list[str] = []
    for path in sorted(incoming.rglob("*")):
        if path.is_file() and path.name not in {"SHA256SUMS.txt", "PASS", "FAIL"}:
            checksum_lines.append(f"{sha256_file(path)}  {path.relative_to(incoming).as_posix()}")
    (incoming / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")
    (incoming / ("PASS" if overall == "pass" else "FAIL")).write_text(overall.upper() + "\n", encoding="utf-8")
    final_dir.parent.mkdir(parents=True, exist_ok=True)
    incoming.rename(final_dir)
    print(f"AUDIT_{overall.upper()}={final_dir}")
    if audit.failures:
        for failure in audit.failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
