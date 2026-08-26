"""Profile metric parsing and derived report construction."""

from software.engine.protocol import Move, move_to_uci

from .common import BuildError
from .profile_schema import (
    CONTROLLER_STATES,
    ENGINE_STATES,
    GENERATOR_STATES,
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATIONS,
    MOVE_ORDER_STATES,
    ORDINAL_BUCKETS,
    SDRAM_STATES,
    THREAD_PHASES,
    TT_FRONTEND_STATES,
)


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
    nnue["update_request_rate_percent"] = percent(
        nnue["update_requests"], search_cycles
    )
    for values in components.values():
        values["issue_rate_percent"] = percent(
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


def _aggregate_profile_reports(reports: list[dict], configuration: dict) -> dict:
    """Build one detailed profile from suite counters using each counter's aggregation semantics."""
    metric_names = sorted(set().union(*(report["raw_metrics"] for report in reports)))

    def is_maximum_metric(name: str) -> bool:
        return (
            name.endswith(".max_cycles")
            or name.endswith(".max_ply")
            or "high_water" in name
        )

    metrics = {
        name: (
            max(report["raw_metrics"].get(name, 0) for report in reports)
            if is_maximum_metric(name)
            else sum(report["raw_metrics"].get(name, 0) for report in reports)
        )
        for name in metric_names
    }
    completed_depths = [report["result"]["completed_depth"] for report in reports]
    result_values = {
        "best_move.from": 0,
        "best_move.to": 0,
        "best_move.promotion": 0,
        "score": 0,
        "nodes": sum(report["result"]["nodes"] for report in reports),
        "completed_depth": min(completed_depths),
        "deepest_search_ply": max(report["result"]["deepest_search_ply"] for report in reports),
        "end_reason": 0,
        "error": int(any(report["result"]["error"] for report in reports)),
    }
    aggregate_configuration = dict(configuration)
    aggregate_configuration["fen"] = f"aggregate of {len(reports)} named positions"
    aggregate = build_profile_report(
        aggregate_configuration,
        metrics,
        result_values,
        sum(report["timing"]["simulator_wall_seconds"] for report in reports),
    )
    for depth in aggregate["depth_breakdown"]:
        depth_number = depth["depth"]
        depth["positions_completed"] = sum(
            report["result"]["completed_depth"] >= depth_number
            for report in reports
        )
    return aggregate


def build_profile_suite_report(
    named_reports: list[tuple[str, dict]],
    suite_wall_seconds: float | None = None,
    jobs: int = 1,
) -> dict:
    """Aggregate additive counters and weighted rates across named positions."""
    if not named_reports:
        raise BuildError("The profiling position suite is empty")
    reports = [report for _, report in named_reports]
    total_nodes = sum(report["result"]["nodes"] for report in reports)
    total_cycles = sum(report["timing"]["search_cycles"] for report in reports)
    total_simulated_seconds = sum(report["timing"]["simulated_search_seconds"] for report in reports)
    total_wall_seconds = sum(report["timing"]["simulator_wall_seconds"] for report in reports)
    if suite_wall_seconds is None:
        suite_wall_seconds = total_wall_seconds
    tt_lookups = sum(report["transposition_table"]["lookups"] for report in reports)
    tt_hits = sum(report["transposition_table"]["hits"] for report in reports)
    cache_probes = sum(report["transposition_table"]["cache"]["lookup_probes"] for report in reports)
    cache_hits = sum(report["transposition_table"]["cache"]["lookup_hits"] for report in reports)
    row_hits = sum(report["sdram"]["row_hits"] for report in reports)
    row_misses = sum(report["sdram"]["row_misses"] for report in reports)
    row_conflicts = sum(report["sdram"]["row_conflicts"] for report in reports)
    common_configuration = dict(reports[0]["configuration"])
    common_configuration.pop("fen", None)
    common_configuration.pop("position_name", None)
    aggregate_profile = _aggregate_profile_reports(reports, common_configuration)
    return {
        "configuration": common_configuration,
        "position_count": len(reports),
        "jobs": jobs,
        "aggregate_profile": aggregate_profile,
        "positions": [
            {
                "name": name,
                "fen": report["configuration"]["fen"],
                "result": report["result"],
                "timing": report["timing"],
            }
            for name, report in named_reports
        ],
        "timing": {
            "search_cycles": total_cycles,
            "nodes": total_nodes,
            "simulated_search_seconds": total_simulated_seconds,
            "simulator_wall_seconds": total_wall_seconds,
            "suite_wall_seconds": suite_wall_seconds,
            "cycles_per_node": rate(total_cycles, total_nodes),
            "nodes_per_simulated_second": rate(total_nodes, total_simulated_seconds),
            "search_cycles_per_wall_second": rate(total_cycles, total_wall_seconds),
            "wall_to_simulated_time_ratio": rate(total_wall_seconds, total_simulated_seconds),
            "suite_search_cycles_per_wall_second": rate(total_cycles, suite_wall_seconds),
            "suite_wall_to_simulated_time_ratio": rate(suite_wall_seconds, total_simulated_seconds),
        },
        "transposition_table": {
            "lookups": tt_lookups,
            "hits": tt_hits,
            "hit_rate_percent": percent(tt_hits, tt_lookups),
            "cache_lookup_probes": cache_probes,
            "cache_lookup_hits": cache_hits,
            "cache_hit_rate_percent": percent(cache_hits, cache_probes),
        },
        "sdram": {
            "row_hits": row_hits,
            "row_misses": row_misses,
            "row_conflicts": row_conflicts,
            "row_hit_rate_percent": percent(row_hits, row_hits + row_misses + row_conflicts),
        },
    }
