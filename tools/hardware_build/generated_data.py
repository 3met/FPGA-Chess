"""Generate and verify deterministic hardware data."""

import argparse
import sys

from .common import BuildError, REPO_ROOT, rel, restore_outputs, run_command
from .manifest import ensure_existing, load_manifest, repo_path


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
