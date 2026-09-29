import contextlib
import io
import json
import random
import re
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

import chess
import torch

from tools.tuning.config import ConfigError, cache_key, load_config
from tools.tuning.data import (
    CacheBatchLoader,
    CacheDataset,
    Sample,
    _board_and_codes,
    _obvious_capture,
    _validation_group,
    build_cache,
    cache_datasets,
    encode_board,
    encode_fen,
    parse_record,
    select_evaluation,
)
from tools.tuning.engine import (
    commit_parameters,
    export_values,
    export_nnue,
    load_run_parameters,
    round_half_away,
    round_ties_to_even,
)
from tools.tuning.cli import main as tuning_main
from tools.tuning.model import (
    NNUE_ACCUMULATOR_BITS,
    NNUE_ACCUMULATOR_BIAS_MAX,
    NNUE_ACCUMULATORS,
    NNUE_ACTIVATION_MAX,
    NNUE_CLIPPED_ACCUMULATOR_MAX,
    NNUE_ENGINE_UNIT_CP,
    NNUE_MAX_ENGINE_UNITS,
    NNUE_OUTPUT_BUCKETS,
    NNUE_OUTPUT_BIAS_MAX,
    NNUE_OUTPUT_INPUTS,
    NNUE_OUTPUT_WEIGHT_MAX,
    NNUE_OUTPUT_WEIGHT_MIN,
    NNUE_SCRELU_TOP_CODE,
    PIECE_ORDER,
    _accumulator_overflow_penalty,
    _squared_clipped_activation,
    _wrap_accumulators,
    EvaluationModel,
    engine_combined_cp,
    nnue_output_bucket,
    pst_opening_phase,
)
from tools.tuning.quantization import (
    _parameter_stats,
    analyze_quantization,
    print_quantization_report,
    signed_bits,
)
from tools.tuning.reporting import atomic_json, print_report, resolve_run
from tools.tuning.training import (
    _initialize_model,
    _loss,
    _microbatches,
    _optimizer,
    _parameter_report,
    _repair_boundary_momentum,
    _scheduler,
    _score_probability,
    _training_objective,
    train,
)


def filters(**overrides):
    values = {
        "minimum_depth": 20,
        "max_evaluation_cp": 2000,
        "remove_in_check": False,
        "remove_captures": False,
        "remove_checks": False,
    }
    values.update(overrides)
    return values


def record(cp=25, depth=30, line="e2e4 e7e5", fen=chess.STARTING_FEN):
    return {"fen": " ".join(fen.split()[:4]), "evals": [{"depth": depth, "pvs": [{"cp": cp, "line": line}]}]}


def record_series(count: int, cp_scale: int = 1) -> list[dict]:
    """Create deterministic, distinct legal positions for cache tests."""
    rng = random.Random(19)
    board = chess.Board()
    records = []
    for index in range(count):
        move = list(board.legal_moves)[rng.randrange(board.legal_moves.count())]
        records.append(record(cp=index * cp_scale, line=move.uci(), fen=board.fen()))
        board.push(move)
        if board.is_game_over(claim_draw=False):
            board = chess.Board()
            for _ in range(index % 7):
                board.push(list(board.legal_moves)[rng.randrange(board.legal_moves.count())])
    return records


def config_for(directory: Path, dataset: Path, validation_size=2):
    return {
        "dataset": {
            "path": str(dataset), "max_positions": 6,
            "num_workers": 1, "progress_interval_seconds": 60,
        },
        "filters": filters(),
        "training": {
            "seed": 7, "batch_size": 2, "microbatch_size": 1,
            "validation_size": validation_size,
            "accumulator_overflow_penalty": 0.0001,
            "learning_rate": 0.001, "max_steps": 2,
            "cosine_final_factor": 0.1,
            "score_probability_offset": 270.0,
            "score_probability_scale": 380.0,
            "weight_decay": 0.00001,
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
    def test_cache_dataset_context_manager_closes_resources(self):
        dataset = CacheDataset(Path("unused"), 0, 0)
        with mock.patch.object(dataset, "close") as close:
            with dataset as opened:
                self.assertIs(opened, dataset)
        close.assert_called_once_with()

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
        self.assertEqual(parse_record(mate, filters(max_evaluation_cp=None))[1], "mate")
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

    def test_fast_capture_prefilter_only_rejects_real_ordinary_captures(self):
        """The cheap FEN probe must leave quiet moves and en passant to normal validation."""
        board = chess.Board()
        rng = random.Random(31)
        for _ in range(100):
            moves = list(board.legal_moves)
            move = moves[rng.randrange(len(moves))]
            if _obvious_capture(board.fen(), move.uci()):
                self.assertTrue(board.is_capture(move))
            board.push(move)
            if board.is_game_over(claim_draw=False):
                board.reset()
        en_passant = "7k/8/8/3pP3/8/8/8/K7 w - d6 0 1"
        self.assertFalse(_obvious_capture(en_passant, "e5d6"))
        self.assertEqual(
            parse_record(record(fen=en_passant, line="e5d6"), filters(remove_captures=True))[1],
            "capture",
        )

    def test_four_field_fen_fast_path_matches_python_chess(self):
        """Direct bitboard construction must preserve legal moves and encoded features."""
        board = chess.Board()
        rng = random.Random(53)
        for _ in range(120):
            fen = " ".join(board.fen().split()[:4])
            reference = chess.Board(fen)
            decoded, codes = _board_and_codes(fen)
            self.assertEqual(decoded.fen(), reference.fen())
            self.assertEqual(decoded.status(), reference.status())
            self.assertEqual(set(decoded.legal_moves), set(reference.legal_moves))
            self.assertEqual(codes, encode_fen(fen))
            board.push(rng.choice(list(board.legal_moves)))
            if board.is_game_over(claim_draw=False):
                board.reset()
        full_fen = "4k3/8/8/8/8/8/8/R3K3 w - - 150 1"
        decoded, codes = _board_and_codes(full_fen)
        self.assertIsNone(codes)
        self.assertEqual(decoded.fen(), chess.Board(full_fen).fen())
        with self.assertRaises(ValueError):
            _board_and_codes("116/8/8/8/8/8/8/K6k w - -")

    def test_standard_position_and_quiet_filters(self):
        self.assertEqual(
            parse_record(record(line=""), filters())[1],
            "missing_pv_move",
        )
        self.assertEqual(
            parse_record(record(fen="8/8/8/8/8/8/8/K7 w - -"), filters())[1],
            "invalid_position",
        )
        self.assertEqual(
            parse_record(record(fen="8/8/8/8/8/8/8/K6k w - -", line="a1a2"), filters())[1],
            "terminal_position",
        )
        seventyfive = record(line="a1a2")
        seventyfive["fen"] = "4k3/8/8/8/8/8/8/R3K3 w - - 150 1"
        self.assertEqual(parse_record(seventyfive, filters())[1], "terminal_position")
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
        self.assertTrue(torch.equal(model.pst_endgame_cp(), model.pst_cp()))

    def test_orientation_and_white_relative_signs(self):
        board = chess.Board("8/8/8/8/8/8/p7/N6k w - -")
        codes = encode_board(board)
        white_knight_a1 = 64 + chess.A1 + 1
        black_pawn_a2_mirrored = -(chess.A7 + 1)
        self.assertIn(white_knight_a1, codes)
        self.assertIn(black_pawn_a2_mirrored, codes)
        self.assertEqual(codes, encode_fen("8/8/8/8/8/8/p7/N6k w - -"))

    def test_validation_group_ties_color_flipped_positions_together(self):
        board = chess.Board("r3k2r/pp1n1ppp/2p1pn2/3p4/3P4/2N1PN2/PP3PPP/R3K2R w KQkq -")
        original, _ = parse_record(
            record(fen=board.fen(), line=next(iter(board.legal_moves)).uci()), filters()
        )
        flipped = board.mirror()
        mirrored, _ = parse_record(
            record(fen=flipped.fen(), line=next(iter(flipped.legal_moves)).uci()), filters()
        )
        self.assertEqual(_validation_group(original, 1_000_003), _validation_group(mirrored, 1_000_003))
        without_rights = board.copy()
        without_rights.castling_rights = chess.BB_EMPTY
        same_input, _ = parse_record(
            record(fen=without_rights.fen(), line=next(iter(without_rights.legal_moves)).uci()),
            filters(),
        )
        self.assertEqual(_validation_group(original, 1_000_003), _validation_group(same_input, 1_000_003))

    def test_validation_group_keeps_existing_hashes(self):
        """Sorting one perspective must not move positions between cache splits."""
        rng = random.Random(47)
        for _ in range(200):
            codes = tuple(rng.choices(range(-384, 385), k=32))
            white_to_move = bool(rng.randrange(2))
            direct = tuple(sorted(codes)) + (white_to_move,)
            flipped = tuple(sorted(-code for code in codes)) + (not white_to_move,)
            old = zlib.crc32(struct.pack("<32h?", *min(direct, flipped))) % 1_000_003
            sample = Sample(codes, white_to_move, 0.0)
            self.assertEqual(_validation_group(sample, 1_000_003), old)

    def test_cache_is_deterministic_and_rebuild_flag_does_not_change_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "positions.jsonl"
            source.write_text(
                "".join(json.dumps(item) + "\n" for item in record_series(64)),
                encoding="utf-8",
            )
            config = config_for(root, source)
            other_seed = json.loads(json.dumps(config))
            other_seed["training"]["seed"] += 1
            self.assertEqual(cache_key(config), cache_key(other_seed))
            first = build_cache(config, print_fn=lambda _: None)
            first_bytes = (first / "records.bin").read_bytes()
            second = build_cache(config, print_fn=lambda _: None, rebuild=True)
            self.assertEqual(first_bytes, (second / "records.bin").read_bytes())
            train_data, validation_data, metadata = cache_datasets(first)
            self.assertEqual((len(train_data), len(validation_data)), (4, 2))
            self.assertGreaterEqual(metadata["counts"]["read"], 6)
            self.assertEqual(metadata["split"], "model-visible color-flip symmetry class")

    def test_fixed_shuffle_randomizes_validation_reproducibly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "positions.jsonl"
            source.write_text(
                "".join(json.dumps(item) + "\n" for item in record_series(64)),
                encoding="utf-8",
            )
            config = config_for(root, source, validation_size=4)
            cache = build_cache(config, print_fn=lambda _: None)
            _train, validation, _metadata = cache_datasets(cache)
            loader = CacheBatchLoader(
                validation,
                batch_size=2,
                shuffle=True,
                seed=11,
                shuffle_buffer=2,
                reshuffle_each_iteration=False,
            )
            first = torch.cat([target for _codes, _stm, target in loader]).tolist()
            second = torch.cat([target for _codes, _stm, target in loader]).tolist()
            sequential = torch.cat([
                target for _codes, _stm, target in CacheBatchLoader(
                    validation,
                    batch_size=2,
                    shuffle=False,
                    seed=11,
                    shuffle_buffer=2,
                )
            ]).tolist()
            validation.close()
            self.assertEqual(first, second)
            self.assertNotEqual(first, sequential)


class TuningModelAndExportTests(unittest.TestCase):
    @staticmethod
    def parameter_document() -> dict:
        """Return a current-format material/PST document for export tests."""
        material = {piece: 0.0 for piece in PIECE_ORDER}
        material["pawn"] = 100.0
        pst = {piece: [0.0] * 64 for piece in PIECE_ORDER}
        model = EvaluationModel()
        return {
            "material": material,
            "pst": pst,
            "material_endgame": dict(material),
            "pst_endgame": {piece: list(table) for piece, table in pst.items()},
            "nnue": {
                "encoding": "relative-2x6x64",
                "output_units": "pawn/128",
                "output_buckets": model.output_buckets,
                "feature_weights": torch.zeros_like(model.feature_weights, dtype=torch.int8).tolist(),
                "accumulator_bias": torch.zeros_like(model.accumulator_bias).tolist(),
                "output_weights": torch.zeros_like(model.output_weights).tolist(),
                "output_bias": torch.zeros_like(model.output_bias).tolist(),
            },
        }

    @staticmethod
    def make_engine_outputs(root: Path) -> dict[str, Path]:
        """Create isolated sentinel files for every engine parameter output."""
        paths = {
            "pst": root / "pst.json",
            "pst_hex": root / "pst.hex",
            "material": root / "material.svh",
            "nnue_feature": root / "nnue-feature.hex",
            "nnue_output": root / "nnue-output.hex",
            "nnue_output_bias": root / "nnue-output-bias.hex",
            "nnue_bias": root / "nnue-bias.hex",
        }
        paths["pst"].write_text(json.dumps({
            "material": {piece: 0 for piece in PIECE_ORDER},
            "pst": {piece: [0] * 64 for piece in PIECE_ORDER},
        }), encoding="utf-8")
        for name, path in paths.items():
            if name != "pst":
                path.write_text(f"old {name}", encoding="utf-8")
        return paths

    def test_nnue_piece_count_bucket_boundaries(self):
        counts = (2, 5, 6, 9, 10, 13, 14, 17, 18, 21, 22, 25, 26, 29, 30, 32)
        codes = torch.zeros((len(counts), 32), dtype=torch.int16)
        for row, count in enumerate(counts):
            codes[row, :count] = 1
        self.assertEqual(
            nnue_output_bucket(codes).tolist(),
            [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
        )

    def test_qat_projection_keeps_latent_parameters_deployable(self):
        model = EvaluationModel()
        with torch.no_grad():
            model.feature_weights.fill_(100.0)
            model.accumulator_bias.fill_(-100.0)
            model.output_weights.fill_(100.0)
            model.output_bias.fill_(-100.0)
            model.project_parameters()
        self.assertEqual(model.feature_weights.unique().tolist(), [1.0])
        self.assertEqual(model.accumulator_bias.unique().tolist(), [0.0])
        self.assertEqual(model.output_weights.unique().tolist(), [float(NNUE_OUTPUT_WEIGHT_MAX)])
        self.assertEqual(model.output_bias.unique().tolist(), [0.0])
        with torch.no_grad():
            model.accumulator_bias.fill_(100.0)
            model.output_bias.fill_(float(NNUE_OUTPUT_BIAS_MAX + 1))
            model.project_parameters()
        self.assertEqual(model.accumulator_bias.unique().tolist(), [float(NNUE_ACCUMULATOR_BIAS_MAX)])
        self.assertEqual(model.output_bias.unique().tolist(), [float(NNUE_OUTPUT_BIAS_MAX)])

    def test_training_forward_penalizes_accumulator_overflow(self):
        model = EvaluationModel()
        codes = torch.tensor([encode_board(chess.Board())], dtype=torch.int16)
        white_to_move = torch.tensor([True])
        with torch.no_grad():
            model.feature_weights.fill_(-2.0)
            model.accumulator_bias.zero_()
        prediction, penalty = model(codes, white_to_move, True)
        self.assertEqual(prediction.shape, torch.Size([1]))
        self.assertGreater(penalty.item(), 0.0)
        penalty.backward()
        self.assertGreater(model.feature_weights.grad.abs().sum().item(), 0.0)

    def test_overflow_penalty_has_linear_tail_and_boundary_gradient(self):
        limit = 1 << (NNUE_ACCUMULATOR_BITS - 1)
        values = torch.tensor(
            [-limit - 2, -limit - 1, -limit, limit - 1, limit, limit + 1],
            dtype=torch.float32, requires_grad=True,
        )
        penalty = _accumulator_overflow_penalty(values)
        self.assertAlmostEqual(penalty.item(), 8 / values.numel())
        penalty.backward()
        expected = torch.tensor([-2, -2, 0, 0, 2, 2], dtype=torch.float32)
        torch.testing.assert_close(values.grad * values.numel(), expected)

    def test_floor_accumulator_wrap_matches_remainder_and_gradient(self):
        values = torch.arange(-96, 96, dtype=torch.float32, requires_grad=True)
        modulus = 1 << NNUE_ACCUMULATOR_BITS
        actual = _wrap_accumulators(values)
        reference = torch.remainder(values + modulus // 2, modulus) - modulus // 2
        torch.testing.assert_close(actual, reference, rtol=0, atol=0)
        actual.sum().backward()
        torch.testing.assert_close(values.grad, torch.ones_like(values))

    def test_screlu_codes_and_shadow_gradients(self):
        """The forward codes use integer division while QAT retains useful slopes."""
        values = torch.arange(-1, 32, dtype=torch.float32, requires_grad=True)
        actual = _squared_clipped_activation(values)
        expected = [0, 0, 0, 0, 1, 2, 3, 4, 6] + [7] * 24
        self.assertEqual(actual.tolist(), expected)
        actual.sum().backward()
        self.assertEqual(values.grad[2].item(), 0.25)
        self.assertEqual(values.grad[4].item(), 0.75)
        self.assertEqual(values.grad[9].item(), 0.0)
        self.assertEqual(values.grad[17].item(), 0.0)

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
        self.assertGreater(model.output_bias.grad.abs().sum().item(), 0.0)

    def test_nnue_output_uses_hardware_score_units(self):
        model = EvaluationModel()
        with torch.no_grad():
            model.feature_weights.zero_()
            model.accumulator_bias.fill_(2)
            model.output_weights.zero_()
            model.feature_weights[8, 0] = 1
        codes = torch.tensor([
            encode_board(chess.Board("4k3/8/8/8/8/8/P7/4K3 w - -"))
        ], dtype=torch.int16)
        with torch.no_grad():
            model.output_weights[nnue_output_bucket(codes)[0], 0] = 1
        self.assertEqual(
            model.nnue_correction(codes, torch.tensor([True])).item(),
            NNUE_ENGINE_UNIT_CP,
        )

    def test_screlu_bias_and_output_weight_use_target_codes(self):
        """The widened bias feeds a capped activation and a four-bit output weight."""
        model = EvaluationModel()
        with torch.no_grad():
            model.feature_weights.zero_()
            model.accumulator_bias.fill_(NNUE_ACCUMULATOR_BIAS_MAX)
            model.output_weights.zero_()
            model.output_weights[:, 0] = NNUE_OUTPUT_WEIGHT_MAX
        codes = torch.tensor([
            encode_board(chess.Board("4k3/8/8/8/8/8/P7/4K3 w - -"))
        ], dtype=torch.int16)
        correction = model.nnue_correction(codes, torch.tensor([True]))
        self.assertEqual(
            correction.item(),
            NNUE_SCRELU_TOP_CODE * NNUE_OUTPUT_WEIGHT_MAX * NNUE_ENGINE_UNIT_CP,
        )
        self.assertEqual(NNUE_CLIPPED_ACCUMULATOR_MAX, NNUE_ACCUMULATOR_BIAS_MAX)
        self.assertEqual(
            model._output_weight_quantized(torch.tensor([float(NNUE_OUTPUT_WEIGHT_MIN)])).item(),
            float(NNUE_OUTPUT_WEIGHT_MIN),
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
            model.accumulator_bias.copy_(
                torch.arange(NNUE_ACCUMULATORS).remainder(NNUE_ACCUMULATOR_BIAS_MAX + 1)
            )
            model.output_weights.copy_(
                torch.arange(model.output_weights.numel()).reshape_as(model.output_weights)
                    .remainder(17) - 8
            )
            model.output_bias.copy_(torch.arange(NNUE_OUTPUT_BUCKETS).remainder(7))
        indices, valid, _ = model.nnue_indices(codes)
        feature_weights = model._feature_int2(model.feature_weights)
        reference_accumulators = (feature_weights[indices] * valid.unsqueeze(-1)).sum(dim=2)
        reference_accumulators += model._accumulator_bias_quantized(model.accumulator_bias)
        modulus = 1 << NNUE_ACCUMULATOR_BITS
        reference_accumulators = torch.remainder(
            reference_accumulators + modulus // 2, modulus
        ) - modulus // 2
        reference_positive = reference_accumulators.clamp_min(0)
        reference_activations = (reference_positive.square() / 8).floor().clamp_max(
            NNUE_ACTIVATION_MAX
        )
        white_to_move = torch.tensor([True, False])
        first = torch.where(
            white_to_move[:, None], reference_activations[:, 0], reference_activations[:, 1]
        )
        second = torch.where(
            white_to_move[:, None], reference_activations[:, 1], reference_activations[:, 0]
        )
        buckets = nnue_output_bucket(codes)
        reference = (torch.cat((first, second), dim=1)
            * model._output_weight_quantized(model.output_weights)[buckets]).sum(dim=1)
        reference += model._output_bias_quantized(model.output_bias)[buckets]
        reference = reference.clamp(
            -NNUE_MAX_ENGINE_UNITS, NNUE_MAX_ENGINE_UNITS
        ) * NNUE_ENGINE_UNIT_CP
        self.assertTrue(torch.equal(model.nnue_correction(codes, white_to_move), reference))

    def test_zero_padded_material_lookup_has_zero_value_and_gradient(self):
        """Signed zero codes make the padding mask unnecessary in the PST path."""
        table_size = EvaluationModel().combined_cp().numel()
        codes = torch.tensor([[0, 1, -table_size]], dtype=torch.int16)
        first = torch.arange(table_size, dtype=torch.float32, requires_grad=True)
        second = first.detach().clone().requires_grad_()
        signs = codes.sign().to(torch.float32)
        without_mask = (first[codes.abs().long() - 1] * signs).sum()
        with_mask = (
            second[codes.abs().long().sub(1).clamp_min(0)]
            * signs * codes.ne(0)
        ).sum()
        self.assertEqual(without_mask.item(), with_mask.item())
        without_mask.backward()
        with_mask.backward()
        torch.testing.assert_close(first.grad, second.grad)

    def test_perspective_selection_matches_gather_gradient(self):
        """The cheaper two-way selection preserves both perspective gradients."""
        values = torch.arange(12, dtype=torch.float32).reshape(3, 2, 2)
        first = values.clone().requires_grad_()
        second = values.clone().requires_grad_()
        white_to_move = torch.tensor([True, False, True])
        selected = torch.cat((
            torch.where(white_to_move[:, None], first[:, 0], first[:, 1]),
            torch.where(white_to_move[:, None], first[:, 1], first[:, 0]),
        ), dim=1)
        order = torch.stack((~white_to_move, white_to_move), dim=1).long()
        gathered = second.gather(1, order[:, :, None].expand_as(second)).flatten(1)
        torch.testing.assert_close(selected, gathered)
        selected.square().sum().backward()
        gathered.square().sum().backward()
        torch.testing.assert_close(first.grad, second.grad)

    def test_nnue_code_lookup_matches_direct_feature_encoding(self):
        model = EvaluationModel()
        codes = torch.arange(-384, 385, dtype=torch.int16)[:, None]
        expected, _, _ = model.nnue_indices(codes)
        self.assertTrue(torch.equal(model._nnue_index_lut, expected[:, :, 0]))
        self.assertNotIn("_nnue_index_lut", model.state_dict())

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
                "feature_weights": [([-2, -1, 0, 1] * 64)] * 768,
                "accumulator_bias": [200.0] + [0.0] * (NNUE_ACCUMULATORS - 1),
                "output_units": "pawn/128",
                "output_buckets": NNUE_OUTPUT_BUCKETS,
                "output_weights": [
                    [0.0] * NNUE_OUTPUT_INPUTS for _ in range(NNUE_OUTPUT_BUCKETS)
                ],
                "output_bias": [float(NNUE_OUTPUT_BIAS_MAX + 1)] * NNUE_OUTPUT_BUCKETS,
            }
        }
        parameters["nnue"]["output_weights"][0][0] = 1.0
        parameters["nnue"]["output_weights"][0][1] = 8.0
        features, outputs, output_bias, biases = export_nnue(parameters)
        self.assertEqual(len(features.splitlines()), 768)
        self.assertEqual(len(features.splitlines()[0]), 128)
        self.assertTrue(features.splitlines()[0].endswith("4e"))
        self.assertEqual(len(outputs.splitlines()), 4 * NNUE_OUTPUT_BUCKETS)
        self.assertTrue(all(len(row) == 96 for row in outputs.splitlines()))
        self.assertEqual(outputs.splitlines()[0][-2:], "19")
        self.assertEqual(output_bias, f"{NNUE_OUTPUT_BIAS_MAX:02x}\n" * NNUE_OUTPUT_BUCKETS)
        self.assertEqual(biases.splitlines()[0], f"{NNUE_ACCUMULATOR_BIAS_MAX:x}")
        parameters["nnue"]["output_weights"][0][0:4] = [0.5, 1.5, 2.5, -0.5]
        parameters["nnue"]["accumulator_bias"][0:4] = [0.5, 1.5, 2.5, -0.5]
        parameters["nnue"]["output_bias"][0:4] = [0.5, 1.5, 2.5, -0.5]
        _, tied_outputs, tied_output_bias, tied_biases = export_nnue(parameters)
        self.assertEqual(tied_outputs.splitlines()[0][-3:], "090")
        self.assertEqual(tied_biases.splitlines()[0:4], ["0", "2", "2", "0"])
        self.assertEqual(tied_output_bias.splitlines()[:4], ["00", "02", "02", "00"])
        parameters["nnue"]["output_units"] = "centipawns"
        with self.assertRaises(ValueError):
            export_nnue(parameters)

    def test_nnue_correction_is_exactly_color_flip_invariant(self):
        model = EvaluationModel()
        with torch.no_grad():
            rows = torch.arange(model.feature_weights.numel()).reshape_as(model.feature_weights)
            model.feature_weights.copy_((rows.remainder(3) - 1).to(torch.float32))
            model.accumulator_bias.copy_(torch.arange(NNUE_ACCUMULATORS).remainder(8))
            model.output_weights.copy_(
                torch.arange(model.output_weights.numel()).reshape_as(model.output_weights)
                    .remainder(16) - 8
            )
            model.output_bias.copy_(torch.arange(NNUE_OUTPUT_BUCKETS).remainder(16))
        board = chess.Board("r3k2r/pp1n1ppp/2p1pn2/3p4/3P4/2N1PN2/PP3PPP/R3K2R w KQkq -")
        swapped = board.mirror()
        codes = torch.tensor([encode_board(board), encode_board(swapped)], dtype=torch.int16)
        white_to_move = torch.tensor([board.turn, swapped.turn])
        corrections = model.nnue_correction(codes, white_to_move)
        self.assertEqual(corrections[0].item(), corrections[1].item())
        white_relative = model(codes, white_to_move)
        stm_relative = torch.where(white_to_move, white_relative, -white_relative)
        self.assertEqual(stm_relative[0].item(), stm_relative[1].item())

    def test_incompatible_nnue_checkpoint_shape_is_rejected(self):
        model = EvaluationModel()
        old_state = dict(model.state_dict())
        old_state["output_weights"] = old_state["output_weights"][:1]
        with self.assertRaises(RuntimeError):
            _initialize_model(model, {"model": old_state})

    def test_warm_start_preserves_compatible_parameters(self):
        previous = EvaluationModel()
        with torch.no_grad():
            for bucket in range(NNUE_OUTPUT_BUCKETS):
                previous.output_weights[bucket].fill_(float(bucket % 4 - 2))
                previous.output_bias[bucket] = float(bucket)
        current = EvaluationModel()
        _initialize_model(current, {"model": previous.state_dict()})
        self.assertTrue(torch.equal(current.output_weights, previous.output_weights))
        self.assertTrue(torch.equal(current.output_bias, previous.output_bias))
        codes = torch.zeros((31, 32), dtype=torch.int16)
        for row, piece_count in enumerate(range(2, 33)):
            codes[row, :piece_count] = 1
        side_to_move = torch.ones(31, dtype=torch.bool)
        self.assertTrue(torch.equal(
            current.nnue_correction(codes, side_to_move),
            previous.nnue_correction(codes, side_to_move),
        ))

    def test_quantized_parameter_stats_expose_histogram_and_dynamic_range_use(self):
        stats = _parameter_stats(torch.tensor([-3.0, -2.0, 0.0, 1.0, 2.0]), -2, 1)
        self.assertEqual(stats["histogram"], {"-2": 2, "-1": 0, "0": 1, "1": 2})
        self.assertEqual(stats["saturated_values"], 2)
        self.assertEqual(stats["zero_fraction"], 0.2)
        self.assertEqual(stats["minimum_value_fraction"], 0.4)
        self.assertEqual(stats["maximum_value_fraction"], 0.4)
        bias_stats = _parameter_stats(
            torch.tensor([0.0, float(NNUE_ACCUMULATOR_BIAS_MAX)]),
            0, NNUE_ACCUMULATOR_BIAS_MAX, signed=False,
        )
        self.assertEqual(bias_stats["encoding"], "unsigned")
        self.assertEqual(bias_stats["minimum_bits"], NNUE_ACCUMULATOR_BIAS_MAX.bit_length())

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
        self.assertEqual(set(model.terms), {
            "material", "pst", "material_endgame", "pst_endgame",
        })
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

    def test_piece_count_interpolates_the_two_pst_sets(self):
        model = EvaluationModel()
        with torch.no_grad():
            model.terms["pst"][64] = 30.0
            model.terms["pst_endgame"][64] = -30.0
        for count, expected in ((2, -30.0), (17, 0.0), (32, 30.0)):
            codes = torch.zeros((1, 32), dtype=torch.int16)
            codes[0, 0] = 65
            codes[0, 1:count] = 321
            self.assertEqual(pst_opening_phase(codes).item(), count - 2)
            deployed = round_half_away(expected / NNUE_ENGINE_UNIT_CP) * NNUE_ENGINE_UNIT_CP
            self.assertAlmostEqual(model(codes, torch.tensor([True])).item(), deployed)

    def test_material_and_pst_quantize_separately_with_live_gradients(self):
        model = EvaluationModel()
        with torch.no_grad():
            for suffix in ("", "_endgame"):
                model.terms[f"material{suffix}"][0] = 1.0
                model.terms[f"pst{suffix}"][64] = 1.0
        codes = torch.tensor([[65, 321, -321] + [0] * 29], dtype=torch.int16)
        prediction = model(codes, torch.tensor([True]))
        self.assertEqual(prediction.item(), 2 * NNUE_ENGINE_UNIT_CP)
        prediction.backward()
        self.assertNotEqual(model.terms["material"].grad[0].item(), 0.0)
        self.assertNotEqual(model.terms["pst"].grad[64].item(), 0.0)

    def test_material_pst_rounding_matches_export_ties(self):
        values = torch.tensor([
            -1.5 * NNUE_ENGINE_UNIT_CP,
            -0.5 * NNUE_ENGINE_UNIT_CP,
            0.5 * NNUE_ENGINE_UNIT_CP,
            1.5 * NNUE_ENGINE_UNIT_CP,
        ])
        self.assertEqual(
            EvaluationModel._engine_units(values).tolist(),
            [round_half_away(float(value) / NNUE_ENGINE_UNIT_CP) for value in values],
        )

    def test_optimizer_clears_outward_momentum_at_quantized_bounds(self):
        model = EvaluationModel()
        optimizer = _optimizer(torch, model, {
            "learning_rate": 0.01, "weight_decay": 0.01,
        }, torch.device("cpu"))
        self.assertEqual(optimizer.param_groups[0]["weight_decay"], 0.01)
        self.assertEqual(optimizer.param_groups[1]["weight_decay"], 0.0)
        with torch.no_grad():
            model.feature_weights[0, :3] = torch.tensor([-2.0, 1.0, 0.0])
            model.accumulator_bias[:3] = torch.tensor([
                0.0, float(NNUE_ACCUMULATOR_BIAS_MAX), 1.0,
            ])
        moment = torch.zeros_like(model.feature_weights)
        moment[0, :3] = torch.tensor([1.0, -1.0, 1.0])
        optimizer.state[model.feature_weights]["exp_avg"] = moment
        bias_moment = torch.zeros_like(model.accumulator_bias)
        bias_moment[:3] = torch.tensor([1.0, -1.0, 1.0])
        optimizer.state[model.accumulator_bias]["exp_avg"] = bias_moment
        with torch.no_grad():
            model.output_bias[:3] = torch.tensor([0.0, float(NNUE_OUTPUT_BIAS_MAX), 1.0])
        output_bias_moment = torch.zeros_like(model.output_bias)
        output_bias_moment[:3] = torch.tensor([1.0, -1.0, 1.0])
        optimizer.state[model.output_bias]["exp_avg"] = output_bias_moment
        _repair_boundary_momentum(torch, model, optimizer)
        self.assertEqual(moment[0, :3].tolist(), [0.0, 0.0, 1.0])
        self.assertEqual(bias_moment[:3].tolist(), [0.0, 0.0, 1.0])
        self.assertEqual(output_bias_moment[:3].tolist(), [0.0, 0.0, 1.0])

    def test_rounding_and_export_range_validation(self):
        self.assertEqual(round_half_away(1.5), 2)
        self.assertEqual(round_half_away(-1.5), -2)
        self.assertEqual(round_ties_to_even(0.5), 0)
        self.assertEqual(round_ties_to_even(-0.5), 0)
        self.assertEqual(round_ties_to_even(1.5), 2)
        self.assertEqual(round_ties_to_even(2.5), 2)
        parameters = self.parameter_document()
        parameters["pst"]["knight"][0] = 100000.0
        with self.assertRaises(ValueError):
            export_values(parameters)

    def test_explicit_parameter_export_keeps_material_separate(self):
        parameters = {
            "material": {
                "pawn": 5.0, "knight": 301.0, "bishop": 321.0,
                "rook": 503.0, "queen": 901.0, "king": 17.0,
            },
            "pst": {piece: [0.0] * 64 for piece in PIECE_ORDER},
        }
        parameters["pst"]["knight"][0:2] = [-10.0, 10.0]
        parameters["material_endgame"] = dict(parameters["material"])
        parameters["pst_endgame"] = {
            piece: list(table) for piece, table in parameters["pst"].items()
        }
        material, pst = export_values(parameters)
        self.assertEqual(material[0], 128)
        self.assertEqual(material[1], round_half_away(301.0 * 128.0 / 100.0))
        self.assertEqual(material[5], 0)
        self.assertEqual(pst["knight"][0], -pst["knight"][1])
        endgame_material, endgame_pst = export_values(parameters, "_endgame")
        self.assertEqual(endgame_material, material)
        self.assertEqual(endgame_pst, pst)
        parameters["pst_endgame"]["knight"][0] = 7.0
        _, endgame_pst = export_values(parameters, "_endgame")
        self.assertEqual(endgame_pst["knight"][0], round_half_away(7.0 * 128.0 / 100.0))
        self.assertNotEqual(endgame_pst["knight"][0], pst["knight"][0])

    def test_interrupted_run_recovers_its_best_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            model = EvaluationModel()
            torch.save({"model": model.state_dict(), "step": 11}, run / "best.pt")
            parameters, source = load_run_parameters(run)
            self.assertEqual(source, "best checkpoint")
            self.assertEqual(parameters["best_step"], 11)
            self.assertEqual(parameters["material"]["pawn"], 100.0)

    def test_dry_run_does_not_change_engine_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            atomic_json(run / "parameters.json", self.parameter_document())
            paths = self.make_engine_outputs(root)
            before = {path: path.read_bytes() for path in paths.values()}
            with (
                mock.patch("tools.tuning.engine.PST_PATH", paths["pst"]),
                mock.patch("tools.tuning.engine.GENERATED_PATHS", (paths["pst_hex"], paths["material"])),
                mock.patch("tools.tuning.engine.NNUE_FEATURE_PATH", paths["nnue_feature"]),
                mock.patch("tools.tuning.engine.NNUE_OUTPUT_PATH", paths["nnue_output"]),
                mock.patch("tools.tuning.engine.NNUE_OUTPUT_BIAS_PATH", paths["nnue_output_bias"]),
                mock.patch("tools.tuning.engine.NNUE_BIAS_PATH", paths["nnue_bias"]),
                mock.patch("tools.tuning.engine.subprocess.run") as generate,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                commit_parameters(run, dry_run=True)
            self.assertEqual(before, {path: path.read_bytes() for path in paths.values()})
            generate.assert_not_called()

    def test_engine_commit_waits_for_matching_rtl(self):
        """A width mismatch must block ROM export before changing engine files."""
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            atomic_json(run / "parameters.json", self.parameter_document())
            with mock.patch("tools.tuning.engine.NNUE_OUTPUT_BIAS_BITS", 1):
                with self.assertRaisesRegex(RuntimeError, "update RTL"):
                    commit_parameters(run)

    def test_dry_run_rejects_missing_nnue_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            parameters = self.parameter_document()
            del parameters["nnue"]
            atomic_json(run / "parameters.json", parameters)
            with self.assertRaisesRegex(ValueError, "NNUE"):
                commit_parameters(run, dry_run=True)

    def test_failed_generation_rolls_back_canonical_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            atomic_json(run / "parameters.json", self.parameter_document())
            paths = self.make_engine_outputs(root)
            before = {path: path.read_bytes() for path in paths.values()}
            failed = mock.Mock(returncode=1, stdout="generation failed")
            with (
                mock.patch("tools.tuning.engine.PST_PATH", paths["pst"]),
                mock.patch("tools.tuning.engine.GENERATED_PATHS", (paths["pst_hex"], paths["material"])),
                mock.patch("tools.tuning.engine.NNUE_FEATURE_PATH", paths["nnue_feature"]),
                mock.patch("tools.tuning.engine.NNUE_OUTPUT_PATH", paths["nnue_output"]),
                mock.patch("tools.tuning.engine.NNUE_OUTPUT_BIAS_PATH", paths["nnue_output_bias"]),
                mock.patch("tools.tuning.engine.NNUE_BIAS_PATH", paths["nnue_bias"]),
                mock.patch("tools.tuning.engine._require_matching_rtl"),
                mock.patch("tools.tuning.engine.subprocess.run", return_value=failed),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(RuntimeError):
                    commit_parameters(run)
            self.assertEqual(before, {path: path.read_bytes() for path in paths.values()})


class TuningTrainingAndReportTests(unittest.TestCase):
    def test_running_report_separates_latest_and_selected_piece_values(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            selected = EvaluationModel()
            latest = EvaluationModel()
            with torch.no_grad():
                latest.terms["material"][0] = 10.0
            torch.save({
                "model": selected.state_dict(), "step": 0,
                "validation_loss": 0.01, "validation_mae": 20.0,
                "validation_rmse": 30.0,
            }, run / "best.pt")
            atomic_json(run / "report.json", {
                "status": "running", "step": 10, "max_steps": 20,
                "validation_loss": 0.02, "validation_mae": 21.0,
                "validation_rmse": 31.0,
                **_parameter_report(latest),
            })
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                print_report(run)
            self.assertIn("Selected checkpoint: step 0", output.getvalue())
            self.assertIn("Latest opening material", output.getvalue())
            self.assertIn("Selected opening material", output.getvalue())
            material_rows = [
                line for line in output.getvalue().splitlines()
                if "opening material" in line
            ]
            self.assertNotEqual(material_rows[0].split()[3:], material_rows[1].split()[3:])

    def test_score_probability_transform_and_loss_are_symmetric(self):
        values = torch.tensor([-1000.0, -270.0, 0.0, 270.0, 1000.0])
        transformed = _score_probability(values, 270.0, 380.0)
        self.assertAlmostEqual(transformed[2].item(), 0.5, places=7)
        self.assertTrue(torch.allclose(transformed + transformed.flip(0), torch.ones(5)))
        settings = {
            "score_probability_offset": 270.0,
            "score_probability_scale": 380.0,
        }
        self.assertEqual(_loss(values, values, settings).item(), 0.0)
        self.assertGreater(
            _loss(torch.zeros(1), torch.full((1,), 500.0), settings).item(),
            0.0,
        )

    def test_training_objective_matches_separate_forward_and_loss(self):
        model = EvaluationModel()
        codes = torch.tensor([encode_board(chess.Board())], dtype=torch.int16)
        white_to_move = torch.tensor([True])
        target = torch.tensor([30.0])
        settings = {
            "accumulator_overflow_penalty": 0.0001,
            "score_probability_offset": 270.0,
            "score_probability_scale": 380.0,
        }
        prediction, overflow = model(codes, white_to_move, True)
        data_loss = _loss(prediction, target, settings)
        total, actual_data, actual_overflow = _training_objective(
            model, codes, white_to_move, target, settings
        )
        torch.testing.assert_close(actual_data, data_loss)
        torch.testing.assert_close(actual_overflow, overflow)
        torch.testing.assert_close(total, data_loss + 0.0001 * overflow)

    def test_learning_rate_warms_up_then_cosine_decays_to_final_factor(self):
        parameter = torch.nn.Parameter(torch.zeros(()))
        optimizer = torch.optim.AdamW([parameter], lr=0.01)
        settings = {
            "max_steps": 100,
            "learning_rate": 0.01,
            "cosine_final_factor": 0.1,
        }
        scheduler = _scheduler(torch, optimizer, settings)
        self.assertAlmostEqual(optimizer.param_groups[0]["lr"], 0.001)
        for _ in range(2):
            optimizer.step()
            scheduler.step()
        self.assertAlmostEqual(optimizer.param_groups[0]["lr"], 0.01)
        for _ in range(98):
            optimizer.step()
            scheduler.step()
        self.assertAlmostEqual(optimizer.param_groups[0]["lr"], 0.001, places=9)

    def test_auto_microbatching_uses_cpu_cache_sized_chunks(self):
        codes = torch.zeros((5000, 32), dtype=torch.int16)
        white_to_move = torch.zeros(5000, dtype=torch.bool)
        target = torch.zeros(5000)
        chunks = list(_microbatches(
            codes, white_to_move, target,
            {"batch_size": 5000, "microbatch_size": "auto"},
        ))
        self.assertEqual(
            [len(chunk_target) for _, _, chunk_target in chunks],
            [2048, 2048, 904],
        )

    def test_signed_quantization_width(self):
        self.assertEqual(signed_bits(-1, 0), 1)
        self.assertEqual(signed_bits(-2, 1), 2)
        self.assertEqual(signed_bits(-4, 3), 3)
        self.assertEqual(signed_bits(-16, 15), 5)

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

    def test_train_rebuild_cache_is_an_explicit_command_option(self):
        """The cache rebuild choice belongs to each invocation, not the run config."""
        with tempfile.TemporaryDirectory() as directory:
            config = {"output": {"root": directory}}
            cache = Path(directory) / "cache"
            with (
                mock.patch("tools.tuning.cli.load_config", return_value=config),
                mock.patch("tools.tuning.cli.build_cache", return_value=cache) as build,
                mock.patch("tools.tuning.cli.train") as train_run,
            ):
                self.assertEqual(tuning_main(["train", "--rebuild-cache"]), 0)
            build.assert_called_once_with(config, rebuild=True)
            train_run.assert_called_once_with(
                config, cache, resume_run=None, initialize_run=None,
            )

    def test_tiny_training_run_and_report_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "positions.jsonl"
            source.write_text(
                "".join(json.dumps(item) + "\n" for item in record_series(64, cp_scale=10)),
                encoding="utf-8",
            )
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
            self.assertIn("Material and PST ranges", output.getvalue())
            self.assertIn("Selected opening material", output.getvalue())
            config["training"]["max_steps"] = 4
            with contextlib.redirect_stdout(io.StringIO()):
                resumed = train(config, cache, resume_run=run)
            self.assertEqual(resumed, run)
            resumed_report = json.loads((run / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(resumed_report["step"], 4)
            self.assertAlmostEqual(
                resumed_report["learning_rate"],
                config["training"]["learning_rate"]
                * config["training"]["cosine_final_factor"],
            )
            with contextlib.redirect_stdout(io.StringIO()):
                quantization = analyze_quantization(config, run, sample_positions=2)
            self.assertEqual(quantization["sample_positions"], 2)
            self.assertEqual(quantization["output_buckets"], NNUE_OUTPUT_BUCKETS)
            self.assertEqual(quantization["parameters"]["accumulator_bias"]["encoding"], "unsigned")
            self.assertEqual(quantization["parameters"]["output_bias"]["encoding"], "unsigned")
            self.assertEqual(quantization["target_bits"]["accumulator_state"], NNUE_ACCUMULATOR_BITS)
            self.assertEqual(
                len(quantization["nodes"]["clipped_accumulator_histogram"]),
                NNUE_CLIPPED_ACCUMULATOR_MAX + 1,
            )
            self.assertEqual(len(quantization["nodes"]["activation_histogram"]), NNUE_ACTIVATION_MAX + 1)
            self.assertEqual(quantization["nodes"]["activation_top_code"], NNUE_SCRELU_TOP_CODE)
            self.assertIn(str(NNUE_OUTPUT_WEIGHT_MIN), quantization["parameters"]["output_weights"]["histogram"])
            self.assertIn(str(NNUE_OUTPUT_WEIGHT_MAX), quantization["parameters"]["output_weights"]["histogram"])
            feature = torch.load(run / "best.pt", map_location="cpu", weights_only=True)[
                "model"
            ]["feature_weights"].round().clamp(-2, 1)
            categories = quantization["feature_zero_by_category"]
            self.assertEqual(len(categories), 2 * len(PIECE_ORDER))
            weights_per_category = feature.shape[0] // len(categories) * feature.shape[1]
            for index, entry in enumerate(categories):
                category_weights = feature.reshape(len(categories), -1)[index]
                expected_zeros = int(category_weights.eq(0).sum())
                self.assertEqual(entry["zero_count"], expected_zeros)
                self.assertEqual(entry["weight_count"], weights_per_category)
                self.assertAlmostEqual(
                    entry["zero_fraction"], expected_zeros / weights_per_category
                )
            self.assertEqual(categories[0]["category"], "Friendly pawn")
            self.assertEqual(categories[-1]["category"], "Opposing king")
            self.assertGreaterEqual(quantization["nodes"]["position_wrap_fraction"], 0.0)
            self.assertLessEqual(quantization["nodes"]["position_wrap_fraction"], 1.0)
            self.assertTrue((run / "quantization.json").exists())
            quantization_output = io.StringIO()
            with contextlib.redirect_stdout(quantization_output):
                print_quantization_report(quantization)
            quantization_text = quantization_output.getvalue()
            self.assertIn("Observed", quantization_text)
            self.assertIn("Allowed", quantization_text)
            self.assertIn(">= 0", quantization_text)
            self.assertNotIn("Parameter code frequencies", quantization_text)
            for key, label in (
                ("feature_weights", "Feature weights"),
                ("accumulator_bias", "Accumulator bias"),
                ("output_weights", "Output weights"),
                ("output_bias", "Output bias"),
            ):
                row = next(line for line in quantization_text.splitlines() if line.startswith(label))
                cells = re.split(r" {2,}", row.strip())
                values = quantization["parameters"][key]
                expected = (
                    f"{100 * sum(count for code, count in values['histogram'].items() if int(code) >= 0) / values['value_count']:.1f}%"
                    if values["encoding"] == "signed" else "-"
                )
                self.assertEqual(cells[6], expected)
            self.assertIn("Accumulator lanes that wrap", quantization_text)
            self.assertIn("Zero feature weights by piece category", quantization_text)
            self.assertIn("SCReLU code frequencies", quantization_text)
            self.assertIn("Input count", quantization_text)
            self.assertIn("Output count", quantization_text)
            self.assertNotIn("SCReLU input code frequencies", quantization_text)
            self.assertNotIn("SCReLU output code frequencies", quantization_text)
            category_row = next(
                line for line in quantization_text.splitlines()
                if line.startswith("Friendly pawn")
            )
            self.assertEqual(
                re.split(r" {2,}", category_row.strip())[2],
                f"{100 * categories[0]['zero_fraction']:.1f}%",
            )
            screlu_table = quantization_text.split("\nSCReLU code frequencies\n", 1)[1]
            screlu_table = screlu_table.split("\n\nOutput bucket coverage", 1)[0]
            screlu_rows = [re.split(r" {2,}", line.strip()) for line in screlu_table.splitlines()[2:]]
            self.assertEqual(
                len(screlu_rows),
                len(quantization["nodes"]["clipped_accumulator_histogram"]),
            )
            self.assertEqual(
                screlu_rows[0][1],
                f"{quantization['nodes']['clipped_accumulator_histogram'][0]:,}",
            )
            self.assertEqual(
                screlu_rows[0][3], f"{quantization['nodes']['activation_histogram'][0]:,}"
            )
            self.assertEqual(screlu_rows[-1][3:], ["-", "-"])
            self.assertIn("\n\nWrap, activation, and clipping rates\n", quantization_text)
            self.assertIn("Sampled positions", quantization_text)
            self.assertNotIn("Output sums at zero", quantization_text)
            self.assertNotIn("output_zero_fraction", quantization["nodes"])

    def test_default_config_and_validation(self):
        config = load_config(None)
        self.assertTrue(Path(config["dataset"]["path"]).is_absolute())
        self.assertIsInstance(config["filters"]["remove_captures"], bool)
        self.assertIsInstance(config["filters"]["remove_in_check"], bool)
        self.assertGreater(config["training"]["learning_rate"], 0)
        self.assertGreater(config["training"]["cosine_final_factor"], 0)
        self.assertLess(config["training"]["cosine_final_factor"], 1)
        bad = json.loads(Path("tools/tuning/default_config.json").read_text(encoding="utf-8"))
        bad["training"]["batch_size"] = 0
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)
        bad["training"]["batch_size"] = 1
        bad["training"]["microbatch_size"] = 1
        bad["training"]["early_stopping_patience"] = 0
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)
        bad["training"]["early_stopping_patience"] = 1
        bad["training"]["bucket_loss_weights"] = [1.0] * NNUE_OUTPUT_BUCKETS
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)
        del bad["training"]["bucket_loss_weights"]
        bad["training"]["microbatch_size"] = 2
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)
        bad["training"]["microbatch_size"] = 1
        bad["training"]["loss"] = "score_probability_mse"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_config(path)


if __name__ == "__main__":
    unittest.main()
