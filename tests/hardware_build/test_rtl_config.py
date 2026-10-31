"""Configuration selection and compiler wiring for shared RTL types."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.common import BuildError
from tools.evaluation_model import BASELINE_PATH
from tools.hardware_build.manifest import load_manifest
from tools.hardware_build.rtl_config import load_type_config, rtl_config_source, type_config_for_target, write_rtl_config
from tools.hardware_build.simulation import compile_modelsim
from tools.hardware_build.synthesis import write_vivado_project


class RTLConfigTests(unittest.TestCase):
    def test_separate_builds_keep_their_selected_capacities(self):
        """Single-entry and non-power-of-two configurations remain independent."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for threads, stack_depth in ((1, 1), (3, 33), (17, 65)):
                config = {"evaluation_file": str(BASELINE_PATH), "threads": threads, "stack_depth": stack_depth, "nnue_cache_entries": 4}
                write_rtl_config(root / str(threads), config)
            # Read after all writes so accidental shared output paths are detected.
            for threads, stack_depth in ((1, 1), (3, 33), (17, 65)):
                with self.subTest(threads=threads, stack_depth=stack_depth):
                    source = (root / str(threads) / "rtl_config.sv").read_text()
                    self.assertIn(f"THREAD_CAPACITY = {threads};", source)
                    self.assertIn(f"SEARCH_STACK_CAPACITY = {stack_depth};", source)

    def test_missing_or_invalid_capacities_have_no_fallback(self):
        """A missing input fails rather than choosing unrelated shared type widths."""
        for config in ({}, {"threads": 0, "stack_depth": 2},
                       {"threads": True, "stack_depth": 2}, {"threads": 2, "stack_depth": 0}):
            with self.subTest(config=config), self.assertRaises(BuildError):
                rtl_config_source(config)
        for target in ({}, {"engine_config": "unused", "type_config": "unused"}):
            with self.subTest(target=target), self.assertRaises(BuildError):
                type_config_for_target(target)

    def test_cache_capacity_is_validated_and_rendered(self):
        """Cache geometry travels with the shared slot type in each generated package."""
        for entries in (2, 4, 16):
            source = rtl_config_source({"evaluation_file": str(BASELINE_PATH), "threads": 3, "stack_depth": 33, "nnue_cache_entries": entries})
            self.assertIn(f"NNUE_CACHE_ENTRIES = {entries};", source)
        for entries in (0, 1, 3, True):
            with self.subTest(entries=entries), self.assertRaises(BuildError):
                rtl_config_source({"evaluation_file": str(BASELINE_PATH), "threads": 3, "stack_depth": 33, "nnue_cache_entries": entries})

    def test_standalone_profile_rejects_independent_width_settings(self):
        """Widths must be derived from capacities rather than independently configured."""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "types.json"
            path.write_text(json.dumps({"evaluation_file": str(BASELINE_PATH), "threads": 3, "stack_depth": 33, "thread_id_bits": 2, "nnue_cache_entries": 4}))
            with self.assertRaisesRegex(BuildError, "unknown thread_id_bits"):
                load_type_config(str(path))

    def test_modelsim_compiles_selected_configuration_before_shared_types(self):
        """Standalone builds deliver their explicit capacities to the compiler first."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "types.json"
            config = {"evaluation_file": str(BASELINE_PATH), "threads": 3, "stack_depth": 33, "nnue_cache_entries": 4}
            config_path.write_text(json.dumps(config))
            source = root / "chess_defs.sv"
            with mock.patch("tools.hardware_build.simulation.modelsim_tools", return_value={"vlib": "vlib", "vlog": "vlog"}), \
                    mock.patch("tools.hardware_build.simulation.run_command", return_value=(0, "", 0)) as run:
                result = compile_modelsim("types", [source], root / "build", {"type_config": str(config_path)})
            self.assertTrue(result["ok"])
            command = run.call_args.args[0]
            generated = root / "build/rtl_config.sv"
            self.assertLess(command.index(str(generated)), command.index(str(source)))
            self.assertEqual(generated.read_text(), rtl_config_source(config, generated.parent))

    def test_vivado_compiles_explicit_capacity_profile_first(self):
        """Generic vendor projects consume the same generator as simulations."""
        manifest = load_manifest()
        target = manifest["synthesis_targets"]["vivado-nnue"]
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch("tools.hardware_build.synthesis.BUILD_ROOT", Path(temporary)):
            tcl = write_vivado_project(manifest, "types", target, "test-part")
            source = tcl.read_text()
            generated = tcl.parent / "rtl_config.sv"
            self.assertLess(source.index("rtl_config.sv"), source.index("chess_defs.sv"))
            self.assertEqual(generated.read_text(), rtl_config_source(load_type_config(target["type_config"]), generated.parent))
