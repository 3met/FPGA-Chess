"""Shared profiling measurements and report factories for Python tests."""

from tools.hardware_build.profile_report import build_profile_report
from tools.hardware_build.profile_schema import (
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATIONS,
    ORDINAL_BUCKETS,
    TT_FIFOS,
)


def sample_metrics(search_cycles: int = 10) -> dict[str, int]:
    """Return consistent counters independently of production settings."""
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
        "components.board.null_completions": 0,
        "components.board.reverse_completions": 0,
        "components.board.illegal.failed_evasion": 1,
        "components.board.illegal.king_destination": 0,
        "components.board.illegal.en_passant_exposure": 0,
        "components.board.illegal.exposed_king": 0,
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
        "algorithm.futility_pruned_moves": 2,
        "algorithm.qdelta_pruned_moves": 4,
        "tt.lookups": 2,
        "tt.hits": 1,
        "tt.stores": 1,
        "tt.store_drops": 0,
        "tt.store_fifo_high_water": 1,
        "tt.writeback_probe_queue_overlap_cycles": 1,
        "tt.bound_hits.exact": 1,
        "tt.bound_hits.lower": 0,
        "tt.bound_hits.upper": 0,
        "tt.cutoff_hits": 1,
        "tt.ordering_hits": 0,
        "tt.cache.entries": 16,
        "tt.cache.port_cycles": 20,
        "tt.cache.probe_read_cycles": 2,
        "tt.cache.probe_write_cycles": 1,
        "tt.cache.store_read_cycles": 1,
        "tt.cache.store_write_cycles": 1,
        "tt.cache.probe_wait_cycles": 3,
        "tt.cache.store_wait_cycles": 5,
        "tt.cache.lookup_probes": 2,
        "tt.cache.lookup_hits": 1,
        "tt.cache.bypass_hits": 1,
        "tt.cache.store_probes": 1,
        "tt.cache.store_hits": 0,
        "sdram.read_requests": 1,
        "sdram.probe_reads": 1,
        "sdram.store_reads": 0,
        "sdram.word_bits": 16,
        "sdram.read_words_per_request": 6,
        "sdram.clock_hz": 200,
        "sdram.idle_cycles": 4,
        "sdram.states.idle": 5,
        "sdram.states.read_data": 6,
        "sdram.states.write_cmd": 1,
        "sdram.states.write_data": 5,
        "sdram.write_requests": 1,
        "sdram.read_words": 6,
        "sdram.write_words": 6,
        "sdram.row_hits": 1,
        "sdram.row_misses": 1,
        "sdram.row_conflicts": 0,
    }
    for operation in ("probe", "store"):
        metrics[f"tt.latency.{operation}.unfinished"] = 0
        for outcome in ("hit", "miss"):
            metrics[f"tt.latency.{operation}.{outcome}.samples"] = 0
            metrics[f"tt.latency.{operation}.{outcome}.total_ps"] = 0
    metrics["tt.latency.store.dropped"] = 0
    for name in TT_FIFOS:
        # Synthetic histogram depths are independent of the engine configuration.
        capacity = 4
        prefix = f"tt.fifos.{name}"
        metrics[f"{prefix}.capacity"] = capacity
        metrics[f"{prefix}.samples"] = search_cycles
        for level in range(capacity + 1):
            metrics[f"{prefix}.occupancy.{level}"] = search_cycles if level == 0 else 0
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
    metrics["states.engine.wait_result"] = search_cycles
    metrics["states.controller.search_run"] = search_cycles
    metrics["states.controller.search_root_init"] = 0
    for phase in ("idle", "ready", "tt_wait", "eval_wait", "move_wait", "board_wait",
                  "reverse_wait", "repetition_wait", "store_publish", "terminal_wait", "done",
                  "time_scale", "time_scale_wait", "time_check"):
        metrics[f"threads.0.phases.{phase}"] = search_cycles if phase == "ready" else 0
    metrics["threads.0.move_order.direct"] = search_cycles
    metrics["components.move_generator.states.idle"] = 2 * search_cycles
    metrics["tt.frontend_states.idle"] = search_cycles
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
        metrics[f"move_order.bucket_max_occupancy.{index}"] = 1 if index == 2 else 0
        metrics[f"move_order.bucket_arena_high_water.{index}"] = 2 if index == 2 else 0
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



def build_sample_report() -> dict:
    """Build one internally consistent report shared by focused assertions."""
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
    return build_profile_report(configuration, sample_metrics(), result_values, 0.5)



def make_report(fen: str, nodes: int, wall_seconds: float) -> dict:
    """Build a position report with explicit node and wall-time measurements."""
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

