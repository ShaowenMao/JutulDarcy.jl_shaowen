#!/usr/bin/env python3
"""Integration checks for the scheduler-safe production rolling controller."""

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
ROLLING_FILES = (
    "gom_step62_production_rolling_controller.sbatch",
    "gom_step62_production_rolling_step.sh",
    "gom_step62_production_rolling_submit.sh",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionRollingLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        for command in ("bash", "git", "python3"):
            if shutil.which(command) is None:
                raise unittest.SkipTest(f"rolling launcher test requires {command}")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.workflow = self.root / "workflow"
        self.simulation = self.root / "simulation"
        self.scratch = self.root / "scratch"
        self.archive = self.root / "archive"
        self.manifest = self.root / "campaign.toml"
        self.manifest.write_text("synthetic rolling manifest\n", encoding="utf-8")
        self.install_workflow()
        self.install_simulation()
        self.fakebin, self.slurm = self.install_fake_slurm()

    def tearDown(self) -> None:
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

    def initialize_repository(self, path: Path) -> str:
        self.run_command(["git", "init", "-q"], cwd=path)
        self.run_command(["git", "add", "."], cwd=path)
        self.run_command(
            [
                "git",
                "-c",
                "user.name=Rolling Test",
                "-c",
                "user.email=rolling-test@example.invalid",
                "commit",
                "-q",
                "-m",
                "test fixture",
            ],
            cwd=path,
        )
        return self.run_command(["git", "rev-parse", "HEAD"], cwd=path).stdout.strip()

    def install_workflow(self) -> None:
        scripts = self.workflow / "scripts/engaging"
        scripts.mkdir(parents=True)
        for name in ROLLING_FILES:
            shutil.copy2(REPO / "scripts/engaging" / name, scripts / name)
        self.workflow_commit = self.initialize_repository(self.workflow)

    def install_simulation(self) -> None:
        scripts = self.simulation / "scripts/engaging"
        scripts.mkdir(parents=True)
        resolver = scripts / "gom_step62_production_manifest.py"
        resolver.write_text(
            "#!/usr/bin/env python3\n"
            "import hashlib, pathlib, subprocess, sys\n"
            "manifest=pathlib.Path(sys.argv[sys.argv.index('--manifest')+1])\n"
            "repo=pathlib.Path(__file__).resolve().parents[2]\n"
            "commit=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'], text=True).strip()\n"
            "sha=hashlib.sha256(manifest.read_bytes()).hexdigest()\n"
            "values={\n"
            "'GOM_PRODUCTION_SCHEMA_VERSION':'2',\n"
            "'GOM_PRODUCTION_ENSEMBLE_KIND':'full_1620',\n"
            "'GOM_PRODUCTION_CASE_COUNT':'1620',\n"
            "'GOM_PRODUCTION_ARCHIVE_SHARD_SIZE':'50',\n"
            "'GOM_PRODUCTION_JUTULDARCY_COMMIT':commit,\n"
            f"'GOM_PRODUCTION_ARCHIVE_ROOT':{str(self.archive)!r},\n"
            "'GOM_PRODUCTION_CAMPAIGN_ID':'rolling_test_campaign',\n"
            "'GOM_PRODUCTION_MANIFEST_SHA256':sha,\n"
            "'GOM_PRODUCTION_PHYSICS_PROFILE':'sandpc_effective_globalplateau_v1',\n"
            "}\n"
            "for key,value in values.items(): print(f'{key}={value!r}')\n",
            encoding="utf-8",
        )
        launcher = scripts / "gom_step62_production_ensemble_submit.sh"
        launcher.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "mkdir -p \"$GOM_GRID_ROOT/submissions\"\n"
            "start=${GOM_PRODUCTION_SELECTION_START:-1}\n"
            "end=${GOM_PRODUCTION_SELECTION_END:-1620}\n"
            "finalizer=$((900000 + end))\n"
            "receipt=\"$GOM_GRID_ROOT/submissions/${GOM_PRODUCTION_SUBMISSION_ID}.txt\"\n"
            "printf '%s\\n' \\\n"
            "  'status=submitted' \\\n"
            "  \"submission_id=$GOM_PRODUCTION_SUBMISSION_ID\" \\\n"
            "  'campaign_id=rolling_test_campaign' \\\n"
            f"  'manifest_sha256={digest(self.manifest)}' \\\n"
            "  \"selection_start=$start\" \\\n"
            "  \"selection_end=$end\" \\\n"
            "  'physics_profile=sandpc_effective_globalplateau_v1' \\\n"
            "  \"finalize_job=$finalizer\" > \"$receipt\"\n"
            "calls=\"$GOM_GRID_ROOT/launcher_calls\"\n"
            "printf '%s %s %s\\n' \"$GOM_PRODUCTION_SUBMISSION_ID\" \"$start\" \"$end\" >> \"$calls\"\n"
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
            "import json, os, pathlib, sys\n"
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
        return fakebin, state

    def environment(self) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update(
            {
                "PATH": f"{self.fakebin}:{environment['PATH']}",
                "FAKE_SLURM_ROOT": str(self.slurm),
                "GOM_GRID_ROOT": str(self.scratch),
                "GOM_PRODUCTION_ROLLING_WORKFLOW_REPO": str(self.workflow),
                "GOM_PRODUCTION_SIM_REPO": str(self.simulation),
                "GOM_PRODUCTION_MANIFEST": str(self.manifest),
                "GOM_PRODUCTION_ROLLING_ID": "rolling_test",
                "GOM_PRODUCTION_ROLLING_WAVE_CASES": "100",
                "GOM_PRODUCTION_MAX_CONCURRENT": "64",
                "GOM_PRODUCTION_SHARD_WINDOW": "2",
                "GOM_PRODUCTION_PYTHON": sys.executable,
            }
        )
        return environment

    def test_attach_wave_chain_is_bounded_and_idempotent(self) -> None:
        source = self.root / "source_receipt.txt"
        source.write_text(
            "status=submitted\n"
            "submission_id=source_wave\n"
            "campaign_id=rolling_test_campaign\n"
            f"manifest_sha256={digest(self.manifest)}\n"
            "selection_start=1\nselection_end=150\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n"
            "finalize_job=19539143\n",
            encoding="utf-8",
        )
        environment = self.environment()
        environment.update(
            {
                "GOM_PRODUCTION_ROLLING_START": "151",
                "GOM_PRODUCTION_ROLLING_SOURCE_RECEIPT": str(source),
            }
        )
        launched = self.run_command(
            [
                "bash",
                str(
                    self.workflow
                    / "scripts/engaging/gom_step62_production_rolling_submit.sh"
                ),
            ],
            env=environment,
        )
        self.assertIn("controller_job=910001", launched.stdout)
        calls = self.read_sbatch_calls()
        self.assertEqual(len(calls), 1)
        self.assertIn("--dependency=afterok:19539143", calls[0])

        step_environment = self.environment()
        step_environment.update(
            {
                "GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT": self.workflow_commit,
                "GOM_PRODUCTION_ROLLING_PHASE": "wave",
                "GOM_PRODUCTION_ROLLING_NEXT_START": "151",
            }
        )
        step = self.workflow / "scripts/engaging/gom_step62_production_rolling_step.sh"
        self.run_command(["bash", str(step)], env=step_environment)
        calls = self.read_sbatch_calls()
        self.assertEqual(len(calls), 2)
        self.assertIn("--dependency=afterok:900250", calls[1])
        export_argument = next(value for value in calls[1] if value.startswith("--export="))
        self.assertIn("GOM_PRODUCTION_ROLLING_PHASE=wave", export_argument)
        self.assertIn("GOM_PRODUCTION_ROLLING_NEXT_START=251", export_argument)

        launcher_calls = (self.scratch / "launcher_calls").read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertEqual(
            launcher_calls,
            ["rolling_test_wave_0151_0250 151 250"],
        )
        self.run_command(["bash", str(step)], env=step_environment)
        self.assertEqual(len(self.read_sbatch_calls()), 2)
        self.assertEqual(
            (self.scratch / "launcher_calls").read_text(encoding="utf-8").splitlines(),
            launcher_calls,
        )

        reconcile_environment = self.environment()
        reconcile_environment.update(
            {
                "GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT": self.workflow_commit,
                "GOM_PRODUCTION_ROLLING_PHASE": "reconcile",
                "GOM_PRODUCTION_ROLLING_NEXT_START": "1",
            }
        )
        self.run_command(["bash", str(step)], env=reconcile_environment)
        calls = self.read_sbatch_calls()
        self.assertEqual(len(calls), 3)
        self.assertIn("--dependency=afterok:901620", calls[2])
        complete_export = next(
            value for value in calls[2] if value.startswith("--export=")
        )
        self.assertIn("GOM_PRODUCTION_ROLLING_PHASE=complete", complete_export)
        self.assertEqual(
            (self.scratch / "launcher_calls").read_text(encoding="utf-8").splitlines(),
            launcher_calls + ["rolling_test_complete 1 1620"],
        )

        campaign_root = self.archive / "campaigns/rolling_test_campaign"
        submission_root = campaign_root / "submissions/rolling_test_complete"
        submission_root.mkdir(parents=True)
        (campaign_root / "CAMPAIGN_COMPLETE").write_text(
            "status=pass\n", encoding="utf-8"
        )
        (submission_root / "SUBMISSION_COMPLETE").write_text(
            "status=pass\n", encoding="utf-8"
        )
        complete_environment = self.environment()
        complete_environment.update(
            {
                "GOM_PRODUCTION_ROLLING_WORKFLOW_COMMIT": self.workflow_commit,
                "GOM_PRODUCTION_ROLLING_PHASE": "complete",
                "GOM_PRODUCTION_ROLLING_NEXT_START": "1",
            }
        )
        completed = self.run_command(["bash", str(step)], env=complete_environment)
        self.assertIn("status=pass", completed.stdout)
        rolling_marker = (
            self.archive
            / "rolling_submissions/rolling_test_campaign/rolling_test/ROLLING_COMPLETE"
        )
        self.assertTrue(rolling_marker.is_file())
        self.assertEqual(len(self.read_sbatch_calls()), 3)

    def read_sbatch_calls(self) -> list[list[str]]:
        return [
            json.loads(line)
            for line in (self.slurm / "sbatch.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
        ]


if __name__ == "__main__":
    unittest.main()
