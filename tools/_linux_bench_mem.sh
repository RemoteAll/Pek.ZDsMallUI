#!/bin/bash
set -u
ulimit -n 200000 2>/dev/null
ulimit -n
cd "$HOME/work/zbench" || exit 1
./zig-out/bin/zbench 18401 2 32 > /tmp/zbench2.log 2>&1 &
SRV=$!
sleep 3
echo "--- baseline ---"
grep -E "VmRSS" /proc/"$SRV"/status
python3 /mnt/g/Code/Zig/Pek.ZDsMallUI/tools/_hold_conns.py 18401 5000 75 > /tmp/hold.log 2>&1 &
HOLD=$!
sleep 40
echo "--- established ---"
ss -tn state established "( sport = :18401 )" 2>/dev/null | wc -l
echo "--- after 5000 conns ---"
grep -E "VmRSS|Threads" /proc/"$SRV"/status
grep -a "CONNECTED" /tmp/hold.log
wait $HOLD 2>/dev/null
echo "--- after close ---"
grep -E "VmRSS" /proc/"$SRV"/status
kill "$SRV" 2>/dev/null
