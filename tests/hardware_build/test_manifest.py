"""Source-set graph validation and deterministic expansion."""

import tempfile
import unittest
from pathlib import Path

from tools.hardware_build.common import BuildError
from tools.hardware_build.manifest import expand_source_set, load_manifest, validate_manifest


class SourceSetTests(unittest.TestCase):
    def test_shared_references_preserve_first_seen_order(self):
        """Shared dependencies appear once at their earliest reference."""
        with tempfile.TemporaryDirectory() as temporary:
            paths = [Path(temporary) / name for name in ("base.sv", "left.sv", "right.sv")]
            for path in paths:
                path.touch()
            manifest = {"source_sets": {
                "root": ["@left", "@right", "@base"],
                "left": ["@base", str(paths[1])],
                "right": ["@base", str(paths[2])],
                "base": [str(paths[0])],
            }}
            self.assertEqual(expand_source_set(manifest, "root"), paths)

    def test_cycles_and_missing_references_raise_build_errors(self):
        """Graph failures retain actionable source-set diagnostics."""
        for source_sets, message in (
            ({"root": ["@child"], "child": ["@root"]}, "root -> child -> root"),
            ({"root": ["@missing"]}, "Unknown source set 'missing'"),
        ):
            with self.subTest(source_sets=source_sets), self.assertRaisesRegex(BuildError, message):
                expand_source_set({"source_sets": source_sets}, "root")

    def test_invalid_forward_reference_is_validated_before_expansion(self):
        """Malformed referenced entries must not escape as Python type errors."""
        manifest = load_manifest()
        for invalid in (None, [1], "not a list"):
            manifest["source_sets"] = {"root": ["@invalid"], "invalid": invalid}
            with self.subTest(invalid=invalid), self.assertRaisesRegex(BuildError, "Source set 'invalid'"):
                validate_manifest(manifest)
