#!/usr/bin/env python3
"""Regression tests for reusable noncontiguous Step62 task sets."""

from __future__ import annotations

import csv
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / "scripts/engaging/gom_step62_production_build_manifest.py"
VERIFIER = REPO / "scripts/engaging/gom_step62_production_taskset_verify.py"
SOURCE_SHA = "a" * 64
GEOLOGY_SHA = "b" * 64
COMMIT = "c" * 40
JUTUL_SHA = "d" * 64


def digest(path: Path) -> str:
    value = hashlib.sha256()
    value.update(path.read_bytes())
    return value.hexdigest()


class ProductionTasksetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = self.build_manifest()
        self.selection = self.build_selection()
        self.taskset = self.build_taskset()

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
        for realization in range(1, 4):
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
            "taskset_test",
            "--archive-root",
            "/orcd/data/juanes/001/shaowen/gom_full_production/tests",
            "--jutuldarcy-commit",
            COMMIT,
            "--jutul-manifest-sha256",
            JUTUL_SHA,
            "--mrst-prepare-commit",
            COMMIT,
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

    def build_selection(self) -> Path:
        selection = self.root / "selection.tsv"
        selection.write_text(
            "task\tcase_key\tgeology_id\trealization_id\tcase_name\tpurpose\n"
            "3\ts01_c001_case03\ts01_c001\t3\tcase_03\tcanary\n"
            "1\ts01_c001_case01\ts01_c001\t1\tcase_01\tcanary\n",
            encoding="utf-8",
        )
        return selection

    def build_taskset(self) -> Path:
        taskset = self.root / "taskset_0001"
        (taskset / "payload").mkdir(parents=True)
        (taskset / "payload/dummy.txt").write_text("payload", encoding="utf-8")
        shutil.copy2(self.selection, taskset / "TASKSET_SELECTION.tsv")
        shutil.copy2(self.manifest, taskset / "campaign.toml")
        shutil.copy2(
            Path(str(self.manifest) + ".sha256"),
            taskset / "campaign.toml.sha256.original",
        )
        (taskset / "JUTULDARCY_COMMIT.txt").write_text(COMMIT + "\n", encoding="utf-8")
        (taskset / "CASE_INDEX.tsv").write_text(
            "task\tcase_key\tgeology_id\trealization_id\n"
            "3\ts01_c001_case03\ts01_c001\t3\n"
            "1\ts01_c001_case01\ts01_c001\t1\n",
            encoding="utf-8",
        )
        manifest_sha = digest(self.manifest)
        selection_sha = digest(self.selection)
        (taskset / "TASKSET_METADATA.txt").write_text(
            "status=ready_for_promotion\n"
            "submission_id=test_submission\n"
            "taskset_id=taskset_0001\n"
            "campaign_id=taskset_test\n"
            f"campaign_manifest_sha256={manifest_sha}\n"
            f"taskset_selection_sha256={selection_sha}\n"
            "case_count=2\n",
            encoding="utf-8",
        )
        inventory_paths = sorted(path for path in taskset.rglob("*") if path.is_file())
        with (taskset / "SHA256SUMS").open("w", encoding="utf-8") as handle:
            for path in inventory_paths:
                handle.write(f"{digest(path)}  ./{path.relative_to(taskset).as_posix()}\n")
        sums_sha = digest(taskset / "SHA256SUMS")
        (taskset / "TASKSET_COMPLETE").write_text(
            "status=pass\n"
            "submission_id=test_submission\n"
            "taskset_id=taskset_0001\n"
            "campaign_id=taskset_test\n"
            f"campaign_manifest_sha256={manifest_sha}\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            f"taskset_selection_sha256={selection_sha}\n"
            "case_count=2\n"
            "all_payload_sha256_verified_before_atomic_promote=true\n"
            f"sha256sums_sha256={sums_sha}\n",
            encoding="utf-8",
        )
        return taskset

    def verify(self, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return self.run_command(
            str(VERIFIER),
            "--manifest",
            str(self.manifest),
            "--taskset",
            str(self.taskset),
            "--selection",
            str(self.selection),
            expect=expect,
        )

    def test_noncontiguous_taskset_is_reusable(self) -> None:
        result = self.verify()
        self.assertIn("TASKSET_REUSABLE cases=2", result.stdout)

    def test_selection_tampering_is_rejected(self) -> None:
        text = self.selection.read_text(encoding="utf-8").replace(
            "case_03\tcanary", "changed\tcanary"
        )
        self.selection.write_text(text, encoding="utf-8")
        result = self.verify(expect=2)
        self.assertIn("taskset_selection_sha256 mismatch", result.stderr)

    def test_case_index_tampering_is_rejected(self) -> None:
        with (self.taskset / "CASE_INDEX.tsv").open("a", encoding="utf-8") as handle:
            handle.write("2\tbad\tbad\t2\n")
        result = self.verify(expect=2)
        self.assertIn("CASE_INDEX.tsv SHA-256 mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
