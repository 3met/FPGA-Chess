"""FPGA Chess host protocol encoding and response parsing.

The functions in this module intentionally use only the Python standard
library so they can be tested without a serial port or chess package.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Callable


BAUD_RATE = 2_000_000
FULL_BOARD_BYTES = 36
TIME_MAX_MS = (1 << 24) - 1
NODE_COUNT_MAX = (1 << 40) - 1

STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


class ProtocolError(ValueError):
    """Raised when host protocol data is malformed."""


class Command(IntEnum):
    GET_STATUS = 0x00
    SET_BOARD = 0x01
    MAKE_MOVE = 0x02
    UNDO_MOVE = 0x03
    NEW_GAME = 0x04
    SEARCH_DEPTH = 0x10
    SEARCH_FIXED_TIME = 0x11
    SEARCH_ON_CLOCK = 0x12
    SEARCH_NODES = 0x13
    PERFT = 0x14
    KILL = 0x1F
    GET_SEARCH_RESULT = 0x20


class ResponseType(IntEnum):
    STATUS = 0x80
    ACK = 0x81
    SEARCH_RESULT = 0x82
    PERFT_RESULT = 0x83
    ERROR = 0xFF


class EngineError(IntEnum):
    NONE = 0
    UNKNOWN_OPCODE = 1
    MALFORMED_PAYLOAD = 2
    RX_OVERFLOW = 3
    UART_FRAMING = 4
    INTERNAL = 5


class EndReason(IntEnum):
    NORMAL = 0
    DEPTH_LIMIT = 1
    TIME_LIMIT = 2
    NODE_LIMIT = 3
    KILLED = 4
    ERROR = 5


PROMOTION_TO_BITS = {
    "q": 0,
    "n": 1,
    "r": 2,
    "b": 3,
}

BITS_TO_PROMOTION = {
    0: "q",
    1: "n",
    2: "r",
    3: "b",
}

PIECE_TO_TILE = {
    "P": 0x1,
    "N": 0x2,
    "B": 0x3,
    "R": 0x4,
    "Q": 0x5,
    "K": 0x6,
    "p": 0x9,
    "n": 0xA,
    "b": 0xB,
    "r": 0xC,
    "q": 0xD,
    "k": 0xE,
}


@dataclass(frozen=True)
class Move:
    """A 14-bit engine move represented in host-friendly form."""

    from_square: int
    to_square: int
    promotion: int = 0

    @property
    def is_null(self) -> bool:
        return self.from_square == 0 and self.to_square == 0


@dataclass(frozen=True)
class StatusResponse:
    status: int
    error: EngineError | int
    active_operation: int

    @property
    def ready(self) -> bool:
        return bool(self.status & 0x01)

    @property
    def search_active(self) -> bool:
        return bool(self.status & 0x02)

    @property
    def output_pending(self) -> bool:
        return bool(self.status & 0x04)

    @property
    def error_latched(self) -> bool:
        return bool(self.status & 0x08)


@dataclass(frozen=True)
class AckResponse:
    status: int


@dataclass(frozen=True)
class SearchResultResponse:
    best_move: Move
    score: int
    nodes: int
    completed_depth: int
    end_reason: EndReason | int


@dataclass(frozen=True)
class PerftResultResponse:
    nodes: int
    completed_depth: int


@dataclass(frozen=True)
class ErrorResponse:
    error: EngineError | int
    status: int


EngineResponse = (
    StatusResponse
    | AckResponse
    | SearchResultResponse
    | PerftResultResponse
    | ErrorResponse
)


def _enum_or_int(enum_type: type[IntEnum], value: int) -> IntEnum | int:
    try:
        return enum_type(value)
    except ValueError:
        return value


def square_name_to_index(square: str) -> int:
    if len(square) != 2:
        raise ProtocolError(f"Invalid square '{square}'")
    file_ch, rank_ch = square[0], square[1]
    if file_ch < "a" or file_ch > "h" or rank_ch < "1" or rank_ch > "8":
        raise ProtocolError(f"Invalid square '{square}'")
    return (ord(rank_ch) - ord("1")) * 8 + (ord(file_ch) - ord("a"))


def square_index_to_name(index: int) -> str:
    if not 0 <= index < 64:
        raise ProtocolError(f"Invalid square index {index}")
    return f"{chr(ord('a') + index % 8)}{index // 8 + 1}"


def encode_move(move: Move) -> bytes:
    if not 0 <= move.from_square < 64 or not 0 <= move.to_square < 64:
        raise ProtocolError(f"Move square out of range: {move}")
    if not 0 <= move.promotion < 4:
        raise ProtocolError(f"Promotion bits out of range: {move.promotion}")
    return bytes([(move.to_square << 2) | move.promotion, move.from_square])


def decode_move(data: bytes) -> Move:
    if len(data) != 2:
        raise ProtocolError(f"Move encoding needs 2 bytes, got {len(data)}")
    if data[1] & 0xC0:
        raise ProtocolError("Move reserved bits are set")
    return Move(from_square=data[1] & 0x3F, to_square=data[0] >> 2, promotion=data[0] & 0x03)


def encode_uci_move(uci_move: str) -> bytes:
    move = parse_uci_move(uci_move)
    return encode_move(move)


def parse_uci_move(uci_move: str) -> Move:
    if uci_move == "0000":
        return Move(0, 0, 0)
    if len(uci_move) not in (4, 5):
        raise ProtocolError(f"Invalid UCI move '{uci_move}'")
    from_square = square_name_to_index(uci_move[:2])
    to_square = square_name_to_index(uci_move[2:4])
    promotion = 0
    if len(uci_move) == 5:
        promo_ch = uci_move[4].lower()
        if promo_ch not in PROMOTION_TO_BITS:
            raise ProtocolError(f"Invalid promotion piece '{uci_move[4]}'")
        promotion = PROMOTION_TO_BITS[promo_ch]
    return Move(from_square, to_square, promotion)


def move_to_uci(move: Move, promote: bool = False) -> str:
    if move.is_null:
        return "0000"
    suffix = BITS_TO_PROMOTION[move.promotion] if promote else ""
    return f"{square_index_to_name(move.from_square)}{square_index_to_name(move.to_square)}{suffix}"


def _parse_fen_fields(fen: str) -> list[str]:
    fields = fen.strip().split()
    if len(fields) == 4:
        fields += ["0", "1"]
    if len(fields) != 6:
        raise ProtocolError("FEN must have 4 or 6 fields")
    return fields


def encode_fen(fen: str) -> bytes:
    """Encode a FEN position as the documented 36-byte FullBoard payload."""

    board_part, turn, castling, en_passant, halfmove_clock, _fullmove = _parse_fen_fields(fen)
    tiles = [0] * 64
    ranks = board_part.split("/")
    if len(ranks) != 8:
        raise ProtocolError("FEN board must have 8 ranks")

    for fen_rank_index, rank_text in enumerate(ranks):
        rank = 7 - fen_rank_index
        file_index = 0
        for ch in rank_text:
            if ch.isdigit():
                empty_count = int(ch)
                if empty_count < 1 or empty_count > 8:
                    raise ProtocolError(f"Invalid empty-square count '{ch}'")
                file_index += empty_count
                continue
            if ch not in PIECE_TO_TILE:
                raise ProtocolError(f"Invalid FEN piece '{ch}'")
            if file_index >= 8:
                raise ProtocolError("FEN rank has too many files")
            tiles[rank * 8 + file_index] = PIECE_TO_TILE[ch]
            file_index += 1
        if file_index != 8:
            raise ProtocolError("FEN rank does not contain 8 files")

    if turn not in ("w", "b"):
        raise ProtocolError("FEN turn must be 'w' or 'b'")

    if castling != "-":
        seen = set()
        for ch in castling:
            if ch not in "KQkq" or ch in seen:
                raise ProtocolError(f"Invalid castling rights '{castling}'")
            seen.add(ch)

    if en_passant == "-":
        ep_byte = 0
    else:
        if len(en_passant) != 2 or en_passant[0] < "a" or en_passant[0] > "h" or en_passant[1] not in "36":
            raise ProtocolError(f"Invalid en passant square '{en_passant}'")
        ep_byte = ((ord(en_passant[0]) - ord("a")) << 1) | 0x1

    try:
        halfmove = int(halfmove_clock)
    except ValueError as exc:
        raise ProtocolError("Halfmove clock must be an integer") from exc
    if not 0 <= halfmove <= 127:
        raise ProtocolError("Halfmove clock must fit in 7 bits")

    payload = bytearray(FULL_BOARD_BYTES)
    for idx in range(32):
        payload[idx] = tiles[2 * idx] | (tiles[2 * idx + 1] << 4)
    payload[32] = (
        (0x8 if "K" in castling else 0)
        | (0x4 if "Q" in castling else 0)
        | (0x2 if "k" in castling else 0)
        | (0x1 if "q" in castling else 0)
    )
    payload[33] = ep_byte
    payload[34] = 0 if turn == "w" else 1
    payload[35] = halfmove
    return bytes(payload)


def encode_time_ms(milliseconds: int) -> bytes:
    if not 0 <= milliseconds <= TIME_MAX_MS:
        raise ProtocolError(f"Time value must fit in 24 bits: {milliseconds}")
    return milliseconds.to_bytes(3, "little", signed=False)


def encode_node_count(nodes: int) -> bytes:
    if not 0 <= nodes <= NODE_COUNT_MAX:
        raise ProtocolError(f"Node count must fit in 40 bits: {nodes}")
    return nodes.to_bytes(5, "little", signed=False)


def command(opcode: Command, payload: bytes = b"") -> bytes:
    return bytes([int(opcode)]) + payload


def cmd_get_status() -> bytes:
    return command(Command.GET_STATUS)


def cmd_set_board(fen: str) -> bytes:
    return command(Command.SET_BOARD, encode_fen(fen))


def cmd_make_move(uci_move: str) -> bytes:
    return command(Command.MAKE_MOVE, encode_uci_move(uci_move))


def cmd_undo_move() -> bytes:
    return command(Command.UNDO_MOVE)


def cmd_new_game() -> bytes:
    return command(Command.NEW_GAME)


def cmd_search_depth(depth: int) -> bytes:
    if not 0 <= depth <= 31:
        raise ProtocolError("Search depth must be between 0 and 31")
    return command(Command.SEARCH_DEPTH, bytes([depth]))


def cmd_search_fixed_time(milliseconds: int) -> bytes:
    return command(Command.SEARCH_FIXED_TIME, encode_time_ms(milliseconds))


def cmd_search_on_clock(wtime: int, btime: int, winc: int = 0, binc: int = 0) -> bytes:
    return command(
        Command.SEARCH_ON_CLOCK,
        encode_time_ms(wtime) + encode_time_ms(btime) + encode_time_ms(winc) + encode_time_ms(binc),
    )


def cmd_search_nodes(nodes: int) -> bytes:
    return command(Command.SEARCH_NODES, encode_node_count(nodes))


def cmd_perft(depth: int) -> bytes:
    if not 0 <= depth <= 31:
        raise ProtocolError("Perft depth must be between 0 and 31")
    return command(Command.PERFT, bytes([depth]))


def cmd_kill() -> bytes:
    return command(Command.KILL)


def cmd_get_search_result() -> bytes:
    return command(Command.GET_SEARCH_RESULT)


def response_payload_length(response_type: int) -> int:
    if response_type == ResponseType.STATUS:
        return 3
    if response_type == ResponseType.ACK:
        return 1
    if response_type == ResponseType.SEARCH_RESULT:
        return 11
    if response_type == ResponseType.PERFT_RESULT:
        return 6
    if response_type == ResponseType.ERROR:
        return 2
    raise ProtocolError(f"Unknown response type 0x{response_type:02x}")


def decode_response(packet: bytes) -> EngineResponse:
    if not packet:
        raise ProtocolError("Empty response packet")
    response_type = packet[0]
    expected_len = response_payload_length(response_type) + 1
    if len(packet) != expected_len:
        raise ProtocolError(f"Response 0x{response_type:02x} needs {expected_len} bytes, got {len(packet)}")

    payload = packet[1:]
    if response_type == ResponseType.STATUS:
        return StatusResponse(
            status=payload[0],
            error=_enum_or_int(EngineError, payload[1]),
            active_operation=payload[2],
        )
    if response_type == ResponseType.ACK:
        return AckResponse(status=payload[0])
    if response_type == ResponseType.SEARCH_RESULT:
        return SearchResultResponse(
            best_move=decode_move(payload[0:2]),
            score=int.from_bytes(payload[2:4], "little", signed=True),
            nodes=int.from_bytes(payload[4:9], "little", signed=False),
            completed_depth=payload[9],
            end_reason=_enum_or_int(EndReason, payload[10]),
        )
    if response_type == ResponseType.PERFT_RESULT:
        return PerftResultResponse(
            nodes=int.from_bytes(payload[0:5], "little", signed=False),
            completed_depth=payload[5],
        )
    return ErrorResponse(
        error=_enum_or_int(EngineError, payload[0]),
        status=payload[1],
    )


def read_response(read_exact: Callable[[int], bytes]) -> EngineResponse:
    header = read_exact(1)
    if len(header) != 1:
        raise ProtocolError("Response reader returned fewer header bytes than requested")
    payload_len = response_payload_length(header[0])
    payload = read_exact(payload_len)
    if len(payload) != payload_len:
        raise ProtocolError("Response reader returned fewer payload bytes than requested")
    return decode_response(header + payload)
