"""Behavioral tests for the reusable FPGA benchmark runner."""

from __future__ import annotations

import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import stockfish_benchmark as benchmark


STANDINGS = """--------------------------------------------------
Results of FPGA-test vs Stockfish-unlimited:
Elo: 0.00 +/- 50.00, nElo: 0.00 +/- 50.00
Games: 2, Wins: 1, Losses: 1, Draws: 0, Points: 1.0 (50.00 %)
Ptnml(0-2): [0, 1, 0, 0, 0], WL/DD Ratio: inf
--------------------------------------------------
"""


class BenchmarkTests(unittest.TestCase):
    """Verify result handling and run-directory safety without FPGA hardware."""

    def test_command_uses_full_strength_and_configured_hash(self) -> None:
        config = benchmark.BenchmarkConfig(stockfish_hash_mb=64)
        with patch.object(benchmark, "_executable", side_effect=lambda value: value):
            command = benchmark._fresh_command(config, Path("results"), "test")
        self.assertIn("option.UCI_LimitStrength=false", command)
        self.assertIn("option.Hash=64", command)
        self.assertFalse(any("UCI_Elo" in value or "Skill Level" in value for value in command))

    def test_run_returns_standings_and_protects_existing_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            book = root / "book.epd"
            book.write_text("", encoding="utf-8")
            config = benchmark.BenchmarkConfig(name="test", matches=1, results_root=root, book=book)

            def fake_process(command: list[str], run_dir: Path, *, resume: bool, output: io.StringIO) -> None:
                (run_dir / "summary.txt").write_text(STANDINGS, encoding="utf-8")
                (run_dir / "state.json").write_text("{}", encoding="utf-8")

            with patch.object(benchmark, "_executable", side_effect=lambda value: value), \
                    patch.object(benchmark, "_run_process", side_effect=fake_process) as run_process:
                result = benchmark.run_tournament(config, output=io.StringIO())
                self.assertEqual((result.games, result.wins, result.losses, result.draws), (2, 1, 1, 0))
                self.assertEqual(result.pentanomial, (0, 1, 0, 0, 0))
                with self.assertRaisesRegex(benchmark.BenchmarkError, "already exists"):
                    benchmark.run_tournament(config, output=io.StringIO())
                resumed = benchmark.resume_tournament(result.run_dir, output=io.StringIO())
                self.assertEqual(resumed, result)
                self.assertEqual(run_process.call_count, 1)

    def test_continue_named_run_resumes_then_reuses_completed_result(self) -> None:
        """Name-based continuation should use the autosave and avoid rerunning completed games."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_dir = root / "test"
            run_dir.mkdir()
            (run_dir / benchmark.RUN_MARKER).write_text(json.dumps({"name": "test", "matches": 2}), encoding="utf-8")
            (run_dir / "state.json").write_text("{}", encoding="utf-8")
            (run_dir / "summary.txt").write_text(STANDINGS, encoding="utf-8")

            def fake_process(command: list[str], run_dir: Path, *, resume: bool, output: io.StringIO) -> None:
                self.assertTrue(resume)
                with (run_dir / "summary.txt").open("a", encoding="utf-8") as summary:
                    summary.write("Elo: 0.00 +/- 20.00\n"
                                  "Games: 4, Wins: 2, Losses: 2, Draws: 0, Points: 2.0\n")

            with patch.object(benchmark, "_executable", side_effect=lambda value: value), \
                    patch.object(benchmark, "_run_process", side_effect=fake_process) as run_process:
                result = benchmark.continue_tournament("test", results_root=root, output=io.StringIO())
                self.assertEqual(result.games, 4)
                self.assertEqual(benchmark.continue_tournament("test", results_root=root, output=io.StringIO()), result)
                with patch("sys.stdout", new_callable=io.StringIO) as stdout:
                    self.assertEqual(benchmark.main(["test", "--continue", "--results-root", str(root)]), 0)
                self.assertIn("Complete: 4 games", stdout.getvalue())
                self.assertEqual(run_process.call_count, 1)

    def test_continue_rejects_missing_or_invalid_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(benchmark.BenchmarkError, "saved tournament state not found"):
                benchmark.continue_tournament("missing", results_root=Path(directory), output=io.StringIO())
            with self.assertRaisesRegex(benchmark.BenchmarkError, "run name"):
                benchmark.continue_tournament("../other", results_root=Path(directory), output=io.StringIO())

    def test_disabled_sprt_does_not_make_historical_h1_a_completed_result(self) -> None:
        """An H1 checkpoint can resume after a caller disables SPRT in Fastchess state."""
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory)
            (run_dir / benchmark.RUN_MARKER).write_text(json.dumps({"name": "trial", "matches": 2}), encoding="utf-8")
            state_path = run_dir / "state.json"
            state_path.write_text(json.dumps({"sprt": {"enabled": True}}), encoding="utf-8")
            (run_dir / "summary.txt").write_text(STANDINGS, encoding="utf-8")
            (run_dir / "raw-output.txt").write_text(
                "SPRT ([-20.0, 5.0]) completed - H1 was accepted\n", encoding="utf-8",
            )
            self.assertEqual(benchmark.read_result(run_dir, expected_games=4).sprt_decision, "H1")
            state_path.write_text(json.dumps({"sprt": {"enabled": False}}), encoding="utf-8")
            with self.assertRaisesRegex(benchmark.BenchmarkError, "expected 4"):
                benchmark.read_result(run_dir, expected_games=4)

            def finish_match(command: list[str], run_dir: Path, *, resume: bool, output: io.StringIO) -> None:
                self.assertTrue(resume)
                with (run_dir / "summary.txt").open("a", encoding="utf-8") as summary:
                    summary.write("Elo: 0.00 +/- 20.00\n"
                                  "Games: 4, Wins: 2, Losses: 2, Draws: 0, Points: 2.0\n")

            with patch.object(benchmark, "_executable", side_effect=lambda value: value), \
                    patch.object(benchmark, "_run_process", side_effect=finish_match) as run_process:
                result = benchmark.resume_tournament(run_dir, output=io.StringIO())
            self.assertEqual(result.games, 4)
            run_process.assert_called_once()

    def test_force_refuses_unowned_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            book = root / "book.epd"
            book.write_text("", encoding="utf-8")
            (root / "test").mkdir()
            config = benchmark.BenchmarkConfig(name="test", results_root=root, book=book, force=True)
            with patch.object(benchmark, "_executable", side_effect=lambda value: value):
                with self.assertRaisesRegex(benchmark.BenchmarkError, "refusing to replace"):
                    benchmark.run_tournament(config, output=io.StringIO())

    def test_elo_error_extends_the_same_saved_tournament(self) -> None:
        """Adaptive runs should retain earlier games and stop at the reported half-width."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            book = root / "book.epd"
            book.write_text("", encoding="utf-8")
            config = benchmark.BenchmarkConfig(name="precision", target_elo_error=20,
                                               results_root=root, book=book)
            calls = []

            def fake_process(command: list[str], run_dir: Path, *, resume: bool, output: io.StringIO) -> None:
                rounds = json.loads((run_dir / "state.json").read_text(encoding="utf-8"))["rounds"] \
                    if resume else int(command[command.index("-rounds") + 1])
                calls.append((rounds, resume))
                (run_dir / "state.json").write_text(json.dumps({"rounds": rounds}), encoding="utf-8")
                error = 50 if len(calls) == 1 else 10
                standings = (f"Elo: 0.00 +/- {error:.2f}\n"
                             f"Games: {2 * rounds}, Wins: {rounds}, Losses: {rounds}, "
                             f"Draws: 0, Points: {rounds}.0\n")
                with (run_dir / "summary.txt").open("a", encoding="utf-8") as summary:
                    summary.write(standings)

            with patch.object(benchmark, "_executable", side_effect=lambda value: value), \
                    patch.object(benchmark, "_run_process", side_effect=fake_process):
                result = benchmark.run_tournament(config, output=io.StringIO())
            self.assertEqual(result.elo_error, 10)
            self.assertEqual(calls, [(benchmark.ERROR_CHECK_MATCHES, False),
                                     (2 * benchmark.ERROR_CHECK_MATCHES, True)])

    def test_elo_error_rejects_match_count(self) -> None:
        config = benchmark.BenchmarkConfig(matches=12, target_elo_error=20)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "either matches or target Elo error"):
            benchmark._validate(config)

    def test_resume_extends_an_unfinished_elo_error_run(self) -> None:
        """A completed batch below the requested precision can grow after restart."""
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory)
            (run_dir / benchmark.RUN_MARKER).write_text(json.dumps({
                "name": "precision", "matches": None, "target_elo_error": 20,
                "max_matches": 3 * benchmark.ERROR_CHECK_MATCHES,
            }), encoding="utf-8")
            (run_dir / "state.json").write_text(json.dumps({"rounds": benchmark.ERROR_CHECK_MATCHES}),
                                                encoding="utf-8")
            (run_dir / "summary.txt").write_text(
                f"Elo: 0.00 +/- 50.00\nGames: {2 * benchmark.ERROR_CHECK_MATCHES}, "
                f"Wins: {benchmark.ERROR_CHECK_MATCHES}, Losses: {benchmark.ERROR_CHECK_MATCHES}, "
                f"Draws: 0, Points: {benchmark.ERROR_CHECK_MATCHES}.0\n", encoding="utf-8")

            def fake_process(command: list[str], run_dir: Path, *, resume: bool, output: io.StringIO) -> None:
                rounds = json.loads((run_dir / "state.json").read_text(encoding="utf-8"))["rounds"]
                with (run_dir / "summary.txt").open("a", encoding="utf-8") as summary:
                    summary.write(f"Elo: 0.00 +/- 10.00\nGames: {2 * rounds}, Wins: {rounds}, "
                                  f"Losses: {rounds}, Draws: 0, Points: {rounds}.0\n")

            with patch.object(benchmark, "_executable", side_effect=lambda value: value), \
                    patch.object(benchmark, "_run_process", side_effect=fake_process):
                result = benchmark.resume_tournament(run_dir, output=io.StringIO())
            self.assertEqual(result.elo_error, 10)
            self.assertEqual(result.games, 4 * benchmark.ERROR_CHECK_MATCHES)

    @unittest.skipUnless(sys.platform.startswith("linux"), "checks Linux process-group cleanup")
    def test_ctrl_c_saves_state_and_stops_descendant(self) -> None:
        """Ctrl+C should give Fastchess time to save and then remove stray children."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child_pid = root / "child.pid"
            state = root / "state.json"
            stub = root / "fastchess_stub.py"
            stub.write_text(
                "import os, signal, subprocess, sys, time\n"
                "from pathlib import Path\n"
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(60)'], "
                "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
                "Path(sys.argv[1]).write_text(str(child.pid))\n"
                "def stop(_signal, _frame):\n"
                "    Path(sys.argv[2]).write_text('saved')\n"
                "    raise SystemExit(1)\n"
                "signal.signal(signal.SIGINT, stop)\n"
                "while True: time.sleep(1)\n", encoding="utf-8")
            wrapper = root / "runner.py"
            wrapper.write_text(
                "import sys\n"
                "from pathlib import Path\n"
                "from tools.stockfish_benchmark import _run_process\n"
                "try:\n"
                "    _run_process([sys.executable, sys.argv[1], sys.argv[2], sys.argv[3]], "
                "Path(sys.argv[4]), resume=False, output=sys.stdout)\n"
                "except KeyboardInterrupt:\n"
                "    raise SystemExit(130)\n", encoding="utf-8")
            runner = subprocess.Popen(
                [sys.executable, str(wrapper), str(stub), str(child_pid), str(state), str(root)],
                cwd=benchmark.REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                env={**os.environ, "PYTHONPATH": str(benchmark.REPO_ROOT) + os.pathsep + os.environ.get("PYTHONPATH", "")},
            )
            try:
                deadline = time.monotonic() + 5
                while not child_pid.is_file() and time.monotonic() < deadline:
                    if runner.poll() is not None:
                        break
                    time.sleep(0.02)
                self.assertTrue(child_pid.is_file(), f"stub did not start its child: {runner.communicate()[1] if runner.poll() is not None else ''}")
                pid = int(child_pid.read_text())
                os.kill(runner.pid, signal.SIGINT)
                stdout, stderr = runner.communicate(timeout=5)
                self.assertEqual(runner.returncode, 130, stderr)
                self.assertTrue(state.is_file(), stdout)
                self.assertIn("Resume with", stdout)
                status = Path(f"/proc/{pid}/stat")
                self.assertTrue(not status.exists() or status.read_text().split()[2] == "Z",
                                "descendant process is still running")
            finally:
                if runner.poll() is None:
                    runner.kill()
                    runner.wait()
                runner.communicate()


if __name__ == "__main__":
    unittest.main()
