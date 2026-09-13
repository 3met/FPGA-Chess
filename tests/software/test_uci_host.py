import contextlib
import importlib.util
import io
import logging
import threading
import unittest
from unittest import mock

from software.engine.protocol import (
    AckResponse,
    BuildInfoResponse,
    DebugStatResponse,
    EndReason,
    EngineError,
    ErrorResponse,
    Move,
    SearchResultResponse,
    StatusResponse,
    cmd_get_status,
    cmd_get_build_info,
    cmd_make_move,
    cmd_new_game,
    cmd_set_board,
    cmd_search_depth,
)
from software.engine.host import (
    FPGAClient,
    FPGACommunicationError,
    FPGAUCIHost,
    HostError,
    INITIALIZATION_ATTEMPTS,
    INITIAL_STATUS_TIMEOUT_SECONDS,
    RESET_RECOVERY_SECONDS,
    _input_lines,
)
from software.engine.transport import SerialTimeoutError


@unittest.skipIf(importlib.util.find_spec("chess") is None, "python-chess is required for the UCI host")
class UCIHostSpecTests(unittest.TestCase):
    def make_host(self) -> FPGAUCIHost:
        return FPGAUCIHost(
            port="loop://",
            baudrate=2_000_000,
            response_timeout=0.01,
            logger=logging.getLogger("test_uci_host"),
        )

    def capture_lines(self, host: FPGAUCIHost, command: str) -> list[str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            host.handle_line(command)
        return [line.strip() for line in output.getvalue().splitlines() if line.strip()]

    def test_input_lines_preserves_piped_uci_input(self):
        stream = io.StringIO("uci\nisready\n")
        with mock.patch("sys.stdin", stream):
            self.assertEqual(list(_input_lines()), ["uci\n", "isready\n"])

    def test_input_lines_uses_editable_input_for_a_terminal(self):
        stream = mock.Mock()
        stream.isatty.return_value = True
        with mock.patch("sys.stdin", stream), mock.patch("builtins.input", side_effect=["uci", EOFError]):
            self.assertEqual(list(_input_lines()), ["uci"])

    def test_later_command_tokens_do_not_turn_malformed_input_into_a_command(self):
        host = self.make_host()
        lines = self.capture_lines(host, "joho debug on")
        self.assertEqual(lines, ["info string unknown command: joho"])
        self.assertFalse(host.debug)

    def test_debug_board_uses_uci_debug_command_and_includes_coordinates(self):
        host = self.make_host()
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            host.handle_line("debug board")

        self.assertEqual(
            output.getvalue().splitlines(),
            [
                "-------------------",
                "8 | r n b q k b n r",
                "7 | p p p p p p p p",
                "6 | . . . . . . . .",
                "5 | . . . . . . . .",
                "4 | . . . . . . . .",
                "3 | . . . . . . . .",
                "2 | P P P P P P P P",
                "1 | R N B Q K B N R",
                "  +----------------",
                "    a b c d e f g h",
                "FEN: rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                "-------------------",
            ],
        )

    def test_help_and_unknown_commands_report_useful_output(self):
        host = self.make_host()

        self.assertEqual(
            self.capture_lines(host, "help"),
            [
                "info string commands: uci, isready, setoption, ucinewgame, position, go, stop, ponderhit, quit, debug, help",
                "info string use 'debug help' for diagnostics",
            ],
        )
        self.assertEqual(self.capture_lines(host, "nonsense"), ["info string unknown command: nonsense"])

    def test_isready_does_not_query_hardware_while_searching(self):
        host = self.make_host()
        host._search_active = True
        lines = self.capture_lines(host, "isready")
        self.assertEqual(lines, ["readyok"])

    def test_eval_score_uci_representation(self):
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(128), ("cp", 100))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x3FFF), ("cp", 12_799))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x4000), ("mate", 128))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x4100 - 100), ("mate", 50))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x40FF), ("mate", 1))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x40FE), ("mate", 1))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(0x40FD), ("mate", 2))
        self.assertEqual(FPGAUCIHost._eval_score_to_uci(-0x40FD), ("mate", -2))

    def test_search_result_emits_uci_mate_score(self):
        host = self.make_host()
        lines: list[str] = []
        host.emit = lines.append

        host._emit_search_result(
            SearchResultResponse(
                Move(0, 0), 0x40FF, nodes=42, completed_depth=3, end_reason=EndReason.DEPTH_LIMIT
            ),
            board_snapshot=None,
        )

        self.assertEqual(lines, ["info depth 3 score mate 1 nodes 42", "bestmove 0000"])

    def test_search_result_emits_legal_ponder_move(self):
        host = self.make_host()
        lines: list[str] = []
        host.emit = lines.append

        host._emit_search_result(
            SearchResultResponse(
                Move(12, 28), 20, nodes=42, completed_depth=3,
                end_reason=EndReason.DEPTH_LIMIT, ponder_move=Move(52, 36),
            ),
            host.chess.Board(),
        )

        self.assertEqual(lines[-1], "bestmove e2e4 ponder e7e5")

    def test_search_result_omits_illegal_ponder_move(self):
        host = self.make_host()
        lines: list[str] = []
        host.emit = lines.append

        host._emit_search_result(
            SearchResultResponse(
                Move(12, 28), 20, nodes=42, completed_depth=3,
                end_reason=EndReason.DEPTH_LIMIT, ponder_move=Move(8, 16),
            ),
            host.chess.Board(),
        )

        self.assertEqual(lines[-1], "bestmove e2e4")

    def test_position_validates_all_moves_before_sending_anything(self):
        host = self.make_host()
        client = mock.Mock()
        host.connect = lambda: client
        host.position_synced = True
        original_board = host.board

        with self.assertRaisesRegex(HostError, "Illegal move.*e1e3"):
            host._handle_position(["startpos", "moves", "e2e4", "e7e5", "e1e3"])

        client.request.assert_not_called()
        self.assertIs(host.board, original_board)
        self.assertTrue(host.position_synced)

    def test_position_rejects_null_move_before_sending_anything(self):
        host = self.make_host()
        client = mock.Mock()
        host.connect = lambda: client

        with self.assertRaisesRegex(HostError, "Illegal move.*0000"):
            host._handle_position(["startpos", "moves", "0000"])

        client.request.assert_not_called()

    def test_position_skips_identical_history_and_sends_only_extensions(self):
        host = self.make_host()
        client = mock.Mock()
        client.synchronized = True
        client.request.return_value = AckResponse(status=0x01)
        host.client = client
        host.connect = lambda: client

        host._handle_position(["startpos", "moves", "e2e4"])
        initial_calls = list(client.request.call_args_list)
        host._handle_position(["startpos", "moves", "e2e4"])
        self.assertEqual(client.request.call_args_list, initial_calls)

        host._handle_position(["startpos", "moves", "e2e4", "e7e5"])
        self.assertEqual(
            client.request.call_args_list[len(initial_calls):],
            [mock.call(cmd_make_move("e7e5"))],
        )
        self.assertTrue(host.position_synced)
        self.assertEqual(host._synced_moves, ("e2e4", "e7e5"))

    def test_position_does_not_reuse_cache_when_client_lost_synchronization(self):
        host = self.make_host()
        stale_client = mock.Mock()
        stale_client.synchronized = True
        stale_client.request.return_value = AckResponse(status=0x01)
        host.client = stale_client
        host.connect = lambda: stale_client
        host._handle_position(["startpos", "moves", "e2e4"])

        stale_client.synchronized = False
        fresh_client = mock.Mock()
        fresh_client.synchronized = True
        fresh_client.request.return_value = AckResponse(status=0x01)
        host.connect = lambda: fresh_client
        host._handle_position(["startpos", "moves", "e2e4", "e7e5"])

        self.assertEqual(
            fresh_client.request.call_args_list,
            [
                mock.call(cmd_set_board(host.chess.Board().fen())),
                mock.call(cmd_make_move("e2e4")),
                mock.call(cmd_make_move("e7e5")),
            ],
        )

    def test_position_failure_invalidates_sync_and_does_not_commit_local_board(self):
        host = self.make_host()
        original_fen = host.board.fen()
        client = mock.Mock()
        client.request.side_effect = [
            AckResponse(status=0x01),
            AckResponse(status=0x01),
            ErrorResponse(error=EngineError.INTERNAL, status=0x09),
        ]
        host.connect = lambda: client

        with self.assertRaisesRegex(HostError, "make move e7e5 failed"):
            host._handle_position(["startpos", "moves", "e2e4", "e7e5"])

        self.assertFalse(host.position_synced)
        self.assertIsNone(host._synced_base_fen)
        self.assertEqual(host.board.fen(), original_fen)

    def test_position_is_marked_unsynchronized_before_each_hardware_change(self):
        host = self.make_host()
        client = mock.Mock()

        def acknowledge(_command):
            self.assertFalse(host.position_synced)
            return AckResponse(status=0x01)

        client.request.side_effect = acknowledge
        host.connect = lambda: client

        host._handle_position(["startpos", "moves", "e2e4", "e7e5"])

        self.assertTrue(host.position_synced)

    def test_all_non_null_hardware_bestmoves_must_be_legal(self):
        host = self.make_host()
        with self.assertRaisesRegex(HostError, "illegal bestmove a2a5"):
            host._format_bestmove(Move(8, 32), host.chess.Board())

    def test_null_hardware_bestmove_is_rejected_for_non_terminal_position(self):
        host = self.make_host()
        with self.assertRaisesRegex(HostError, "null bestmove for non-terminal position"):
            host._format_bestmove(Move(0, 0), host.chess.Board())


class UCIHostDiagnosticTests(unittest.TestCase):
    """Exercise diagnostics without requiring python-chess or a serial adapter."""

    def test_uci_advertises_only_runtime_options_without_touching_hardware(self):
        class Client:
            def __init__(self):
                self.commands = []

            def request(self, command):
                self.commands.append(command)
                return BuildInfoResponse(0x0123456789ABCDEF, 3, 40_000_000, 24)

        host = object.__new__(FPGAUCIHost)
        host.client = Client()
        host.build_info = None
        host.emit = (lines := []).append
        host.connect = lambda: host.client
        host.logger = logging.getLogger("test_uci_build_options")

        host._handle_uci()

        self.assertEqual(host.client.commands, [])
        self.assertEqual(
            lines,
            [
                "id name FPGA Chess",
                "id author Emet Behrendt",
                "option name Ponder type check default false",
                "option name Move Overhead type spin default 10 min 0 max 16777215",
                "uciok",
            ],
        )

    def test_uci_does_not_request_build_information(self):
        host = object.__new__(FPGAUCIHost)
        host.emit = (lines := []).append
        host._get_build_info = lambda: (_ for _ in ()).throw(TimeoutError("no FPGA"))
        host.logger = logging.getLogger("test_uci_build_options_failure")
        host.logger.disabled = True

        host._handle_uci()

        self.assertEqual(lines, [
            "id name FPGA Chess",
            "id author Emet Behrendt",
            "option name Ponder type check default false",
            "option name Move Overhead type spin default 10 min 0 max 16777215",
            "uciok",
        ])

    def test_ponder_option_is_stored_and_build_properties_are_not_options(self):
        host = object.__new__(FPGAUCIHost)
        host.client = mock.Mock()
        host.build_info = BuildInfoResponse(0x0123456789ABCDEF, 3, 40_000_000, 24)
        host.debug = False
        host.ponder_enabled = False
        host.move_overhead_ms = 10

        host._handle_setoption(["name", "Ponder", "value", "true"])
        self.assertTrue(host.ponder_enabled)
        host._handle_setoption(["name", "Move", "Overhead", "value", "25"])
        self.assertEqual(host.move_overhead_ms, 25)
        host._handle_setoption(["name", "Threads", "value", "4"])
        host.client.request.assert_not_called()

    def test_isready_withholds_readyok_for_latched_engine_error(self):
        class Client:
            def request(self, command):
                self.command = command
                return StatusResponse(status=0x09, error=EngineError.INTERNAL, active_operation=0)

        host = object.__new__(FPGAUCIHost)
        host.client = Client()
        host.build_info = None
        host._search_active = False
        host._search_lock = threading.Lock()
        host.emit = (lines := []).append
        host.connect = lambda: host.client

        host._handle_isready()

        self.assertEqual(host.client.command, cmd_get_status())
        self.assertEqual(lines, ["info string engine error latched: 5"])

    def test_isready_withholds_readyok_when_status_request_fails(self):
        host = object.__new__(FPGAUCIHost)
        host._search_active = False
        host._search_lock = threading.Lock()
        host.emit = (lines := []).append
        host.connect = lambda: (_ for _ in ()).throw(TimeoutError("no response"))
        host.logger = logging.getLogger("test_isready_failure")
        host.logger.disabled = True

        host._handle_isready()

        self.assertEqual(lines, ["info string hardware not ready: no response"])

    def test_repeated_stop_sends_only_one_in_band_kill(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._search_active = True
        host._hardware_search_inflight = True
        host._hardware_kill_requested = False
        host._search_thread = None
        host._stop_event = threading.Event()
        host.client = mock.Mock()

        host.stop_search()
        host.stop_search()

        host.client.kill.assert_called_once_with()

    def test_repeated_ponderhit_sends_one_kill(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._search_active = True
        host._search_is_ponder = True
        host._hardware_search_inflight = True
        host._hardware_kill_requested = False
        host._stop_event = threading.Event()
        host._ponderhit_event = threading.Event()
        host.client = mock.Mock()
        host.logger = logging.getLogger("test_ponderhit")

        host._handle_ponderhit()
        host._handle_ponderhit()

        host.client.kill.assert_called_once_with()

    def test_ponderhit_restarts_saved_search_limit(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._hardware_search_inflight = False
        host._hardware_kill_requested = False
        host._stop_event = threading.Event()
        host._ponderhit_event = threading.Event()
        host._ponderhit_event.set()
        resumed_result = SearchResultResponse(
            Move(6, 21), 10, nodes=12, completed_depth=2,
            end_reason=EndReason.TIME_LIMIT,
        )
        client = mock.Mock()
        client.search_request.return_value = resumed_result

        response, _elapsed = host._finish_ponder_search(
            client,
            StatusResponse(status=1, error=EngineError.NONE, active_operation=0),
            cmd_search_depth(4),
            1.0,
        )

        self.assertIs(response, resumed_result)
        client.search_request.assert_called_once()
        self.assertEqual(client.search_request.call_args.args[0], cmd_search_depth(4))

    def test_stop_during_ponder_does_not_restart(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._hardware_search_inflight = False
        host._hardware_kill_requested = False
        host._stop_event = threading.Event()
        host._stop_event.set()
        host._ponderhit_event = threading.Event()
        client = mock.Mock()
        killed = StatusResponse(status=1, error=EngineError.NONE, active_operation=0)

        response, elapsed = host._finish_ponder_search(client, killed, cmd_search_depth(4), 1.0)

        self.assertIs(response, killed)
        self.assertEqual(elapsed, 1.0)
        client.search_request.assert_not_called()

    def test_stop_before_search_write_is_honored_after_write(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._hardware_search_inflight = False
        host._hardware_kill_requested = False
        host._stop_event = threading.Event()
        host._stop_event.set()
        host._ponderhit_event = threading.Event()
        client = mock.Mock()

        host._mark_hardware_search_started(client)

        self.assertTrue(host._hardware_search_inflight)
        client.kill.assert_called_once_with()

    def test_status_diagnostic_formats_protocol_state(self):
        class Client:
            def request(self, command):
                self.command = command
                return StatusResponse(status=0x09, error=EngineError.INTERNAL, active_operation=7)

        host = object.__new__(FPGAUCIHost)
        host.client = Client()
        host.build_info = None
        host._search_active = False
        host._search_lock = threading.Lock()
        lines: list[str] = []
        host.emit = lines.append
        host.connect = lambda: host.client

        host._handle_debug_command(["status"])

        self.assertEqual(host.client.command, cmd_get_status())
        self.assertEqual(
            lines,
            ["info string status ready=1 search_active=0 output_pending=0 error=internal operation=7"],
        )

    def test_build_diagnostic_formats_all_metadata(self):
        class Client:
            def request(self, command):
                self.command = command
                return BuildInfoResponse(0x0123456789ABCDEF, 3, 40_000_000, 24)

        host = object.__new__(FPGAUCIHost)
        host.client = Client()
        host.build_info = None
        host._search_active = False
        host._search_lock = threading.Lock()
        lines: list[str] = []
        host.emit = lines.append
        host.connect = lambda: host.client

        host._handle_debug_command(["build"])

        self.assertEqual(host.client.command, cmd_get_build_info())
        self.assertEqual(
            lines,
            ["info string build id=0123456789abcdef threads=3 clock_hz=40000000 stack_depth=24"],
        )

    def test_latency_diagnostic_reports_rtt_distribution(self):
        host = object.__new__(FPGAUCIHost)
        client = mock.Mock()
        client.request.return_value = StatusResponse(
            status=0x01, error=EngineError.NONE, active_operation=0
        )
        host.client = client
        host.connect = lambda: client
        host._search_active = False
        host._search_lock = threading.Lock()
        host.emit = (lines := []).append

        timestamps = []
        for index in range(100):
            timestamps.extend([float(index), float(index) + 0.001])
        with mock.patch("software.engine.host.time.perf_counter", side_effect=timestamps):
            host._handle_debug_command(["latency", "100"])

        self.assertEqual(client.request.call_count, 100)
        self.assertEqual(
            lines,
            ["info string latency count=100 min_ms=1.000 median_ms=1.000 p95_ms=1.000"],
        )

    def test_debug_reset_does_not_initialize_a_new_connection_twice(self):
        host = object.__new__(FPGAUCIHost)
        host.client = None
        host.stop_search = mock.Mock()
        host.emit = (lines := []).append
        client = mock.Mock()
        host.connect = mock.Mock(return_value=client)

        host._debug_reset()

        host.connect.assert_called_once_with()
        client.initialize.assert_not_called()
        self.assertFalse(host.position_synced)
        self.assertEqual(lines, ["info string reset sent; resend position before searching"])

    def test_debug_reset_reinitializes_an_existing_connection_once(self):
        host = object.__new__(FPGAUCIHost)
        host.client = mock.Mock()
        host.stop_search = mock.Mock()
        host.emit = mock.Mock()

        host._debug_reset()

        host.client.initialize.assert_called_once_with()

    def test_stats_diagnostic_formats_rates_and_per_thread_cycles(self):
        class Client:
            def request(self, command):
                address = command[1]
                values = {0: 1, 1: 1, 2: 10, 3: 8, 4: 2, 5: 4, 6: 3}
                return DebugStatResponse(address=address, value=values.get(address, address - 15))

        host = object.__new__(FPGAUCIHost)
        host.client = Client()
        host._search_active = False
        host._search_lock = threading.Lock()
        lines: list[str] = []
        host.emit = lines.append
        host.connect = lambda: host.client

        host._handle_debug_command(["stats"])

        self.assertEqual(lines[0], "info string TT hits=2 lookups=8 hit_rate=25.00%")
        self.assertEqual(lines[1], "info string TT cache hits=3 lookups=4 hit_rate=75.00%")
        self.assertIn("ready=1", lines[2])
        self.assertIn("store_publish=8", lines[2])
        self.assertIn("done=10", lines[2])


class FPGAClientInitializationTests(unittest.TestCase):
    def test_remote_reset_waits_for_board_reinitialization(self):
        transport = mock.Mock()
        client = FPGAClient(transport)

        with mock.patch("software.engine.host.time.sleep") as sleep:
            client.remote_reset()

        transport.reset_output_buffer.assert_called_once_with()
        transport.send_break.assert_called_once_with()
        self.assertEqual(transport.reset_input_buffer.call_count, 2)
        sleep.assert_called_once_with(RESET_RECOVERY_SECONDS)

    def test_initialize_always_breaks_then_verifies_status_and_new_game(self):
        transport = mock.Mock()
        client = FPGAClient(transport)
        client._exchange = mock.Mock(
            side_effect=[
                StatusResponse(status=0x01, error=EngineError.NONE, active_operation=0),
                AckResponse(status=0x01),
            ]
        )
        client._remote_reset = mock.Mock()

        client.initialize()

        self.assertEqual(
            client._exchange.call_args_list,
            [
                mock.call(cmd_get_status(), max(INITIAL_STATUS_TIMEOUT_SECONDS, client.response_timeout)),
                mock.call(cmd_new_game(), client.response_timeout),
            ],
        )
        client._remote_reset.assert_called_once_with()
        self.assertTrue(client.synchronized)

    def test_initialize_retries_the_full_reset_sequence_after_failed_verification(self):
        transport = mock.Mock()
        client = FPGAClient(transport)
        client._exchange = mock.Mock(
            side_effect=[
                SerialTimeoutError("no status"),
                StatusResponse(status=0x01, error=EngineError.NONE, active_operation=0),
                AckResponse(status=0x01),
            ]
        )
        client._remote_reset = mock.Mock()

        client.initialize()

        self.assertEqual(client._remote_reset.call_count, 2)
        self.assertEqual(
            client._exchange.call_args_list,
            [
                mock.call(cmd_get_status(), max(INITIAL_STATUS_TIMEOUT_SECONDS, client.response_timeout)),
                mock.call(cmd_get_status(), max(INITIAL_STATUS_TIMEOUT_SECONDS, client.response_timeout)),
                mock.call(cmd_new_game(), client.response_timeout),
            ],
        )
        self.assertTrue(client.synchronized)

    def test_initialize_reports_after_all_reset_attempts_fail(self):
        transport = mock.Mock()
        client = FPGAClient(transport)
        client._exchange = mock.Mock(side_effect=SerialTimeoutError("no status"))
        client._remote_reset = mock.Mock()

        with self.assertRaisesRegex(RuntimeError, f"after {INITIALIZATION_ATTEMPTS} reset attempts"):
            client.initialize()

        self.assertEqual(client._remote_reset.call_count, INITIALIZATION_ATTEMPTS)
        self.assertFalse(client.synchronized)

    def test_partial_response_poisons_stream_until_reinitialized(self):
        transport = mock.Mock()
        transport.read_exact.side_effect = [bytes([0x80]), SerialTimeoutError("partial status")]
        client = FPGAClient(transport)
        client._synchronized = True

        with self.assertRaisesRegex(FPGACommunicationError, "byte-stream position is unknown"):
            client.request(cmd_get_status())
        self.assertFalse(client.synchronized)
        with self.assertRaisesRegex(FPGACommunicationError, "needs reset synchronization"):
            client.request(cmd_get_status())
        transport.write.assert_called_once_with(cmd_get_status())

    def test_unexpected_response_type_poisons_stream(self):
        transport = mock.Mock()
        client = FPGAClient(transport)
        client._synchronized = True

        with mock.patch("software.engine.host.read_response", return_value=AckResponse(status=0x01)):
            with self.assertRaisesRegex(FPGACommunicationError, "unexpected AckResponse"):
                client.request(cmd_get_status())

        self.assertFalse(client.synchronized)

    def test_search_callback_runs_after_command_write_before_response_read(self):
        events: list[str] = []
        transport = mock.Mock()
        transport.write.side_effect = lambda _command: events.append("write")
        client = FPGAClient(transport)
        client._synchronized = True

        def response_reader(_read_exact):
            events.append("read")
            return StatusResponse(status=0x01, error=EngineError.NONE, active_operation=0)

        with mock.patch("software.engine.host.read_response", side_effect=response_reader):
            client.search_request(cmd_search_depth(1), command_sent=lambda: events.append("sent"))

        self.assertEqual(events, ["write", "sent", "read"])


if __name__ == "__main__":
    unittest.main()
