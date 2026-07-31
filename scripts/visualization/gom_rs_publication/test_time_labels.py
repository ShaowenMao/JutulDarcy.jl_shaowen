"""Regression tests for GOM adaptive physical-time annotations."""

from __future__ import annotations

import math
import unittest

import render_gom_rs_cross_section as renderer


def inclusive_range(start: float, stop: float, step: float) -> list[float]:
    count = int(round((stop - start) / step)) + 1
    return [start + index * step for index in range(count)]


def current_gom_report_times_years() -> list[float]:
    days_per_year = renderer.MRST_DAYS_PER_YEAR
    times = [1.0 / (renderer.HOURS_PER_DAY * days_per_year)]
    times.extend(
        day / days_per_year
        for day in (
            1,
            2,
            7,
            14,
            21,
            30,
            60,
            90,
            120,
            150,
            180,
            240,
            300,
            365,
            456.25,
            547.5,
            638.75,
            730,
            821.25,
        )
    )
    times.extend(inclusive_range(2.5, 10.0, 0.5))
    times.extend(inclusive_range(11.0, 48.0, 1.0))
    times.extend(inclusive_range(48.5, 52.0, 0.5))
    times.extend(inclusive_range(53.0, 60.0, 1.0))
    times.extend(inclusive_range(62.0, 100.0, 2.0))
    times.extend(inclusive_range(105.0, 200.0, 5.0))
    times.extend(inclusive_range(210.0, 1000.0, 10.0))
    return times


class AdaptiveTimeLabelTests(unittest.TestCase):
    def label_from_days(self, days: float) -> renderer.PhysicalTimeLabel:
        return renderer.format_physical_time_label(
            days / renderer.MRST_DAYS_PER_YEAR
        )

    def test_representative_schedule_labels(self) -> None:
        self.assertEqual(
            renderer.format_physical_time_label(0.0).plain,
            "0",
        )
        self.assertEqual(self.label_from_days(1.0 / 24.0).plain, "1 h")
        self.assertEqual(self.label_from_days(1.0).plain, "1 d")
        self.assertEqual(self.label_from_days(300.0).plain, "300 d")
        self.assertEqual(self.label_from_days(365.0).plain, "1 yr")
        self.assertEqual(self.label_from_days(456.25).plain, "1.25 yr")
        self.assertEqual(self.label_from_days(547.5).plain, "1.5 yr")
        self.assertEqual(self.label_from_days(730.0).plain, "2 yr")
        self.assertEqual(self.label_from_days(821.25).plain, "2.25 yr")
        self.assertEqual(
            renderer.format_physical_time_label(2.5).plain,
            "2.5 yr",
        )
        self.assertEqual(
            renderer.format_physical_time_label(48.5).plain,
            "48.5 yr",
        )
        self.assertEqual(
            renderer.format_physical_time_label(50.0).plain,
            "50 yr",
        )
        self.assertEqual(
            renderer.format_physical_time_label(1000.0).plain,
            "1000 yr",
        )

    def test_latex_label(self) -> None:
        label = renderer.format_physical_time_label(48.5)
        self.assertEqual(label.latex, r"$t = 48.5\,\mathrm{yr}$")

    def test_all_current_report_labels_are_unique(self) -> None:
        times = current_gom_report_times_years()
        labels = [renderer.format_physical_time_label(t).plain for t in times]
        self.assertEqual(len(times), 210)
        self.assertEqual(len(labels), len(set(labels)))

    def test_invalid_times_are_rejected(self) -> None:
        for value in (-1.0, math.nan, math.inf):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    renderer.format_physical_time_label(value)


if __name__ == "__main__":
    unittest.main()
