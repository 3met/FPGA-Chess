"""Small Gaussian-process trust-region optimizer with no external dependency."""

from __future__ import annotations

import math
import random
from statistics import NormalDist

from .space import Parameter, json_from_vector, parameter_hash, vector_from_json


def _matern52(distance: float) -> float:
    scaled = math.sqrt(5.0) * distance
    return (1.0 + scaled + 5.0 * distance * distance / 3.0) * math.exp(-scaled)


def _kernel(left: list[float], right: list[float], length: float, groups: list[list[int]]) -> float:
    """Average group-local kernels to model mostly additive search effects."""
    values = []
    for axes in groups:
        distance = math.sqrt(sum((left[axis] - right[axis]) ** 2 for axis in axes) / len(axes)) / length
        values.append(_matern52(distance))
    return sum(values) / len(values)


def _cholesky(matrix: list[list[float]]) -> list[list[float]]:
    size = len(matrix)
    lower = [[0.0] * size for _ in range(size)]
    for row in range(size):
        for column in range(row + 1):
            value = matrix[row][column] - sum(lower[row][k] * lower[column][k] for k in range(column))
            if row == column:
                if value <= 1e-12:
                    raise ArithmeticError("non-positive covariance")
                lower[row][column] = math.sqrt(value)
            else:
                lower[row][column] = value / lower[column][column]
    return lower


def _solve(lower: list[list[float]], values: list[float]) -> list[float]:
    size = len(values)
    forward = [0.0] * size
    for row in range(size):
        forward[row] = (values[row] - sum(lower[row][k] * forward[k] for k in range(row))) / lower[row][row]
    result = [0.0] * size
    for row in range(size - 1, -1, -1):
        result[row] = (
            forward[row] - sum(lower[k][row] * result[k] for k in range(row + 1, size))
        ) / lower[row][row]
    return result


class GaussianProcess:
    """Isotropic Matérn-5/2 GP with marginal-likelihood hyperparameter search."""

    def __init__(
        self, points: list[list[float]], scores: list[float], errors: list[float],
        configured_noise: float, groups: list[list[int]],
    ):
        self.points = points
        self.groups = groups
        self.mean = sum(scores) / len(scores)
        self.scale = max(1.0, math.sqrt(sum((score - self.mean) ** 2 for score in scores) / len(scores)))
        targets = [(score - self.mean) / self.scale for score in scores]
        noise = [max(configured_noise, error) / self.scale for error in errors]
        best = None
        for length in (0.06, 0.09, 0.13, 0.19, 0.28, 0.42, 0.63, 0.95, 1.4):
            # Cholesky reads only the lower triangle of the symmetric covariance.
            matrix = [
                [_kernel(left, points[column], length, groups) for column in range(row)]
                + [1.0 + (noise[row] ** 2 + 1e-8)]
                for row, left in enumerate(points)
            ]
            try:
                lower = _cholesky(matrix)
            except ArithmeticError:
                continue
            alpha = _solve(lower, targets)
            log_likelihood = -0.5 * sum(a * b for a, b in zip(targets, alpha, strict=True))
            log_likelihood -= sum(math.log(lower[index][index]) for index in range(len(points)))
            if best is None or log_likelihood > best[0]:
                best = (log_likelihood, length, lower, alpha)
        if best is None:
            raise ArithmeticError("could not fit Gaussian process")
        _, self.length, self.lower, self.alpha = best

    def predict(self, point: list[float]) -> tuple[float, float]:
        covariance = [_kernel(point, observed, self.length, self.groups) for observed in self.points]
        normalized_mean = sum(value * alpha for value, alpha in zip(covariance, self.alpha, strict=True))
        projected = []
        for row in range(len(covariance)):
            projected.append(
                (covariance[row] - sum(self.lower[row][k] * projected[k] for k in range(row)))
                / self.lower[row][row]
            )
        variance = max(1e-12, 1.0 - sum(value * value for value in projected))
        return self.mean + self.scale * normalized_mean, self.scale * math.sqrt(variance)


def _expected_improvement(mean: float, deviation: float, incumbent: float, exploration: float) -> float:
    if deviation <= 1e-12:
        return max(0.0, mean - incumbent - exploration)
    improvement = mean - incumbent - exploration
    z_score = improvement / deviation
    normal = NormalDist()
    return improvement * normal.cdf(z_score) + deviation * normal.pdf(z_score)


def _halton(index: int, base: int) -> float:
    result = 0.0
    fraction = 1.0
    while index:
        fraction /= base
        result += fraction * (index % base)
        index //= base
    return result


PRIMES = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71,
          73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167,
          173, 179, 181, 191, 193, 197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263]


def _parameter_groups(parameters: list[Parameter]) -> list[list[int]]:
    """Group coordinates by policy section in stable name order."""
    groups: dict[str, list[int]] = {}
    for axis, parameter in enumerate(parameters):
        groups.setdefault(parameter.path.split(".", 1)[0], []).append(axis)
    return [groups[name] for name in sorted(groups)]


def posterior_rankings(
    parameters: list[Parameter], history: list[dict], settings: dict
) -> list[dict]:
    """Rank feasible observations by the fitted GP posterior at each point."""
    feasible = [record for record in history if not record.get("runtime_invalid", False)]
    if not feasible:
        return []
    group_axes = _parameter_groups(parameters)
    points = [vector_from_json(record["parameters"], parameters) for record in feasible]
    scores = [float(record["score"]) for record in feasible]
    errors = [
        max(float(settings["observation_noise_elo"]), float(record["score_error"]) / 1.96)
        for record in feasible
    ]
    model = GaussianProcess(points, scores, errors, float(settings["observation_noise_elo"]), group_axes)
    rankings = []
    for record, point in zip(feasible, points, strict=True):
        mean, deviation = model.predict(point)
        rankings.append({
            "trial_id": record["id"],
            "posterior_elo": mean,
            "posterior_stddev": deviation,
            "vector": point,
        })
    return sorted(rankings, key=lambda item: item["posterior_elo"], reverse=True)


def suggest(
    base_json: dict,
    parameters: list[Parameter],
    history: list[dict],
    settings: dict,
    seed: int,
    radius: float,
    excluded_hashes: set[str] | None = None,
) -> tuple[dict, dict]:
    """Spend CPU time fitting a surrogate and maximizing expected improvement."""
    excluded = excluded_hashes or set()
    observed = {record["parameter_hash"] for record in history}
    observed.update(excluded)
    proposal_index = len(history) + len(excluded)
    dimension = len(parameters)
    pool_size = int(settings["candidate_pool_size"])
    rng = random.Random(seed + proposal_index * 104729)
    model_history = [record for record in history if not record.get("runtime_invalid", False)]
    if len(model_history) < 2:
        # Bootstrap across the full configured space until a usable challenger
        # joins the baseline; failed builds and runtime-invalid trials do not count.
        for attempt in range(pool_size):
            candidate = json_from_vector(base_json, [rng.random() for _ in parameters], parameters)
            if parameter_hash(candidate) not in observed:
                return candidate, {"method": "random startup challenger", "pool": attempt + 1}
        raise RuntimeError("no untested startup candidate found at the current quantization")

    group_axes = _parameter_groups(parameters)
    mutation_probability = min(1.0, float(settings["mutation_axes"]) / dimension)
    points = [vector_from_json(record["parameters"], parameters) for record in model_history]
    scores = [float(record["score"]) for record in model_history]
    errors = [
        max(float(settings["observation_noise_elo"]), float(record.get("score_error") or 0.0) / 1.96)
        for record in model_history
    ]
    model = GaussianProcess(
        points, scores, errors, float(settings["observation_noise_elo"]), group_axes
    )
    posterior_predictions = [model.predict(point) for point in points]
    posterior_means = [prediction[0] for prediction in posterior_predictions]
    center_index = max(range(len(model_history)), key=posterior_means.__getitem__)
    center_record = model_history[center_index]
    incumbent = posterior_means[center_index]
    center_uncertainty = posterior_predictions[center_index][1]
    center = points[center_index]
    seen: set[str] = set()
    selected: dict | None = None
    selected_prediction: tuple[float, float] | None = None
    selected_acquisition = -math.inf
    proposal_count = 0

    # A scrambled low-discrepancy pool provides much more even coverage than
    # independent random sampling, then sparse mutation keeps trials local.
    offset = rng.randrange(1, 1_000_000)
    rotations = [rng.random() for _ in range(dimension)]
    for item in range(pool_size):
        vector = center.copy()
        changed = False
        for axis in range(dimension):
            if rng.random() <= mutation_probability:
                unit = (_halton(offset + item + 1, PRIMES[axis]) + rotations[axis]) % 1.0
                vector[axis] = min(1.0, max(0.0, center[axis] + (2.0 * unit - 1.0) * radius))
                changed = True
        if not changed:
            axis = item % dimension
            vector[axis] = min(1.0, max(0.0, center[axis] + rng.choice((-1.0, 1.0)) * radius))
        candidate = json_from_vector(base_json, vector, parameters)
        digest = parameter_hash(candidate)
        if digest in observed or digest in seen:
            continue
        seen.add(digest)
        proposal_count += 1
        # Score every unique, untested proposal with the full GP posterior.
        canonical_vector = vector_from_json(candidate, parameters)
        predicted, uncertainty = model.predict(canonical_vector)
        acquisition = _expected_improvement(
            predicted, uncertainty, incumbent, float(settings["acquisition_exploration_elo"])
        )
        if acquisition > selected_acquisition:
            selected_acquisition = acquisition
            selected = candidate
            selected_prediction = predicted, uncertainty

    if selected is None or selected_prediction is None:
        raise RuntimeError("candidate space is exhausted at the current quantization")
    predicted, uncertainty = selected_prediction
    return selected, {
        "method": "Gaussian-process expected improvement",
        "pool": proposal_count,
        "predicted_elo": round(predicted, 2),
        "predicted_stddev": round(uncertainty, 2),
        "kernel_length": model.length,
        "center_id": center_record["id"],
        "center_posterior_elo": round(incumbent, 2),
        "center_posterior_stddev": round(center_uncertainty, 2),
    }
