"""Small cross-platform filesystem helpers."""

from __future__ import annotations

import json
import os
from pathlib import Path


def atomic_write_text(path: Path, contents: str) -> None:
    """Replace a text file only after its complete contents are on disk."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(contents, encoding="utf-8")
    os.replace(temporary, path)


def atomic_write_json(path: Path, value: object) -> None:
    """Write stable, human-readable JSON through an atomic replacement."""
    atomic_write_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")
