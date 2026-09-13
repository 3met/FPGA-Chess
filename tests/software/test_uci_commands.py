import unittest

from software.engine.protocol import Command, ProtocolError, STARTPOS_FEN
from software.engine.uci_commands import parse_go_command, parse_position_args, split_command_line


class UCICommandParsingTests(unittest.TestCase):
    def test_command_split_uses_only_the_leading_token_as_the_command(self):
        self.assertEqual(split_command_line("prefix DEBUG on"), ("prefix", ["DEBUG", "on"]))
        self.assertEqual(split_command_line("nonsense"), ("nonsense", []))
        self.assertIsNone(split_command_line("  "))

    def test_position_parsing_handles_startpos_and_fen_moves(self):
        self.assertEqual(
            parse_position_args(["startpos", "moves", "e2e4"]),
            (STARTPOS_FEN, ["e2e4"]),
        )
        self.assertEqual(
            parse_position_args(["fen", "8/8/8/8/8/8/8/8", "w", "-", "-", "moves", "a1a2"]),
            ("8/8/8/8/8/8/8/8 w - -", ["a1a2"]),
        )

    def test_go_parsing_encodes_supported_limit_and_reports_ignored_constraints(self):
        parsed = parse_go_command(["searchmoves", "e2e4", "depth", "3"])
        self.assertEqual(parsed.command, bytes([Command.SEARCH_DEPTH, 3]))
        self.assertFalse(parsed.is_perft)
        self.assertFalse(parsed.wait_for_stop)
        self.assertFalse(parsed.is_ponder)
        self.assertIsNone(parsed.resume_command)
        self.assertEqual(
            parsed.warnings,
            (
                "searchmoves is ignored by this FPGA protocol",
            ),
        )

    def test_clock_fields_and_move_overhead_are_encoded(self):
        parsed = parse_go_command(
            ["wtime", "1000", "btime", "2000", "winc", "10", "binc", "20", "movestogo", "30"],
            move_overhead_ms=15,
        )
        self.assertEqual(
            parsed.command,
            bytes.fromhex("12e80300d007000a00001400001e000f0000"),
        )

    def test_movetime_carries_move_overhead(self):
        parsed = parse_go_command(["movetime", "250"], move_overhead_ms=10)
        self.assertEqual(parsed.command, bytes.fromhex("11fa00000a0000"))

    def test_go_parsing_keeps_original_range_validation(self):
        with self.assertRaisesRegex(ProtocolError, "depth must be between 0 and 31"):
            parse_go_command(["depth", "32"])
        with self.assertRaisesRegex(ProtocolError, "nodes must be nonnegative"):
            parse_go_command(["nodes", "-1"])

    def test_go_parsing_rejects_recognized_fields_without_values(self):
        with self.assertRaisesRegex(ProtocolError, "go depth requires a value"):
            parse_go_command(["depth"])
        with self.assertRaisesRegex(ProtocolError, "go wtime requires a value"):
            parse_go_command(["wtime", "btime", "1000"])
        with self.assertRaisesRegex(ProtocolError, "go searchmoves requires at least one move"):
            parse_go_command(["searchmoves", "depth", "3"])

    def test_unknown_tokens_are_ignored_and_infinite_waits_for_stop(self):
        parsed = parse_go_command(["nonsense", "depth", "3"])
        self.assertEqual(parsed.command, bytes([Command.SEARCH_DEPTH, 3]))
        self.assertFalse(parsed.wait_for_stop)

        parsed = parse_go_command(["infinite"])
        self.assertEqual(parsed.command, bytes([Command.SEARCH_DEPTH, 31]))
        self.assertTrue(parsed.wait_for_stop)

    def test_ponder_searches_to_max_depth_then_resumes_the_clock_limit(self):
        parsed = parse_go_command(["ponder", "wtime", "1000", "btime", "2000", "winc", "10"])

        self.assertEqual(parsed.command, bytes([Command.SEARCH_DEPTH, 31]))
        self.assertTrue(parsed.is_ponder)
        self.assertFalse(parsed.wait_for_stop)
        self.assertEqual(
            parsed.resume_command,
            bytes.fromhex("12e80300d007000a000000000000000a0000"),
        )


if __name__ == "__main__":
    unittest.main()
