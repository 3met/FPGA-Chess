"""Small Gaussian-process trust-region optimizer with no external dependency."""

from __future__ import annotations

import heapq
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
        best = None
        for length in (0.06, 0.09, 0.13, 0.19, 0.28, 0.42, 0.63, 0.95, 1.4):
            noise = [max(configured_noise, error) / self.scale for error in errors]
            matrix = [
                [
                    _kernel(left, right, length, groups) + (noise[row] ** 2 + 1e-8 if row == column else 0.0)
                    for column, right in enumerate(points)
                ]
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

    def screen(self, point: list[float]) -> tuple[float, float]:
        """Cheap O(n) approximation used before exact O(n^2) uncertainty."""
        covariance = [_kernel(point, observed, self.length, self.groups) for observed in self.points]
        normalized_mean = sum(value * alpha for value, alpha in zip(covariance, self.alpha, strict=True))
        proxy_variance = max(1e-12, 1.0 - max(covariance, default=0.0) ** 2)
        return self.mean + self.scale * normalized_mean, self.scale * math.sqrt(proxy_variance)


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


def posterior_rankings(
    parameters: list[Parameter], history: list[dict], settings: dict
) -> list[dict]:
    """Rank feasible observations by the fitted GP posterior at each point."""
    feasible = [record for record in history if not record.get("runtime_invalid", False)]
    if not feasible:
        return []
    group_names = sorted({parameter.path.split(".", 1)[0] for parameter in parameters})
    group_axes = [
        [axis for axis, parameter in enumerate(parameters) if parameter.path.split(".", 1)[0] == name]
        for name in group_names
    ]
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
    initial_design = int(settings["initial_design"])
    in_initial_design = proposal_index < max(2, initial_design)
    pool_size = int(settings["initial_candidate_pool_size"] if in_initial_design else settings["candidate_pool_size"])
    rng = random.Random(seed + proposal_index * 104729)
    group_names = sorted({parameter.path.split(".", 1)[0] for parameter in parameters})
    group_axes = [
        [axis for axis, parameter in enumerate(parameters) if parameter.path.split(".", 1)[0] == name]
        for name in group_names
    ]
    initial_group = group_names[(proposal_index - 1) % len(group_names)] if in_initial_design else None
    active_axes = [
        axis for axis, parameter in enumerate(parameters)
        if initial_group is None or parameter.path.split(".", 1)[0] == initial_group
    ]
    mutation_probability = 1.0 if in_initial_design else min(1.0, float(settings["mutation_axes"]) / dimension)
    model = None
    incumbent = None
    model_history = [record for record in history if not record.get("runtime_invalid", False)]
    promoted = [record for record in model_history if record.get("promoted")]
    center_record = max(promoted or model_history, key=lambda record: record["score"])
    if not in_initial_design:
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
    center = vector_from_json(center_record["parameters"], parameters)
    seen: set[str] = set()
    selected: tuple[list[float], dict] | None = None
    selected_acquisition = -math.inf
    proposal_count = 0
    shortlist: list[tuple[float, int, list[float], dict]] = []
    shortlist_size = int(settings["acquisition_shortlist_size"])

    # A scrambled low-discrepancy pool provides much more even coverage than
    # independent random sampling, then sparse mutation keeps trials local.
    offset = rng.randrange(1, 1_000_000)
    rotations = [rng.random() for _ in range(dimension)]
    observed_vectors = [vector_from_json(record["parameters"], parameters) for record in history]
    best_minimum_distance = -1.0
    for item in range(pool_size):
        vector = center.copy()
        changed = False
        for axis in active_axes:
            if rng.random() <= mutation_probability:
                unit = (_halton(offset + item + 1, PRIMES[axis]) + rotations[axis]) % 1.0
                vector[axis] = min(1.0, max(0.0, center[axis] + (2.0 * unit - 1.0) * radius))
                changed = True
        if not changed:
            axis = active_axes[item % len(active_axes)]
            vector[axis] = min(1.0, max(0.0, center[axis] + rng.choice((-1.0, 1.0)) * radius))
        candidate = json_from_vector(base_json, vector, parameters)
        canonical_vector = vector_from_json(candidate, parameters)
        digest = parameter_hash(candidate)
        if digest in observed or digest in seen:
            continue
        seen.add(digest)
        proposal_count += 1
        if model is None:
            minimum_distance = min(
                math.sqrt(sum((a - b) ** 2 for a, b in zip(canonical_vector, point, strict=True)))
                for point in observed_vectors
            )
            if minimum_distance > best_minimum_distance:
                best_minimum_distance = minimum_distance
                selected = canonical_vector, candidate
            continue
        predicted, uncertainty = model.screen(canonical_vector)
        screening_value = _expected_improvement(
            predicted, uncertainty, incumbent, float(settings["acquisition_exploration_elo"])
        )
        item_value = (screening_value, proposal_count, canonical_vector, candidate)
        if len(shortlist) < shortlist_size:
            heapq.heappush(shortlist, item_value)
        elif screening_value > shortlist[0][0]:
            heapq.heapreplace(shortlist, item_value)

    if model is not None:
        for _, _, canonical_vector, candidate in shortlist:
            predicted, uncertainty = model.predict(canonical_vector)
            acquisition = _expected_improvement(
                predicted, uncertainty, incumbent, float(settings["acquisition_exploration_elo"])
            )
            if acquisition > selected_acquisition:
                selected_acquisition = acquisition
                selected = canonical_vector, candidate

    if selected is None:
        raise RuntimeError("candidate space is exhausted at the current quantization")
    if model is None:
        return selected[1], {
            "method": "grouped maximin low-discrepancy design",
            "group": initial_group,
            "pool": proposal_count,
        }
    predicted, uncertainty = model.predict(selected[0])
    return selected[1], {
        "method": "Gaussian-process expected improvement",
        "pool": proposal_count,
        "shortlist": len(shortlist),
        "predicted_elo": round(predicted, 2),
        "predicted_stddev": round(uncertainty, 2),
        "kernel_length": model.length,
        "center_id": center_record["id"],
        "center_posterior_elo": round(incumbent, 2),
        "center_posterior_stddev": round(center_uncertainty, 2),
    }
