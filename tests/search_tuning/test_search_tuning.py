import copy
import io
import json
import math
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.search_tuning.optimizer import posterior_rankings, suggest
from tools.search_tuning.space import (
    Parameter,
    configured_parameters,
    json_from_vector,
    parameter_hash,
    vector_from_json,
)
from tools.search_tuning.workflow import (
    RunLock,
    Runner,
    TuningError,
    aggregate_evaluations,
    experiment_snapshot,
    paired_elo_difference,
    parse_tournament_completion,
    validate_config,
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
    if isinstance(value, list) and not (prefix.endswith("_fraction") and len(value) == 2
            and all(isinstance(item, int) for item in value)):
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
        "tournament_dirs": ["synthetic"],
    }


def write_match_pgn(path: Path, scores: list[float]) -> None:
    """Write a minimal Fastchess-style PGN with deterministic opening keys."""
    games = []
    for index, score in enumerate(scores):
        fpga_white = index % 2 == 0
        if score == 0.5:
            result = "1/2-1/2"
        elif (score == 1.0) == fpga_white:
            result = "1-0"
        else:
            result = "0-1"
        games.append(
            f'[White "{"FPGA-test" if fpga_white else "Stockfish"}"]\n'
            f'[Black "{"Stockfish" if fpga_white else "FPGA-test"}"]\n'
            f'[Result "{result}"]\n'
            f'[FEN "8/8/8/8/8/8/8/K6k w - - 0 {index + 1}"]\n\n'
            f'{result}\n'
        )
    path.write_text("\n".join(games), encoding="utf-8")


class SearchSpaceTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
        self.baseline = json.loads((ROOT / "hardware/config/search/default.json").read_text(encoding="utf-8"))
        self.parameters = configured_parameters(self.config)

    def test_default_space_round_trips_every_search_leaf(self):
        vector = vector_from_json(self.baseline, self.parameters)

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

    def test_fraction_decoding_returns_independent_policy_values(self):
        """Mutating one decoded policy must not corrupt later proposals."""
        parameter = Parameter("fraction", 0.25, 0.75, "fraction", maximum_denominator=8)
        first = parameter.decode(0.5)
        expected = first.copy()
        first[0] = -1
        self.assertEqual(parameter.decode(0.5), expected)
        self.assertEqual(parameter.encode(expected), 0.5)

    def test_experiment_snapshot_ignores_populated_fraction_caches(self):
        """Reading a parameter's cached choices cannot change checkpoint identity."""
        parameters = [Parameter("fraction", 0.25, 0.75, "fraction")]
        with mock.patch("tools.search_tuning.workflow.hash_file", return_value="asset"), \
                mock.patch("tools.search_tuning.workflow.hash_source_tree", return_value="source"):
            before = json.dumps(experiment_snapshot(self.config, self.baseline, parameters), sort_keys=True)
            parameters[0].decode(0.5)
            after = experiment_snapshot(self.config, self.baseline, parameters)
        self.assertEqual(before, json.dumps(after, sort_keys=True))
        self.assertNotIn("fraction_values", after["parameters"][0])

    def test_startup_is_deterministic_unique_and_spans_parameter_groups(self):
        settings = dict(self.config["optimizer"], candidate_pool_size=250)
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
        self.assertEqual(details["method"], "random startup challenger")
        changed_groups = {key for key in self.baseline if first[key] != self.baseline[key]}
        self.assertGreater(len(changed_groups), 1)
        # Startup samples the configured ranges independently of the local radius.
        without_radius, _ = suggest(self.baseline, self.parameters, history, settings, seed=7, radius=0.0)
        self.assertEqual(first, without_radius)

    def test_gp_search_center_can_use_an_unpromoted_observation(self):
        alternative = copy.deepcopy(self.baseline)
        alternative["aspiration"]["starting_delta"] += 32
        settings = dict(
            self.config["optimizer"],
            candidate_pool_size=250,
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

        self.assertEqual(details["method"], "Gaussian-process expected improvement")
        self.assertEqual(details["center_id"], 1)
        self.assertGreater(details["center_posterior_stddev"], 0.0)

    def test_runtime_invalid_observations_are_excluded_from_the_gp(self):
        alternative = copy.deepcopy(self.baseline)
        alternative["aspiration"]["starting_delta"] += 32
        history = [
            completed_record(0, self.baseline, 10.0, 20.0),
            dict(completed_record(1, alternative, 500.0, 1.0), runtime_invalid=True),
        ]

        rankings = posterior_rankings(self.parameters, history, self.config["optimizer"])

        self.assertEqual([item["trial_id"] for item in rankings], [0])

    def test_full_posterior_scores_every_unique_untested_proposal(self):
        """All proposals receive full predictions, and the highest improvement wins."""
        alternative = copy.deepcopy(self.baseline)
        alternative["aspiration"]["starting_delta"] += 32
        history = [
            completed_record(0, self.baseline, 0.0, 20.0),
            completed_record(1, alternative, 10.0, 20.0),
        ]
        settings = dict(self.config["optimizer"], candidate_pool_size=250)
        # Equal uncertainty makes expected improvement increase with predicted Elo.
        model = mock.Mock(spec=["predict", "length"])
        model.length = 0.2
        model.predict.side_effect = lambda point: (sum(point), 1.0)
        with mock.patch("tools.search_tuning.optimizer.GaussianProcess", return_value=model):
            candidate, details = suggest(
                self.baseline, self.parameters, history, settings, seed=4, radius=0.2,
            )

        proposals = [call.args[0] for call in model.predict.call_args_list[len(history):]]
        self.assertGreater(len(proposals), 0)
        self.assertEqual(len(proposals), details["pool"])
        self.assertLessEqual(len(proposals), settings["candidate_pool_size"])
        self.assertEqual(len({tuple(point) for point in proposals}), len(proposals))
        tested = {tuple(vector_from_json(record["parameters"], self.parameters)) for record in history}
        self.assertTrue(tested.isdisjoint(tuple(point) for point in proposals))
        self.assertEqual(vector_from_json(candidate, self.parameters), max(proposals, key=sum))

    def test_rejected_startup_challenger_is_replaced_without_starting_gp(self):
        """A failed build is excluded without counting as the second observation."""
        settings = dict(self.config["optimizer"], candidate_pool_size=250)
        history = [completed_record(0, self.baseline, 0.0, 20.0)]
        first, _ = suggest(self.baseline, self.parameters, history, settings, seed=3, radius=0.2)

        with mock.patch("tools.search_tuning.optimizer.GaussianProcess") as model:
            replacement, details = suggest(
                self.baseline, self.parameters, history, settings, seed=3, radius=0.2,
                excluded_hashes={parameter_hash(first)},
            )

        model.assert_not_called()
        self.assertNotEqual(parameter_hash(replacement), parameter_hash(first))
        self.assertEqual(details["method"], "random startup challenger")

    def test_runtime_invalid_challenger_does_not_complete_startup(self):
        """The GP waits for a challenger with a usable strength measurement."""
        invalid = copy.deepcopy(self.baseline)
        invalid["aspiration"]["starting_delta"] += 32
        history = [
            completed_record(0, self.baseline, 0.0, 20.0),
            dict(completed_record(1, invalid, 500.0, 1.0), runtime_invalid=True),
        ]
        with mock.patch("tools.search_tuning.optimizer.GaussianProcess") as model:
            replacement, details = suggest(
                self.baseline, self.parameters, history, self.config["optimizer"], seed=3, radius=0.2,
            )

        model.assert_not_called()
        self.assertNotIn(parameter_hash(replacement), {record["parameter_hash"] for record in history})
        self.assertEqual(details["method"], "random startup challenger")


class StatisticalTests(unittest.TestCase):
    def test_aggregates_confidence_intervals_as_standard_errors(self):
        score, error = aggregate_evaluations([
            {"score": 10.0, "score_error": 19.6},
            {"score": 20.0, "score_error": 19.6},
        ])

        self.assertAlmostEqual(score, 15.0)
        self.assertAlmostEqual(error, 19.6 / 2**0.5)

    def test_paired_elo_uses_matching_game_covariance(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            baseline = directory / "baseline.pgn"
            candidate = directory / "candidate.pgn"
            write_match_pgn(baseline, [0.0, 0.5, 0.0, 0.5, 1.0, 0.0])
            write_match_pgn(candidate, [1.0, 0.5, 0.5, 1.0, 1.0, 0.5])

            result = paired_elo_difference([candidate], [baseline])

            self.assertEqual(result["games"], 6)
            self.assertGreater(result["elo_difference"], 0.0)
            self.assertGreater(result["probability_better"], 0.5)
            self.assertTrue(math.isfinite(result["elo_error"]))

            # Equal marginal results isolate the effect of matching game covariance.
            scores = [0.0, 0.5, 0.0, 0.5, 1.0, 0.0]
            write_match_pgn(candidate, scores)
            matched = paired_elo_difference([candidate], [baseline])
            write_match_pgn(candidate, list(reversed(scores)))
            shuffled = paired_elo_difference([candidate], [baseline])
            self.assertAlmostEqual(matched["elo_difference"], 0.0)
            self.assertAlmostEqual(shuffled["elo_difference"], 0.0)
            self.assertLess(matched["elo_error"], shuffled["elo_error"])


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

    def test_parses_early_sprt_decisions(self):
        """Recognize both stopping decisions, including unbounded H0 ratings."""
        cases = (
            (-42.0, 25.0, 300, "H0"),
            (-math.inf, math.nan, 104, "H0"),
            (60.0, 40.0, 200, "H1"),
        )
        for score, error, games, decision in cases:
            with self.subTest(decision=decision, score=score):
                summary = f"Elo: {score} +/- {error}\nGames: {games}, Wins: 0\n"
                raw = f"SPRT ([-40.00, -15.00]) completed - {decision} was accepted\n"
                actual_score, actual_error, actual_games, completion = parse_tournament_completion(summary, raw, 1000)
                self.assertEqual((actual_score, actual_games, completion), (score, games, decision))
                if math.isnan(error):
                    self.assertTrue(math.isnan(actual_error))
                else:
                    self.assertEqual(actual_error, error)


class WorkflowTests(unittest.TestCase):
    def test_opening_seeds_must_be_distinct_nonnegative_integers(self):
        """Both stages require explicit, distinct seeds for matched opening selection."""
        original = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
        for key in ("opening_seed", "validation_opening_seed"):
            for value in (None, True, -1, 1.5, "seed"):
                config = copy.deepcopy(original)
                config[key] = value
                with self.subTest(key=key, value=value), self.assertRaisesRegex(TuningError, key):
                    validate_config(config)
        config = copy.deepcopy(original)
        config["validation_opening_seed"] = config["opening_seed"]
        with self.assertRaisesRegex(TuningError, "must differ"):
            validate_config(config)

    def make_runner(self, directory: Path, **changes) -> Runner:
        config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
        config.update(changes)
        config["output_root"] = directory.relative_to(ROOT).as_posix()
        config["optimizer"]["candidate_pool_size"] = 250
        config["validation"]["maximum_finalists"] = 0
        config_path = directory / "config.json"
        directory.mkdir(parents=True, exist_ok=True)
        config_path.write_text(json.dumps(config), encoding="utf-8")
        return Runner(config_path)

    def test_rejects_limited_strength_stockfish_settings(self):
        """Old Elo controls must not silently change the shared benchmark semantics."""
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            config = json.loads((ROOT / "tools/search_tuning/default_config.json").read_text(encoding="utf-8"))
            config["stockfish_elo"] = 3000
            config_path = directory / "config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(TuningError, "full strength"):
                Runner(config_path)

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

            for key in ("paired_openings", "opening_seed", "validation_opening_seed"):
                incompatible = copy.deepcopy(allowed)
                incompatible[key] += max(allowed["opening_seed"], allowed["validation_opening_seed"]) + 1
                (directory / "config.json").write_text(json.dumps(incompatible), encoding="utf-8")
                with self.subTest(key=key), self.assertRaisesRegex(TuningError, "incompatible"):
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

            self.assertIsNone(runner._archive_output())
            fresh_state = runner.initialize()
            self.assertEqual(fresh_state["history"], [])
            self.assertIsNone(fresh_state["pending"])
            self.assertEqual(
                json.loads(runner.best_path.read_text()),
                json.loads((ROOT / runner.config["baseline"]).read_text()),
            )

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

    def test_dry_run_prepares_candidate_without_running_hardware(self):
        """Preview checkpoints a candidate while avoiding builds and tournaments."""
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp))

            with mock.patch.object(runner, "preflight") as preflight, \
                    mock.patch.object(runner, "_run_logged") as hardware, \
                    mock.patch.object(runner, "_run_tournament") as tournament:
                runner._run_locked(True)

            preflight.assert_called_once_with()
            hardware.assert_not_called()
            tournament.assert_not_called()
            saved = json.loads(runner.state_path.read_text(encoding="utf-8"))
            self.assertEqual(saved["pending"]["phase"], "synthesis")
            self.assertEqual(
                json.loads(runner.candidate_path.read_text(encoding="utf-8")),
                saved["pending"]["parameters"],
            )

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

    def test_apparent_improvement_remains_provisional_until_validation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [completed_record(0, baseline, 10.0, 19.6)]
            state["best_id"] = 0
            pending = runner._new_trial(state)
            pending["phase"] = "tournament"
            runner.save(state)

            results = [(20.0, 19.6, Path(temp) / "first", 1000, "full")]
            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", return_value=""), \
                    mock.patch.object(runner, "_run_tournament", side_effect=results) as tournament:
                runner._run_locked(False)

            finished = json.loads(runner.state_path.read_text(encoding="utf-8"))
            record = finished["history"][-1]
            self.assertEqual(tournament.call_count, 1)
            self.assertEqual(record["score"], 20.0)
            self.assertEqual(len(record["evaluations"]), 1)
            self.assertIsNone(finished["pending"])
            self.assertFalse(record["promoted"])
            self.assertEqual(finished["best_id"], 0)

    def test_validation_selects_diverse_posterior_leaders(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp))
            runner.config["validation"]["maximum_finalists"] = 2
            runner.config["validation"]["minimum_parameter_distance"] = 0.10
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [
                completed_record(index, baseline, 10.0 + index, 20.0, promoted=index == 0)
                for index in range(4)
            ]
            state["best_id"] = 0
            dimension = len(runner.parameters)
            rankings = [
                {"trial_id": 0, "posterior_elo": 0.0, "posterior_stddev": 1.0, "vector": [0.0] * dimension},
                {"trial_id": 1, "posterior_elo": 30.0, "posterior_stddev": 1.0, "vector": [0.0] * dimension},
                {"trial_id": 2, "posterior_elo": 29.0, "posterior_stddev": 1.0, "vector": [0.01] * dimension},
                {"trial_id": 3, "posterior_elo": 28.0, "posterior_stddev": 1.0, "vector": [0.5] * dimension},
            ]

            with mock.patch("tools.search_tuning.workflow.posterior_rankings", return_value=rankings):
                runner._select_validation_finalists(state)

            self.assertEqual(state["validation"]["finalist_ids"], [1, 3])

    def test_validation_schedules_baseline_before_finalist_on_each_block(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp))
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [
                completed_record(0, baseline, 10.0, 20.0),
                completed_record(1, baseline, 20.0, 20.0, promoted=False),
            ]
            state["best_id"] = 0
            state["validation"]["finalist_ids"] = [1]

            first = runner._next_validation_target(state)
            self.assertEqual((first["trial_id"], first["block"]), (0, 1))
            state["history"][0]["evaluations"].append(state["history"][0]["evaluations"][0].copy())
            state["history"][0]["tournament_dirs"].append("baseline-repeat")
            state["validation"]["active"] = None
            second = runner._next_validation_target(state)

            self.assertEqual((second["trial_id"], second["block"]), (1, 1))

    def test_paired_validation_promotes_and_writes_report(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(directory)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [
                completed_record(0, baseline, 10.0, 20.0),
                completed_record(1, baseline, 20.0, 20.0, promoted=False),
            ]
            state["best_id"] = 0
            baseline_run = directory / "baseline-validation"
            candidate_run = directory / "candidate-validation"
            baseline_run.mkdir()
            candidate_run.mkdir()
            write_match_pgn(baseline_run / "games.pgn", [1.0, 0.0, 0.5, 0.5] * 5)
            write_match_pgn(candidate_run / "games.pgn", [0.0, 1.0, 0.5, 0.5] * 4 + [0.0, 1.0, 0.5, 1.0])
            for record, run in zip(state["history"], (baseline_run, candidate_run), strict=True):
                record["evaluations"].append({
                    "score": record["score"], "score_error": 20.0, "games": 20,
                    "completion": "full", "tournament_dir": str(run),
                })
                record["tournament_dirs"].append(str(run))
            state["validation"].update({
                "finalist_ids": [1], "failed_ids": [], "active": None, "complete": False,
                "posterior": [{"trial_id": 1, "posterior_elo": 20.0, "posterior_stddev": 5.0}],
            })

            runner._finish_validation(state)

            self.assertEqual(state["best_id"], 1)
            self.assertTrue(state["validation"]["complete"])
            self.assertTrue(runner.report_path.is_file())
            self.assertTrue(runner.provisional_path.is_file())
            result = state["validation"]["results"][0]
            self.assertGreater(result["elo_difference"], 0.0)
            self.assertLess(result["elo_difference"], result["elo_error"])

    def test_validation_winner_depends_only_on_measured_elo(self):
        """A positive lead wins regardless of error; ties and losses retain the baseline."""
        cases = (
            ([(0.1, 100.0)], 1),
            ([(0.0, 100.0)], 0),
            ([(-0.1, 100.0)], 0),
            ([(6.0, 1.0), (10.0, 100.0)], 2),
        )
        for estimates, expected_id in cases:
            with self.subTest(estimates=estimates), tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
                runner = self.make_runner(Path(temp))
                state = runner.initialize()
                policies = [copy.deepcopy(state["baseline"]) for _ in range(len(estimates) + 1)]
                for index, policy in enumerate(policies):
                    policy["aspiration"]["starting_delta"] += index
                state["history"] = [
                    completed_record(index, policy, 0.0, 20.0, promoted=index == 0)
                    for index, policy in enumerate(policies)
                ]
                state["best_id"] = 0
                runner.best_path.write_text(json.dumps(policies[0]), encoding="utf-8")
                state["validation"]["finalist_ids"] = list(range(1, len(policies)))
                results = [
                    {"trial_id": index, "elo_difference": score, "elo_error": error}
                    for index, (score, error) in enumerate(estimates, start=1)
                ]

                with mock.patch.object(runner, "_paired_validation_result", side_effect=results):
                    runner._finish_validation(state)

                self.assertEqual(state["best_id"], expected_id)
                self.assertEqual(json.loads(runner.best_path.read_text(encoding="utf-8")), policies[expected_id])
                report = json.loads(runner.report_path.read_text(encoding="utf-8"))
                self.assertEqual(report["best_id"], expected_id)
                self.assertEqual(report["paired_results"], results)
                if expected_id:
                    self.assertTrue(state["history"][expected_id]["promoted"])
                    self.assertEqual(report["provisional_id"], expected_id)

    def test_resume_does_not_repeat_a_checkpointed_validation_result(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [
                completed_record(0, baseline, 10.0, 19.6),
                completed_record(1, baseline, 20.0, 19.6, promoted=False),
            ]
            state["history"][1]["evaluations"].append({
                "score": 40.0, "score_error": 19.6, "games": 1000,
                "completion": "full", "tournament_dir": "validation",
            })
            state["history"][1]["tournament_dirs"].append("validation")
            state["history"][1]["score"] = 30.0
            state["history"][1]["score_error"] = 19.6 / 2**0.5
            state["best_id"] = 0
            state["validation"] = {
                "finalist_ids": [1], "failed_ids": [], "complete": False,
                "active": {
                    "trial_id": 1, "block": 1, "phase": "tournament", "synthesis_seed_index": 0,
                },
            }
            runner.save(state)

            active = state["validation"]["active"]
            with mock.patch.object(runner, "_run_tournament") as tournament, \
                    mock.patch.object(runner, "_next_validation_target", side_effect=[active, None]):
                runner._run_validation(state)

            tournament.assert_not_called()
            self.assertIsNone(state["validation"]["active"])

    def test_resume_reuses_completed_exploration_with_validation_disabled(self):
        """Checkpointed games are reused even when the challenger narrowly leads."""
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

            seeds = [str(seed) for seed in runner.config["synthesis_seeds"]]

            def run_phase(command, *_args, **_kwargs):
                """Fail the first configured fitter seed to exercise retry selection."""
                commands.append(command)
                if "synth" in command and command[command.index("--seed") + 1] == seeds[0]:
                    raise TuningError("first seed failed")
                return ""

            with mock.patch.object(runner, "preflight"), \
                    mock.patch.object(runner, "_run_logged", side_effect=run_phase), \
                    mock.patch.object(
                        runner, "_run_tournament",
                        return_value=(5.0, 20.0, Path(temp), 1000, "full"),
                    ):
                runner._run_locked(False)

            synth_commands = [command for command in commands if "synth" in command]
            self.assertEqual([command[command.index("--seed") + 1] for command in synth_commands], seeds[:2])
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
            tournament_dir = directory / label
            tournament_dir.mkdir()
            (tournament_dir / "state.json").write_text("{}", encoding="utf-8")
            (tournament_dir / "summary.txt").write_text(
                "Elo: 1.0 +/- 2.0\nGames: 20, Wins: 1\n", encoding="utf-8"
            )
            captured = {}

            def complete_resume(run_dir, *, fastchess, output):
                captured["run_dir"] = run_dir
                captured["fastchess"] = fastchess
                (tournament_dir / "summary.txt").write_text(
                    "Elo: 12.0 +/- 19.6\nGames: 1000, Wins: 400\n", encoding="utf-8"
                )

            with mock.patch("tools.search_tuning.workflow.resume_tournament", side_effect=complete_resume):
                score, error, result, games, completion = runner._run_tournament(state, pending)

            self.assertEqual((score, error), (12.0, 19.6))
            self.assertEqual(result, tournament_dir)
            self.assertEqual((games, completion), (1000, "full"))
            self.assertEqual(captured["run_dir"], tournament_dir)
            self.assertEqual(pending["tournament_dirs"], [str(tournament_dir)])

    def test_tournaments_forward_match_settings_and_share_stage_seeds(self):
        """Match settings reach the benchmark, with a shared opening seed per stage."""
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(
                directory, opening_seed=17, validation_opening_seed=29, stockfish_nodes=1234,
                benchmark_results_root=directory.relative_to(ROOT).as_posix(),
            )
            state = runner.initialize()
            pending = runner._new_trial(state)
            captured = []

            def complete_match(config, *, output):
                captured.append(config)
                tournament = config.results_root / config.name
                tournament.mkdir()
                (tournament / "summary.txt").write_text(
                    f"Elo: 0.0 +/- 19.6\nGames: {2 * config.matches}, Wins: 400\n",
                    encoding="utf-8",
                )

            with mock.patch("tools.search_tuning.workflow.run_tournament", side_effect=complete_match):
                for repeat in range(3):
                    for trial_id in (0, 1):
                        context = dict(pending, id=trial_id, evaluations=[{}] * repeat, tournament_dirs=[])
                        result = runner._run_tournament(state, context)
                        self.assertEqual(result[:2], (0.0, 19.6))
                        self.assertEqual(result[3:], (2 * runner.config["paired_openings"], "full"))
                        self.assertEqual(captured[-1].stockfish_nodes, runner.config["stockfish_nodes"])
                        self.assertEqual(captured[-1].stockfish_hash_mb, runner.config["stockfish_hash_mb"])
                        self.assertIsNone(captured[-1].sprt_elo0)
                        self.assertEqual(result[2], captured[-1].results_root / captured[-1].name)
                        key = "validation_opening_seed" if repeat else "opening_seed"
                        self.assertEqual(captured[-1].opening_seed, runner.config[key])
                        self.assertEqual(captured[-1].opening_start, runner.config["opening_start"])

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
            tournament_dir = directory / label
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
            with mock.patch("tools.search_tuning.workflow.resume_tournament", side_effect=complete_resume) as resumed, \
                    redirect_stdout(output):
                result = runner._run_tournament(state, pending)

            saved = json.loads((tournament_dir / "state.json").read_text(encoding="utf-8"))
            self.assertEqual(result[:2], (30.0, 20.0))
            self.assertEqual(result[3:], (1000, "full"))
            self.assertEqual(resumed.call_count, 1)
            self.assertFalse(saved["sprt"]["enabled"])
            self.assertEqual(output.getvalue().count("Futility upper bound cleared"), 1)

    def test_sprt_bounds_use_the_conservative_best_and_skip_validation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            state["history"] = [{"score": 70.0, "score_error": 20.0}]
            state["best_id"] = 0

            first = runner._sprt_environment(state, repeat=0)
            validation = runner._sprt_environment(state, repeat=1)

            early = runner.config["early_stopping"]
            self.assertEqual(float(first["SPRT_ELO0"]), 50.0 - early["reject_margin_elo"])
            self.assertEqual(float(first["SPRT_ELO1"]), 50.0 - early["competitive_margin_elo"])
            self.assertEqual(float(first["SPRT_ALPHA"]), early["alpha"])
            self.assertEqual(float(first["SPRT_BETA"]), early["beta"])
            self.assertNotIn("SPRT_ELO0", validation)
            self.assertEqual(validation["OPENING_START"], first["OPENING_START"])

    def test_h0_results_are_finite_censored_observations(self):
        """An early rejection preserves raw evidence while storing finite model inputs."""
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=2)
            state = runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 70.0, 20.0)]
            state["best_id"] = 0
            bounds = runner._sprt_environment(state, repeat=0)
            upper_elo = float(bounds["SPRT_ELO0"])
            bound_width = float(bounds["SPRT_ELO1"]) - upper_elo

            for score, error in ((-25.0, 18.0), (-math.inf, math.nan)):
                with self.subTest(score=score):
                    record = runner._evaluation_record(
                        state, score=score, error=error, games=240,
                        completion="H0", tournament=Path(temp),
                    )
                    self.assertEqual(record["score"], upper_elo)
                    self.assertEqual(record["censored_upper_elo"], upper_elo)
                    self.assertTrue(math.isfinite(record["score_error"]))
                    self.assertGreaterEqual(record["score_error"], bound_width)
                    if math.isfinite(score):
                        self.assertEqual(record["raw_score"], score)
                        self.assertEqual(record["raw_score_error"], error)
                    else:
                        self.assertEqual(record["raw_score_unbounded"], "negative")

    def test_excessive_runtime_failures_mark_an_evaluation_invalid(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            directory = Path(temp)
            runner = self.make_runner(directory, iterations=2)
            state = runner.initialize()
            state["history"] = [completed_record(0, state["baseline"], 56.43, 19.79)]
            state["best_id"] = 0
            (directory / "raw-output.txt").write_text(
                "Player: FPGA-test\n  Timeouts: 1\n  Crashed: 3\n", encoding="utf-8"
            )

            record = runner._evaluation_record(
                state, score=-20.0, error=20.0, games=100,
                completion="H0", tournament=directory,
            )

            self.assertEqual((record["timeouts"], record["crashes"]), (1, 3))
            self.assertTrue(record["runtime_invalid"])

    def test_only_startup_skips_trust_region_adaptation(self):
        """Adaptation begins with the first GP-selected challenger after startup."""
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=10)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [completed_record(0, baseline, 50.0, 20.0)]
            state["best_id"] = 0
            initial_radius = state["trust_region_radius"]

            pending = runner._new_trial(state)
            pending["evaluations"] = [{
                "score": 0.0, "score_error": 20.0, "games": 1000,
                "completion": "full", "tournament_dir": "synthetic",
            }]
            runner._finish_trial(state)

            self.assertEqual(state["trust_region_radius"], initial_radius)
            self.assertEqual((state["successes"], state["failures"]), (0, 0))
            self.assertNotIn("optimizer_improvement_probability", state["history"][-1])

            pending = runner._new_trial(state)
            self.assertIn("center_id", pending["acquisition"])
            pending["evaluations"] = [{
                "score": -50.0, "score_error": 20.0, "games": 1000,
                "completion": "full", "tournament_dir": "synthetic",
            }]
            runner._finish_trial(state)
            self.assertIn("optimizer_improvement_probability", state["history"][-1])

    def test_ambiguous_gp_result_preserves_trust_region_evidence(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "work") as temp:
            runner = self.make_runner(Path(temp), iterations=12)
            state = runner.initialize()
            baseline = state["baseline"]
            state["history"] = [
                completed_record(identifier, baseline, 50.0, 20.0)
                for identifier in range(10)
            ]
            state["best_id"] = 0
            state["successes"] = 1
            state["failures"] = 0
            state["pending"] = {
                "id": 10,
                "parameter_hash": parameter_hash(baseline),
                "parameters": baseline,
                "snapshot": "synthetic",
                "acquisition": {
                    "center_id": 0,
                    "center_posterior_elo": 50.0,
                    "center_posterior_stddev": 10.0,
                },
                "evaluations": [{
                    "score": 50.0, "score_error": 20.0, "games": 1000,
                    "completion": "full", "tournament_dir": "synthetic",
                }],
                "tournament_dirs": ["synthetic"],
                "started_at": "synthetic",
            }

            runner._finish_trial(state)

            probability = state["history"][-1]["optimizer_improvement_probability"]
            self.assertGreater(probability, runner.config["optimizer"]["trust_region_failure_probability"])
            self.assertLess(probability, runner.config["optimizer"]["trust_region_success_probability"])
            self.assertEqual((state["successes"], state["failures"]), (1, 0))


if __name__ == "__main__":
    unittest.main()
