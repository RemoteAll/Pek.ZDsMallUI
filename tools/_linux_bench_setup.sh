#!/bin/bash
set -u
# 准备 WSL 侧工程：lighting / zio / bench（zzig 已同步）
rm -rf "$HOME/work/zio" "$HOME/work/zbench"
cp -r /mnt/g/Code/Zig/Pek.ZDsMallUI/zig-pkg/zio-0.20.1-* "$HOME/work/zio"
rm -rf "$HOME/work/zio/.git"
cp -r /mnt/g/Code/Zig/Pek.ZDsMallUI/tools/linux-bench "$HOME/work/zbench"
echo "--- 目录 ---"
ls "$HOME/work"
echo "--- 构建 ---"
cd "$HOME/work/zbench" || exit 1
~/zig-x86_64-linux-0.17.1/zig build -Doptimize=ReleaseFast > /tmp/zb_build.log 2>&1
echo "BUILD_EXIT=$?"
tail -12 /tmp/zb_build.log
