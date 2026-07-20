"""Lichess evaluation parsing and compact reusable dataset caches."""

from __future__ import annotations

import io
import json
import mmap
import os
import random
import struct
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterator

from .config import cache_key


PIECE_COUNT = 6
SQUARE_COUNT = 64
FEATURE_COUNT = PIECE_COUNT * SQUARE_COUNT
MAX_PIECES = 32
RECORD = struct.Struct("<32hf")
META_NAME = "metadata.json"
DATA_NAME = "records.bin"
_WORKER_FILTERS: dict | None = None
FEN_PIECES = {
    "P": (0, True), "N": (1, True), "B": (2, True),
    "R": (3, True), "Q": (4, True), "K": (5, True),
    "p": (0, False), "n": (1, False), "b": (2, False),
    "r": (3, False), "q": (4, False), "k": (5, False),
}


@dataclass(frozen=True)
class Sample:
    codes: tuple[int, ...]
    target_cp: float


def encode_board(board: object) -> tuple[int, ...]:
    """Encode a board as signed, White-oriented combined-PST feature indices."""
    import chess

    codes: list[int] = []
    for square, piece in sorted(board.piece_map().items()):
        oriented = square if piece.color == chess.WHITE else chess.square_mirror(square)
        index = (piece.piece_type - 1) * 64 + oriented
        codes.append(index + 1 if piece.color == chess.WHITE else -(index + 1))
    if len(codes) > MAX_PIECES:
        raise ValueError("position has more than 32 pieces")
    return tuple(codes + [0] * (MAX_PIECES - len(codes)))


def encode_fen(fen: str) -> tuple[int, ...]:
    """Encode FEN piece placement directly, avoiding chess-board construction."""
    if fen.count(" ") not in (3, 5):
        raise ValueError("FEN must contain four or six fields")
    placement = fen.partition(" ")[0]
    rank_codes: list[list[int]] = [[] for _ in range(8)]
    fen_rank = 0
    file_index = 0
    for symbol in placement:
        if symbol == "/":
            if file_index != 8 or fen_rank >= 7:
                raise ValueError("invalid FEN rank")
            fen_rank += 1
            file_index = 0
            continue
        codepoint = ord(symbol)
        if 49 <= codepoint <= 56:
            file_index += codepoint - 48
            if file_index > 8:
                raise ValueError("invalid FEN empty-square count")
            continue
        piece = FEN_PIECES.get(symbol)
        if piece is None or file_index >= 8:
            raise ValueError("invalid FEN piece placement")
        piece_index, is_white = piece
        if is_white:
            square = file_index + (7 - fen_rank) * 8
            rank_codes[fen_rank].append(piece_index * 64 + square + 1)
        else:
            mirrored_square = file_index + fen_rank * 8
            rank_codes[fen_rank].append(-(piece_index * 64 + mirrored_square + 1))
        file_index += 1
    if fen_rank != 7:
        raise ValueError("FEN piece placement must contain eight ranks")
    codes = [code for rank in reversed(rank_codes) for code in rank]
    if file_index != 8:
        raise ValueError("FEN rank does not contain eight squares")
    if len(codes) > MAX_PIECES:
        raise ValueError("position has more than 32 pieces")
    return tuple(codes) + (0,) * (MAX_PIECES - len(codes))


def select_evaluation(record: dict) -> tuple[dict, dict]:
    """Select the first PV from the first evaluation having maximum depth."""
    evaluations = record["evals"]
    selected = max(evaluations, key=lambda item: item["depth"])
    return selected, selected["pvs"][0]


def parse_record(record: dict, filters: dict) -> tuple[Sample | None, str | None]:
    """Validate and filter one Lichess record, returning a compact sample."""
    try:
        selected, pv = select_evaluation(record)
        if selected["depth"] < filters["minimum_depth"]:
            return None, "minimum_depth"
        is_mate = "mate" in pv
        if is_mate and filters["remove_mates"]:
            return None, "mate"
        if is_mate:
            mate = int(pv["mate"])
            target = float(filters["mate_score_cp"] if mate > 0 else -filters["mate_score_cp"])
        else:
            target = float(pv["cp"])
        limit = filters.get("max_evaluation_cp")
        if limit is not None and abs(target) > limit:
            return None, "evaluation_magnitude"

        import chess

        board = chess.Board(record["fen"])
        if not board.is_valid():
            return None, "invalid_position"
        if board.is_game_over(claim_draw=False):
            return None, "terminal_position"
        moves = str(pv.get("line", "")).split()
        if not moves:
            return None, "missing_pv_move"
        first = board.parse_uci(moves[0])
        if filters["remove_in_check"] and board.is_check():
            return None, "in_check"
        if filters["remove_captures"] and board.is_capture(first):
            return None, "capture"
        if filters["remove_checks"] and board.gives_check(first):
            return None, "check"
        return Sample(encode_fen(record["fen"]), target), None
    except (KeyError, TypeError, ValueError, IndexError):
        return None, "malformed"


def _open_lines(path: Path) -> tuple[BinaryIO, io.TextIOWrapper]:
    raw = path.open("rb")
    if path.suffix == ".zst":
        try:
            import zstandard
        except ImportError as exc:
            raw.close()
            raise RuntimeError("reading .zst datasets requires the zstandard package") from exc
        reader = zstandard.ZstdDecompressor().stream_reader(raw)
        return raw, io.TextIOWrapper(reader, encoding="utf-8")
    return raw, io.TextIOWrapper(raw, encoding="utf-8")


def _packed_sample(sample: Sample) -> bytes:
    return RECORD.pack(*sample.codes, sample.target_cp)


def _write_sample(handle: BinaryIO, sample: Sample | bytes) -> None:
    handle.write(sample if isinstance(sample, bytes) else _packed_sample(sample))


def available_cpus() -> int:
    """Return the CPUs available to this process, respecting affinity where supported."""
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


def resolve_cache_workers(value: int | str) -> int:
    # CPU-bound parsing scales best to physical cores; SMT adds IPC contention.
    return max(1, available_cpus() // 2) if value == "auto" else int(value)


def _init_worker(filters: dict) -> None:
    global _WORKER_FILTERS
    _WORKER_FILTERS = filters


def _parse_line(line: str) -> tuple[bytes | None, str | None]:
    try:
        if _WORKER_FILTERS is None:
            raise RuntimeError("cache parser worker was not initialized")
        sample, reason = parse_record(json.loads(line), _WORKER_FILTERS)
        return (_packed_sample(sample) if sample is not None else None), reason
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None, "malformed"


def build_cache(config: dict, print_fn=print) -> Path:
    """Create or reuse a compact cache with an exact reservoir validation set."""
    dataset = Path(config["dataset"]["path"])
    root = Path(config["output"]["root"]) / "cache"
    key = cache_key(config)
    cache = root / key
    meta_path = cache / META_NAME
    if meta_path.exists() and not config["dataset"].get("rebuild_cache", False):
        return cache
    cache.mkdir(parents=True, exist_ok=True)
    build_log = cache / "build.log"

    def status(message: str) -> None:
        print_fn(message)
        with build_log.open("a", encoding="utf-8") as handle:
            handle.write(message + "\n")

    temporary = cache / (DATA_NAME + ".tmp")
    counts: Counter[str] = Counter()
    reservoir: list[bytes] = []
    rng = random.Random(config["training"]["seed"])
    validation_size = config["training"]["validation_size"]
    max_positions = config["dataset"]["max_positions"]
    workers = resolve_cache_workers(config["dataset"].get("num_workers", "auto"))
    progress_interval = config["dataset"].get("progress_interval_seconds", 5)
    accepted = 0
    train_count = 0
    started = last_progress = time.monotonic()
    status(f"Building dataset cache with {workers} parser worker{'s' if workers != 1 else ''}...")
    raw, lines = _open_lines(dataset)
    try:
        executor_context = (
            nullcontext(None)
            if workers == 1 else ProcessPoolExecutor(
                max_workers=workers,
                initializer=_init_worker,
                initargs=(config["filters"],),
            )
        )
        if workers == 1:
            _init_worker(config["filters"])
        with temporary.open("wb") as output, executor_context as executor:
            finished = False
            while not finished:
                batch = []
                for _ in range(4096):
                    line = lines.readline()
                    if not line:
                        break
                    batch.append(line)
                if not batch:
                    break
                results = map(_parse_line, batch) if executor is None else executor.map(
                    _parse_line, batch, chunksize=64
                )
                for sample, reason in results:
                    counts["read"] += 1
                    if sample is None:
                        counts[reason or "malformed"] += 1
                    else:
                        accepted += 1
                        if len(reservoir) < validation_size:
                            reservoir.append(sample)
                        else:
                            choice = rng.randrange(accepted)
                            if choice < validation_size:
                                _write_sample(output, reservoir[choice])
                                reservoir[choice] = sample
                            else:
                                _write_sample(output, sample)
                            train_count += 1
                    now = time.monotonic()
                    if now - last_progress >= progress_interval:
                        rate = counts["read"] / max(now - started, 1e-9)
                        status(
                            f"Cache: read {counts['read']:,}, accepted {accepted:,}, "
                            f"{rate:,.0f} positions/s."
                        )
                        last_progress = now
                    if max_positions is not None and accepted >= max_positions:
                        finished = True
                        break
            for sample in reservoir:
                _write_sample(output, sample)
    finally:
        lines.close()
        raw.close()
    if accepted <= validation_size:
        temporary.unlink(missing_ok=True)
        raise ValueError(f"only {accepted} positions passed filters; need more than {validation_size}")
    temporary.replace(cache / DATA_NAME)
    metadata = {
        "schema": 1,
        "record_size": RECORD.size,
        "train_count": train_count,
        "validation_count": len(reservoir),
        "counts": dict(sorted(counts.items())),
        "validation_offset": train_count,
    }
    _atomic_json(meta_path, metadata)
    status(f"Cached {train_count:,} training and {len(reservoir):,} validation positions ({key}).")
    return cache


def _atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


class CacheDataset:
    """Memory-mapped map-style dataset over a cache range."""

    def __init__(self, cache: Path, start: int, count: int):
        self.path = cache / DATA_NAME
        self.start = start
        self.count = count
        self._handle: BinaryIO | None = None
        self._map: mmap.mmap | None = None

    def __len__(self) -> int:
        return self.count

    def __getitem__(self, index: int):
        import torch

        if not 0 <= index < self.count:
            raise IndexError(index)
        if self._map is None:
            self._handle = self.path.open("rb")
            self._map = mmap.mmap(self._handle.fileno(), 0, access=mmap.ACCESS_READ)
        values = RECORD.unpack_from(self._map, (self.start + index) * RECORD.size)
        return torch.tensor(values[:MAX_PIECES], dtype=torch.int16), torch.tensor(values[-1], dtype=torch.float32)

    def close(self) -> None:
        if self._map is not None:
            self._map.close()
            self._map = None
        if self._handle is not None:
            self._handle.close()
            self._handle = None

    def __del__(self):
        self.close()


class CacheBatchLoader:
    """Vectorized memory-mapped batches without per-position Python calls."""

    def __init__(
        self,
        dataset: CacheDataset,
        batch_size: int,
        shuffle: bool,
        seed: int,
        shuffle_buffer: int,
    ):
        self.dataset = dataset
        self.batch_size = batch_size
        self.shuffle = shuffle
        self.seed = seed
        self.shuffle_buffer = max(batch_size, shuffle_buffer)
        self.iteration = 0

    def __len__(self) -> int:
        return (len(self.dataset) + self.batch_size - 1) // self.batch_size

    def __iter__(self):
        import numpy
        import torch

        dtype = numpy.dtype([("codes", "<i2", (MAX_PIECES,)), ("target", "<f4")])
        records = numpy.memmap(self.dataset.path, dtype=dtype, mode="r")
        start = self.dataset.start
        stop = start + len(self.dataset)
        rng = numpy.random.default_rng(self.seed + self.iteration)
        self.iteration += 1
        if self.shuffle:
            block_starts = numpy.arange(start, stop, self.shuffle_buffer)
            rng.shuffle(block_starts)
        else:
            block_starts = numpy.arange(start, stop, self.shuffle_buffer)
        for block_start in block_starts:
            block_stop = min(int(block_start) + self.shuffle_buffer, stop)
            indices = numpy.arange(int(block_start), block_stop)
            if self.shuffle:
                rng.shuffle(indices)
            for offset in range(0, len(indices), self.batch_size):
                batch = records[indices[offset:offset + self.batch_size]]
                codes = torch.from_numpy(numpy.array(batch["codes"], copy=True))
                target = torch.from_numpy(numpy.array(batch["target"], copy=True))
                yield codes, target


class BufferedShuffleSampler:
    """Shuffle a large cache with bounded memory and deterministic seeds."""

    def __init__(self, count: int, buffer_size: int, seed: int):
        self.count = count
        self.buffer_size = min(count, buffer_size)
        self.seed = seed
        self.iteration = 0

    def __len__(self) -> int:
        return self.count

    def __iter__(self) -> Iterator[int]:
        rng = random.Random(self.seed + self.iteration)
        self.iteration += 1
        buffer = list(range(self.buffer_size))
        next_index = self.buffer_size
        while next_index < self.count:
            slot = rng.randrange(len(buffer))
            yield buffer[slot]
            buffer[slot] = next_index
            next_index += 1
        rng.shuffle(buffer)
        yield from buffer


def cache_datasets(cache: Path) -> tuple[CacheDataset, CacheDataset, dict]:
    metadata = json.loads((cache / META_NAME).read_text(encoding="utf-8"))
    train = CacheDataset(cache, 0, metadata["train_count"])
    validation = CacheDataset(cache, metadata["validation_offset"], metadata["validation_count"])
    return train, validation, metadata
