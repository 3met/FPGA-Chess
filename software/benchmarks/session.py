"""Subprocess session for the repository's FPGA UCI host."""

from __future__ import annotations

import queue
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable
import sys


class FPGAUCIError(RuntimeError):
    """Raised when an engine violates the requested UCI interaction."""


@dataclass
class UCIResult:
    """Lines observed while waiting for one engine operation."""

    lines: list[str]
    elapsed_seconds: float


class FPGAUCISession:
    """Run this repository's FPGA UCI host and wait for protocol responses."""

    def __init__(self, *, verbose: bool = False) -> None:
        self.command = [sys.executable, "-m", "software.engine"]
        self.verbose = verbose
        self.process: subprocess.Popen[str] | None = None
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._recent: deque[str] = deque(maxlen=40)
        self._reader: threading.Thread | None = None

    def __enter__(self) -> "FPGAUCISession":
        self.process = subprocess.Popen(
            self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _read_stdout(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for raw in self.process.stdout:
            line = raw.rstrip("\r\n")
            self._recent.append(line)
            if self.verbose:
                print(f"< {line}")
            self._lines.put(line)
        self._lines.put(None)

    def send(self, line: str) -> None:
        if self.process is None or self.process.stdin is None or self.process.poll() is not None:
            raise FPGAUCIError(f"engine is not running; recent output: {self._recent_output()}")
        if self.verbose:
            print(f"> {line}")
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def wait_for(self, predicate: Callable[[str], bool], timeout: float, description: str) -> UCIResult:
        """Return all lines through the first line matching *predicate*."""
        started = time.monotonic()
        lines: list[str] = []
        while True:
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise FPGAUCIError(f"timed out waiting for {description}; recent output: {self._recent_output()}")
            try:
                line = self._lines.get(timeout=remaining)
            except queue.Empty as exc:
                raise FPGAUCIError(f"timed out waiting for {description}; recent output: {self._recent_output()}") from exc
            if line is None:
                raise FPGAUCIError(f"engine exited while waiting for {description}; recent output: {self._recent_output()}")
            lines.append(line)
            if predicate(line):
                return UCIResult(lines, time.monotonic() - started)

    def initialize(self, timeout: float) -> None:
        self.send("uci")
        self.wait_for(lambda line: line == "uciok", timeout, "uciok")
        self.ready(timeout)

    def ready(self, timeout: float) -> None:
        self.send("isready")
        self.wait_for(lambda line: line == "readyok", timeout, "readyok")

    def close(self) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=1.0)
            except (OSError, subprocess.TimeoutExpired, FPGAUCIError):
                self.process.terminate()
                try:
                    self.process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()
        self.process = None

    def _recent_output(self) -> str:
        return " | ".join(self._recent) or "(none)"
