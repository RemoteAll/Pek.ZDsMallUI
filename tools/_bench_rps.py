"""HTTP 吞吐压测：N 个 keep-alive 长连接、持续 M 秒；连接被服务端关闭时自动重连。

用法: python _bench_rps.py <port> <并发连接数> <秒数> [path]
用 asyncio 单线程驱动（客户端不是瓶颈时足够；要压更高并发可多开几个进程）。
"""
import asyncio
import sys
import time

REQ = b"GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n"


async def worker(port: int, deadline: float, path: bytes, counter: list, lat: list, errs: list) -> None:
    req = REQ % path
    while time.perf_counter() < deadline:
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
        except OSError as exc:
            errs.append(f"connect: {exc}")
            return
        try:
            while time.perf_counter() < deadline:
                t0 = time.perf_counter()
                writer.write(req)
                await writer.drain()
                head = await reader.readuntil(b"\r\n\r\n")
                clen = 0
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        clen = int(line.split(b":", 1)[1].strip())
                        break
                if clen:
                    await reader.readexactly(clen)
                lat.append(time.perf_counter() - t0)
                counter[0] += 1
                if b"connection: close" in head.lower():
                    break
        except (asyncio.IncompleteReadError, ConnectionResetError, OSError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass


async def main() -> None:
    port = int(sys.argv[1])
    conns = int(sys.argv[2])
    seconds = float(sys.argv[3])
    path = (sys.argv[4] if len(sys.argv) > 4 else "/").encode()

    counter = [0]
    lat: list = []
    errs: list = []
    deadline = time.perf_counter() + seconds
    t_start = time.perf_counter()
    await asyncio.gather(*(worker(port, deadline, path, counter, lat, errs) for _ in range(conns)))
    elapsed = time.perf_counter() - t_start

    n = counter[0]
    lat.sort()

    def pct(p: float) -> float:
        if not lat:
            return 0.0
        return lat[min(len(lat) - 1, int(len(lat) * p))] * 1000

    print(
        f"conns={conns} elapsed={elapsed:.2f}s reqs={n} rps={n / elapsed:.0f} "
        f"p50={pct(0.50):.2f}ms p99={pct(0.99):.2f}ms errs={len(errs)}",
        flush=True,
    )
    if errs:
        print(f"first error: {errs[0]}", flush=True)


asyncio.run(main())
