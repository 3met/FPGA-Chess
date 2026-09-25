"""Pure parsing and encoding for supported UCI commands."""

from __future__ import annotations

from dataclasses import dataclass

from software.engine.protocol import (
    MAX_SEARCH_DEPTH,
    STARTPOS_FEN,
    ProtocolError,
    cmd_perft,
    cmd_search_depth,
    cmd_search_fixed_time,
    cmd_search_nodes,
    cmd_search_on_clock,
)


DEFAULT_SEARCH_DEPTH = MAX_SEARCH_DEPTH
DEFAULT_MOVE_OVERHEAD_MS = 2

KNOWN_COMMANDS = frozenset({
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
    "help",
})

GO_VALUE_KEYS = frozenset({
    "searchmoves",
    "ponder",
    "wtime",
    "btime",
    "winc",
    "binc",
    "movestogo",
    "depth",
    "nodes",
    "mate",
    "movetime",
    "infinite",
    "perft",
})


@dataclass(frozen=True)
class ParsedGoCommand:
    """Encoded FPGA search request plus UCI handling metadata."""

    command: bytes
    is_perft: bool
    wait_for_stop: bool
    is_ponder: bool
    resume_command: bytes | None
    warnings: tuple[str, ...]


def split_command_line(line: str) -> tuple[str, list[str]] | None:
    """Split a command line without interpreting later tokens as commands."""
    tokens = line.strip().split()
    if not tokens:
        return None
    return tokens[0].lower(), tokens[1:]


def parse_position_args(args: list[str]) -> tuple[str, list[str]]:
    """Parse a UCI position command without mutating a chess board."""
    if not args:
        raise ValueError("position command missing arguments")
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
            raise ValueError("position fen requires 4 or 6 FEN fields")
        base_fen = " ".join(fen_fields)
    else:
        raise ValueError("position must use startpos or fen")

    if not rest:
        return base_fen, []
    if rest[0] != "moves":
        raise ValueError("Unexpected tokens after position base")
    return base_fen, rest[1:]


def parse_depth(value: str, name: str) -> int:
    depth = int(value)
    if not 0 <= depth <= MAX_SEARCH_DEPTH:
        raise ProtocolError(f"{name} must be between 0 and {MAX_SEARCH_DEPTH}")
    return depth


def parse_time(value: str, name: str) -> int:
    milliseconds = int(value)
    if milliseconds < 0:
        raise ProtocolError(f"{name} must be nonnegative")
    return milliseconds


def parse_nodes(value: str) -> int:
    nodes = int(value)
    if nodes < 0:
        raise ProtocolError("nodes must be nonnegative")
    return nodes


def _go_values(args: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    index = 0
    while index < len(args):
        key = args[index].lower()
        if key == "searchmoves":
            index += 1
            moves: list[str] = []
            while index < len(args) and args[index].lower() not in GO_VALUE_KEYS:
                moves.append(args[index])
                index += 1
            if not moves:
                raise ProtocolError("go searchmoves requires at least one move")
            values[key] = " ".join(moves)
            continue
        if key in {"ponder", "infinite"}:
            values[key] = "1"
            index += 1
            continue
        if key in GO_VALUE_KEYS:
            if index + 1 >= len(args) or args[index + 1].lower() in GO_VALUE_KEYS:
                raise ProtocolError(f"go {key} requires a value")
            values[key] = args[index + 1]
            index += 2
            continue
        index += 1
    return values


def parse_go_command(
    args: list[str],
    side_to_move_white: bool,
    move_overhead_ms: int = DEFAULT_MOVE_OVERHEAD_MS,
) -> ParsedGoCommand:
    """Parse UCI go arguments and encode the supported FPGA operation."""
    values = _go_values(args)
    is_ponder = "ponder" in values
    wait_for_stop = "infinite" in values and not is_ponder
    warnings = []
    if "searchmoves" in values:
        warnings.append("searchmoves is ignored by this FPGA protocol")
    if "mate" in values:
        warnings.append("mate constraints are ignored")

    if "perft" in values:
        command = cmd_perft(parse_depth(values["perft"], "perft"))
        return ParsedGoCommand(command, True, False, False, None, tuple(warnings))
    if "depth" in values:
        command = cmd_search_depth(parse_depth(values["depth"], "depth"))
    elif "movetime" in values:
        command = cmd_search_fixed_time(
            parse_time(values["movetime"], "movetime"),
            move_overhead_ms,
        )
    elif "nodes" in values:
        command = cmd_search_nodes(parse_nodes(values["nodes"]))
    elif "wtime" in values or "btime" in values:
        # Only the clock of the side to move is relevant to this search.
        time_key, increment_key = ("wtime", "winc") if side_to_move_white else ("btime", "binc")
        command = cmd_search_on_clock(
            parse_time(values.get(time_key, "0"), time_key),
            parse_time(values.get(increment_key, "0"), increment_key),
            parse_time(values.get("movestogo", "0"), "movestogo"),
            move_overhead_ms,
        )
    else:
        command = cmd_search_depth(DEFAULT_SEARCH_DEPTH)
    if is_ponder:
        # Pondering must not consume the ordinary move budget. Search to the
        # hardware depth ceiling, then restart the saved limit on ponderhit.
        return ParsedGoCommand(
            cmd_search_depth(DEFAULT_SEARCH_DEPTH),
            False,
            False,
            True,
            command,
            tuple(warnings),
        )
    return ParsedGoCommand(command, False, wait_for_stop, False, None, tuple(warnings))
