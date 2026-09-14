import argparse
import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.search_tuning.cli import main as tuning_main
from tools.search_tuning.benchmark import fresh_command, resume_command
from tools.search_tuning.optimizer import suggest
from tools.search_tuning.space import (
    configured_parameters,
    get_path,
    json_from_vector,
    parameter_hash,
    vector_from_json,
)
from tools.search_tuning.workflow import (
    RunLock,
    Runner,
    TuningError,
    aggregate_evaluations,
    confirmation_success_probability,
    parse_tournament_completion,
    promotion_is_significant,
)


ROOT = Path(__file__).resolve().parents[2]


def semantic_leaf_paths(value, prefix=""):
    """Treat rational pairs as leaves while expanding ordinary arrays."""
    if isinstance(value, dict):
        return {
            path
            for key, item in value.items()
            for path in semantic_leaf_paths(item, f"{prefix}.{key}" if prefix else key)
        }
    if isinstance(value, list) and not (len(value) == 2 and all(isinstance(item, int) for item in value)):
        return {
            path
            for index, item in enumerate(value)
            for path in semantic_leaf_paths(item, f"{prefix}.{index}")
        }
    return {prefix}


def completed_record(identifier, parameters, score, error, promoted=True):
    """Build one current-schema history record for workflow tests."""
    return {
        "id": identifier,
        "parameter_hash": parameter_hash(parameters),
        "parameters": parameters,
        "score": score,
        "score_error": error,
        "promoted": promoted,
        "evaluations": [{
            "score": score, "score_error": error, "games": 1000,
            "completion": "full", "tournament_dir": "synthetic",
        }],
    }


class CliTests(unittest.TestCase):
    def test_clean_is_forwarded_to_run(self):
        with mock.patch("tools.search_tuning.cli.Runner") as runner_type, mock.patch(
            "tools.search_tuning.cli.install_signal_handlers"
        ):
            self.assertEqual(tuning_main(["run", "--clean"]), 0)

        runner_type.return_value.run.assert_called_once_with(False, clean=True)


class BenchmarkCommandTests(unittest.TestCase):
    def test_fresh_command_contains_reproducible_match_and_sprt_settings(self):
        run_dir = Path("results/run")
        args = argparse.Namespace(
            fastchess=Path("fastchess"), label="candidate", repo_root=Path("fpga"),
            fpga_tc="2+0.02", stockfish=Path("stockfish"), stockfish_tc="0.2+0.002",
            stockfish_elo=3100, stockfish_threads=1, stockfish_hash=256,
            book=Path("book.epd"), opening_start=501, rounds=500,
            sprt_elo0=-20.0, sprt_elo1=5.0, sprt_alpha=0.1, sprt_beta=0.02,
        )

        command = fresh_command(args, run_dir)

        self.assertIn("args=-m software.engine", command)
        self.assertIn("start=501", command)
        self.assertIn("elo0=-20.0", command)
        self.assertIn("outname=results/run/state.json", command)
        self.assertEqual(command.count("-engine"), 2)

    def test_resume_command_uses_only_the_saved_configuration(self):
        command = resume_command(Path("fastchess"), Path("results/run"))

        self.assertEqual(command[:3], ["fastchess", "-config", "file=results/run/state.json"])
        self.assertIn("append=true", command)


class SearchSpaceTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
        self.baseline = json.loads((ROOT / "hardware/config/search/default.json").read_text(encoding="utf-8"))
        self.parameters = configured_parameters(self.config)

    def test_default_space_round_trips_every_search_leaf(self):
        vector = vector_from_json(self.baseline, self.parameters)

        self.assertEqual(len(self.parameters), 39)
        self.assertEqual({parameter.path for parameter in self.parameters}, semantic_leaf_paths(self.baseline))
        self.assertEqual(json_from_vector(self.baseline, vector, self.parameters), self.baseline)

    def test_decoding_repairs_cross_parameter_constraints(self):
        candidate = json_from_vector(self.baseline, [0.0] * len(self.parameters), self.parameters)

        soft = candidate["time_management"]
        self.assertLessEqual(soft["soft_factor_minimum"], soft["soft_factor_default"])
        self.assertLessEqual(soft["soft_factor_default"], soft["soft_factor_maximum"])
        null = candidate["null_move"]
        self.assertLess(null["shallow_reduction"], null["minimum_depth"])
        self.assertLess(null["deep_reduction"], null["deep_depth_threshold"])
        thresholds = candidate["history"]["quiet_bucket_thresholds"]
        self.assertTrue(thresholds[0] < thresholds[1] < thresholds[2])

    def test_all_configured_paths_exist(self):
        for parameter in self.parameters:
            self.assertIsNotNone(get_path(self.baseline, parameter.path))

    def test_suggestion_is_quantized_unique_and_deterministic(self):
        settings = dict(self.config["optimizer"], candidate_pool_size=250, initial_design=8)
        history = [{
            "parameter_hash": parameter_hash(self.baseline),
            "parameters": self.baseline,
            "score": -100.0,
            "score_error": 10.0,
        }]

        first, details = suggest(self.baseline, self.parameters, history, settings, seed=7, radius=0.2)
        second, _ = suggest(self.baseline, self.parameters, history, settings, seed=7, radius=0.2)

        self.assertEqual(first, second)
        self.assertNotEqual(parameter_hash(first), history[0]["parameter_hash"])
        self.assertIn("low-discrepancy", details["method"])
        self.assertEqual(details["group"], "aspiration")
        self.assertEqual(first["lmr"], self.baseline["lmr"])

    def test_gp_search_center_can_use_an_unpromoted_observation(self):
        alternative = copy.deepcopy(self.baseline)
        alternative["aspiration"]["starting_delta"] += 32
        settings = dict(
            self.config["optimizer"], initial_design=2,
            candidate_pool_size=250, acquisition_shortlist_size=50,
        )
        history = [
            {
                "id": 0, "parameter_hash": parameter_hash(self.baseline),
                "parameters": self.baseline, "score": 0.0,
                "score_error": 5.0, "promoted": True,
            },
            {
                "id": 1, "parameter_hash": parameter_hash(alternative),
                "parameters": alternative, "score": 50.0,
                "score_error": 5.0, "promoted": False,
            },
        ]

        _, details = suggest(self.baseline, self.parameters, history, settings, seed=4, radius=0.2)

        self.assertEqual(details["center_id"], 1)
        self.assertGreater(details["center_posterior_stddev"], 0.0)

    def test_rejected_candidate_advances_the_initial_design_group(self):
        settings = dict(self.config["optimizer"], initial_design=10, initial_candidate_pool_size=250)
        history = [{
            "id": 0,
            "parameter_hash": parameter_hash(self.baseline),
            "parameters": self.baseline,
            "score": 0.0,
            "score_error": 20.0,
            "promoted": True,
        }]

        _, first = suggest(
            self.baseline, self.parameters, history, settings, seed=3, radius=0.2,
        )
        _, after_rejection = suggest(
            self.baseline, self.parameters, history, settings, seed=3, radius=0.2,
            excluded_hashes={"synthetic-rejection"},
        )

        self.assertEqual(first["group"], "aspiration")
        self.assertEqual(after_rejection["group"], "futility")


class StatisticalTests(unittest.TestCase):
    def test_aggregates_confidence_intervals_as_standard_errors(self):
        score, error = aggregate_evaluations([
            {"score": 10.0, "score_error": 19.6},
            {"score": 20.0, "score_error": 19.6},
        ])

        self.assertAlmostEqual(score, 15.0)
        self.assertAlmostEqual(error, 19.6 / 2**0.5)

    def test_promotion_accounts_for_both_measurement_errors(self):
        incumbent = {"score": 10.0, "score_error": 19.6}

        self.assertFalse(promotion_is_significant(20.0, 19.6, incumbent, 1.0))
        self.assertTrue(promotion_is_significant(25.0, 19.6, incumbent, 1.0))

    def test_confirmation_probability_rejects_a_noise_level_lead(self):
        incumbent = {"score": 57.14, "score_error": 19.81}
        evaluations = [{"score": 58.21, "score_error": 19.79}]

        probability = confirmation_success_probability(evaluations, incumbent, 1.5)

        self.assertLess(probability, 0.01)


class TournamentParsingTests(unittest.TestCase):
    def test_uses_final_complete_rating(self):
        summary = """Elo: -44.00 +/- 12.00, nElo: x
Games: 20, Wins: 1, Losses: 2
Elo: -31.25 +/- 8.50, nElo: x
Games: 40, Wins: 3, Losses: 4
"""
        self.assertEqual(
            parse_tournament_completion(summary, "", 40),
            (-31.25, 8.5, 40, "full"),
        )

    def test_rejects_incomplete_or_infinite_result(self):
        with self.assertRaises(TuningError):
            parse_tournament_completion("Elo: -1.0 +/- 2.0\nGames: 18, Wins: 1\n", "", 20)
        with self.assertRaises(TuningError):
            parse_tournament_completion("Elo: inf +/- nan\nGames: 20, Wins: 20\n", "", 20)

    def test_accepts_a_native_sprt_completion_before_the_game_limit(self):
        summary = "Elo: -42.0 +/- 25.0\nGames: 300, Wins: 100\n"
        raw = "SPRT ([-40.00, -15.00]) completed - H0 was accepted\n"

        self.assertEqual(
            parse_tournament_completion(summary, raw, 1000),
            (-42.0, 25.0, 300, "H0"),
        )

    def test_detects_an_upper_sprt_decision_for_continuation(self):
        summary = "Elo: 60.0 +/- 40.0\nGames: 200, Wins: 100\n"
        raw = "SPRT ([-40.00, -15.00]) completed - H1 was accepted\n"

        self.assertEqual(
            parse_tournament_completion(summary, raw, 1000),
            (60.0, 40.0, 200, "H1"),
        )


class WorkflowTests(unittest.TestCase):
    def make_runner(self, directory: Path, **changes) -> Runner:
        config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
        config.update(changes)
        config["output_root"] = directory.relative_to(ROOT).as_posix()
        config["optimizer"]["candidate_pool_size"] = 250
        config["optimizer"]["initial_candidate_pool_size"] = 250
        config["optimizer"]["acquisition_shortlist_size"] = 50
        config_path = directory / "config.json"
        directory.mkdir(parents=True, exist_ok=True)
        config_path.write_text(json.dumps(config), encoding="utf-8")
        return Runner(config_path)

    def test_experiment_changes_are_rejected_but_operational_changes_are_allowed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(directory)
            runner.initialize()

            allowed = copy.deepcopy(runner.config)
            allowed["iterations"] += 10
            allowed["progress_interval_games"] += 10
            allowed["optimizer"]["candidate_pool_size"] += 100
            (directory / "config.json").write_text(json.dumps(allowed), encoding="utf-8")
            allowed_runner = Runner(directory / "config.json")
            state = allowed_runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 0.0, 20.0)]
            state["best_id"] = 0
            allowed_runner.save(state)

            incompatible = copy.deepcopy(allowed)
            incompatible["paired_openings"] += 1
            (directory / "config.json").write_text(json.dumps(incompatible), encoding="utf-8")
            with self.assertRaisesRegex(TuningError, "incompatible"):
                Runner(directory / "config.json").initialize()

    def test_clean_archives_existing_run_and_restarts_from_current_baseline(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            parent = Path(temp)
            output = parent / "active"
            runner = self.make_runner(output)
            old_state = runner.initialize()
            old_state["history"] = [completed_record(0, old_state["baseline"], 0.0, 20.0)]
            old_state["best_id"] = 0
            runner.save(old_state)

            archived = runner._archive_output()
            self.assertIsNotNone(archived)
            self.assertFalse(output.exists())
            self.assertTrue((archived / "state.json").is_file())
            self.assertEqual(len(json.loads((archived / "state.json").read_text())["history"]), 1)

            fresh_state = runner.initialize()
            self.assertEqual(fresh_state["history"], [])
            self.assertIsNone(fresh_state["pending"])
            self.assertEqual(
                json.loads(runner.best_path.read_text()),
                json.loads((ROOT / runner.config["baseline"]).read_text()),
            )

    def test_clean_without_an_existing_run_is_a_noop(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            parent = Path(temp)
            output = parent / "active"
            config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text())
            config["output_root"] = output.relative_to(ROOT).as_posix()
            config_path = parent / "config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            runner = Runner(config_path)

            self.assertIsNone(runner._archive_output())

    def test_run_lock_rejects_a_second_writer(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            lock_path = Path(temp) / "run.lock"
            with RunLock(lock_path):
                with self.assertRaisesRegex(TuningError, "another tuner"):
                    with RunLock(lock_path):
                        pass

    def test_state_schema_rejects_an_incomplete_tournament_record(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp))
            state = runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 0.0, 20.0)]
            state["history"][0]["evaluations"][0].pop("completion")
            state["best_id"] = 0
            runner.save(state)

            with self.assertRaisesRegex(TuningError, "invalid tournament result"):
                runner.initialize()

    def test_status_does_not_reset_an_incompatible_empty_experiment(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(directory)
            runner.initialize()
            before = runner.state_path.read_bytes()
            changed = copy.deepcopy(runner.config)
            changed["paired_openings"] += 1
            (directory / "config.json").write_text(json.dumps(changed), encoding="utf-8")

            with self.assertRaisesRegex(TuningError, "incompatible"):
                Runner(directory / "config.json").status()

            self.assertEqual(runner.state_path.read_bytes(), before)

    def test_dry_run_performs_preflight(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp))

            with mock.patch.object(runner, "preflight") as preflight:
                runner._run_locked(True)

            preflight.assert_called_once_with()

    def test_resume_from_flash_skips_synthesis_and_completes_trial(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=1)
            state = runner.initialize()
            pending = runner._new_trial(state)
            pending["phase"] = "flash"
            runner.save(state)
            commands = []

            def record_command(command, *_args, **_kwargs):
                commands.append(command)
                return ""

            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", side_effect=record_command), \
                    mock.patch.object(
                        runner, "_run_tournament",
                        return_value=(12.0, 19.6, Path(temp), 1000, "full"),
                    ):
                runner._run_locked(False)

            finished = json.loads(runner.state_path.read_text(encoding="utf-8"))
            self.assertEqual(len(commands), 1)
            self.assertIn("flash", commands[0])
            self.assertEqual(finished["history"][0]["score"], 12.0)
            self.assertTrue(finished["history"][0]["promoted"])
            self.assertIsNone(finished["pending"])

    def test_apparent_improvement_is_confirmed_before_promotion(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [completed_record(0, baseline, 10.0, 19.6)]
            state["best_id"] = 0
            pending = runner._new_trial(state)
            pending["phase"] = "tournament"
            runner.save(state)

            results = [
                (20.0, 19.6, Path(temp) / "first", 1000, "full"),
                (40.0, 19.6, Path(temp) / "confirmation", 1000, "full"),
            ]
            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_tournament", side_effect=results) as tournament:
                runner._run_locked(False)

            finished = json.loads(runner.state_path.read_text(encoding="utf-8"))
            record = finished["history"][-1]
            self.assertEqual(tournament.call_count, 2)
            self.assertAlmostEqual(record["score"], 30.0)
            self.assertAlmostEqual(record["score_error"], 19.6 / 2**0.5)
            self.assertTrue(record["promoted"])
            self.assertEqual(finished["best_id"], 1)

    def test_resume_does_not_start_a_confirmation_that_cannot_change_promotion(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [completed_record(0, baseline, 57.14, 19.81)]
            state["best_id"] = 0
            pending = runner._new_trial(state)
            pending["phase"] = "tournament"
            pending["evaluations"] = [{
                "score": 58.21, "score_error": 19.79, "games": 1000,
                "completion": "full", "tournament_dir": "first",
            }]
            pending["tournament_dirs"] = ["first"]
            runner.save(state)

            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_tournament") as tournament:
                runner._run_locked(False)

            finished = json.loads(runner.state_path.read_text(encoding="utf-8"))
            record = finished["history"][-1]
            tournament.assert_not_called()
            self.assertFalse(record["promoted"])
            self.assertEqual(record["tournament_dirs"], ["first"])

    def test_failed_phase_remains_pending_for_retry(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=1)
            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", side_effect=TuningError("synthetic failure")):
                with self.assertRaisesRegex(TuningError, "synthetic failure"):
                    runner._run_locked(False)

            state = json.loads(runner.state_path.read_text(encoding="utf-8"))
            self.assertEqual(state["pending"]["phase"], "synthesis")
            self.assertEqual(state["history"], [])

    def test_failed_candidate_is_rejected_without_an_elo_observation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(
                Path(temp), iterations=2, maximum_synthesis_rejections=1,
            )
            state = runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 0.0, 20.0)]
            state["best_id"] = 0
            runner.save(state)

            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", side_effect=TuningError("failed")), \
                    self.assertRaisesRegex(TuningError, "maximum synthesis rejections"):
                runner._run_locked(False)

            saved = json.loads(runner.state_path.read_text(encoding="utf-8"))
            self.assertEqual(len(saved["history"]), 1)
            self.assertEqual(len(saved["rejections"]), 1)
            self.assertNotIn("score", saved["rejections"][0])
            self.assertIsNone(saved["pending"])

    def test_synthesis_retries_with_the_next_seed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 0.0, 20.0)]
            state["best_id"] = 0
            runner.save(state)
            commands = []

            def run_phase(command, *_args, **_kwargs):
                commands.append(command)
                if "synth" in command and command[command.index("--seed") + 1] == "1":
                    raise TuningError("seed 1 failed")
                return ""

            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", side_effect=run_phase), \
                    mock.patch.object(
                        runner, "_run_tournament",
                        return_value=(5.0, 20.0, Path(temp), 1000, "full"),
                    ):
                runner._run_locked(False)

            synth_commands = [command for command in commands if "synth" in command]
            self.assertEqual([command[command.index("--seed") + 1] for command in synth_commands], ["1", "2"])
            saved = json.loads(runner.state_path.read_text(encoding="utf-8"))
            self.assertEqual(len(saved["history"]), 2)
            self.assertEqual(saved["rejections"], [])

    def test_interrupted_tournament_is_discovered_and_resumed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(
                directory, iterations=1,
                benchmark_results_root=directory.relative_to(ROOT).as_posix(),
            )
            state = runner.initialize()
            pending = runner._new_trial(state)
            pending["phase"] = "tournament"
            runner.save(state)
            label = (
                f"search-tune-{state['run_id']}-0000-"
                f"{pending['parameter_hash'][:8]}-s1-r0"
            )
            tournament_dir = directory / f"{label}-20260913-120000"
            tournament_dir.mkdir()
            (tournament_dir / "summary.txt").write_text(
                "Elo: 1.0 +/- 2.0\nGames: 20, Wins: 1\n", encoding="utf-8"
            )
            captured = {}

            def complete_resume(command, _log, _inspect, _progress, environment):
                captured["command"] = command
                captured["opening_start"] = environment["OPENING_START"]
                (tournament_dir / "summary.txt").write_text(
                    "Elo: 12.0 +/- 19.6\nGames: 1000, Wins: 400\n", encoding="utf-8"
                )
                return ""

            with mock.patch.object(runner, "_run_logged", side_effect=complete_resume):
                score, error, result, games, completion = runner._run_tournament(state, pending)

            self.assertEqual((score, error), (12.0, 19.6))
            self.assertEqual(result, tournament_dir)
            self.assertEqual((games, completion), (1000, "full"))
            self.assertIn("--resume", captured["command"])
            self.assertEqual(captured["opening_start"], "1")
            self.assertEqual(pending["tournament_dirs"], [str(tournament_dir)])

    def test_h1_checkpoint_continues_the_same_match_without_sprt(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(
                directory, iterations=1,
                benchmark_results_root=directory.relative_to(ROOT).as_posix(),
            )
            state = runner.initialize()
            pending = runner._new_trial(state)
            pending["phase"] = "tournament"
            runner.save(state)
            label = (
                f"search-tune-{state['run_id']}-0000-"
                f"{pending['parameter_hash'][:8]}-s1-r0"
            )
            tournament_dir = directory / f"{label}-20260913-120000"
            tournament_dir.mkdir()
            (tournament_dir / "summary.txt").write_text(
                "Elo: 60.0 +/- 40.0\nGames: 200, Wins: 100\n", encoding="utf-8"
            )
            (tournament_dir / "raw-output.txt").write_text(
                "SPRT ([-40.00, -15.00]) completed - H1 was accepted\n", encoding="utf-8"
            )
            (tournament_dir / "state.json").write_text(
                json.dumps({"sprt": {"enabled": True}}), encoding="utf-8"
            )

            def complete_resume(*_args, **_kwargs):
                (tournament_dir / "summary.txt").write_text(
                    "Elo: 30.0 +/- 20.0\nGames: 1000, Wins: 500\n", encoding="utf-8"
                )
                return ""

            output = io.StringIO()
            with mock.patch.object(runner, "_run_logged", side_effect=complete_resume) as resumed, \
                    redirect_stdout(output):
                result = runner._run_tournament(state, pending)

            saved = json.loads((tournament_dir / "state.json").read_text(encoding="utf-8"))
            self.assertEqual(result[:2], (30.0, 20.0))
            self.assertEqual(result[3:], (1000, "full"))
            self.assertEqual(resumed.call_count, 1)
            self.assertFalse(saved["sprt"]["enabled"])
            self.assertEqual(output.getvalue().count("Futility upper bound cleared"), 1)

    def test_sprt_bounds_use_the_conservative_best_and_skip_confirmations(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            state["history"] = [{"score": 70.0, "score_error": 20.0}]
            state["best_id"] = 0

            first = runner._sprt_environment(state, repeat=0)
            confirmation = runner._sprt_environment(state, repeat=1)

            self.assertEqual(float(first["SPRT_ELO0"]), 10.0)
            self.assertEqual(float(first["SPRT_ELO1"]), 35.0)
            self.assertEqual(float(first["SPRT_ALPHA"]), 0.1)
            self.assertEqual(first["SPRT_BETA"], "0.02")
            self.assertNotIn("SPRT_ELO0", confirmation)
            self.assertEqual(confirmation["OPENING_START"], "501")

    def test_h0_is_stored_as_a_conservative_censored_observation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            state["history"] = [{"score": 70.0, "score_error": 20.0}]
            state["best_id"] = 0

            record = runner._evaluation_record(
                state, score=-25.0, error=18.0, games=240,
                completion="H0", tournament=Path(temp),
            )

            self.assertEqual(record["score"], 10.0)
            self.assertEqual(record["raw_score"], -25.0)
            self.assertEqual(record["censored_upper_elo"], 10.0)
            self.assertGreaterEqual(record["score_error"], 25.0)

    def test_initial_design_does_not_shrink_the_trust_region(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=10)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [completed_record(0, baseline, 50.0, 20.0)]
            state["best_id"] = 0
            initial_radius = state["trust_region_radius"]

            for _ in range(4):
                pending = runner._new_trial(state)
                pending["evaluations"] = [{
                    "score": 0.0, "score_error": 20.0, "games": 1000,
                    "completion": "full", "tournament_dir": "synthetic",
                }]
                runner._finish_trial(state)

            self.assertEqual(state["trust_region_radius"], initial_radius)
            self.assertEqual((state["successes"], state["failures"]), (0, 0))


if __name__ == "__main__":
    unittest.main()
