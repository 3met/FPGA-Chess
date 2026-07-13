"""Build-manifest loading, validation, and source-set expansion."""

import argparse
import json
import re
from pathlib import Path

from .common import BuildError, MANIFEST_PATH, REPO_ROOT, rel, repo_path


def load_manifest() -> dict:
    try:
        with MANIFEST_PATH.open(encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildError(f"Could not load {rel(MANIFEST_PATH)}: {exc}") from exc
    validate_manifest(manifest)
    return manifest


def repo_path(value: str) -> Path:
    return (REPO_ROOT / value).resolve()


def manifest_object(manifest: dict, key: str) -> dict:
    value = manifest.get(key)
    if not isinstance(value, dict):
        raise BuildError(f"Manifest field '{key}' must be an object")
    return value


def require_fields(item: dict, context: str, fields: set[str]) -> None:
    missing = sorted(fields - item.keys())
    if missing:
        raise BuildError(f"{context} is missing field(s): {', '.join(missing)}")


def validate_manifest(manifest: object) -> None:
    if not isinstance(manifest, dict):
        raise BuildError("Manifest root must be an object")
    if manifest.get("schema_version") != 1:
        raise BuildError("Manifest schema_version must be 1")

    source_sets = manifest_object(manifest, "source_sets")
    tests = manifest_object(manifest, "tests")
    generated_data = manifest_object(manifest, "generated_data")
    targets = manifest_object(manifest, "synthesis_targets")
    programming_targets = manifest_object(manifest, "programming_targets")
    simulator = manifest_object(manifest, "simulator")
    modelsim = simulator.get("modelsim")
    if not isinstance(modelsim, dict):
        raise BuildError("Manifest field 'simulator.modelsim' must be an object")

    for name, items in source_sets.items():
        if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
            raise BuildError(f"Source set '{name}' must be a list of paths or @references")
        expand_source_set(manifest, name)

    for name, test in tests.items():
        if not isinstance(test, dict):
            raise BuildError(f"Test '{name}' must be an object")
        require_fields(test, f"Test '{name}'", {"source_set", "testbench", "top"})
        if test["source_set"] not in source_sets:
            raise BuildError(f"Test '{name}' uses unknown source set '{test['source_set']}'")
        ensure_existing([repo_path(test["testbench"])])

    for name, item in generated_data.items():
        if not isinstance(item, dict):
            raise BuildError(f"Generated data '{name}' must be an object")
        require_fields(item, f"Generated data '{name}'", {"script", "outputs"})
        if not isinstance(item["outputs"], list) or not item["outputs"]:
            raise BuildError(f"Generated data '{name}' outputs must be a non-empty list")
        ensure_existing([repo_path(item["script"])])

    for name, target in targets.items():
        if not isinstance(target, dict):
            raise BuildError(f"Synthesis target '{name}' must be an object")
        require_fields(target, f"Synthesis target '{name}'", {"tool", "top", "source_set"})
        if target["source_set"] not in source_sets:
            raise BuildError(f"Synthesis target '{name}' uses unknown source set '{target['source_set']}'")
        tool_fields = {
            "quartus": {"family", "device", "sdc", "qsf_template"},
            "vivado": {"clock_port", "clock_period_ns"},
        }
        if target["tool"] not in tool_fields:
            raise BuildError(f"Synthesis target '{name}' uses unsupported tool '{target['tool']}'")
        require_fields(target, f"Synthesis target '{name}'", tool_fields[target["tool"]])
        if "seed" in target and (not isinstance(target["seed"], int) or target["seed"] < 1):
            raise BuildError(f"Synthesis target '{name}' seed must be a positive integer")
        if target["tool"] == "quartus":
            message_disable = target.get("message_disable", [])
            if not isinstance(message_disable, list) or not all(
                isinstance(message_id, int) and message_id > 0 for message_id in message_disable
            ):
                raise BuildError(f"Synthesis target '{name}' message_disable must contain positive integers")
            ensure_existing(
                [
                    repo_path(target["sdc"]),
                    repo_path(target["qsf_template"]),
                    *[repo_path(path) for path in target.get("qip_files", [])],
                ]
            )

    for name, target in programming_targets.items():
        if not isinstance(target, dict):
            raise BuildError(f"Programming target '{name}' must be an object")
        require_fields(target, f"Programming target '{name}'", {"tool", "synthesis_target", "artifact", "mode", "jtag_id"})
        if target["synthesis_target"] not in targets:
            raise BuildError(
                f"Programming target '{name}' uses unknown synthesis target '{target['synthesis_target']}'"
            )
        if target["tool"] != "quartus":
            raise BuildError(f"Programming target '{name}' uses unsupported tool '{target['tool']}'")
        if target["mode"] != "jtag":
            raise BuildError(f"Programming target '{name}' uses unsupported Quartus mode '{target['mode']}'")
        if not isinstance(target["jtag_id"], str) or not re.fullmatch(r"[0-9A-Fa-f]{8}", target["jtag_id"]):
            raise BuildError(f"Programming target '{name}' jtag_id must be an 8-digit hexadecimal ID code")
        if not isinstance(target["artifact"], str) or not target["artifact"]:
            raise BuildError(f"Programming target '{name}' artifact must be a non-empty path")


def ensure_existing(paths: list[Path]) -> None:
    missing = [rel(path) for path in paths if not path.exists()]
    if missing:
        raise BuildError("Missing required file(s): " + ", ".join(missing))


def expand_source_set(manifest: dict, name: str) -> list[Path]:
    source_sets = manifest["source_sets"]
    if name not in source_sets:
        raise BuildError(f"Unknown source set '{name}'")

    expanded: list[Path] = []
    seen: set[Path] = set()
    active: list[str] = []

    def visit(set_name: str) -> None:
        if set_name in active:
            chain = " -> ".join(active + [set_name])
            raise BuildError(f"Recursive source-set reference: {chain}")
        if set_name not in source_sets:
            raise BuildError(f"Unknown source set '{set_name}'")

        active.append(set_name)
        for item in source_sets[set_name]:
            if item.startswith("@"):
                visit(item[1:])
            else:
                path = repo_path(item)
                if path not in seen:
                    expanded.append(path)
                    seen.add(path)
        active.pop()

    visit(name)
    ensure_existing(expanded)
    return expanded


def print_list(manifest: dict) -> None:
    print("Source sets:")
    for name in sorted(manifest["source_sets"]):
        sources = expand_source_set(manifest, name)
        print(f"  {name}: {len(sources)} files")

    print("\nTests:")
    for name, test in sorted(manifest["tests"].items()):
        print(f"  {name}: top={test['top']} source_set={test['source_set']}")

    print("\nSynthesis targets:")
    for name, target in sorted(manifest["synthesis_targets"].items()):
        print(f"  {name}: tool={target['tool']} top={target['top']}")

    print("\nProgramming targets:")
    for name, target in sorted(manifest["programming_targets"].items()):
        print(f"  {name}: tool={target['tool']} artifact={target['artifact']}")

    print("\nGenerated data:")
    for name, item in sorted(manifest["generated_data"].items()):
        outputs = ", ".join(item["outputs"])
        print(f"  {name}: {item['script']} -> {outputs}")


def command_list(args: argparse.Namespace) -> int:
    """Print the complete build-manifest inventory."""
    print_list(load_manifest())
    return 0


def command_validate(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    print(
        "Manifest is valid: "
        f"{len(manifest['source_sets'])} source sets, "
        f"{len(manifest['tests'])} tests, "
        f"{len(manifest['synthesis_targets'])} synthesis targets."
    )
    return 0
