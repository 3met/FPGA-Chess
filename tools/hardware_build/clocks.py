"""Validate operating clocks shared by synthesis and engine profiling."""

from .common import BuildError


def resolve_clocks(value: dict) -> dict:
    """Require every operating setting; memory IO inherits the memory frequency."""
    roles = {"engine", "memory", "memory_io", "communication"}
    if not isinstance(value, dict) or set(value) != roles:
        raise BuildError("clocks must define exactly engine, memory, memory_io, communication")
    resolved = {}
    for role in sorted(roles):
        clock = value[role]
        keys = {"phase_ps", "duty_percent"}
        if role != "memory_io":
            keys.add("frequency_hz")
        if not isinstance(clock, dict) or set(clock) != keys:
            raise BuildError(f"clocks.{role} must define exactly {', '.join(sorted(keys))}")
        if any(type(item) is not int for item in clock.values()):
            raise BuildError(f"clocks.{role} settings must be integers")
        if not -(1 << 30) <= clock["phase_ps"] < (1 << 30):
            raise BuildError(f"clocks.{role}.phase_ps must fit a signed 31-bit value")
        if not 1 <= clock["duty_percent"] <= 99:
            raise BuildError(f"clocks.{role}.duty_percent must be between 1 and 99")
        if role != "memory_io" and not 1000 <= clock["frequency_hz"] <= 1_000_000_000:
            raise BuildError(f"clocks.{role}.frequency_hz must be between 1000 and 1000000000")
        if role == "engine" and clock["frequency_hz"] % 1000:
            raise BuildError("clocks.engine.frequency_hz must be a multiple of 1000 for the millisecond timer")
        resolved[role] = dict(clock)
    return resolved


def clock_rtl_parameters(clocks: dict, *, profiling: bool = False) -> dict[str, int]:
    """Translate clock roles consistently for generated metadata and simulator arguments."""
    values = {}
    for role in ("engine", "memory", "communication"):
        if profiling and role == "communication":
            continue
        clock = clocks[role]
        values[f"{role.upper()}_CLOCK_FREQ"] = clock["frequency_hz"]
        values[f"{role.upper()}_PHASE_PS"] = clock["phase_ps"]
        values[f"{role.upper()}_DUTY_PERCENT"] = clock["duty_percent"]
    values["MEMORY_OUTPUT_PHASE_PS"] = clocks["memory_io"]["phase_ps"]
    values["MEMORY_OUTPUT_DUTY_PERCENT"] = clocks["memory_io"]["duty_percent"]
    return values
