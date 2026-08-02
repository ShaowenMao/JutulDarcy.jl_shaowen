#!/usr/bin/env python3
"""Regression tests for immutable schema-2 checkpoint-recovery plans."""

from __future__ import annotations

import csv
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / "scripts/engaging/gom_step62_production_build_manifest.py"
PLAN = REPO / "scripts/engaging/gom_step62_production_schema2_recovery_plan.py"
SIMULATION_COMMIT = "d" * 40
WORKFLOW_COMMIT = "f" * 40
SOURCE_SHA = "b" * 64
GEOLOGY_SHA = "c" * 64
JUTUL_SHA = "e" * 64
ARCHIVE_ROOT = "/orcd/data/juanes/001/shaowen/gom_grid/recovery_tests"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionRecoveryPlanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.simulation_repo = self.root / "simulation_repo"
        self.simulation_repo.mkdir()
        self.manifest = self.build_manifest()
        self.receipt, self.shards = self.write_source_receipts()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_command(
        self, *arguments: str, expect: int = 0
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, *arguments],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            expect,
            msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        return result

    def build_manifest(self) -> Path:
        common = self.root / "common.mat"
        common.write_bytes(b"common")
        fields = (
            "artifactKind",
            "caseKey",
            "relativePath",
            "sha256",
            "geologyId",
            "geologyHash",
            "realizationId",
            "level3CaseName",
            "inputManifestSha256",
        )
        rows = [
            {
                "artifactKind": "common",
                "caseKey": "",
                "relativePath": common.name,
                "sha256": digest(common),
                "geologyId": "",
                "geologyHash": "",
                "realizationId": "",
                "level3CaseName": "",
                "inputManifestSha256": SOURCE_SHA,
            }
        ]
        for realization in range(1, 7):
            case_key = f"s01_c001_case{realization:02d}"
            specific = self.root / f"specific_{realization:02d}.mat"
            specific.write_bytes(case_key.encode())
            rows.append(
                {
                    "artifactKind": "geology_specific",
                    "caseKey": case_key,
                    "relativePath": specific.name,
                    "sha256": digest(specific),
                    "geologyId": "s01_c001",
                    "geologyHash": GEOLOGY_SHA,
                    "realizationId": str(realization),
                    "level3CaseName": f"case_{realization:02d}",
                    "inputManifestSha256": SOURCE_SHA,
                }
            )
        derived = self.root / "derived.csv"
        with derived.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        manifest = self.root / "campaign.toml"
        self.run_command(
            str(BUILDER),
            "--derived-manifest",
            str(derived),
            "--campaign-id",
            "recovery_test",
            "--archive-root",
            ARCHIVE_ROOT,
            "--jutuldarcy-commit",
            SIMULATION_COMMIT,
            "--jutul-manifest-sha256",
            JUTUL_SHA,
            "--mrst-prepare-commit",
            SIMULATION_COMMIT,
            "--source-input-manifest-sha256",
            SOURCE_SHA,
            "--schema-version",
            "2",
            "--ensemble-kind",
            "subset",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            "--qoi-mode",
            "required",
            "--archive-shard-size",
            "3",
            "--output",
            str(manifest),
        )
        return manifest

    def write_source_receipts(
        self, first_mode: str = "new"
    ) -> tuple[Path, Path]:
        with self.manifest.open("rb") as handle:
            campaign = tomllib.load(handle)
        shards = self.root / "source_shards.tsv"
        header = (
            "shard_index\ttask_start\ttask_end\tmode\tpreflight_job\t"
            "full_job\tvtu_job\tarchive_job\twave_gate_archive_job\t"
            "archive_path\n"
        )
        first_jobs = (
            "101\t201\t301\t401" if first_mode == "new" else "none\tnone\tnone\tnone"
        )
        shards.write_text(
            header
            + f"1\t1\t3\t{first_mode}\t{first_jobs}\tnone\t"
            + f"{ARCHIVE_ROOT}/campaigns/recovery_test/shards/shard_0001_0003"
            + "\n"
            + "2\t4\t6\tnew\t102\t202\t302\t402\t401\t"
            + f"{ARCHIVE_ROOT}/campaigns/recovery_test/shards/shard_0004_0006"
            + "\n",
            encoding="utf-8",
        )
        receipt = self.root / "source.txt"
        receipt.write_text(
            "status=submitted\n"
            "submission_id=source_test\n"
            "campaign_id=recovery_test\n"
            f"manifest={self.manifest}\n"
            f"manifest_sha256={digest(self.manifest)}\n"
            f"case_order_sha256={campaign['case_order_sha256']}\n"
            f"ensemble_kind={campaign['ensemble_kind']}\n"
            "selection_start=1\n"
            "selection_end=6\n"
            "selection_count=6\n"
            "archive_shard_size=3\n"
            "shard_count=2\n"
            f"new_shard_count={2 if first_mode == 'new' else 1}\n"
            f"reused_shard_count={0 if first_mode == 'new' else 1}\n"
            "qoi_mode=required\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            "campaign_check_job=100\n"
            "finalize_job=500\n"
            f"shard_receipt={shards}\n",
            encoding="utf-8",
        )
        return receipt, shards

    def build_plan(
        self,
        tasks: str = "2,5-6",
        expect: int = 0,
        output_name: str = "recovery.toml",
    ) -> tuple[Path, subprocess.CompletedProcess[str]]:
        output = self.root / output_name
        result = self.run_command(
            str(PLAN),
            "build",
            "--manifest",
            str(self.manifest),
            "--source-receipt",
            str(self.receipt),
            "--source-shards",
            str(self.shards),
            "--tasks",
            tasks,
            "--recovery-id",
            "recovery_attempt_1",
            "--workflow-commit",
            WORKFLOW_COMMIT,
            "--simulation-repo",
            str(self.simulation_repo),
            "--output",
            str(output),
            expect=expect,
        )
        return output, result

    def test_multishard_plan_resolves_selected_and_coverage_tasks(self) -> None:
        plan, result = self.build_plan()
        self.assertIn("selected=3 coverage=6 shards=2", result.stdout)
        validated = self.run_command(str(PLAN), "validate", "--plan", str(plan))
        self.assertIn("selected=3 coverage=6 shards=2", validated.stdout)
        selected = self.run_command(
            str(PLAN), "tasks", "--plan", str(plan), "--scope", "selected"
        )
        self.assertEqual(selected.stdout.splitlines(), ["2", "5", "6"])
        coverage = self.run_command(
            str(PLAN), "tasks", "--plan", str(plan), "--scope", "coverage"
        )
        self.assertEqual(coverage.stdout.splitlines(), [str(i) for i in range(1, 7)])
        resolved = self.run_command(
            str(PLAN),
            "resolve",
            "--plan",
            str(plan),
            "--task",
            "5",
            "--format",
            "json",
        )
        self.assertIn('"GOM_RECOVERY_SOURCE_FULL_JOB": 202', resolved.stdout)
        self.assertIn('"GOM_RECOVERY_TASK_SELECTED": "true"', resolved.stdout)

    def test_invalid_task_selectors_are_rejected(self) -> None:
        for index, selector in enumerate(("2,2", "4,2", "0", "7", "1-3,3")):
            _, result = self.build_plan(
                selector, expect=2, output_name=f"bad_{index}.toml"
            )
            self.assertIn("RECOVERY_PLAN_ERROR", result.stderr)

    def test_source_receipt_mutation_invalidates_existing_plan(self) -> None:
        plan, _ = self.build_plan()
        with self.receipt.open("a", encoding="utf-8") as handle:
            handle.write("unexpected=mutation\n")
        result = self.run_command(
            str(PLAN), "validate", "--plan", str(plan), expect=2
        )
        self.assertIn("source receipt changed", result.stderr)

    def test_plan_cannot_forge_source_job_even_with_new_companion(self) -> None:
        plan, _ = self.build_plan()
        text = plan.read_text(encoding="utf-8").replace(
            "source_full_job = 202", "source_full_job = 999", 1
        )
        plan.write_text(text, encoding="utf-8")
        Path(str(plan) + ".sha256").write_text(
            f"{digest(plan)}  {plan.name}\n", encoding="utf-8"
        )
        result = self.run_command(
            str(PLAN), "validate", "--plan", str(plan), expect=2
        )
        self.assertIn("differs from source receipt", result.stderr)

    def test_affected_reused_shard_is_rejected(self) -> None:
        self.receipt, self.shards = self.write_source_receipts(first_mode="reused")
        _, result = self.build_plan("2", expect=2)
        self.assertIn("already marked reused", result.stderr)

    def test_unaffected_reused_shard_is_allowed(self) -> None:
        self.receipt, self.shards = self.write_source_receipts(first_mode="reused")
        plan, result = self.build_plan("5")
        self.assertIn("selected=1 coverage=3 shards=1", result.stdout)
        self.run_command(str(PLAN), "validate", "--plan", str(plan))

    def test_plan_companion_detects_plan_mutation(self) -> None:
        plan, _ = self.build_plan()
        shutil.copy2(plan, self.root / "original.toml")
        with plan.open("a", encoding="utf-8") as handle:
            handle.write("# mutation\n")
        result = self.run_command(
            str(PLAN), "validate", "--plan", str(plan), expect=2
        )
        self.assertIn("SHA-256 mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
