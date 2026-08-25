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
    Command,
    DebugStatResponse,
    EndReason,
    EngineError,
    Move,
    SearchResultResponse,
    StatusResponse,
    cmd_get_status,
    cmd_get_build_info,
    cmd_new_game,
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

    def test_leading_unknown_tokens_are_ignored(self):
        host = self.make_host()
        lines = self.capture_lines(host, "joho debug on")
        self.assertEqual(lines, [])
        self.assertTrue(host.debug)

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
                "info string commands: uci, isready, setoption, ucinewgame, position, go, stop, quit, debug, help",
                "info string use 'debug help' for diagnostics",
            ],
        )
        self.assertEqual(self.capture_lines(host, "nonsense"), ["info string unknown command: nonsense"])

    def test_isready_does_not_query_hardware_while_searching(self):
        host = self.make_host()
        host._search_active = True
        lines = self.capture_lines(host, "isready")
        self.assertEqual(lines, ["readyok"])

    def test_unknown_go_tokens_are_ignored(self):
        host = self.make_host()
        command, is_perft, wait_for_stop = host._build_go_command(["nonsense", "depth", "3"])
        self.assertEqual(command, bytes([Command.SEARCH_DEPTH, 3]))
        self.assertFalse(is_perft)
        self.assertFalse(wait_for_stop)

    def test_infinite_search_waits_for_stop(self):
        host = self.make_host()
        command, is_perft, wait_for_stop = host._build_go_command(["infinite"])
        self.assertEqual(command, bytes([Command.SEARCH_DEPTH, 31]))
        self.assertFalse(is_perft)
        self.assertTrue(wait_for_stop)

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


class UCIHostDiagnosticTests(unittest.TestCase):
    """Exercise diagnostics without requiring python-chess or a serial adapter."""

    def test_uci_advertises_synthesized_configuration_as_fixed_options(self):
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

        self.assertEqual(host.client.commands, [cmd_get_build_info()])
        self.assertEqual(
            lines,
            [
                "id name FPGA Chess",
                "id author Emet Behrendt",
                "option name Port type string default auto",
                "option name Baud type spin default 2000000 min 9600 max 4000000",
                "option name Threads type spin default 3 min 3 max 3",
                "option name Clock Frequency Hz type spin default 40000000 min 40000000 max 40000000",
                "option name Search Stack Depth type spin default 24 min 24 max 24",
                "uciok",
            ],
        )

    def test_uci_completes_when_build_information_is_unavailable(self):
        host = object.__new__(FPGAUCIHost)
        host.emit = (lines := []).append
        host._get_build_info = lambda: (_ for _ in ()).throw(TimeoutError("no FPGA"))
        host.logger = logging.getLogger("test_uci_build_options_failure")
        host.logger.disabled = True

        host._handle_uci()

        self.assertEqual(lines[-2:], ["info string FPGA build information unavailable: no FPGA", "uciok"])

    def test_synthesized_configuration_options_accept_only_fixed_value(self):
        host = object.__new__(FPGAUCIHost)
        host.client = mock.Mock()
        host.build_info = BuildInfoResponse(0x0123456789ABCDEF, 3, 40_000_000, 24)
        host.debug = False

        host._handle_setoption(["name", "Threads", "value", "3"])
        host._handle_setoption(["name", "Clock", "Frequency", "Hz", "value", "40000000"])
        host._handle_setoption(["name", "Search", "Stack", "Depth", "value", "24"])
        with self.assertRaisesRegex(HostError, "threads is fixed at 3"):
            host._handle_setoption(["name", "Threads", "value", "4"])

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
        host._search_thread = None
        host._stop_event = threading.Event()
        host.client = mock.Mock()

        host.stop_search()
        host.stop_search()

        host.client.kill.assert_called_once_with()

    def test_stop_before_search_write_is_honored_after_write(self):
        host = object.__new__(FPGAUCIHost)
        host._search_lock = threading.Lock()
        host._hardware_search_inflight = False
        host._stop_event = threading.Event()
        host._stop_event.set()
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
