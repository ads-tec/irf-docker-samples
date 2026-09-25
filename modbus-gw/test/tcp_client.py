# Test helper, tested with pymodbus 3.15 (pip install pymodbus pyserial)
import sys, time
from pymodbus.client import ModbusTcpClient
host, port = sys.argv[1], int(sys.argv[2])
c = ModbusTcpClient(host, port=port, timeout=3)
assert c.connect(), "TCP connect failed"
t = time.time(); r = c.read_holding_registers(0, count=10, device_id=1); dt = (time.time() - t) * 1000
print("read  HR0-9 unit1:", r.registers if not r.isError() else r, f"({dt:.0f} ms)")
w = c.write_register(3, 4242, device_id=1); print("write HR3=4242:", "ok" if not w.isError() else w)
r = c.read_holding_registers(3, count=1, device_id=1); print("read  HR3:", r.registers if not r.isError() else r)
r = c.read_holding_registers(0, count=1, device_id=7); print("read  unit7 (absent):", r)
c.close()
