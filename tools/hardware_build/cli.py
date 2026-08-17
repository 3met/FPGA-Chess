"""Command-line parsing and dispatch for the hardware build tools."""

import argparse
import signal
import sys

from .common import BuildError, RTL_TEST_TIMEOUT_SECONDS
from .generated_data import command_check, command_gen_data
from .manifest import command_list, command_validate
from .programming import command_flash
from .profiling import command_profile, command_profile_position
from .reports import command_synth_report
from .reports_quartus import command_timing_paths
from .simulation import command_compile, command_test
from .synthesis import command_synth


def handle_termination_signal(_signum: int, _frame: object) -> None:
    """Turn SIGTERM into normal interruption so active tool trees are cleaned up."""
    raise KeyboardInterrupt


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

    def add_profile_options(profile_command: argparse.ArgumentParser) -> None:
        """Add simulator and search settings shared by both profiling commands."""
        limits = profile_command.add_mutually_exclusive_group()
        limits.add_argument("--depth", type=int, help="Fixed search depth")
        limits.add_argument("--nodes", type=int, help="Node-limited search")
        limits.add_argument("--time-ms", type=int, help="Fixed simulated search time; defaults to 50 ms")
        profile_command.add_argument("--threads", type=int, default=1, help="Search threads; defaults to the DE1 value 1")
        profile_command.add_argument("--stack-depth", type=int, default=32, help="Stack plies; defaults to 32")
        profile_command.add_argument(
            "--engine-clock-hz", type=int, default=50_000_000,
            help="Engine clock frequency; defaults to the DE1 value 50000000",
        )
        profile_command.add_argument(
            "--timeout", type=float,
            help="Optional simulator wall-clock timeout in seconds per position; disabled by default",
        )
        profile_command.add_argument("--output", help="Artifact directory; defaults to a timestamped build directory")
        profile_command.add_argument(
            "--simulator", choices=("auto", "verilator", "modelsim"), default="auto",
            help="Simulation backend; auto prefers Verilator when installed",
        )
        profile_command.add_argument(
            "--simulator-threads", type=int, default=1,
            help="Verilator execution threads; defaults to 1 because this design partitions poorly",
        )
        profile_command.add_argument("--force-rebuild", action="store_true", help="Rebuild the profiling simulator")
        profile_command.add_argument("--event-trace", action="store_true", help="Retain a JSONL event trace per position")
        profile_command.add_argument(
            "--waveform", action="store_true",
            help="Retain a complete FST (Verilator) or WLF (ModelSim) waveform per position",
        )

    profile_parser = subparsers.add_parser(
        "profile", help="Profile the named position suite and print aggregate statistics"
    )
    add_profile_options(profile_parser)
    profile_parser.add_argument(
        "--jobs", type=int,
        help="Concurrent position simulations; defaults to available CPUs for Verilator and 1 for ModelSim",
    )
    profile_parser.set_defaults(func=command_profile)

    position_parser = subparsers.add_parser(
        "profile_position", help="Profile one specified position in the cycle-accurate engine simulation"
    )
    position_parser.add_argument("--fen", required=True, help="Position to profile in FEN notation")
    add_profile_options(position_parser)
    position_parser.set_defaults(func=command_profile_position)

    check_parser = subparsers.add_parser("check", help="Check generated data and run Python and RTL tests")
    check_parser.add_argument("--jobs", type=int, help="Number of RTL tests to run concurrently; defaults to 1")
    check_parser.add_argument(
        "--tuning",
        action="store_true",
        help="Also run tests requiring the optional evaluation-tuning dependencies",
    )
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

    flash_parser = subparsers.add_parser("flash", help="Program an FPGA with a synthesized artifact")
    flash_parser.add_argument("--target", required=True, help="Programming target name")
    flash_parser.add_argument("--file", help="Artifact file; overrides the target default")
    flash_parser.add_argument("--cable", help="Quartus programmer cable name or number")
    flash_parser.add_argument("--device-index", type=int, help="JTAG chain position; overrides automatic ID detection")
    flash_parser.add_argument("--dry-run", action="store_true", help="Print the programmer command without running it")
    flash_parser.set_defaults(func=command_flash)

    report_parser = subparsers.add_parser("synth-report", help="Print results from the previous synthesis run")
    report_parser.add_argument("--target", help="Synthesis target; defaults to the most recently modified result")
    report_parser.add_argument("--verbose", action="store_true", help="Show the complete component utilization hierarchy")
    report_parser.set_defaults(func=command_synth_report)

    paths_parser = subparsers.add_parser(
        "timing-paths", help="Report failing setup paths, or the tightest passing paths when timing is met"
    )
    paths_parser.add_argument("--target", required=True, help="Quartus synthesis target to inspect")
    paths_parser.add_argument("--limit", type=int, default=15, help="Maximum paths to report; defaults to 15")
    paths_parser.set_defaults(func=command_timing_paths)

    return parser


def main(argv: list[str] | None = None) -> int:
    signal.signal(signal.SIGTERM, handle_termination_signal)
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("Interrupted; stopped active build processes.", file=sys.stderr)
        return 130
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
