#!/usr/bin/env python3
"""Linux integration test for the schema-2 recovery submission DAG."""

from __future__ import annotations

import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest
import uuid


REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / "scripts/engaging/gom_step62_production_build_manifest.py"
PLAN = REPO / "scripts/engaging/gom_step62_production_schema2_recovery_plan.py"
LAUNCHER = "scripts/engaging/gom_step62_production_schema2_recovery_submit.sh"
ORCD_TEST_PARENT = Path(
    "/orcd/data/juanes/001/shaowen/gom_grid/recovery_launcher_tests"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionRecoveryLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("bash") is None or shutil.which("git") is None:
            raise unittest.SkipTest("recovery launcher integration requires bash and git")
        if not ORCD_TEST_PARENT.parent.is_dir() or not os.access(
            ORCD_TEST_PARENT.parent, os.W_OK
        ):
            raise unittest.SkipTest("writable ORCD recovery test root is unavailable")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive_root = ORCD_TEST_PARENT / f"test_{uuid.uuid4().hex}"
        self.archive_root.mkdir(parents=True)

    def tearDown(self) -> None:
        resolved = self.archive_root.resolve()
        expected_parent = ORCD_TEST_PARENT.resolve()
        self.assertEqual(resolved.parent, expected_parent)
        self.assertTrue(resolved.name.startswith("test_"))
        shutil.rmtree(resolved, ignore_errors=True)
        self.temporary.cleanup()

    def run_command(
        self,
        arguments: list[str],
        *,
        cwd: Path | None = None,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"command: {arguments}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        return result

    def clone_repositories(self) -> tuple[Path, Path, str, str]:
        simulation = self.root / "simulation"
        workflow = self.root / "workflow"
        self.run_command(["git", "clone", "--shared", str(REPO), str(simulation)])
        self.run_command(["git", "clone", "--shared", str(REPO), str(workflow)])
        source_manifest = REPO / "Manifest.toml"
        manifest_bytes = (
            source_manifest.read_bytes()
            if source_manifest.is_file()
            else b"synthetic recovery launcher test manifest\n"
        )
        (simulation / "Manifest.toml").write_bytes(manifest_bytes)
        (workflow / "Manifest.toml").write_bytes(manifest_bytes)
        simulation_commit = self.run_command(
            ["git", "rev-parse", "HEAD"], cwd=simulation
        ).stdout.strip()
        self.run_command(
            [
                "git",
                "-c",
                "user.name=Recovery Launcher Test",
                "-c",
                "user.email=recovery-test@example.invalid",
                "commit",
                "--allow-empty",
                "-m",
                "test: distinguish recovery control commit",
            ],
            cwd=workflow,
        )
        workflow_commit = self.run_command(
            ["git", "rev-parse", "HEAD"], cwd=workflow
        ).stdout.strip()
        self.assertNotEqual(simulation_commit, workflow_commit)
        return simulation, workflow, simulation_commit, workflow_commit

    def build_manifest(self, simulation: Path, commit: str) -> Path:
        inputs = self.root / "inputs"
        inputs.mkdir()
        common = inputs / "common.mat"
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
        source_sha = "b" * 64
        geology_sha = "c" * 64
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
                "inputManifestSha256": source_sha,
            }
        ]
        for realization in range(1, 7):
            case_key = f"s01_c001_case{realization:02d}"
            specific = inputs / f"specific_{realization:02d}.mat"
            specific.write_bytes(case_key.encode())
            rows.append(
                {
                    "artifactKind": "geology_specific",
                    "caseKey": case_key,
                    "relativePath": specific.name,
                    "sha256": digest(specific),
                    "geologyId": "s01_c001",
                    "geologyHash": geology_sha,
                    "realizationId": str(realization),
                    "level3CaseName": f"case_{realization:02d}",
                    "inputManifestSha256": source_sha,
                }
            )
        derived = inputs / "derived.csv"
        with derived.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        manifest = self.root / "campaign.toml"
        self.run_command(
            [
                "python3.12",
                str(BUILDER),
                "--derived-manifest",
                str(derived),
                "--campaign-id",
                "recovery_launcher_test",
                "--archive-root",
                str(self.archive_root),
                "--jutuldarcy-commit",
                commit,
                "--jutul-manifest-sha256",
                digest(simulation / "Manifest.toml"),
                "--mrst-prepare-commit",
                "d" * 40,
                "--source-input-manifest-sha256",
                source_sha,
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
            ]
        )
        return manifest

    def write_source_receipts(self, manifest: Path) -> tuple[Path, Path]:
        with manifest.open("rb") as handle:
            campaign = tomllib.load(handle)
        shards = self.root / "source_shards.tsv"
        shards.write_text(
            "shard_index\ttask_start\ttask_end\tmode\tpreflight_job\t"
            "full_job\tvtu_job\tarchive_job\twave_gate_archive_job\t"
            "archive_path\n"
            "1\t1\t3\tnew\t101\t201\t301\t401\tnone\t"
            f"{self.archive_root}/campaigns/recovery_launcher_test/"
            "shards/shard_0001_0003\n"
            "2\t4\t6\tnew\t102\t202\t302\t402\t401\t"
            f"{self.archive_root}/campaigns/recovery_launcher_test/"
            "shards/shard_0004_0006\n",
            encoding="utf-8",
        )
        receipt = self.root / "source.txt"
        receipt.write_text(
            "status=submitted\n"
            "submission_id=source_launcher_test\n"
            "campaign_id=recovery_launcher_test\n"
            f"manifest={manifest}\n"
            f"manifest_sha256={digest(manifest)}\n"
            f"case_order_sha256={campaign['case_order_sha256']}\n"
            "ensemble_kind=subset\n"
            "selection_start=1\nselection_end=6\nselection_count=6\n"
            "archive_shard_size=3\nshard_count=2\n"
            "new_shard_count=2\nreused_shard_count=0\n"
            "qoi_mode=required\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            "campaign_check_job=100\nfinalize_job=500\n"
            f"shard_receipt={shards}\n",
            encoding="utf-8",
        )
        return receipt, shards

    def install_fake_slurm(self) -> tuple[Path, Path]:
        fakebin = self.root / "fakebin"
        fakebin.mkdir()
        state = self.root / "fake_slurm"
        state.mkdir()
        sbatch = fakebin / "sbatch"
        sbatch.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "root=pathlib.Path(os.environ['FAKE_SLURM_ROOT'])\n"
            "counter=root/'counter'\n"
            "value=int(counter.read_text())+1 if counter.exists() else 900001\n"
            "counter.write_text(str(value))\n"
            "with (root/'sbatch.jsonl').open('a') as handle:\n"
            "    handle.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "print(value)\n",
            encoding="utf-8",
        )
        scancel = fakebin / "scancel"
        scancel.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "root=pathlib.Path(os.environ['FAKE_SLURM_ROOT'])\n"
            "with (root/'scancel.jsonl').open('a') as handle:\n"
            "    handle.write(json.dumps(sys.argv[1:])+'\\n')\n",
            encoding="utf-8",
        )
        sbatch.chmod(0o755)
        scancel.chmod(0o755)
        return fakebin, state

    def test_launcher_builds_expected_multishard_dependency_dag(self) -> None:
        simulation, workflow, simulation_commit, workflow_commit = (
            self.clone_repositories()
        )
        manifest = self.build_manifest(simulation, simulation_commit)
        receipt, shards = self.write_source_receipts(manifest)
        fakebin, fake_state = self.install_fake_slurm()
        scratch = self.root / "scratch"
        environment = dict(os.environ)
        environment.update(
            {
                "PATH": f"{fakebin}:{environment['PATH']}",
                "FAKE_SLURM_ROOT": str(fake_state),
                "GOM_GRID_ROOT": str(scratch),
                "GOM_RECOVERY_WORKFLOW_REPO": str(workflow),
                "GOM_RECOVERY_SIM_REPO": str(simulation),
                "GOM_PRODUCTION_MANIFEST": str(manifest),
                "GOM_RECOVERY_SOURCE_RECEIPT": str(receipt),
                "GOM_RECOVERY_SOURCE_SHARDS": str(shards),
                "GOM_RECOVERY_TASKS": "2,5",
                "GOM_RECOVERY_SUBMISSION_ID": "launcher_integration_test",
                "GOM_RECOVERY_MAX_CONCURRENT": "8",
            }
        )
        launched = self.run_command(
            ["bash", str(workflow / LAUNCHER)], env=environment
        )
        self.assertIn("status=submitted", launched.stdout)
        calls = [
            json.loads(line)
            for line in (fake_state / "sbatch.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
        ]
        self.assertEqual(len(calls), 8)
        self.assertTrue(calls[0][-1].endswith("recovery_gate.sbatch"))
        self.assertIn("--dependency=afterok:900001", calls[1])
        self.assertIn("--array=2,5%2", calls[1])
        self.assertIn("--dependency=afterok:900002", calls[2])
        self.assertIn("--array=1-6%6", calls[2])
        self.assertIn("--dependency=afterok:900003", calls[3])
        self.assertTrue(calls[3][-1].endswith("production_shard_archive.sbatch"))
        self.assertIn("--dependency=afterok:900004", calls[4])
        self.assertTrue(calls[4][-1].endswith("production_finalize.sbatch"))
        self.assertIn("--dependency=afterok:900003", calls[5])
        self.assertIn("--dependency=afterok:900006", calls[6])
        self.assertIn("--dependency=afterok:900005:900007", calls[7])
        self.assertTrue(calls[7][-1].endswith("recovery_complete.sbatch"))
        self.assertFalse((fake_state / "scancel.jsonl").exists())

        scratch_receipt = scratch / "submissions/launcher_integration_test_recovery.txt"
        durable = (
            self.archive_root
            / "recovery_submissions/recovery_launcher_test/launcher_integration_test"
        )
        self.assertTrue(scratch_receipt.is_file())
        self.assertTrue((durable / "submission_receipt.txt").is_file())
        self.assertTrue((durable / "recovery_plan.toml").is_file())
        self.assertFalse((durable / "RECOVERY_COMPLETE").exists())
        self.assertIn(
            "completion_job=900008", scratch_receipt.read_text(encoding="utf-8")
        )
        self.run_command(
            [
                "python3.12",
                str(PLAN),
                "validate",
                "--plan",
                str(
                    scratch
                    / "recovery_plans/recovery_launcher_test/"
                    "launcher_integration_test/recovery_plan.toml"
                ),
            ]
        )
        self.assertEqual(
            self.run_command(
                ["git", "rev-parse", "HEAD"], cwd=workflow
            ).stdout.strip(),
            workflow_commit,
        )


if __name__ == "__main__":
    unittest.main()
