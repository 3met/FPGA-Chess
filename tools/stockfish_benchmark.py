"""Run a paired-opening FPGA versus full-strength Stockfish tournament."""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TextIO


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BOOK = REPO_ROOT.parent / "fastchess" / "books" / "UHO_Lichess_4852_v1.epd"
BOOK_URL = "https://github.com/official-stockfish/books/raw/master/UHO_Lichess_4852_v1.epd.zip"
DEFAULT_RESULTS_ROOT = REPO_ROOT / "work" / "benchmark-results"
DEFAULT_STOCKFISH_NODES = 2000
ERROR_CHECK_MATCHES = 10
MAX_ADAPTIVE_MATCHES = 500000
INTERRUPT_GRACE_SECONDS = 15
RUN_MARKER = "run.json"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ELO_RE = re.compile(r"^Elo:\s+([-+]?\d+(?:\.\d+)?|[-+]?inf|nan)\s+\+/-\s+([-+]?\d+(?:\.\d+)?|inf|nan)", re.I)
GAMES_RE = re.compile(r"^Games:\s+(\d+), Wins:\s+(\d+), Losses:\s+(\d+), Draws:\s+(\d+), Points:\s+([\d.]+)")
PENTA_RE = re.compile(r"^Ptnml\(0-2\):\s+\[([\d, ]+)\]")
SPRT_RE = re.compile(r"SPRT \([^\n]+\) completed - (H[01]) was accepted")


class BenchmarkError(RuntimeError):
    """Report a failed or invalid benchmark run."""


@dataclass(frozen=True)
class BenchmarkConfig:
    """Inputs for a new tournament; each match is two games with reversed colors."""

    name: str | None = None
    matches: int | None = None
    target_elo_error: float | None = None
    max_matches: int = MAX_ADAPTIVE_MATCHES
    results_root: Path = DEFAULT_RESULTS_ROOT
    book: Path = DEFAULT_BOOK
    fastchess: str = "fastchess"
    stockfish: str = "stockfish"
    fpga_time_control: str = "2+0.02"
    stockfish_nodes: int = DEFAULT_STOCKFISH_NODES
    stockfish_threads: int = 1
    stockfish_hash_mb: int = 32
    opening_start: int = 1
    sprt_elo0: float | None = None
    sprt_elo1: float | None = None
    sprt_alpha: float = 0.10
    sprt_beta: float = 0.02
    force: bool = False


@dataclass(frozen=True)
class TournamentResult:
    """Final Fastchess standings from the FPGA player's perspective."""

    name: str
    run_dir: Path
    games: int
    wins: int
    losses: int
    draws: int
    points: float
    elo: float
    elo_error: float
    pentanomial: tuple[int, int, int, int, int] | None
    sprt_decision: str | None = None


def _executable(command: str) -> str:
    """Resolve an executable from PATH or an explicit filesystem path."""
    found = shutil.which(command)
    if found is None:
        raise BenchmarkError(f"executable not found: {command}")
    return str(Path(found).resolve())


def _book_path(book: Path) -> Path:
    """Use the existing opening suite or fetch the official archive once."""
    book = Path(book)
    if book.is_file():
        return book.resolve()
    if book != DEFAULT_BOOK:
        raise BenchmarkError(f"opening book not found: {book}")
    destination = REPO_ROOT / "work" / "books" / DEFAULT_BOOK.name
    if destination.is_file():
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    archive = destination.with_suffix(destination.suffix + ".zip")
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    try:
        with urllib.request.urlopen(BOOK_URL, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        with zipfile.ZipFile(archive) as zipped, zipped.open(DEFAULT_BOOK.name) as source, \
                temporary.open("wb") as output:
            shutil.copyfileobj(source, output)
        temporary.replace(destination)
    except (OSError, zipfile.BadZipFile, KeyError) as exc:
        raise BenchmarkError(f"could not download opening book: {exc}; pass --book") from exc
    finally:
        archive.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)
    return destination


def _validate(config: BenchmarkConfig) -> str:
    """Check inputs before touching an existing result directory."""
    name = config.name or datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    if not NAME_RE.fullmatch(name):
        raise BenchmarkError("run name may contain only letters, digits, dots, underscores, and hyphens")
    if config.matches is not None and config.target_elo_error is not None:
        raise BenchmarkError("specify either matches or target Elo error")
    if config.target_elo_error is not None and (not math.isfinite(config.target_elo_error) or config.target_elo_error <= 0):
        raise BenchmarkError("target Elo error must be a finite positive number")
    if config.target_elo_error is None and config.max_matches != MAX_ADAPTIVE_MATCHES:
        raise BenchmarkError("max matches requires a target Elo error")
    for label, value in (("matches", config.matches if config.matches is not None else 500),
                         ("maximum matches", config.max_matches), ("Stockfish nodes", config.stockfish_nodes),
                         ("Stockfish threads", config.stockfish_threads), ("Stockfish hash", config.stockfish_hash_mb),
                         ("opening start", config.opening_start)):
        if value < 1:
            raise BenchmarkError(f"{label} must be positive")
    _book_path(config.book)
    if not (REPO_ROOT / "software" / "engine").is_dir():
        raise BenchmarkError(f"FPGA UCI engine package not found: {REPO_ROOT / 'software' / 'engine'}")
    if (config.sprt_elo0 is None) != (config.sprt_elo1 is None):
        raise BenchmarkError("both SPRT Elo bounds must be specified together")
    if config.sprt_elo0 is not None:
        if config.target_elo_error is not None:
            raise BenchmarkError("SPRT and target Elo error cannot be combined")
        if not all(math.isfinite(value) for value in
                   (config.sprt_elo0, config.sprt_elo1, config.sprt_alpha, config.sprt_beta)):
            raise BenchmarkError("SPRT settings must be finite")
        if not (config.sprt_elo0 < config.sprt_elo1 and 0 < config.sprt_alpha < 1 and
                0 < config.sprt_beta < 1 and config.sprt_alpha + config.sprt_beta < 1):
            raise BenchmarkError("SPRT requires Elo0 < Elo1 and alpha + beta < 1")
    _executable(config.fastchess)
    _executable(config.stockfish)
    return name


def _fresh_command(config: BenchmarkConfig, run_dir: Path, name: str, rounds: int | None = None) -> list[str]:
    """Build the complete Fastchess invocation without shell dependencies."""
    sprt = []
    if config.sprt_elo0 is not None:
        sprt = ["-sprt", f"elo0={config.sprt_elo0}", f"elo1={config.sprt_elo1}",
                f"alpha={config.sprt_alpha}", f"beta={config.sprt_beta}", "model=logistic"]
    return [
        _executable(config.fastchess),
        "-engine", f"name=FPGA-{name}", f"cmd={sys.executable}",
        "args=-m software.engine", f"dir={REPO_ROOT}", f"tc={config.fpga_time_control}",
        "timemargin=1000",
        "-engine", "name=Stockfish-unlimited", f"cmd={_executable(config.stockfish)}",
        f"nodes={config.stockfish_nodes}", "option.UCI_LimitStrength=false",
        f"option.Threads={config.stockfish_threads}", f"option.Hash={config.stockfish_hash_mb}",
        "option.Ponder=false",
        "-openings", f"file={_book_path(config.book)}", "format=epd", "order=sequential",
        f"start={config.opening_start}", *sprt,
        "-rounds", str(rounds if rounds is not None else (config.matches or 500)),
        "-repeat", "-concurrency", "1", "-recover",
        "-report", "penta=true", "-ratinginterval", "10", "-autosaveinterval", "10",
        "-config", f"outname={run_dir / 'state.json'}", "-event", f"FPGA benchmark {name}",
        "-pgnout", f"file={run_dir / 'games.pgn'}", "append=false",
        "-log", f"file={run_dir / 'fastchess.log'}", "level=info", "append=false", "engine=false",
    ]


def _resume_command(fastchess: str, run_dir: Path) -> list[str]:
    """Resume the exact configuration held in a Fastchess autosave."""
    return [
        _executable(fastchess), "-config", f"file={run_dir / 'state.json'}",
        f"outname={run_dir / 'state.json'}", "-log", f"file={run_dir / 'fastchess.log'}",
        "level=info", "append=true", "engine=false",
    ]


def _elapsed(seconds: float) -> str:
    """Format wall time for the live standings header."""
    hours, remainder = divmod(int(seconds), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


class _WindowsJob:
    """Keep Fastchess and all descendant engines in one kill-on-close job."""

    def __init__(self, process: subprocess.Popen[str]):
        import ctypes
        from ctypes import wintypes

        class BasicLimits(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("limit_flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
                        ("max_working_set", ctypes.c_size_t), ("active_process_limit", wintypes.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority_class", wintypes.DWORD),
                        ("scheduling_class", wintypes.DWORD)]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in (
                "read_operations", "write_operations", "other_operations", "read_bytes", "write_bytes", "other_bytes")]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [("basic", BasicLimits), ("io", IoCounters),
                        ("process_memory_limit", ctypes.c_size_t), ("job_memory_limit", ctypes.c_size_t),
                        ("peak_process_memory_used", ctypes.c_size_t), ("peak_job_memory_used", ctypes.c_size_t)]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel.SetInformationJobObject.restype = wintypes.BOOL
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        self._kernel = kernel
        self._handle = kernel.CreateJobObjectW(None, None)
        if not self._handle:
            raise OSError(ctypes.get_last_error(), "could not create a Windows process job")
        limits = ExtendedLimits()
        limits.basic.limit_flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(self._handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)) or \
                not kernel.AssignProcessToJobObject(self._handle, wintypes.HANDLE(process._handle)):
            error = ctypes.get_last_error()
            self.close()
            raise OSError(error, "could not contain Fastchess in a Windows process job")

    def close(self) -> None:
        """Kill any remaining engine descendants and release the job handle."""
        if self._handle:
            self._kernel.CloseHandle(self._handle)
            self._handle = None


def _force_stop_tree(process: subprocess.Popen[str], job: _WindowsJob | None) -> None:
    """Stop leftover Fastchess and UCI engine processes as one group."""
    if os.name == "nt":
        if job is not None:
            job.close()
        elif process.poll() is None:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


@contextlib.contextmanager
def _ignore_further_ctrl_c():
    """Keep a second Ctrl+C from interrupting child-process cleanup."""
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN) if threading.current_thread() is threading.main_thread() else None
    try:
        yield
    finally:
        if previous is not None:
            signal.signal(signal.SIGINT, previous)


def _interrupt_process(process: subprocess.Popen[str], job: _WindowsJob | None) -> str:
    """Ask Fastchess to save its state, then force cleanup if it stalls."""
    with _ignore_further_ctrl_c():
        if process.poll() is None:
            try:
                if os.name == "nt":
                    process.send_signal(signal.CTRL_BREAK_EVENT)
                else:
                    os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
        try:
            tail, _ = process.communicate(timeout=INTERRUPT_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            _force_stop_tree(process, job)
            tail, _ = process.communicate()
        return tail or ""


def _run_process(command: list[str], run_dir: Path, *, resume: bool, output: TextIO) -> None:
    """Save raw output and a compact live summary while Fastchess runs."""
    mode = "a" if resume else "w"
    started = time.monotonic()
    standings = False
    with (run_dir / "raw-output.txt").open(mode, encoding="utf-8", newline="\n") as raw, \
            (run_dir / "summary.txt").open(mode, encoding="utf-8", newline="\n") as summary:
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, encoding="utf-8", errors="replace", bufsize=1,
                                       **({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
                                          else {"start_new_session": True}))
        except OSError as exc:
            raise BenchmarkError(f"could not start Fastchess: {exc}") from exc
        job = None
        if os.name == "nt":
            try:
                job = _WindowsJob(process)
            except OSError as exc:
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                process.wait()
                raise BenchmarkError(str(exc)) from exc
        assert process.stdout is not None

        def record(line: str) -> None:
            """Append one Fastchess line to the raw log and visible summary."""
            nonlocal standings
            raw.write(line)
            raw.flush()
            stripped = line.rstrip("\r\n")
            visible = False
            if stripped == "--------------------------------------------------":
                if not standings:
                    header = f"\n[elapsed {_elapsed(time.monotonic() - started)}]\n"
                    summary.write(header)
                    output.write(header)
                standings = not standings
                visible = True
            elif standings or stripped.startswith(("Warning;", "Error;", "Fatal;", "Tournament finished", "Tournament was interrupted")):
                visible = True
            elif stripped.startswith("Finished game ") and any(word in stripped for word in ("loses on time", "illegal move", "crash")):
                visible = True
            if visible:
                summary.write(line)
                summary.flush()
                output.write(line)
                output.flush()

        try:
            for line in process.stdout:
                record(line)
            return_code = process.wait()
        except KeyboardInterrupt:
            for line in _interrupt_process(process, job).splitlines(keepends=True):
                record(line)
            status = f"Interrupted. Resume with: python -m tools.stockfish_benchmark --resume {run_dir}\n" \
                if (run_dir / "state.json").is_file() else "Interrupted before a tournament autosave was created.\n"
            output.write(status)
            output.flush()
            raise
        finally:
            with _ignore_further_ctrl_c():
                _force_stop_tree(process, job)
                process.stdout.close()
                process.wait()
        if return_code != 0:
            raise BenchmarkError(f"Fastchess failed; see {run_dir / 'raw-output.txt'}")


def read_result(run_dir: Path, *, expected_games: int | None = None) -> TournamentResult:
    """Parse the last complete standings block from a saved tournament."""
    run_dir = Path(run_dir).resolve()
    metadata = json.loads((run_dir / RUN_MARKER).read_text(encoding="utf-8"))
    elo = None
    games = None
    penta = None
    for line in (run_dir / "summary.txt").read_text(encoding="utf-8", errors="replace").splitlines():
        if match := ELO_RE.match(line):
            elo = (float(match[1]), float(match[2]))
        if match := GAMES_RE.match(line):
            games = (int(match[1]), int(match[2]), int(match[3]), int(match[4]), float(match[5]))
        if match := PENTA_RE.match(line):
            counts = tuple(int(value.strip()) for value in match[1].split(","))
            if len(counts) == 5:
                penta = counts
    if elo is None or games is None:
        raise BenchmarkError(f"no tournament standings found in {run_dir / 'summary.txt'}")
    decisions = SPRT_RE.findall((run_dir / "raw-output.txt").read_text(encoding="utf-8", errors="replace")) \
        if (run_dir / "raw-output.txt").is_file() else []
    decision = decisions[-1] if decisions else None
    if decision and expected_games is not None and games[0] < expected_games:
        state_path = run_dir / "state.json"
        if state_path.is_file():
            state = json.loads(state_path.read_text(encoding="utf-8"))
            if not state.get("sprt", {}).get("enabled", False):
                decision = None
    if expected_games is not None and games[0] != expected_games and not (0 < games[0] < expected_games and decision):
        raise BenchmarkError(f"tournament has {games[0]} games; expected {expected_games}; resume {run_dir}")
    return TournamentResult(metadata["name"], run_dir, *games, *elo, penta, decision)


def _extend_rounds(run_dir: Path, new_rounds: int) -> None:
    """Extend the completed Fastchess autosave without changing prior games."""
    state_path = run_dir / "state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if new_rounds <= state["rounds"]:
        raise BenchmarkError("new match limit must exceed the saved limit")
    state["rounds"] = new_rounds
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=4) + "\n", encoding="utf-8")
    temporary.replace(state_path)


def _run_to_error_target(
    run_dir: Path, metadata: dict, *, fastchess: str, output: TextIO, fresh_command: list[str] | None = None
) -> TournamentResult:
    """Continue paired batches until Fastchess's reported Elo error meets the target."""
    target = metadata["target_elo_error"]
    cap = metadata["max_matches"]
    command = fresh_command
    while True:
        state_path = run_dir / "state.json"
        if command is None:
            if not state_path.is_file():
                raise BenchmarkError(f"saved tournament state not found: {state_path}")
            rounds = json.loads(state_path.read_text(encoding="utf-8"))["rounds"]
            try:
                current = read_result(run_dir)
            except (BenchmarkError, FileNotFoundError):
                current = None
            if current is not None and current.games == 2 * rounds:
                if math.isfinite(current.elo_error) and current.elo_error <= target:
                    return current
                if rounds >= cap:
                    raise BenchmarkError(f"Elo error target {target} was not reached after {rounds} matches")
                rounds = min(rounds + ERROR_CHECK_MATCHES, cap)
                _extend_rounds(run_dir, rounds)
            command = _resume_command(fastchess, run_dir)
        else:
            rounds = int(command[command.index("-rounds") + 1])
        _run_process(command, run_dir, resume=fresh_command is None or command is not fresh_command, output=output)
        current = read_result(run_dir, expected_games=2 * rounds)
        if math.isfinite(current.elo_error) and current.elo_error <= target:
            return current
        if rounds >= cap:
            raise BenchmarkError(f"Elo error target {target} was not reached after {rounds} matches")
        command = None


def run_tournament(config: BenchmarkConfig, *, output: TextIO | None = None) -> TournamentResult:
    """Run a new tournament and return its final structured standings."""
    name = _validate(config)
    run_dir = (Path(config.results_root) / name).resolve()
    if run_dir.exists():
        if not config.force:
            raise BenchmarkError(f"run already exists: {run_dir}; pass --continue to resume or --force to replace it")
        if not (run_dir / RUN_MARKER).is_file():
            raise BenchmarkError(f"refusing to replace a directory without {RUN_MARKER}: {run_dir}")
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True)
    rounds = min(ERROR_CHECK_MATCHES, config.max_matches) if config.target_elo_error is not None \
        else (config.matches if config.matches is not None else 500)
    metadata = {"name": name, "matches": config.matches, "target_elo_error": config.target_elo_error,
                "max_matches": config.max_matches,
                "command": _fresh_command(config, run_dir, name, rounds)}
    (run_dir / RUN_MARKER).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    stream = output if output is not None else sys.stdout
    print(f"Results: {run_dir}", file=stream, flush=True)
    if config.target_elo_error is not None:
        return _run_to_error_target(run_dir, metadata, fastchess=config.fastchess, output=stream,
                                    fresh_command=metadata["command"])
    _run_process(metadata["command"], run_dir, resume=False, output=stream)
    return read_result(run_dir, expected_games=2 * rounds)


def resume_tournament(run_dir: Path, *, fastchess: str = "fastchess", output: TextIO | None = None) -> TournamentResult:
    """Resume an interrupted run and return its final standings."""
    run_dir = Path(run_dir).resolve()
    if not (run_dir / RUN_MARKER).is_file() or not (run_dir / "state.json").is_file():
        raise BenchmarkError(f"saved tournament state not found: {run_dir}")
    metadata = json.loads((run_dir / RUN_MARKER).read_text(encoding="utf-8"))
    stream = output if output is not None else sys.stdout
    print(f"Resuming: {run_dir}", file=stream, flush=True)
    if metadata.get("target_elo_error") is not None:
        return _run_to_error_target(run_dir, metadata, fastchess=fastchess, output=stream)
    try:
        return read_result(run_dir, expected_games=2 * (metadata["matches"] or 500))
    except (BenchmarkError, FileNotFoundError):
        pass
    _run_process(_resume_command(fastchess, run_dir), run_dir, resume=True, output=stream)
    return read_result(run_dir, expected_games=2 * (metadata["matches"] or 500))


def continue_tournament(
    name: str, *, results_root: Path = DEFAULT_RESULTS_ROOT, fastchess: str = "fastchess",
    output: TextIO | None = None,
) -> TournamentResult:
    """Resume a named run from its saved Fastchess state."""
    if not NAME_RE.fullmatch(name):
        raise BenchmarkError("run name may contain only letters, digits, dots, underscores, and hyphens")
    run_dir = (Path(results_root) / name).resolve()
    return resume_tournament(run_dir, fastchess=fastchess, output=output)


def main(argv: list[str] | None = None) -> int:
    """Provide the command-line interface to the reusable tournament runner."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", nargs="?", help="run name (default: local timestamp)")
    parser.add_argument("matches", nargs="?", type=int, help="paired openings (default: 500)")
    parser.add_argument("--matches", dest="match_option", type=int, help="paired openings when omitting a run name")
    parser.add_argument("--elo-error", type=float, metavar="ELO",
                        help="stop when Fastchess reports Elo +/- ELO or less")
    parser.add_argument("--max-matches", type=int, default=MAX_ADAPTIVE_MATCHES,
                        help="safety cap for an Elo-error run")
    parser.add_argument("--resume", type=Path, metavar="RUN_DIR")
    parser.add_argument("--continue", dest="continue_run", action="store_true",
                        help="resume the named run from --results-root")
    parser.add_argument("--force", action="store_true", help="replace an existing run created by this tool")
    parser.add_argument("--results-root", type=Path, default=DEFAULT_RESULTS_ROOT)
    parser.add_argument("--book", type=Path, default=DEFAULT_BOOK)
    parser.add_argument("--fastchess", default="fastchess")
    parser.add_argument("--stockfish", default="stockfish")
    parser.add_argument("--fpga-tc", default="2+0.02")
    parser.add_argument("--stockfish-nodes", type=int, default=DEFAULT_STOCKFISH_NODES)
    parser.add_argument("--stockfish-threads", type=int, default=1)
    parser.add_argument("--stockfish-hash", type=int, default=32, metavar="MB")
    parser.add_argument("--opening-start", type=int, default=1)
    parser.add_argument("--sprt-elo0", type=float)
    parser.add_argument("--sprt-elo1", type=float)
    parser.add_argument("--sprt-alpha", type=float, default=0.10)
    parser.add_argument("--sprt-beta", type=float, default=0.02)
    args = parser.parse_args(argv)
    if args.matches is not None and args.match_option is not None:
        parser.error("specify matches once, either as a positional argument or with --matches")
    if args.elo_error is not None and (args.matches is not None or args.match_option is not None):
        parser.error("--elo-error cannot be combined with a match count")
    matches = args.match_option if args.match_option is not None else args.matches
    if args.continue_run:
        if args.resume or args.name is None or matches is not None or args.elo_error is not None or args.force:
            parser.error("--continue requires a run name and cannot be combined with --resume, matches, --elo-error, or --force")
    try:
        if args.resume:
            if args.name is not None or args.matches is not None or args.match_option is not None or \
                    args.elo_error is not None or args.force:
                parser.error("--resume cannot be combined with a new run name, match count, Elo error, or --force")
            result = resume_tournament(args.resume, fastchess=args.fastchess)
        elif args.continue_run:
            result = continue_tournament(args.name, results_root=args.results_root, fastchess=args.fastchess)
        else:
            result = run_tournament(BenchmarkConfig(
                name=args.name, matches=matches, target_elo_error=args.elo_error,
                max_matches=args.max_matches, results_root=args.results_root, book=args.book,
                fastchess=args.fastchess, stockfish=args.stockfish, fpga_time_control=args.fpga_tc,
                stockfish_nodes=args.stockfish_nodes, stockfish_threads=args.stockfish_threads,
                stockfish_hash_mb=args.stockfish_hash, opening_start=args.opening_start,
                sprt_elo0=args.sprt_elo0, sprt_elo1=args.sprt_elo1,
                sprt_alpha=args.sprt_alpha, sprt_beta=args.sprt_beta, force=args.force,
            ))
    except (BenchmarkError, OSError, ValueError) as exc:
        parser.exit(1, f"error: {exc}\n")
    except KeyboardInterrupt:
        parser.exit(130)
    print(f"Complete: {result.games} games, FPGA {result.wins}-{result.losses}-{result.draws}, "
          f"Elo {result.elo:+.2f} +/- {result.elo_error:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
