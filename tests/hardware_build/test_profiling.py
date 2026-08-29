import argparse
import os
import tempfile
import unittest
from pathlib import Path

from tools.hardware_build.common import BuildError
from tools.hardware_build.profile_format import format_profile_report, format_profile_suite_report
from tools.hardware_build.profile_report import (
    build_profile_report,
    build_profile_suite_report,
    parse_metric_records,
    percent,
    rate,
)
from tools.hardware_build.profile_schema import (
    CONTROLLER_STATES,
    ENGINE_STATES,
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATIONS,
    MOVE_ORDER_STATES,
    ORDINAL_BUCKETS,
    THREAD_PHASES,
)
from tools.hardware_build.profiling import (
    _compact_verilator_profile_build,
    _prune_verilator_profile_cache,
    _profile_job_count,
    _profile_parameter_args,
    _resolve_profile_config,
    _validate_profile_args,
)


def make_completed_verilator_build(cache: Path, name: str, timestamp: int) -> Path:
    build = cache / name
    build.mkdir()
    fingerprint = build / "fingerprint.txt"
    fingerprint.write_text(name, encoding="utf-8")
    (build / ("profile_sim.exe" if os.name == "nt" else "profile_sim")).touch()
    os.utime(fingerprint, ns=(timestamp, timestamp))
    return build


def sample_metrics(search_cycles: int = 10) -> dict[str, int]:
    metrics = {
        "cycles.setup": 2,
        "cycles.search": search_cycles,
        "cycles.output": 1,
        "cycles.drain": 3,
        "components.board.issues": 2,
        "components.board.reverses": 0,
        "components.board.completions": 2,
        "components.board.legal_candidates": 1,
        "components.board.illegal_candidates": 1,
        "components.move.commands": 1,
        "components.move.pops": 1,
        "components.move.pop_misses": 0,
        "components.eval.evaluations": 1,
        "components.eval.completions": 1,
        "components.eval.update_requests": 5,
        "components.eval.root_rows": 2,
        "components.eval.rebuild_rows": 0,
        "components.eval.rebuilds": 0,
        "components.eval.delta_requests": 3,
        "components.eval.completion_markers": 0,
        "components.eval.recovery_rows": 0,
        "components.eval.update_completions": 2,
        "components.eval.update_busy_cycles": 5,
        "components.eval.update_backpressure_cycles": 2,
        "components.eval.accumulator_wrap_lanes": 0,
        "components.repetition.requests": 1,
        "components.repetition.responses": 1,
        "stalls.move_not_ready": 2,
        "algorithm.main_board_issues": 1,
        "algorithm.qsearch_board_issues": 1,
        "algorithm.rfp_cutoffs": 3,
        "algorithm.qdelta_pruned_moves": 4,
        "tt.lookups": 2,
        "tt.hits": 1,
        "tt.stores": 1,
        "tt.store_drops": 0,
        "tt.store_fifo_high_water": 1,
        "tt.store_write_preemptions": 1,
        "tt.bound_hits.exact": 1,
        "tt.bound_hits.lower": 0,
        "tt.bound_hits.upper": 0,
        "tt.cutoff_hits": 1,
        "tt.ordering_hits": 0,
        "tt.cache.lookup_probes": 2,
        "tt.cache.lookup_hits": 1,
        "tt.cache.bypass_hits": 1,
        "tt.cache.store_probes": 1,
        "tt.cache.store_hits": 0,
        "sdram.read_requests": 1,
        "sdram.write_requests": 1,
        "sdram.read_words": 6,
        "sdram.write_words": 6,
        "sdram.row_hits": 1,
        "sdram.row_misses": 1,
        "sdram.row_conflicts": 0,
    }
    operation_counts = [1, 0, 0, 1]
    operation_cycles = [2, 0, 0, 1]
    for index in range(len(MOVE_GENERATOR_OPERATIONS)):
        metrics[f"components.move_generator.operations.{index}.count"] = operation_counts[index]
        metrics[f"components.move_generator.operations.{index}.total_cycles"] = (
            operation_cycles[index]
        )
        metrics[f"components.move_generator.operations.{index}.max_cycles"] = (
            operation_cycles[index]
        )
        metrics[f"components.move_generator.operations.{index}.aborted"] = 0
    for kind in ("noisy", "quiet"):
        metrics[f"components.move_generator.generation.{kind}.destinations_examined"] = 0
        metrics[
            f"components.move_generator.generation.{kind}.destinations_with_sources"
        ] = 0
        metrics[f"components.move_generator.generation.{kind}.candidates_emitted"] = 0
    for index in range(len(ENGINE_STATES)):
        metrics[f"states.engine.{index}"] = search_cycles if index == 5 else 0
    for index in range(len(CONTROLLER_STATES)):
        metrics[f"states.controller.{index}"] = search_cycles if index == 19 else 0
    for index in range(len(THREAD_PHASES)):
        metrics[f"threads.0.phases.{index}"] = search_cycles if index == 1 else 0
    for index in range(len(MOVE_ORDER_STATES)):
        metrics[f"threads.0.move_order.{index}"] = search_cycles if index == 0 else 0
    metrics["threads.0.nodes"] = 5
    metrics["threads.0.ready.nnue_init"] = 0
    metrics["threads.0.ready.dispatch"] = search_cycles
    metrics["threads.0.ready.arbitration"] = 0
    metrics["threads.0.ready.tt_blocked"] = 0
    metrics["threads.0.ready.noisy_move_blocked"] = 0
    metrics["threads.0.ready.quiet_move_blocked"] = 0
    metrics["threads.0.ready.transition"] = 0
    metrics["threads.0.move_wait.noisy"] = 0
    metrics["threads.0.move_wait.quiet"] = 0
    metrics["threads.0.repetition_wait.nnue_update"] = 0
    metrics["threads.0.repetition_wait.overlap"] = 0
    metrics["threads.0.repetition_wait.checker"] = 0
    metrics["concurrency.active_threads.0"] = 0
    metrics["concurrency.active_threads.1"] = search_cycles
    metrics["concurrency.inflight.0"] = search_cycles
    for index in range(1, 6):
        metrics[f"concurrency.inflight.{index}"] = 0
    for index in range(len(MOVE_BUCKETS)):
        metrics[f"move_order.bucket_writes.{index}"] = 1 if index == 2 else 0
        metrics[f"move_order.bucket_pops.{index}"] = 1 if index == 2 else 0
        metrics[f"move_order.bucket_cutoffs.{index}"] = 1 if index == 2 else 0
        metrics[f"move_order.bucket_high_water.{index}"] = 1 if index == 2 else 0
    for index in range(len(ORDINAL_BUCKETS)):
        metrics[f"move_order.legal_ordinal.{index}"] = 1 if index == 0 else 0
        metrics[f"move_order.cutoff_ordinal.{index}"] = 1 if index == 0 else 0
    metrics["move_order.direct_cutoffs"] = 0
    metrics.update(
        {
            "depths.1.cycles": 4,
            "depths.1.nodes": 1,
            "depths.1.tt_lookups": 0,
            "depths.1.tt_hits": 0,
            "depths.1.cache_probes": 0,
            "depths.1.cache_hits": 0,
            "depths.1.max_ply": 2,
            "depths.2.cycles": 6,
            "depths.2.nodes": 4,
            "depths.2.tt_lookups": 2,
            "depths.2.tt_hits": 1,
            "depths.2.cache_probes": 2,
            "depths.2.cache_hits": 1,
            "depths.2.max_ply": 4,
        }
    )
    return metrics


class ProfileMathTests(unittest.TestCase):
    def test_undefined_rates_are_none(self):
        self.assertIsNone(percent(3, 0))
        self.assertIsNone(rate(3, 0))
        self.assertEqual(percent(1, 4), 25.0)
        self.assertEqual(rate(9, 3), 3.0)


class MetricRecordTests(unittest.TestCase):
    def test_parse_records(self):
        metrics, result = parse_metric_records(
            "METRIC\tcycles.search\t12\nRESULT\tnodes\t3\nPROFILE_COMPLETE\n"
        )
        self.assertEqual(metrics, {"cycles.search": 12})
        self.assertEqual(result, {"nodes": 3})

    def test_incomplete_and_duplicate_records_fail(self):
        with self.assertRaises(BuildError):
            parse_metric_records("METRIC\tcycles.search\t12\n")
        with self.assertRaises(BuildError):
            parse_metric_records(
                "METRIC\tcycles.search\t12\nMETRIC\tcycles.search\t13\nPROFILE_COMPLETE\n"
            )


class ReportTests(unittest.TestCase):
    def test_build_and_format_report(self):
        configuration = {
            "fen": "8/8/8/8/8/8/8/K6k w - - 0 1",
            "threads": 1,
            "engine_clock_hz": 100,
        }
        result_values = {
            "best_move.from": 0,
            "best_move.to": 8,
            "best_move.promotion": 0,
            "score": 2,
            "nodes": 5,
            "completed_depth": 1,
            "deepest_search_ply": 3,
            "end_reason": 1,
            "error": 0,
        }
        report = build_profile_report(configuration, sample_metrics(), result_values, 0.5)
        self.assertEqual(report["timing"]["cycles_per_node"], 2)
        self.assertEqual(report["timing"]["simulated_search_seconds"], 0.1)
        self.assertEqual(report["timing"]["search_cycles_per_wall_second"], 20)
        self.assertEqual(report["timing"]["wall_to_simulated_time_ratio"], 5)
        self.assertEqual(report["transposition_table"]["hit_rate_percent"], 50)
        self.assertEqual(report["result"]["qsearch_extension_beyond_completed_depth"], 2)
        self.assertEqual(report["depth_breakdown"][1]["node_growth_vs_previous_depth"], 4)
        self.assertEqual(report["depth_breakdown"][0]["status"], "complete")
        self.assertEqual(report["depth_breakdown"][1]["status"], "partial")
        text = format_profile_report(report)
        self.assertIn("FPGA Chess Engine Runtime Profile", text)
        self.assertIn("command/position setup=2 cycles", text)
        self.assertIn("Simulated FPGA search time: 100.00 ms", text)
        self.assertIn("20.00 search cycles/wall s", text)
        self.assertNotIn("wall s/search cycle", text)
        self.assertIn("Peak queued", text)
        self.assertIn("Per-depth breakdown", text)
        self.assertIn("max ply  status", text)
        self.assertIn("Deepest search ply reached (including quiescence search): 3", text)
        self.assertIn("Metric", text)
        self.assertIn("T0", text)
        self.assertIn("Pipeline request accepted", text)
        self.assertNotIn("Move request blocked", text)
        self.assertIn("10 (100.0%)", text)
        self.assertNotRegex(text, r"\(\s+\d+\.\d+%")
        self.assertNotIn("runnable breakdown", text)
        self.assertIn("Searched move ranks", text)
        self.assertIn("Legal candidates", text)
        self.assertIn("Cutoff share", text)
        self.assertIn("Move generator busy; a generation request was waiting", text)
        self.assertIn("2 candidate pushes: 1 legal, 1 illegal; 0 reversals", text)
        self.assertIn("NNUE evaluator: 1 evaluations", text)
        self.assertIn("Quiescence delta-pruned moves: 4", text)
        self.assertIn("updates: 5 accepted", text)
        self.assertIn("update busy=5 cycles", text)
        self.assertEqual(report["components"]["nnue_evaluator"]["evaluations"], 1)
        self.assertIn("Move generator operations", text)
        self.assertIn("Direct validation", text)
        self.assertIn("Move generation work", text)
        self.assertIn("Cycles/candidate", text)
        self.assertEqual(
            report["components"]["move_generator"]["operations"]["direct_validation"][
                "average_cycles"
            ],
            2,
        )
        self.assertEqual(
            report["components"]["move_generator"]["operations"]["direct_validation"][
                "aborted_at_search_end"
            ],
            0,
        )
        self.assertIsNone(
            report["components"]["move_generator"]["generation"]["noisy"][
                "cycles_per_candidate"
            ]
        )
        self.assertIn("Main-search move pushes", text)
        self.assertIn("Reverse futility pruning cutoffs: 3", text)
        self.assertEqual(report["algorithm"]["rfp_cutoffs"], 3)
        self.assertLess(text.index("Good noisy high"), text.index("Bad noisy low"))

    def test_move_generator_operation_table_is_dense_and_aligned(self):
        metrics = sample_metrics()
        counts = [1_890_533, 26_132_510, 5_124_774, 129_484_860]
        totals = [3_781_066, 549_674_678, 520_589_377, 129_484_860]
        maximums = [2, 41, 132, 1]
        for index in range(4):
            metrics[f"components.move_generator.operations.{index}.count"] = counts[index]
            metrics[f"components.move_generator.operations.{index}.total_cycles"] = totals[index]
            metrics[f"components.move_generator.operations.{index}.max_cycles"] = maximums[index]
        metrics["components.move.commands"] = sum(counts[:3])
        metrics["components.move.pops"] = counts[3]
        report = build_profile_report(
            {"fen": "x", "threads": 1, "engine_clock_hz": 100},
            metrics,
            {
                "best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                "score": 0, "nodes": 5, "completed_depth": 0,
                "deepest_search_ply": 0, "end_reason": 0, "error": 0,
            },
            1,
        )

        text = format_profile_report(report)

        self.assertIn(
            "Move generator operations\n"
            "  Operation               Count Total cycles    Avg Max\n"
            "  Direct validation   1,890,533    3,781,066   2.00   2\n"
            "  Noisy generation   26,132,510  549,674,678  21.03  41\n"
            "  Quiet generation    5,124,774  520,589,377 101.58 132\n"
            "  Bucket pop        129,484,860  129,484,860   1.00   1\n",
            text,
        )

    def test_phase_total_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.1"] = 9
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0,
                    "best_move.to": 0,
                    "best_move.promotion": 0,
                    "score": 0,
                    "nodes": 0,
                    "completed_depth": 0,
                    "deepest_search_ply": 0,
                    "end_reason": 0,
                    "error": 0,
                },
                0,
            )

    def test_controller_state_total_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["states.controller.19"] = 9
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0,
                    "best_move.to": 0,
                    "best_move.promotion": 0,
                    "score": 0,
                    "nodes": 0,
                    "completed_depth": 0,
                    "deepest_search_ply": 0,
                    "end_reason": 0,
                    "error": 0,
                },
                0,
            )

    def test_ready_breakdown_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["threads.0.ready.dispatch"] = 9
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0,
                    "best_move.to": 0,
                    "best_move.promotion": 0,
                    "score": 0,
                    "nodes": 0,
                    "completed_depth": 0,
                    "deepest_search_ply": 0,
                    "end_reason": 0,
                    "error": 0,
                },
                0,
            )

    def test_move_wait_breakdown_is_reported_by_move_class(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.1"] = 4
        metrics["threads.0.phases.4"] = 6
        metrics["threads.0.ready.dispatch"] = 4
        metrics["threads.0.move_wait.noisy"] = 2
        metrics["threads.0.move_wait.quiet"] = 4
        report = build_profile_report(
            {"fen": "x", "threads": 1, "engine_clock_hz": 100},
            metrics,
            {
                "best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                "score": 0, "nodes": 5, "completed_depth": 0,
                "deepest_search_ply": 0, "end_reason": 0, "error": 0,
            },
            1,
        )
        text = format_profile_report(report)
        self.assertIn("Noisy move operation in flight", text)
        self.assertIn("Quiet move operation in flight", text)
        self.assertEqual(
            report["threads"][0]["move_wait_breakdown"],
            {"noisy": 2, "quiet": 4},
        )

    def test_repetition_wait_excludes_nnue_child_update(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.1"] = 4
        metrics["threads.0.phases.7"] = 6
        metrics["threads.0.ready.dispatch"] = 4
        metrics["threads.0.repetition_wait.nnue_update"] = 2
        metrics["threads.0.repetition_wait.overlap"] = 3
        metrics["threads.0.repetition_wait.checker"] = 1
        report = build_profile_report(
            {"fen": "x", "threads": 1, "engine_clock_hz": 100},
            metrics,
            {
                "best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                "score": 0, "nodes": 5, "completed_depth": 0,
                "deepest_search_ply": 0, "end_reason": 0, "error": 0,
            },
            1,
        )
        text = format_profile_report(report)
        self.assertIn("NNUE child update pending", text)
        self.assertIn("NNUE + repetition in flight", text)
        self.assertIn("Repetition check in flight", text)
        self.assertEqual(
            report["threads"][0]["repetition_wait_breakdown"],
            {"nnue_update": 2, "overlap": 3, "checker": 1},
        )

    def test_repetition_wait_breakdown_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.1"] = 9
        metrics["threads.0.phases.7"] = 1
        metrics["threads.0.ready.dispatch"] = 9
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                    "score": 0, "nodes": 5, "completed_depth": 0,
                    "deepest_search_ply": 0, "end_reason": 0, "error": 0,
                },
                1,
            )

    def test_move_generator_operation_count_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["components.move_generator.operations.0.count"] = 0
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0,
                    "best_move.to": 0,
                    "best_move.promotion": 0,
                    "score": 0,
                    "nodes": 0,
                    "completed_depth": 0,
                    "deepest_search_ply": 0,
                    "end_reason": 0,
                    "error": 0,
                },
                0,
            )

    def test_legal_ordinal_total_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["move_order.legal_ordinal.0"] = 0
        with self.assertRaises(BuildError):
            build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100},
                metrics,
                {
                    "best_move.from": 0,
                    "best_move.to": 0,
                    "best_move.promotion": 0,
                    "score": 0,
                    "nodes": 0,
                    "completed_depth": 0,
                    "deepest_search_ply": 0,
                    "end_reason": 0,
                    "error": 0,
                },
                0,
            )

    def test_incomplete_board_request_at_search_end_is_allowed(self):
        metrics = sample_metrics()
        metrics["components.board.issues"] = 3
        metrics["algorithm.main_board_issues"] = 2
        report = build_profile_report(
            {"fen": "x", "threads": 1, "engine_clock_hz": 100},
            metrics,
            {
                "best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                "score": 0, "nodes": 5, "completed_depth": 0,
                "deepest_search_ply": 0, "end_reason": 0, "error": 0,
            },
            1,
        )
        self.assertEqual(report["components"]["board_update"]["issues"], 3)
        self.assertEqual(report["components"]["board_update"]["legal_candidates"], 1)
        self.assertEqual(report["components"]["board_update"]["illegal_candidates"], 1)


class ProfileArgumentTests(unittest.TestCase):
    def namespace(self, **updates):
        values = {
            "threads": 1,
            "stack_depth": 32,
            "engine_clock_hz": 75_000_000,
            "timeout": 10,
            "simulator_threads": 1,
            "depth": None,
            "nodes": None,
            "time_ms": None,
        }
        values.update(updates)
        return argparse.Namespace(**values)

    def test_default_and_explicit_limits(self):
        self.assertEqual(_validate_profile_args(self.namespace()), ("time", 50))
        self.assertEqual(_validate_profile_args(self.namespace(timeout=None)), ("time", 50))
        self.assertEqual(_validate_profile_args(self.namespace(nodes=100)), ("nodes", 100))
        self.assertEqual(_validate_profile_args(self.namespace(time_ms=5)), ("time", 5))

    def test_invalid_configuration_fails(self):
        self.assertEqual(_validate_profile_args(self.namespace(threads=17)), ("time", 50))
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(threads=0))
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(depth=32))
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(simulator_threads=0))

    def test_structural_overrides_update_resolved_profile(self):
        args = self.namespace(threads=17, stack_depth=65, engine_clock_hz=60_000_000)
        args.engine_config = "hardware/config/engine/de1-soc.json"
        config = _resolve_profile_config(args)
        self.assertEqual(config["threads"], 17)
        self.assertEqual(config["stack_depth"], 65)
        self.assertEqual(config["clock_frequency_hz"], 60_000_000)

    def test_default_profile_comes_from_synthesis_target(self):
        args = self.namespace(threads=None, stack_depth=None, engine_clock_hz=None)
        args.target = "quartus-de1-soc"
        args.engine_config = None
        config = _resolve_profile_config(args)
        self.assertEqual(args.synthesis_target, "quartus-de1-soc")
        self.assertEqual(config["engine_config"], "hardware/config/engine/de1-soc.json")

    def test_all_resolved_rtl_parameters_are_forwarded(self):
        args = self.namespace(threads=None, stack_depth=None, engine_clock_hz=None)
        args.target = "quartus-de1-soc"
        args.engine_config = None
        config = _resolve_profile_config(args)
        parameters = _profile_parameter_args(config, "-G")
        self.assertIn("-GTT_CACHE_INDEX_BITS=11", parameters)
        self.assertIn("-GENABLE_SEARCH_STATS=0", parameters)


class ProfileSuiteTests(unittest.TestCase):
    def make_report(self, fen: str, nodes: int, wall_seconds: float) -> dict:
        metrics = sample_metrics()
        result_values = {
            "best_move.from": 0,
            "best_move.to": 8,
            "best_move.promotion": 0,
            "score": 2,
            "nodes": nodes,
            "completed_depth": 1,
            "deepest_search_ply": 3,
            "end_reason": 1,
            "error": 0,
        }
        return build_profile_report(
            {
                "fen": fen,
                "search_limit": {"kind": "time", "value": 50},
                "threads": 1,
                "engine_clock_hz": 100,
                "simulator": "verilator",
                "simulator_threads": 1,
            },
            metrics,
            result_values,
            wall_seconds,
        )

    def test_suite_uses_weighted_aggregate_rates(self):
        report = build_profile_suite_report([
            ("first", self.make_report("first fen", 5, 0.5)),
            ("second", self.make_report("second fen", 10, 1.5)),
        ])
        self.assertEqual(report["position_count"], 2)
        self.assertEqual(report["timing"]["nodes"], 15)
        self.assertEqual(report["timing"]["search_cycles"], 20)
        self.assertAlmostEqual(report["timing"]["cycles_per_node"], 20 / 15)
        self.assertEqual(report["transposition_table"]["lookups"], 4)
        self.assertEqual(report["transposition_table"]["hits"], 2)
        aggregate = report["aggregate_profile"]
        self.assertEqual(aggregate["timing"]["setup_cycles"], 4)
        self.assertEqual(aggregate["components"]["board_update"]["issues"], 4)
        self.assertEqual(aggregate["transposition_table"]["store_fifo_high_water"], 1)
        self.assertEqual(
            aggregate["components"]["move_generator"]["operations"]
            ["direct_validation"]["maximum_cycles"],
            2,
        )
        self.assertEqual(aggregate["depth_breakdown"][0]["positions_completed"], 2)
        self.assertEqual(aggregate["depth_breakdown"][1]["positions_completed"], 0)
        text = format_profile_suite_report(report)
        self.assertIn("FPGA Chess Engine Runtime Profile Suite", text)
        self.assertIn("Positions: 2", text)
        self.assertIn("Simulator: verilator", text)
        self.assertNotIn("execution thread per process", text)
        self.assertNotIn("Completed depth:", text)
        self.assertNotIn("first fen", text)
        self.assertNotIn("second fen", text)
        self.assertIn("Per-thread lifecycle", text)
        self.assertIn("Per-depth breakdown", text)
        self.assertIn("positions", text)
        self.assertIn("Component activity", text)
        self.assertIn("Move generator operations", text)
        self.assertIn("Type       Destinations   With >=1 source", text)
        self.assertIn("Transposition table and SDRAM", text)
        self.assertIn("Suite simulation performance", text)
        self.assertNotRegex(text, r"\(\s+\d+\.\d+%")

    def test_suite_parallelism_is_bounded_and_validated(self):
        args = argparse.Namespace(jobs=3, simulator_threads=1)
        self.assertEqual(_profile_job_count(args, "verilator"), 3)
        args.jobs = 1000
        self.assertEqual(_profile_job_count(args, "verilator"), 48)
        args.jobs = 0
        with self.assertRaises(BuildError):
            _profile_job_count(args, "verilator")

    def test_modelsim_defaults_to_one_suite_job(self):
        args = argparse.Namespace(jobs=None, simulator_threads=1)
        self.assertEqual(_profile_job_count(args, "modelsim"), 1)

    def test_verilator_profile_cache_keeps_ten_most_recent_completed_builds(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            builds = [
                make_completed_verilator_build(cache, f"build-{index}", index + 1)
                for index in range(12)
            ]
            incomplete = cache / "incomplete"
            incomplete.mkdir()
            (incomplete / "fingerprint.txt").write_text("incomplete", encoding="utf-8")

            _prune_verilator_profile_cache(cache, builds[-1])

            self.assertFalse(builds[0].exists())
            self.assertFalse(builds[1].exists())
            self.assertTrue(all(build.exists() for build in builds[2:]))
            self.assertTrue(incomplete.exists())

    def test_completed_verilator_build_is_compacted_to_reusable_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            build = make_completed_verilator_build(Path(temporary), "build", 1)
            (build / "compile.log").write_text("complete", encoding="utf-8")
            (build / "generated.cpp").write_text("generated", encoding="utf-8")
            object_dir = build / "objects"
            object_dir.mkdir()
            (object_dir / "generated.o").touch()

            _compact_verilator_profile_build(build)

            self.assertEqual(
                {path.name for path in build.iterdir()},
                {"profile_sim.exe" if os.name == "nt" else "profile_sim", "fingerprint.txt", "compile.log"},
            )


if __name__ == "__main__":
    unittest.main()
