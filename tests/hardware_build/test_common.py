"""Exercise subprocess timeout logs and process-exit races without vendor tools."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.common import run_command, terminate_process_tree


class CommandTests(unittest.TestCase):
    def test_timeout_keeps_output_once_in_result_and_log(self):
        """Output read before a timeout must not be repeated when communicate resumes."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "command.log"
            code, output, _ = run_command(
                [sys.executable, "-c", "import time; print('before timeout', flush=True); time.sleep(60)"],
                root, log, timeout_seconds=1,
            )
            self.assertEqual(code, 124)
            self.assertEqual(output.count("before timeout"), 1)
            self.assertIn("Command timed out", output)
            self.assertEqual(log.read_text(encoding="utf-8"), output)

    @unittest.skipIf(os.name == "nt", "POSIX process-group race")
    def test_group_exit_between_poll_and_signal_is_harmless(self):
        """A completed process group needs no further termination."""
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch("tools.hardware_build.common.os.killpg", side_effect=ProcessLookupError):
            terminate_process_tree(process)


if __name__ == "__main__":
    unittest.main()
