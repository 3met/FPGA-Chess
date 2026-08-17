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

# Position suite used by the cycle-accurate hardware profiler.  Names are
# intentionally descriptive and stable because they become artifact directory names.
PROFILE_POSITIONS: tuple[SearchCase, ...] = (
    SearchCase("undermining", "1kr5/3n4/q3p2p/p2n2p1/PppB1P2/5BP1/1P2Q2P/3R2K1 w - - 0 1"),
    SearchCase("open-files-diagonals", "1r1qbr1k/4bp1p/p3p2Q/3pP3/2pP4/P1N1PN2/1PR2RP1/6K1 b - - 0 1"),
    SearchCase("knight-outposts-repositioning", "1k2r2r/1bq2p2/pn4p1/3pP3/pbpN1P1p/4QN1B/1P4PP/2RR3K b - - 0 1"),
    SearchCase("square-vacancy", "6k1/p2pp2p/bp4n1/q1r4R/1RP1P3/2P2B2/P2Q2P1/4K3 w - - 0 1"),
    SearchCase("bishop-vs-knight", "1b3rk1/5ppp/2p2rq1/1p1n4/3P2P1/1BPbBP2/1P1N2QP/R3R1K1 w - - 0 1"),
    SearchCase("recapture-choice", "1k1r1r2/p1p5/Bpnbb3/3p2pp/3P4/P1N1NPP1/1PP4P/2KR1R2 w - - 0 1"),
    SearchCase("simplification-decision", "1R3b2/r4pk1/2qpn1p1/P1p1p2p/2P1P2P/5PP1/6K1/1Q1BB3 w - - 0 1"),
    SearchCase("strategic-kingside-pawn", "1qr2k1r/pb3pp1/1b2p2p/3nP3/1p6/3B2QN/PP3PPP/R1BR2K1 b - - 0 1"),
    SearchCase("queenside-pawn-advance", "1b2r1k1/1bqn1pp1/p1p4p/Pp2p3/1P2B3/2B1PN1P/5PP1/1Q1R2K1 b - - 0 1"),
    SearchCase("simplification", "1b1qrr2/1p4pk/1np4p/p3Np1B/Pn1P4/R1N3B1/1Pb2PPP/2Q1R1K1 b - - 0 1"),
    SearchCase("king-activity", "1r2r3/1p1b3k/2p2n2/p1Pp4/P2N1PpP/1R2p3/1P2P1BP/3R2K1 b - - 0 1"),
    SearchCase("centralization-center-control", "1r1r1bk1/1bq2p1p/pn2p1p1/2p1P3/5P2/P1NBB3/1P3QPP/R2R2K1 b - - 0 1"),
    SearchCase("central-pawn-play", "1q2rrk1/p5bp/2p1p1p1/3p4/5P2/4QBP1/PPP2R1P/1R4K1 b - - 0 1"),
    SearchCase("seventh-rank-penetration", "1n1r1rk1/4bpp1/p2p3p/1q1Qp3/1P2P3/P3BN1P/5PP1/2R1R1K1 w - - 0 1"),
    SearchCase("general-strategic-positional", "rnb1r1k1/pp2bppp/2p2n2/8/1q1Q1B2/2N2NPP/PP2PPB1/R4RK1 w - - 0 1"),
    SearchCase("open-files-diagonals-second", "1qrr3k/1p2bp1p/1n2p1pP/p2pP3/P4B2/1PPB2P1/2R1QP2/3R2K1 w - - 0 1"),
    SearchCase("high-branching-castling-tactical", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10"),
    SearchCase("tactical-middle-one", "4rrk1/pp1n3p/3q2pQ/2p1pb2/2PP4/2P3N1/P2B2PP/4RRK1 b - - 7 19"),
    SearchCase("tactical-middle-two", "r3r1k1/2p2ppp/p1p1bn2/8/1q2P3/2NPQN2/PPP3PP/R4RK1 b - - 2 15"),
    SearchCase("tactical-middle-three", "r1bbk1nr/pp3p1p/2n5/1N4p1/2Np1B2/8/PPP2PPP/2KR1B1R w kq - 0 13"),
    SearchCase("tactical-middle-four", "r1bq1rk1/ppp1nppp/4n3/3p3Q/3P4/1BP1B3/PP1N2PP/R4RK1 w - - 1 16"),
    SearchCase("tactical-middle-five", "4r1k1/r1q2ppp/ppp2n2/4P3/5Rb1/1N1BQ3/PPP3PP/R5K1 w - - 1 17"),
    SearchCase("tactical-middle-six", "2rqkb1r/ppp2p2/2npb1p1/1N1Nn2p/2P1PP2/8/PP2B1PP/R1BQK2R b KQ - 0 11"),
    SearchCase("tactical-middle-seven", "r1bq1r1k/b1p1npp1/p2p3p/1p6/3PP3/1B2NN2/PP3PPP/R2Q1RK1 w - - 1 16"),
    SearchCase("tactical-middle-eight", "3r1rk1/p5pp/bpp1pp2/8/q1PP1P2/b3P3/P2NQRPP/1R2B1K1 b - - 6 22"),
    SearchCase("tactical-middle-nine", "r1q2rk1/2p1bppp/2Pp4/p6b/Q1PNp3/4B3/PP1R1PPP/2K4R w - - 2 18"),
    SearchCase("tactical-middle-ten", "4k2r/1pb2ppp/1p2p3/1R1p4/3P4/2r1PN2/P4PPP/1R4K1 b - - 3 22"),
    SearchCase("tactical-middle-eleven", "3q2k1/pb3p1p/4pbp1/2r5/PpN2N2/1P2P2P/5PP1/Q2R2K1 b - - 4 26"),
    SearchCase("tactical-fifty-move-pressure", "5rk1/q6p/2p3bR/1pPp1rP1/1P1Pp3/P3B1Q1/1K3P2/R7 w - - 93 90"),
    SearchCase("tactical-middle-twelve", "4rrk1/1p1nq3/p7/2p1P1pp/3P2bp/3Q1Bn1/PPPB4/1K2R1NR w - - 40 21"),
    SearchCase("tactical-middle-thirteen", "r3k2r/3nnpbp/q2pp1p1/p7/Pp1PPPP1/4BNN1/1P5P/R2Q1RK1 w kq - 0 16"),
    SearchCase("extremely-tactically-entangled", "3Qb1k1/1r2ppb1/pN1n2q1/Pp1Pp1Pr/4P2p/4BP2/4B1R1/1R5K b - - 11 40"),
    SearchCase("rook-pawns", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 11"),
    SearchCase("knight-pawns", "6k1/6p1/6Pp/ppp5/3pn2P/1P3K2/1PP2P2/3N4 b - - 0 1"),
    SearchCase("closed-bishop-knight-pawns", "3b4/5kp1/1p1p1p1p/pP1PpP1P/P1P1P3/3KN3/8/8 w - - 0 1"),
    SearchCase("queen-endgame", "8/6pk/1p6/8/PP3p1p/5P2/4KP1q/3Q4 w - - 0 1"),
    SearchCase("queen-bishop-dangerous-pawns", "7k/3p2pp/4q3/8/4Q3/5Kp1/P6b/8 w - - 0 1"),
    SearchCase("pure-pawn-endgame", "8/2p5/8/2kPKp1p/2p4P/2P5/3P4/8 w - - 0 1"),
    SearchCase("pure-pawn-endgame-second", "8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1"),
    SearchCase("rook-locked-pawns", "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1"),
    SearchCase("bishop-pawns", "8/3p4/p1bk3p/Pp6/1Kp1PpPp/2P2P1P/2P5/5B2 b - - 0 1"),
    SearchCase("rook-endgame-passer", "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1"),
    SearchCase("rook-minor-passed-pawn", "6k1/6p1/P6p/r1N5/5p2/7P/1b3PP1/4R1K1 w - - 0 1"),
    SearchCase("queen-minor-advanced-passer", "1r3k2/4q3/2Pp3b/3Bp3/2Q2p2/1p1P2P1/1P2KP2/3N4 w - - 0 1"),
    SearchCase("starting-position-baseline", STARTPOS_FEN),
    SearchCase("actionable-en-passant", "rnbqkb1r/ppp1pppp/5n2/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"),
    SearchCase("sicilian-najdorf", "r2qkb1r/1p1n1ppp/p2pbn2/4p3/4P3/1NN1BP2/PPP3PP/R2QKB1R w KQkq - 1 9"),
    SearchCase("immediate-promotion-possibilities", "8/2p4P/8/kr6/6R1/8/8/1K6 w - - 0 1"),
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
