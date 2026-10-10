"""Names and labels for the profiler's stable metric schema."""

THREAD_PHASE_LABELS = {
    "idle": "Inactive",
    "ready": "Runnable",
    "tt_wait": "TT probe in flight",
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
    "tt_blocked": "TT probe request blocked",
    "noisy_move_blocked": "Noisy move request blocked",
    "quiet_move_blocked": "Quiet move request blocked",
    "transition": "Node/iteration transition",
}
MOVE_BUCKETS = [
    "bad_noisy_low", "bad_noisy_high", "quiet_low", "quiet_medium",
    "quiet_high", "quiet_highest", "good_noisy_low", "good_noisy_high",
]
ORDINAL_BUCKETS = ["1", "2", "3", "4", "5-8", "9-16", "17-32", "33+"]
STALL_LABELS = {
    "move_not_ready": "Move generator busy; a generation request was waiting",
    "tt_request_not_ready": "TT frontend busy; a probe request was waiting",
    "cdc_command": "SDRAM request backpressure (engine-clock samples)",
    "cdc_write": "SDRAM write backpressure (engine-clock samples)",
    "cdc_read": "SDRAM read backpressure (engine-clock samples)",
    "cdc_done": "SDRAM completion backpressure (engine-clock samples)",
}
ALGORITHM_LABELS = {
    "main_board_issues": "Main-search move pushes",
    "qsearch_board_issues": "Quiescence-search move pushes",
    "pvs_scouts": "PVS scout searches",
    "pvs_researches": "PVS full-window re-searches",
    "lmr_reduced_issues": "LMR reduced move pushes",
    "rfp_cutoffs": "Reverse futility pruning cutoffs",
    "futility_pruned_moves": "Ordinary futility-pruned moves",
    "qdelta_pruned_moves": "Quiescence delta-pruned moves",
    "terminal_checkmates": "Checkmate terminals",
    "terminal_stalemates": "Stalemate terminals",
    "terminal_main_exhausted": "Main-search nodes that exhausted every move",
    "terminal_qsearch_exhausted": "Quiescence nodes that exhausted every tactical move",
    "repetition_draws": "Repetition draws",
    "fifty_move_draws": "Fifty-move draws",
}
MOVE_GENERATOR_OPERATIONS = [
    "direct_validation", "noisy_generation", "quiet_generation", "bucket_pop",
]
MOVE_GENERATOR_OPERATION_LABELS = {
    "direct_validation": "Direct validation",
    "noisy_generation": "Noisy generation",
    "quiet_generation": "Quiet generation",
    "bucket_pop": "Bucket pop",
}


# Queue identifiers match the testbench's occupancy histogram rows.
TT_FIFOS = {
    "stores": ("Store queue", "entries", "engine"),
    "probe_metadata": ("Probe metadata", "entries", "engine"),
    "store_metadata": ("Store metadata", "entries", "engine"),
    "probe_read": ("Probe read CDC", "entries", "engine"),
    "store_read": ("Store read CDC", "entries", "engine"),
    "way_write": ("Way writeback CDC", "entries", "engine"),
    "probe_response": ("Probe response CDC", "words", "memory"),
    "store_response": ("Store response CDC", "words", "memory"),
}
