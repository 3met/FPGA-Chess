"""Named positions for cycle-accurate hardware profiling."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ProfileCase:
    """A named chess position for the hardware profiler."""

    name: str
    fen: str


STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# Position suite used by the cycle-accurate hardware profiler.  Names are
# intentionally descriptive and stable because they become artifact directory names.
PROFILE_POSITIONS: tuple[ProfileCase, ...] = (
    ProfileCase("undermining", "1kr5/3n4/q3p2p/p2n2p1/PppB1P2/5BP1/1P2Q2P/3R2K1 w - - 0 1"),
    ProfileCase("open-files-diagonals", "1r1qbr1k/4bp1p/p3p2Q/3pP3/2pP4/P1N1PN2/1PR2RP1/6K1 b - - 0 1"),
    ProfileCase("knight-outposts-repositioning", "1k2r2r/1bq2p2/pn4p1/3pP3/pbpN1P1p/4QN1B/1P4PP/2RR3K b - - 0 1"),
    ProfileCase("square-vacancy", "6k1/p2pp2p/bp4n1/q1r4R/1RP1P3/2P2B2/P2Q2P1/4K3 w - - 0 1"),
    ProfileCase("bishop-vs-knight", "1b3rk1/5ppp/2p2rq1/1p1n4/3P2P1/1BPbBP2/1P1N2QP/R3R1K1 w - - 0 1"),
    ProfileCase("recapture-choice", "1k1r1r2/p1p5/Bpnbb3/3p2pp/3P4/P1N1NPP1/1PP4P/2KR1R2 w - - 0 1"),
    ProfileCase("simplification-decision", "1R3b2/r4pk1/2qpn1p1/P1p1p2p/2P1P2P/5PP1/6K1/1Q1BB3 w - - 0 1"),
    ProfileCase("strategic-kingside-pawn", "1qr2k1r/pb3pp1/1b2p2p/3nP3/1p6/3B2QN/PP3PPP/R1BR2K1 b - - 0 1"),
    ProfileCase("queenside-pawn-advance", "1b2r1k1/1bqn1pp1/p1p4p/Pp2p3/1P2B3/2B1PN1P/5PP1/1Q1R2K1 b - - 0 1"),
    ProfileCase("simplification", "1b1qrr2/1p4pk/1np4p/p3Np1B/Pn1P4/R1N3B1/1Pb2PPP/2Q1R1K1 b - - 0 1"),
    ProfileCase("king-activity", "1r2r3/1p1b3k/2p2n2/p1Pp4/P2N1PpP/1R2p3/1P2P1BP/3R2K1 b - - 0 1"),
    ProfileCase("centralization-center-control", "1r1r1bk1/1bq2p1p/pn2p1p1/2p1P3/5P2/P1NBB3/1P3QPP/R2R2K1 b - - 0 1"),
    ProfileCase("central-pawn-play", "1q2rrk1/p5bp/2p1p1p1/3p4/5P2/4QBP1/PPP2R1P/1R4K1 b - - 0 1"),
    ProfileCase("seventh-rank-penetration", "1n1r1rk1/4bpp1/p2p3p/1q1Qp3/1P2P3/P3BN1P/5PP1/2R1R1K1 w - - 0 1"),
    ProfileCase("general-strategic-positional", "rnb1r1k1/pp2bppp/2p2n2/8/1q1Q1B2/2N2NPP/PP2PPB1/R4RK1 w - - 0 1"),
    ProfileCase("open-files-diagonals-second", "1qrr3k/1p2bp1p/1n2p1pP/p2pP3/P4B2/1PPB2P1/2R1QP2/3R2K1 w - - 0 1"),
    ProfileCase("high-branching-castling-tactical", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10"),
    ProfileCase("tactical-middle-one", "4rrk1/pp1n3p/3q2pQ/2p1pb2/2PP4/2P3N1/P2B2PP/4RRK1 b - - 7 19"),
    ProfileCase("tactical-middle-two", "r3r1k1/2p2ppp/p1p1bn2/8/1q2P3/2NPQN2/PPP3PP/R4RK1 b - - 2 15"),
    ProfileCase("tactical-middle-three", "r1bbk1nr/pp3p1p/2n5/1N4p1/2Np1B2/8/PPP2PPP/2KR1B1R w kq - 0 13"),
    ProfileCase("tactical-middle-four", "r1bq1rk1/ppp1nppp/4n3/3p3Q/3P4/1BP1B3/PP1N2PP/R4RK1 w - - 1 16"),
    ProfileCase("tactical-middle-five", "4r1k1/r1q2ppp/ppp2n2/4P3/5Rb1/1N1BQ3/PPP3PP/R5K1 w - - 1 17"),
    ProfileCase("tactical-middle-six", "2rqkb1r/ppp2p2/2npb1p1/1N1Nn2p/2P1PP2/8/PP2B1PP/R1BQK2R b KQ - 0 11"),
    ProfileCase("tactical-middle-seven", "r1bq1r1k/b1p1npp1/p2p3p/1p6/3PP3/1B2NN2/PP3PPP/R2Q1RK1 w - - 1 16"),
    ProfileCase("tactical-middle-eight", "3r1rk1/p5pp/bpp1pp2/8/q1PP1P2/b3P3/P2NQRPP/1R2B1K1 b - - 6 22"),
    ProfileCase("tactical-middle-nine", "r1q2rk1/2p1bppp/2Pp4/p6b/Q1PNp3/4B3/PP1R1PPP/2K4R w - - 2 18"),
    ProfileCase("tactical-middle-ten", "4k2r/1pb2ppp/1p2p3/1R1p4/3P4/2r1PN2/P4PPP/1R4K1 b - - 3 22"),
    ProfileCase("tactical-middle-eleven", "3q2k1/pb3p1p/4pbp1/2r5/PpN2N2/1P2P2P/5PP1/Q2R2K1 b - - 4 26"),
    ProfileCase("tactical-fifty-move-pressure", "5rk1/q6p/2p3bR/1pPp1rP1/1P1Pp3/P3B1Q1/1K3P2/R7 w - - 93 90"),
    ProfileCase("tactical-middle-twelve", "4rrk1/1p1nq3/p7/2p1P1pp/3P2bp/3Q1Bn1/PPPB4/1K2R1NR w - - 40 21"),
    ProfileCase("tactical-middle-thirteen", "r3k2r/3nnpbp/q2pp1p1/p7/Pp1PPPP1/4BNN1/1P5P/R2Q1RK1 w kq - 0 16"),
    ProfileCase("extremely-tactically-entangled", "3Qb1k1/1r2ppb1/pN1n2q1/Pp1Pp1Pr/4P2p/4BP2/4B1R1/1R5K b - - 11 40"),
    ProfileCase("rook-pawns", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 11"),
    ProfileCase("knight-pawns", "6k1/6p1/6Pp/ppp5/3pn2P/1P3K2/1PP2P2/3N4 b - - 0 1"),
    ProfileCase("closed-bishop-knight-pawns", "3b4/5kp1/1p1p1p1p/pP1PpP1P/P1P1P3/3KN3/8/8 w - - 0 1"),
    ProfileCase("queen-endgame", "8/6pk/1p6/8/PP3p1p/5P2/4KP1q/3Q4 w - - 0 1"),
    ProfileCase("queen-bishop-dangerous-pawns", "7k/3p2pp/4q3/8/4Q3/5Kp1/P6b/8 w - - 0 1"),
    ProfileCase("pure-pawn-endgame", "8/2p5/8/2kPKp1p/2p4P/2P5/3P4/8 w - - 0 1"),
    ProfileCase("pure-pawn-endgame-second", "8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1"),
    ProfileCase("rook-locked-pawns", "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1"),
    ProfileCase("bishop-pawns", "8/3p4/p1bk3p/Pp6/1Kp1PpPp/2P2P1P/2P5/5B2 b - - 0 1"),
    ProfileCase("rook-endgame-passer", "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1"),
    ProfileCase("rook-minor-passed-pawn", "6k1/6p1/P6p/r1N5/5p2/7P/1b3PP1/4R1K1 w - - 0 1"),
    ProfileCase("queen-minor-advanced-passer", "1r3k2/4q3/2Pp3b/3Bp3/2Q2p2/1p1P2P1/1P2KP2/3N4 w - - 0 1"),
    ProfileCase("starting-position-baseline", STARTPOS_FEN),
    ProfileCase("actionable-en-passant", "rnbqkb1r/ppp1pppp/5n2/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"),
    ProfileCase("sicilian-najdorf", "r2qkb1r/1p1n1ppp/p2pbn2/4p3/4P3/1NN1BP2/PPP3PP/R2QKB1R w KQkq - 1 9"),
    ProfileCase("immediate-promotion-possibilities", "8/2p4P/8/kr6/6R1/8/8/1K6 w - - 0 1"),
)

