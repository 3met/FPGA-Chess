import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import chess
import torch

from tools.tuning.config import ConfigError, load_config
from tools.tuning.data import (
    BufferedShuffleSampler,
    build_cache,
    cache_datasets,
    encode_board,
    encode_fen,
    parse_record,
    select_evaluation,
)
from tools.tuning.engine import (
    commit_parameters,
    decompose,
    export_values,
    export_nnue,
    load_run_parameters,
    round_half_away,
    round_ties_to_even,
)
from tools.tuning.cli import main as tuning_main
from tools.tuning.model import (
    NNUE_ACCUMULATORS,
    NNUE_ENGINE_UNIT_CP,
    NNUE_MODEL_VERSION,
    NNUE_OUTPUT_INPUTS,
    PIECE_ORDER,
    EvaluationModel,
    engine_combined_cp,
)
from tools.tuning.reporting import atomic_json, print_report, resolve_run
from tools.tuning.training import _initialize_model, train


def filters(**overrides):
    values = {
        "remove_mates": True,
        "minimum_depth": 20,
        "max_evaluation_cp": 2000,
        "remove_in_check": False,
        "remove_captures": False,
        "remove_checks": False,
        "mate_score_cp": 30000,
    }
    values.update(overrides)
    return values


def record(cp=25, depth=30, line="e2e4 e7e5", fen=chess.STARTING_FEN):
    return {"fen": " ".join(fen.split()[:4]), "evals": [{"depth": depth, "pvs": [{"cp": cp, "line": line}]}]}


def config_for(directory: Path, dataset: Path, validation_size=2):
    return {
        "dataset": {
            "path": str(dataset), "max_positions": 6, "rebuild_cache": True,
            "num_workers": 1, "progress_interval_seconds": 60,
        },
        "filters": filters(),
        "training": {
            "seed": 7, "batch_size": 2, "validation_size": validation_size,
            "learning_rate": 0.001, "max_steps": 2, "optimizer": "adamw",
            "scheduler": "cosine", "minimum_learning_rate": 0.0001,
            "loss": "huber", "huber_delta": 100.0, "weight_decay": 0.0,
            "gradient_clip": 1000.0, "device": "cpu", "cpu_threads": 1,
            "shuffle_buffer": 3, "compile": False, "amp": False,
            "validation_interval_steps": 1, "checkpoint_interval_steps": 1,
            "early_stopping_patience": 2,
        },
        "output": {"root": str(directory / "work")},
        "wandb": {"enabled": False, "required": False, "project": "test", "entity": None, "mode": "disabled"},
        "_config_path": "test",
    }


class TuningDataTests(unittest.TestCase):
    def test_highest_depth_and_first_pv_are_selected_with_stable_ties(self):
        item = record()
        item["evals"] = [
            {"depth": 40, "pvs": [{"cp": 1, "line": "a2a3"}, {"cp": 2, "line": "a2a4"}]},
            {"depth": 40, "pvs": [{"cp": 3, "line": "b2b3"}]},
            {"depth": 30, "pvs": [{"cp": 4, "line": "c2c3"}]},
        ]
        selected, pv = select_evaluation(item)
        self.assertEqual(selected["depth"], 40)
        self.assertEqual(pv["cp"], 1)

    def test_mate_depth_and_magnitude_filters(self):
        mate = record()
        mate["evals"][0]["pvs"][0] = {"mate": -3, "line": "e2e4"}
        self.assertEqual(parse_record(mate, filters())[1], "mate")
        sample, reason = parse_record(
            mate, filters(remove_mates=False, max_evaluation_cp=None, mate_score_cp=31000)
        )
        self.assertIsNone(reason)
        self.assertTrue(sample.white_to_move)
        self.assertEqual(sample.target_cp, -31000)
        self.assertEqual(parse_record(record(depth=10), filters())[1], "minimum_depth")
        self.assertEqual(parse_record(record(cp=2001), filters())[1], "evaluation_magnitude")

    def test_move_filters_and_malformed_records(self):
        capture_fen = "7k/8/8/8/8/8/r7/R6K w - -"
        self.assertEqual(
            parse_record(record(line="a1a2", fen=capture_fen), filters(remove_captures=True))[1],
            "capture",
        )
        next_capture = record(line="d7d5 e5d6")
        next_capture["fen"] = "7k/3p4/8/4P3/8/8/8/K7 b - -"
        self.assertIsNone(parse_record(next_capture, filters(remove_captures=True))[1])
        self.assertIsNone(parse_record(record(line="e2e4"), filters(remove_checks=True))[1])
        self.assertEqual(parse_record({}, filters())[1], "malformed")

    def test_standard_position_and_quiet_filters(self):
        self.assertEqual(
            parse_record(record(line=""), filters())[1],
            "missing_pv_move",
        )
        self.assertEqual(
            parse_record(record(fen="8/8/8/8/8/8/8/K7 w - -"), filters())[1],
            "invalid_position",
        )
        in_check = "4k3/8/8/8/8/8/4r3/4K3 w - -"
        self.assertEqual(
            parse_record(record(line="e1f1", fen=in_check), filters(remove_in_check=True))[1],
            "in_check",
        )
        selected_check = "4k3/8/8/8/8/8/R7/4K3 w - -"
        self.assertEqual(
            parse_record(
                record(line="a2e2 e8f8", fen=selected_check),
                filters(remove_checks=True),
            )[1],
            "check",
        )

    def test_zero_knowledge_initialization(self):
        model = EvaluationModel()
        self.assertEqual(model.material_cp().tolist(), [100.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        self.assertTrue(torch.equal(model.pst_cp(), torch.zeros((6, 64))))

    def test_orientation_and_white_relative_signs(self):
        board = chess.Board("8/8/8/8/8/8/p7/N6k w - -")
        codes = encode_board(board)
        white_knight_a1 = 64 + chess.A1 + 1
        black_pawn_a2_mirrored = -(chess.A7 + 1)
        self.assertIn(white_knight_a1, codes)
        self.assertIn(black_pawn_a2_mirrored, codes)
        self.assertEqual(codes, encode_fen("8/8/8/8/8/8/p7/N6k w - -"))

    def test_cache_is_deterministic_and_sampler_is_bounded_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "positions.jsonl"
            source.write_text("".join(json.dumps(record(cp=value)) + "\n" for value in range(8)), encoding="utf-8")
            config = config_for(root, source)
            first = build_cache(config, print_fn=lambda _: None)
            first_bytes = (first / "records.bin").read_bytes()
            second = build_cache(config, print_fn=lambda _: None)
            self.assertEqual(first_bytes, (second / "records.bin").read_bytes())
            train_data, validation_data, metadata = cache_datasets(first)
            self.assertEqual((len(train_data), len(validation_data)), (4, 2))
            self.assertEqual(metadata["counts"]["read"], 6)
        first_order = list(BufferedShuffleSampler(20, 4, 3))
        second_order = list(BufferedShuffleSampler(20, 4, 3))
        self.assertEqual(first_order, second_order)
        self.assertEqual(sorted(first_order), list(range(20)))


class TuningModelAndExportTests(unittest.TestCase):
    def test_nnue_initialization_is_zero_output_but_has_live_gradients(self):
        model = EvaluationModel()
        codes = torch.tensor([encode_board(chess.Board(
            "4k3/8/8/8/8/8/P7/R3K3 w - -"
        ))], dtype=torch.int16)
        white_to_move = torch.tensor([True])
        correction = model.nnue_correction(codes, white_to_move)
        self.assertEqual(correction.item(), 0.0)
        correction.sub(50.0).square().backward()
        self.assertGreater(model.feature_weights.grad.abs().sum().item(), 0.0)
        self.assertGreater(model.accumulator_bias.grad.abs().sum().item(), 0.0)
        self.assertGreater(model.output_weights.grad.abs().sum().item(), 0.0)
        self.assertGreater(model.output_bias.grad.abs().item(), 0.0)

    def test_nnue_output_uses_hardware_score_units(self):
        model = EvaluationModel()
        with torch.no_grad():
            model.feature_weights.zero_()
            model.accumulator_bias.zero_()
            model.output_weights.zero_()
            model.output_weights[0] = 1
            model.feature_weights[8, 0] = 1
        codes = torch.tensor([
            encode_board(chess.Board("4k3/8/8/8/8/8/P7/4K3 w - -"))
        ], dtype=torch.int16)
        self.assertEqual(
            model.nnue_correction(codes, torch.tensor([True])).item(),
            NNUE_ENGINE_UNIT_CP,
        )

    def test_nnue_cpu_embedding_bag_matches_masked_reference(self):
        """The CPU-optimized reduction must retain the original masked sum."""
        model = EvaluationModel()
        codes = torch.tensor([
            encode_board(chess.Board()),
            encode_board(chess.Board("4k3/8/8/8/8/8/P7/4K3 w - -")),
        ], dtype=torch.int16)
        with torch.no_grad():
            rows = torch.arange(model.feature_weights.numel()).reshape_as(model.feature_weights)
            model.feature_weights.copy_((rows.remainder(3) - 1).to(torch.float32))
            model.accumulator_bias.copy_(torch.arange(NNUE_ACCUMULATORS).remainder(19) - 9)
            model.output_weights.copy_(torch.arange(NNUE_OUTPUT_INPUTS).remainder(17) - 8)
            model.output_bias.copy_(torch.tensor(7.0))
        indices, valid, _ = model.nnue_indices(codes)
        feature_weights = model._feature_int2(model.feature_weights)
        reference_accumulators = (feature_weights[indices] * valid.unsqueeze(-1)).sum(dim=2)
        reference_accumulators += model._accumulator_bias_int3(model.accumulator_bias)
        reference_accumulators = torch.remainder(reference_accumulators + 16, 32) - 16
        reference_activations = reference_accumulators.clamp(0, 7)
        white_to_move = torch.tensor([True, False])
        first = torch.where(
            white_to_move[:, None], reference_activations[:, 0], reference_activations[:, 1]
        )
        second = torch.where(
            white_to_move[:, None], reference_activations[:, 1], reference_activations[:, 0]
        )
        reference = (torch.cat((first, second), dim=1)
            * model._int3(model.output_weights)).sum(dim=1)
        reference += model._output_bias_int5(model.output_bias)
        reference = reference.clamp(-30999, 30999) * NNUE_ENGINE_UNIT_CP
        self.assertTrue(torch.equal(model.nnue_correction(codes, white_to_move), reference))

    def test_direct_nnue_indices_and_king_delta_match_full_accumulation(self):
        original = torch.tensor([encode_board(chess.Board(
            "4k3/8/8/8/8/8/P7/4K3 w - -"
        ))], dtype=torch.int16)
        original_indices, original_valid, _ = EvaluationModel.nnue_indices(original)
        self.assertEqual(
            sorted(original_indices[0, 0][original_valid[0, 0]].tolist()), [8, 324, 764]
        )
        self.assertEqual(
            sorted(original_indices[0, 1][original_valid[0, 1]].tolist()), [324, 432, 764]
        )

        moved = torch.tensor([encode_board(chess.Board(
            "4k3/8/8/8/8/8/P7/5K2 w - -"
        ))], dtype=torch.int16)
        moved_indices, moved_valid, _ = EvaluationModel.nnue_indices(moved)

        def row(index: int) -> torch.Tensor:
            lanes = torch.arange(NNUE_ACCUMULATORS, dtype=torch.int64)
            return ((index * 17 + lanes * 5) % 3 - 1).to(torch.int16)

        def full(indices: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
            accumulator = torch.ones(NNUE_ACCUMULATORS, dtype=torch.int16)
            for index in indices[valid].tolist():
                accumulator += row(index)
            return accumulator

        for perspective in range(2):
            old_features = set(original_indices[0, perspective][original_valid[0, perspective]].tolist())
            new_features = set(moved_indices[0, perspective][moved_valid[0, perspective]].tolist())
            self.assertEqual(len(old_features - new_features), 1)
            self.assertEqual(len(new_features - old_features), 1)
            incremental = (
                full(original_indices[0, perspective], original_valid[0, perspective])
                - row(next(iter(old_features - new_features)))
                + row(next(iter(new_features - old_features)))
            )
            self.assertTrue(torch.equal(
                incremental,
                full(moved_indices[0, perspective], moved_valid[0, perspective]),
            ))

    def test_nnue_export_packs_signed_two_bit_weights_output_and_safe_bias(self):
        parameters = {
            "nnue": {
                "feature_weights": [([-2, -1, 0, 1] * 32)] * 768,
                "accumulator_bias": [200.0] + [0.0] * (NNUE_ACCUMULATORS - 1),
                "output_units": "pawn/128",
                "output_weights": [0.0] * NNUE_OUTPUT_INPUTS,
                "output_bias": -3.0,
            }
        }
        parameters["nnue"]["output_weights"][0] = 1.0
        parameters["nnue"]["output_weights"][1] = 8.0
        features, outputs, output_bias, biases = export_nnue(parameters)
        self.assertEqual(len(features.splitlines()), 768)
        self.assertEqual(len(features.splitlines()[0]), 64)
        self.assertTrue(features.splitlines()[0].endswith("4e"))
        self.assertEqual(len(outputs.splitlines()), 2)
        self.assertTrue(all(len(row) == 96 for row in outputs.splitlines()))
        self.assertEqual(outputs.splitlines()[0][-2:], "19")
        self.assertEqual(output_bias, "1d\n")
        self.assertEqual(biases.splitlines()[0], "3")
        parameters["nnue"]["output_weights"][0:4] = [0.5, 1.5, 2.5, -0.5]
        parameters["nnue"]["accumulator_bias"][0:4] = [0.5, 1.5, 2.5, -0.5]
        _, tied_outputs, tied_output_bias, tied_biases = export_nnue(parameters)
        self.assertEqual(tied_outputs.splitlines()[0][-3:], "090")
        self.assertEqual(tied_biases.splitlines()[0:4], ["0", "2", "2", "0"])
        self.assertEqual(tied_output_bias, "1d\n")
        parameters["nnue"]["output_units"] = "centipawns"
        with self.assertRaises(ValueError):
            export_nnue(parameters)

    def test_nnue_correction_is_exactly_color_flip_invariant(self):
        model = EvaluationModel()
        with torch.no_grad():
            rows = torch.arange(model.feature_weights.numel()).reshape_as(model.feature_weights)
            model.feature_weights.copy_((rows.remainder(3) - 1).to(torch.float32))
            model.accumulator_bias.copy_(torch.arange(NNUE_ACCUMULATORS).remainder(8) - 4)
            model.output_weights.copy_(torch.arange(NNUE_OUTPUT_INPUTS).remainder(16) - 8)
            model.output_bias.copy_(torch.tensor(13.0))
        board = chess.Board("r3k2r/pp1n1ppp/2p1pn2/3p4/3P4/2N1PN2/PP3PPP/R3K2R w KQkq -")
        swapped = board.mirror()
        codes = torch.tensor([encode_board(board), encode_board(swapped)], dtype=torch.int16)
        white_to_move = torch.tensor([board.turn, swapped.turn])
        corrections = model.nnue_correction(codes, white_to_move)
        self.assertEqual(corrections[0].item(), corrections[1].item())
        white_relative = model(codes, white_to_move)
        stm_relative = torch.where(white_to_move, white_relative, -white_relative)
        self.assertEqual(stm_relative[0].item(), stm_relative[1].item())

    def test_old_nnue_checkpoint_is_rejected(self):
        model = EvaluationModel()
        old_state = dict(model.state_dict())
        with self.assertRaises(ValueError):
            _initialize_model(model, {
                "nnue_model_version": NNUE_MODEL_VERSION - 1,
                "model": old_state,
            })

    def test_model_matches_manual_current_engine_evaluation(self):
        weights = engine_combined_cp()
        model = EvaluationModel(weights)
        board = chess.Board("8/8/8/3p4/4N3/8/8/K6k w - -")
        codes = torch.tensor([encode_board(board)], dtype=torch.int16)
        prediction = model(codes, torch.tensor([True])).item()
        manual = 0.0
        for code in codes[0].tolist():
            if code:
                manual += (1 if code > 0 else -1) * weights[abs(code) - 1].item()
        self.assertAlmostEqual(prediction, manual, places=4)

    def test_model_has_identifiable_material_and_pst_groups(self):
        model = EvaluationModel(engine_combined_cp())
        self.assertEqual(set(model.terms), {"material", "pst"})
        self.assertEqual(model.material_cp()[0].item(), 100.0)
        self.assertEqual(model.material_cp()[5].item(), 0.0)
        pst = model.pst_cp().detach()
        self.assertTrue(torch.equal(pst[0, :8], torch.zeros(8)))
        self.assertTrue(torch.equal(pst[0, 56:], torch.zeros(8)))
        for piece_index in range(1, 6):
            self.assertAlmostEqual(
                (pst[piece_index].min() + pst[piece_index].max()).item(),
                0.0,
                places=4,
            )

    def test_rounding_and_integer_decomposition(self):
        self.assertEqual(round_half_away(1.5), 2)
        self.assertEqual(round_half_away(-1.5), -2)
        self.assertEqual(round_ties_to_even(0.5), 0)
        self.assertEqual(round_ties_to_even(-0.5), 0)
        self.assertEqual(round_ties_to_even(1.5), 2)
        self.assertEqual(round_ties_to_even(2.5), 2)
        tables = [[0.0] * 64 for _ in range(6)]
        tables[1][0], tables[1][1] = 0.0, 100.0 / 128.0
        material, pst = decompose(tables)
        self.assertEqual(material[1], 1)
        self.assertEqual((pst["knight"][0], pst["knight"][1]), (-1, 0))
        self.assertEqual(material[0], 128)
        self.assertEqual(material[5], 0)
        self.assertEqual(pst["pawn"][8], -128)
        self.assertEqual(pst["king"][0], 0)
        self.assertTrue(all(pst["pawn"][square] == 0 for square in (*range(8), *range(56, 64))))
        with self.assertRaises(ValueError):
            decompose([[100000.0] * 64 for _ in range(6)])

    def test_explicit_parameter_export_keeps_material_separate(self):
        parameters = {
            "material": {
                "pawn": 5.0, "knight": 301.0, "bishop": 321.0,
                "rook": 503.0, "queen": 901.0, "king": 17.0,
            },
            "pst": {piece: [0.0] * 64 for piece in PIECE_ORDER},
        }
        parameters["pst"]["knight"][0:2] = [-10.0, 10.0]
        material, pst = export_values(parameters)
        self.assertEqual(material[0], 128)
        self.assertEqual(material[1], round_half_away(301.0 * 128.0 / 100.0))
        self.assertEqual(material[5], 0)
        self.assertEqual(pst["knight"][0], -pst["knight"][1])

    def test_interrupted_run_recovers_its_best_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            model = EvaluationModel()
            torch.save({"model": model.state_dict(), "step": 11}, run / "best.pt")
            with self.assertRaisesRegex(ValueError, "does not match"):
                load_run_parameters(run)
            torch.save({
                "nnue_model_version": NNUE_MODEL_VERSION,
                "model": model.state_dict(),
                "step": 12,
            }, run / "best.pt")
            parameters, source = load_run_parameters(run)
            self.assertEqual(source, "best checkpoint")
            self.assertEqual(parameters["best_step"], 12)
            self.assertEqual(parameters["material"]["pawn"], 100.0)

    def test_dry_run_does_not_change_engine_files(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            weights = engine_combined_cp().reshape(6, 64).tolist()
            atomic_json(run / "parameters.json", {"combined_pst": weights})
            before = Path("hardware/rtl/defs.sv").read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                commit_parameters(run, dry_run=True)
            self.assertEqual(before, Path("hardware/rtl/defs.sv").read_bytes())

    def test_failed_generation_rolls_back_canonical_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            atomic_json(run / "parameters.json", {"combined_pst": [[100.0] * 64 for _ in range(6)]})
            pst_path = root / "pst.json"
            hex_path = root / "pst.hex"
            package_path = root / "pst.sv"
            material_path = root / "material.svh"
            pst_path.write_text(json.dumps({
                "material": {piece: 0 for piece in PIECE_ORDER},
                "pst": {piece: [0] * 64 for piece in PIECE_ORDER},
            }), encoding="utf-8")
            hex_path.write_text("old hex", encoding="utf-8")
            package_path.write_text("old package", encoding="utf-8")
            material_path.write_text("old material", encoding="utf-8")
            before = {path: path.read_bytes() for path in (pst_path, hex_path, package_path, material_path)}
            failed = mock.Mock(returncode=1, stdout="generation failed")
            with (
                mock.patch("tools.tuning.engine.PST_PATH", pst_path),
                mock.patch("tools.tuning.engine.GENERATED_PATHS", (hex_path, package_path, material_path)),
                mock.patch("tools.tuning.engine.subprocess.run", return_value=failed),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(RuntimeError):
                    commit_parameters(run)
            self.assertEqual(before, {path: path.read_bytes() for path in before})


class TuningTrainingAndReportTests(unittest.TestCase):
    def test_engine_commit_refuses_interrupted_latest_without_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "runs" / "interrupted"
            run.mkdir(parents=True)
            atomic_json(run / "report.json", {"status": "interrupted"})
            atomic_json(root / "latest.json", {"run": str(run)})
            config = {"output": {"root": str(root)}}
            with (
                mock.patch("tools.tuning.cli.load_config", return_value=config),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(tuning_main(["engine-commit", "--dry-run"]), 2)
            with (
                mock.patch("tools.tuning.cli.load_config", return_value=config),
                mock.patch("tools.tuning.cli.commit_parameters") as commit,
            ):
                self.assertEqual(
                    tuning_main(["engine-commit", "--run", "interrupted", "--dry-run"]),
                    0,
                )
            commit.assert_called_once_with(run.resolve(), True)

    def test_tiny_training_run_and_report_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "positions.jsonl"
            source.write_text("".join(json.dumps(record(cp=value * 10)) + "\n" for value in range(8)), encoding="utf-8")
            config = config_for(root, source)
            cache = build_cache(config, print_fn=lambda _: None)
            with contextlib.redirect_stdout(io.StringIO()):
                run = train(config, cache)
            report = json.loads((run / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "complete")
            self.assertTrue((run / "best.pt").exists())
            self.assertTrue((run / "parameters.json").exists())
            self.assertEqual(resolve_run(Path(config["output"]["root"]), None), run)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                print_report(run)
            self.assertIn("Status: complete", output.getvalue())
            self.assertIn("Material values (cp):", output.getvalue())
            self.assertIn("Normalized PST ranges (cp):", output.getvalue())
            config["training"]["max_steps"] = 4
            with contextlib.redirect_stdout(io.StringIO()):
                resumed = train(config, cache, resume_run=run)
            self.assertEqual(resumed, run)
            resumed_report = json.loads((run / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(resumed_report["step"], 4)

    def test_default_config_and_validation(self):
        config = load_config(None)
        self.assertTrue(Path(config["dataset"]["path"]).is_absolute())
        bad = json.loads(Path("tools/tuning/default_config.json").read_text(encoding="utf-8"))
        bad["training"]["batch_size"] = 0
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)
        bad["training"]["batch_size"] = 1
        bad["training"]["early_stopping_patience"] = 0
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)


if __name__ == "__main__":
    unittest.main()
