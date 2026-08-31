#!/usr/bin/env python3
"""Focused fail-closed checks for the Quartus report parser."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "summarize_quartus_reports", ROOT / "tools/summarize_quartus_reports.py"
)
assert SPEC is not None and SPEC.loader is not None
REPORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORTS)


class QuartusReportParserTest(unittest.TestCase):
    def test_comma_decimal(self) -> None:
        self.assertEqual(REPORTS.decimal("1,234.500 ns"), 1234.5)

    def test_timing_uses_worst_match_per_kind(self) -> None:
        timing = REPORTS.parse_timing(
            [
                "Worst-case setup slack is 0.400",
                "Worst-case setup slack is 0.125",
                "Worst-case hold slack is 0.220",
                "Worst-case recovery slack is 2.900",
                "Worst-case removal slack is 0.600",
                "Worst-case minimum pulse width slack is 1.100",
            ]
        )
        self.assertEqual(timing["setup"], 0.125)

    def test_missing_timing_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing timing summaries"):
            REPORTS.parse_timing(["Worst-case setup slack is 0.400"])

    def test_empty_sections_fail_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "empty fitter resource"):
            REPORTS.parse_entities([])
        with self.assertRaisesRegex(ValueError, "empty fitter RAM"):
            REPORTS.parse_rams([])
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "empty.rpt"
            report.write_text("")
            with self.assertRaisesRegex(ValueError, "empty setup-path"):
                REPORTS.parse_worst_paths(report)


if __name__ == "__main__":
    unittest.main()
