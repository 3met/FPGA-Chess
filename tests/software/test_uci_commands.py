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


if __name__ == "__main__":
    unittest.main()
