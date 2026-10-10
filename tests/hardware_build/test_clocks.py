"""Clock ownership and propagation regressions use explicit operating fixtures."""

import argparse
import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.hardware_build.clocks import clock_rtl_parameters, resolve_clocks
from tools.hardware_build.common import BuildError
from tools.hardware_build.engine_config import engine_config_digest, load_engine_config
from tools.hardware_build.manifest import load_manifest
from tools.hardware_build.profiling import _profile_clock_parameter_args, _resolve_profile_config
from tools.hardware_build.synthesis import deterministic_build_id, materialize_intel_pll, write_quartus_project


def fixture_clocks():
    """Distinct settings expose role swaps, ignored phase, and stale board defaults."""
    return {"engine": {"frequency_hz": 60_000_000, "phase_ps": -100, "duty_percent": 45},
            "memory": {"frequency_hz": 100_000_000, "phase_ps": 200, "duty_percent": 55},
            "memory_io": {"phase_ps": -1250, "duty_percent": 40},
            "communication": {"frequency_hz": 80_000_000, "phase_ps": 300, "duty_percent": 60}}


class ClockTests(unittest.TestCase):
    def test_invalid_and_missing_settings_are_rejected(self):
        cases = []
        for role, setting, value in (("engine", "frequency_hz", True),
                                     ("engine", "frequency_hz", 60_000_001),
                                     ("memory", "frequency_hz", 0),
                                     ("memory_io", "duty_percent", 100),
                                     ("communication", "phase_ps", 1.5)):
            clocks = fixture_clocks()
            clocks[role][setting] = value
            cases.append(clocks)
        clocks = fixture_clocks()
        del clocks["memory"]["phase_ps"]
        cases.append(clocks)
        clocks = fixture_clocks()
        clocks["memory_io"]["frequency_hz"] = 50_000_000
        cases.append(clocks)
        cases.extend([None, {}, {**fixture_clocks(), "unused": {}}])
        for clocks in cases:
            with self.subTest(clocks=clocks), self.assertRaises(BuildError):
                resolve_clocks(clocks)

    def test_alternate_engine_profile_drives_profiler_and_all_pll_outputs(self):
        manifest = load_manifest()
        target = manifest["synthesis_targets"]["quartus-de1-soc"]
        profile = load_engine_config(target["engine_config"])
        profile["clocks"] = fixture_clocks()
        profile["digest"] = engine_config_digest(profile)
        args = argparse.Namespace(target="quartus-de1-soc", engine_config="alternate.json",
                                  threads=None, stack_depth=None, engine_clock_hz=None)
        with patch("tools.hardware_build.profiling.load_engine_config", return_value=copy.deepcopy(profile)):
            args.resolved_engine_config = _resolve_profile_config(args, manifest)
        self.assertEqual(args.resolved_engine_config["clocks"], profile["clocks"])
        parameters = _profile_clock_parameter_args(args, "-G")
        for name, value in clock_rtl_parameters(profile["clocks"], profiling=True).items():
            self.assertIn(f"-G{name}={value}", parameters)
        with tempfile.TemporaryDirectory() as temporary:
            build = Path(temporary)
            project = write_quartus_project(manifest, target, build, 1, 123, profile)
            pll = (build / "clock_generator/pll_ip/pll_ip_0002.sv").read_text()
            blocks = pll.split("    altera_pll #(\n")[1:]
            for block, role in zip(blocks, ("engine", "memory", "communication")):
                clock = profile["clocks"][role]
                self.assertIn(f'.output_clock_frequency0("{clock["frequency_hz"] / 1e6:.6f} MHz")', block)
                self.assertIn(f'.phase_shift0("{clock["phase_ps"]} ps")', block)
                self.assertIn(f'.duty_cycle0({clock["duty_percent"]})', block)
            self.assertIn('.phase_shift1("-1050 ps")', blocks[1])
            self.assertIn('.output_clock_frequency1("100.000000 MHz")', blocks[1])
            text = (build / "engine_build_config.svh").read_text()
            for name, value in clock_rtl_parameters(profile["clocks"]).items():
                self.assertIn(f"localparam int {name} = {value};", text)
            qsf = project.with_suffix(".qsf").read_text()
            self.assertLess(qsf.index("reference_clock.sdc"), qsf.index(target["sdc"]))
            reference = (build / "reference_clock.sdc").read_text()
            board = target["clock_generator"]
            self.assertIn(f"-period {1e9 / board['reference_frequency_hz']:.9f}", reference)
            self.assertIn(f"[get_ports {{{board['reference_port']}}}]", reference)

    def test_every_clock_setting_invalidates_digest_and_build_id(self):
        manifest = load_manifest()
        target = manifest["synthesis_targets"]["quartus-de1-soc"]
        profile = load_engine_config(target["engine_config"])
        first = deterministic_build_id(manifest, target, profile)
        for role, clock in profile["clocks"].items():
            for setting in clock:
                changed = copy.deepcopy(profile)
                changed["clocks"][role][setting] += 1000 if setting == "frequency_hz" else 1
                changed["digest"] = engine_config_digest(changed)
                with self.subTest(role=role, setting=setting):
                    self.assertNotEqual(changed["digest"], profile["digest"])
                    self.assertNotEqual(deterministic_build_id(manifest, target, changed), first)

    def test_missing_template_field_fails_instead_of_using_stale_setting(self):
        target = load_manifest()["synthesis_targets"]["quartus-de1-soc"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            template = root / "template"
            (template / "pll_ip").mkdir(parents=True)
            (template / "pll_ip/pll_ip_0002.sv").write_text("module obsolete; endmodule\n")
            with self.assertRaisesRegex(BuildError, "PLL template must contain"):
                materialize_intel_pll(template, root / "build", fixture_clocks(), target["clock_generator"])
