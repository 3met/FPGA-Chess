
# By Emet Behrendt

import glob
import serial
import serial.tools.list_ports
import sys
import threading
import time


# Function largely taken from:
# https://stackoverflow.com/questions/12090503/listing-available-com-ports-with-python
def get_serial_port():
    """ Lists serial port names

        :raises EnvironmentError:
            On unsupported or unknown platforms
        :returns:
            A list of the serial ports available on the system
    """
    if sys.platform.startswith('win'):
        possible_ports = ['COM%s' % (i + 1) for i in range(256)]
    elif sys.platform.startswith('linux') or sys.platform.startswith('cygwin'):
        # this excludes your current terminal "/dev/tty"
        possible_ports = glob.glob('/dev/tty[A-Za-z]*')
    elif sys.platform.startswith('darwin'):
        possible_ports = glob.glob('/dev/tty.*')
    else:
        raise EnvironmentError('Unsupported platform')

    valid_ports = []
    for port in possible_ports:
        try:
            s = serial.Serial(port)
            s.close()
            valid_ports.append(port)
        except (OSError, serial.SerialException):
            pass

    target_port = None

    # Use the only port if only one port it found
    if len(valid_ports) == 1:
        print(f"Only one available port found... using '{valid_ports[0]}'")
        target_port = valid_ports[0]

    # List the ports if multiple ports are found
    elif len(valid_ports) > 1:
        print("Choose a port:")
        for i in range(len(valid_ports)):
            print(f" [{i}] - {valid_ports[i]}")

        p_idx = input()
        target_port = valid_ports[p_idx]

    # Throw error if no port can be found
    else:
        print("Error: Could not find a suitable port to connect through")
        raise serial.SerialException

    return target_port





class UART_Manager:

    def __init__(self, port, baudrate):

        # Configure the serial port
        self.ser = serial.Serial(
            port=port,
            baudrate=baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=0.001,
            write_timeout=3
        )

        # TX/RX buffers
        self.tx_queue = list()
        self.tx_queue_urgent = list()
        self.rx_buffer = list()

        self.del_event = threading.Event()

        # Crate infinite loops for sending and receiving
        self.tx_thread = threading.Thread(target=self.tx_loop)
        self.tx_thread.daemon = True
        self.tx_thread.start()
        self.rx_thread = threading.Thread(target=self.rx_loop)
        self.rx_thread.daemon = True
        self.rx_thread.start()


    # Kills TX/RX threads on deletion
    def __del__(self):
        self.del_event.set()
        self.tx_thread.join()
        self.rx_thread.join()
        self.ser.close()


    # Forever loops and transmits data from queues
    def tx_loop(self):
        while not self.del_event.is_set():

            # Write next urgent request and restart loop
            if self.tx_queue_urgent:
                print(f'Send: 0x{self.tx_queue_urgent[0].hex()} (urgent)')
                self.ser.write(self.tx_queue_urgent.pop(0))
                continue

            # Write next non-urgent request
            if self.tx_queue:
                print(f'Send: 0x{self.tx_queue[0].hex()}')
                self.ser.write(self.tx_queue.pop(0))
                continue

            time.sleep(0.001)
        

    # Adds received messages to RX data buffer
    def rx_loop(self):
        while not self.del_event.is_set():
            data_in = self.ser.read(size=1)
            if len(data_in) == 1:
                print(f'Read: 0x{data_in.hex()}')
                self.rx_buffer.append(data_in)


    # Adds a message to the transmission queue
    def transmit(self, msg, urgent=False):
        assert(type(msg) == type(bytes()))
        if urgent:
            self.tx_queue_urgent.append(msg)
        else:
            self.tx_queue.append(msg)


    # Returns the oldest received message or waits until next message arrives
    def receive_next(self):
        if rx_buffer:
            return rx_buffer.pop(0)
        else:
            return None

    

# --- Main Function ---
# main() executes when file run directly
def main():

    engine_port = get_serial_port()

    uart_manager = UART_Manager(port=engine_port, baudrate=2_000_000)

    data_out = bytes([i for i in range(0,256)])

    for _ in range(1):
        uart_manager.transmit(data_out)
        # time.sleep(0.001)

    time.sleep(10)


if __name__ == '__main__':
    main()
