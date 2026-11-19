"""保持 N 个空闲 TCP 连接，用于对比不同运行时的每连接内存。"""
import socket
import sys
import time

port = int(sys.argv[1])
count = int(sys.argv[2])
hold = int(sys.argv[3]) if len(sys.argv) > 3 else 120

socks = []
for i in range(count):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        socks.append(s)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL at {i}: {exc}", flush=True)
        break

print(f"CONNECTED {len(socks)}", flush=True)
sys.stdout.flush()
time.sleep(hold)
for s in socks:
    s.close()
print("CLOSED", flush=True)
