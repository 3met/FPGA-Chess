"""Regression coverage for the complete software and RTL check entrypoint."""

import argparse
import io
import unittest
from contextlib import redirect_stdout
from unittest import mock

from tools.hardware_build.check import command_check


class CheckCommandTests(unittest.TestCase):
    def test_core_suites_include_benchmark_and_search_tuning(self):
        """Dependency-free tooling must participate in routine checks."""
        for tuning in (False, True):
            with self.subTest(tuning=tuning), \
                    mock.patch("tools.hardware_build.check.command_gen_data", return_value=0), \
                    mock.patch("tools.hardware_build.check.run_command", return_value=(0, "", 0)) as run, \
                    mock.patch("tools.hardware_build.check.command_test", return_value=0) as rtl, \
                    redirect_stdout(io.StringIO()):
                result = command_check(argparse.Namespace(jobs=2, timeout=60, tuning=tuning))
                commands = [call.args[0] for call in run.call_args_list]
                directories = {command[command.index("-s") + 1] for command in commands}
                self.assertTrue({"tests/engine", "tests/live_fpga", "tests/hardware_build",
                                 "tests", "tests/search_tuning"} <= directories)
                self.assertEqual("tests/tuning" in directories, tuning)
                benchmark = next(command for command in commands if command[command.index("-s") + 1] == "tests")
                self.assertEqual(benchmark[benchmark.index("-p") + 1], "test_stockfish_benchmark.py")
                self.assertEqual(result, 0)
                rtl.assert_called_once()

    def test_failed_python_suite_prevents_rtl_execution(self):
        """A tooling regression must fail the command before costly simulation starts."""
        with mock.patch("tools.hardware_build.check.command_gen_data", return_value=0), \
                mock.patch("tools.hardware_build.check.run_command", return_value=(1, "test failure", 0)), \
                mock.patch("tools.hardware_build.check.command_test") as rtl, \
                redirect_stdout(io.StringIO()):
            self.assertEqual(command_check(argparse.Namespace(jobs=1, timeout=60, tuning=False)), 1)
        rtl.assert_not_called()
