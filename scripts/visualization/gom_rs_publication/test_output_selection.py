from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import render_gom_rs_cross_section as renderer


class OutputSelectionTest(unittest.TestCase):
    def parse(self, *arguments: str):
        argv = ["render_gom_rs_cross_section.py", "--input", "frame.vtu"]
        argv.extend(arguments)
        with patch.object(sys, "argv", argv):
            return renderer.parse_args()

    def test_publication_defaults_keep_all_outputs(self) -> None:
        args = self.parse()
        self.assertFalse(args.no_svg)
        self.assertFalse(args.no_pdf)
        self.assertFalse(args.no_audit_csv)

    def test_movie_mode_can_keep_only_png_and_audit(self) -> None:
        args = self.parse(
            "--png",
            "frames/frame_0001.png",
            "--audit-csv",
            "audit/frame_0001.csv",
            "--no-svg",
            "--no-pdf",
        )
        self.assertEqual(args.png, Path("frames/frame_0001.png"))
        self.assertEqual(args.audit_csv, Path("audit/frame_0001.csv"))
        self.assertTrue(args.no_svg)
        self.assertTrue(args.no_pdf)
        self.assertFalse(args.no_audit_csv)


if __name__ == "__main__":
    unittest.main()
