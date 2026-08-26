"""Terminal formatting for engine profile reports."""

import math

from .profile_report import percent
from .profile_schema import (
    ALGORITHM_LABELS,
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATION_LABELS,
    MOVE_GENERATOR_OPERATIONS,
    ORDINAL_BUCKETS,
    READY_BREAKDOWN_LABELS,
    STALL_LABELS,
    THREAD_PHASE_LABELS,
)


def _format_number(value: float | int | None, suffix: str = "") -> str:
    if value is None or (isinstance(value, float) and not math.isfinite(value)):
        return "n/a"
    if isinstance(value, float):
        return f"{value:,.2f}{suffix}"
    return f"{value:,}{suffix}"


def _format_percent(value: float | None) -> str:
    """Format a percentage without prose-only alignment padding."""
    if value is None or not math.isfinite(value):
        return "n/a"
    return f"{value:.1f}%"


def format_profile_report(
    report: dict,
    *,
    include_header: bool = True,
    include_simulator_performance: bool = True,
) -> str:
    """Format a compact but detailed terminal report."""
    timing = report["timing"]
    result = report["result"]
    tt = report["transposition_table"]
    cache = tt["cache"]
    lines = []
    if include_header:
        title = "FPGA Chess Engine Runtime Profile"
        lines += [
            title,
            "=" * len(title),
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
                f"Deepest search ply reached (including quiescence search): {result['deepest_search_ply']} "
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
        ]
    lines.append("Per-thread lifecycle (cycles and % of search)")
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
    label_width = max(
        20,
        max((len(label) for label, _, _ in lifecycle_metrics), default=18) + 2,
    )
    lifecycle_count_width = 11
    lifecycle_percent_width = 8
    lifecycle_suffix_width = 1 + lifecycle_percent_width
    cell_width = lifecycle_count_width + lifecycle_suffix_width
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
        lines.append((
            f"  {'Nodes':<{label_width}}"
            + "".join(
                f"{thread['nodes']:>{lifecycle_count_width},}"
                f"{'':>{lifecycle_suffix_width}}"
                for thread in thread_group
            )
        ).rstrip())
        for label, source, key in lifecycle_metrics:
            cells = []
            for thread in thread_group:
                value = lifecycle_value(thread, source, key)
                if value == 0:
                    cells.append(
                        f"{'-':>{lifecycle_count_width}}{'':>{lifecycle_suffix_width}}"
                    )
                    continue
                percentage_text = (
                    f"({_format_percent(percent(value, timing['search_cycles']))})"
                )
                percentage_cell = (
                    f" {percentage_text}"
                    if len(percentage_text) >= lifecycle_percent_width
                    else f"{percentage_text:>{lifecycle_percent_width}} "
                )
                cells.append(
                    f"{value:>{lifecycle_count_width},}{percentage_cell}"
                )
            lines.append((
                f"  {label:<{label_width}}"
                + "".join(cells)
            ).rstrip())

    aggregate_depths = bool(
        report["depth_breakdown"]
        and "positions_completed" in report["depth_breakdown"][0]
    )
    lines += [
        "",
        "Per-depth breakdown",
    ]
    depth_suffix_header = (
        f"  {'positions':>9}"
        if aggregate_depths
        else "  status"
    )
    lines.append(
        f"  {'Depth':>5}  {'cycles':>11}  {'nodes':>10}  {'cycles/node':>11}  "
        f"{'node growth':>11}  {'TT hit rate':>11}  {'cache hit':>9}  "
        f"{'max ply':>7}{depth_suffix_header}"
    )
    for depth in report["depth_breakdown"]:
        depth_suffix = (
            f"  {depth['positions_completed']:>9,}"
            if aggregate_depths
            else f"  {depth['status']}"
        )
        lines.append(
            f"  {depth['depth']:>5}  {depth['cycles']:>11,}  {depth['nodes']:>10,}  "
            f"{_format_number(depth['cycles_per_node']):>11}  "
            f"{_format_number(depth['node_growth_vs_previous_depth']):>11}  "
            f"{_format_percent(depth['tt_hit_rate_percent']):>11}  "
            f"{_format_percent(depth['cache_hit_rate_percent']):>9}  "
            f"{depth['maximum_ply']:>7}{depth_suffix}"
        )

    lines += ["", "Component activity"]
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
                f"accepted in {_format_percent(values['issue_rate_percent'])} of search cycles "
                f"({forward_count:,} candidate pushes: "
                f"{values['legal_candidates']:,} legal, "
                f"{values['illegal_candidates']:,} illegal; "
                f"{values['reverses']:,} reversals)"
            )
            continue
        if name == "nnue_evaluator":
            lines.append(
                f"  NNUE evaluator: {count:,} evaluations, "
                f"started in {_format_percent(values['issue_rate_percent'])} of search cycles"
            )
            lines.append(
                f"    updates: {values['update_requests']:,} accepted "
                f"({_format_percent(values['update_request_rate_percent'])} of search cycles); "
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
                f"accepted in {_format_percent(values['issue_rate_percent'])} of search cycles; "
                f"child requests in flight={values['inflight_child_thread_cycles']:,} "
                "thread-cycles"
            )
            continue
        lines.append(
            f"  {name.replace('_', ' ')}: {count:,} issues, "
            f"accepted in {_format_percent(values['issue_rate_percent'])} of search cycles"
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
        f"  {'Type':<8}  {'Destinations':>13}  {'With >=1 source':>16}  "
        f"{'Candidates':>12}  {'Gen cycles':>12}  "
        f"{'Cycles/candidate':>16}  {'Cycles/destination':>18}",
    ]
    for kind in ("noisy", "quiet"):
        generation = move_generator["generation"][kind]
        lines.append(
            f"  {kind.capitalize():<8}  "
            f"{generation['destinations_examined']:>13,}  "
            f"{generation['destinations_with_at_least_one_source']:>16,}  "
            f"{generation['candidates_emitted']:>12,}  "
            f"{generation['generation_cycles']:>12,}  "
            f"{_format_number(generation['cycles_per_candidate']):>16}  "
            f"{_format_number(generation['cycles_per_destination']):>18}"
        )

    lines += ["", "Stalls"]
    stall_names = [name for name in STALL_LABELS if name in report["stalls"]]
    stall_names += sorted(name for name in report["stalls"] if name not in STALL_LABELS)
    for name in stall_names:
        value = report["stalls"][name]
        denominator = (
            timing["search_cycles"] + timing["post_search_drain_cycles"]
            if name.startswith("cdc_")
            else timing["search_cycles"]
        )
        lines.append(
            f"  {STALL_LABELS.get(name, name.replace('_', ' ').capitalize())}: {value:,} cycles "
            f"({_format_percent(percent(value, denominator))})"
        )

    lines += [
        "",
        "Move ordering",
        "  Bucket                  Writes        Pops  Beta cutoffs  Cutoff rate  Peak queued",
        "  ------------------  ----------  ----------  ------------  -----------  -----------",
    ]
    # Hardware bucket indices run from worst to best; reports read more
    # naturally in the opposite direction.
    for bucket in reversed(MOVE_BUCKETS):
        writes = report["move_ordering"]["bucket_writes"][bucket]
        pops = report["move_ordering"]["bucket_pops"][bucket]
        cutoffs = report["move_ordering"]["bucket_cutoffs"][bucket]
        high = report["move_ordering"]["bucket_high_water"][bucket]
        lines.append(
            f"  {bucket.replace('_', ' ').capitalize():<18}"
            f"{writes:>12,}{pops:>12,}{cutoffs:>14,}"
            f"{_format_percent(percent(cutoffs, pops)):>13}{high:>13,}"
        )
    cutoff_total = sum(report["move_ordering"]["cutoff_ordinal"].values())
    lines += [
        "",
        "  Searched move ranks",
        "  Rank    Legal candidates  Beta cutoffs  Cutoff share",
        "  ------  ----------------  ------------  ------------",
    ]
    for bucket in ORDINAL_BUCKETS:
        legal = report["move_ordering"]["legal_move_ordinal"][bucket]
        cutoffs = report["move_ordering"]["cutoff_ordinal"][bucket]
        lines.append(
            f"  {bucket:<6}{legal:>18,}{cutoffs:>14,}"
            f"{_format_percent(percent(cutoffs, cutoff_total)):>14}"
        )
    lines.append(
        f"  Direct/unbucketed beta cutoffs: "
        f"{report['move_ordering']['direct_move_cutoffs']:,}"
    )

    lines += ["", "Search algorithm"]
    algorithm_names = [name for name in ALGORITHM_LABELS if name in report["algorithm"]]
    algorithm_names += sorted(name for name in report["algorithm"] if name not in ALGORITHM_LABELS)
    for name in algorithm_names:
        value = report["algorithm"][name]
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
    ]
    if include_simulator_performance:
        lines += [
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

def format_profile_suite_report(report: dict) -> str:
    """Format a detailed aggregate report without dumping individual positions."""
    timing = report["timing"]
    aggregate = report["aggregate_profile"]
    aggregate_timing = aggregate["timing"]
    configuration = report["configuration"]
    limit = configuration["search_limit"]
    limit_text = {
        "depth": f"depth {limit['value']}",
        "nodes": f"{limit['value']:,} node{'' if limit['value'] == 1 else 's'}",
        "time": f"{limit['value']:,} ms",
    }[limit["kind"]]
    title = "FPGA Chess Engine Runtime Profile Suite"
    lines = [
        title,
        "=" * len(title),
        (
            f"Positions: {report['position_count']}; search threads: {configuration['threads']}; "
            f"search limit: {limit_text}"
        ),
        f"Simulator: {configuration['simulator']}",
        (
            f"Aggregate search: {timing['search_cycles']:,} cycles, {timing['nodes']:,} nodes, "
            f"{_format_number(timing['cycles_per_node'])} cycles/node"
        ),
        (
            f"Simulated FPGA search time: "
            f"{_format_number(timing['simulated_search_seconds'] * 1_000)} ms; "
            f"throughput: {_format_number(timing['nodes_per_simulated_second'])} nodes/s"
        ),
        (
            f"Outside measured search: command/position setup={aggregate_timing['setup_cycles']:,} cycles, "
            f"result serialization={aggregate_timing['output_cycles']:,} cycles, "
            f"background TT-store completion={aggregate_timing['post_search_drain_cycles']:,} cycles"
        ),
        "",
        format_profile_report(
            aggregate,
            include_header=False,
            include_simulator_performance=False,
        ).rstrip(),
        "",
        "Suite simulation performance",
        (
            f"  Elapsed wall time: {_format_number(timing['suite_wall_seconds'])} s"
        ),
        (
            f"  Aggregate simulation throughput: "
            f"{_format_number(timing['suite_search_cycles_per_wall_second'])} "
            "search cycles/wall s"
        ),
        (
            f"  Wall time / aggregate simulated search time: "
            f"{_format_number(timing['suite_wall_to_simulated_time_ratio'])}x"
        ),
    ]
    return "\n".join(lines) + "\n"
