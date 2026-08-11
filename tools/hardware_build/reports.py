"""Synthesis-result report command dispatch."""

import argparse

from .common import BUILD_ROOT, BuildError, rel
from .manifest import load_manifest
from .report_common import format_duration, load_synth_metadata, print_table, report_timestamp
from .reports_quartus import quartus_partial_report, quartus_synth_report
from .reports_vivado import vivado_synth_report

def command_synth_report(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    targets = manifest["synthesis_targets"]
    if args.target:
        if args.target not in targets:
            raise BuildError(f"Unknown synthesis target '{args.target}'")
        target_name = args.target
    else:
        candidates = [
            (path.stat().st_mtime, name)
            for name in targets
            if (path := BUILD_ROOT / name).is_dir()
        ]
        if not candidates:
            raise BuildError("No previous synthesis results found")
        target_name = max(candidates)[1]

    target = targets[target_name]
    build_dir = BUILD_ROOT / target_name
    if not build_dir.is_dir():
        raise BuildError(f"No synthesis results found for target '{target_name}'")
    metadata = load_synth_metadata(build_dir)
    print(f"Synthesis report: {target_name}")
    details = [
        ["Tool", target["tool"]],
        ["Top", target["top"]],
        ["Device", target.get("device", metadata.get("part") if metadata else "unspecified")],
        ["Started", report_timestamp(build_dir, metadata)],
    ]
    if metadata:
        if "build_id" in metadata:
            details.append(["Build ID", str(metadata["build_id"])])
        if "seed" in metadata:
            details.append(["Seed", str(metadata["seed"])])
        details.append(["Status", str(metadata.get("status", "unknown")).upper()])
        if "elapsed_seconds" in metadata:
            details.append(["Tool time", format_duration(metadata["elapsed_seconds"])])
        print_table("Run", ["Field", "Value"], details)
        stage_rows = []
        for stage in metadata.get("stages", []):
            stage_rows.append(
                [
                    stage["name"],
                    str(stage["status"]).upper(),
                    format_duration(stage["elapsed_seconds"]),
                    str(stage.get("return_code", "")),
                ]
            )
        print_table("Stages", ["Stage", "Status", "Time", "Return code"], stage_rows)
    else:
        details.append(["Status/time", "unavailable (run predates synthesis metadata)"])
        print_table("Run", ["Field", "Value"], details)

    found = (
        quartus_synth_report(build_dir, args.verbose)
        if target["tool"] == "quartus"
        else vivado_synth_report(build_dir, args.verbose)
    )
    partial = False
    if not found and target["tool"] == "quartus":
        partial = quartus_partial_report(build_dir)
    if not found:
        if partial:
            print(f"\n  Build directory: {rel(build_dir)}")
            return 0
        print("\nNo synthesis reports or partial logs were found.")
        print(f"  Build directory: {rel(build_dir)}")
        return 1
    return 0
