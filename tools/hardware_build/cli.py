"""Command-line parsing and dispatch for the hardware build tools."""

import argparse
import sys

from .common import BuildError, RTL_TEST_TIMEOUT_SECONDS
from .generated_data import command_check, command_gen_data
from .manifest import command_list, command_validate
from .reports import command_synth_report, command_timing_paths
from .simulation import command_compile, command_test
from .synthesis import command_synth


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List source sets, tests, synthesis targets, and generated data")
    list_parser.set_defaults(func=command_list)

    validate_parser = subparsers.add_parser("validate", help="Validate the build manifest and referenced files")
    validate_parser.set_defaults(func=command_validate)

    gen_parser = subparsers.add_parser("gen-data", help="Regenerate deterministic RTL data files")
    gen_parser.add_argument("--update", action="store_true", help="Keep regenerated outputs when they differ")
    gen_parser.set_defaults(func=command_gen_data)

    compile_parser = subparsers.add_parser("compile", help="Compile an RTL source set with ModelSim/Questa")
    compile_parser.add_argument("--set", dest="sets", action="append", help="Source set to compile; defaults to portable-rtl")
    compile_parser.set_defaults(func=command_compile)

    test_parser = subparsers.add_parser("test", help="Run SystemVerilog testbenches with ModelSim/Questa")
    test_parser.add_argument("--name", dest="names", action="append", help="Test name to run; defaults to all tests")
    test_parser.add_argument("--jobs", type=int, help="Number of tests to run concurrently; defaults to 1")
    test_parser.add_argument(
        "--timeout",
        type=float,
        default=RTL_TEST_TIMEOUT_SECONDS,
        help=f"Wall-clock seconds allowed per RTL simulation; defaults to {RTL_TEST_TIMEOUT_SECONDS}",
    )
    test_parser.set_defaults(func=command_test)

    check_parser = subparsers.add_parser("check", help="Check generated data and run Python and RTL tests")
    check_parser.add_argument("--jobs", type=int, help="Number of RTL tests to run concurrently; defaults to 1")
    check_parser.add_argument(
        "--timeout",
        type=float,
        default=RTL_TEST_TIMEOUT_SECONDS,
        help=f"Wall-clock seconds allowed per RTL simulation; defaults to {RTL_TEST_TIMEOUT_SECONDS}",
    )
    check_parser.set_defaults(func=command_check)

    synth_parser = subparsers.add_parser("synth", help="Run a synthesis target")
    synth_parser.add_argument("--target", required=True, help="Synthesis target name")
    synth_parser.add_argument("--part", help="Xilinx part for vivado-generic")
    synth_parser.add_argument("--jobs", type=int, help="Quartus parallel processor limit; overrides automatic detection")
    synth_parser.add_argument("--clean", action="store_true", help="Delete the Quartus build directory before synthesis")
    synth_parser.add_argument(
        "--stream-logs",
        action="store_true",
        help="Stream vendor tool output to the console while synthesis runs",
    )
    synth_parser.add_argument(
        "--update-generated-data",
        action="store_true",
        help="Regenerate and keep changed generated data before synthesis",
    )
    synth_parser.set_defaults(func=command_synth)

    report_parser = subparsers.add_parser("synth-report", help="Print results from the previous synthesis run")
    report_parser.add_argument("--target", help="Synthesis target; defaults to the most recently modified result")
    report_parser.add_argument("--verbose", action="store_true", help="Show the complete component utilization hierarchy")
    report_parser.set_defaults(func=command_synth_report)

    paths_parser = subparsers.add_parser("timing-paths", help="Report the worst failing setup paths from an existing Quartus fit")
    paths_parser.add_argument("--target", required=True, help="Quartus synthesis target to inspect")
    paths_parser.add_argument("--limit", type=int, default=15, help="Maximum failing paths to report; defaults to 15")
    paths_parser.set_defaults(func=command_timing_paths)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

