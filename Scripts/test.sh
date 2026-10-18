#!/bin/bash
#  HoverFocus — 单元测试（verifier 所有）
#
#  为什么不用 swift test / XCTest：
#   1. 本机 SwiftPM 损坏 —— swift build / swift test / swift package 全部在编译
#      manifest 时链接失败（libPackageDescription.dylib 与 swiftmodule 版本不一致）；
#   2. 本机只有 Command Line Tools，没有可用的 XCTest。
#  所以这里把**所有源码 + 测试源码编进同一个模块**，用 swiftc 一次编译出可执行文件。
#  因此测试文件里绝对不要写 `import HoverFocusCore`。
#
#  用法：bash Scripts/test.sh
#  退出码：0 = 全绿；1 = 有失败（含契约 16 步覆盖不全）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
ARCH="$(uname -m)"
MIN_MACOS="13.0"

CORE=("$ROOT"/Sources/HoverFocusCore/*.swift)
# 测试额外编入的 **App 层**文件（不属于核心逻辑，单独列出便于一眼审计）。
# 为什么需要：IconState / StatusIcon.state·symbolName 是纯函数式的状态映射，
# 但定义在 Sources/HoverFocus/（App 层），默认不在测试编译单元里。
# 备注：把 UI 语义挪进 Core 是架构上更错的方向，所以选择「测试多编两个文件」。
# 将来 App 层文件多到测不动时，应当停下来报告，而不是为了测试去拆 UI 代码。
APP_STATE_SRC=(
  "$ROOT/Sources/HoverFocus/AppInfo.swift"
  "$ROOT/Sources/HoverFocus/StatusIcon.swift"
)
SUPPORT=("$ROOT"/Tests/TestSupport/*.swift)
RUNNER=("$ROOT"/Tests/TestRunner/*.swift)

if [ ! -e "${CORE[0]}" ]; then echo "错误：找不到 Sources/HoverFocusCore/*.swift" >&2; exit 1; fi
if [ ! -e "${RUNNER[0]}" ]; then echo "错误：找不到 Tests/TestRunner/*.swift" >&2; exit 1; fi
if ! ls "$ROOT"/Tests/TestRunner/main.swift >/dev/null 2>&1; then
  echo "错误：缺少 Tests/TestRunner/main.swift（顶层代码只能写在 main.swift 里）" >&2; exit 1
fi

mkdir -p "$BUILD"
BIN="$BUILD/run-tests"

echo "== 编译测试（${ARCH}, macOS ${MIN_MACOS}+，单模块，无 SwiftPM） =="
echo "   核心源码：${#CORE[@]} 个"
echo "   App 层（仅状态映射）：${#APP_STATE_SRC[@]} 个"
echo "   测试替身：${#SUPPORT[@]} 个"
echo "   测试用例：${#RUNNER[@]} 个"

swiftc \
  -O \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-name HoverFocusTests \
  "${CORE[@]}" "${APP_STATE_SRC[@]}" "${SUPPORT[@]}" "${RUNNER[@]}" \
  -o "$BIN"

echo "== 运行 =="
# set -e 会让测试失败直接以 1 退出 —— 这是故意的：测试红了必须让人看见。
"$BIN"
