"""Names and labels for the profiler's stable metric schema."""

from software.engine.search_metadata import SEARCH_THREAD_PHASES


ENGINE_STATES = [
    "idle", "receive_payload", "process_payload", "board_update",
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
THREAD_PHASES = list(SEARCH_THREAD_PHASES)
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
    "refresh", "refresh_wait", "write_close_wait", "write_close",
    "write_close_precharge_wait",
]
