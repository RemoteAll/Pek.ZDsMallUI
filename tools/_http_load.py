"""真实请求压测：每个连接发一个 GET，断言拿到 200，然后保持连接。

用来验证「协程栈压到 32 KiB 后，走完整解析+响应路径不会 Stack overflow」。
"""
import socket
import sys
import time

port = int(sys.argv[1])
count = int(sys.argv[2])
hold = int(sys.argv[3]) if len(sys.argv) > 3 else 60

REQ = b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n"

socks = []
ok = 0
bad = 0
for i in range(count):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.sendall(REQ)
        data = s.recv(4096)
        if b"200" in data.split(b"\r\n", 1)[0]:
            ok += 1
            socks.append(s)
        else:
            bad += 1
            print(f"BAD at {i}: {data[:60]!r}", flush=True)
            s.close()
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL at {i}: {exc}", flush=True)
        break

print(f"OK {ok} / BAD {bad}", flush=True)
sys.stdout.flush()
time.sleep(hold)
for s in socks:
    s.close()
print("CLOSED", flush=True)
