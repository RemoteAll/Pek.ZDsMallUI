#!/bin/bash
set -u
cd "$HOME/work/zbench" || exit 1
./zig-out/bin/zbench 18400 2 32 > /tmp/zbench.log 2>&1 &
SRV=$!
sleep 3
if ! kill -0 "$SRV" 2>/dev/null; then
    echo "SERVER DIED"
    cat /tmp/zbench.log
    exit 1
fi
echo "--- baseline ---"
grep -E "VmRSS|Threads" /proc/"$SRV"/status
echo "--- rps 32 conns ---"
python3 /mnt/g/Code/Zig/Pek.ZDsMallUI/tools/_bench_rps.py 18400 32 8
echo "--- rps 64 conns ---"
python3 /mnt/g/Code/Zig/Pek.ZDsMallUI/tools/_bench_rps.py 18400 64 8
echo "--- after ---"
grep -E "VmRSS|Threads" /proc/"$SRV"/status
kill "$SRV" 2>/dev/null
