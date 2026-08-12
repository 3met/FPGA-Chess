"""Measure deployed NNUE quantization against trained parameters and positions."""

from __future__ import annotations

from pathlib import Path

from .config import public_config
from .data import CacheBatchLoader, build_cache, cache_datasets
from .model import (
    EvaluationModel,
    NNUE_ACCUMULATOR_BITS,
    NNUE_OUTPUT_BIAS_BITS,
    NNUE_OUTPUT_WEIGHT_BITS,
    nnue_output_bucket,
)
from .reporting import atomic_json


def signed_bits(low: int, high: int) -> int:
    """Return the smallest two's-complement width containing both endpoints."""
    bits = 1
    while low < -(1 << (bits - 1)) or high > (1 << (bits - 1)) - 1:
        bits += 1
    return bits


def _parameter_stats(values, low: int, high: int) -> dict:
    rounded = values.detach().cpu().round()
    quantized = rounded.clamp(low, high)
    minimum = int(quantized.min().item())
    maximum = int(quantized.max().item())
    return {
        "raw_range": [float(values.detach().cpu().min()), float(values.detach().cpu().max())],
        "quantized_range": [minimum, maximum],
        "minimum_signed_bits": signed_bits(minimum, maximum),
        "saturated_values": int(((rounded < low) | (rounded > high)).sum().item()),
        "value_count": int(values.numel()),
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
    model.load_state_dict(state)
    model.project_parameters()
    model.eval()

    feature = model.feature_weights.round().clamp(-2, 1)
    accumulator_bias = model.accumulator_bias.round().clamp(-4, 3)
    output_weights = model.output_weights.round().clamp(-4, 3)
    output_bias = model.output_bias.round().clamp(-16, 15)
    parameter_report = {
        "feature_weights": _parameter_stats(model.feature_weights, -2, 1),
        "accumulator_bias": _parameter_stats(model.accumulator_bias, -4, 3),
        "output_weights": _parameter_stats(model.output_weights, -4, 3),
        "output_bias": _parameter_stats(model.output_bias, -16, 15),
    }

    cache = build_cache(config)
    train_data, validation_data, _ = cache_datasets(cache)
    loader = CacheBatchLoader(
        validation_data,
        batch_size=min(8192, sample_positions),
        shuffle=False,
        seed=int(config["training"]["seed"]),
        shuffle_buffer=min(8192, sample_positions),
    )
    accumulator_range = activation_range = output_range = None
    accumulator_values = accumulator_overflows = activation_zero = activation_max = 0
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
                accumulator_modulus = 1 << NNUE_ACCUMULATOR_BITS
                accumulator_overflows += int(((
                    accumulators < -accumulator_modulus // 2
                ) | (
                    accumulators > accumulator_modulus // 2 - 1
                )).sum())
                wrapped = torch.remainder(
                    accumulators + accumulator_modulus // 2, accumulator_modulus
                ) - accumulator_modulus // 2
                activations = wrapped.clamp(0, 7)
                activation_range = _update_range(activation_range, activations)
                activation_zero += int((activations == 0).sum())
                activation_max += int((activations == 7).sum())
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
                sampled += codes.shape[0]
    finally:
        train_data.close()
        validation_data.close()

    activation_values = sampled * 2 * feature.shape[1]
    report = {
        "run": run.name,
        "checkpoint_step": int(checkpoint.get("step", 0)),
        "sample_positions": sampled,
        "output_buckets": output_buckets,
        "bucket_counts": bucket_counts.tolist(),
        "parameters": parameter_report,
        "nodes": {
            "unwrapped_accumulator_range": accumulator_range,
            "unwrapped_accumulator_required_signed_bits": signed_bits(*accumulator_range),
            "five_bit_wrap_fraction": accumulator_overflows / max(accumulator_values, 1),
            "activation_range": activation_range,
            "activation_zero_fraction": activation_zero / max(activation_values, 1),
            "activation_seven_fraction": activation_max / max(activation_values, 1),
            "output_sum_range": output_range,
            "output_sum_required_signed_bits": signed_bits(*output_range),
        },
        "deployed_bits": {
            "feature_weights": 2,
            "accumulator_bias": 3,
            "accumulator_state": NNUE_ACCUMULATOR_BITS,
            "activation": 3,
            "output_weights": NNUE_OUTPUT_WEIGHT_BITS,
            "output_bias": NNUE_OUTPUT_BIAS_BITS,
        },
        "config": public_config(config),
    }
    atomic_json(run / "quantization.json", report)
    return report


def print_quantization_report(report: dict) -> None:
    """Print the compact fields used for a width decision."""
    print(
        f"Run {report['run']}: {report['sample_positions']:,} validation positions, "
        f"{report['output_buckets']} output buckets."
    )
    for name, values in report["parameters"].items():
        print(
            f"{name}: quantized={values['quantized_range'][0]}..{values['quantized_range'][1]}, "
            f"minimum_signed_bits={values['minimum_signed_bits']}, "
            f"saturated={values['saturated_values']}/{values['value_count']}"
        )
    nodes = report["nodes"]
    print(
        "accumulator nodes: unwrapped="
        f"{nodes['unwrapped_accumulator_range'][0]}..{nodes['unwrapped_accumulator_range'][1]}, "
        f"wrapped_fraction={nodes['five_bit_wrap_fraction']:.8f}"
    )
    print(
        f"activations: {nodes['activation_range'][0]}..{nodes['activation_range'][1]}, "
        f"zero={nodes['activation_zero_fraction']:.4f}, seven={nodes['activation_seven_fraction']:.4f}"
    )
    print(
        f"output sums: {nodes['output_sum_range'][0]}..{nodes['output_sum_range'][1]}, "
        f"minimum_signed_bits={nodes['output_sum_required_signed_bits']}"
    )
    total = max(sum(report["bucket_counts"]), 1)
    print("bucket population: " + ", ".join(
        f"{index}={count:,} ({100.0 * count / total:.2f}%)"
        for index, count in enumerate(report["bucket_counts"])
    ))
