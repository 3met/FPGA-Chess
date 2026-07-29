import argparse
import unittest

from tools.hardware_build.common import BuildError
from tools.hardware_build.profiling import (
    CONTROLLER_STATES,
    ENGINE_STATES,
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATIONS,
    MOVE_ORDER_STATES,
    ORDINAL_BUCKETS,
    THREAD_PHASES,
    _validate_profile_args,
    build_profile_report,
    format_profile_report,
    parse_metric_records,
    percent,
    rate,
)


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
        "components.repetition.requests": 1,
        "components.repetition.responses": 1,
        "stalls.move_not_ready": 2,
        "algorithm.main_board_issues": 1,
        "algorithm.qsearch_board_issues": 1,
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
        metrics[f"states.controller.{index}"] = search_cycles if index == 18 else 0
    for index in range(len(THREAD_PHASES)):
        metrics[f"threads.0.phases.{index}"] = search_cycles if index == 1 else 0
    for index in range(len(MOVE_ORDER_STATES)):
        metrics[f"threads.0.move_order.{index}"] = search_cycles if index == 0 else 0
    metrics["threads.0.nodes"] = 5
    metrics["threads.0.ready.dispatch"] = search_cycles
    metrics["threads.0.ready.arbitration"] = 0
    metrics["threads.0.ready.tt_blocked"] = 0
    metrics["threads.0.ready.move_blocked"] = 0
    metrics["threads.0.ready.transition"] = 0
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
        self.assertIn("peak queued=", text)
        self.assertIn("Per-depth breakdown", text)
        self.assertIn("max ply  status", text)
        self.assertIn("Deepest search ply reached (including qsearch): 3", text)
        self.assertIn("Metric", text)
        self.assertIn("T0", text)
        self.assertIn("Pipeline request accepted", text)
        self.assertIn("10 (100.0%)", text)
        self.assertNotIn("runnable breakdown", text)
        self.assertIn("Beta cutoffs by searched move rank", text)
        self.assertIn("Legal candidates by searched rank", text)
        self.assertIn("Move generator busy; a generation request was waiting", text)
        self.assertIn("2 candidate pushes: 1 legal, 1 illegal; 0 reversals", text)
        self.assertIn("static evaluator: 1 evaluations", text)
        self.assertEqual(report["components"]["static_evaluator"]["evaluations"], 1)
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
        self.assertLess(text.index("good_noisy_high"), text.index("bad_noisy_low"))

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


class ProfileArgumentTests(unittest.TestCase):
    def namespace(self, **updates):
        values = {
            "threads": 1,
            "stack_depth": 32,
            "engine_clock_hz": 35_714_286,
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
        self.assertEqual(_validate_profile_args(self.namespace(nodes=100)), ("nodes", 100))
        self.assertEqual(_validate_profile_args(self.namespace(time_ms=5)), ("time", 5))

    def test_invalid_configuration_fails(self):
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(threads=17))
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(depth=32))
        with self.assertRaises(BuildError):
            _validate_profile_args(self.namespace(simulator_threads=0))


if __name__ == "__main__":
    unittest.main()
