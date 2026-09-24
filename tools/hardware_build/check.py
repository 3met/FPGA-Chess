"""Run generated-data, Python, and RTL checks together."""

import argparse
import sys

from .common import BuildError, REPO_ROOT, print_failure_excerpt, run_command
from .generated_data import command_gen_data
from .simulation import command_test


def command_check(args: argparse.Namespace) -> int:
    """Run core checks in order and stop at the first failure."""
    if args.jobs is not None and args.jobs < 1:
        raise BuildError("--jobs must be at least 1")
    if args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    print("== Generated data ==")
    if command_gen_data(argparse.Namespace(update=False)) != 0:
        return 1

    suites = [
        ("Engine host", "tests/engine"),
        ("Live FPGA tooling", "tests/live_fpga"),
        ("Hardware build", "tests/hardware_build"),
    ]
    if args.tuning:
        suites.append(("Evaluation tuning", "tests/tuning"))

    print("\n== Python tests ==")
    for label, directory in suites:
        cmd = [sys.executable, "-m", "unittest", "discover", "-s", directory, "-p", "test_*.py"]
        code, output, elapsed = run_command(cmd, REPO_ROOT)
        if output.strip():
            print(output.rstrip())
        print(f"[{'PASS' if code == 0 else 'FAIL'}] {label} tests ({elapsed:.2f}s)")
        if code != 0:
            print_failure_excerpt(output)
            return 1

    print("\n== RTL tests ==")
    return command_test(argparse.Namespace(names=None, jobs=args.jobs, timeout=args.timeout))
