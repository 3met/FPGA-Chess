import argparse
import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from software.engine.protocol import encode_fen
from tests.hardware_build.profile_fixtures import (
    build_sample_report,
    make_report,
    sample_metrics,
)
from tools.hardware_build.common import BuildError
from tools.hardware_build.manifest import load_manifest
from tools.hardware_build.profile_format import format_profile_topics
from tools.hardware_build.profile_positions import PROFILE_POSITIONS
from tools.hardware_build.profile_report import (
    _build_tt_cache_report,
    _build_tt_fifo_reports,
    _build_tt_latency_reports,
    _build_tt_memory_interface,
    build_profile_report,
    build_profile_suite_report,
    parse_metric_records,
    percent,
    rate,
)
from tools.hardware_build.profile_schema import (
    TT_FIFOS,
)
from tools.hardware_build.profiling import (
    _compact_verilator_profile_build,
    _compile_profile,
    _compile_verilator,
    _profile_job_count,
    _profile_parameter_args,
    _prune_verilator_profile_cache,
    _resolve_profile_config,
    _train_verilator_profile,
    _validate_profile_args,
    _verilator_native_flags,
)


def make_completed_verilator_build(cache: Path, name: str, timestamp: int) -> Path:
    build = cache / name
    build.mkdir()
    fingerprint = build / "fingerprint.txt"
    fingerprint.write_text(name, encoding="utf-8")
    (build / ("profile_sim.exe" if os.name == "nt" else "profile_sim")).touch()
    os.utime(fingerprint, ns=(timestamp, timestamp))
    return build


class NativeCompilerTests(unittest.TestCase):
    """Check portable fallback and CPU-specific simulator cache identities."""

    def probe(self, root: Path, macros: str) -> tuple[str, str, bool]:
        """Supply compiler output without depending on the test host's toolchain."""
        outputs = [
            subprocess.CompletedProcess([], 0, str(root)),
            subprocess.CompletedProcess([], 0, macros),
        ]
        with patch("tools.hardware_build.profiling.subprocess.run", side_effect=outputs):
            return _verilator_native_flags("verilator")

    def test_cache_identity_tracks_cpu_features_and_ignores_macro_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "include" / "verilated.mk").write_text("CXX = c++\n", encoding="utf-8")
            flags, first, _ = self.probe(root, "#define CPU_A 1\n#define ABI 1\n")
            _, reordered, _ = self.probe(root, "#define ABI 1\n#define CPU_A 1\n")
            _, changed, _ = self.probe(root, "#define CPU_B 1\n#define ABI 1\n")
            self.assertTrue(flags)
            self.assertEqual(first, reordered)
            self.assertNotEqual(first, changed)

    def test_unavailable_or_unsupported_compiler_uses_portable_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "include" / "verilated.mk").write_text("CXX = c++\n", encoding="utf-8")
            for error in (OSError("missing tool"), subprocess.CalledProcessError(1, "compiler"),
                          subprocess.TimeoutExpired("compiler", 10)):
                with self.subTest(error=error), patch(
                    "tools.hardware_build.profiling.subprocess.run",
                    side_effect=[subprocess.CompletedProcess([], 0, str(root)), error],
                ):
                    self.assertEqual(_verilator_native_flags("verilator"), ("", "portable", False))

    def test_unrecognized_compiler_command_or_empty_probe_uses_portable_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            makefile = root / "include" / "verilated.mk"
            makefile.write_text("CXX = $(CUSTOM_COMPILER)\n", encoding="utf-8")
            self.assertEqual(self.probe(root, "#define CPU_A 1\n"), ("", "portable", False))
            makefile.write_text("CXX = c++\n", encoding="utf-8")
            self.assertEqual(self.probe(root, ""), ("", "portable", False))

    def test_profile_guided_support_is_selected_for_gcc_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "include" / "verilated.mk").write_text("CXX = c++\n", encoding="utf-8")
            gcc_macros = "#define __GNUC__ 14\n"
            self.assertTrue(self.probe(root, gcc_macros)[2])
            for other in ("__clang__", "__INTEL_COMPILER", "__INTEL_LLVM_COMPILER"):
                with self.subTest(compiler=other):
                    self.assertFalse(self.probe(root, gcc_macros + f"#define {other} 1\n")[2])


class ProfileGuidedBuildTests(unittest.TestCase):
    """Keep compiler training separate from reusable builds and reported searches."""

    def test_training_checks_completion_faults_and_wall_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for content, code, fails in (("PROFILE_COMPLETE\nRESULT\terror\t0\n", 0, False),
                                         ("RESULT\terror\t0\n", 0, True),
                                         ("PROFILE_COMPLETE\nRESULT\terror\t1\n", 0, True),
                                         ("", 124, True)):
                def run(cmd, cwd, log, **kwargs):
                    """Supply the simulator's output and record its bounded command."""
                    metrics = Path(next(value.split("=", 1)[1] for value in cmd
                                        if value.startswith("+METRICS_FILE=")))
                    metrics.write_text(content, encoding="utf-8")
                    self.assertGreater(kwargs["timeout_seconds"], 0)
                    return code, "", 0.1

                with self.subTest(content=content, code=code), patch(
                    "tools.hardware_build.profiling.run_command", side_effect=run,
                ):
                    if fails:
                        with self.assertRaises(BuildError):
                            _train_verilator_profile(root / "simulator", root)
                    else:
                        _train_verilator_profile(root / "simulator", root)

    def test_failed_training_invalidates_build_and_successful_retry_is_cached(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool = root / "verilator"
            tool.touch()
            build = root / "profile" / "compile" / "verilator" / "test-key"
            build.mkdir(parents=True)
            fingerprint = build / "fingerprint.txt"
            fingerprint.write_text("test-key\n", encoding="utf-8")
            args = argparse.Namespace(threads=2, stack_depth=8, engine_clock_hz=100,
                                      simulator_threads=1, waveform=False, force_rebuild=True,
                                      resolved_engine_config={"digest": "configuration", "threads": 2, "stack_depth": 8,
                                          "clocks": json.loads(Path("hardware/config/engine/de1-soc.json").read_text())["clocks"]})

            def run(cmd, *unused, **kwargs):
                """Create the instrumented executable before training fails."""
                self.assertGreater(kwargs["timeout_seconds"], 0)
                (build / ("profile_sim.exe" if os.name == "nt" else "profile_sim")).touch()
                return 0, "", 0.1

            with patch("tools.hardware_build.profiling.BUILD_ROOT", root), \
                    patch("tools.hardware_build.profiling.require_tool", return_value=str(tool)), \
                    patch("tools.hardware_build.profiling._verilator_native_flags", return_value=("", "cpu", True)), \
                    patch("tools.hardware_build.profiling._profile_fingerprint", return_value="test-key"), \
                    patch("tools.hardware_build.profiling._profile_parameter_args", return_value=[]), \
                    patch("tools.hardware_build.profiling.run_command", side_effect=run) as compiler, \
                    patch("tools.hardware_build.profiling._train_verilator_profile", side_effect=BuildError("training failed")) as training:
                with self.assertRaisesRegex(BuildError, "training failed"):
                    _compile_verilator([], args)
                self.assertFalse(fingerprint.exists())
                args.force_rebuild = False
                training.side_effect = None
                calls_before_retry = compiler.call_count
                executable = _compile_verilator([], args)
                self.assertEqual(compiler.call_count, calls_before_retry + 2)
                self.assertTrue(fingerprint.exists())
                calls_after_retry = compiler.call_count
                self.assertEqual(_compile_verilator([], args), executable)
                self.assertEqual(compiler.call_count, calls_after_retry)
                self.assertEqual(training.call_count, 2)


class ModelSimProfileBuildTests(unittest.TestCase):
    def test_failed_forced_rebuild_invalidates_receipt_and_retry_is_cached(self):
        """A partially rebuilt library cannot retain an earlier successful receipt."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool = root / "vlog"
            tool.touch()
            build = root / "profile/compile/modelsim/test-key"
            (build / "modelsim_work").mkdir(parents=True)
            receipt = build / "fingerprint.txt"
            receipt.write_text("test-key\n")
            args = argparse.Namespace(threads=2, stack_depth=8, force_rebuild=True,
                                      resolved_engine_config={"digest": "fixture", "threads": 2, "stack_depth": 8})
            manifest = {"simulator": {"modelsim": {"vlog_args": ["-sv"]}}}
            with patch("tools.hardware_build.profiling.BUILD_ROOT", root), \
                    patch("tools.hardware_build.profiling.require_tool", return_value=str(tool)), \
                    patch("tools.hardware_build.profiling._profile_fingerprint", return_value="test-key"), \
                    patch("tools.hardware_build.profiling.rel", side_effect=str), \
                    patch("tools.hardware_build.profiling.run_command", return_value=(124, "compile timeout", 1)) as compiler:
                with self.assertRaises(BuildError):
                    _compile_profile(manifest, [], args)
                self.assertGreater(compiler.call_args.kwargs["timeout_seconds"], 0)
                self.assertFalse(receipt.exists())
                args.force_rebuild = False
                compiler.return_value = (0, "", 0.1)
                _compile_profile(manifest, [], args)
                self.assertTrue(receipt.exists())
                calls = compiler.call_count
                _compile_profile(manifest, [], args)
                self.assertEqual(compiler.call_count, calls)

    def test_compiler_and_flags_participate_in_library_identity(self):
        """Tool replacement or compile-option changes require a new library."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool = root / "vlog"
            tool.touch()
            args = argparse.Namespace(threads=2, stack_depth=8, force_rebuild=False,
                                      resolved_engine_config={"digest": "fixture", "threads": 2, "stack_depth": 8})
            manifest = {"simulator": {"modelsim": {"vlog_args": ["-sv"]}}}
            def compile_command(command, *unused, **kwargs):
                if len(command) == 2:
                    Path(command[1]).mkdir(parents=True)
                return 0, "", 0.1
            with patch("tools.hardware_build.profiling.BUILD_ROOT", root), \
                    patch("tools.hardware_build.profiling.require_tool", return_value=str(tool)), \
                    patch("tools.hardware_build.profiling.run_command", side_effect=compile_command):
                first = _compile_profile(manifest, [], args)
                manifest["simulator"]["modelsim"]["vlog_args"].append("+define+FIXTURE")
                changed_flags = _compile_profile(manifest, [], args)
                tool.write_text("changed compiler")
                changed_tool = _compile_profile(manifest, [], args)
                self.assertEqual(len({first, changed_flags, changed_tool}), 3)



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


class StateHistogramTests(unittest.TestCase):
    def test_state_names_do_not_depend_on_order_or_known_state_count(self):
        """Reordered and newly added states retain their identity and counts."""
        from tools.hardware_build.profile_report import _state_series
        self.assertEqual(_state_series({"states.controller.search_run": 7,
                                        "states.controller.future_state": 3,
                                        "states.controller.idle": 0}, "states.controller"),
                         {"search_run": 7, "future_state": 3, "idle": 0})

    def test_numeric_or_negative_state_histograms_fail(self):
        """Refuse unlabeled encodings instead of silently attaching stale names."""
        from tools.hardware_build.profile_report import _state_series
        for metrics in ({}, {"states.controller.18": 7}, {"states.controller.search_run": -1}):
            with self.subTest(metrics=metrics), self.assertRaises(BuildError):
                _state_series(metrics, "states.controller")


class ReportTests(unittest.TestCase):
    def test_report_calculates_timing_depth_and_tt_metrics(self):
        report = build_sample_report()

        self.assertEqual(report["timing"]["cycles_per_node"], 2)
        self.assertEqual(report["timing"]["simulated_search_seconds"], 0.1)
        self.assertEqual(report["timing"]["search_cycles_per_wall_second"], 20)
        self.assertEqual(report["timing"]["wall_to_simulated_time_ratio"], 5)
        self.assertEqual(report["transposition_table"]["hit_rate_percent"], 50)
        self.assertEqual(report["result"]["qsearch_extension_beyond_completed_depth"], 2)
        self.assertEqual(report["depth_breakdown"][1]["node_growth_vs_previous_depth"], 4)
        self.assertEqual(report["depth_breakdown"][0]["status"], "complete")
        self.assertEqual(report["depth_breakdown"][1]["status"], "partial")

    def test_memory_interface_formats_totals_width_and_clock(self):
        report = build_sample_report()
        metrics = report["raw_metrics"]
        memory = report["transposition_table"]["memory_interface"]
        self.assertEqual(memory["word_bits"], metrics["sdram.word_bits"])
        self.assertEqual(memory["clock_hz"], metrics["sdram.clock_hz"])
        text = format_profile_topics(report, ["tt"])
        self.assertIn("Memory interface (search + drain)", text)
        self.assertIn(f"Total probe reads: {memory['probe_reads']:,}", text)
        self.assertIn(f"Total store reads: {memory['store_reads']:,}", text)
        self.assertIn(f"Total store writes: {memory['store_writes']:,}", text)
        self.assertIn(f"Bus width: {memory['word_bits']:,} bits", text)
        self.assertNotIn("Read width:", text)
        self.assertNotIn("SDRAM payload words", text)
        self.assertIn(f"Memory clock: {memory['clock_hz'] / 1e6:.2f} MHz (single data rate)", text)

    def test_memory_read_classification_requires_complete_totals(self):
        metrics = sample_metrics()
        metrics["sdram.store_reads"] += 1
        with self.assertRaisesRegex(BuildError, "do not match total SDRAM reads"):
            _build_tt_memory_interface(metrics)

    def test_memory_idle_and_bandwidth_use_executed_data_cycles(self):
        metrics = sample_metrics()
        memory = _build_tt_memory_interface(metrics)
        self.assertAlmostEqual(memory["controller_idle_percent"], 4 * 100 / 17)
        self.assertAlmostEqual(memory["data_bus_idle_percent"], 5 * 100 / 17)
        self.assertAlmostEqual(memory["average_payload_bytes_per_second"], 12 * 2 / (17 / metrics["sdram.clock_hz"]))
        metrics["sdram.read_words"] *= 100
        self.assertEqual(_build_tt_memory_interface(metrics)["average_payload_bytes_per_second"], memory["average_payload_bytes_per_second"])
        metrics["sdram.idle_cycles"] = 6
        with self.assertRaisesRegex(BuildError, "Invalid SDRAM idle"):
            _build_tt_memory_interface(metrics)

    def test_memory_suite_idle_and_bandwidth_pool_memory_cycles(self):
        first = build_sample_report()
        second = build_sample_report()
        second["raw_metrics"]["sdram.states.idle"] *= 10
        second["raw_metrics"]["sdram.idle_cycles"] *= 10
        suite = build_profile_suite_report([("first", first), ("second", second)])
        memory = suite["aggregate_profile"]["transposition_table"]["memory_interface"]
        self.assertAlmostEqual(memory["controller_idle_percent"], 44 * 100 / 79)
        self.assertAlmostEqual(memory["data_bus_idle_percent"], 55 * 100 / 79)
        self.assertAlmostEqual(memory["average_payload_bytes_per_second"],
                               24 * 2 / (79 / first["raw_metrics"]["sdram.clock_hz"]))

    def test_report_uses_probe_wording_and_clarifies_queue_overlap(self):
        text = format_profile_topics(build_sample_report(), ["tt"])
        for removed in ("lookup", "preempted", "Read width", "SDRAM payload words", "(SDR,"):
            self.assertNotIn(removed, text)
        for added in ("TT: probes=", "Writebacks queued alongside probe reads:",
                      "Average payload bandwidth:", "Controller idle (no request):",
                      "Data bus idle (no payload):", "Probe read", "Probe write", "Store read", "Store write"):
            self.assertIn(added, text)

    def test_memory_suite_sums_requests_and_preserves_interface_dimensions(self):
        first = build_sample_report()
        metrics = dict(first["raw_metrics"])
        metrics["sdram.probe_reads"] = 3
        metrics["sdram.store_reads"] = 2
        metrics["sdram.read_requests"] = 5
        metrics["sdram.write_requests"] = 4
        second = build_profile_report(first["configuration"], metrics, {
            "best_move.from": 0, "best_move.to": 8, "best_move.promotion": 0,
            "score": 0, "nodes": 5, "completed_depth": 1, "deepest_search_ply": 3,
            "end_reason": 1, "error": 0,
        }, 0.5)
        suite = build_profile_suite_report([("first", first), ("second", second)])
        memory = suite["aggregate_profile"]["transposition_table"]["memory_interface"]
        self.assertEqual(memory["probe_reads"], 4)
        self.assertEqual(memory["store_reads"], 2)
        self.assertEqual(memory["store_writes"], 5)
        for key in ("word_bits", "clock_hz"):
            self.assertEqual(memory[key], first["transposition_table"]["memory_interface"][key])
        second["raw_metrics"]["sdram.clock_hz"] += 1
        with self.assertRaises(BuildError):
            build_profile_suite_report([("first", first), ("second", second)])

    def test_report_formats_timing_and_thread_lifecycle(self):
        text = format_profile_topics(build_sample_report(), ["all"])

        self.assertIn("FPGA Chess Engine Runtime Profile", text)
        self.assertIn("command/position setup=2 cycles", text)
        self.assertIn("Simulated FPGA search time: 100.00 ms", text)
        self.assertIn("20.00 search cycles/wall s", text)
        self.assertNotIn("wall s/search cycle", text)
        self.assertIn("Peak queued", text)
        self.assertIn("Arena high", text)
        self.assertIn("Per-depth breakdown", text)
        self.assertIn("max ply  status", text)
        self.assertIn("Deepest search ply: 3", text)
        self.assertIn("Phase", text)
        self.assertIn("T0", text)
        self.assertIn("Pipeline request accepted", text)
        self.assertNotIn("Move request blocked", text)
        self.assertRegex(text, r"Search total\s+10\s+100\.0%")
        self.assertNotRegex(text, r"\(\s+\d+\.\d+%")
        self.assertNotIn("runnable breakdown", text)

    def test_lifecycle_groups_threads_and_aligns_large_cycle_counts(self):
        """Large suites retain aligned columns when the thread table wraps."""
        report = build_sample_report()
        search_cycles = 12_345_678_901_234
        report["timing"]["search_cycles"] = search_cycles
        thread = report["threads"][0]
        thread["phase_cycles"] = dict.fromkeys(thread["phase_cycles"], 0)
        thread["phase_cycles"]["ready"] = search_cycles
        thread["ready_breakdown"] = dict.fromkeys(thread["ready_breakdown"], 0)
        thread["ready_breakdown"]["dispatch"] = search_cycles
        report["threads"] = [dict(copy.deepcopy(thread), id=index) for index in range(5)]

        text = format_profile_topics(report, ["pipeline"])
        self.assertEqual(text.count("Search total"), 2)
        self.assertIn("T4", text)
        self.assertNotIn("TT probe", text.split("Board update pipeline")[0])
        rows = text.splitlines()
        parents = [row for row in rows if row.startswith("  Node control and dispatch")]
        children = [row for row in rows if row.startswith("    Pipeline request accepted")]
        totals = [row for row in rows if row.startswith("  Search total")]
        for parent, child, total in zip(parents, children, totals):
            self.assertEqual(parent.index(f"{search_cycles:,}"), child.index(f"{search_cycles:,}"))
            self.assertEqual(parent.index(f"{search_cycles:,}"), total.index(f"{search_cycles:,}"))
            self.assertIn("100.0%", total)

    def test_lifecycle_with_no_search_cycles_has_undefined_percentages(self):
        """An empty lifecycle still prints its total without inventing a rate."""
        report = build_sample_report()
        report["timing"]["search_cycles"] = 0
        thread = report["threads"][0]
        thread["phase_cycles"] = dict.fromkeys(thread["phase_cycles"], 0)
        text = format_profile_topics(report, ["pipeline"])
        self.assertRegex(text, r"Search total\s+0\s+n/a")

    def test_report_formats_component_activity(self):
        report = build_sample_report()
        text = format_profile_topics(report, ["all"])

        self.assertIn("Searched move ranks", text)
        self.assertIn("Legal candidates", text)
        self.assertIn("Cutoff share", text)
        self.assertIn("Move generator busy; a generation request was waiting", text)
        self.assertIn("Real candidate pushes: 2", text)
        self.assertIn("Illegal: 1 (50.0% of completed candidates)", text)
        self.assertIn("Failed to escape check (including king moves): 1 (100.0% of illegal)", text)
        self.assertNotIn("Component activity", text)
        self.assertIn("Evaluations: 1", text)
        self.assertIn("Quiescence delta-pruned moves: 4", text)
        self.assertIn("Accumulator updates: 5 accepted", text)
        self.assertIn("Update busy: 5 cycles", text)
        self.assertEqual(report["components"]["nnue_evaluator"]["evaluations"], 1)

    def test_memory_backpressure_formats_in_pipeline_and_tt_topics(self):
        """Real simulations emit memory stalls even when the count is zero."""
        report = build_sample_report()
        report["stalls"].update({"tt_request_not_ready": 1, "cdc_command": 2})
        for topic in ("pipeline", "tt"):
            with self.subTest(topic=topic):
                text = format_profile_topics(report, [topic])
                self.assertIn("TT frontend busy; a probe request was waiting: 1 cycles (10.0% of search cycles)", text)
                self.assertIn("2 cycles (15.4% of search + drain cycles)", text)

    def test_report_formats_move_generator_and_pruning_metrics(self):
        report = build_sample_report()
        text = format_profile_topics(report, ["all"])

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
        self.assertIn("Main-search board pushes (including nulls)", text)
        self.assertIn("Reverse futility pruning cutoffs: 3", text)
        self.assertIn("Ordinary futility-pruned moves: 2", text)
        self.assertEqual(report["algorithm"]["rfp_cutoffs"], 3)
        self.assertLess(text.index("Good noisy high"), text.index("Bad noisy low"))

    def test_moves_topic_is_separate_from_search_heuristics(self):
        report = build_sample_report()
        report["algorithm"].update(null_searches=7, null_cutoffs=2, future_heuristic=3)
        search = format_profile_topics(report, ["search"])
        moves = format_profile_topics(report, ["moves"])

        self.assertIn("Per-depth breakdown", search)
        self.assertIn("Late-move reductions (LMR)", search)
        self.assertIn("Principal variation search (PVS)", search)
        self.assertIn("Null-move searches: 7", search)
        self.assertIn("Null-move beta cutoffs: 2", search)
        self.assertIn("TT score cutoffs", search)
        self.assertIn("Future heuristic: 3", search)
        self.assertNotIn("Move generator operations", search)
        self.assertNotIn("Searched move ranks", search)
        self.assertNotIn("Search algorithm", search)
        self.assertIn("\nLate-move reductions (LMR)\n", search)
        self.assertIn("Move generator operations", moves)
        self.assertIn("Move generation work", moves)
        self.assertIn("Searched move ranks", moves)
        self.assertIn("Good noisy high", moves)

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

        text = format_profile_topics(report, ["all"])

        self.assertIn(
            "Move generator operations\n"
            "  Operation               Count Total cycles    Avg Max\n"
            "  Direct validation   1,890,533    3,781,066   2.00   2\n"
            "  Noisy generation   26,132,510  549,674,678  21.03  41\n"
            "  Quiet generation    5,124,774  520,589,377 101.58 132\n"
            "  Bucket pop        129,484,860  129,484,860   1.00   1\n",
            text,
        )

    def test_new_rtl_phase_is_counted_and_displayed(self):
        """A new phase participates in totals and rendering without a Python label table."""
        metrics = sample_metrics()
        metrics["threads.0.phases.ready"] -= 3
        metrics["threads.0.ready.dispatch"] -= 3
        metrics["threads.0.phases.future_phase"] = 3
        sample = build_sample_report()
        report = build_profile_report(sample["configuration"], metrics, {
            "best_move.from": 0, "best_move.to": 8, "best_move.promotion": 0,
            "score": 0, "nodes": 5, "completed_depth": 1, "deepest_search_ply": 1,
            "end_reason": 0, "error": 0,
        }, 0.5)
        self.assertEqual(report["threads"][0]["phase_cycles"]["future_phase"], 3)
        self.assertIn("Future phase", format_profile_topics(report, ["pipeline"]))

    def test_phase_total_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.ready"] = 9
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
        metrics["states.controller.search_run"] = 9
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
        metrics["threads.0.phases.ready"] = 4
        metrics["threads.0.phases.move_wait"] = 6
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
        text = format_profile_topics(report, ["all"])
        self.assertIn("Noisy moves", text)
        self.assertIn("Quiet moves", text)
        self.assertEqual(
            report["threads"][0]["move_wait_breakdown"],
            {"noisy": 2, "quiet": 4},
        )

    def test_repetition_wait_excludes_nnue_child_update(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.ready"] = 4
        metrics["threads.0.phases.repetition_wait"] = 6
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
        text = format_profile_topics(report, ["all"])
        self.assertIn("NNUE child update pending", text)
        self.assertIn("NNUE + repetition in flight", text)
        self.assertIn("Repetition check in flight", text)
        self.assertEqual(
            report["threads"][0]["repetition_wait_breakdown"],
            {"nnue_update": 2, "overlap": 3, "checker": 1},
        )

    def test_repetition_wait_breakdown_mismatch_fails(self):
        metrics = sample_metrics()
        metrics["threads.0.phases.ready"] = 9
        metrics["threads.0.phases.repetition_wait"] = 1
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

    def test_pvs_issues_cannot_exceed_main_search_pushes(self):
        report = build_sample_report()
        for scouts, researches in ((1, 0), (0, 1), (2, 0), (0, 2), (1, 1)):
            with self.subTest(scouts=scouts, researches=researches):
                metrics = sample_metrics()
                metrics.update({"algorithm.pvs_scouts": scouts, "algorithm.pvs_researches": researches})
                args = (report["configuration"], metrics,
                        {"best_move.from": 0, "best_move.to": 0, "best_move.promotion": 0,
                         "score": 0, "nodes": 0, "completed_depth": 0,
                         "deepest_search_ply": 0, "end_reason": 0, "error": 0}, 0)
                if scouts + researches <= metrics["algorithm.main_board_issues"]:
                    built = build_profile_report(*args)
                    self.assertEqual(built["algorithm"]["pvs_scouts"], scouts)
                    self.assertEqual(built["algorithm"]["pvs_researches"], researches)
                else:
                    with self.assertRaisesRegex(BuildError, "PVS scout and re-search"):
                        build_profile_report(*args)

    def test_board_classifications_separate_nulls_reversals_and_unfinished_candidates(self):
        """Only completed real moves enter legality counts and their denominator."""
        base = build_sample_report()
        metrics = sample_metrics()
        metrics.update({
            "components.board.issues": 6,
            "components.board.reverses": 1,
            "components.board.reverse_completions": 1,
            "components.board.null_completions": 1,
            "components.board.completions": 4,
            "algorithm.null_searches": 2,
            "algorithm.main_board_issues": 4,
        })
        result = {"best_move.from": 0, "best_move.to": 8, "best_move.promotion": 0,
                  "score": 0, "nodes": 1, "completed_depth": 1,
                  "deepest_search_ply": 1, "end_reason": 0, "error": 0}
        report = build_profile_report(base["configuration"], metrics, result, 0)
        board = report["components"]["board_update"]
        self.assertEqual(board["candidate_pushes"], 3)
        self.assertEqual(board["unfinished_candidates"], 1)
        text = format_profile_topics(report, ["pipeline"])
        self.assertIn("Illegal: 1 (50.0% of completed candidates)", text)
        self.assertIn("Synthetic null pushes: 2", text)
        self.assertIn("Unfinished candidate pushes at search end: 1", text)
        self.assertIn("Null completions: 1; reverse completions: 1", text)

    def test_board_classification_invariants_reject_bad_totals(self):
        """Reject overlapping causes and completions attributed to wrong operations."""
        base = build_sample_report()
        result = {"best_move.from": 0, "best_move.to": 8, "best_move.promotion": 0,
                  "score": 0, "nodes": 1, "completed_depth": 1,
                  "deepest_search_ply": 1, "end_reason": 0, "error": 0}
        for key, value, message in (
            ("components.board.illegal.king_destination", 1, "Illegal move causes"),
            ("components.board.illegal.failed_evasion", -1, "Illegal move causes"),
            ("components.board.null_completions", 1, "null/reverse completions"),
            ("components.board.reverse_completions", 1, "null/reverse completions"),
            ("components.board.completions", 1, "completion classifications"),
        ):
            with self.subTest(key=key):
                metrics = sample_metrics()
                metrics[key] = value
                with self.assertRaisesRegex(BuildError, message):
                    build_profile_report(base["configuration"], metrics, result, 0)

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
        self.assertEqual(report["components"]["board_update"]["unfinished_candidates"], 1)
        self.assertEqual(report["components"]["board_update"]["issues"], 3)
        self.assertEqual(report["components"]["board_update"]["legal_candidates"], 1)
        self.assertEqual(report["components"]["board_update"]["illegal_candidates"], 1)


class LatencyReportTests(unittest.TestCase):
    """Verify completion-weighted means and exact pooled latency percentiles."""

    def with_distribution(self, metrics, operation, outcome, histogram):
        """Populate consistent sample totals for a synthetic latency distribution."""
        prefix = f"tt.latency.{operation}.{outcome}"
        metrics[f"{prefix}.samples"] = sum(histogram.values())
        metrics[f"{prefix}.total_ps"] = sum(latency * count for latency, count in histogram.items())
        for latency, count in histogram.items():
            metrics[f"{prefix}.histogram.{latency}"] = count

    def test_latency_uses_nanoseconds_and_nearest_rank(self):
        metrics = sample_metrics()
        self.with_distribution(metrics, "probe", "hit", {1000: 99})
        self.with_distribution(metrics, "probe", "miss", {100000: 1})
        self.with_distribution(metrics, "store", "hit", {1357: 2, 6000: 1})
        report = _build_tt_latency_reports(metrics)
        self.assertAlmostEqual(report["probe"]["all"]["average_ns"], 1.99)
        self.assertEqual(report["probe"]["all"]["p99_ns"], 1)
        self.assertEqual(report["probe"]["miss"]["p99_ns"], 100)
        self.assertAlmostEqual(report["store"]["hit"]["average_ns"], 8.714 / 3)
        self.assertEqual(report["store"]["hit"]["p99_ns"], 6)
        self.assertIsNone(report["store"]["miss"]["average_ns"])
        self.assertIsNone(report["store"]["miss"]["p99_ns"])

    def test_latency_rejects_inconsistent_or_malformed_histograms(self):
        for key, value in (("samples", 2), ("total_ps", 999), ("histogram.1000", -1),
                           ("histogram.invalid", 1)):
            metrics = sample_metrics()
            self.with_distribution(metrics, "probe", "hit", {1000: 1})
            metrics[f"tt.latency.probe.hit.{key}"] = value
            with self.subTest(key=key), self.assertRaises(BuildError):
                _build_tt_latency_reports(metrics)

    def test_suite_percentile_pools_samples_instead_of_position_percentiles(self):
        first = build_sample_report()
        second = build_sample_report()
        self.with_distribution(first["raw_metrics"], "probe", "hit", {1000: 99})
        self.with_distribution(second["raw_metrics"], "probe", "miss", {100000: 1})
        report = build_profile_suite_report([("first", first), ("second", second)])
        latency = report["aggregate_profile"]["transposition_table"]["latency"]["probe"]
        self.assertEqual(latency["all"]["samples"], 100)
        self.assertEqual(latency["all"]["p99_ns"], 1)
        self.assertAlmostEqual(latency["all"]["average_ns"], 1.99)
        text = format_profile_topics(report, ["tt"])
        for label in ("TT latency (ns, search + drain)", "Hit average", "Hit P99", "Miss average", "Miss P99"):
            self.assertIn(label, text)


class CacheReportTests(unittest.TestCase):
    def test_idle_time_uses_port_cycles_and_reports_empty_windows(self):
        metrics = sample_metrics()
        cache = _build_tt_cache_report(metrics, 100)
        for operation, activity in cache["port_activity"].items():
            self.assertAlmostEqual(activity["idle_percent"],
                                   100 * (1 - metrics[f"tt.cache.{operation}_cycles"] / metrics["tt.cache.port_cycles"]))
        metrics["tt.cache.port_cycles"] = 0
        for operation in cache["port_activity"]:
            metrics[f"tt.cache.{operation}_cycles"] = 0
        empty = _build_tt_cache_report(metrics, 100)
        self.assertTrue(all(value["idle_percent"] is None for value in empty["port_activity"].values()))
        metrics["tt.cache.store_write_cycles"] = 1
        with self.assertRaisesRegex(BuildError, "Invalid activity counters"):
            _build_tt_cache_report(metrics, 100)

    def test_suite_idle_time_pools_cycles(self):
        first = build_sample_report()
        second = build_sample_report()
        second["raw_metrics"]["tt.cache.port_cycles"] *= 9
        second["raw_metrics"]["tt.cache.probe_read_cycles"] = second["raw_metrics"]["tt.cache.port_cycles"]
        suite = build_profile_suite_report([("first", first), ("second", second)])
        actual = suite["aggregate_profile"]["transposition_table"]["cache"]["port_activity"]["probe_read"]
        self.assertEqual(actual["active_cycles"], 182)
        self.assertEqual(actual["sampled_cycles"], 200)
        self.assertAlmostEqual(actual["idle_percent"], 9)

    def test_cache_counts_hit_rates_size_and_wait_units(self):
        metrics = sample_metrics()
        clock_hz = 250
        cache = _build_tt_cache_report(metrics, clock_hz)
        self.assertEqual(cache["entries"], metrics["tt.cache.entries"])
        self.assertEqual(cache["lookup_probes"], 2)
        self.assertEqual(cache["lookup_hit_rate_percent"], 50)
        self.assertEqual(cache["store_probes"], 1)
        self.assertEqual(cache["store_hit_rate_percent"], 0)
        self.assertEqual(cache["average_probe_wait_cycles"], 1.5)
        self.assertEqual(cache["average_store_wait_cycles"], 5)
        self.assertEqual(cache["average_probe_wait_ns"], 1.5 * 1e9 / clock_hz)
        self.assertEqual(cache["average_store_wait_ns"], 5 * 1e9 / clock_hz)

    def test_no_accesses_have_undefined_rates_and_waits(self):
        metrics = sample_metrics()
        for key in ("lookup_probes", "lookup_hits", "store_probes", "store_hits",
                    "probe_wait_cycles", "store_wait_cycles", "bypass_hits"):
            metrics[f"tt.cache.{key}"] = 0
        cache = _build_tt_cache_report(metrics, 100)
        for key in ("lookup_hit_rate_percent", "store_hit_rate_percent",
                    "average_probe_wait_cycles", "average_store_wait_cycles",
                    "average_probe_wait_ns", "average_store_wait_ns"):
            self.assertIsNone(cache[key])

    def test_impossible_measurements_fail(self):
        for key, value in (("store_hits", 2), ("probe_wait_cycles", -1), ("store_probes", 0), ("entries", 0)):
            metrics = sample_metrics()
            metrics[f"tt.cache.{key}"] = value
            with self.subTest(key=key), self.assertRaises(BuildError):
                _build_tt_cache_report(metrics, 100)

    def test_suite_weights_waits_and_hit_rates_by_access_counts(self):
        first = make_report("first fen", 5, 0.5)
        second = make_report("second fen", 5, 0.5)
        second["raw_metrics"].update({
            "tt.cache.lookup_probes": 8, "tt.cache.lookup_hits": 7,
            "tt.cache.probe_wait_cycles": 32, "tt.cache.store_probes": 3,
            "tt.cache.store_hits": 2, "tt.cache.store_wait_cycles": 30,
        })
        suite = build_profile_suite_report([("first", first), ("second", second)])
        cache = suite["aggregate_profile"]["transposition_table"]["cache"]
        self.assertEqual(cache["entries"], first["raw_metrics"]["tt.cache.entries"])
        self.assertEqual(cache["lookup_probes"], 10)
        self.assertEqual(cache["lookup_hit_rate_percent"], 80)
        self.assertEqual(cache["store_hit_rate_percent"], 50)
        self.assertEqual(cache["average_probe_wait_cycles"], 3.5)
        self.assertEqual(cache["average_store_wait_cycles"], 8.75)
        second["raw_metrics"]["tt.cache.entries"] += 1
        with self.assertRaisesRegex(BuildError, "different capacities for TT cache"):
            build_profile_suite_report([("first", first), ("second", second)])

    def test_cache_has_its_own_report_section(self):
        report = build_sample_report()
        text = format_profile_topics(report, ["tt"])
        self.assertIn("TT cache", text)
        self.assertIn(f"Cache size: {report['transposition_table']['cache']['entries']:,} individual TT ways", text)
        for label in ("Probe", "Store", "Count", "Hit rate", "Avg wait (cycles)", "Avg wait (ns)"):
            self.assertIn(label, text)
        self.assertNotIn("Cache stores: probes=", text)


class FIFOReportTests(unittest.TestCase):
    def set_histogram(self, metrics, name, histogram):
        """Replace one queue distribution independently of hardware settings."""
        prefix = f"tt.fifos.{name}"
        metrics[f"{prefix}.capacity"] = len(histogram) - 1
        metrics[f"{prefix}.samples"] = sum(histogram)
        for level, count in enumerate(histogram):
            metrics[f"{prefix}.occupancy.{level}"] = count

    def test_discrete_percentiles_include_idle_cycles_and_rare_peaks(self):
        histogram = [5000, 4000, 900, 90, 10]
        metrics = sample_metrics(sum(histogram))
        self.set_histogram(metrics, "stores", histogram)
        values = _build_tt_fifo_reports(metrics, sum(histogram))["stores"]
        self.assertAlmostEqual(values["average"], 0.611)
        self.assertEqual(values["median"], 0)
        self.assertEqual(values["p90"], 1)
        self.assertEqual(values["p99"], 2)
        self.assertEqual(values["p99_9"], 3)
        self.assertEqual(values["peak"], 4)

    def test_empty_measurements_have_undefined_statistics(self):
        values = _build_tt_fifo_reports(sample_metrics(0), 0)["stores"]
        for field in ("average", "median", "p90", "p99", "p99_9", "peak"):
            self.assertIsNone(values[field])

    def test_incomplete_or_inconsistent_histograms_fail(self):
        for change in ("missing", "negative", "samples", "search-cycles", "memory-samples"):
            metrics = sample_metrics()
            if change == "missing":
                del metrics["tt.fifos.stores.occupancy.4"]
            elif change == "negative":
                metrics["tt.fifos.stores.occupancy.0"] = -1
            elif change == "samples":
                metrics["tt.fifos.stores.samples"] += 1
            elif change == "search-cycles":
                self.set_histogram(metrics, "stores", [11, 0, 0, 0, 0])
            else:
                self.set_histogram(metrics, "probe_response", [11, 0, 0, 0, 0])
            with self.subTest(change=change), self.assertRaises(BuildError):
                _build_tt_fifo_reports(metrics, 10)

    def test_suite_pools_distributions_and_preserves_capacity(self):
        reports = []
        for cycles, occupancy in ((10, 0), (1000, 4)):
            metrics = sample_metrics(cycles)
            metrics["depths.2.cycles"] = cycles - metrics["depths.1.cycles"]
            histogram = [0] * 5
            histogram[occupancy] = cycles
            self.set_histogram(metrics, "stores", histogram)
            report = build_profile_report(
                {"fen": "x", "threads": 1, "engine_clock_hz": 100,
                 "search_limit": {"kind": "nodes", "value": 5}, "simulator": "verilator"},
                metrics,
                {"best_move.from": 0, "best_move.to": 8, "best_move.promotion": 0,
                 "score": 0, "nodes": 5, "completed_depth": 1,
                 "deepest_search_ply": 3, "end_reason": 1, "error": 0},
                0.5,
            )
            reports.append(report)
        suite = build_profile_suite_report([("first", reports[0]), ("second", reports[1])])
        values = suite["aggregate_profile"]["transposition_table"]["fifos"]["stores"]
        self.assertEqual(values["capacity"], reports[0]["transposition_table"]["fifos"]["stores"]["capacity"])
        self.assertAlmostEqual(values["average"], 4000 / 1010)
        self.assertEqual(values["median"], 4)
        self.assertEqual(values["p99_9"], 4)
        self.assertEqual(values["peak"], 4)
        reports[1]["raw_metrics"]["tt.fifos.stores.capacity"] += 1
        with self.assertRaisesRegex(BuildError, "different capacities"):
            build_profile_suite_report([("first", reports[0]), ("second", reports[1])])

    def test_tt_table_covers_all_fifos_and_requested_percentiles(self):
        report = build_sample_report()
        text = format_profile_topics(report, ["tt"])
        for label, unit, _ in TT_FIFOS.values():
            self.assertIn(label, text)
            self.assertIn(unit, text)
        for header in ("Depth", "Average", "Median", "P90", "P99", "P99.9", "Peak"):
            self.assertIn(header, text)


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
        default = _validate_profile_args(self.namespace())
        self.assertEqual(default[0], "time")
        self.assertGreater(default[1], 0)
        self.assertEqual(_validate_profile_args(self.namespace(timeout=None)), default)
        self.assertEqual(_validate_profile_args(self.namespace(nodes=100)), ("nodes", 100))
        self.assertEqual(_validate_profile_args(self.namespace(time_ms=5)), ("time", 5))

    def test_invalid_configuration_fails(self):
        self.assertEqual(_validate_profile_args(self.namespace(threads=17, nodes=100)), ("nodes", 100))
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
        self.assertEqual(config["clocks"]["engine"]["frequency_hz"], 60_000_000)

    def test_default_profile_comes_from_synthesis_target(self):
        args = self.namespace(threads=None, stack_depth=None, engine_clock_hz=None)
        args.target = "quartus-de1-soc"
        args.engine_config = None
        config = _resolve_profile_config(args)
        self.assertEqual(args.synthesis_target, "quartus-de1-soc")
        target = load_manifest()["synthesis_targets"][args.target]
        self.assertEqual(config["engine_config"], target["engine_config"])

    def test_all_resolved_rtl_parameters_are_forwarded(self):
        args = self.namespace(threads=None, stack_depth=None, engine_clock_hz=None)
        args.target = "quartus-de1-soc"
        args.engine_config = None
        config = _resolve_profile_config(args)
        parameters = _profile_parameter_args(config, "-G")
        self.assertIn(f"-GTT_CACHE_INDEX_BITS={config['tt_cache_index_bits']}", parameters)
        for name in ("store_fifo_depth", "outstanding_depth", "response_fifo_depth", "writeback_fifo_depth"):
            self.assertIn(f"-GTT_{name.upper()}={config['tt_' + name]}", parameters)
        self.assertIn("-GENABLE_SEARCH_STATS=0", parameters)



class ProfileSuiteTests(unittest.TestCase):
    def test_profile_positions_are_complete_and_unique(self):
        self.assertTrue(PROFILE_POSITIONS)
        self.assertEqual(len({case.name for case in PROFILE_POSITIONS}), len(PROFILE_POSITIONS))
        self.assertEqual(len({case.fen for case in PROFILE_POSITIONS}), len(PROFILE_POSITIONS))
        for case in PROFILE_POSITIONS:
            self.assertTrue(case.name)
            self.assertEqual(len(case.fen.split()), 6)
            self.assertEqual(len(encode_fen(case.fen)), 36)

    def test_suite_uses_weighted_aggregate_rates(self):
        report = build_profile_suite_report([
            ("first", make_report("first fen", 5, 0.5)),
            ("second", make_report("second fen", 10, 1.5)),
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
        self.assertEqual(
            aggregate["move_ordering"]["bucket_max_occupancy"]["bad_noisy_high"], 1
        )
        self.assertEqual(
            aggregate["move_ordering"]["bucket_arena_high_water"]["bad_noisy_high"], 2
        )
        self.assertEqual(aggregate["transposition_table"]["store_fifo_high_water"], 1)
        self.assertEqual(
            aggregate["components"]["move_generator"]["operations"]
            ["direct_validation"]["maximum_cycles"],
            2,
        )
        self.assertEqual(aggregate["depth_breakdown"][0]["positions_completed"], 2)
        self.assertEqual(aggregate["depth_breakdown"][1]["positions_completed"], 0)
        text = format_profile_topics(report, ["all"])
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
        self.assertIn("Board update pipeline", text)
        self.assertIn("Move generator operations", text)
        self.assertIn("Type       Destinations   With >=1 source", text)
        self.assertIn("Transposition table and SDRAM", text)
        self.assertIn("Suite elapsed wall time", text)
        self.assertNotRegex(text, r"\(\s+\d+\.\d+%")

    def test_suite_parallelism_is_bounded_and_validated(self):
        args = argparse.Namespace(jobs=3, simulator_threads=1)
        self.assertEqual(_profile_job_count(args, "verilator"), 3)
        args.jobs = 1000
        self.assertEqual(_profile_job_count(args, "verilator"), len(PROFILE_POSITIONS))
        args.jobs = 0
        with self.assertRaises(BuildError):
            _profile_job_count(args, "verilator")

    def test_modelsim_defaults_to_one_suite_job(self):
        args = argparse.Namespace(jobs=None, simulator_threads=1)
        self.assertEqual(_profile_job_count(args, "modelsim"), 1)

    def test_verilator_profile_cache_keeps_most_recent_completed_builds(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            builds = [
                make_completed_verilator_build(cache, f"build-{index}", index + 1)
                for index in range(12)
            ]
            incomplete = cache / "incomplete"
            incomplete.mkdir()
            (incomplete / "fingerprint.txt").write_text("incomplete", encoding="utf-8")

            with patch("tools.hardware_build.profiling.VERILATOR_PROFILE_CACHE_LIMIT", 10):
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
