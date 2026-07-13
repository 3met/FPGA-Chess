"""Deterministic hardware-data generation and comprehensive checks."""

import argparse
import sys

from .common import BuildError, REPO_ROOT, print_failure_excerpt, rel, restore_outputs, run_command
from .manifest import ensure_existing, load_manifest, repo_path
from .simulation import command_test


def command_gen_data(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    changed: list[str] = []

    for name, item in sorted(manifest["generated_data"].items()):
        script = repo_path(item["script"])
        outputs = [repo_path(output) for output in item["outputs"]]
        ensure_existing([script])
        before = {path: path.read_bytes() if path.exists() else None for path in outputs}

        print(f"Generating {name}...")
        code, output, elapsed = run_command([sys.executable, str(script)], REPO_ROOT)
        if output.strip():
            print(output.rstrip())
        if code != 0:
            if not args.update:
                restore_outputs(before)
            raise BuildError(f"{rel(script)} failed with exit code {code}")

        for path in outputs:
            old = before[path]
            new = path.read_bytes() if path.exists() else None
            if old != new:
                changed.append(rel(path))
                if not args.update:
                    restore_outputs({path: old})
        print(f"  done in {elapsed:.2f}s")

    if changed and not args.update:
        print("Generated data drift detected; restored original files:")
        for path in changed:
            print(f"  {path}")
        print("Run with --update to keep regenerated outputs.")
        return 1

    if changed:
        print("Updated generated data:")
        for path in changed:
            print(f"  {path}")
    else:
        print("Generated data is up to date.")
    return 0


def command_check(args: argparse.Namespace) -> int:
    if args.jobs is not None and args.jobs < 1:
        raise BuildError("--jobs must be at least 1")
    if args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    print("== Generated data ==")
    if command_gen_data(argparse.Namespace(update=False)) != 0:
        return 1

    print("\n== Python tests ==")
    cmd = [sys.executable, "-m", "unittest", "discover", "-s", "software", "-p", "test_*.py"]
    code, output, elapsed = run_command(cmd, REPO_ROOT)
    if output.strip():
        print(output.rstrip())
    print(f"[{'PASS' if code == 0 else 'FAIL'}] Python tests ({elapsed:.2f}s)")
    if code != 0:
        print_failure_excerpt(output)
        return 1

    print("\n== RTL tests ==")
    return command_test(argparse.Namespace(names=None, jobs=args.jobs, timeout=args.timeout))
