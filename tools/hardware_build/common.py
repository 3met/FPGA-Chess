#!/usr/bin/env python3
"""Shared paths, process handling, and errors for hardware build tooling."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# This package remains under tools/ while all operation paths stay repo-rooted.
REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "hardware" / "build" / "manifest.json"
BUILD_ROOT = REPO_ROOT / "work" / "build"
SYNTH_METADATA = "synthesis.json"
QUARTUS_ERROR_RE = re.compile(
    r"^\s*(?:internal\s+error|fatal|error(?:\s+\(\d+\))?):",
    flags=re.IGNORECASE | re.MULTILINE,
)
# The full eight-thread search-controller regression is intentionally large
# and can take several minutes in the free ModelSim edition.
RTL_TEST_TIMEOUT_SECONDS = 600


class BuildError(RuntimeError):
    pass


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def repo_path(value: str) -> Path:
    """Resolve a manifest path relative to the repository root."""
    return (REPO_ROOT / value).resolve()


def quote_tcl_path(path: Path) -> str:
    return path.resolve().as_posix()


def require_tool(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise BuildError(f"Required tool '{name}' was not found on PATH")
    return found


def host_parallel_processors() -> int:
    if hasattr(os, "sched_getaffinity"):
        try:
            return max(1, len(os.sched_getaffinity(0)))
        except OSError:
            pass
    return max(1, os.cpu_count() or 1)


def process_group_options() -> dict[str, object]:
    """Start each tool in its own group so interruption can stop all of its workers."""
    if os.name == "nt":
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def terminate_process_tree(proc: subprocess.Popen[str], force: bool = False) -> None:
    """Stop a launched tool and every process it started, on either supported host OS."""
    if proc.poll() is not None:
        return
    if os.name == "nt":
        # taskkill's /T includes vendor-tool worker processes that do not exit
        # when their immediate launcher is terminated.
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return
    os.killpg(proc.pid, signal.SIGKILL if force else signal.SIGTERM)


def stop_process_tree(proc: subprocess.Popen[str]) -> None:
    """Allow a tool tree to exit cleanly, then force it down if necessary."""
    terminate_process_tree(proc)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        terminate_process_tree(proc, force=True)
        proc.wait()


def run_command(
    cmd: list[str],
    cwd: Path,
    log_path: Path | None = None,
    live_log: bool = False,
    tee_stdout: bool = False,
    timeout_seconds: float | None = None,
) -> tuple[int, str, float]:
    start = time.monotonic()
    if not live_log:
        # A wall-clock limit prevents a non-converging simulator delta cycle
        # from leaving the unified check command running indefinitely.
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            **process_group_options(),
        )
        timed_out = False
        try:
            output, _ = proc.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            terminate_process_tree(proc)
            try:
                output, _ = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                terminate_process_tree(proc, force=True)
                output, _ = proc.communicate()
            partial_output = exc.output or ""
            if isinstance(partial_output, bytes):
                partial_output = partial_output.decode("utf-8", errors="replace")
            timeout_text = f"Command timed out after {timeout_seconds:.0f}s.\n"
            output = partial_output + output + timeout_text
        except BaseException:
            # KeyboardInterrupt and termination signals are delivered to this
            # Python process, not the isolated vendor-tool process group.
            stop_process_tree(proc)
            raise
        elapsed = time.monotonic() - start
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(output, encoding="utf-8")
        return (124 if timed_out else proc.returncode), output, elapsed

    if log_path is None:
        raise BuildError("live_log requires a log path")

    log_path.parent.mkdir(parents=True, exist_ok=True)
    chunks: list[str] = []
    with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            **process_group_options(),
        )
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                chunks.append(line)
                log_file.write(line)
                log_file.flush()
                if tee_stdout:
                    print(line, end="", flush=True)
            code = proc.wait()
        except BaseException:
            stop_process_tree(proc)
            raise
    elapsed = time.monotonic() - start
    return code, "".join(chunks), elapsed


def error_excerpt(output: str, limit: int = 8) -> list[str]:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    interesting = [
        line
        for line in lines
        if re.search(r"\b(error|fatal|failed|failure)\b", line, flags=re.IGNORECASE)
    ]
    return (interesting or lines)[-limit:]


def print_failure_excerpt(output: str) -> None:
    excerpt = error_excerpt(output)
    if excerpt:
        print("  error summary:")
        for line in excerpt:
            print(f"    {line}")


def print_quartus_failure_excerpt(output: str) -> None:
    excerpt = [line.strip() for line in output.splitlines() if QUARTUS_ERROR_RE.search(line)]
    if not excerpt:
        print_failure_excerpt(output)
        return
    print("  error summary:")
    for line in excerpt[-8:]:
        print(f"    {line}")


def write_synth_metadata(build_dir: Path, metadata: dict) -> None:
    (build_dir / SYNTH_METADATA).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def begin_synth_metadata(build_dir: Path, target_name: str, target: dict) -> dict:
    metadata = {
        "target": target_name,
        "tool": target["tool"],
        "top": target["top"],
        "started": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "status": "running",
        "stages": [],
    }
    if "seed" in target:
        metadata["seed"] = target["seed"]
    write_synth_metadata(build_dir, metadata)
    return metadata


def finish_synth_metadata(build_dir: Path, metadata: dict, failed: bool) -> None:
    metadata["finished"] = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    metadata["status"] = "failed" if failed else "complete"
    metadata["elapsed_seconds"] = round(sum(stage["elapsed_seconds"] for stage in metadata["stages"]), 2)
    write_synth_metadata(build_dir, metadata)


def restore_outputs(before: dict[Path, bytes | None]) -> None:
    for path, old in before.items():
        if old is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(old)


def clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)
