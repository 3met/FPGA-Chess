import argparse
import hashlib
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.hardware_build.manifest import load_manifest
from tools.hardware_build.reports_quartus import quartus_bram_columns, quartus_bram_count, short_quartus_node, wrap_timing_node
from tools.hardware_build.synthesis import (
    command_synth,
    deterministic_build_id,
    quartus_negative_slack,
    quartus_smart_commands,
    synth_quartus,
    write_engine_build_config,
    write_quartus_project,
)


class EngineBuildConfigTests(unittest.TestCase):
    def test_build_id_is_deterministic_and_tracks_target_configuration(self):
        manifest = load_manifest()
        target = manifest["synthesis_targets"]["quartus-de1-soc"]

        first = deterministic_build_id(manifest, target)
        self.assertEqual(deterministic_build_id(manifest, target), first)
        self.assertNotEqual(first, 0)
        changed_target = dict(target, seed=target["seed"] + 1)
        self.assertNotEqual(deterministic_build_id(manifest, changed_target), first)

    def test_config_contains_exact_build_id_and_clock_frequency(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = write_engine_build_config(Path(temp_dir), 40.0, 0x0123456789ABCDEF)
            self.assertEqual(config.name, "engine_build_config.svh")
            self.assertEqual(
                config.read_text(encoding="utf-8"),
                "// Generated for this synthesis configuration; do not edit.\n"
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
            self.assertIn(f"ENGINE_TT_CACHE_INDEX_BITS = {resolved['tt_cache_index_bits']}", generated_config)
            self.assertIn(
                f"ENGINE_ASPIRATION_DELTA_MULTIPLIER_Q3 = {resolved['search']['aspiration_delta_multiplier_q3']}",
                generated_config,
            )
            self.assertIn(
                f"ENGINE_RFP_MAXIMUM_DEPTH = {resolved['search']['rfp_maximum_depth']}",
                generated_config,
            )
            self.assertIn(
                f"ENGINE_FUTILITY_MAXIMUM_DEPTH = {resolved['search']['futility_maximum_depth']}",
                generated_config,
            )
            self.assertIn(
                f"ENGINE_QDELTA_MARGIN = {resolved['search']['qdelta_margin']}",
                generated_config,
            )
            qsf = project.with_suffix(".qsf").read_text(encoding="utf-8")
            self.assertIn("engine_build_config.svh", qsf)
            self.assertIn("set_global_assignment -name SMART_RECOMPILE ON", qsf)
            self.assertIn("set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED", qsf)
            self.assertIn('set_global_assignment -name FITTER_EFFORT "STANDARD FIT"', qsf)
            self.assertIn(f"FPGA_CHESS_THREAD_CAPACITY={resolved['threads']}", qsf)
            self.assertIn(f"FPGA_CHESS_SEARCH_STACK_CAPACITY={resolved['stack_depth']}", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_COMBO_LOGIC ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON", qsf)
            self.assertIn("PHYSICAL_SYNTHESIS_EFFORT EXTRA", qsf)


class QuartusReportTests(unittest.TestCase):
    def test_timing_nodes_are_compacted_and_wrapped_at_hierarchy_boundaries(self):
        node = "engine:engine|search_controller:controller|move_generator:move_generator|move_generator_pipeline:noisy_pipeline|destination_mask[5]"

        self.assertEqual(
            short_quartus_node(node),
            "engine/controller/move_generator/noisy_pipeline/destination_mask[5]",
        )
        lines = wrap_timing_node(f"{node}|very_long_intermediate_hierarchy_level", "      from: ", "            ")

        self.assertEqual(lines[0], "      from: engine/controller/move_generator/noisy_pipeline/destination_mask[5]")
        self.assertEqual(lines[1], "            very_long_intermediate_hierarchy_level")
        self.assertTrue(all(len(line) <= 88 for line in lines))

    def test_bram_columns_are_device_family_independent(self):
        headers = ["Block Memory Bits", "M10K blocks", "M20Ks", "DSP Blocks"]
        indices = quartus_bram_columns(headers)

        self.assertEqual(indices, [1, 2])
        self.assertEqual(quartus_bram_count(["30,720", "2", "3", "0"], indices), "5")

    def test_generic_ram_block_header_is_supported(self):
        headers = ["Block Memory Bits", "Total RAM Blocks"]

        self.assertEqual(quartus_bram_count(["10,240", "1"], quartus_bram_columns(headers)), "1")


class QuartusSynthesisTests(unittest.TestCase):
    def test_command_synth_applies_engine_profile_override_to_a_copy(self):
        original = {
            "tool": "quartus",
            "engine_config": "hardware/config/engine/de1-soc.json",
        }
        manifest = {"synthesis_targets": {"test": original}}
        args = argparse.Namespace(
            target="test", engine_config="work/search-tuning/engine.json",
            update_generated_data=False, jobs=2, clean=False, stream_logs=False, part=None,
        )
        with mock.patch("tools.hardware_build.synthesis.load_manifest", return_value=manifest), \
                mock.patch("tools.hardware_build.synthesis.command_gen_data", return_value=0), \
                mock.patch("tools.hardware_build.synthesis.synth_quartus", return_value=0) as synth:
            self.assertEqual(command_synth(args), 0)

        self.assertEqual(original["engine_config"], "hardware/config/engine/de1-soc.json")
        self.assertEqual(synth.call_args.args[2]["engine_config"], "work/search-tuning/engine.json")

    def test_smart_action_selects_only_required_stages(self):
        commands = [[name] for name in ("quartus_map", "quartus_fit", "quartus_sta", "quartus_asm")]

        self.assertEqual(quartus_smart_commands("DONE", commands), [])
        self.assertEqual(quartus_smart_commands("SOURCE", commands), commands)
        self.assertEqual(quartus_smart_commands("FIT_ASM", commands), commands[1:])
        self.assertEqual(quartus_smart_commands("TAN", commands), commands[2:3])
        self.assertEqual(quartus_smart_commands("ASM", commands), commands[3:])

    def test_negative_slack_includes_timing_context(self):
        summary = (
            "Type  : Slow 1100mV 85C Model Setup 'engine_clk'\n"
            "Slack : -0.736\n"
            "TNS   : -1.234\n"
            "\n"
            "Type  : Fast 1100mV 0C Model Hold 'engine_clk'\n"
            "Slack : -0.418\n"
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            (Path(temp_dir) / "fpga_chess.sta.summary").write_text(summary, encoding="utf-8")

            self.assertEqual(
                quartus_negative_slack(Path(temp_dir)),
                [
                    "Setup 'engine_clk': -0.736 ns (Slow 1100mV 85C)",
                    "Hold 'engine_clk': -0.418 ns (Fast 1100mV 0C)",
                ],
            )

    def test_negative_slack_prints_sta_as_failure_once(self):
        target = {"tool": "quartus", "top": "fpga_chess"}
        command_results = [(0, "Info: SMART_ACTION = SOURCE\n", 0.5)] + [(0, "", 1.0)] * 3
        timing_failure = "Setup 'engine_clk': -0.736 ns (Slow 1100mV 85C)"

        with tempfile.TemporaryDirectory() as temp_dir:
            build_root = Path(temp_dir)
            project = build_root / "quartus-test" / "fpga_chess"
            output = io.StringIO()
            with (
                mock.patch("tools.hardware_build.synthesis.BUILD_ROOT", build_root),
                mock.patch("tools.hardware_build.synthesis.require_tool"),
                mock.patch(
                    "tools.hardware_build.synthesis.deterministic_build_id",
                    return_value=0x1234,
                ),
                mock.patch(
                    "tools.hardware_build.synthesis.rel",
                    side_effect=lambda path: path.as_posix(),
                ),
                mock.patch(
                    "tools.hardware_build.synthesis.write_quartus_project",
                    return_value=project,
                ),
                mock.patch(
                    "tools.hardware_build.synthesis.run_command",
                    side_effect=command_results,
                ) as run_command,
                mock.patch(
                    "tools.hardware_build.synthesis.quartus_negative_slack",
                    return_value=[timing_failure],
                ),
                redirect_stdout(output),
            ):
                result = synth_quartus({}, "quartus-test", target, jobs=2)

            printed = output.getvalue()
            self.assertEqual(result, 1)
            self.assertIn(
                "[FAIL] quartus_sta (1.00s): timing constraints not met\n",
                printed,
            )
            self.assertNotIn("[PASS] quartus_sta", printed)
            self.assertEqual(printed.count("quartus_sta (1.00s)"), 1)
            self.assertNotIn("quartus_asm", printed)
            self.assertIn(f"  {timing_failure}\n", printed)
            self.assertEqual(
                [call.args[0][0] for call in run_command.call_args_list],
                ["quartus_sh", "quartus_map", "quartus_fit", "quartus_sta"],
            )

            metadata = json.loads(
                (build_root / "quartus-test" / "synthesis.json").read_text(encoding="utf-8")
            )
            self.assertEqual(metadata["status"], "failed")
            self.assertEqual(metadata["stages"][-1]["status"], "fail")

    def test_done_smart_action_skips_all_compilation_stages(self):
        target = {"tool": "quartus", "top": "fpga_chess"}
        with tempfile.TemporaryDirectory() as temp_dir:
            build_root = Path(temp_dir)
            project = build_root / "quartus-test" / "fpga_chess"
            project.parent.mkdir(parents=True)
            artifact = project.with_suffix(".sof")
            artifact.write_bytes(b"valid image")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            (project.parent / "synthesis.json").write_text(json.dumps({
                "status": "complete",
                "build_id": "0000000000001234",
                "validated_build_id": "0000000000001234",
                "artifact_sha256": digest,
            }), encoding="utf-8")
            with (
                mock.patch("tools.hardware_build.synthesis.BUILD_ROOT", build_root),
                mock.patch("tools.hardware_build.synthesis.require_tool"),
                mock.patch("tools.hardware_build.synthesis.deterministic_build_id", return_value=0x1234),
                mock.patch("tools.hardware_build.synthesis.rel", side_effect=lambda path: path.as_posix()),
                mock.patch("tools.hardware_build.synthesis.write_quartus_project", return_value=project),
                mock.patch(
                    "tools.hardware_build.synthesis.run_command",
                    return_value=(0, "Info: SMART_ACTION = DONE\n", 0.5),
                ) as run_command,
            ):
                result = synth_quartus({}, "quartus-test", target, jobs=2)

            self.assertEqual(result, 0)
            self.assertEqual(run_command.call_count, 1)
            metadata = json.loads((project.parent / "synthesis.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["smart_action"], "DONE")
            self.assertEqual(metadata["status"], "complete")


if __name__ == "__main__":
    unittest.main()
