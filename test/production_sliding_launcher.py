#!/usr/bin/env python3
"""Integration checks for the shard-level sliding production controller."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SLIDING_FILES = (
    "gom_step62_production_sliding_controller.sbatch",
    "gom_step62_production_sliding_step.sh",
    "gom_step62_production_sliding_submit.sh",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shell_path(path: Path | str) -> str:
    """Return a path accepted by Git Bash as well as native Unix Bash."""
    return str(path).replace("\\", "/")


class ProductionSlidingLauncherTest(unittest.TestCase):
    schema_version = 2
    ensemble_kind = "full_1620"
    case_count = 1620

    @classmethod
    def setUpClass(cls) -> None:
        for command in ("bash", "git", "python3"):
            if shutil.which(command) is None:
                raise unittest.SkipTest(f"sliding launcher test requires {command}")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.workflow = self.root / "workflow"
        self.simulation = self.root / "simulation"
        self.scratch = self.root / "scratch"
        self.archive = self.root / "archive"
        self.manifest = self.root / "campaign.toml"
        self.manifest.write_text("synthetic sliding manifest\n", encoding="utf-8")
        self.install_workflow()
        self.install_simulation()
        self.fakebin, self.slurm = self.install_fake_slurm()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_command(
        self,
        arguments: list[str],
        *,
        env: dict[str, str] | None = None,
        expected_returncode: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            arguments,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        trace = ""
        if result.returncode != expected_returncode and arguments[:1] == ["bash"]:
            traced = subprocess.run(
                ["bash", "-x", *arguments[1:]],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            trace = f"\ntrace stdout:\n{traced.stdout}\ntrace stderr:\n{traced.stderr}"
        self.assertEqual(
            result.returncode,
            expected_returncode,
            msg=(
                f"command: {arguments}\nstdout:\n{result.stdout}"
                f"\nstderr:\n{result.stderr}{trace}"
            ),
        )
        return result

    def initialize_repository(self, path: Path) -> str:
        self.run_command(["git", "init", "-q", str(path)])
        self.run_command(["git", "-C", str(path), "add", "."])
        self.run_command(
            [
                "git",
                "-C",
                str(path),
                "-c",
                "user.name=Sliding Test",
                "-c",
                "user.email=sliding-test@example.invalid",
                "commit",
                "-q",
                "-m",
                "test fixture",
            ]
        )
        return self.run_command(
            ["git", "-C", str(path), "rev-parse", "HEAD"]
        ).stdout.strip()

    def install_workflow(self) -> None:
        scripts = self.workflow / "scripts/engaging"
        scripts.mkdir(parents=True)
        for name in SLIDING_FILES:
            shutil.copy2(REPO / "scripts/engaging" / name, scripts / name)
        self.workflow_commit = self.initialize_repository(self.workflow)

    def install_simulation(self) -> None:
        scripts = self.simulation / "scripts/engaging"
        scripts.mkdir(parents=True)
        resolver = scripts / "gom_step62_production_manifest.py"
        resolver.write_text(
            "#!/usr/bin/env python3\n"
            "import hashlib,pathlib,subprocess,sys\n"
            "manifest=pathlib.Path(sys.argv[sys.argv.index('--manifest')+1])\n"
            "repo=pathlib.Path(__file__).resolve().parents[2]\n"
            "commit=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()\n"
            "sha=hashlib.sha256(manifest.read_bytes()).hexdigest()\n"
            "values={\n"
            f"'GOM_PRODUCTION_SCHEMA_VERSION':'{self.schema_version}',\n"
            f"'GOM_PRODUCTION_ENSEMBLE_KIND':'{self.ensemble_kind}',\n"
            f"'GOM_PRODUCTION_CASE_COUNT':'{self.case_count}',\n"
            "'GOM_PRODUCTION_ARCHIVE_SHARD_SIZE':'50',\n"
            "'GOM_PRODUCTION_JUTULDARCY_COMMIT':commit,\n"
            f"'GOM_PRODUCTION_ARCHIVE_ROOT':{shell_path(self.archive)!r},\n"
            "'GOM_PRODUCTION_CAMPAIGN_ID':'sliding_test_campaign',\n"
            "'GOM_PRODUCTION_MANIFEST_SHA256':sha,\n"
            "'GOM_PRODUCTION_PHYSICS_PROFILE':'sandpc_effective_globalplateau_v1',\n"
            "}\n"
            "for key,value in values.items(): print(f'{key}={value!r}')\n",
            encoding="utf-8",
        )
        verifier = scripts / "gom_step62_production_shard_verify.py"
        verifier.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib,sys\n"
            "shard=pathlib.Path(sys.argv[sys.argv.index('--shard')+1])\n"
            "assert (shard/'SHARD_COMPLETE').is_file(), shard\n",
            encoding="utf-8",
        )
        launcher = scripts / "gom_step62_production_ensemble_submit.sh"
        launcher.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "mkdir -p \"$GOM_GRID_ROOT/submissions\"\n"
            "start=${GOM_PRODUCTION_SELECTION_START:-1}\n"
            f"end=${{GOM_PRODUCTION_SELECTION_END:-{self.case_count}}}\n"
            "finalizer=$((900000 + end))\n"
            "receipt=\"$GOM_GRID_ROOT/submissions/${GOM_PRODUCTION_SUBMISSION_ID}.txt\"\n"
            "printf '%s\\n' \\\n"
            "  'status=submitted' \\\n"
            "  \"submission_id=$GOM_PRODUCTION_SUBMISSION_ID\" \\\n"
            "  'campaign_id=sliding_test_campaign' \\\n"
            f"  'manifest_sha256={digest(self.manifest)}' \\\n"
            "  \"selection_start=$start\" \\\n"
            "  \"selection_end=$end\" \\\n"
            "  'physics_profile=sandpc_effective_globalplateau_v1' \\\n"
            "  \"finalize_job=$finalizer\" > \"$receipt\"\n"
            "printf 'shard_index\\ttask_start\\ttask_end\\n1\\t%s\\t%s\\n' \"$start\" \"$end\" > \"$GOM_GRID_ROOT/submissions/${GOM_PRODUCTION_SUBMISSION_ID}_shards.tsv\"\n"
            "printf '%s %s %s\\n' \"$GOM_PRODUCTION_SUBMISSION_ID\" \"$start\" \"$end\" >> \"$GOM_GRID_ROOT/launcher_calls\"\n"
            "cat \"$receipt\"\n",
            encoding="utf-8",
        )
        launcher.chmod(0o755)
        self.simulation_commit = self.initialize_repository(self.simulation)

    def install_fake_slurm(self) -> tuple[Path, Path]:
        fakebin = self.root / "fakebin"
        fakebin.mkdir()
        state = self.root / "fake_slurm"
        state.mkdir()
        sbatch = fakebin / "sbatch"
        sbatch.write_text(
            "#!/usr/bin/env python3\n"
            "import json,os,pathlib,sys\n"
            "root=pathlib.Path(os.environ['FAKE_SLURM_ROOT'])\n"
            "counter=root/'counter'\n"
            "value=int(counter.read_text())+1 if counter.exists() else 910001\n"
            "counter.write_text(str(value))\n"
            "with (root/'sbatch.jsonl').open('a') as handle:\n"
            "    handle.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "print(value)\n",
            encoding="utf-8",
        )
        sbatch.chmod(0o755)
        flock = fakebin / "flock"
        flock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        flock.chmod(0o755)
        return fakebin, state

    def environment(self) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update(
            {
                "PATH": f"{self.fakebin}{os.pathsep}{environment['PATH']}",
                "FAKE_SLURM_ROOT": shell_path(self.slurm),
                "GOM_GRID_ROOT": shell_path(self.scratch),
                "GOM_PRODUCTION_SLIDING_WORKFLOW_REPO": shell_path(self.workflow),
                "GOM_PRODUCTION_SLIDING_WORKFLOW_COMMIT": self.workflow_commit,
                "GOM_PRODUCTION_SIM_REPO": shell_path(self.simulation),
                "GOM_PRODUCTION_MANIFEST": shell_path(self.manifest),
                "GOM_PRODUCTION_SLIDING_ID": "sliding_test",
                "GOM_PRODUCTION_SLIDING_LANES": "2",
                "GOM_PRODUCTION_MAX_CONCURRENT": "64",
                "GOM_PRODUCTION_PYTHON": shell_path(sys.executable),
            }
        )
        return environment

    def read_sbatch_calls(self) -> list[list[str]]:
        path = self.slurm / "sbatch.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def state_dir(self) -> Path:
        return (
            self.archive
            / "sliding_submissions/sliding_test_campaign/sliding_test"
        )

    def create_durable_shard(self, start: int, end: int) -> None:
        shard = (
            self.archive
            / "campaigns/sliding_test_campaign/shards"
            / f"shard_{start:04d}_{end:04d}"
        )
        shard.mkdir(parents=True)
        (shard / "SHARD_COMPLETE").write_text("status=pass\n", encoding="utf-8")

    def test_two_lanes_claim_unique_shards_and_requeue_is_idempotent(self) -> None:
        environment = self.environment()
        environment.update(
            {
                "GOM_PRODUCTION_SLIDING_START": "1",
                "GOM_PRODUCTION_SLIDING_SEED_DEPENDENCIES": "none,none",
            }
        )
        submit = self.workflow / "scripts/engaging/gom_step62_production_sliding_submit.sh"
        self.run_command(["bash", shell_path(submit)], env=environment)
        self.assertEqual(len(self.read_sbatch_calls()), 2)

        step = self.workflow / "scripts/engaging/gom_step62_production_sliding_step.sh"
        lane_one = dict(environment)
        lane_one.update(
            {
                "GOM_PRODUCTION_SLIDING_LANE_ID": "1",
                "GOM_PRODUCTION_SLIDING_PHASE": "release",
                "GOM_PRODUCTION_SLIDING_EVENT_ID": "seed-job-1",
            }
        )
        lane_two = dict(environment)
        lane_two.update(
            {
                "GOM_PRODUCTION_SLIDING_LANE_ID": "2",
                "GOM_PRODUCTION_SLIDING_PHASE": "release",
                "GOM_PRODUCTION_SLIDING_EVENT_ID": "seed-job-2",
            }
        )
        self.run_command(["bash", shell_path(step)], env=lane_one)
        self.run_command(["bash", shell_path(step)], env=lane_two)
        self.assertEqual((self.state_dir() / "NEXT_START").read_text().strip(), "101")
        calls = (self.scratch / "launcher_calls").read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "sliding_test_shard_0001_0050 1 50",
                "sliding_test_shard_0051_0100 51 100",
            ],
        )
        claims = sorted((self.state_dir() / "claims").glob("*.txt"))
        self.assertEqual(len(claims), 2)
        sbatch_calls = self.read_sbatch_calls()
        self.assertEqual(len(sbatch_calls), 4)
        self.assertTrue(any("--dependency=afterok:900050" in call for call in sbatch_calls))
        self.assertTrue(any("--dependency=afterok:900100" in call for call in sbatch_calls))

        # Re-executing the same Slurm controller event cannot consume a third
        # shard or create a third successor controller.
        self.run_command(["bash", shell_path(step)], env=lane_one)
        self.assertEqual((self.state_dir() / "NEXT_START").read_text().strip(), "101")
        self.assertEqual(len(self.read_sbatch_calls()), 4)
        self.assertEqual((self.scratch / "launcher_calls").read_text().splitlines(), calls)

        # Simulate a requeue after the claim was durable but before the event
        # marker was written.  Recovery must repair only the cached cursor.
        event = self.state_dir() / "events/seed-job-2.txt"
        event.unlink()
        (self.state_dir() / "NEXT_START").write_text("51\n", encoding="utf-8")
        self.run_command(["bash", shell_path(step)], env=lane_two)
        self.assertEqual((self.state_dir() / "NEXT_START").read_text().strip(), "101")
        self.assertEqual(len(self.read_sbatch_calls()), 4)

    def test_attachment_allows_one_open_shard_with_deferred_lane(self) -> None:
        self.create_durable_shard(1, 50)
        self.create_durable_shard(101, 150)
        source = self.root / "source_receipt.txt"
        source.write_text(
            "status=submitted\n"
            "submission_id=prior_wave\n"
            "campaign_id=sliding_test_campaign\n"
            f"manifest_sha256={digest(self.manifest)}\n"
            "selection_start=51\nselection_end=150\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            "finalize_job=888888\n",
            encoding="utf-8",
        )
        environment = self.environment()
        environment.update(
            {
                "GOM_PRODUCTION_SLIDING_START": "151",
                "GOM_PRODUCTION_SLIDING_OPEN_SHARDS": "51-100",
                "GOM_PRODUCTION_SLIDING_SOURCE_RECEIPT": shell_path(source),
                "GOM_PRODUCTION_SLIDING_SEED_DEPENDENCIES": "none,777777",
                "GOM_PRODUCTION_SLIDING_SUPERSEDED_CONTROLLER_JOB": "666666",
            }
        )
        submit = self.workflow / "scripts/engaging/gom_step62_production_sliding_submit.sh"
        self.run_command(["bash", shell_path(submit)], env=environment)
        calls = self.read_sbatch_calls()
        self.assertEqual(len(calls), 2)
        self.assertFalse(any(value.startswith("--dependency=") for value in calls[0]))
        self.assertIn("--dependency=afterok:777777", calls[1])
        config = (self.state_dir() / "SLIDING_CONFIG").read_text()
        self.assertIn("open_shards=51-100", config)
        self.assertIn("superseded_controller_job=666666", config)

    def test_open_shard_requires_exactly_one_deferred_lane(self) -> None:
        self.create_durable_shard(1, 50)
        self.create_durable_shard(101, 150)
        source = self.root / "source_receipt.txt"
        source.write_text(
            "status=submitted\n"
            "campaign_id=sliding_test_campaign\n"
            f"manifest_sha256={digest(self.manifest)}\n"
            "selection_end=150\n",
            encoding="utf-8",
        )
        environment = self.environment()
        environment.update(
            {
                "GOM_PRODUCTION_SLIDING_START": "151",
                "GOM_PRODUCTION_SLIDING_OPEN_SHARDS": "51-100",
                "GOM_PRODUCTION_SLIDING_SOURCE_RECEIPT": shell_path(source),
                "GOM_PRODUCTION_SLIDING_SEED_DEPENDENCIES": "none,none",
            }
        )
        submit = self.workflow / "scripts/engaging/gom_step62_production_sliding_submit.sh"
        result = self.run_command(
            ["bash", shell_path(submit)], env=environment, expected_returncode=1
        )
        self.assertIn("requires one dependency-gated seed lane", result.stderr)
        self.assertEqual(self.read_sbatch_calls(), [])


class ProductionSlidingPhase1LauncherTest(ProductionSlidingLauncherTest):
    """Run the same restart/idempotence checks for the 2,430-case contract."""

    schema_version = 3
    ensemble_kind = "phase1_2430"
    case_count = 2430


if __name__ == "__main__":
    unittest.main()
