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

    def test_license_lock_failure_is_identified_without_bench_summaries(self):
        """A simulator licensing failure must be distinguished from an incomplete bench."""
        transcript = (
            "# ** Fatal: Unable to read lock file necessary for use of "
            "uncounted nodelocked license. Exiting.\n"
        )
        result = self.run_transcript(transcript, exit_code=4)
        self.assertFalse(result["ok"])
        self.assertEqual(result["message"], "ModelSim license-lock failure")
        result = self.run_transcript(transcript.replace("# ** Fatal: ", "")
                                     + "Pass Count: 1\nFail Count: 0\n", exit_code=0)
        self.assertFalse(result["ok"])


class VerilatorBackendTests(unittest.TestCase):
    def test_auto_selection_and_explicit_backends(self):
        """Auto chooses an installed backend; explicit requests remain explicit."""
        from tools.hardware_build.simulation import select_simulators
        for installed in (None, '/tools/verilator'):
            with mock.patch('tools.hardware_build.simulation.shutil.which', return_value=installed):
                self.assertEqual(select_simulators('auto'), ['verilator' if installed else 'modelsim'])
                self.assertEqual(select_simulators('modelsim'), ['modelsim'])
                self.assertEqual(select_simulators('both'), ['verilator', 'modelsim'])

    def test_verilator_error_cannot_pass_with_success_summaries(self):
        """Runtime errors take precedence over a bench's passing summary."""
        from tools.hardware_build.simulation import simulation_result
        result = simulation_result('bench', 0, 'Pass Count: 1\nFail Count: 0\n%Error: assertion failed\n',
                                   0.1, Path('transcript.log'), 1)
        self.assertFalse(result['ok'])

    def test_cache_invalidates_sources_capacities_and_toolchain_and_rejects_failed_builds(self):
        """Cached executables must match inputs, and failed rebuilds must remove stale results."""
        import json
        from tools.hardware_build.simulation import compile_verilator
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'bench.sv'
            source.write_text('`include "fixture.svh"\nmodule bench; endmodule')
            header = root / 'fixture.svh'
            header.write_text('// original fixture')
            config = root / 'types.json'
            config.write_text(json.dumps({'threads': 3, 'stack_depth': 33}))
            versions = {'verilator': 'Verilator fixture', 'g++': 'C++ fixture'}
            builds = []
            backend_flags = []
            fail_build = False
            def run(command, cwd, log_path=None, **kwargs):
                if '--version' in command:
                    return 0, versions[command[0]], 0
                builds.append(command)
                if fail_build:
                    return 124, 'compile timeout', 0
                self.assertGreater(kwargs['timeout_seconds'], 0)
                Path(command[command.index('-o') + 1]).write_bytes(b'executable fixture')
                return 0, '', 0
            def compile_bench():
                return compile_verilator('bench', 'bench', [source], root / 'build',
                                          {'type_config': str(config), 'verilator_args': backend_flags})
            with mock.patch('tools.hardware_build.simulation.require_tool', side_effect=lambda name: name), \
                    mock.patch('tools.hardware_build.simulation.run_command', side_effect=run), \
                    mock.patch.dict('os.environ', {'CXX': 'g++'}):
                self.assertTrue(compile_bench()['ok'])
                self.assertEqual(compile_bench()['message'], 'cached')
                self.assertEqual(len(builds), 1)
                header.write_text('// changed fixture')
                self.assertTrue(compile_bench()['ok'])
                self.assertEqual(len(builds), 2)
                source.write_text('module bench; initial $finish; endmodule')
                self.assertTrue(compile_bench()['ok'])
                config.write_text(json.dumps({'threads': 5, 'stack_depth': 17}))
                self.assertTrue(compile_bench()['ok'])
                versions['verilator'] = 'changed toolchain fixture'
                self.assertTrue(compile_bench()['ok'])
                backend_flags.append('-O0')
                self.assertTrue(compile_bench()['ok'])
                self.assertEqual(len(builds), 6)
                self.assertIn('-O0', builds[-1])
                self.assertIn('--assert', builds[-1])
                self.assertLess(builds[-1].index(str(root / 'build/rtl_config.sv')),
                                builds[-1].index(str(source)))
                source.write_text('invalid bench')
                fail_build = True
                failure = compile_bench()
                self.assertFalse(failure['ok'])
                self.assertIn('build timed out', failure['message'])
                self.assertFalse((root / 'build/fingerprint.txt').exists())
                self.assertFalse(compile_bench()['executable'].exists())

    def test_concurrent_commands_serialize_shared_artifacts(self):
        """Two invocations of one bench cannot replace each other's build or logs."""
        import concurrent.futures
        import threading
        from tools.hardware_build.simulation import run_test
        active = 0
        overlap = False
        guard = threading.Lock()
        def simulate(*args):
            nonlocal active, overlap
            with guard:
                active += 1
                overlap |= active > 1
            threading.Event().wait(0.15)
            with guard:
                active -= 1
            return ({'ok': True}, {'ok': True})
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch('tools.hardware_build.simulation.BUILD_ROOT', Path(temporary)), \
                mock.patch('tools.hardware_build.simulation._run_test_unlocked', side_effect=simulate):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                futures = [executor.submit(run_test, {}, 'bench', 1, 'verilator') for _ in range(2)]
                for future in futures:
                    self.assertTrue(future.result()[1]['ok'])
        self.assertFalse(overlap)

    def test_source_dependencies_follow_nested_headers_and_cycles(self):
        """Nested headers are fingerprinted once; commented includes are ignored."""
        from tools.hardware_build.common import BuildError, rtl_source_dependencies
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, header, nested = [root / name for name in ('bench.sv', 'first.svh', 'second.svh')]
            source.write_text('`include "first.svh"\n// `include "absent.svh"')
            header.write_text('`include "second.svh"')
            nested.write_text('`include "first.svh"')
            self.assertEqual(rtl_source_dependencies([source]), [source, header, nested])
            nested.unlink()
            with self.assertRaisesRegex(BuildError, 'Cannot resolve RTL include'):
                rtl_source_dependencies([source])

    def test_verilator_failure_never_falls_back_to_modelsim(self):
        """A failed test must remain visible rather than selecting a different simulator."""
        import argparse
        import io
        from contextlib import redirect_stdout
        from tools.hardware_build.simulation import command_test
        result = ({'ok': False, 'message': 'compile error', 'elapsed': 0,
                   'log': Path('compile.log'), 'output': 'error'}, None)
        with mock.patch('tools.hardware_build.simulation.load_manifest', return_value={'tests': {'bench': {}}}), \
                mock.patch('tools.hardware_build.simulation.run_test', return_value=result) as run, \
                mock.patch('tools.hardware_build.simulation.print_test_result', return_value=False), \
                redirect_stdout(io.StringIO()):
            self.assertEqual(command_test(argparse.Namespace(names=['bench', 'bench'], jobs=2,
                                                            timeout=1, simulator='verilator')), 1)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[-1], 'verilator')


if __name__ == "__main__":
    unittest.main()
