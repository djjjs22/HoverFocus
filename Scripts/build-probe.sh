#!/bin/bash
#  HoverFocus — 诊断探针构建（verifier 所有）
#
#  产出 build/hf-probe。探针**链接真实核心代码**（WindowProbe / FocusController /
#  SkyLightBridge / Permissions），但所有测量都用它自己独立实现的 CGWindowList /
#  NSWorkspace 查询 —— 不用被测代码去测被测代码。
#
#  为什么不是单文件独立编译：探针要标定「App 实际会用的那条激活路径」，
#  自己重写一遍策略等于测了个赝品。
#
#  用法：bash Scripts/build-probe.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
ARCH="$(uname -m)"
MIN_MACOS="13.0"

CORE=("$ROOT"/Sources/HoverFocusCore/*.swift)
PROBE="$ROOT/Tools/hf-probe/main.swift"

if [ ! -e "$PROBE" ]; then echo "错误：找不到 $PROBE" >&2; exit 1; fi

mkdir -p "$BUILD"

echo "== 编译 hf-probe（${ARCH}, macOS ${MIN_MACOS}+） =="
swiftc \
  -O \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-name hfprobe \
  "${CORE[@]}" "$PROBE" \
  -o "$BUILD/hf-probe"

echo "== 自检 =="
"$BUILD/hf-probe" check
echo ""
echo "   probe: $BUILD/hf-probe"
