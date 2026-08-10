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


@dataclass(frozen=True)
class RepetitionCase:
    """A root move whose line changes from playable to a threefold draw."""

    name: str
    base_fen: str
    return_moves: tuple[str, ...]
    draw_move: str
    should_choose_draw: bool
    draw_replies: tuple[str, ...] = ()

    @property
    def draw_line(self) -> tuple[str, ...]:
        """Return the root move and any opponent reply that completes the draw."""
        return (self.draw_move,) + self.draw_replies

    @property
    def final_moves(self) -> tuple[str, ...]:
        """Build history with two prior occurrences of the candidate child position."""
        return self.return_moves + self.draw_line + self.return_moves


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

# These positions cover varied open, semi-open, and closed middlegame structures.
SANITY_POSITIONS: tuple[SearchCase, ...] = (
    SearchCase("open-game", "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3"),
    SearchCase("ruy-lopez", "r1bqk2r/1pppbppp/p1n2n2/1B2p3/4P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 4 6"),
    SearchCase("queen-gambit", "r1bq1rk1/pp1n1ppp/2pbpn2/3p4/3P4/2NBPN2/PPQ1BPPP/R3K2R w KQ - 4 8"),
    SearchCase("sicilian-najdorf", "r2qkb1r/1p1n1ppp/p2pbn2/4p3/4P3/1NN1BP2/PPP3PP/R2QKB1R w KQkq - 1 9"),
    SearchCase("french-winawer", "rnbqk2r/p3nppp/1p2p3/2ppP3/3P4/P1P2N2/2P2PPP/R1BQKB1R w KQkq - 0 8"),
    SearchCase("caro-kann-advance", "r2qkbnr/pp3ppp/2n1p3/3pPb2/3N4/4B3/PPP1BPPP/RN1Q1RK1 b kq - 0 8"),
    SearchCase("kings-indian", "r1bq1rk1/ppp1npbp/3p1np1/3Pp3/2P1P3/2N2N2/PP2BPPP/R1BQ1RK1 w - - 1 9"),
    SearchCase("nimzo-indian", "r1bq1rk1/pp3ppp/2n1pn2/2pp4/1bPP4/2NBPN2/PP3PPP/R1BQ1RK1 w - - 2 8"),
    SearchCase("english", "r1bqk2r/ppp1bppp/1nn5/4p3/8/2N2NP1/PP1PPPBP/R1BQ1RK1 w kq - 6 8"),
    SearchCase("reti", "r1bq1rk1/pp2ppbp/2n2np1/2pp4/4P3/3P1NP1/PPPN1PBP/R1BQ1RK1 w - - 1 8"),
    SearchCase("scotch", "r1b1kb1r/p1ppqppp/2p5/3nP3/2P5/8/PP2QPPP/RNB1KB1R b KQkq - 0 8"),
    SearchCase("italian", "r1bq1rk1/bpp2ppp/p1np1n2/4p3/4P3/1BPP1N2/PP3PPP/RNBQR1K1 w - - 2 9"),
    SearchCase("slav", "r2qk2r/pp1n1ppp/2p1pn2/5b2/PbBP4/2N1PN2/1P3PPP/R1BQ1RK1 w kq - 3 9"),
    SearchCase("dutch", "r1bq1rk1/ppp1p1bp/3p1np1/3Pnp2/2P5/2N2NP1/PP2PPBP/R1BQ1RK1 w - - 1 9"),
    SearchCase("pirc", "r2q1rk1/ppp1ppbp/2np1np1/8/3PPPb1/2NB1N2/PPP3PP/R1BQ1RK1 w - - 7 8"),
    SearchCase("queens-indian", "rn1q1rk1/p1p1bppp/bp2pn2/3p4/2PP4/1P3NP1/P2BPPBP/RN1Q1RK1 w - - 0 9"),
)

# Each base is the position immediately after the complete draw line. Returning to
# the root once primes the TT without a draw; another complete cycle makes the draw
# line repeat it for the third time. Winning cases avoid it, while losing cases take it.
REPETITION_CASES: tuple[RepetitionCase, ...] = (
    # Five real games where the FPGA side was winning but repeated an earlier
    # choice after the same root returned with additional game history.
    RepetitionCase(
        "lichess-t9ujrjwq-black-winning",
        "1k6/pbN4p/8/8/BP1q3p/8/P1P5/5QK1 w - - 5 38",
        ("f1f2", "d4a1", "f2f1"),
        "a1d4",
        False,
    ),
    RepetitionCase(
        "lichess-x6xl91ty-white-winning",
        "8/8/7Q/4n3/5k2/8/7K/8 b - - 28 77",
        ("f4f3", "h6h5", "f3f4"),
        "h5h6",
        False,
    ),
    RepetitionCase(
        "lichess-9f9ubkjf-black-winning",
        "1r2r1k1/pbQ2p2/7p/5np1/1R6/B1P5/P1PP1q1P/2KR4 b - - 7 34",
        ("e8c8", "c7e5"),
        "c8e8",
        False,
        ("e5c7",),
    ),
    RepetitionCase(
        "lichess-xyrmg14b-white-winning",
        "2b4R/4rk2/2p5/r1NpP1R1/1p4p1/1P4K1/P6P/8 w - - 11 48",
        ("h8h7", "f7f8"),
        "h7h8",
        False,
        ("f8f7",),
    ),
    RepetitionCase(
        "lichess-pgjvtdii-white-winning",
        "r7/6R1/3kp3/2p1p3/P3P3/1PK2P2/6PP/8 w - - 6 37",
        ("g7g6", "a8b8"),
        "g6g7",
        False,
        ("b8a8",),
    ),
    RepetitionCase(
        "rook-white-losing",
        "R6k/8/8/4q3/8/8/8/6K1 b - - 0 1",
        ("h8h7", "a8a1", "h7h8"),
        "a1a8",
        True,
    ),
    RepetitionCase(
        "rook-black-losing",
        "6k1/8/8/8/4Q3/8/8/r6K w - - 0 1",
        ("h1h2", "a1a8", "h2h1"),
        "a8a1",
        True,
    ),
    RepetitionCase(
        "queen-white-losing",
        "8/Q6k/2r5/3q4/8/8/8/6K1 b - - 0 1",
        ("h7h6", "a7a1", "h6h7"),
        "a1a7",
        True,
    ),
    RepetitionCase(
        "queen-black-losing",
        "1k6/8/8/8/4Q3/5R2/K6q/8 w - - 0 1",
        ("a2a3", "h2h8", "a3a2"),
        "h8h2",
        True,
    ),
    RepetitionCase(
        "knight-white-losing",
        "7k/8/8/4q3/8/N7/8/6K1 b - - 0 1",
        ("h8h7", "a3b1", "h7h8"),
        "b1a3",
        True,
    ),
)
