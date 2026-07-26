import os
import unittest
from unittest import mock

from software.engine.transport import SerialDependencyError, SerialPortInfo, get_serial_port


class SerialPortDetectionTests(unittest.TestCase):
    def test_environment_port_takes_precedence(self):
        with mock.patch.dict(os.environ, {"FPGA_CHESS_PORT": "COM42"}):
            self.assertEqual(get_serial_port(), "COM42")

    def test_single_port_is_selected(self):
        ports = [SerialPortInfo(device="/dev/ttyUSB0", description="USB Serial")]
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("software.engine.transport.list_serial_ports", return_value=ports):
            self.assertEqual(get_serial_port(), "/dev/ttyUSB0")

    def test_clear_usb_uart_candidate_is_selected(self):
        ports = [
            SerialPortInfo(device="COM1", description="Standard Serial Port"),
            SerialPortInfo(
                device="COM5",
                description="USB Serial Port",
                hwid="USB VID:PID=0403:6001",
                manufacturer="FTDI",
                product="USB UART",
                vid=0x0403,
                pid=0x6001,
            ),
        ]
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("software.engine.transport.list_serial_ports", return_value=ports):
            self.assertEqual(get_serial_port(), "COM5")

    def test_ambiguous_ports_raise_in_headless_mode(self):
        ports = [
            SerialPortInfo(device="/dev/ttyUSB0", description="USB Serial", vid=1, pid=1),
            SerialPortInfo(device="/dev/ttyUSB1", description="USB Serial", vid=2, pid=2),
        ]
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("software.engine.transport.list_serial_ports", return_value=ports):
            with self.assertRaises(SerialDependencyError):
                get_serial_port(interactive=False)


if __name__ == "__main__":
    unittest.main()
