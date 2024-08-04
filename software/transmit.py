
import serial
import time
import serial.tools.list_ports
import sys
import glob


# Function taken from
# https://stackoverflow.com/questions/12090503/listing-available-com-ports-with-python
def serial_ports():
    """ Lists serial port names

        :raises EnvironmentError:
            On unsupported or unknown platforms
        :returns:
            A list of the serial ports available on the system
    """
    if sys.platform.startswith('win'):
        ports = ['COM%s' % (i + 1) for i in range(256)]
    elif sys.platform.startswith('linux') or sys.platform.startswith('cygwin'):
        # this excludes your current terminal "/dev/tty"
        ports = glob.glob('/dev/tty[A-Za-z]*')
    elif sys.platform.startswith('darwin'):
        ports = glob.glob('/dev/tty.*')
    else:
        raise EnvironmentError('Unsupported platform')

    result = []
    for port in ports:
        try:
            s = serial.Serial(port)
            s.close()
            result.append(port)
        except (OSError, serial.SerialException):
            pass
    return result


def transmit(port):

    # Configure the serial port
    ser = serial.Serial(
        port=port,
        # baudrate=115200,
        baudrate=12_000_000,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=1
    )

    # Data to send
    data = bytes([int(input(), 2),])
    # data = (1000 * 'xasdfasdfasdg').encode()
    print(len(data))
    print(data.hex())

    # return

    # Send data
    ser.write(data)

    ser.close()


if __name__ == '__main__':

    ports = serial_ports()

    # Use the only port if only one port it found
    if len(ports) == 1:
        print(f"Only one available port found... using '{ports[0]}'")
        transmit(ports[0])

    # List the ports if multiple ports are found
    elif len(ports) > 1:
        print("Choose a port:")
        for i in range(len(ports)):
            print(f"[{i}] - {ports[i]}")

        p_idx = input()
        transmit(ports[p_idx])

    # Throw error if no port can be found
    else:
        print("Error: Could not find a suitable port to connect through")
        raise serial.SerialException
