#!/usr/bin/env python3
"""Regression tests for immutable Step62 production manifests."""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / "scripts/engaging/gom_step62_production_build_manifest.py"
RESOLVER = REPO / "scripts/engaging/gom_step62_production_manifest.py"
SOURCE_SHA = "b" * 64
GEOLOGY_SHA = "c" * 64
COMMIT = "d" * 40
JUTUL_SHA = "e" * 64
PILOT_CASES = (
    ("s05_c012_case01", "s05_c012", 1),
    ("s05_c012_case03", "s05_c012", 3),
    ("s05_c012_case04", "s05_c012", 4),
    ("s05_c012_case07", "s05_c012", 7),
    ("s03_c001_case04", "s03_c001", 4),
    ("s03_c012_case08", "s03_c012", 8),
    ("s04_c024_case03", "s04_c024", 3),
)
PHASE1_CASE_IDS = tuple(range(1, 13)) + (101, 102, 103)
PHASE1_CASES = tuple(
    (
        f"s{scenario:02d}_c{geology:03d}_case{realization:02d}",
        f"s{scenario:02d}_c{geology:03d}",
        realization,
    )
    for scenario in range(1, 7)
    for geology in range(1, 28)
    for realization in PHASE1_CASE_IDS
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_command(self, *arguments: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
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

    def write_derived(
        self, cases: tuple[tuple[str, str, int], ...]
    ) -> Path:
        common = self.root / "gom_step62_87slice_7case_common.mat"
        common.write_bytes(b"common-input")
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
        for index, (case_key, geology_id, realization) in enumerate(cases, 1):
            specific = self.root / f"specific_{index:04d}.mat"
            specific.write_bytes(f"specific-{case_key}".encode())
            rows.append(
                {
                    "artifactKind": "geology_specific",
                    "caseKey": case_key,
                    "relativePath": specific.name,
                    "sha256": digest(specific),
                    "geologyId": geology_id,
                    "geologyHash": GEOLOGY_SHA,
                    "realizationId": str(realization),
                    "level3CaseName": f"case_{realization:02d}",
                    "inputManifestSha256": SOURCE_SHA,
                }
            )
        manifest = self.root / "derived.csv"
        with manifest.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        return manifest

    def build(
        self,
        derived: Path,
        output: Path,
        *extra: str,
        expect: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        return self.run_command(
            str(BUILDER),
            "--derived-manifest",
            str(derived),
            "--campaign-id",
            "manifest_test",
            "--archive-root",
            "/orcd/data/juanes/001/shaowen/gom_grid/tests",
            "--jutuldarcy-commit",
            COMMIT,
            "--jutul-manifest-sha256",
            JUTUL_SHA,
            "--mrst-prepare-commit",
            COMMIT,
            "--source-input-manifest-sha256",
            SOURCE_SHA,
            "--output",
            str(output),
            *extra,
            expect=expect,
        )

    def test_schema1_pilot_remains_valid(self) -> None:
        derived = self.write_derived(PILOT_CASES)
        manifest = self.root / "pilot.toml"
        self.build(derived, manifest)
        result = self.run_command(
            str(RESOLVER), "--manifest", str(manifest), "validate"
        )
        self.assertIn("schema=1", result.stdout)
        self.assertIn("cases=7", result.stdout)

    def test_schema2_subset_summary_and_resolution(self) -> None:
        cases = tuple(
            (f"s01_c001_case{realization:02d}", "s01_c001", realization)
            for realization in range(1, 4)
        )
        derived = self.write_derived(cases)
        manifest = self.root / "subset.toml"
        self.build(
            derived,
            manifest,
            "--schema-version",
            "2",
            "--ensemble-kind",
            "subset",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            "--archive-shard-size",
            "2",
            "--qoi-mode",
            "required",
        )
        summary = self.run_command(
            str(RESOLVER),
            "--manifest",
            str(manifest),
            "summary",
            "--format",
            "json",
        )
        values = json.loads(summary.stdout)
        self.assertEqual(values["GOM_PRODUCTION_CASE_COUNT"], 3)
        self.assertEqual(values["GOM_PRODUCTION_ARCHIVE_SHARD_COUNT"], 2)
        self.assertEqual(values["GOM_PRODUCTION_QOI_MODE"], "required")
        self.assertEqual(
            values["GOM_PRODUCTION_PHYSICS_PROFILE"],
            "sandpc_effective_globalplateau_v1",
        )
        resolved = self.run_command(
            str(RESOLVER),
            "--manifest",
            str(manifest),
            "resolve",
            "--task",
            "3",
            "--format",
            "json",
        )
        self.assertEqual(json.loads(resolved.stdout)["case_key"], "s01_c001_case03")

    def test_schema2_rejects_reordered_subset(self) -> None:
        cases = (
            ("s01_c001_case02", "s01_c001", 2),
            ("s01_c001_case01", "s01_c001", 1),
        )
        derived = self.write_derived(cases)
        result = self.build(
            derived,
            self.root / "bad.toml",
            "--schema-version",
            "2",
            "--ensemble-kind",
            "subset",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            expect=1,
        )
        self.assertIn("deterministic", result.stderr)

    def test_full_ensemble_rejects_incomplete_identity_set(self) -> None:
        derived = self.write_derived(
            (("s01_c001_case01", "s01_c001", 1),)
        )
        result = self.build(
            derived,
            self.root / "incomplete.toml",
            "--schema-version",
            "2",
            "--ensemble-kind",
            "full_1620",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            expect=1,
        )
        self.assertIn("full_1620 must contain exactly", result.stderr)

    def test_schema3_phase1_2430_exact_contract(self) -> None:
        derived = self.write_derived(PHASE1_CASES)
        manifest = self.root / "phase1.toml"
        self.build(
            derived,
            manifest,
            "--schema-version",
            "3",
            "--ensemble-kind",
            "phase1_2430",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            "--archive-root",
            "/orcd/data/juanes/001/shaowen/gom_full_production/tests",
        )
        summary = self.run_command(
            str(RESOLVER),
            "--manifest",
            str(manifest),
            "summary",
            "--format",
            "json",
        )
        values = json.loads(summary.stdout)
        self.assertEqual(values["GOM_PRODUCTION_SCHEMA_VERSION"], 3)
        self.assertEqual(values["GOM_PRODUCTION_ENSEMBLE_KIND"], "phase1_2430")
        self.assertEqual(values["GOM_PRODUCTION_CASE_COUNT"], 2430)
        self.assertEqual(values["GOM_PRODUCTION_QOI_SCHEMA_VERSION"], 4)
        resolved = self.run_command(
            str(RESOLVER),
            "--manifest",
            str(manifest),
            "resolve",
            "--task",
            "2430",
            "--format",
            "json",
        )
        self.assertEqual(
            json.loads(resolved.stdout)["case_key"], "s06_c027_case103"
        )

    def test_schema3_rejects_incomplete_phase1_identity_set(self) -> None:
        derived = self.write_derived(PHASE1_CASES[:-1])
        result = self.build(
            derived,
            self.root / "incomplete_phase1.toml",
            "--schema-version",
            "3",
            "--ensemble-kind",
            "phase1_2430",
            "--physics-profile",
            "sandpc_effective_globalplateau_v1",
            "--archive-root",
            "/orcd/data/juanes/001/shaowen/gom_full_production/tests",
            expect=1,
        )
        self.assertIn("phase1_2430 must contain exactly", result.stderr)

    def test_manifest_companion_detects_tampering(self) -> None:
        derived = self.write_derived(PILOT_CASES)
        manifest = self.root / "tampered.toml"
        self.build(derived, manifest)
        with manifest.open("a", encoding="utf-8") as handle:
            handle.write("# altered\n")
        result = self.run_command(
            str(RESOLVER),
            "--manifest",
            str(manifest),
            "validate",
            expect=2,
        )
        self.assertIn("manifest SHA-256 mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
