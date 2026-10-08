"""Terminal formatting for engine profile reports."""

import math

from .profile_report import percent, rate
from .profile_schema import (
    ALGORITHM_LABELS,
    MOVE_BUCKETS,
    MOVE_GENERATOR_OPERATION_LABELS,
    MOVE_GENERATOR_OPERATIONS,
    ORDINAL_BUCKETS,
    READY_BREAKDOWN_LABELS,
    STALL_LABELS,
    TT_FIFOS,
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


def _format_lifecycle(report: dict) -> str:
    """Show exclusive phase totals with their constituent work indented below."""
    search_cycles = report["timing"]["search_cycles"]
    threads = report["threads"]
    phases = [
        ("ready", "Node control and dispatch", "ready_breakdown", [
            ("nnue_init", READY_BREAKDOWN_LABELS["nnue_init"]),
            ("dispatch", READY_BREAKDOWN_LABELS["dispatch"]),
            ("transition", READY_BREAKDOWN_LABELS["transition"]),
            ("arbitration", READY_BREAKDOWN_LABELS["arbitration"]),
            ("tt_blocked", READY_BREAKDOWN_LABELS["tt_blocked"]),
            ("noisy_move_blocked", READY_BREAKDOWN_LABELS["noisy_move_blocked"]),
            ("quiet_move_blocked", READY_BREAKDOWN_LABELS["quiet_move_blocked"]),
        ]),
        ("tt_wait", "TT probe", None, []),
        ("eval_wait", "Evaluation", None, []),
        ("move_wait", "Move generation / validation", "move_wait_breakdown", [
            ("noisy", "Noisy moves"),
            ("quiet", "Quiet moves"),
        ]),
        ("board_wait", "Board update", None, []),
        ("repetition_wait", "Child preparation", "repetition_wait_breakdown", [
            ("nnue_update", "NNUE child update pending"),
            ("overlap", "NNUE + repetition in flight"),
            ("checker", "Repetition check in flight"),
        ]),
        ("reverse_wait", "Board reverse update", None, []),
        ("terminal_wait", "Terminal scoring", None, []),
        ("store_publish", "TT store request pending", None, []),
        ("done", "Iteration handoff", None, []),
        ("idle", "Inactive", None, []),
    ]

    # Hide globally unused phases, retaining the same row order for every group.
    rows = []
    for key, label, source, children in phases:
        if not any(thread["phase_cycles"][key] for thread in threads):
            continue
        rows.append((label, "phase_cycles", key))
        for child_key, child_label in children:
            if any(thread[source][child_key] for thread in threads):
                rows.append((f"  {child_label}", source, child_key))
    label_width = max([len("Search total")] + [len(label) for label, _, _ in rows])
    lines = [
        "Per-thread lifecycle (cycles and % of search)",
        "  Top-level phases sum to search time for each thread.",
        "  Indented rows split the phase above; all percentages use full search time.",
        "  Phases with no cycles across all threads are omitted.",
    ]
    for start in range(0, len(threads), 4):
        group = threads[start : start + 4]
        counts = [search_cycles] + [thread["nodes"] for thread in group]
        counts += [thread[source][key] for _, source, key in rows for thread in group]
        count_width = max(len("cycles"), *(len(f"{count:,}") for count in counts))
        percent_width = len("% search")
        cell_width = count_width + 2 + percent_width
        lines += [
            "",
            f"  {'Phase':<{label_width}}"
            + "".join(f"  {f'T{thread['id']}':^{cell_width}}" for thread in group),
            f"  {'':<{label_width}}"
            + "".join(f"  {'cycles':>{count_width}}  {'% search':>{percent_width}}" for _ in group),
            f"  {'-' * label_width}"
            + "".join(f"  {'-' * cell_width}" for _ in group),
            f"  {'Nodes':<{label_width}}"
            + "".join(f"  {thread['nodes']:>{count_width},}  {'':>{percent_width}}" for thread in group),
        ]
        for label, source, key in rows:
            cells = []
            for thread in group:
                value = thread[source][key]
                cells.append(
                    f"  {value:>{count_width},}  "
                    f"{_format_percent(percent(value, search_cycles)):>{percent_width}}"
                )
            lines.append(f"  {label:<{label_width}}" + "".join(cells))
        lines += [
            f"  {'-' * label_width}"
            + "".join(f"  {'-' * cell_width}" for _ in group),
            f"  {'Search total':<{label_width}}"
            + "".join(
                f"  {search_cycles:>{count_width},}  "
                f"{_format_percent(percent(search_cycles, search_cycles)):>{percent_width}}"
                for _ in group
            ),
        ]
    return "\n".join(line.rstrip() for line in lines) + "\n"


def _format_depths(report: dict) -> str:
    """Format the depths measurements."""
    lines = []
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

    return "\n".join(lines).strip("\n") + "\n"


def _format_components(report: dict) -> str:
    """Format the components measurements."""
    timing = report["timing"]
    lines = []
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

    return "\n".join(lines).strip("\n") + "\n"


def _format_moves(report: dict) -> str:
    """Format the moves measurements."""
    lines = []
    move_generator = report["components"]["move_generator"]
    operation_rows = []
    for name in MOVE_GENERATOR_OPERATIONS:
        operation = move_generator["operations"][name]
        operation_rows.append(
            (
                MOVE_GENERATOR_OPERATION_LABELS[name],
                f"{operation['count']:,}",
                f"{operation['total_cycles']:,}",
                _format_number(operation["average_cycles"]),
                f"{operation['maximum_cycles']:,}",
            )
        )
    operation_headers = ("Operation", "Count", "Total cycles", "Avg", "Max")
    operation_widths = [
        max(len(operation_headers[index]), *(len(row[index]) for row in operation_rows))
        for index in range(len(operation_headers))
    ]
    lines += [
        "",
        "Move generator operations",
        "  " + " ".join(
            f"{value:<{operation_widths[index]}}" if index == 0
            else f"{value:>{operation_widths[index]}}"
            for index, value in enumerate(operation_headers)
        ),
    ]
    lines.extend(
        "  " + " ".join(
            f"{value:<{operation_widths[index]}}" if index == 0
            else f"{value:>{operation_widths[index]}}"
            for index, value in enumerate(row)
        )
        for row in operation_rows
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

    return "\n".join(lines).strip("\n") + "\n"


def _format_stalls(report: dict) -> str:
    """Format the stalls measurements."""
    timing = report["timing"]
    lines = []
    lines += ["", "Stalls", "  Percentages use search cycles; CDC uses search + drain cycles. Categories may overlap."]
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

    return "\n".join(lines).strip("\n") + "\n"


def _format_search(report: dict) -> str:
    """Format the search measurements."""
    lines = []
    lines += [
        "",
        "Move ordering",
        "  Bucket                  Writes        Pops  Beta cutoffs  Cutoff rate  Peak queued  Arena high",
        "  ------------------  ----------  ----------  ------------  -----------  -----------  ----------",
    ]
    # Hardware bucket indices run from worst to best; reports read more
    # naturally in the opposite direction.
    for bucket in reversed(MOVE_BUCKETS):
        writes = report["move_ordering"]["bucket_writes"][bucket]
        pops = report["move_ordering"]["bucket_pops"][bucket]
        cutoffs = report["move_ordering"]["bucket_cutoffs"][bucket]
        queued = report["move_ordering"]["bucket_max_occupancy"][bucket]
        arena = report["move_ordering"]["bucket_arena_high_water"][bucket]
        lines.append(
            f"  {bucket.replace('_', ' ').capitalize():<18}"
            f"{writes:>12,}{pops:>12,}{cutoffs:>14,}"
            f"{_format_percent(percent(cutoffs, pops)):>13}{queued:>13,}{arena:>12,}"
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

    return "\n".join(lines).strip("\n") + "\n"


def _format_tt_fifos(fifos: dict) -> str:
    """Compare occupancy distributions against configured FIFO storage depths."""
    headers = ("FIFO", "Unit", "Depth", "Average", "Median", "P90", "P99", "P99.9", "Peak")
    rows = []
    for name, (label, _, _) in TT_FIFOS.items():
        values = fifos[name]
        rows.append((label, values["unit"], str(values["capacity"]), *(
            _format_number(values[key]) for key in ("average", "median", "p90", "p99", "p99_9", "peak")
        )))
    widths = [max(len(header), *(len(row[index]) for row in rows)) for index, header in enumerate(headers)]
    lines = [
        "TT FIFO occupancy",
        "  Samples include empty cycles during search, before transfers on each FIFO's producer clock.",
        "  CDC occupancy uses actual pointers. Percentiles use nearest rank; peak is the highest sampled occupancy.",
    ]
    for row in [headers, *rows]:
        lines.append("  " + "  ".join(
            f"{value:<{widths[index]}}" if index < 2 else f"{value:>{widths[index]}}"
            for index, value in enumerate(row)
        ))
    return "\n".join(lines) + "\n"


def _format_tt_cache(cache: dict) -> str:
    """Show cache size, per-operation hit rates, and acceptance-to-bank-read waits."""
    headers = ("Operation", "Count", "Hits", "Hit rate", "Avg wait (cycles)", "Avg wait (ns)")
    rows = []
    for label, operation, prefix in (("Probe", "lookup", "probe"), ("Store", "store", "store")):
        rows.append((
            label, _format_number(cache[f"{operation}_probes"]),
            _format_number(cache[f"{operation}_hits"]),
            _format_percent(cache[f"{operation}_hit_rate_percent"]),
            _format_number(cache[f"average_{prefix}_wait_cycles"]),
            _format_number(cache[f"average_{prefix}_wait_ns"]),
        ))
    widths = [max(len(header), *(len(row[index]) for row in rows)) for index, header in enumerate(headers)]
    lines = [
        "TT cache",
        f"  Cache size: {cache['entries']:,} entries (three-way groups, both banks combined)",
        "  Counts cover cache accesses during search + drain. Hits require a matching position way.",
        "  Waits run from frontend acceptance to bank read, including queuing and staging, in engine cycles.",
    ]
    for row in [headers, *rows]:
        lines.append("  " + "  ".join(
            f"{value:<{widths[index]}}" if index == 0 else f"{value:>{widths[index]}}"
            for index, value in enumerate(row)
        ))
    lines.append(f"  Probe hits while external transport busy: {cache['bypass_hits']:,}")
    lines += [
        "", "  Cache operation idle time (search + drain)",
        "  Idle = engine cycles with no access of that type on either bank; ports are shared.",
        "  Probe writes fill the cache; store writes publish replacements.",
    ]
    for operation, activity in cache["port_activity"].items():
        lines.append(f"  {operation.replace('_', ' ').capitalize():<12} "
                     f"{_format_percent(activity['idle_percent'])} idle")
    return "\n".join(lines) + "\n"


def _format_tt_latency(latency: dict) -> str:
    """Compare all-request, cache-hit, and cache-miss completion times in nanoseconds."""
    headers = ("Operation", "Average", "P99", "Hit average", "Hit P99", "Miss average", "Miss P99")
    rows = []
    for operation in ("probe", "store"):
        values = latency[operation]
        rows.append((operation.capitalize(), *(
            _format_number(values[outcome][statistic])
            for outcome in ("all", "hit", "miss") for statistic in ("average_ns", "p99_ns")
        )))
    widths = [max(len(header), *(len(row[index]) for row in rows)) for index, header in enumerate(headers)]
    lines = [
        "TT latency (ns, search + drain)",
        "  Probes: frontend acceptance to response; stores: acceptance to SDRAM write acknowledgement.",
        "  Stores requiring no replacement complete at the replacement decision.",
        "  Hit/miss classification uses the initial cache probe; P99 uses nearest rank.",
    ]
    for row in [headers, *rows]:
        lines.append("  " + "  ".join(
            f"{value:<{widths[index]}}" if index == 0 else f"{value:>{widths[index]}}"
            for index, value in enumerate(row)
        ))
    for operation in ("probe", "store"):
        values = latency[operation]
        lines.append(f"  {operation.capitalize()} samples: hits={values['hit']['samples']:,}, "
                     f"misses={values['miss']['samples']:,}; unfinished={values['unfinished']:,}")
    lines.append(f"  Dropped stores excluded: {latency['store']['dropped']:,}")
    return "\n".join(lines) + "\n"


def _format_tt(report: dict) -> str:
    """Format the tt measurements."""
    tt = report["transposition_table"]
    cache = tt["cache"]
    bandwidth = tt["memory_interface"]["average_payload_bytes_per_second"]
    payload_mib_per_second = None if bandwidth is None else rate(bandwidth, 1024 * 1024)
    lines = []
    lines += [
        "",
        "Transposition table and SDRAM",
        (
            f"  TT: probes={tt['lookups']:,}, hits={tt['hits']:,} "
            f"({_format_percent(tt['hit_rate_percent'])}), stores={tt['stores']:,}, "
            f"dropped={tt['store_drops']:,}"
        ),
        (
            f"  Store queue: peak={tt['store_fifo_high_water']:,}"
        ),
        (
            f"  Writebacks queued alongside probe reads: {tt['writeback_probe_queue_overlap_cycles']:,} "
            "engine cycles (search only)"
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
            f"({_format_percent(report['sdram']['row_hit_rate_percent'])} hit)"
        ),
    ]
    lines += [
        "  Bound hits: " + ", ".join(f"{name}={value:,}" for name, value in tt["bound_hits"].items()),
    ]
    memory = tt["memory_interface"]
    lines += [
        "", "Memory interface (search + drain)",
        f"  Total probe reads: {memory['probe_reads']:,}",
        f"  Total store reads: {memory['store_reads']:,}",
        f"  Total store writes: {memory['store_writes']:,}",
        f"  Bus width: {memory['word_bits']:,} bits",
        f"  Memory clock: {_format_number(memory['clock_hz'] / 1_000_000)} MHz "
        f"({memory['transfer_mode']})",
        f"  Controller idle (no request): {_format_percent(memory['controller_idle_percent'])}",
        f"  Data bus idle (no payload): {_format_percent(memory['data_bus_idle_percent'])}",
        f"  Average payload bandwidth: {_format_number(payload_mib_per_second)} MiB/s (reads + writes)",
        "  Average includes idle cycles, row timing, refresh, and completion overhead.",
        "  Counts are accepted memory requests, including cache-hit store writes.",
        "", _format_tt_cache(cache).rstrip(), "", _format_tt_latency(tt["latency"]).rstrip(),
        "", _format_tt_fifos(tt["fifos"]).rstrip(),
    ]
    memory_stalls = {name: value for name, value in report["stalls"].items() if name.startswith(("tt_", "cdc_"))}
    if memory_stalls:
        lines += ["", _format_stalls({**report, "stalls": memory_stalls}).rstrip()]
    return "\n".join(lines).strip("\n") + "\n"


PROFILE_TOPICS = {
    "summary": "Throughput, search results, completed depths, and faults",
    "search": "Depth breakdown, move generation, ordering, and pruning",
    "pipeline": "Thread lifecycle, component activity, and stalls",
    "tt": "TT probes, cache, latency, queues, and SDRAM traffic",
    "simulation": "Simulator speed, wall time, setup, and drain overhead",
}


def _format_summary(report: dict) -> str:
    """Show throughput and results without the detailed component tables."""
    suite = "aggregate_profile" in report
    aggregate = report["aggregate_profile"] if suite else report
    timing = report["timing"]
    result = aggregate["result"]
    title = "FPGA Chess Engine Runtime Profile" + (" Suite" if suite else "")
    lines = [title, "=" * len(title)]
    if suite:
        lines.append(f"Positions: {report['position_count']}")
    else:
        lines.append(f"Position: {report['configuration']['fen']}")
        lines.append(
            f"Result: {result['best_move']}  score={result['score']}  "
            f"depth={result['completed_depth']}  nodes={result['nodes']:,}"
        )
        lines.append(f"Deepest search ply: {result['deepest_search_ply']}")
    lines += [
        f"Search: {timing['search_cycles']:,} cycles, "
        f"{_format_number(timing['cycles_per_node'])} cycles/node, "
        f"{_format_number(timing['nodes_per_simulated_second'])} nodes/s",
        f"Simulated FPGA search time: "
        f"{_format_number(timing['simulated_search_seconds'] * 1_000)} ms",
        f"Engine fault: {'yes' if result['error'] else 'no'}",
    ]
    if suite:
        lines += [
            "Simulated search time per position (average): "
            f"{_format_number(timing['simulated_search_seconds'] * 1_000 / report['position_count'])} ms",
            f"Overall profiling wall time: {_format_number(timing['profiling_wall_seconds'])} s",
        ]
        failures = [position for position in report["positions"] if position["result"]["error"]]
        if failures:
            lines += ["", "Failed positions"]
            lines.extend(f"  {position['name']}: engine fault" for position in failures)
    return "\n".join(lines) + "\n"


def _format_simulation(report: dict) -> str:
    """Distinguish suite elapsed time from the sum of position simulator times."""
    aggregate = report.get("aggregate_profile", report)
    timing = aggregate["timing"]
    configuration = report["configuration"]
    lines = [
        "Simulation",
        f"Simulator: {configuration.get('simulator', 'unspecified')}",
        f"Simulator wall time (sum for suites): {_format_number(timing['simulator_wall_seconds'])} s",
        f"Simulation throughput: {_format_number(timing['search_cycles_per_wall_second'])} search cycles/wall s",
        f"Simulation slowdown versus FPGA clock: {_format_number(timing['wall_to_simulated_time_ratio'])}x",
        f"Outside measured search: command/position setup={timing['setup_cycles']:,} cycles, "
        f"result serialization={timing['output_cycles']:,} cycles, "
        f"background TT-store completion={timing['post_search_drain_cycles']:,} cycles",
    ]
    if "aggregate_profile" in report:
        suite_timing = report["timing"]
        lines += [
            f"Concurrent position jobs: {report['jobs']}",
            f"Suite elapsed wall time: {_format_number(suite_timing['suite_wall_seconds'])} s",
            f"Suite throughput: {_format_number(suite_timing['suite_search_cycles_per_wall_second'])} search cycles/wall s",
        ]
    return "\n".join(lines) + "\n"


def format_profile_topics(report: dict, topics: list[str] | None = None) -> str:
    """Render selected topics from saved measurements, for a suite or position."""
    selected = topics or ["summary"]
    if "all" in selected:
        selected = list(PROFILE_TOPICS)
    aggregate = report.get("aggregate_profile", report)
    formatters = {
        "summary": lambda: _format_summary(report),
        "search": lambda: _format_depths(aggregate) + "\n" + _format_moves(aggregate) + "\n" + _format_search(aggregate),
        "pipeline": lambda: _format_lifecycle(aggregate) + "\n" + _format_components(aggregate) + "\n" + _format_stalls(aggregate),
        "tt": lambda: _format_tt(aggregate),
        "simulation": lambda: _format_simulation(report),
    }
    return "\n\n".join(
        f"[{topic}]\n{formatters[topic]().rstrip()}"
        for topic in dict.fromkeys(selected)
    ) + "\n"
