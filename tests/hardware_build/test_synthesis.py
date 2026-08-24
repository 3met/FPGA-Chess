import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.manifest import load_manifest
from tools.hardware_build.synthesis import new_build_id, write_engine_build_config, write_quartus_project


class EngineBuildConfigTests(unittest.TestCase):
    def test_build_id_is_nonzero_and_retries_zero(self):
        with mock.patch("tools.hardware_build.synthesis.secrets.randbits", side_effect=[0, 0x1234]) as randbits:
            self.assertEqual(new_build_id(), 0x1234)
        self.assertEqual(randbits.call_args_list, [mock.call(64), mock.call(64)])

    def test_config_contains_exact_build_id_and_clock_frequency(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = write_engine_build_config(Path(temp_dir), 40.0, 0x0123456789ABCDEF)
            self.assertEqual(config.name, "engine_build_config.svh")
            self.assertEqual(
                config.read_text(encoding="utf-8"),
                "// Generated for this synthesis invocation; do not edit.\n"
                "localparam logic [63:0] FPGA_BUILD_ID = 64'h0123456789abcdef;\n"
                "localparam int ENGINE_CLOCK_FREQ = 40_000_000;\n",
            )

    def test_quartus_project_includes_generated_engine_metadata(self):
        manifest = load_manifest()
        target = manifest["synthesis_targets"]["quartus-de1-soc"]
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            project = write_quartus_project(manifest, target, build_dir, 2, 0x0123456789ABCDEF)

            self.assertEqual(project, build_dir / "fpga_chess")
            self.assertTrue((build_dir / "engine_build_config.svh").is_file())
            self.assertTrue((build_dir / "resolved_engine_config.json").is_file())
            resolved = json.loads(
                (build_dir / "resolved_engine_config.json").read_text(encoding="utf-8")
            )
            generated_config = (build_dir / "engine_build_config.svh").read_text(encoding="utf-8")
            self.assertIn(f"ENGINE_SEARCH_THREAD_COUNT = {resolved['threads']}", generated_config)
            self.assertIn(f"ENGINE_SEARCH_STACK_DEPTH = {resolved['stack_depth']}", generated_config)
            self.assertIn(
                f"ENGINE_ASPIRATION_DELTA_MULTIPLIER_Q3 = {resolved['search']['aspiration_delta_multiplier_q3']}",
                generated_config,
            )
            qsf = project.with_suffix(".qsf").read_text(encoding="utf-8")
            self.assertIn("engine_build_config.svh", qsf)
            self.assertIn(f"FPGA_CHESS_THREAD_CAPACITY={resolved['threads']}", qsf)
            self.assertIn(f"FPGA_CHESS_SEARCH_STACK_CAPACITY={resolved['stack_depth']}", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_COMBO_LOGIC ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_EFFORT EXTRA", qsf)


if __name__ == "__main__":
    unittest.main()
