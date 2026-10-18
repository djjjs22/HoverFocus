#!/bin/bash
#  HoverFocus — 权限与运行环境体检（verifier 所有）
#
#  为什么单独一个脚本：本机的「权限」不是一个布尔值，而是四个互相独立的信号，
#  而且**授权对象是具体的二进制**（TCC 按 codesign 身份/责任进程判定），
#  所以「探针没权限」不等于「HoverFocus 没权限」，反之亦然。
#  这个脚本把两者分开报，避免把环境事实误读成产品缺陷。
#
#  用法：bash Scripts/verify-permissions.sh
#  退出码：0 = HoverFocus 的鼠标监听能起来（功能可用，精度可能降级）
#          2 = 鼠标监听起不来（需要授权才能用）
#  ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/build/hf-probe"
APP_BIN="$ROOT/build/HoverFocus.app/Contents/MacOS/HoverFocus"

echo "════════════════════════════════════════════════════════════"
echo " HoverFocus 权限与运行环境体检"
echo "════════════════════════════════════════════════════════════"

echo ""
echo "【1】探针自身（build/hf-probe）的系统权限"
echo "    注意：探针与 HoverFocus 是两个不同的二进制，TCC 授权互不影响。"
if [ ! -x "$PROBE" ]; then
  echo "  build/hf-probe 不存在，先构建…"
  bash "$ROOT/Scripts/build-probe.sh" >/dev/null 2>&1 || { echo "  ❌ 构建失败"; exit 2; }
fi
"$PROBE" check | sed 's/^/  /'

echo ""
echo "【2】HoverFocus.app 自身的权限与启动状态"
echo "    判据用 App 自己的 --selftest（它会真的把 driver 起一次再停掉）。"
if [ ! -x "$APP_BIN" ]; then
  echo "  build/HoverFocus.app 不存在，先构建…"
  bash "$ROOT/Scripts/build.sh" >/dev/null 2>&1 || { echo "  ❌ 构建失败"; exit 2; }
fi

SELFTEST=$("$APP_BIN" --selftest 2>/dev/null | tail -1)
if [ -z "$SELFTEST" ]; then
  echo "  ❌ --selftest 没有输出，无法判断"
  exit 2
fi

field() { printf '%s' "$SELFTEST" | grep -o "\"$1\":[^,}]*" | cut -d: -f2; }
AX=$(field axTrusted)
DRIVER_STARTED=$(field driverStarted)
DRIVER_ERROR=$(field driverError)
STATUS_ITEM=$(field statusItemCreated)
HIT_MODE=$(field hitTestMode)

echo "  菜单栏图标创建成功 (statusItemCreated) = ${STATUS_ITEM:-未知}"
echo "  辅助功能授权 (axTrusted)              = ${AX:-未知}"
echo "  鼠标监听启动成功 (driverStarted)      = ${DRIVER_STARTED:-未知}"
echo "  鼠标监听错误 (driverError)            = ${DRIVER_ERROR:-null}"
echo "  命中测试模式 (hitTestMode)            = ${HIT_MODE:-未知（旧版本无此字段）}"
echo ""
echo "  说明："
echo "   · 事件源=轮询(MousePoller) 时**零权限可用**，axTrusted=false 也能正常工作，"
echo "     只是命中测试会走窗口列表降级模式（重叠/圆角窗口可能判错）；"
echo "   · axTrusted=true 时命中测试升级为 AX 精确模式；"
echo "   · 两者都不影响「切前台不置顶」（走私有 SkyLight）。"

if [ "$DRIVER_STARTED" = "true" ]; then
  echo ""
  echo "  结论：鼠标监听可启动 → 功能可用。"
  if [ "$AX" != "true" ]; then
    echo "        （当前为降级命中测试模式，精度低于授权后；这不是故障）"
  fi
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi

echo ""
echo "  结论：鼠标监听起不来（driverError=${DRIVER_ERROR:-未知}）→ 需要处理。"
echo ""
echo "  授权方式："
echo "   1. 打开 系统设置 → 隐私与安全性 → 辅助功能"
echo "   2. 把 build/HoverFocus.app 拖进去 / 勾选它"
echo "   3. 重新运行本脚本确认"
echo "   提示：若用 ad-hoc 签名，每次重新构建 cdhash 都会变，授权会失效；"
echo "         可先跑 bash Scripts/make-signing-cert.sh 用固定证书签名。"
echo "════════════════════════════════════════════════════════════"
exit 2
