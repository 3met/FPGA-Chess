"""Named FPGA benchmark positions and their reference data."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PerftCase:
    """One complete perft request that can be issued to the FPGA host."""

    name: str
    fen: str
    depth: int
    nodes: int


@dataclass(frozen=True)
class SearchCase:
    """A named middlegame position for FPGA search and timing checks."""

    name: str
    fen: str


STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# Keep each case compact enough for an opt-in live-FPGA regression run.
PERFT_POSITIONS: tuple[PerftCase, ...] = (
    PerftCase("startpos", STARTPOS_FEN, 5, 4865609),
    PerftCase("castling", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", 3, 13744),
    PerftCase("en-passant-and-check", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 3, 2812),
    PerftCase("promotions", "4k3/P7/8/8/8/8/7p/4K3 w - - 0 1", 3, 699),
    PerftCase("checkmate", "7k/6Q1/7K/8/8/8/8/8 b - - 0 1", 2, 0),
    PerftCase("wiki position #2", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -", 4, 4085603),
    PerftCase("wiki position #3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 5, 674624),
    PerftCase("wiki position #4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 5, 15833292),
    PerftCase("wiki position #5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 4, 2103487),
    PerftCase("wiki position #6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", 4, 3894594),
    PerftCase("ep-illegal-white", "8/5bk1/8/2Pp4/8/1K6/8/8 w - d6 0 1", 6, 824064),
    PerftCase("ep-illegal-black", "8/8/1k6/8/2pP4/8/5BK1/8 b - d3 0 1", 6, 824064),
    PerftCase("ep-checks-black", "8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1", 6, 1440467),
    PerftCase("ep-checks-white", "8/5k2/8/2Pp4/2B5/1K6/8/8 w - d6 0 1", 6, 1440467),
    PerftCase("short-castle-check-white", "5k2/8/8/8/8/8/8/4K2R w K - 0 1", 6, 661072),
    PerftCase("short-castle-check-black", "4k2r/8/8/8/8/8/8/5K2 b k - 0 1", 6, 661072),
    PerftCase("long-castle-check-white", "3k4/8/8/8/8/8/8/R3K3 w Q - 0 1", 6, 803711),
    PerftCase("long-castle-check-black", "r3k3/8/8/8/8/8/8/3K4 b q - 0 1", 6, 803711),
    PerftCase("castling-rook-capture-white", "r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1", 4, 1274206),
    PerftCase("castling-rook-capture-black", "r3k2r/7b/8/8/8/8/1B4BQ/R3K2R b KQkq - 0 1", 4, 1274206),
    PerftCase("castling-prevented-black", "r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1", 4, 1720476),
    PerftCase("castling-prevented-white", "r3k2r/8/5Q2/8/8/3q4/8/R3K2R w KQkq - 0 1", 4, 1720476),
    PerftCase("promote-out-of-check-white", "2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1", 6, 3821001),
    PerftCase("promote-out-of-check-black", "3K4/8/8/8/8/8/4p3/2k2R2 b - - 0 1", 6, 3821001),
    PerftCase("discovered-check-black", "8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1", 5, 1004658),
    PerftCase("discovered-check-white", "5K2/8/1Q6/2N5/8/1p2k3/8/8 w - - 0 1", 5, 1004658),
    PerftCase("promote-gives-check-white", "4k3/1P6/8/8/8/8/K7/8 w - - 0 1", 6, 217342),
    PerftCase("promote-gives-check-black", "8/k7/8/8/8/8/1p6/4K3 b - - 0 1", 6, 217342),
    PerftCase("underpromote-check-white", "8/P1k5/K7/8/8/8/8/8 w - - 0 1", 6, 92683),
    PerftCase("underpromote-check-black", "8/8/8/8/8/k7/p1K5/8 b - - 0 1", 6, 92683),
    PerftCase("self-stalemate-white", "K1k5/8/P7/8/8/8/8/8 w - - 0 1", 6, 2217),
    PerftCase("self-stalemate-black", "8/8/8/8/8/p7/8/k1K5 b - - 0 1", 6, 2217),
    PerftCase("stalemate-checkmate-white", "8/k1P5/8/1K6/8/8/8/8 w - - 0 1", 7, 567584),
    PerftCase("stalemate-checkmate-black", "8/8/8/8/1k6/8/K1p5/8 b - - 0 1", 7, 567584),
    PerftCase("double-check-black", "8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1", 4, 23527),
    PerftCase("double-check-white", "8/5k2/8/5N2/5Q2/2K5/8/8 w - - 0 1", 4, 23527),
)

# These positions exercise different opening structures without requiring deep searches.
SANITY_POSITIONS: tuple[SearchCase, ...] = (
    SearchCase("open-game", "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3"),
    SearchCase("ruy-lopez", "r1bqk2r/1pppbppp/p1n2n2/1B2p3/4P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 4 6"),
    SearchCase("queen-gambit", "r1bq1rk1/pp1n1ppp/2pbpn2/3p4/3P4/2NBPN2/PPQ1BPPP/R3K2R w KQ - 4 8"),
)
