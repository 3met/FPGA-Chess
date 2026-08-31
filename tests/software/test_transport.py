import os
import unittest
from unittest import mock

from software.engine.transport import SerialByteTransport, SerialDependencyError, SerialPortInfo, get_serial_port, list_serial_ports


class SerialPortListingTests(unittest.TestCase):
    def test_linux_device_node_fills_a_pyserial_enumeration_gap(self):
        list_ports = mock.Mock()
        list_ports.comports.return_value = []
        with mock.patch("software.engine.transport._list_ports_module", return_value=list_ports), \
                mock.patch("software.engine.transport._linux_serial_device_nodes", return_value=["/dev/ttyUSB0"]):
            ports = list_serial_ports()

        self.assertEqual(ports, [SerialPortInfo(device="/dev/ttyUSB0", description="Linux USB serial device")])

    def test_linux_alias_replaces_the_renumberable_pyserial_path(self):
        detected = mock.Mock(
            device="/dev/ttyUSB0", description="USB Serial", hwid="",
            manufacturer="", product="", vid=0x0403, pid=0x6001,
        )
        list_ports = mock.Mock()
        list_ports.comports.return_value = [detected]
        with mock.patch("software.engine.transport._list_ports_module", return_value=list_ports), \
                mock.patch("software.engine.transport._linux_serial_device_nodes", return_value=["/dev/serial/by-id/usb-uart"]), \
                mock.patch("software.engine.transport._device_identity", return_value="same-device"):
            ports = list_serial_ports()

        self.assertEqual(len(ports), 1)
        self.assertEqual(ports[0].device, "/dev/serial/by-id/usb-uart")


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
                get_serial_port(interactive=False, discovery_timeout=0)

    def test_lone_generic_system_serial_port_is_not_guessed(self):
        ports = [SerialPortInfo(device="COM1", description="Standard Serial Port")]
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("software.engine.transport.list_serial_ports", return_value=ports):
            with self.assertRaises(SerialDependencyError):
                get_serial_port(interactive=False, discovery_timeout=0)

    def test_detection_retries_until_a_usb_uart_appears(self):
        port = SerialPortInfo(device="/dev/ttyUSB0", description="USB Serial")
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch("software.engine.transport.list_serial_ports", side_effect=[[], [port]]) as listing, \
                mock.patch("software.engine.transport.time.sleep") as sleep:
            selected = get_serial_port(discovery_timeout=1.0, poll_interval=0.0)

        self.assertEqual(selected, "/dev/ttyUSB0")
        self.assertEqual(listing.call_count, 2)
        sleep.assert_called_once_with(0.0)


class SerialBreakTests(unittest.TestCase):
    def test_break_waits_for_idle_high_recovery(self):
        serial_port = mock.Mock()
        transport = object.__new__(SerialByteTransport)
        transport.baudrate = 2_000_000
        transport._serial = serial_port

        with mock.patch("software.engine.transport.time.sleep") as sleep:
            transport.send_break(0.01)

        serial_port.send_break.assert_called_once_with(0.01)
        sleep.assert_called_once_with(0.001)

    def test_break_enforces_receiver_threshold(self):
        serial_port = mock.Mock()
        transport = object.__new__(SerialByteTransport)
        transport.baudrate = 2_000_000
        transport._serial = serial_port

        with mock.patch("software.engine.transport.time.sleep"):
            transport.send_break(0.0)

        serial_port.send_break.assert_called_once_with(20 / 2_000_000)


if __name__ == "__main__":
    unittest.main()
