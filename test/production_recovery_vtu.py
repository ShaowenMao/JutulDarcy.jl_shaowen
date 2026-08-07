#!/usr/bin/env python3
"""Behavioral tests for mixed selected/unselected recovery VTU coverage."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
VTU_SCRIPT = (
    REPO
    / "scripts/engaging/gom_step62_production_schema2_recovery_vtu.sbatch"
)
PLAN_SHA256 = "a" * 64


@unittest.skipUnless(
    os.name == "posix" and shutil.which("bash") is not None,
    "the recovery VTU entry point requires a POSIX bash environment",
)
class ProductionRecoveryVtuTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.workflow = self.root / "workflow"
        self.simulation = self.root / "simulation"
        self.scratch = self.root / "scratch"
        self.source_case = self.root / "source_case"
        self.marker = self.root / "vtu_called.txt"
        self.campaign = self.root / "campaign.toml"
        (self.workflow / "scripts/engaging").mkdir(parents=True)
        (self.simulation / "scripts/engaging").mkdir(parents=True)
        self.source_case.mkdir()
        (self.source_case / "PASS").write_text("PASS\n", encoding="utf-8")
        self.campaign.write_text("schema_version = 2\n", encoding="utf-8")
        self.install_fake_common()
        self.install_fake_vtu()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @property
    def attempt_dir(self) -> Path:
        return (
            self.scratch
            / "results/gom_step62_schema2_recovery_case_job900/case_7"
        )

    def install_fake_common(self) -> None:
        common = (
            self.workflow
            / "scripts/engaging/gom_step62_production_schema2_recovery_common.sh"
        )
        common.write_text(
            """#!/bin/bash
recovery_sim_repo="${FAKE_SIM_REPO:?}"
GOM_RECOVERY_CAMPAIGN_MANIFEST="${FAKE_CAMPAIGN_MANIFEST:?}"

gom_recovery_resolve_plan_task() {
    test "$1" -eq 7
    GOM_RECOVERY_TASK=7
    GOM_RECOVERY_CASE_KEY=case_7
    GOM_RECOVERY_SOURCE_PREFLIGHT_JOB=101
    GOM_RECOVERY_SOURCE_FULL_JOB=201
    GOM_RECOVERY_TASK_SELECTED="$FAKE_SELECTED"
}

gom_recovery_set_case_paths() {
    test "$1" -eq 7
    test "$2" = case_7
    test "$3" -eq 101
    test "$4" -eq 201
    GOM_RECOVERY_CASE_DIR="$FAKE_SOURCE_CASE"
}

gom_recovery_validate_complete_case() {
    test "$1" = "$FAKE_SOURCE_CASE"
    test "$2" = case_7
    test -f "$1/PASS"
}
""",
            encoding="utf-8",
        )

    def install_fake_vtu(self) -> None:
        vtu = (
            self.simulation
            / "scripts/engaging/gom_step62_effective_pc_global_plateau_vtu.sbatch"
        )
        vtu.write_text(
            """#!/bin/bash
set -euo pipefail
test "$JUTULDARCY_COMBINED_REPO" = "$FAKE_SIM_REPO"
test "$GOM_PRODUCTION_MANIFEST" = "$FAKE_CAMPAIGN_MANIFEST"
test "$GOM_PRODUCTION_FULL_JOB_ID" -eq 201
printf 'called\n' > "$FAKE_VTU_MARKER"
""",
            encoding="utf-8",
        )

    def run_vtu(self, selected: str) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "GOM_GRID_ROOT": str(self.scratch),
                "GOM_RECOVERY_CASE_JOB_ID": "900",
                "GOM_RECOVERY_WORKFLOW_REPO": str(self.workflow),
                "GOM_RECOVERY_PLAN_SHA256": PLAN_SHA256,
                "SLURM_ARRAY_TASK_ID": "7",
                "FAKE_SELECTED": selected,
                "FAKE_SIM_REPO": str(self.simulation),
                "FAKE_CAMPAIGN_MANIFEST": str(self.campaign),
                "FAKE_SOURCE_CASE": str(self.source_case),
                "FAKE_VTU_MARKER": str(self.marker),
            }
        )
        return subprocess.run(
            ["bash", str(VTU_SCRIPT)],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_unselected_complete_case_does_not_require_recovery_attempt(self) -> None:
        result = self.run_vtu("false")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(self.marker.read_text(encoding="utf-8"), "called\n")

    def test_selected_case_requires_plan_bound_recovery_attempt(self) -> None:
        self.attempt_dir.mkdir(parents=True)
        (self.attempt_dir / "PASS").write_text("PASS\n", encoding="utf-8")
        (self.attempt_dir / "recovery_summary.txt").write_text(
            f"recovery_plan_sha256={PLAN_SHA256}\n", encoding="utf-8"
        )
        result = self.run_vtu("true")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(self.marker.read_text(encoding="utf-8"), "called\n")

    def test_selected_case_without_recovery_attempt_fails_closed(self) -> None:
        result = self.run_vtu("true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_unselected_case_with_unexpected_attempt_fails_closed(self) -> None:
        self.attempt_dir.mkdir(parents=True)
        result = self.run_vtu("false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
