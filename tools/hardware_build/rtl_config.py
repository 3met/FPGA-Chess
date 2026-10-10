"""Generate shared RTL type capacities from an explicitly selected configuration."""

import json
from pathlib import Path

from .common import BuildError, repo_path
from .engine_config import _integer, _require_keys, engine_config_for_target


def load_type_config(path: str) -> dict[str, int]:
    """Load capacities for standalone module compilation and verification."""
    if not isinstance(path, str) or not path:
        raise BuildError("RTL type_config must be a nonempty path")
    try:
        config = json.loads(repo_path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildError(f"Could not load RTL type configuration {path}: {exc}") from exc
    if not isinstance(config, dict):
        raise BuildError(f"RTL type configuration {path} must contain a JSON object")
    _require_keys(config, {"threads", "stack_depth"}, path)
    return {name: _integer(config, name, path, 1) for name in ("threads", "stack_depth")}


def type_config_for_target(target: dict) -> dict:
    """Use an engine profile when present; otherwise require explicit type capacities."""
    if "engine_config" in target and "type_config" in target:
        raise BuildError("Select either engine_config or type_config, not both")
    config = engine_config_for_target(target)
    if config is not None:
        return config
    if "type_config" not in target:
        raise BuildError("RTL compilation requires an engine_config or type_config")
    return load_type_config(target["type_config"])


def rtl_config_source(config: dict) -> str:
    """Render primitive inputs only; identifier and address widths remain derived in RTL."""
    capacities = {name: _integer(config, name, "RTL configuration", 1)
                  for name in ("threads", "stack_depth")}
    return (
        "// Generated from the selected configuration; do not edit.\n"
        "package rtl_config;\n"
        f"    localparam int THREAD_CAPACITY = {capacities['threads']};\n"
        f"    localparam int SEARCH_STACK_CAPACITY = {capacities['stack_depth']};\n"
        "endpackage : rtl_config\n"
    )


def write_rtl_config(build_dir: Path, config: dict) -> Path:
    """Write each build's package locally so concurrent configurations remain isolated."""
    build_dir.mkdir(parents=True, exist_ok=True)
    path = build_dir / "rtl_config.sv"
    source = rtl_config_source(config)
    if not path.exists() or path.read_text(encoding="utf-8") != source:
        path.write_text(source, encoding="utf-8")
    return path
