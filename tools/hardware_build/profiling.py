"""Cycle-accurate engine profiling with ModelSim/Questa."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
from datetime import datetime
from pathlib import Path

from software.engine.protocol import (
    NODE_COUNT_MAX,
    TIME_MAX_MS,
    Move,
    ProtocolError,
    encode_fen,
    move_to_uci,
)

from .common import BUILD_ROOT, REPO_ROOT, BuildError, print_failure_excerpt, rel, require_tool, run_command
from .manifest import expand_source_set, load_manifest
from .simulation import has_sim_errors


ENGINE_STATES = [
    "idle", "receive_payload", "process_payload", "direct_board",
    "issue_request", "wait_result", "issue_kill", "output",
]
CONTROLLER_STATES = [
    "idle", "board_issue", "board_wait", "direct_done", "new_clear_start",
    "new_clear_wait", "new_setup_issue", "new_setup_wait", "new_done",
    "perft_gen_issue", "perft_gen_wait", "perft_push_issue", "perft_push_wait",
    "perft_reverse_issue", "perft_reverse_wait", "repetition_init",
    "repetition_root_wait", "search_iter_start", "search_root_init", "search_run",
    "respond", "kill_done",
]
THREAD_PHASES = [
    "idle", "ready", "tt_wait", "eval_wait", "move_wait", "board_wait",
    "reverse_wait", "repetition_wait", "store_publish", "terminal_wait", "done",
]
THREAD_PHASE_LABELS = {
    "idle": "Inactive",
    "ready": "Runnable",
    "tt_wait": "TT lookup in flight",
    "eval_wait": "Evaluation in flight",
    "board_wait": "Board update in flight",
    "reverse_wait": "Reverse update in flight",
    "repetition_wait": "Child preparation/repetition wait",
    "store_publish": "TT store request pending",
    "terminal_wait": "Terminal scoring",
    "done": "Iteration handoff",
}
READY_BREAKDOWN_LABELS = {
    "nnue_init": "NNUE root initialization",
    "dispatch": "Pipeline request accepted",
    "arbitration": "Shared-pipeline arbitration",
    "tt_blocked": "TT lookup request blocked",
    "noisy_move_blocked": "Noisy move request blocked",
    "quiet_move_blocked": "Quiet move request blocked",
    "transition": "Node/iteration transition",
}
MOVE_ORDER_STATES = [
    "direct", "generate_noisy", "good_noisy", "generate_quiet", "quiet", "bad_noisy", "done",
]
MOVE_BUCKETS = [
    "bad_noisy_low", "bad_noisy_high", "quiet_low", "quiet_medium",
    "quiet_high", "quiet_highest", "good_noisy_low", "good_noisy_high",
]
ORDINAL_BUCKETS = ["1", "2", "3", "4", "5-8", "9-16", "17-32", "33+"]
STALL_LABELS = {
    "move_not_ready": "Move generator busy; a generation request was waiting",
    "tt_request_not_ready": "TT frontend busy; a lookup request was waiting",
    "cdc_command": "SDRAM command CDC FIFO full",
    "cdc_write": "SDRAM write-data CDC FIFO full",
    "cdc_read": "Returned SDRAM read data waiting for the TT frontend",
    "cdc_done": "Returned SDRAM completion waiting for the TT frontend",
}
ALGORITHM_LABELS = {
    "main_board_issues": "Main-search move pushes",
    "qsearch_board_issues": "Quiescence-search move pushes",
    "pvs_scouts": "PVS scout searches",
    "pvs_researches": "PVS full-window re-searches",
    "lmr_reduced_issues": "LMR reduced move pushes",
    "terminal_checkmates": "Checkmate terminals",
    "terminal_stalemates": "Stalemate terminals",
    "terminal_main_exhausted": "Main-search nodes that exhausted every move",
    "terminal_qsearch_exhausted": "Quiescence nodes that exhausted every tactical move",
    "repetition_draws": "Repetition draws",
    "fifty_move_draws": "Fifty-move draws",
}
GENERATOR_STATES = [
    "idle", "direct", "select_destination", "expand_source",
    "build_context", "history_wait", "castle", "finish",
]
MOVE_GENERATOR_OPERATIONS = [
    "direct_validation", "noisy_generation", "quiet_generation", "bucket_pop",
]
MOVE_GENERATOR_OPERATION_LABELS = {
    "direct_validation": "Direct validation",
    "noisy_generation": "Noisy generation",
    "quiet_generation": "Quiet generation",
    "bucket_pop": "Bucket pop",
}
TT_FRONTEND_STATES = [
    "idle", "read_request", "read_data", "write_request", "write_data", "write_done",
    "clear_request", "clear_data", "clear_done", "cache_clear", "cache_read", "read_done",
]
SDRAM_STATES = [
    "powerup", "init_precharge", "init_precharge_wait", "init_refresh_1",
    "init_refresh_1_wait", "init_refresh_2", "init_refresh_2_wait", "init_mode",
    "init_mode_wait", "clear_check", "clear_precharge", "clear_precharge_wait",
    "clear_activate", "clear_activate_wait", "clear_write", "clear_terminate", "idle",
    "precharge", "precharge_wait", "activate", "activate_wait", "read_command",
    "read_wait", "read_data", "read_serve", "write_collect", "write_command", "write_data",
    "burst_terminate", "complete", "refresh_precharge", "refresh_precharge_wait",
    "refresh", "refresh_wait",
]


def percent(numerator: int | float, denominator: int | float) -> float | None:
    """Return a percentage, preserving undefined zero-denominator rates."""
    if denominator == 0:
        return None
    return float(numerator) * 100.0 / float(denominator)


def rate(numerator: int | float, denominator: int | float) -> float | None:
    """Return a rate, preserving undefined zero-denominator rates."""
    if denominator == 0:
        return None
    return float(numerator) / float(denominator)


def parse_metric_records(text: str) -> tuple[dict[str, int], dict[str, int]]:
    """Parse the profiler's deliberately simple tab-separated interchange."""
    metrics: dict[str, int] = {}
    result: dict[str, int] = {}
    complete = False
    for line_number, line in enumerate(text.splitlines(), 1):
        if line == "PROFILE_COMPLETE":
            complete = True
            continue
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 3 or parts[0] not in {"METRIC", "RESULT"}:
            raise BuildError(f"Malformed profile metric record on line {line_number}")
        try:
            value = int(parts[2])
        except ValueError as exc:
            raise BuildError(f"Non-integer profile metric on line {line_number}") from exc
        target = metrics if parts[0] == "METRIC" else result
        if parts[1] in target:
            raise BuildError(f"Duplicate profile metric '{parts[1]}'")
        target[parts[1]] = value
    if not complete:
        raise BuildError("Profile metric output is incomplete")
    return metrics, result


def _named_series(metrics: dict[str, int], prefix: str, names: list[str]) -> dict[str, int]:
    return {name: metrics.get(f"{prefix}.{index}", 0) for index, name in enumerate(names)}


def build_profile_report(
    configuration: dict,
    metrics: dict[str, int],
    result_values: dict[str, int],
    simulator_seconds: float,
) -> dict:
    """Build the stable JSON and all derived measurements."""
    search_cycles = metrics["cycles.search"]
    nodes = result_values["nodes"]
    engine_states = _named_series(metrics, "states.engine", ENGINE_STATES)
    controller_states = _named_series(metrics, "states.controller", CONTROLLER_STATES)
    if sum(engine_states.values()) != search_cycles:
        raise BuildError("Engine-state cycles do not match measured search cycles")
    if sum(controller_states.values()) != search_cycles:
        raise BuildError("Controller-state cycles do not match measured search cycles")
    simulated_seconds = search_cycles / configuration["engine_clock_hz"]
    memory_window_seconds = (
        search_cycles + metrics["cycles.drain"]
    ) / configuration["engine_clock_hz"]
    threads = []
    for tid in range(configuration["threads"]):
        phases = _named_series(metrics, f"threads.{tid}.phases", THREAD_PHASES)
        phase_total = sum(phases.values())
        if phase_total != search_cycles:
            raise BuildError(
                f"Thread {tid} phase total {phase_total} does not match search cycles {search_cycles}"
            )
        ready_breakdown = {
            name: metrics[f"threads.{tid}.ready.{name}"]
            for name in (
                "nnue_init", "dispatch", "arbitration", "tt_blocked", "noisy_move_blocked",
                "quiet_move_blocked", "transition"
            )
        }
        if sum(ready_breakdown.values()) != phases["ready"]:
            raise BuildError(
                f"Thread {tid} ready breakdown does not match ready cycles"
            )
        move_wait_breakdown = {
            kind: metrics[f"threads.{tid}.move_wait.{kind}"]
            for kind in ("noisy", "quiet")
        }
        if sum(move_wait_breakdown.values()) != phases["move_wait"]:
            raise BuildError(
                f"Thread {tid} move-wait breakdown does not match move-wait cycles"
            )
        repetition_wait_breakdown = {
            kind: metrics[f"threads.{tid}.repetition_wait.{kind}"]
            for kind in ("nnue_update", "overlap", "checker")
        }
        if sum(repetition_wait_breakdown.values()) != phases["repetition_wait"]:
            raise BuildError(
                f"Thread {tid} repetition-wait breakdown does not match repetition-wait cycles"
            )
        threads.append(
            {
                "id": tid,
                "nodes": metrics.get(f"threads.{tid}.nodes", 0),
                "phase_cycles": phases,
                "phase_percent": {name: percent(value, search_cycles) for name, value in phases.items()},
                "ready_breakdown": ready_breakdown,
                "move_wait_breakdown": move_wait_breakdown,
                "repetition_wait_breakdown": repetition_wait_breakdown,
                "move_order_cycles": _named_series(
                    metrics, f"threads.{tid}.move_order", MOVE_ORDER_STATES
                ),
                "ply_cycles": {
                    key.rsplit(".", 1)[-1]: value
                    for key, value in metrics.items()
                    if key.startswith(f"threads.{tid}.ply.")
                },
            }
        )

    tt_lookups = metrics["tt.lookups"]
    tt_hits = metrics["tt.hits"]
    cache_probes = metrics["tt.cache.lookup_probes"]
    cache_hits = metrics["tt.cache.lookup_hits"]
    if tt_hits > tt_lookups or cache_hits > cache_probes:
        raise BuildError("Profile hit counters exceed their corresponding probes")

    move_operations = {}
    for index, name in enumerate(MOVE_GENERATOR_OPERATIONS):
        prefix = f"components.move_generator.operations.{index}"
        count = metrics[f"{prefix}.count"]
        total_cycles = metrics[f"{prefix}.total_cycles"]
        maximum_cycles = metrics[f"{prefix}.max_cycles"]
        aborted = metrics[f"{prefix}.aborted"]
        if (
            maximum_cycles > total_cycles
            or aborted > count
            or (count == 0 and (total_cycles or maximum_cycles or aborted))
        ):
            raise BuildError(f"Invalid move-generator latency counters for {name}")
        move_operations[name] = {
            "count": count,
            "total_cycles": total_cycles,
            "average_cycles": rate(total_cycles, count),
            "maximum_cycles": maximum_cycles,
            "aborted_at_search_end": aborted,
        }
    if (
        sum(move_operations[name]["count"] for name in MOVE_GENERATOR_OPERATIONS[:3])
        != metrics["components.move.commands"]
        or move_operations["bucket_pop"]["count"] != metrics["components.move.pops"]
    ):
        raise BuildError("Move-generator operation counts do not match accepted requests")

    board_issues = metrics["components.board.issues"]
    board_reverses = metrics["components.board.reverses"]
    forward_board_issues = (
        metrics.get("algorithm.main_board_issues", 0)
        + metrics.get("algorithm.qsearch_board_issues", 0)
    )
    if board_reverses + forward_board_issues != board_issues:
        raise BuildError("Board-update issue classifications do not match total issues")
    legal_ordinal_total = sum(
        metrics.get(f"move_order.legal_ordinal.{index}", 0)
        for index in range(len(ORDINAL_BUCKETS))
    )
    if legal_ordinal_total != metrics["components.board.legal_candidates"]:
        raise BuildError("Legal move ordinal total does not match legal board candidates")
    if (
        metrics["components.board.legal_candidates"]
        + metrics["components.board.illegal_candidates"]
        > forward_board_issues
    ):
        raise BuildError("Board candidate completions exceed forward board-update issues")

    move_generation = {}
    for kind, operation_name in (
        ("noisy", "noisy_generation"),
        ("quiet", "quiet_generation"),
    ):
        prefix = f"components.move_generator.generation.{kind}"
        destinations = metrics[f"{prefix}.destinations_examined"]
        destinations_with_sources = metrics[f"{prefix}.destinations_with_sources"]
        candidates = metrics[f"{prefix}.candidates_emitted"]
        if destinations_with_sources > destinations:
            raise BuildError(
                f"{kind.capitalize()} destinations with sources exceed destinations examined"
            )
        generation_cycles = move_operations[operation_name]["total_cycles"]
        move_generation[kind] = {
            "destinations_examined": destinations,
            "destinations_with_at_least_one_source": destinations_with_sources,
            "candidates_emitted": candidates,
            "generation_cycles": generation_cycles,
            "cycles_per_candidate": rate(generation_cycles, candidates),
            "cycles_per_destination": rate(generation_cycles, destinations),
        }

    depth_breakdown = []
    previous_depth_nodes = 0
    depth_numbers = sorted(
        int(key.split(".")[1])
        for key in metrics
        if key.startswith("depths.") and key.endswith(".cycles")
    )
    for depth in depth_numbers:
        prefix = f"depths.{depth}"
        depth_cycles = metrics[f"{prefix}.cycles"]
        depth_node_count = metrics[f"{prefix}.nodes"]
        depth_lookups = metrics[f"{prefix}.tt_lookups"]
        depth_hits = metrics[f"{prefix}.tt_hits"]
        depth_probes = metrics[f"{prefix}.cache_probes"]
        depth_cache_hit_count = metrics[f"{prefix}.cache_hits"]
        max_ply = metrics[f"{prefix}.max_ply"]
        depth_breakdown.append(
            {
                "depth": depth,
                "cycles": depth_cycles,
                "search_cycle_percent": percent(depth_cycles, search_cycles),
                "nodes": depth_node_count,
                "cycles_per_node": rate(depth_cycles, depth_node_count),
                "node_growth_vs_previous_depth": (
                    rate(depth_node_count, previous_depth_nodes)
                    if previous_depth_nodes
                    else None
                ),
                "tt_lookups": depth_lookups,
                "tt_hits": depth_hits,
                "tt_hit_rate_percent": percent(depth_hits, depth_lookups),
                "cache_probes": depth_probes,
                "cache_hits": depth_cache_hit_count,
                "cache_hit_rate_percent": percent(depth_cache_hit_count, depth_probes),
                "maximum_ply": max_ply,
                "qsearch_extension_plies": max(0, max_ply - depth),
                "status": (
                    "complete"
                    if depth <= result_values["completed_depth"]
                    else "partial"
                ),
            }
        )
        previous_depth_nodes = depth_node_count
    if sum(depth["cycles"] for depth in depth_breakdown) != search_cycles:
        raise BuildError("Per-depth cycles do not match measured search cycles")

    active_thread_histogram = {
        str(index): metrics.get(f"concurrency.active_threads.{index}", 0)
        for index in range(configuration["threads"] + 1)
    }
    inflight_histogram = {
        str(index): metrics.get(f"concurrency.inflight.{index}", 0) for index in range(6)
    }
    if sum(active_thread_histogram.values()) != search_cycles:
        raise BuildError("Active-thread histogram does not match measured search cycles")
    if sum(inflight_histogram.values()) != search_cycles:
        raise BuildError("In-flight histogram does not match measured search cycles")

    components = {
        "board_update": {
            "issues": metrics["components.board.issues"],
            "reverses": metrics["components.board.reverses"],
            "completions": metrics["components.board.completions"],
            "legal_candidates": metrics["components.board.legal_candidates"],
            "illegal_candidates": metrics["components.board.illegal_candidates"],
        },
        "move_generator": {
            "commands": metrics["components.move.commands"],
            "pops": metrics["components.move.pops"],
            "pop_misses": metrics["components.move.pop_misses"],
            "operations": move_operations,
            "generation": move_generation,
            "state_cycles": _named_series(
                metrics, "components.move_generator.states", GENERATOR_STATES
            ),
        },
        "nnue_evaluator": {
            "evaluations": metrics["components.eval.evaluations"],
            "completions": metrics["components.eval.completions"],
            "update_requests": metrics["components.eval.update_requests"],
            "root_initialization_rows": metrics["components.eval.root_rows"],
            "child_rebuild_rows": metrics["components.eval.rebuild_rows"],
            "child_rebuilds": metrics["components.eval.rebuilds"],
            "delta_feature_requests": metrics["components.eval.delta_requests"],
            "completion_markers": metrics["components.eval.completion_markers"],
            "recovery_rebuild_rows": metrics["components.eval.recovery_rows"],
            "child_update_completions": metrics["components.eval.update_completions"],
            "update_pipeline_busy_cycles": metrics["components.eval.update_busy_cycles"],
            "update_backpressure_cycles":
                metrics["components.eval.update_backpressure_cycles"],
            "accumulator_wrap_lanes":
                metrics["components.eval.accumulator_wrap_lanes"],
        },
        "repetition_checker": {
            "requests": metrics["components.repetition.requests"],
            "responses": metrics["components.repetition.responses"],
        },
    }
    components["repetition_checker"]["inflight_child_thread_cycles"] = sum(
        thread["repetition_wait_breakdown"]["overlap"]
        + thread["repetition_wait_breakdown"]["checker"]
        for thread in threads
    )
    nnue = components["nnue_evaluator"]
    nnue_update_class_total = (
        nnue["root_initialization_rows"]
        + nnue["child_rebuild_rows"]
        + nnue["delta_feature_requests"]
        + nnue["completion_markers"]
        + nnue["recovery_rebuild_rows"]
    )
    if nnue_update_class_total != nnue["update_requests"]:
        raise BuildError("NNUE update classifications do not match accepted update requests")
    if (
        nnue["completions"] > nnue["evaluations"]
        or nnue["update_pipeline_busy_cycles"] > search_cycles
    ):
        raise BuildError("NNUE completion or per-cycle counters exceed their measurement window")
    nnue["root_initialization_cycles"] = controller_states["search_root_init"]
    nnue["update_request_utilization_percent"] = percent(
        nnue["update_requests"], search_cycles
    )
    for values in components.values():
        values["issue_utilization_percent"] = percent(
            values.get(
                "issues",
                values.get(
                    "evaluations",
                    values.get("commands", values.get("requests", 0)),
                ),
            ),
            search_cycles,
        )

    return {
        "configuration": configuration,
        "result": {
            "best_move": move_to_uci(
                Move(result_values["best_move.from"], result_values["best_move.to"])
            ),
            "promotion_bits": result_values["best_move.promotion"],
            "score": result_values["score"],
            "nodes": nodes,
            "completed_depth": result_values["completed_depth"],
            "deepest_search_ply": result_values["deepest_search_ply"],
            "qsearch_extension_beyond_completed_depth": max(
                0, result_values["deepest_search_ply"] - result_values["completed_depth"]
            ),
            "end_reason": result_values["end_reason"],
            "error": bool(result_values["error"]),
        },
        "timing": {
            "setup_cycles": metrics["cycles.setup"],
            "search_cycles": search_cycles,
            "output_cycles": metrics["cycles.output"],
            "post_search_drain_cycles": metrics["cycles.drain"],
            "simulated_search_seconds": simulated_seconds,
            "cycles_per_node": rate(search_cycles, nodes),
            "nodes_per_simulated_second": rate(nodes, simulated_seconds),
            "simulator_wall_seconds": simulator_seconds,
            "search_cycles_per_wall_second": rate(search_cycles, simulator_seconds),
            "wall_to_simulated_time_ratio": rate(simulator_seconds, simulated_seconds),
        },
        "states": {
            "engine": engine_states,
            "controller": controller_states,
        },
        "threads": threads,
        "depth_breakdown": depth_breakdown,
        "concurrency": {
            "active_threads": active_thread_histogram,
            "inflight_components": inflight_histogram,
        },
        "components": components,
        "stalls": {
            key.removeprefix("stalls."): value
            for key, value in metrics.items()
            if key.startswith("stalls.")
        },
        "move_ordering": {
            "bucket_writes": _named_series(metrics, "move_order.bucket_writes", MOVE_BUCKETS),
            "bucket_pops": _named_series(metrics, "move_order.bucket_pops", MOVE_BUCKETS),
            "bucket_cutoffs": _named_series(metrics, "move_order.bucket_cutoffs", MOVE_BUCKETS),
            "bucket_high_water": _named_series(
                metrics, "move_order.bucket_high_water", MOVE_BUCKETS
            ),
            "legal_move_ordinal": _named_series(
                metrics, "move_order.legal_ordinal", ORDINAL_BUCKETS
            ),
            "cutoff_ordinal": _named_series(
                metrics, "move_order.cutoff_ordinal", ORDINAL_BUCKETS
            ),
            "direct_move_cutoffs": metrics["move_order.direct_cutoffs"],
            "generation": {
                key.removeprefix("move_order."): value
                for key, value in metrics.items()
                if key.startswith("move_order.")
                and not key.startswith(("move_order.bucket_", "move_order.legal_", "move_order.cutoff_"))
            },
        },
        "algorithm": {
            key.removeprefix("algorithm."): value
            for key, value in metrics.items()
            if key.startswith("algorithm.")
        },
        "transposition_table": {
            "lookups": tt_lookups,
            "hits": tt_hits,
            "hit_rate_percent": percent(tt_hits, tt_lookups),
            "stores": metrics["tt.stores"],
            "store_drops": metrics["tt.store_drops"],
            "store_fifo_high_water": metrics["tt.store_fifo_high_water"],
            "store_write_preemptions": metrics["tt.store_write_preemptions"],
            "cutoff_hits": metrics["tt.cutoff_hits"],
            "ordering_only_hits": metrics["tt.ordering_hits"],
            "bound_hits": {
                name: metrics[f"tt.bound_hits.{name}"] for name in ("exact", "lower", "upper")
            },
            "cache": {
                "lookup_probes": cache_probes,
                "lookup_hits": cache_hits,
                "lookup_hit_rate_percent": percent(cache_hits, cache_probes),
                "bypass_hits": metrics["tt.cache.bypass_hits"],
                "store_probes": metrics["tt.cache.store_probes"],
                "store_hits": metrics["tt.cache.store_hits"],
            },
            "frontend_state_cycles": _named_series(
                metrics, "tt.frontend_states", TT_FRONTEND_STATES
            ),
        },
        "sdram": {
            "read_requests": metrics["sdram.read_requests"],
            "write_requests": metrics["sdram.write_requests"],
            "read_words": metrics["sdram.read_words"],
            "write_words": metrics["sdram.write_words"],
            "row_hits": metrics["sdram.row_hits"],
            "row_misses": metrics["sdram.row_misses"],
            "row_conflicts": metrics["sdram.row_conflicts"],
            "row_hit_rate_percent": percent(
                metrics["sdram.row_hits"],
                metrics["sdram.row_hits"]
                + metrics["sdram.row_misses"]
                + metrics["sdram.row_conflicts"],
            ),
            "effective_bytes_per_simulated_second": rate(
                2 * (metrics["sdram.read_words"] + metrics["sdram.write_words"]),
                memory_window_seconds,
            ),
            "state_cycles": _named_series(metrics, "sdram.states", SDRAM_STATES),
        },
        "raw_metrics": metrics,
    }


def _format_number(value: float | int | None, suffix: str = "") -> str:
    if value is None or (isinstance(value, float) and not math.isfinite(value)):
        return "n/a"
    if isinstance(value, float):
        return f"{value:,.2f}{suffix}"
    return f"{value:,}{suffix}"


def _format_percent(value: float | None) -> str:
    """Format percentages compactly with a fixed-width numeric field."""
    if value is None or not math.isfinite(value):
        return "n/a"
    return f"{value:4.1f}%"


def format_profile_report(report: dict) -> str:
    """Format a compact but detailed terminal report."""
    timing = report["timing"]
    result = report["result"]
    tt = report["transposition_table"]
    cache = tt["cache"]
    lines = [
        "FPGA Chess Engine Runtime Profile",
        "=" * 34,
        f"Position: {report['configuration']['fen']}",
        (
            f"Simulator: {report['configuration'].get('simulator', 'unspecified')} "
            f"({report['configuration'].get('simulator_threads', 1)} execution thread"
            f"{'' if report['configuration'].get('simulator_threads', 1) == 1 else 's'})"
        ),
        (
            f"Result: {result['best_move']}  score={result['score']}  "
            f"depth={result['completed_depth']}  nodes={result['nodes']:,}"
        ),
        (
            f"Deepest search ply reached (including qsearch): {result['deepest_search_ply']} "
            f"(+{result['qsearch_extension_beyond_completed_depth']} beyond completed depth)"
        ),
        (
            f"Search: {timing['search_cycles']:,} cycles, "
            f"{_format_number(timing['cycles_per_node'])} cycles/node, "
            f"{_format_number(timing['nodes_per_simulated_second'])} nodes/s"
        ),
        (
            f"Simulated FPGA search time: "
            f"{_format_number(timing['simulated_search_seconds'] * 1_000)} ms"
        ),
        (
            f"Outside measured search: command/position setup={timing['setup_cycles']:,} cycles, "
            f"result serialization={timing['output_cycles']:,} cycles, "
            f"background TT-store completion={timing['post_search_drain_cycles']:,} cycles"
        ),
        "",
        "Per-thread lifecycle (cycles and % of search)",
    ]
    lifecycle_metrics = [
        (THREAD_PHASE_LABELS["idle"], "phase", "idle"),
        (READY_BREAKDOWN_LABELS["nnue_init"], "ready", "nnue_init"),
        (READY_BREAKDOWN_LABELS["dispatch"], "ready", "dispatch"),
        (READY_BREAKDOWN_LABELS["tt_blocked"], "ready", "tt_blocked"),
        (READY_BREAKDOWN_LABELS["noisy_move_blocked"], "ready", "noisy_move_blocked"),
        (READY_BREAKDOWN_LABELS["quiet_move_blocked"], "ready", "quiet_move_blocked"),
        (READY_BREAKDOWN_LABELS["arbitration"], "ready", "arbitration"),
        (THREAD_PHASE_LABELS["tt_wait"], "phase", "tt_wait"),
        (THREAD_PHASE_LABELS["eval_wait"], "phase", "eval_wait"),
        ("Noisy move operation in flight", "move_wait", "noisy"),
        ("Quiet move operation in flight", "move_wait", "quiet"),
        (THREAD_PHASE_LABELS["board_wait"], "phase", "board_wait"),
        ("NNUE child update pending", "repetition_wait", "nnue_update"),
        ("NNUE + repetition in flight", "repetition_wait", "overlap"),
        ("Repetition check in flight", "repetition_wait", "checker"),
        (THREAD_PHASE_LABELS["reverse_wait"], "phase", "reverse_wait"),
        (THREAD_PHASE_LABELS["terminal_wait"], "phase", "terminal_wait"),
        (THREAD_PHASE_LABELS["store_publish"], "phase", "store_publish"),
        (READY_BREAKDOWN_LABELS["transition"], "ready", "transition"),
        (THREAD_PHASE_LABELS["done"], "phase", "done"),
    ]

    def lifecycle_value(thread: dict, source: str, key: str) -> int:
        if source == "phase":
            return thread["phase_cycles"][key]
        if source == "move_wait":
            return thread["move_wait_breakdown"][key]
        if source == "repetition_wait":
            return thread["repetition_wait_breakdown"][key]
        return thread["ready_breakdown"][key]

    lifecycle_metrics = [
        metric
        for metric in lifecycle_metrics
        if any(lifecycle_value(thread, metric[1], metric[2]) for thread in report["threads"])
    ]
    label_width = max(20, max(len(label) for label, _, _ in lifecycle_metrics) + 2)
    cell_width = 20
    for start in range(0, len(report["threads"]), 4):
        thread_group = report["threads"][start : start + 4]
        if start:
            lines.append("")
        lines.append(
            f"  {'Metric':<{label_width}}"
            + "".join(f"{f'T{thread['id']}':>{cell_width}}" for thread in thread_group)
        )
        lines.append(
            f"  {'-' * (label_width - 2):<{label_width}}"
            + "".join(f"{'-' * (cell_width - 2):>{cell_width}}" for _ in thread_group)
        )
        lines.append(
            f"  {'Nodes':<{label_width}}"
            + "".join(f"{thread['nodes']:>{cell_width},}" for thread in thread_group)
        )
        for label, source, key in lifecycle_metrics:
            cells = []
            for thread in thread_group:
                value = lifecycle_value(thread, source, key)
                cells.append(
                    "-"
                    if value == 0
                    else f"{value:,} ({_format_percent(percent(value, timing['search_cycles']))})"
                )
            lines.append(
                f"  {label:<{label_width}}"
                + "".join(f"{cell:>{cell_width}}" for cell in cells)
            )

    lines += ["", "Per-depth breakdown"]
    lines.append(
        "  Depth       cycles    nodes  cycles/node  node growth  TT hit rate  cache hit  max ply  status"
    )
    for depth in report["depth_breakdown"]:
        lines.append(
            f"  {depth['depth']:>5}  {depth['cycles']:>11,}  {depth['nodes']:>7,}  "
            f"{_format_number(depth['cycles_per_node']):>11}  "
            f"{_format_number(depth['node_growth_vs_previous_depth']):>11}  "
            f"{_format_percent(depth['tt_hit_rate_percent']):>11}  "
            f"{_format_percent(depth['cache_hit_rate_percent']):>9}  "
            f"{depth['maximum_ply']:>7}  {depth['status']}"
        )

    lines += ["", "Component utilization"]
    for name, values in report["components"].items():
        if name == "move_generator":
            continue
        count = values.get(
            "issues",
            values.get(
                "evaluations",
                values.get("commands", values.get("requests", 0)),
            ),
        )
        if name == "board_update":
            forward_count = count - values["reverses"]
            lines.append(
                f"  board update: {count:,} issues, "
                f"{_format_percent(values['issue_utilization_percent'])} issue utilization "
                f"({forward_count:,} candidate pushes: "
                f"{values['legal_candidates']:,} legal, "
                f"{values['illegal_candidates']:,} illegal; "
                f"{values['reverses']:,} reversals)"
            )
            continue
        if name == "nnue_evaluator":
            lines.append(
                f"  NNUE evaluator: {count:,} evaluations, "
                f"{_format_percent(values['issue_utilization_percent'])} issue utilization"
            )
            lines.append(
                f"    updates: {values['update_requests']:,} accepted "
                f"({_format_percent(values['update_request_utilization_percent'])} request utilization); "
                f"root initialization={values['root_initialization_cycles']:,} cycles; "
                f"rows: {values['root_initialization_rows']:,} root, "
                f"{values['delta_feature_requests']:,} delta rows, "
                f"{values['child_rebuild_rows']:,} child-rebuild rows, "
                f"{values['recovery_rebuild_rows']:,} recovery, "
                f"{values['completion_markers']:,} completion markers"
            )
            lines.append(
                f"    child completions={values['child_update_completions']:,}, "
                f"rebuilds={values['child_rebuilds']:,}, "
                f"accumulator wraps={values['accumulator_wrap_lanes']:,}, "
                f"update busy={values['update_pipeline_busy_cycles']:,} cycles "
                f"({_format_percent(percent(values['update_pipeline_busy_cycles'], timing['search_cycles']))})"
            )
            continue
        if name == "repetition_checker":
            lines.append(
                f"  repetition checker: {count:,} issues, "
                f"{_format_percent(values['issue_utilization_percent'])} issue utilization; "
                f"child requests in flight={values['inflight_child_thread_cycles']:,} "
                "thread-cycles"
            )
            continue
        lines.append(
            f"  {name.replace('_', ' ')}: {count:,} issues, "
            f"{_format_percent(values['issue_utilization_percent'])} issue utilization"
        )

    move_generator = report["components"]["move_generator"]
    lines += [
        "",
        "Move generator operations",
        "  Operation                 Count   Total cycles       Avg       Max",
    ]
    for name in MOVE_GENERATOR_OPERATIONS:
        operation = move_generator["operations"][name]
        lines.append(
            f"  {MOVE_GENERATOR_OPERATION_LABELS[name]:<22}"
            f"{operation['count']:>9,}"
            f"{operation['total_cycles']:>15,}"
            f"{_format_number(operation['average_cycles']):>10}"
            f"{operation['maximum_cycles']:>10,}"
        )
    lines += [
        "",
        "Move generation work",
        (
            "  Type       Destinations  With >=1 source  Candidates  "
            "Gen cycles  Cycles/candidate  Cycles/destination"
        ),
    ]
    for kind in ("noisy", "quiet"):
        generation = move_generator["generation"][kind]
        lines.append(
            f"  {kind.capitalize():<10}"
            f"{generation['destinations_examined']:>12,}"
            f"{generation['destinations_with_at_least_one_source']:>17,}"
            f"{generation['candidates_emitted']:>12,}"
            f"{generation['generation_cycles']:>12,}"
            f"{_format_number(generation['cycles_per_candidate']):>18}"
            f"{_format_number(generation['cycles_per_destination']):>20}"
        )

    lines += ["", "Stalls"]
    for name, value in report["stalls"].items():
        denominator = (
            timing["search_cycles"] + timing["post_search_drain_cycles"]
            if name.startswith("cdc_")
            else timing["search_cycles"]
        )
        lines.append(
            f"  {STALL_LABELS.get(name, name.replace('_', ' ').capitalize())}: {value:,} cycles "
            f"({_format_percent(percent(value, denominator))})"
        )

    lines += ["", "Move ordering"]
    # Hardware bucket indices run from worst to best; reports read more
    # naturally in the opposite direction.
    for bucket in reversed(MOVE_BUCKETS):
        writes = report["move_ordering"]["bucket_writes"][bucket]
        pops = report["move_ordering"]["bucket_pops"][bucket]
        cutoffs = report["move_ordering"]["bucket_cutoffs"][bucket]
        high = report["move_ordering"]["bucket_high_water"][bucket]
        lines.append(
            f"  {bucket}: writes={writes:,}, pops={pops:,}, beta cutoffs={cutoffs:,} "
            f"({_format_percent(percent(cutoffs, pops))} of pops), peak queued={high:,}"
        )
    ordinal_text = ", ".join(
        f"{bucket}={count:,}"
        for bucket, count in report["move_ordering"]["legal_move_ordinal"].items()
    )
    lines.append(f"  Legal candidates by searched rank: {ordinal_text}")
    cutoff_total = sum(report["move_ordering"]["cutoff_ordinal"].values())
    cutoff_text = ", ".join(
        f"{bucket}={count:,} ({_format_percent(percent(count, cutoff_total))})"
        for bucket, count in report["move_ordering"]["cutoff_ordinal"].items()
    )
    lines.append(f"  Beta cutoffs by searched move rank: {cutoff_text}")
    lines.append(
        f"  Direct or otherwise unbucketed beta cutoffs: "
        f"{report['move_ordering']['direct_move_cutoffs']:,}"
    )

    lines += ["", "Search algorithm"]
    for name, value in report["algorithm"].items():
        lines.append(f"  {ALGORITHM_LABELS.get(name, name.replace('_', ' ').capitalize())}: {value:,}")

    lines += [
        "",
        "Transposition table and SDRAM",
        (
            f"  TT: lookups={tt['lookups']:,}, hits={tt['hits']:,} "
            f"({_format_percent(tt['hit_rate_percent'])}), stores={tt['stores']:,}, "
            f"dropped={tt['store_drops']:,}"
        ),
        (
            f"  Cache: probes={cache['lookup_probes']:,}, hits={cache['lookup_hits']:,} "
            f"({_format_percent(cache['lookup_hit_rate_percent'])}), "
            f"busy bypasses={cache['bypass_hits']:,}"
        ),
        (
            f"  Store queue: peak={tt['store_fifo_high_water']:,}, "
            f"writes preempted by lookup misses={tt['store_write_preemptions']:,}"
        ),
        (
            f"  TT hit use: cutoffs={tt['cutoff_hits']:,}, "
            f"ordering-only={tt['ordering_only_hits']:,}"
        ),
        (
            f"  SDRAM: reads={report['sdram']['read_requests']:,}, "
            f"writes={report['sdram']['write_requests']:,}, "
            f"rows hit/miss/conflict={report['sdram']['row_hits']:,}/"
            f"{report['sdram']['row_misses']:,}/{report['sdram']['row_conflicts']:,} "
            f"({_format_percent(report['sdram']['row_hit_rate_percent'])} hit), "
            f"payload={_format_number(report['sdram']['effective_bytes_per_simulated_second'] / (1024 * 1024))} MiB/s"
        ),
        "",
        (
            f"Simulator performance: {_format_number(timing['simulator_wall_seconds'])} s wall time, "
            f"{_format_number(timing['search_cycles_per_wall_second'])} search cycles/wall s"
        ),
        (
            f"Simulation slowdown versus the configured FPGA clock: "
            f"{_format_number(timing['wall_to_simulated_time_ratio'])}x"
        ),
    ]
    return "\n".join(lines) + "\n"


def _profile_fingerprint(sources: list[Path], extra: str = "") -> str:
    digest = hashlib.sha256()
    digest.update(b"engine-profile-v2")
    digest.update(extra.encode())
    for source in sources:
        digest.update(source.as_posix().encode())
        digest.update(source.read_bytes())
    return digest.hexdigest()


def _compile_verilator(sources: list[Path], args: argparse.Namespace) -> Path:
    """Build and cache a native timed profiler executable."""
    verilator = require_tool("verilator")
    verilator_path = Path(verilator).resolve()
    verilator_stat = verilator_path.stat()
    half_period_ns = max(1, round(500_000_000 / args.engine_clock_hz))
    build_key = (
        f"threads={args.threads};stack={args.stack_depth};clock={args.engine_clock_hz};"
        f"half={half_period_ns};sim_threads={args.simulator_threads};trace={int(args.waveform)};"
        f"verilator={verilator_path}:{verilator_stat.st_size}:{verilator_stat.st_mtime_ns};"
        "native_opt=o3-lto-v1"
    )
    fingerprint = _profile_fingerprint(sources, build_key)
    build_dir = BUILD_ROOT / "profile" / "compile" / "verilator" / fingerprint[:16]
    executable = build_dir / ("profile_sim.exe" if os.name == "nt" else "profile_sim")
    fingerprint_path = build_dir / "fingerprint.txt"
    if (
        not args.force_rebuild
        and executable.exists()
        and fingerprint_path.exists()
        and fingerprint_path.read_text(encoding="utf-8").strip() == fingerprint
    ):
        return executable

    build_dir.mkdir(parents=True, exist_ok=True)
    warnings = [
        "TIMESCALEMOD", "WIDTHEXPAND", "WIDTHTRUNC", "WIDTHXZEXPAND",
        "ALWCOMBORDER", "MULTIDRIVEN", "SIDEEFFECT", "CASEINCOMPLETE",
        "LATCH", "UNOPTFLAT", "UNOPTTHREADS",
    ]
    cmd = [
        verilator,
        "--binary",
        "--timing",
        "--top-module",
        "tb_engine_profile",
        "--threads",
        str(args.simulator_threads),
        "-O3",
        "-CFLAGS",
        "-O3 -flto",
        "-LDFLAGS",
        "-flto",
        "-j",
        "0",
        "-DFPGA_CHESS_PROFILE",
        "-Wno-fatal",
        *[f"-Wno-{warning}" for warning in warnings],
        "-Mdir",
        str(build_dir),
        "-o",
        executable.name,
        f"-GENGINE_CLOCK_FREQ={args.engine_clock_hz}",
        f"-GENGINE_HALF_PERIOD_NS={half_period_ns}",
        f"-GSEARCH_THREAD_COUNT={args.threads}",
        f"-GSEARCH_STACK_DEPTH={args.stack_depth}",
    ]
    if args.waveform:
        cmd.append("--trace-fst")
    cmd.extend(str(path) for path in sources)
    code, output, _ = run_command(cmd, REPO_ROOT, build_dir / "compile.log")
    if code != 0 or not executable.exists():
        print_failure_excerpt(output)
        raise BuildError(f"Verilator profile build failed; see {rel(build_dir / 'compile.log')}")
    fingerprint_path.write_text(fingerprint + "\n", encoding="utf-8")
    return executable


def _compile_profile(manifest: dict, sources: list[Path], force: bool) -> Path:
    library_dir = BUILD_ROOT / "profile" / "compile"
    work_dir = library_dir / "modelsim_work"
    fingerprint_path = library_dir / "fingerprint.txt"
    fingerprint = _profile_fingerprint(sources)
    if not force and work_dir.exists() and fingerprint_path.exists():
        if fingerprint_path.read_text(encoding="utf-8").strip() == fingerprint:
            return work_dir
    library_dir.mkdir(parents=True, exist_ok=True)
    vlib = require_tool("vlib")
    vlog = require_tool("vlog")
    if work_dir.exists():
        # vlib can safely refresh an existing ModelSim library in place.
        pass
    else:
        code, output, _ = run_command([vlib, str(work_dir)], REPO_ROOT, library_dir / "vlib.log")
        if code != 0:
            raise BuildError(f"Could not create profile simulator library:\n{output}")
    cmd = [
        vlog,
        *manifest["simulator"]["modelsim"].get("vlog_args", ["-sv"]),
        "+define+FPGA_CHESS_PROFILE",
        "-work",
        str(work_dir),
        *[str(path) for path in sources],
    ]
    code, output, _ = run_command(cmd, REPO_ROOT, library_dir / "compile.log")
    if code != 0 or has_sim_errors(output):
        print_failure_excerpt(output)
        raise BuildError(f"Profile RTL compilation failed; see {rel(library_dir / 'compile.log')}")
    fingerprint_path.write_text(fingerprint + "\n", encoding="utf-8")
    return work_dir


def _validate_profile_args(args: argparse.Namespace) -> tuple[str, int]:
    if not 1 <= args.threads <= 16:
        raise BuildError("--threads must be between 1 and 16")
    if not 1 <= args.stack_depth <= 64:
        raise BuildError("--stack-depth must be between 1 and 64")
    if args.engine_clock_hz < 1:
        raise BuildError("--engine-clock-hz must be positive")
    if args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    if not 1 <= args.simulator_threads <= 32:
        raise BuildError("--simulator-threads must be between 1 and 32")
    if args.depth is not None:
        if not 1 <= args.depth < args.stack_depth:
            raise BuildError("--depth must be positive and smaller than --stack-depth")
        return "depth", args.depth
    if args.nodes is not None:
        if not 1 <= args.nodes <= NODE_COUNT_MAX:
            raise BuildError(f"--nodes must be between 1 and {NODE_COUNT_MAX}")
        return "nodes", args.nodes
    if args.time_ms is not None:
        if not 1 <= args.time_ms <= TIME_MAX_MS:
            raise BuildError(f"--time-ms must be between 1 and {TIME_MAX_MS}")
        return "time", args.time_ms
    return "time", 50


def command_profile(args: argparse.Namespace) -> int:
    search_kind, search_limit = _validate_profile_args(args)
    try:
        board_payload = encode_fen(args.fen)
    except ProtocolError as exc:
        raise BuildError(f"Invalid FEN: {exc}") from exc

    manifest = load_manifest()
    sources = expand_source_set(manifest, "engine-profile")
    simulator = args.simulator
    if simulator == "auto":
        simulator = "verilator" if shutil.which("verilator") else "modelsim"
    library = None
    executable = None
    if simulator == "verilator":
        executable = _compile_verilator(sources, args)
    else:
        library = _compile_profile(manifest, sources, args.force_rebuild)
    if args.output:
        run_dir = Path(args.output).expanduser().resolve()
    else:
        timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
        run_dir = BUILD_ROOT / "profile" / timestamp
    run_dir.mkdir(parents=True, exist_ok=True)
    board_path = run_dir / "board.hex"
    metrics_path = run_dir / "metrics.tsv"
    transcript_path = run_dir / "transcript.log"
    stdout_path = run_dir / f"{simulator}.stdout.log"
    transient_wave = run_dir / ("wave.wlf" if args.waveform else "transient.wlf")
    board_path.write_text("".join(f"{value:02x}\n" for value in board_payload), encoding="ascii")

    half_period_ns = max(1, round(500_000_000 / args.engine_clock_hz))
    kind_number = {"depth": 0, "nodes": 1, "time": 2}[search_kind]
    plusargs = [
        f"+BOARD_FILE={board_path}",
        f"+METRICS_FILE={metrics_path}",
        f"+SEARCH_KIND={kind_number}",
        f"+SEARCH_LIMIT={search_limit}",
    ]
    if args.event_trace:
        plusargs.append(f"+EVENTS_FILE={run_dir / 'events.jsonl'}")
    if simulator == "verilator":
        if args.waveform:
            plusargs.append(f"+WAVE_FILE={run_dir / 'wave.fst'}")
        cmd = [str(executable), *plusargs]
    else:
        vsim = require_tool("vsim")
        run_do = (
            "log -r /*; run -all; quit -f"
            if args.waveform
            else "nolog -all; run -all; quit -f"
        )
        cmd = [
            vsim,
            *manifest["simulator"]["modelsim"].get("vsim_args", ["-c", "-t", "ns"]),
            "-lib",
            str(library),
            f"-gENGINE_CLOCK_FREQ={args.engine_clock_hz}",
            f"-gENGINE_HALF_PERIOD_NS={half_period_ns}",
            f"-gSEARCH_THREAD_COUNT={args.threads}",
            f"-gSEARCH_STACK_DEPTH={args.stack_depth}",
            *plusargs,
        ]
        if not args.waveform:
            # ModelSim can discard its mandatory working WLF while quitting,
            # avoiding a needless final flush of an artifact the profiler removes.
            cmd.append("-wlfdeleteonquit")
        cmd += [
            "-wlf", str(transient_wave), "tb_engine_profile",
            "-l", str(transcript_path), "-do", run_do,
        ]
    code, output, elapsed = run_command(
        cmd, REPO_ROOT, stdout_path, timeout_seconds=args.timeout
    )
    if simulator == "verilator":
        transcript_path.write_text(output, encoding="utf-8")
    transcript = transcript_path.read_text(encoding="utf-8", errors="replace") if transcript_path.exists() else output
    if code != 0 or has_sim_errors(transcript) or not metrics_path.exists():
        print_failure_excerpt(transcript)
        if code == 124:
            raise BuildError(f"Engine profile timed out after {args.timeout:.0f}s")
        transcript_label = (
            rel(transcript_path) if transcript_path.is_relative_to(REPO_ROOT) else str(transcript_path)
        )
        raise BuildError(f"Engine profile failed; see {transcript_label}")

    metrics, result_values = parse_metric_records(metrics_path.read_text(encoding="utf-8"))
    configuration = {
        "fen": args.fen,
        "search_limit": {"kind": search_kind, "value": search_limit},
        "threads": args.threads,
        "stack_depth": args.stack_depth,
        "engine_clock_hz": args.engine_clock_hz,
        "memory_clock_hz": 100_000_000,
        "tt_entries": 5_592_405,
        "tt_cache_lines": 1024,
        "tt_initial_state": "cold",
        "memory_path": "external-cache-cdc-sdr-sdram",
        "simulator": simulator,
        "simulator_threads": args.simulator_threads if simulator == "verilator" else 1,
    }
    report = build_profile_report(configuration, metrics, result_values, elapsed)
    text_report = format_profile_report(report)
    (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (run_dir / "report.txt").write_text(text_report, encoding="utf-8")
    if simulator == "modelsim" and not args.waveform:
        transient_wave.unlink(missing_ok=True)
    print(text_report, end="")
    print(f"Artifacts: {rel(run_dir) if run_dir.is_relative_to(REPO_ROOT) else run_dir}")
    return 0
