#!/bin/bash
#  HoverFocus — 端到端悬停验证
#
#  验证目标：把指针停在一个**非前台**窗口上 → 停满 dwell → 该窗口所属 App 变成前台，
#            且默认模式（只切焦点）**不改变窗口叠放顺序**。
#
#  为什么必须用自己起的靶子 App：不能拿用户正在用的窗口做实验 —— 那会真的抢走
#  用户的键盘焦点、还可能改坏用户的窗口布局。所以本脚本起两个自己的窗口 App（一左一右）。
#
#  两条路径：
#   · 完整端到端：需要 HoverFocus 本体已获「辅助功能」授权（菜单栏 App + 真实鼠标监听）；
#   · 核心链路参考：不需要任何授权（真实 WindowProbe + FocusController + MousePoller + FocusEngine），
#     但**不含菜单栏 App 本体**，所以只能当参考，不能当端到端结论。
#
#  安全约定（**2026-10-18 修订，务必遵守**）：
#   · ⛔ 绝不按进程名 kill HoverFocus（`pkill -x HoverFocus` / `pkill -f HoverFocus`）。
#     /Applications/HoverFocus.app 是**用户日常在用的工具**，按名杀会把用户那份一起杀掉
#     —— 团队里已经因为这条出过一次事故（详见 docs/VERIFICATION.md §11）。
#   · 只 kill **本脚本自己启动的那个 pid**（${HOVERFOCUS_PID}，按 build 路径定位）。
#   · 本脚本只在「用户那份没在跑」时才做完整端到端（两份实例会互抢焦点，且用户配置可能是
#     置顶模式，会让「z 序不变」的断言失去意义）。用户那份在跑 → 跳过，绝不碰它。
#   · 结束时一定把指针移回原处、关掉自己起的靶子 App；
#     若用户实例原本在跑而中途消失，按规则 `open /Applications/HoverFocus.app` 还回去。
#   · 只有本脚本允许退出 AutoFocus（它会和 HoverFocus 互抢焦点），**测完不会自动重开**。
#
#  用法：bash Scripts/e2e-hover-test.sh
#
#  退出码：
#     0 = 端到端 PASS
#     1 = 端到端 FAIL
#     2 = 权限未授予，无法验证（**不是 PASS**，也绝不伪装成 PASS）
#     3 = 前置条件不满足（AutoFocus 退不掉 / 构建失败 / 靶子起不来 / 用户实例在运行）
#  ─────────────────────────────────────────────────────────────────────────
set -uo pipefail   # 故意不用 -e：要收集完所有检查项再汇总

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
PROBE="$BUILD/hf-probe"
APP="$BUILD/HoverFocus.app"
APP_BIN="$APP/Contents/MacOS/HoverFocus"
ARCH="$(uname -m)"

PASSES=0; FAILS=0; SKIPS=0
pass() { echo "  ✅ $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  ❌ $1"; FAILS=$((FAILS + 1)); }
skip() { echo "  ⏭  $1"; SKIPS=$((SKIPS + 1)); }
hdr()  { echo ""; echo "【$1】"; }

# 用户日常在用的那份（绝不按名杀，只在必要时还回去）
USER_APP="/Applications/HoverFocus.app"
USER_APP_BIN="$USER_APP/Contents/MacOS/HoverFocus"

TARGET_A_PID=""; TARGET_B_PID=""
HOVERFOCUS_PID=""          # ← 只 kill 这个（本脚本自己启动的实例）
ORIGIN_X=""; ORIGIN_Y=""; AUTOFOCUS_WAS_RUNNING=0
WAS_RUNNING=0              # 用户那份在脚本开始时是否在跑

cleanup() {
  echo ""
  echo "【清理】"
  if [ -n "$ORIGIN_X" ]; then
    "$PROBE" warp "$ORIGIN_X" "$ORIGIN_Y" >/dev/null 2>&1 && echo "  指针已恢复到 (${ORIGIN_X}, ${ORIGIN_Y})"
  fi

  # 只杀自己起的那个 pid。**绝不按进程名杀** —— /Applications 那份是用户的日常工具。
  if [ -n "$HOVERFOCUS_PID" ] && kill -0 "$HOVERFOCUS_PID" 2>/dev/null; then
    kill "$HOVERFOCUS_PID" 2>/dev/null && echo "  已停止本次启动的 HoverFocus（pid ${HOVERFOCUS_PID}）"
  else
    echo "  本次启动的 HoverFocus 已不在运行"
  fi

  [ -n "$TARGET_A_PID" ] && kill "$TARGET_A_PID" 2>/dev/null && echo "  已关闭靶子 A"
  [ -n "$TARGET_B_PID" ] && kill "$TARGET_B_PID" 2>/dev/null && echo "  已关闭靶子 B"

  # 用户那份原本在跑、但中途不在了 → 按规则还回去（我们没杀它，可能是别的原因没的）
  if [ "$WAS_RUNNING" = "1" ] && [ -x "$USER_APP_BIN" ] && ! pgrep -f "$USER_APP_BIN" >/dev/null 2>&1; then
    echo "  ⚠️  用户实例原本在运行但已消失，按规则还回去：open $USER_APP"
    open "$USER_APP" >/dev/null 2>&1 || true
  fi

  if [ "$AUTOFOCUS_WAS_RUNNING" = "1" ]; then
    echo "  ⚠️  本脚本退出了 AutoFocus，**不会自动重开**（用户要求）。需要时请手动启动。"
  fi
}
trap cleanup EXIT

echo "════════════════════════════════════════════════════════════"
echo " HoverFocus 端到端悬停验证"
echo "════════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────
hdr "1/6 构建前置产物"

if [ ! -x "$PROBE" ]; then
  echo "  build/hf-probe 不存在，先构建…"
  bash "$ROOT/Scripts/build-probe.sh" >/dev/null 2>&1 || { echo "  ❌ hf-probe 构建失败"; exit 3; }
fi
[ -x "$PROBE" ] && pass "hf-probe 就绪" || { fail "hf-probe 缺失"; exit 3; }

TARGET_BIN="$BUILD/hf-target/hf-target"
mkdir -p "$BUILD/hf-target"
if [ ! -x "$TARGET_BIN" ] || [ "$ROOT/Tools/hf-target/main.swift" -nt "$TARGET_BIN" ]; then
  echo "  编译靶子 App…"
  swiftc -O -target "${ARCH}-apple-macos13.0" "$ROOT/Tools/hf-target/main.swift" -o "$TARGET_BIN" \
    || { echo "  ❌ 靶子 App 编译失败"; exit 3; }
fi
for name in HFTargetA HFTargetB; do
  bundle="$BUILD/$name.app"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$TARGET_BIN" "$bundle/Contents/MacOS/$name"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>local.hoverfocus.$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
done
pass "靶子 App（HFTargetA / HFTargetB）已就绪"

if [ ! -x "$APP_BIN" ]; then
  echo "  build/HoverFocus.app 不存在，先构建…"
  bash "$ROOT/Scripts/build.sh" >/dev/null 2>&1 || echo "  ⚠️  HoverFocus 构建失败（本轮只能跑核心链路参考）"
fi

# ─────────────────────────────────────────────────────────────
hdr "2/6 AutoFocus 必须已退出（它会和 HoverFocus 互抢焦点）"

if pgrep -x AutoFocus >/dev/null 2>&1; then
  AUTOFOCUS_WAS_RUNNING=1
  echo "  AutoFocus 正在运行（pid $(pgrep -x AutoFocus | tr '\n' ' ')），按用户授权退出它…"
  osascript -e 'tell application "AutoFocus" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x AutoFocus >/dev/null 2>&1 || break; sleep 0.25; done
  if pgrep -x AutoFocus >/dev/null 2>&1; then
    pkill -x AutoFocus 2>/dev/null || true
    sleep 0.5
  fi
  if pgrep -x AutoFocus >/dev/null 2>&1; then
    fail "AutoFocus 退不掉，会和 HoverFocus 互抢焦点 → 无法做可信的端到端验证"
    exit 3
  fi
  pass "AutoFocus 已退出（测完不会自动重开）"
else
  pass "AutoFocus 本来就没在运行"
fi

# 记录「用户那份是否在跑」：它决定要不要做完整端到端，以及结束时要不要还回去。
# 注意：只按 **/Applications 路径** 判断，绝不按进程名 —— 按名会把我们自己的 build 实例也算进去。
if [ -x "$USER_APP_BIN" ] && pgrep -f "$USER_APP_BIN" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "  检测到用户日常实例 $USER_APP 正在运行（pid $(pgrep -f "$USER_APP_BIN" | tr '\n' ' ')）"
  echo "  → 本脚本不会停止/重启它；若它中途消失，结束时按规则还回去。"
fi

# ─────────────────────────────────────────────────────────────
# 顺序很重要：--selftest 会短暂起 NSApplication，可能把前台 App 换掉。
# 必须**在起靶子之前**跑完权限检查，否则会污染悬停场景。
hdr "3/6 HoverFocus 本体的辅助功能权限"

HF_AX_TRUSTED="unknown"
HF_DRIVER_STARTED="unknown"
HF_SELFTEST=""
if [ -x "$APP_BIN" ]; then
  HF_SELFTEST=$("$APP_BIN" --selftest 2>/dev/null | tail -1)
  HF_AX_TRUSTED=$(printf '%s' "$HF_SELFTEST" | grep -o '"axTrusted":[^,}]*' | cut -d: -f2)
  HF_DRIVER_STARTED=$(printf '%s' "$HF_SELFTEST" | grep -o '"driverStarted":[^,}]*' | cut -d: -f2)
  echo "  HoverFocus --selftest axTrusted=${HF_AX_TRUSTED:-未知} driverStarted=${HF_DRIVER_STARTED:-未知}"
  echo "  selftest 摘要：$(printf '%s' "$HF_SELFTEST" | cut -c1-220)…"
  echo "  说明：现在默认用 MousePoller（零权限），所以 axTrusted=false 也可能功能可用；"
  echo "        真正的门槛是「鼠标监听能不能起来」，即 driverStarted。"
else
  echo "  ⚠️  HoverFocus.app 不存在，无法查它的启动状态"
fi

# ─────────────────────────────────────────────────────────────
hdr "4/6 起靶子窗口（左 A / 右 B，用我们自己的 App）"

MOUSE_LINE=$("$PROBE" hit 2>/dev/null | grep -m1 '^POINT=' | cut -d= -f2)
ORIGIN_X="${MOUSE_LINE%,*}"; ORIGIN_Y="${MOUSE_LINE#*,}"
echo "  指针原位：(${ORIGIN_X}, ${ORIGIN_Y})"

HF_TARGET_TITLE="HFTargetA" HF_TARGET_X=120 HF_TARGET_Y=200 HF_TARGET_W=560 HF_TARGET_H=460 \
  "$BUILD/HFTargetA.app/Contents/MacOS/HFTargetA" >"$BUILD/hf-target-a.log" 2>&1 &
TARGET_A_PID=$!
sleep 1.2
HF_TARGET_TITLE="HFTargetB" HF_TARGET_X=1300 HF_TARGET_Y=200 HF_TARGET_W=560 HF_TARGET_H=460 \
  "$BUILD/HFTargetB.app/Contents/MacOS/HFTargetB" >"$BUILD/hf-target-b.log" 2>&1 &
TARGET_B_PID=$!
sleep 1.8

B_WINDOW=$("$PROBE" list | awk '/OWNER=HFTargetB/ && /LAYER=0/ {for(i=1;i<=NF;i++) if($i ~ /^ID=/){sub("ID=","",$i); print $i; exit}}')
A_WINDOW=$("$PROBE" list | awk '/OWNER=HFTargetA/ && /LAYER=0/ {for(i=1;i<=NF;i++) if($i ~ /^ID=/){sub("ID=","",$i); print $i; exit}}')
if [ -z "$B_WINDOW" ] || [ -z "$A_WINDOW" ]; then
  fail "靶子窗口没起来（A=${A_WINDOW} B=${B_WINDOW}）→ 无法验证"
  exit 3
fi
pass "靶子窗口就绪：A=#${A_WINDOW}(pid ${TARGET_A_PID})  B=#${B_WINDOW}(pid ${TARGET_B_PID})"

# 让 A 当前台、B 在它后面（这样 B 才是「非前台窗口」）
"$PROBE" focus --pid "$TARGET_A_PID" --strategy publicActivate >/dev/null 2>&1
sleep 0.8
FRONT_NOW=$("$PROBE" frontmost | grep -m1 '^FRONT_PID=' | cut -d= -f2)
Z_BEFORE=$("$PROBE" zorder --window "$B_WINDOW" | grep -m1 '^Z_INDEX_LAYER0=' | cut -d= -f2)
B_BOUNDS=$("$PROBE" list | awk -v w="ID=${B_WINDOW} " 'index($0,w){for(i=1;i<=NF;i++) if($i ~ /^BOUNDS=/){sub("BOUNDS=","",$i); print $i}}')
B_CENTER_X=$(echo "$B_BOUNDS" | awk -F, '{print int($1 + $3/2)}')
B_CENTER_Y=$(echo "$B_BOUNDS" | awk -F, '{print int($2 + $4/2)}')
echo "  当前前台=${FRONT_NOW}  B 的 z 序=${Z_BEFORE}  B 边界=${B_BOUNDS}"
echo "  B 窗口中心（Quartz）= (${B_CENTER_X}, ${B_CENTER_Y})"
if [ "$FRONT_NOW" != "$TARGET_A_PID" ]; then
  echo "  ⚠️  前台不是靶子 A（可能用户正在操作），结果可能被干扰"
fi

# ─────────────────────────────────────────────────────────────
if [ "$HF_DRIVER_STARTED" != "true" ] && [ "$HF_AX_TRUSTED" != "true" ]; then
  hdr "5/6 鼠标监听起不来 → 完整端到端无法进行"
  echo "  HoverFocus --selftest 显示 driverStarted=${HF_DRIVER_STARTED}、axTrusted=${HF_AX_TRUSTED}，"
  echo "  鼠标监听根本起不来 → 完整端到端**无法验证**（本脚本以 exit 2 结束，这不是 PASS）。"
  echo "  授权方式：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 HoverFocus.app"
  echo "  （先跑 bash Scripts/verify-permissions.sh 看完整状态）"
  skip "完整端到端（HoverFocus 菜单栏 App + 真实悬停）— 鼠标监听起不来，无法验证"

  hdr "5b 参考：无权限也能跑的核心链路（不计入 PASS/FAIL）"
  echo "  链路：真实 WindowProbe + FocusController + MousePoller + FocusEngine"
  echo "  注意：**不含菜单栏 App 本体**，只能证明「判定 + 执行」这段是通的，"
  echo "        不能替代端到端结论（的装配、权限门、菜单栏 UI 都没被覆盖）。"
  "$PROBE" pipeline --pid "$TARGET_B_PID" --window "$B_WINDOW" --dwell 0.3 --seconds 4 || true

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " 结论：鼠标监听起不来 → 端到端未验证（exit 2）"
  echo " 已通过检查 ${PASSES} 项，失败 ${FAILS} 项，未验证 ${SKIPS} 项"
  echo "════════════════════════════════════════════════════════════"
  exit 2
fi

pass "HoverFocus 已获辅助功能权限（axTrusted=true）"

# ─────────────────────────────────────────────────────────────
# 用户那份在跑就**不做**完整端到端：两份实例会互抢焦点，而且用户配置可能是「置顶模式」
# （实测用户当前就是 置顶模式 + 120ms），那会让「z 序不变」的断言失去意义。
if [ "$WAS_RUNNING" = "1" ]; then
  hdr "5/6 用户实例正在运行 → 跳过完整端到端（绝不碰它）"
  echo "  检测到 $USER_APP 正在运行（pid $(pgrep -f "$USER_APP_BIN" | tr '\n' ' '))。"
  echo "  原因：① 两份实例会互抢焦点，结果不可信；"
  echo "        ② 用户配置若是「切焦点并置顶」，会直接让本脚本的「z 序不变」断言假红。"
  echo "  本脚本不会停止、也不会重启用户那份 —— 请用户在菜单栏里退出后再重跑本脚本。"
  skip "完整端到端 — 用户实例在运行，为避免互相干扰与假红，主动跳过"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " 结论：用户实例在运行 → 端到端未验证（exit 3）"
  echo " 已通过检查 ${PASSES} 项，失败 ${FAILS} 项，未验证 ${SKIPS} 项"
  echo "════════════════════════════════════════════════════════════"
  exit 3
fi

# ─────────────────────────────────────────────────────────────
hdr "5/6 启动 HoverFocus 并把指针停到 B 窗口上"

open "$APP"
for _ in $(seq 1 20); do pgrep -f "$APP_BIN" >/dev/null 2>&1 && break; sleep 0.25; done
# 只认 **build 路径**：用户那份在 /Applications，绝不会被这条匹配到
HOVERFOCUS_PID=$(pgrep -f "$APP_BIN" | head -1)
if [ -z "$HOVERFOCUS_PID" ]; then
  fail "HoverFocus 没起来（按 build 路径找不到进程）"
  exit 1
fi
sleep 2.0
pass "HoverFocus 已启动（本次实例 pid ${HOVERFOCUS_PID}；绝不按进程名杀）"

"$PROBE" warp "$B_CENTER_X" "$B_CENTER_Y" --post >/dev/null 2>&1
pass "指针已移到 B 窗口中心 (${B_CENTER_X}, ${B_CENTER_Y})"
echo "  等 dwell + 余量 2.5s…"
sleep 2.5

# ─────────────────────────────────────────────────────────────
hdr "6/6 检查结果"

FRONT_AFTER=$("$PROBE" frontmost | grep -m1 '^FRONT_PID=' | cut -d= -f2)
Z_AFTER=$("$PROBE" zorder --window "$B_WINDOW" | grep -m1 '^Z_INDEX_LAYER0=' | cut -d= -f2)

echo "  前台：${FRONT_NOW} → ${FRONT_AFTER}（目标 B pid=${TARGET_B_PID}）"
echo "  B 的 z 序：${Z_BEFORE} → ${Z_AFTER}（默认模式要求不变）"

if [ "$FRONT_AFTER" = "$TARGET_B_PID" ]; then
  pass "悬停后 B 成为前台 App（悬停切焦点生效）"
else
  fail "悬停后前台仍是 pid=${FRONT_AFTER}，不是目标 ${TARGET_B_PID}（悬停切焦点没生效）"
fi

if [ "$Z_BEFORE" = "$Z_AFTER" ]; then
  pass "B 的 z 序未变（默认「只切焦点不置顶」成立）"
else
  fail "B 的 z 序 ${Z_BEFORE} → ${Z_AFTER}（默认模式不该置顶窗口）"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [ "$FAILS" -eq 0 ]; then
  echo " 结果：PASS（通过 ${PASSES} 项，未验证 ${SKIPS} 项）"
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi
echo " 结果：FAIL（通过 ${PASSES} 项，失败 ${FAILS} 项）"
echo "════════════════════════════════════════════════════════════"
exit 1
