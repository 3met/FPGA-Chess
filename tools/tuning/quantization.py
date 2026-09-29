"""Measure target NNUE quantization against trained parameters and positions."""

from __future__ import annotations

from pathlib import Path

from .config import public_config
from .data import CacheBatchLoader, build_cache, cache_datasets
from .model import (
    EvaluationModel,
    NNUE_ACCUMULATOR_BITS,
    NNUE_ACCUMULATOR_BIAS_BITS,
    NNUE_ACCUMULATOR_BIAS_MAX,
    NNUE_ACTIVATION_BITS,
    NNUE_ACTIVATION_MAX,
    NNUE_CLIPPED_ACCUMULATOR_BITS,
    NNUE_CLIPPED_ACCUMULATOR_MAX,
    NNUE_PIECE_CATEGORIES,
    NNUE_MAX_ENGINE_UNITS,
    NNUE_OUTPUT_BIAS_BITS,
    NNUE_OUTPUT_BIAS_MAX,
    NNUE_OUTPUT_WEIGHT_BITS,
    NNUE_OUTPUT_WEIGHT_MAX,
    NNUE_OUTPUT_WEIGHT_MIN,
    NNUE_SCRELU_TOP_CODE,
    NNUE_SIDES,
    PIECE_ORDER,
    _squared_clipped_activation,
    nnue_output_bucket,
)
from .reporting import atomic_json, format_table


def signed_bits(low: int, high: int) -> int:
    """Return the smallest two's-complement width containing both endpoints."""
    bits = 1
    while low < -(1 << (bits - 1)) or high > (1 << (bits - 1)) - 1:
        bits += 1
    return bits


def _parameter_stats(values, low: int, high: int, signed: bool = True) -> dict:
    """Measure the target code distribution and its required signedness/width."""
    rounded = values.detach().cpu().round()
    quantized = rounded.clamp(low, high)
    minimum = int(quantized.min().item())
    maximum = int(quantized.max().item())
    counts = {
        str(value): int((quantized == value).sum().item())
        for value in range(low, high + 1)
    }
    value_count = int(values.numel())
    return {
        "raw_range": [float(values.detach().cpu().min()), float(values.detach().cpu().max())],
        "quantized_range": [minimum, maximum],
        "minimum_bits": signed_bits(minimum, maximum) if signed else max(1, maximum.bit_length()),
        "encoding": "signed" if signed else "unsigned",
        "saturated_values": int(((rounded < low) | (rounded > high)).sum().item()),
        "value_count": value_count,
        "zero_fraction": counts.get("0", 0) / max(value_count, 1),
        "minimum_value_fraction": counts[str(low)] / max(value_count, 1),
        "maximum_value_fraction": counts[str(high)] / max(value_count, 1),
        "histogram": counts,
    }


def _update_range(current: list[int] | None, values) -> list[int]:
    low = int(values.min().item())
    high = int(values.max().item())
    return [low, high] if current is None else [min(current[0], low), max(current[1], high)]


def analyze_quantization(config: dict, run: Path, sample_positions: int = 131_072) -> dict:
    """Profile quantized parameters and exact integer nodes on validation positions."""
    if sample_positions < 1:
        raise ValueError("sample_positions must be positive")
    import torch

    checkpoint_path = run / "best.pt"
    if not checkpoint_path.is_file():
        raise FileNotFoundError(f"run has no best checkpoint: {run.name}")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    state = checkpoint["model"]
    output_buckets = int(state["output_weights"].shape[0])
    model = EvaluationModel(output_buckets=output_buckets)
    from .training import _initialize_model

    _initialize_model(model, checkpoint)
    model.project_parameters()
    model.eval()

    feature = model.feature_weights.round().clamp(-2, 1)
    accumulator_bias = model.accumulator_bias.round().clamp(0, NNUE_ACCUMULATOR_BIAS_MAX)
    output_weights = model.output_weights.round().clamp(
        NNUE_OUTPUT_WEIGHT_MIN, NNUE_OUTPUT_WEIGHT_MAX
    )
    output_bias = model.output_bias.round().clamp(0, NNUE_OUTPUT_BIAS_MAX)
    parameter_report = {
        "feature_weights": _parameter_stats(model.feature_weights, -2, 1),
        "accumulator_bias": _parameter_stats(
            model.accumulator_bias, 0, NNUE_ACCUMULATOR_BIAS_MAX, signed=False
        ),
        "output_weights": _parameter_stats(
            model.output_weights, NNUE_OUTPUT_WEIGHT_MIN, NNUE_OUTPUT_WEIGHT_MAX
        ),
        "output_bias": _parameter_stats(
            model.output_bias, 0, NNUE_OUTPUT_BIAS_MAX, signed=False
        ),
    }
    # Transformer rows are grouped by relative color, piece type, and square.
    category_weights = feature.reshape(NNUE_SIDES, NNUE_PIECE_CATEGORIES, -1)
    category_zeros = category_weights.eq(0).sum(dim=2)
    category_weight_count = category_weights.shape[2]
    feature_zero_by_category = [
        {
            "category": f"{side} {piece}",
            "zero_count": int(category_zeros[side_index, piece_index]),
            "weight_count": category_weight_count,
            "zero_fraction": float(category_zeros[side_index, piece_index])
            / category_weight_count,
        }
        for side_index, side in enumerate(("Friendly", "Opposing"))
        for piece_index, piece in enumerate(PIECE_ORDER)
    ]

    cache = build_cache(config)
    train_data, validation_data, _ = cache_datasets(cache)
    loader = CacheBatchLoader(
        validation_data,
        batch_size=min(8192, sample_positions),
        shuffle=False,
        seed=int(config["training"]["seed"]),
        shuffle_buffer=min(8192, sample_positions),
    )
    accumulator_range = clipped_range = activation_range = output_range = None
    accumulator_values = accumulator_overflows = wrapped_positions = activation_zero = activation_max = 0
    accumulator_sum = accumulator_square_sum = 0.0
    clipped_histogram = torch.zeros(NNUE_CLIPPED_ACCUMULATOR_MAX + 1, dtype=torch.int64)
    activation_histogram = torch.zeros(NNUE_ACTIVATION_MAX + 1, dtype=torch.int64)
    output_values = output_clipped = 0
    output_sum = output_square_sum = 0.0
    bucket_counts = torch.zeros(output_buckets, dtype=torch.int64)
    sampled = 0
    padded_feature = torch.cat((torch.zeros((1, feature.shape[1])), feature))
    try:
        with torch.inference_mode():
            for codes, white_to_move, _target in loader:
                remaining = sample_positions - sampled
                if remaining <= 0:
                    break
                codes = codes[:remaining]
                white_to_move = white_to_move[:remaining]
                indices, valid, _ = model.nnue_indices(codes)
                bag_indices = torch.where(valid, indices + 1, torch.zeros_like(indices))
                accumulators = torch.nn.functional.embedding_bag(
                    bag_indices.reshape(-1, bag_indices.shape[-1]),
                    padded_feature,
                    mode="sum",
                ).reshape(codes.shape[0], 2, feature.shape[1]) + accumulator_bias
                accumulator_range = _update_range(accumulator_range, accumulators)
                accumulator_values += accumulators.numel()
                accumulator_sum += float(accumulators.sum())
                accumulator_square_sum += float(accumulators.square().sum())
                accumulator_modulus = 1 << NNUE_ACCUMULATOR_BITS
                overflow_mask = ((
                    accumulators < -accumulator_modulus // 2
                ) | (
                    accumulators > accumulator_modulus // 2 - 1
                ))
                accumulator_overflows += int(overflow_mask.sum())
                wrapped_positions += int(overflow_mask.any(dim=(1, 2)).sum())
                wrapped = torch.remainder(
                    accumulators + accumulator_modulus // 2, accumulator_modulus
                ) - accumulator_modulus // 2
                clipped = wrapped.clamp(0, NNUE_CLIPPED_ACCUMULATOR_MAX)
                clipped_range = _update_range(clipped_range, clipped)
                clipped_histogram += torch.bincount(
                    clipped.reshape(-1).to(torch.int64),
                    minlength=NNUE_CLIPPED_ACCUMULATOR_MAX + 1,
                )
                activations = _squared_clipped_activation(wrapped)
                activation_range = _update_range(activation_range, activations)
                activation_zero += int((activations == 0).sum())
                activation_max += int((activations == NNUE_SCRELU_TOP_CODE).sum())
                activation_histogram += torch.bincount(
                    activations.reshape(-1).to(torch.int64),
                    minlength=NNUE_ACTIVATION_MAX + 1,
                )
                first = torch.where(
                    white_to_move[:, None], activations[:, 0], activations[:, 1]
                )
                second = torch.where(
                    white_to_move[:, None], activations[:, 1], activations[:, 0]
                )
                ordered = torch.cat((first, second), dim=1)
                buckets = nnue_output_bucket(codes, output_buckets)
                bucket_counts += torch.bincount(buckets, minlength=output_buckets)
                outputs = (ordered * output_weights[buckets]).sum(dim=1) + output_bias[buckets]
                output_range = _update_range(output_range, outputs)
                output_values += outputs.numel()
                output_clipped += int((outputs.abs() > NNUE_MAX_ENGINE_UNITS).sum())
                output_sum += float(outputs.sum())
                output_square_sum += float(outputs.square().sum())
                sampled += codes.shape[0]
    finally:
        train_data.close()
        validation_data.close()

    activation_values = sampled * 2 * feature.shape[1]
    accumulator_mean = accumulator_sum / max(accumulator_values, 1)
    output_mean = output_sum / max(output_values, 1)
    report = {
        "run": run.name,
        "checkpoint_step": int(checkpoint.get("step", 0)),
        "sample_positions": sampled,
        "output_buckets": output_buckets,
        "bucket_counts": bucket_counts.tolist(),
        "parameters": parameter_report,
        "feature_zero_by_category": feature_zero_by_category,
        "nodes": {
            "unwrapped_accumulator_range": accumulator_range,
            "unwrapped_accumulator_required_signed_bits": signed_bits(*accumulator_range),
            "unwrapped_accumulator_mean": accumulator_mean,
            "unwrapped_accumulator_stddev": max(
                accumulator_square_sum / max(accumulator_values, 1) - accumulator_mean ** 2,
                0.0,
            ) ** 0.5,
            "accumulator_wrap_fraction": accumulator_overflows / max(accumulator_values, 1),
            "position_wrap_fraction": wrapped_positions / max(sampled, 1),
            "clipped_accumulator_range": clipped_range,
            "clipped_accumulator_histogram": clipped_histogram.tolist(),
            "activation_range": activation_range,
            "activation_zero_fraction": activation_zero / max(activation_values, 1),
            "activation_top_code": NNUE_SCRELU_TOP_CODE,
            "activation_max_fraction": activation_max / max(activation_values, 1),
            "activation_histogram": activation_histogram.tolist(),
            "output_sum_range": output_range,
            "output_sum_required_signed_bits": signed_bits(*output_range),
            "output_sum_mean": output_mean,
            "output_sum_stddev": max(
                output_square_sum / max(output_values, 1) - output_mean ** 2,
                0.0,
            ) ** 0.5,
            "output_clipping_fraction": output_clipped / max(output_values, 1),
        },
        "target_bits": {
            "feature_weights": 2,
            "accumulator_bias": NNUE_ACCUMULATOR_BIAS_BITS,
            "accumulator_state": NNUE_ACCUMULATOR_BITS,
            "clipped_accumulator": NNUE_CLIPPED_ACCUMULATOR_BITS,
            "activation": NNUE_ACTIVATION_BITS,
            "output_weights": NNUE_OUTPUT_WEIGHT_BITS,
            "output_bias": NNUE_OUTPUT_BIAS_BITS,
        },
        "config": public_config(config),
    }
    atomic_json(run / "quantization.json", report)
    return report


def print_quantization_report(report: dict) -> None:
    """Show quantized widths, occupancy, and node behavior in terminal tables."""
    print(f"Run: {report['run']}  Selected step: {report['checkpoint_step']:,}")
    print(f"Validation sample: {report['sample_positions']:,} positions")

    names = {
        "feature_weights": "Feature weights",
        "accumulator_bias": "Accumulator bias",
        "output_weights": "Output weights",
        "output_bias": "Output bias",
    }
    parameter_rows = []
    for key, name in names.items():
        values = report["parameters"][key]
        low, high = values["quantized_range"]
        codes = sorted(int(code) for code in values["histogram"])
        nonnegative = "-"
        if values["encoding"] == "signed":
            count = sum(values["histogram"][str(code)] for code in codes if code >= 0)
            nonnegative = f"{100 * count / values['value_count']:.1f}%"
        parameter_rows.append((
            name, values["encoding"], f"{low}..{high}", f"{codes[0]}..{codes[-1]}",
            f"{values['minimum_bits']}/{report['target_bits'][key]}",
            f"{100 * values['zero_fraction']:.1f}%",
            nonnegative,
            f"{100 * values['minimum_value_fraction']:.1f}%",
            f"{100 * values['maximum_value_fraction']:.1f}%",
            f"{values['saturated_values']:,}/{values['value_count']:,}",
        ))
    print("\nQuantized parameter ranges and occupancy")
    print(format_table(
        ("Parameter", "Encoding", "Observed", "Allowed", "Bits used/target", "Zero", ">= 0", "At min", "At max", "Out of range"),
        parameter_rows,
    ))
    print("\nZero feature weights by piece category")
    print(format_table(("Category", "Zero weights", "Fraction"), [
        (entry["category"], f"{entry['zero_count']:,}/{entry['weight_count']:,}",
         f"{100 * entry['zero_fraction']:.1f}%")
        for entry in report["feature_zero_by_category"]
    ]))

    nodes = report["nodes"]
    accumulator_range = nodes["unwrapped_accumulator_range"]
    output_range = nodes["output_sum_range"]
    print("\nForward-pass integer ranges")
    print(format_table(("Node", "Range", "Required bits", "Mean", "Std dev"), [
        ("Accumulator before wrap", f"{accumulator_range[0]}..{accumulator_range[1]}",
         str(nodes["unwrapped_accumulator_required_signed_bits"]),
         f"{nodes['unwrapped_accumulator_mean']:.2f}",
         f"{nodes['unwrapped_accumulator_stddev']:.2f}"),
        ("SCReLU input after clip",
         f"{nodes['clipped_accumulator_range'][0]}..{nodes['clipped_accumulator_range'][1]}",
         str(report["target_bits"]["clipped_accumulator"]), "-", "-"),
        ("SCReLU output", f"{nodes['activation_range'][0]}..{nodes['activation_range'][1]}",
         str(report["target_bits"]["activation"]), "-", "-"),
        ("Output sum", f"{output_range[0]}..{output_range[1]}",
         str(nodes["output_sum_required_signed_bits"]),
         f"{nodes['output_sum_mean']:.2f}", f"{nodes['output_sum_stddev']:.2f}"),
    ]))
    print("\nWrap, activation, and clipping rates")
    print(format_table(("Condition", "Fraction"), [
        ("Accumulator lanes that wrap", f"{100 * nodes['accumulator_wrap_fraction']:.3f}%"),
        ("Positions with any wrap", f"{100 * nodes['position_wrap_fraction']:.2f}%"),
        ("SCReLU outputs at zero", f"{100 * nodes['activation_zero_fraction']:.2f}%"),
        (f"SCReLU outputs at top code {nodes['activation_top_code']}",
         f"{100 * nodes['activation_max_fraction']:.2f}%"),
        ("Outputs clipped", f"{100 * nodes['output_clipping_fraction']:.3f}%"),
    ]))
    input_counts = nodes["clipped_accumulator_histogram"]
    output_counts = nodes["activation_histogram"]
    input_total = max(sum(input_counts), 1)
    output_total = max(sum(output_counts), 1)
    activation_rows = [
        (str(code), f"{input_count:,}", f"{100 * input_count / input_total:.2f}%",
         f"{output_counts[code]:,}" if code < len(output_counts) else "-",
         f"{100 * output_counts[code] / output_total:.2f}%"
         if code < len(output_counts) else "-")
        for code, input_count in enumerate(input_counts)
    ]
    print("\nSCReLU code frequencies")
    print(format_table(
        ("Code", "Input count", "Input share", "Output count", "Output share"),
        activation_rows,
    ))

    total = max(sum(report["bucket_counts"]), 1)
    bucket_width = 32 // report["output_buckets"]
    bucket_rows = [
        (str(index), f"{2 + index * bucket_width}..{min(32, 1 + (index + 1) * bucket_width)}",
         f"{count:,}", f"{100 * count / total:.2f}%")
        for index, count in enumerate(report["bucket_counts"])
    ]
    print("\nOutput bucket coverage (validation sample)")
    print(format_table(("Bucket", "Piece count", "Sampled positions", "Sample share"), bucket_rows))
