import contextlib
import importlib.util
import io
import logging
import unittest

from software.protocol import Command
from software.fpga_engine import FPGAUCIHost


@unittest.skipIf(importlib.util.find_spec("chess") is None, "python-chess is required for the UCI host")
class UCIHostSpecTests(unittest.TestCase):
    def make_host(self) -> FPGAUCIHost:
        return FPGAUCIHost(
            port="loop://",
            baudrate=2_000_000,
            response_timeout=0.01,
            logger=logging.getLogger("test_uci_host"),
        )

    def capture_lines(self, host: FPGAUCIHost, command: str) -> list[str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            host.handle_line(command)
        return [line.strip() for line in output.getvalue().splitlines() if line.strip()]

    def test_leading_unknown_tokens_are_ignored(self):
        host = self.make_host()
        lines = self.capture_lines(host, "joho debug on")
        self.assertEqual(lines, [])
        self.assertTrue(host.debug)

    def test_isready_does_not_query_hardware_while_searching(self):
        host = self.make_host()
        host._search_active = True
        lines = self.capture_lines(host, "isready")
        self.assertEqual(lines, ["readyok"])

    def test_unknown_go_tokens_are_ignored(self):
        host = self.make_host()
        command, is_perft, wait_for_stop = host._build_go_command(["nonsense", "depth", "3"])
        self.assertEqual(command, bytes([Command.SEARCH_DEPTH, 3]))
        self.assertFalse(is_perft)
        self.assertFalse(wait_for_stop)

    def test_infinite_search_waits_for_stop(self):
        host = self.make_host()
        command, is_perft, wait_for_stop = host._build_go_command(["infinite"])
        self.assertEqual(command, bytes([Command.SEARCH_DEPTH, 31]))
        self.assertFalse(is_perft)
        self.assertTrue(wait_for_stop)


if __name__ == "__main__":
    unittest.main()
