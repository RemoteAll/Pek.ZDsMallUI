"""业务写接口压测：POST /biz/config/updatebase 多次，统计单次耗时。

用法: python _bench_write.py <port> <次数>
用于对比 SQLite journal_mode（WAL vs DELETE）在真实业务写路径上的差异。
"""
import http.client
import sys
import time

port = int(sys.argv[1])
count = int(sys.argv[2]) if len(sys.argv) > 2 else 200

body = b"SiteName=ZDsMallUI&SiteUrl=&AdminEmail=&LogoUrl=&Copyright=&IcpNumber=&PageSize=20"
headers = {
    "Content-Type": "application/x-www-form-urlencoded",
    "Content-Length": str(len(body)),
    "Cookie": "",
}

conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
times = []
bad = 0
for i in range(count):
    t0 = time.perf_counter()
    conn.request("POST", "/biz/config/updatebase", body=body, headers=headers)
    resp = conn.getresponse()
    resp.read()
    times.append((time.perf_counter() - t0) * 1000)
    if resp.status not in (200, 302):
        bad += 1

times.sort()
n = len(times)
print(
    f"count={n} bad={bad} total={sum(times):.1f}ms "
    f"avg={sum(times) / n:.2f}ms p50={times[n // 2]:.2f}ms p99={times[min(n - 1, int(n * 0.99))]:.2f}ms",
    flush=True,
)
conn.close()
