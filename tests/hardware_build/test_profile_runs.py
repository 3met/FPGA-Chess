"""Behavior checks for named runs, safe replacement, and saved topic viewing."""

import argparse
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.hardware_build.cli import build_parser
from tools.hardware_build.common import BuildError
from tools.hardware_build.profile_format import PROFILE_TOPICS, format_profile_topics
from tools.hardware_build.profile_report import build_profile_suite_report
from tools.hardware_build.profile_runs import (
    command_profile_view,
    complete_profile_run,
    prepare_profile_run,
    profile_output_dir,
    write_profile_reports,
)
import test_profiling as fixtures


class SavedProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.patcher = patch("tools.hardware_build.profile_runs.BUILD_ROOT", self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.parser = build_parser()

    def allocate(self, name, replace=False):
        """Allocate a named test run through the same path as the CLI."""
        args = argparse.Namespace(name=name, output=None, replace=replace)
        path = profile_output_dir(args)
        prepare_profile_run(path, replace)
        return path

    def finish(self, path, report=None):
        """Save a complete run with internally consistent sample metrics."""
        write_profile_reports(path, report or fixtures.ReportTests().build_sample_report())
        complete_profile_run(path)

    def view(self, *arguments):
        """Capture the read-only viewer output using real CLI arguments."""
        args = self.parser.parse_args(["profile-view", *arguments])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            command_profile_view(args)
        return output.getvalue()

    def test_duplicate_requires_replace_and_replace_removes_old_artifacts(self):
        path = self.allocate("baseline")
        self.finish(path)
        (path / "old-waveform.fst").touch()
        with self.assertRaisesRegex(BuildError, "--replace"):
            self.allocate("baseline")
        self.assertTrue((path / "report.json").exists())
        replaced = self.allocate("baseline", replace=True)
        self.assertEqual(path, replaced)
        self.assertFalse((path / "old-waveform.fst").exists())
        self.assertFalse((path / "report.json").exists())
        with self.assertRaisesRegex(BuildError, "incomplete"):
            self.view("baseline")

    def test_replace_refuses_unrelated_directory(self):
        path = self.root / "unrelated"
        path.mkdir()
        sentinel = path / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        args = argparse.Namespace(name=None, output=str(path), replace=True)
        with self.assertRaises(BuildError):
            profile_output_dir(args)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_names_are_portable_and_cannot_escape_run_root(self):
        for name in ("../escape", "/absolute", "a/b", "a\\b", ".", "..", "CON", "nul.txt", "COM1", "trailing.", "compile"):
            with self.subTest(name=name), self.assertRaises(BuildError):
                self.allocate(name)
        self.assertEqual(self.allocate("baseline-test_1").parent, self.root / "profile")
        with self.assertRaisesRegex(BuildError, "requires"):
            profile_output_dir(argparse.Namespace(name=None, output=None, replace=True))

    def test_output_cannot_overlap_simulator_cache_or_profile_root(self):
        for path in (self.root, self.root / "profile", self.root / "profile" / "compile", self.root / "profile" / "compile" / "verilator"):
            with self.subTest(path=path), self.assertRaisesRegex(BuildError, "overlaps"):
                profile_output_dir(argparse.Namespace(name=None, output=str(path), replace=True))

    def test_latest_and_list_ignore_incomplete_runs(self):
        self.finish(self.allocate("first"))
        self.finish(self.allocate("second"))
        self.allocate("interrupted")
        self.assertIn("Run: second", self.view())
        listed = self.view("--list-runs")
        self.assertLess(listed.index("second"), listed.index("first"))
        self.assertNotIn("interrupted", listed)
        with self.assertRaisesRegex(BuildError, "incomplete"):
            self.view("interrupted")

    def test_every_topic_saved_and_viewer_renders_from_json(self):
        path = self.allocate("baseline")
        self.finish(path)
        self.assertEqual({p.stem for p in (path / "reports").iterdir()}, set(PROFILE_TOPICS))
        (path / "reports" / "tt.txt").write_text("stale text", encoding="utf-8")
        viewed = self.view("baseline", "--topic", "tt", "simulation", "--topic", "tt")
        self.assertIn("Transposition table and SDRAM", viewed)
        self.assertIn("Simulation throughput", viewed)
        self.assertNotIn("stale text", viewed)
        self.assertNotIn("Per-thread lifecycle", viewed)
        self.assertEqual(viewed.count("[tt]"), 1)
        self.assertEqual(self.view("baseline", "--topic", "all").count("[summary]"), 1)

    def test_explicit_directory_and_missing_runs(self):
        with self.assertRaisesRegex(BuildError, "No completed"):
            self.view()
        path = self.root / "custom-output"
        args = argparse.Namespace(name=None, output=str(path), replace=False)
        prepare_profile_run(profile_output_dir(args), False)
        self.finish(path)
        self.assertIn("Run: custom-output", self.view("--run", str(path)))
        with self.assertRaisesRegex(BuildError, "not both"):
            self.view("baseline", "--run", str(path))

    def test_suite_summary_and_per_position_topic_selection(self):
        factory = fixtures.ProfileSuiteTests()
        first = factory.make_report("first fen", 5, 0.5)
        second = factory.make_report("second fen", 10, 1.5)
        suite = build_profile_suite_report([("first", first), ("second", second)])
        path = self.allocate("suite")
        for name, report in (("first", first), ("second", second)):
            position_path = path / "positions" / name
            position_path.mkdir(parents=True)
            write_profile_reports(position_path, report)
        self.finish(path, suite)
        summary = self.view("suite")
        self.assertNotIn("Position results", summary)
        self.assertNotIn("first", summary)
        self.assertNotIn("second", summary)
        self.assertIn("Simulated search time per position (average): 100.00 ms", summary)
        self.assertNotIn("Per-thread lifecycle", summary)
        self.assertIn("Position: first", self.view("suite", "--position", "first", "--topic", "tt"))
        with self.assertRaisesRegex(BuildError, "Available positions: first, second"):
            self.view("suite", "--position", "missing")
        self.assertIn("Suite elapsed wall time", self.view("suite", "--topic", "simulation"))

    def test_suite_summary_reports_only_failed_positions_and_overall_time(self):
        factory = fixtures.ProfileSuiteTests()
        first = factory.make_report("first fen", 5, 0.5)
        second = factory.make_report("second fen", 10, 1.5)
        second["result"]["error"] = True
        suite = build_profile_suite_report(
            [("passed-position", first), ("failed-position", second)],
            suite_wall_seconds=1.25, profiling_wall_seconds=3.5,
        )
        text = format_profile_topics(suite)
        self.assertIn("Failed positions", text)
        self.assertIn("failed-position: engine fault", text)
        self.assertNotIn("passed-position", text)
        self.assertIn("Overall profiling wall time: 3.50 s", text)
        self.assertIn("Simulated search time per position (average): 100.00 ms", text)

    def test_topics_are_discoverable_without_saved_runs(self):
        listed = self.view("--list-topics")
        for topic in PROFILE_TOPICS:
            self.assertIn(topic, listed)

    def test_malformed_artifacts_produce_build_error(self):
        path = self.allocate("broken")
        self.finish(path)
        (path / "report.json").write_text("{", encoding="utf-8")
        with self.assertRaisesRegex(BuildError, "Cannot read"):
            self.view("broken")
        (path / "report.json").write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(BuildError, "Invalid profiling report"):
            self.view("broken")

    def test_summary_is_short_and_faults_are_visible(self):
        report = fixtures.ReportTests().build_sample_report()
        report["result"]["error"] = True
        summary = format_profile_topics(report)
        self.assertIn("Engine fault: yes", summary)
        self.assertNotIn("Per-thread lifecycle", summary)
        self.assertNotIn("Transposition table and SDRAM", summary)


if __name__ == "__main__":
    unittest.main()
