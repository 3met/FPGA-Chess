import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.simulation import parse_fail_count, run_modelsim_top


class RTLTestResultTests(unittest.TestCase):
    def run_transcript(self, transcript: str, exit_code: int = 0) -> dict:
        """Run the result classifier without invoking an installed simulator."""
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            with (
                mock.patch(
                    "tools.hardware_build.simulation.modelsim_tools",
                    return_value={"vsim": "vsim"},
                ),
                mock.patch(
                    "tools.hardware_build.simulation.run_command",
                    return_value=(exit_code, transcript, 0.1),
                ),
            ):
                return run_modelsim_top(
                    "example",
                    "tb_example",
                    run_dir / "work",
                    run_dir,
                    {},
                    10.0,
                )

    def test_success_requires_a_real_passing_check_and_clean_completion(self):
        cases = (
            ("Pass Count: 1\nFail Count: 0\n", 0, True, "passed"),
            ("Pass Count: 0\nFail Count: 0\n", 0, False, "no passing checks"),
            ("Fail Count: 0\n", 0, False, "missing completion counts"),
            ("Pass Count: 1\nFail Count: 1\n", 0, False, "failed"),
            ("Pass Count: 1\nFail Count: 0\n# ** Fatal: stopped\n", 0, False, "failed"),
            ("Pass Count: 1\nFail Count: 0\n", 1, False, "failed"),
        )
        for transcript, exit_code, expected_ok, expected_message in cases:
            with self.subTest(transcript=transcript, exit_code=exit_code):
                result = self.run_transcript(transcript, exit_code)
                self.assertEqual(result["ok"], expected_ok)
                self.assertEqual(result["message"], expected_message)

    def test_later_zero_summary_cannot_hide_an_earlier_failure(self):
        transcript = "Pass Count: 1\nFail Count: 1\nPass Count: 2\nFail Count: 0\n"

        self.assertEqual(parse_fail_count(transcript), 1)
        self.assertFalse(self.run_transcript(transcript)["ok"])


if __name__ == "__main__":
    unittest.main()
