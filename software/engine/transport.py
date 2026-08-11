"""Serial transport helpers for the FPGA Chess host protocol."""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from software.engine.protocol import BAUD_RATE


AUTO_SELECT_MIN_SCORE = 20
AUTO_DISCOVERY_TIMEOUT_SECONDS = 2.0
AUTO_DISCOVERY_POLL_SECONDS = 0.1
BREAK_BITS = 20


class SerialDependencyError(RuntimeError):
    """Raised when pyserial is required but unavailable."""


class SerialTimeoutError(TimeoutError):
    """Raised when not enough serial bytes arrive before a deadline."""


def _serial_module():
    try:
        import serial
    except ImportError as exc:
        raise SerialDependencyError("Install pyserial to use the FPGA serial transport.") from exc
    return serial


def _list_ports_module():
    try:
        import serial.tools.list_ports
    except ImportError as exc:
        raise SerialDependencyError("Install pyserial to list serial ports.") from exc
    return serial.tools.list_ports


@dataclass(frozen=True)
class SerialPortInfo:
    device: str
    description: str
    hwid: str = ""
    manufacturer: str = ""
    product: str = ""
    vid: int | None = None
    pid: int | None = None


def _device_identity(device: str) -> str:
    """Normalize aliases so one Linux UART does not appear as multiple candidates."""
    return os.path.normcase(os.path.realpath(device))


def _linux_serial_device_nodes() -> list[str]:
    """Recover USB-UART nodes when pyserial's sysfs metadata scan misses them."""
    if not sys.platform.startswith("linux"):
        return []

    nodes: list[str] = []
    seen: set[str] = set()
    for directory, pattern in ((Path("/dev/serial/by-id"), "*"), (Path("/dev"), "ttyUSB*"), (Path("/dev"), "ttyACM*")):
        for path in sorted(directory.glob(pattern)):
            if not path.exists():
                continue
            identity = _device_identity(str(path))
            if identity not in seen:
                nodes.append(str(path))
                seen.add(identity)
    return nodes


def list_serial_ports() -> list[SerialPortInfo]:
    list_ports = _list_ports_module()
    linux_nodes = _linux_serial_device_nodes()
    preferred_devices = {_device_identity(device): device for device in linux_nodes}
    ports: list[SerialPortInfo] = []
    known: set[str] = set()
    for port in list_ports.comports():
        identity = _device_identity(port.device)
        info = SerialPortInfo(
            device=preferred_devices.get(identity, port.device),
            description=port.description or "",
            hwid=port.hwid or "",
            manufacturer=port.manufacturer or "",
            product=port.product or "",
            vid=port.vid,
            pid=port.pid,
        )
        if identity not in known:
            ports.append(info)
            known.add(identity)
    for device in linux_nodes:
        identity = _device_identity(device)
        if identity not in known:
            # The path proves this is a Linux USB serial endpoint even when
            # pyserial could not obtain its descriptive sysfs properties.
            ports.append(SerialPortInfo(device=device, description="Linux USB serial device"))
            known.add(identity)
    return ports


def _port_score(port: SerialPortInfo) -> int:
    fields = " ".join(
        [
            port.device,
            port.description,
            port.hwid,
            port.manufacturer,
            port.product,
        ]
    ).lower()
    if "bluetooth" in fields:
        return -100

    score = 0
    if port.vid is not None and port.pid is not None:
        score += 30
    if "usb" in fields:
        score += 25
    for token in ("uart", "ftdi", "cp210", "ch340", "ch341", "pl2303", "silicon labs", "wch", "digilent"):
        if token in fields:
            score += 12
    for prefix in ("COM", "/dev/ttyUSB", "/dev/ttyACM", "/dev/serial/by-id"):
        if port.device.startswith(prefix):
            score += 8
    return score


def describe_serial_ports(ports: list[SerialPortInfo]) -> str:
    return ", ".join(f"{port.device} ({port.description or port.hwid or 'no description'})" for port in ports)


def _clear_serial_port(ports: list[SerialPortInfo]) -> str | None:
    """Return the sole high-confidence USB-UART candidate, if one is clear."""
    if not ports:
        return None
    ranked = sorted(((port, _port_score(port)) for port in ports), key=lambda item: item[1], reverse=True)
    if ranked[0][1] >= AUTO_SELECT_MIN_SCORE and (len(ranked) == 1 or ranked[0][1] >= ranked[1][1] + 10):
        return ranked[0][0].device
    return None


def get_serial_port(
    interactive: bool = False,
    env_var: str = "FPGA_CHESS_PORT",
    discovery_timeout: float = AUTO_DISCOVERY_TIMEOUT_SECONDS,
    poll_interval: float = AUTO_DISCOVERY_POLL_SECONDS,
) -> str:
    """Return an explicit port or wait briefly for a clear USB-UART candidate."""

    env_port = os.environ.get(env_var)
    if env_port:
        return env_port

    deadline = time.monotonic() + max(0.0, discovery_timeout)
    ports: list[SerialPortInfo] = []
    while True:
        ports = list_serial_ports()
        selected = _clear_serial_port(ports)
        if selected is not None:
            return selected
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(max(0.0, poll_interval), remaining))

    if not ports:
        raise SerialDependencyError(f"No serial ports were found after {max(0.0, discovery_timeout):g} seconds.")

    if not interactive:
        raise SerialDependencyError(
            f"Could not uniquely auto-detect the FPGA UART port. "
            f"Pass --port or set {env_var}. Available: {describe_serial_ports(ports)}"
        )

    print("Choose a port:")
    for idx, port in enumerate(ports):
        print(f" [{idx}] - {port.device} ({port.description})")
    while True:
        choice = input("> ").strip()
        try:
            index = int(choice)
        except ValueError:
            print("Enter a numeric port index.")
            continue
        if 0 <= index < len(ports):
            return ports[index].device
        print("Port index out of range.")


class SerialByteTransport:
    """Small synchronous byte transport around pyserial."""

    def __init__(
        self,
        port: str | None = None,
        baudrate: int = BAUD_RATE,
        read_timeout: float = 0.05,
        write_timeout: float = 3.0,
        interactive_port_select: bool = False,
    ) -> None:
        serial = _serial_module()
        self.port = port or get_serial_port(interactive=interactive_port_select)
        self.baudrate = baudrate
        self._write_lock = threading.Lock()
        self._serial = serial.serial_for_url(
            self.port,
            baudrate=self.baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=read_timeout,
            write_timeout=write_timeout,
        )

    @property
    def is_open(self) -> bool:
        return bool(self._serial.is_open)

    def close(self) -> None:
        self._serial.close()

    def write(self, data: bytes) -> None:
        if not isinstance(data, bytes):
            raise TypeError("SerialByteTransport.write expects bytes")
        with self._write_lock:
            written = self._serial.write(data)
            self._serial.flush()
        if written != len(data):
            raise SerialTimeoutError(f"Only wrote {written}/{len(data)} bytes")

    def read_exact(self, size: int, timeout: float = 10.0) -> bytes:
        if size < 0:
            raise ValueError("size must be nonnegative")
        deadline = time.monotonic() + timeout
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SerialTimeoutError(f"Timed out waiting for {size} bytes; got {len(data)}")
            chunk = self._serial.read(size - len(data))
            if chunk:
                data.extend(chunk)
        return bytes(data)

    def read_available(self, max_size: int = 4096) -> bytes:
        waiting = getattr(self._serial, "in_waiting", 0)
        if waiting <= 0:
            return b""
        return self._serial.read(min(waiting, max_size))

    def reset_input_buffer(self) -> None:
        self._serial.reset_input_buffer()

    def reset_output_buffer(self) -> None:
        self._serial.reset_output_buffer()

    def send_break(self, duration: float = 0.01) -> None:
        if duration < 0:
            raise ValueError("BREAK duration must be nonnegative")
        # Enforce the receiver's protocol threshold even if a caller asks for
        # a shorter pulse. The generous default also tolerates adapter timing.
        actual_duration = max(duration, BREAK_BITS / self.baudrate)
        self._serial.send_break(actual_duration)
        # Some USB-UART adapters otherwise apply the first queued start bit
        # immediately after BREAK. Give the FPGA receiver an observable
        # mark-high interval so it can leave BREAK before the next byte.
        time.sleep(max(2.0 / self.baudrate, 0.001))

    def __enter__(self) -> "SerialByteTransport":
        return self

    def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
        self.close()


def _parse_hex_bytes(text: str) -> bytes:
    compact = "".join(text.split())
    if compact.startswith("0x"):
        compact = compact[2:]
    if len(compact) % 2:
        compact = "0" + compact
    return bytes.fromhex(compact)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Send raw bytes to the FPGA Chess serial port.")
    parser.add_argument("--port", help="Serial port, for example COM5 or /dev/ttyUSB0.")
    parser.add_argument("--baud", type=int, default=BAUD_RATE, help=f"Baud rate. Default: {BAUD_RATE}.")
    parser.add_argument("--choose-port", action="store_true", help="Prompt for a port if auto-detection is ambiguous.")
    parser.add_argument("--read", type=int, default=0, help="Number of response bytes to read after sending.")
    parser.add_argument("hex", nargs="?", default="", help="Hex bytes to send, for example '00' or '01ff'.")
    args = parser.parse_args(argv)

    try:
        payload = _parse_hex_bytes(args.hex) if args.hex else b""
        with SerialByteTransport(args.port, args.baud, interactive_port_select=args.choose_port) as transport:
            if payload:
                transport.write(payload)
            if args.read:
                print(transport.read_exact(args.read).hex())
    except (SerialDependencyError, SerialTimeoutError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
