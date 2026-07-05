"""Command-line helper for encoding FEN as a FullBoard payload."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from software.protocol import ProtocolError, encode_fen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Encode a FEN position as the FPGA FullBoard payload.")
    parser.add_argument("fen", nargs="?", help="FEN to encode. If omitted, stdin is read.")
    args = parser.parse_args(argv)

    fen = args.fen if args.fen is not None else input("Enter FEN to convert: ")
    try:
        print(encode_fen(fen).hex())
    except ProtocolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
