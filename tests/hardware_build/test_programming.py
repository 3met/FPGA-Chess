import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.common import BuildError
from tools.hardware_build.programming import validate_synthesized_artifact


class ProgrammingReceiptTests(unittest.TestCase):
    def test_rejects_non_object_receipts_and_missing_build_identity(self):
        """A matching file hash alone cannot establish a successful build."""
        with tempfile.TemporaryDirectory() as temporary:
            build_root = Path(temporary)
            build_dir = build_root / "fixture"
            build_dir.mkdir()
            artifact = build_dir / "image.sof"
            artifact.write_bytes(b"image")
            incomplete = {
                "status": "complete",
                "artifact": str(artifact),
                "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
            }
            for receipt in (None, [], "invalid", incomplete):
                (build_dir / "synthesis.json").write_text(json.dumps(receipt), encoding="utf-8")
                with self.subTest(receipt=receipt), mock.patch(
                    "tools.hardware_build.programming.BUILD_ROOT", build_root
                ), self.assertRaises(BuildError):
                    validate_synthesized_artifact({"synthesis_target": "fixture"}, artifact)

    def test_accepts_only_the_artifact_named_by_a_successful_receipt(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_root = Path(temp_dir)
            build_dir = build_root / "quartus-test"
            build_dir.mkdir()
            artifact = build_dir / "fpga_chess.sof"
            artifact.write_bytes(b"candidate image")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            target = {"synthesis_target": "quartus-test"}
            metadata = {
                "status": "complete",
                "build_id": "1234",
                "validated_build_id": "1234",
                "artifact": str(artifact),
                "artifact_sha256": digest,
            }
            (build_dir / "synthesis.json").write_text(json.dumps(metadata), encoding="utf-8")

            with mock.patch("tools.hardware_build.programming.BUILD_ROOT", build_root):
                validate_synthesized_artifact(target, artifact)
                artifact.write_bytes(b"stale image")
                with self.assertRaisesRegex(BuildError, "latest successful synthesis"):
                    validate_synthesized_artifact(target, artifact)

    def test_rejects_a_failed_synthesis_receipt(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_root = Path(temp_dir)
            build_dir = build_root / "quartus-test"
            build_dir.mkdir()
            artifact = build_dir / "fpga_chess.sof"
            artifact.write_bytes(b"old image")
            (build_dir / "synthesis.json").write_text(
                json.dumps({"status": "failed"}), encoding="utf-8"
            )

            with mock.patch("tools.hardware_build.programming.BUILD_ROOT", build_root), \
                    self.assertRaisesRegex(BuildError, "latest successful synthesis"):
                validate_synthesized_artifact({"synthesis_target": "quartus-test"}, artifact)


if __name__ == "__main__":
    unittest.main()
