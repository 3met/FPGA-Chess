"""UCI host process for the FPGA Chess engine."""

from __future__ import annotations

import argparse
import logging
import sys
import threading
import time
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from software.engine.protocol import (
    AckResponse,
    BAUD_RATE,
    BITS_TO_PROMOTION,
    ErrorResponse,
    PerftResultResponse,
    ProtocolError,
    SearchResultResponse,
    StatusResponse,
    STARTPOS_FEN,
    cmd_get_search_result,
    cmd_get_status,
    cmd_kill,
    cmd_make_move,
    cmd_new_game,
    cmd_perft,
    cmd_search_depth,
    cmd_search_fixed_time,
    cmd_search_nodes,
    cmd_search_on_clock,
    cmd_set_board,
    move_to_uci,
    read_response,
)
from software.engine.transport import SerialByteTransport, SerialDependencyError, SerialTimeoutError, describe_serial_ports, list_serial_ports


MAX_SEARCH_DEPTH = 31
DEFAULT_SEARCH_DEPTH = MAX_SEARCH_DEPTH
SEARCH_TIMEOUT_SECONDS = 24 * 60 * 60


class HostError(RuntimeError):
    """Raised for UCI-host-level errors."""


class FPGAClient:
    """Synchronous command/response client for the FPGA protocol."""

    def __init__(self, transport: SerialByteTransport, response_timeout: float = 10.0) -> None:
        self.transport = transport
        self.response_timeout = response_timeout
        self._normal_command_lock = threading.Lock()

    def close(self) -> None:
        self.transport.close()

    def request(self, command: bytes, timeout: float | None = None):
        with self._normal_command_lock:
            self.transport.write(command)
            return read_response(lambda size: self.transport.read_exact(size, timeout or self.response_timeout))

    def search_request(self, command: bytes):
        with self._normal_command_lock:
            self.transport.write(command)
            return read_response(lambda size: self.transport.read_exact(size, SEARCH_TIMEOUT_SECONDS))

    def kill(self) -> None:
        self.transport.write(cmd_kill())

    def remote_reset(self) -> None:
        """Reset the FPGA transport state and discard any pre-reset reply bytes."""
        self.transport.send_break()
        self.transport.reset_input_buffer()

    def initialize(self) -> None:
        """Start a clean game after BREAK, including clearing RAM-backed engine state."""
        self.remote_reset()
        response = self.request(cmd_new_game())
        if not isinstance(response, AckResponse):
            raise HostError(f"FPGA initialization returned unexpected response: {response}")


class FPGAUCIHost:
    def __init__(
        self,
        port: str | None,
        baudrate: int,
        response_timeout: float,
        logger: logging.Logger,
    ) -> None:
        try:
            import chess
        except ImportError as exc:
            raise HostError("Install python-chess to run the UCI host; legality validation is required.") from exc

        self.chess = chess
        self.port = port
        self.baudrate = baudrate
        self.response_timeout = response_timeout
        self.logger = logger
        self.client: FPGAClient | None = None
        self.board = chess.Board()
        self.position_synced = False
        self.debug = False
        self._stdout_lock = threading.Lock()
        self._search_lock = threading.Lock()
        self._search_thread: threading.Thread | None = None
        self._search_active = False
        self._hardware_search_inflight = False
        self._stop_event = threading.Event()

    def emit(self, line: str) -> None:
        with self._stdout_lock:
            print(line, flush=True)

    def connect(self) -> FPGAClient:
        if self.client is None:
            transport = SerialByteTransport(
                port=self.port,
                baudrate=self.baudrate,
                interactive_port_select=False,
            )
            client = FPGAClient(transport, response_timeout=self.response_timeout)
            try:
                # A host process has no trustworthy view of a previously running FPGA.
                # New Game also clears TT RAM, which survives the controller-only BREAK reset.
                client.initialize()
            except Exception:
                client.close()
                raise
            self.client = client
            self.position_synced = False
            self.logger.info("Connected to FPGA serial port %s at %d baud", transport.port, self.baudrate)
        return self.client

    def close(self) -> None:
        self.stop_search(wait=True)
        if self.client is not None:
            self.client.close()
            self.client = None

    def wait_for_search(self) -> None:
        thread = self._search_thread
        if thread is not None:
            thread.join()

    def stop_search(self, wait: bool = False) -> None:
        thread: threading.Thread | None
        with self._search_lock:
            active = self._search_active
            hardware_inflight = self._hardware_search_inflight
            thread = self._search_thread
        if active:
            self._stop_event.set()
        if active and hardware_inflight and self.client is not None:
            try:
                self.client.kill()
            except Exception as exc:
                self.emit(f"info string stop failed: {exc}")
                self.logger.exception("Failed to send kill")
        if wait and thread is not None:
            thread.join()

    def handle_line(self, line: str) -> bool:
        stripped = line.strip()
        if not stripped:
            return True
        tokens = stripped.split()
        known_commands = {
            "uci",
            "debug",
            "isready",
            "setoption",
            "register",
            "ucinewgame",
            "position",
            "go",
            "stop",
            "ponderhit",
            "quit",
            "fpga",
        }
        command_index = next((idx for idx, token in enumerate(tokens) if token.lower() in known_commands), None)
        if command_index is None:
            return True
        command = tokens[command_index].lower()
        args = tokens[command_index + 1 :]
        try:
            if command == "uci":
                self._handle_uci()
            elif command == "debug":
                if args and args[0].lower() in {"on", "off"}:
                    self.debug = args[0].lower() == "on"
            elif command == "isready":
                self._handle_isready()
            elif command == "setoption":
                self._handle_setoption(args)
            elif command == "register":
                pass
            elif command == "ucinewgame":
                self._handle_ucinewgame()
            elif command == "position":
                self._handle_position(args)
            elif command == "go":
                self._handle_go(args)
            elif command == "stop":
                self.stop_search(wait=False)
            elif command == "ponderhit":
                pass
            elif command == "quit":
                self.close()
                return False
            elif command == "fpga":
                self._handle_debug_command(args)
        except Exception as exc:
            self.emit(f"info string error: {exc}")
            self.logger.exception("UCI command failed: %s", stripped)
        return True

    def _handle_uci(self) -> None:
        self.emit("id name FPGA Chess")
        self.emit("id author Emet Behrendt")
        self.emit("option name Port type string default auto")
        self.emit(f"option name Baud type spin default {BAUD_RATE} min 9600 max 4000000")
        self.emit("uciok")

    def _handle_isready(self) -> None:
        if self._is_search_active():
            self.emit("readyok")
            return
        try:
            client = self.connect()
            response = client.request(cmd_get_status())
            if isinstance(response, StatusResponse) and response.error_latched:
                self.emit(f"info string engine error latched: {response.error}")
        except Exception as exc:
            self.emit(f"info string hardware not ready: {exc}")
            self.logger.exception("Readiness check failed")
        self.emit("readyok")

    def _handle_setoption(self, args: list[str]) -> None:
        lowered = [arg.lower() for arg in args]
        if "name" not in lowered:
            return
        name_idx = lowered.index("name") + 1
        value_idx = lowered.index("value") if "value" in lowered else len(args)
        name = " ".join(args[name_idx:value_idx]).lower()
        value = " ".join(args[value_idx + 1 :]) if value_idx < len(args) else ""

        if self.client is not None and name in {"port", "baud"}:
            raise HostError("Port and Baud must be set before the first hardware connection")
        if name == "port":
            self.port = None if value.lower() == "auto" else value
        elif name == "baud":
            self.baudrate = int(value)
        elif self.debug:
            self.emit(f"info string unknown option ignored: {name}")

    def _handle_ucinewgame(self) -> None:
        self.stop_search(wait=True)
        self.board = self.chess.Board()
        response = self.connect().request(cmd_new_game())
        self._raise_on_error_response(response, "ucinewgame")
        self.position_synced = True

    def _handle_debug_command(self, args: list[str]) -> None:
        """Handle manual-only FPGA diagnostics without extending the UCI protocol."""

        if not args or args[0].lower() in {"help", "?"}:
            self.emit("info string fpga commands: status, result, board, sync, reset, perft <depth>")
            return

        subcommand = args[0].lower()
        if subcommand == "board":
            self.emit(f"info string fpga fen {self.board.fen()}")
            for row in str(self.board).splitlines():
                self.emit(f"info string fpga board {row}")
            return
        if subcommand == "reset":
            self.stop_search(wait=True)
            self.connect().initialize()
            # Initialization resets FPGA command/search state, so the local position must be resent.
            self.position_synced = False
            self.emit("info string fpga reset sent; resend position before searching")
            return
        if self._is_search_active():
            raise HostError("FPGA diagnostics are unavailable while search is active")
        if subcommand == "sync":
            response = self.connect().request(cmd_set_board(self.board.fen()))
            self._raise_on_error_response(response, "sync")
            self.position_synced = True
            self.emit("info string fpga position synchronized")
            return
        if subcommand == "status":
            response = self.connect().request(cmd_get_status())
            if not isinstance(response, StatusResponse):
                raise HostError(f"status returned unexpected response: {response}")
            self.emit(
                "info string fpga status "
                f"ready={int(response.ready)} search_active={int(response.search_active)} "
                f"output_pending={int(response.output_pending)} error={self._enum_name(response.error)} "
                f"operation={response.active_operation}"
            )
            return
        if subcommand == "result":
            response = self.connect().request(cmd_get_search_result())
            if isinstance(response, SearchResultResponse):
                reason = self._enum_name(response.end_reason)
                move = self._format_bestmove(response.best_move, self.board)
                self.emit(
                    f"info string fpga result move={move} score={response.score} nodes={response.nodes} "
                    f"depth={response.completed_depth} end={reason}"
                )
                return
            if isinstance(response, ErrorResponse):
                self.emit(f"info string fpga result error={self._enum_name(response.error)}")
                return
            raise HostError(f"result returned unexpected response: {response}")
        if subcommand == "perft":
            if len(args) != 2:
                raise HostError("usage: fpga perft <depth>")
            self._handle_go(["perft", args[1]])
            return
        raise HostError(f"unknown fpga command '{args[0]}'; use 'fpga help'")

    def _handle_position(self, args: list[str]) -> None:
        if self._is_search_active():
            raise HostError("Cannot change position while search is active")
        base_fen, move_tokens = self._parse_position_args(args)
        board = self.chess.Board(base_fen)
        status = board.status()
        if status != self.chess.STATUS_VALID:
            raise HostError(f"Invalid FEN status 0x{status:x}")

        client = self.connect()
        self._raise_on_error_response(client.request(cmd_set_board(board.fen())), "set board")
        for move_token in move_tokens:
            move = board.parse_uci(move_token)
            if move not in board.legal_moves:
                raise HostError(f"Illegal move in position command: {move_token}")
            self._raise_on_error_response(client.request(cmd_make_move(move.uci())), f"make move {move_token}")
            board.push(move)

        self.board = board
        self.position_synced = True

    def _handle_go(self, args: list[str]) -> None:
        if self._is_search_active():
            self.emit("info string search already active")
            return
        if not self.position_synced:
            self._handle_position(["fen", *self.board.fen().split()])

        command, is_perft, wait_for_stop = self._build_go_command(args)
        board_snapshot = self.board.copy(stack=False)
        self._stop_event.clear()

        target = self._perft_divide_worker if is_perft else self._search_worker
        worker_args = (command[1], board_snapshot) if is_perft else (command, False, board_snapshot, wait_for_stop)
        thread = threading.Thread(
            target=target,
            args=worker_args,
            daemon=True,
        )
        with self._search_lock:
            self._search_active = True
            self._search_thread = thread
        thread.start()

    def _parse_position_args(self, args: list[str]) -> tuple[str, list[str]]:
        if not args:
            raise HostError("position command missing arguments")
        if args[0] == "startpos":
            base_fen = STARTPOS_FEN
            rest = args[1:]
        elif args[0] == "fen":
            if "moves" in args:
                moves_idx = args.index("moves")
                fen_fields = args[1:moves_idx]
                rest = args[moves_idx:]
            else:
                fen_fields = args[1:]
                rest = []
            if len(fen_fields) not in (4, 6):
                raise HostError("position fen requires 4 or 6 FEN fields")
            base_fen = " ".join(fen_fields)
        else:
            raise HostError("position must use startpos or fen")

        move_tokens: list[str] = []
        if rest:
            if rest[0] != "moves":
                raise HostError("Unexpected tokens after position base")
            move_tokens = rest[1:]
        return base_fen, move_tokens

    def _build_go_command(self, args: list[str]) -> tuple[bytes, bool, bool]:
        values = self._go_values(args)
        wait_for_stop = "infinite" in values or "ponder" in values
        if "perft" in values:
            return cmd_perft(self._parse_depth(values["perft"], "perft")), True, False
        if "depth" in values:
            return cmd_search_depth(self._parse_depth(values["depth"], "depth")), False, wait_for_stop
        if "movetime" in values:
            return cmd_search_fixed_time(self._parse_time(values["movetime"], "movetime")), False, wait_for_stop
        if "nodes" in values:
            return cmd_search_nodes(self._parse_nodes(values["nodes"])), False, wait_for_stop
        if "wtime" in values and "btime" in values:
            return (
                cmd_search_on_clock(
                    self._parse_time(values["wtime"], "wtime"),
                    self._parse_time(values["btime"], "btime"),
                    self._parse_time(values.get("winc", "0"), "winc"),
                    self._parse_time(values.get("binc", "0"), "binc"),
                ),
                False,
                wait_for_stop,
            )
        return cmd_search_depth(DEFAULT_SEARCH_DEPTH), False, wait_for_stop

    def _go_values(self, args: list[str]) -> dict[str, str]:
        value_keys = {"searchmoves", "ponder", "wtime", "btime", "winc", "binc", "movestogo", "depth", "nodes", "mate", "movetime", "infinite", "perft"}
        values: dict[str, str] = {}
        idx = 0
        while idx < len(args):
            key = args[idx].lower()
            if key == "searchmoves":
                idx += 1
                moves: list[str] = []
                while idx < len(args) and args[idx].lower() not in value_keys:
                    moves.append(args[idx])
                    idx += 1
                values[key] = " ".join(moves)
                continue
            if key in {"ponder", "infinite"}:
                values[key] = "1"
                idx += 1
                continue
            if key in value_keys:
                if idx + 1 >= len(args):
                    idx += 1
                    continue
                values[key] = args[idx + 1]
                idx += 2
                continue
            idx += 1
        if "searchmoves" in values and self.debug:
            self.emit("info string searchmoves is ignored by this FPGA protocol")
        if ("mate" in values or "movestogo" in values) and self.debug:
            self.emit("info string mate/movestogo constraints are ignored")
        return values

    def _search_worker(self, command: bytes, is_perft: bool, board_snapshot: Any, wait_for_stop: bool) -> None:
        try:
            with self._search_lock:
                self._hardware_search_inflight = True
            search_start = time.monotonic()
            response = self.connect().search_request(command)
            search_elapsed = time.monotonic() - search_start
            with self._search_lock:
                self._hardware_search_inflight = False
            if wait_for_stop and not self._stop_event.is_set():
                self._stop_event.wait()
            # UCI consumers may submit a new position as soon as bestmove is printed.
            # The FPGA response is complete here, so release the host search state first.
            self._clear_search_state()
            if isinstance(response, SearchResultResponse):
                self._emit_search_result(response, board_snapshot, search_elapsed)
            elif isinstance(response, PerftResultResponse):
                self.emit(f"info string perft depth {response.completed_depth} nodes {response.nodes}")
            elif isinstance(response, StatusResponse):
                self._emit_killed_search_result(board_snapshot)
            elif isinstance(response, ErrorResponse):
                self.emit(f"info string hardware error: {response.error}")
                self.emit("bestmove 0000")
            else:
                kind = "perft" if is_perft else "search"
                self.emit(f"info string unexpected {kind} response: {response}")
                self.emit("bestmove 0000")
        except Exception as exc:
            self.emit(f"info string search failed: {exc}")
            self.logger.exception("Search worker failed")
            self.emit("bestmove 0000")
        finally:
            self._clear_search_state()

    def _clear_search_state(self) -> None:
        """Mark a completed host search idle before exposing its terminal UCI output."""
        with self._search_lock:
            self._hardware_search_inflight = False
            self._search_active = False
            self._search_thread = None

    def _perft_divide_worker(self, depth: int, board_snapshot: Any) -> None:
        """Run FPGA perft below each locally generated root move and print a divide table."""
        total_nodes = 1 if depth == 0 else 0
        perft_complete = False
        try:
            with self._search_lock:
                self._hardware_search_inflight = True
            client = self.connect()
            if depth > 0:
                root_moves = sorted(
                    board_snapshot.legal_moves,
                    key=lambda move: self._perft_root_move_key(board_snapshot, move),
                )
                for move in root_moves:
                    if self._stop_event.is_set():
                        break
                    child_board = board_snapshot.copy(stack=False)
                    child_board.push(move)
                    setup_response = client.request(cmd_set_board(child_board.fen()))
                    if not isinstance(setup_response, AckResponse):
                        self._raise_on_error_response(setup_response, f"perft setup {move.uci()}")
                        raise HostError(f"perft setup {move.uci()} returned unexpected response: {setup_response}")
                    response = client.search_request(cmd_perft(depth - 1))
                    if not isinstance(response, PerftResultResponse):
                        self._raise_on_error_response(response, f"perft {move.uci()}")
                        raise HostError(f"perft {move.uci()} returned unexpected response: {response}")
                    total_nodes += response.nodes
                    self.emit(f"{move.uci()}: {response.nodes}")
            perft_complete = not self._stop_event.is_set()
        except Exception as exc:
            self.emit(f"info string perft failed: {exc}")
            self.logger.exception("Perft divide worker failed")
        finally:
            try:
                response = self.connect().request(cmd_set_board(board_snapshot.fen()))
                if not isinstance(response, AckResponse):
                    self._raise_on_error_response(response, "perft position restore")
                    raise HostError(f"perft position restore returned unexpected response: {response}")
                self.position_synced = True
            except Exception as exc:
                self.position_synced = False
                self.emit(f"info string perft position restore failed: {exc}")
                self.logger.exception("Failed to restore position after perft divide")
            finally:
                with self._search_lock:
                    self._hardware_search_inflight = False
                    self._search_active = False
                    self._search_thread = None
        # Emit completion only after restoring the position and releasing the search state.
        if perft_complete and self.position_synced:
            self.emit(f"Nodes searched: {total_nodes}")

    def _perft_root_move_key(self, board: Any, move: Any) -> tuple[int, int, int, int, int]:
        """Keep divide output stable, listing pawn pushes before the remaining root moves."""
        piece = board.piece_at(move.from_square)
        if piece is not None and piece.piece_type == self.chess.PAWN:
            distance = abs(move.to_square - move.from_square)
            pawn_group = 0 if distance == 8 else 1 if distance == 16 else 2
            return 0, pawn_group, move.from_square, move.to_square, move.promotion or 0
        return 1, 0, move.from_square, move.to_square, move.promotion or 0

    def _emit_search_result(
        self, response: SearchResultResponse, board_snapshot: Any, elapsed_seconds: float | None = None
    ) -> None:
        """Emit the standard UCI result fields, including host-measured throughput when available."""
        nps = ""
        elapsed = ""
        if elapsed_seconds is not None:
            elapsed = f" time {int(elapsed_seconds * 1000)}"
            nps = f" nps {int(response.nodes / max(elapsed_seconds, 1e-9))}"
        score_cp = self._eval_score_to_centipawns(response.score)
        self.emit(
            f"info depth {response.completed_depth} score cp {score_cp}{elapsed} nodes {response.nodes}{nps}"
        )
        self.emit(f"bestmove {self._format_bestmove(response.best_move, board_snapshot)}")

    @staticmethod
    def _eval_score_to_centipawns(score: int) -> int:
        """Convert the FPGA's signed 1/128-pawn score to rounded UCI centipawns."""
        magnitude = (abs(score) * 100 + 64) // 128
        return magnitude if score >= 0 else -magnitude

    def _emit_killed_search_result(self, board_snapshot: Any) -> None:
        try:
            response = self.connect().request(cmd_get_search_result())
            if isinstance(response, SearchResultResponse):
                self._emit_search_result(response, board_snapshot)
                return
        except Exception as exc:
            self.logger.exception("Failed to fetch cached search result after kill")
            self.emit(f"info string cached result unavailable after stop: {exc}")
        self.emit("bestmove 0000")

    def _format_bestmove(self, move, board_snapshot: Any) -> str:
        if move.is_null:
            return "0000"
        promote = False
        piece = board_snapshot.piece_at(move.from_square)
        if piece is not None and piece.piece_type == self.chess.PAWN:
            to_rank = self.chess.square_rank(move.to_square)
            promote = to_rank in (0, 7)
        if promote:
            promo_char = BITS_TO_PROMOTION[move.promotion]
            promotion_piece = {
                "q": self.chess.QUEEN,
                "n": self.chess.KNIGHT,
                "r": self.chess.ROOK,
                "b": self.chess.BISHOP,
            }[promo_char]
            candidate = self.chess.Move(move.from_square, move.to_square, promotion=promotion_piece)
            if candidate in board_snapshot.legal_moves:
                return candidate.uci()
        return move_to_uci(move, promote=False)

    def _raise_on_error_response(self, response, context: str) -> None:
        if isinstance(response, ErrorResponse):
            raise HostError(f"{context} failed with hardware error {response.error}")
        if isinstance(response, StatusResponse) and response.error_latched:
            raise HostError(f"{context} left hardware error latched: {response.error}")

    def _is_search_active(self) -> bool:
        with self._search_lock:
            return self._search_active

    @staticmethod
    def _enum_name(value: Any) -> str:
        """Return a stable lower-case diagnostic name for known protocol enums."""

        name = getattr(value, "name", None)
        return name.lower() if isinstance(name, str) else str(value)

    @staticmethod
    def _parse_depth(value: str, name: str) -> int:
        depth = int(value)
        if not 0 <= depth <= MAX_SEARCH_DEPTH:
            raise ProtocolError(f"{name} must be between 0 and {MAX_SEARCH_DEPTH}")
        return depth

    @staticmethod
    def _parse_time(value: str, name: str) -> int:
        milliseconds = int(value)
        if milliseconds < 0:
            raise ProtocolError(f"{name} must be nonnegative")
        return milliseconds

    @staticmethod
    def _parse_nodes(value: str) -> int:
        nodes = int(value)
        if nodes < 0:
            raise ProtocolError("nodes must be nonnegative")
        return nodes


def _configure_logging(log_path: str | None, verbose: bool) -> logging.Logger:
    logger = logging.getLogger("fpga_chess_uci")
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    handler: logging.Handler
    if log_path:
        handler = logging.FileHandler(log_path, encoding="utf-8")
    elif verbose:
        handler = logging.StreamHandler(sys.stderr)
    else:
        handler = logging.NullHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.handlers[:] = [handler]
    return logger


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the FPGA Chess UCI host.")
    parser.add_argument(
        "--port",
        help="Serial port, for example COM5 or /dev/ttyUSB0. Defaults to FPGA_CHESS_PORT or USB UART auto-detection.",
    )
    parser.add_argument("--baud", type=int, default=BAUD_RATE, help=f"Serial baud rate. Default: {BAUD_RATE}.")
    parser.add_argument("--timeout", type=float, default=10.0, help="Non-search response timeout in seconds.")
    parser.add_argument("--list-ports", action="store_true", help="List detected serial ports and exit.")
    parser.add_argument("--log", help="Optional log file.")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging to stderr when --log is omitted.")
    args = parser.parse_args(argv)

    logger = _configure_logging(args.log, args.verbose)
    if args.list_ports:
        try:
            ports = list_serial_ports()
        except SerialDependencyError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        print(describe_serial_ports(ports) if ports else "No serial ports found.")
        return 0

    try:
        host = FPGAUCIHost(args.port, args.baud, args.timeout, logger)
    except HostError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    try:
        for line in sys.stdin:
            if not host.handle_line(line):
                break
    except (SerialDependencyError, SerialTimeoutError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        host.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
