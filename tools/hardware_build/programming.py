"""FPGA programming backends for synthesized hardware artifacts."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from .common import BUILD_ROOT, REPO_ROOT, BuildError, print_failure_excerpt, rel, require_tool, run_command
from .manifest import load_manifest


def resolve_artifact(target: dict, override: str | None) -> Path:
    """Return the requested artifact, resolving manifest paths from the repo root."""
    if override:
        artifact = Path(override).expanduser()
        if not artifact.is_absolute():
            artifact = REPO_ROOT / artifact
    else:
        artifact = Path(target["artifact"])
        if not artifact.is_absolute():
            artifact = REPO_ROOT / artifact
    artifact = artifact.resolve()
    if not artifact.is_file():
        raise BuildError(
            f"Programming artifact does not exist: {artifact}. "
            "Run synthesis first or pass --file <path>."
        )
    return artifact


JTAG_ID_RE = re.compile(r"^\s*([0-9A-Fa-f]{8})\b", re.MULTILINE)
JTAG_CHAIN_RE = re.compile(r"^(\d+)\)\s+(.+)$", re.MULTILINE)


def discover_quartus_device_index(jtag_id: str, cable: str | None) -> int:
    """Find a unique device position by scanning the active JTAG chains."""
    require_tool("jtagconfig")
    code, output, _ = run_command(["jtagconfig"], REPO_ROOT)
    if code != 0:
        raise BuildError("Could not scan JTAG chains with jtagconfig")
    chains = list(JTAG_CHAIN_RE.finditer(output))
    found: list[tuple[str, str, int]] = []
    for position, chain in enumerate(chains):
        chain_end = chains[position + 1].start() if position + 1 < len(chains) else len(output)
        for index, value in enumerate(JTAG_ID_RE.findall(output[chain.end() : chain_end]), start=1):
            if value.upper() == jtag_id.upper():
                found.append((chain.group(1), chain.group(2), index))
    if cable:
        # Quartus accepts either its numbered cable identifier or its displayed name.
        found = [item for item in found if cable == item[0] or cable.casefold() in item[1].casefold()]
    if not found:
        raise BuildError(f"No JTAG device with ID code 0x{jtag_id} was found; check the board and cable")
    if len(found) != 1:
        raise BuildError(
            f"Found {len(found)} JTAG devices with ID code 0x{jtag_id}; pass --device-index to select one"
        )
    return found[0][2]


def flash_quartus(
    target_name: str,
    target: dict,
    artifact: Path,
    cable: str | None,
    device_index: int | None,
    dry_run: bool,
) -> int:
    """Program a volatile FPGA image through the Quartus JTAG programmer."""
    if device_index is None:
        device_index = discover_quartus_device_index(target["jtag_id"], cable)
    command = ["quartus_pgm", "-m", target["mode"], "-o", f"p;{artifact}@{device_index}"]
    if cable:
        command.extend(["-c", cable])

    print(f"Programming target: {target_name}")
    artifact_text = rel(artifact) if artifact.is_relative_to(REPO_ROOT) else str(artifact)
    print(f"Artifact: {artifact_text}")
    print(f"JTAG device index: {device_index}")
    print(f"Command: {' '.join(command)}")
    if dry_run:
        print("Dry run: programmer was not started.")
        return 0

    require_tool("quartus_pgm")
    log_path = BUILD_ROOT / target["synthesis_target"] / "quartus_pgm.log"
    code, output, elapsed = run_command(command, REPO_ROOT, log_path, live_log=True, tee_stdout=True)
    if code != 0:
        print(f"[FAIL] Quartus programming ({elapsed:.2f}s)")
        print(f"  log: {rel(log_path)}")
        print_failure_excerpt(output)
        return 1
    print(f"[PASS] Quartus programming ({elapsed:.2f}s)")
    print(f"  log: {rel(log_path)}")
    return 0


def command_flash(args: argparse.Namespace) -> int:
    """Dispatch programming to the selected vendor backend."""
    manifest = load_manifest()
    targets = manifest["programming_targets"]
    if args.target not in targets:
        raise BuildError(f"Unknown programming target '{args.target}'")
    target = targets[args.target]
    if args.device_index is not None and args.device_index < 1:
        raise BuildError("--device-index must be at least 1")
    artifact = resolve_artifact(target, args.file)
    if target["tool"] == "quartus":
        return flash_quartus(args.target, target, artifact, args.cable, args.device_index, args.dry_run)
    raise BuildError(f"Programming target '{args.target}' uses unsupported tool '{target['tool']}'")
