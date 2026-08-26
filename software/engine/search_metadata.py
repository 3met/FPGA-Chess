"""Stable host-facing names for synthesized search instrumentation."""

SEARCH_THREAD_PHASES = (
    "idle",
    "ready",
    "tt_wait",
    "eval_wait",
    "move_wait",
    "board_wait",
    "reverse_wait",
    "repetition_wait",
    "store_publish",
    "terminal_wait",
    "done",
)

# The runtime debug counters omit the inactive phase.
SEARCH_STAT_PHASES = SEARCH_THREAD_PHASES[1:]
