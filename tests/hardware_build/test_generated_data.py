"""Generated-data verification preserves files across tool failures."""

import argparse
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from tools.hardware_build.common import BuildError
from tools.hardware_build.generated_data import command_gen_data


class GeneratedDataTests(unittest.TestCase):
    def test_verification_restores_modified_deleted_and_new_outputs(self):
        """Success, failure, and interruption all leave original files intact."""
        for outcome in (0, 1, KeyboardInterrupt, OSError):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                script = root / "generator.py"
                script.touch()
                modified, deleted, created = [root / name for name in ("modified", "deleted", "created")]
                modified.write_bytes(b"original")
                deleted.write_bytes(b"keep")
                manifest = {"generated_data": {"fixture": {
                    "script": str(script), "outputs": [str(modified), str(deleted), str(created)],
                }}}

                def generate(*args, **kwargs):
                    """Model a generator that partially writes before stopping."""
                    modified.write_bytes(b"changed")
                    deleted.unlink()
                    created.write_bytes(b"new")
                    if isinstance(outcome, type):
                        raise outcome()
                    return outcome, "", 0.0

                with (
                    patch("tools.hardware_build.generated_data.load_manifest", return_value=manifest),
                    patch("tools.hardware_build.generated_data.run_command", side_effect=generate),
                    patch("tools.hardware_build.generated_data.rel", side_effect=str),
                    redirect_stdout(io.StringIO()),
                ):
                    if outcome == 0:
                        self.assertEqual(command_gen_data(argparse.Namespace(update=False)), 1)
                    else:
                        error = BuildError if outcome == 1 else outcome
                        with self.assertRaises(error):
                            command_gen_data(argparse.Namespace(update=False))
                self.assertEqual(modified.read_bytes(), b"original")
                self.assertEqual(deleted.read_bytes(), b"keep")
                self.assertFalse(created.exists())
