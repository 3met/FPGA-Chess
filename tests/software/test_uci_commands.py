import unittest

from software.engine.protocol import Command, ProtocolError, STARTPOS_FEN
from software.engine.uci_commands import parse_go_command, parse_position_args, split_command_line


class UCICommandParsingTests(unittest.TestCase):
    def test_command_split_preserves_leading_token_compatibility(self):
        self.assertEqual(split_command_line("prefix DEBUG on"), ("debug", ["on"]))
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
        parsed = parse_go_command(["searchmoves", "e2e4", "depth", "3", "movestogo", "20"])
        self.assertEqual(parsed.command, bytes([Command.SEARCH_DEPTH, 3]))
        self.assertFalse(parsed.is_perft)
        self.assertFalse(parsed.wait_for_stop)
        self.assertFalse(parsed.is_ponder)
        self.assertIsNone(parsed.resume_command)
        self.assertEqual(
            parsed.warnings,
            (
                "searchmoves is ignored by this FPGA protocol",
                "mate/movestogo constraints are ignored",
            ),
        )

    def test_go_parsing_keeps_original_range_validation(self):
        with self.assertRaisesRegex(ProtocolError, "depth must be between 0 and 31"):
            parse_go_command(["depth", "32"])
        with self.assertRaisesRegex(ProtocolError, "nodes must be nonnegative"):
            parse_go_command(["nodes", "-1"])

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
            bytes.fromhex("12e80300d007000a0000000000"),
        )


if __name__ == "__main__":
    unittest.main()
