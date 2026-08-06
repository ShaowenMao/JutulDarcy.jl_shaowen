#!/usr/bin/env python3
"""Regression checks for schema-2 recovery campaign-check verification."""

from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
VERIFIER = (
    REPO
    / "scripts/engaging/"
    "gom_step62_production_schema2_recovery_verify_campaign_check.sh"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shell_path(path: Path) -> str:
    """Return a path accepted by Git Bash as well as native Unix Bash."""
    return str(path).replace("\\", "/")


class RecoveryCampaignCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("bash") is None:
            raise unittest.SkipTest("campaign-check regression requires bash")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = self.root / "campaign.toml"
        self.manifest.write_text("schema_version = 2\n", encoding="utf-8")
        self.check = self.root / "campaign_check"
        self.check.mkdir()
        (self.check / "PASS").write_text("PASS\n", encoding="utf-8")
        # This is the legacy summary shape that exposed the production bug:
        # it is valid but does not contain campaign_manifest_sha256.
        (self.check / "campaign_check_summary.txt").write_text(
            "status=pass\n"
            "physics_profile=sandpc_effective_globalplateau_v1\n",
            encoding="utf-8",
        )
        shutil.copy2(self.manifest, self.check / "campaign.toml")
        (self.check / "campaign.toml.sha256").write_bytes(
            f"{digest(self.manifest)}  campaign.toml\n".encode("ascii")
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                shell_path(VERIFIER),
                shell_path(self.check),
                shell_path(self.manifest),
                digest(self.manifest),
                "sandpc_effective_globalplateau_v1",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_legacy_summary_is_accepted_by_direct_manifest_proof(self) -> None:
        result = self.verify()
        self.assertEqual(
            result.returncode,
            0,
            msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

    def test_tampered_campaign_check_manifest_is_rejected(self) -> None:
        (self.check / "campaign.toml").write_text(
            "schema_version = 3\n", encoding="utf-8"
        )
        self.assertNotEqual(self.verify().returncode, 0)


if __name__ == "__main__":
    unittest.main()
