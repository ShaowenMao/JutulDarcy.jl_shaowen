#!/usr/bin/env python3
"""Regression tests for reusable Step62 production shards."""

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
VERIFIER = REPO / "scripts/engaging/gom_step62_production_shard_verify.py"
SOURCE_SHA = "a" * 64
GEOLOGY_SHA = "b" * 64
COMMIT = "c" * 40
JUTUL_SHA = "d" * 64


def digest(path: Path) -> str:
    value = hashlib.sha256()
    value.update(path.read_bytes())
    return value.hexdigest()


class ProductionShardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = self.build_manifest()
        self.shard = self.build_shard()

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
            "shard_test",
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

    def build_shard(self) -> Path:
        shard = self.root / "shard_0001_0003"
        (shard / "payload").mkdir(parents=True)
        (shard / "payload/dummy.txt").write_text("payload", encoding="utf-8")
        shutil.copy2(self.manifest, shard / "campaign.toml")
        shutil.copy2(
            Path(str(self.manifest) + ".sha256"),
            shard / "campaign.toml.sha256.original",
        )
        (shard / "JUTULDARCY_COMMIT.txt").write_text(
            COMMIT + "\n", encoding="utf-8"
        )
        (shard / "CASE_INDEX.tsv").write_text(
            "task\tcase_key\tgeology_id\trealization_id\n"
            "1\ts01_c001_case01\ts01_c001\t1\n"
            "2\ts01_c001_case02\ts01_c001\t2\n"
            "3\ts01_c001_case03\ts01_c001\t3\n",
            encoding="utf-8",
        )
        manifest_sha = digest(self.manifest)
        order_sha = hashlib.sha256(
            b"1\ts01_c001_case01\n"
            b"2\ts01_c001_case02\n"
            b"3\ts01_c001_case03\n"
        ).hexdigest()
        (shard / "SHARD_METADATA.txt").write_text(
            "status=ready_for_promotion\n"
            "submission_id=test_submission\n"
            "campaign_id=shard_test\n"
            f"campaign_manifest_sha256={manifest_sha}\n"
            f"case_order_sha256={order_sha}\n"
            "task_start=1\n"
            "task_end=3\n"
            "case_count=3\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n",
            encoding="utf-8",
        )
        inventory_paths = sorted(
            path for path in shard.rglob("*") if path.is_file()
        )
        with (shard / "SHA256SUMS").open("w", encoding="utf-8") as handle:
            for path in inventory_paths:
                relative = path.relative_to(shard).as_posix()
                handle.write(f"{digest(path)}  ./{relative}\n")
        sums_sha = digest(shard / "SHA256SUMS")
        (shard / "SHARD_COMPLETE").write_text(
            "status=pass\n"
            "submission_id=test_submission\n"
            "campaign_id=shard_test\n"
            f"campaign_manifest_sha256={manifest_sha}\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            "task_start=1\n"
            "task_end=3\n"
            "case_count=3\n"
            "all_payload_sha256_verified_before_atomic_promote=true\n"
            f"sha256sums_sha256={sums_sha}\n",
            encoding="utf-8",
        )
        return shard

    def verify(self, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return self.run_command(
            str(VERIFIER),
            "--manifest",
            str(self.manifest),
            "--shard",
            str(self.shard),
            "--start",
            "1",
            "--end",
            "3",
            expect=expect,
        )

    def test_verified_shard_is_reusable(self) -> None:
        result = self.verify()
        self.assertIn("SHARD_REUSABLE tasks=1:3 cases=3", result.stdout)

    def test_case_index_tampering_is_rejected(self) -> None:
        with (self.shard / "CASE_INDEX.tsv").open("a", encoding="utf-8") as handle:
            handle.write("4\tbad\tbad\t4\n")
        result = self.verify(expect=2)
        self.assertIn("CASE_INDEX.tsv SHA-256 mismatch", result.stderr)

    def test_checksum_inventory_tampering_is_rejected(self) -> None:
        with (self.shard / "SHA256SUMS").open("a", encoding="utf-8") as handle:
            handle.write("0" * 64 + "  ./extra\n")
        result = self.verify(expect=2)
        self.assertIn("SHA256SUMS digest mismatch", result.stderr)

    def test_manifest_identity_mismatch_is_rejected(self) -> None:
        marker = self.shard / "SHARD_COMPLETE"
        text = marker.read_text(encoding="utf-8").replace(
            f"campaign_manifest_sha256={digest(self.manifest)}",
            "campaign_manifest_sha256=" + "f" * 64,
        )
        marker.write_text(text, encoding="utf-8")
        result = self.verify(expect=2)
        self.assertIn("campaign_manifest_sha256 mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
