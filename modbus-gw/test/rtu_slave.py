# Test helper, tested with pymodbus 3.15 (pip install pymodbus pyserial)
# Modbus RTU slave simulator: unit 1, holding registers 0..9 = 100..109
import sys
from pymodbus.datastore import ModbusDeviceContext, ModbusSequentialDataBlock, ModbusServerContext
from pymodbus.server import StartSerialServer
from pymodbus import FramerType
port, baud = sys.argv[1], int(sys.argv[2])
dev = ModbusDeviceContext(hr=ModbusSequentialDataBlock(1, [100 + i for i in range(20)]))
ctx = ModbusServerContext(devices={1: dev}, single=False)
StartSerialServer(context=ctx, framer=FramerType.RTU, port=port, baudrate=baud, bytesize=8, parity="N", stopbits=1)
