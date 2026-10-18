#!/bin/bash
#  HoverFocus 最终验收（Lead 所有）
#
#  和 Tests/ 的纯逻辑单测、以及 /tmp 的 harness 不同，这个脚本验收的是**真正要交付的那个
#  .app**：启动它、用真实光标移动触发它、断言真实的前台 App 切换。
#
#  为什么必须单独做这一步：单测用的是假 probe/假 actuator；harness 用的是自己拼的管线。
#  只有这一步能证明「用户双击 .app 之后真的能用」。
#
#  关键前提：默认的轮询事件源（MousePoller）**不需要任何系统权限**，所以本脚本
#  在未授予辅助功能权限的机器上也应当通过。如果它要求你先授权，说明零权限设计退化了。
#
#  用法：Scripts/lead-acceptance.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 允许用 HF_APP 指定要验收的 .app 副本：并发构建时 build/ 会被 rm -rf 重建，
# 验收跑在快照副本上就不会被别人的构建打断（签名相同，TCC 授权照样继承）。
APP="${HF_APP:-$ROOT/build/HoverFocus.app}"
BIN="$APP/Contents/MacOS/HoverFocus"
CTL="/tmp/hfx/hfctl"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1${2:+  [$2]}"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1${2:+  [$2]}"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭  $1${2:+  [$2]}"; }
check(){ if [ "$1" = "1" ]; then ok "$2" "${3:-}"; else bad "$2" "${3:-}"; fi }

# 备份用户设置，验收结束后原样还回去。以前这里直接 `defaults delete`，
# 会把用户自己调好的模式/监听方式/排除名单全部清掉 —— 那是破坏性的，不能这么干。
PREFS_BACKUP="$(mktemp -t hf-prefs)"
HAD_PREFS=0
# 验收会故意把 App 杀掉来测「退出后不再抢焦点」。如果用户原本正在用它，
# 跑完必须还回去 —— 否则用户会发现自己日常用的工具「莫名其妙没了」。
WAS_RUNNING=0
pgrep -x HoverFocus >/dev/null 2>&1 && WAS_RUNNING=1
APP_RESTORED=0

stop_now() {
  pkill -x HoverFocus 2>/dev/null
  pkill -f HFTarget 2>/dev/null
}

cleanup() {
  stop_now
  if [ "$HAD_PREFS" = "1" ]; then
    defaults import com.lunasama.HoverFocus "$PREFS_BACKUP" >/dev/null 2>&1
  fi
  rm -f "$PREFS_BACKUP"
  if [ "$WAS_RUNNING" = "1" ] && [ "$APP_RESTORED" = "0" ] && [ -x /Applications/HoverFocus.app/Contents/MacOS/HoverFocus ]; then
    APP_RESTORED=1
    open /Applications/HoverFocus.app >/dev/null 2>&1 || true
    echo "   （验收前 HoverFocus 在运行，已重新启动还给你）"
  fi
}
trap cleanup EXIT

echo "════════ HoverFocus 最终验收（真实 .app）════════"

# ── 前置 ──
[ -x "$BIN" ] || { echo "先构建：make app"; exit 2; }
[ -x "$CTL" ] || { echo "缺少 ${CTL}（验收控制工具）"; exit 2; }

stop_now; sleep 0.5

# 从默认值开始（默认：轮询模式 + focusOnly + 120ms dwell），但先把用户设置备份起来
if defaults export com.lunasama.HoverFocus "$PREFS_BACKUP" >/dev/null 2>&1; then HAD_PREFS=1; fi
defaults delete com.lunasama.HoverFocus 2>/dev/null

echo
echo "── 1. 自检（不依赖任何权限）──"
# 自检进程本身也叫 HoverFocus，所以脚本自己的 pkill -x HoverFocus 可能把它顺手杀掉
# （表现：无输出、退出码 143 = 128+SIGTERM）。这不是 App 的 bug，重试即可。
SELFTEST=""
for attempt in 1 2 3; do
  SELFTEST="$(timeout 60 "$BIN" --selftest 2>/dev/null | tail -1)"
  [ -n "$SELFTEST" ] && break
  echo "     自检无输出（第 $attempt 次），疑似被并发 pkill 命中，1.5 秒后重试…"
  sleep 1.5
done
if [ -z "$SELFTEST" ]; then
  bad "自检连续 3 次没有输出 JSON"
else
  read -r CREATED VISIBLE DRIVER TRUSTED ICON < <(printf '%s' "$SELFTEST" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(int(bool(d.get('statusItemCreated'))), int(bool(d.get('buttonWindowVisible'))),
      int(bool(d.get('driverStarted'))), int(bool(d.get('axTrusted'))), d.get('iconState'))
" 2>/dev/null)
  check "$CREATED" "菜单栏图标创建成功"
  check "$VISIBLE" "图标窗口真实可见"
  check "$DRIVER"  "driver 在未授权情况下也启动了" "axTrusted=$TRUSTED iconState=$ICON"
  if [ "$TRUSTED" = "0" ] && [ "$ICON" = "permissionMissing" ]; then
    bad "未授权时图标仍报 permissionMissing（轮询模式不该报警）"
  fi
fi

echo
echo "── 2. 启动靶子窗口 ──"
for N in A B; do
  X=$([ "$N" = "A" ] && echo 100 || echo 1300)
  "/tmp/hfx/HFTarget$N.app/Contents/MacOS/HFTarget$N" "$X" 380 600 450 "TARGET-$N" --keepfront >/dev/null 2>&1 &
done
sleep 2
WA="$(/tmp/hfx/hfctl windows | awk -F'\t' '$3=="HFTargetA"{print $1; exit}')"
WB="$(/tmp/hfx/hfctl windows | awk -F'\t' '$3=="HFTargetB"{print $1; exit}')"
[ -n "$WA" ] && ok "靶子A 窗口出现" "wid=$WA" || bad "靶子A 窗口没出现"
[ -n "$WB" ] && ok "靶子B 窗口出现" "wid=$WB" || bad "靶子B 窗口没出现"
[ -n "$WA" ] && [ -n "$WB" ] || exit 2

echo
echo "── 3. 启动真实 App ──"
"$BIN" > /tmp/hfx/hoverfocus.log 2>&1 &
APP_PID=$!
sleep 3
if kill -0 "$APP_PID" 2>/dev/null; then ok "HoverFocus 常驻进程存活" "pid=$APP_PID"; else bad "HoverFocus 启动后退出"; tail -5 /tmp/hfx/hoverfocus.log; fi
if grep -q "驱动已启动\|driver.*启动\|已启动" /tmp/hfx/hoverfocus.log 2>/dev/null; then
  ok "日志显示 driver 已启动" "$(grep -m1 '驱动已启动\|driver' /tmp/hfx/hoverfocus.log | cut -c1-90)"
else
  skip "日志里没找到 driver 启动行" "见 /tmp/hfx/hoverfocus.log"
fi

# 30 秒存活检查：曾经被 AppKit Automatic Termination 在 3–4 秒内静默杀掉
# （日志证据：Setting _kLSApplicationWouldBeTerminatedByTALKey=1）。
# 这个 bug 是间歇性的，所以必须真的等满 30 秒。
echo "     … 等待 30 秒验证不会被系统自动终止（曾复现过 3–4 秒被静默杀掉）"
ALIVE=1
for _ in $(seq 1 30); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then ALIVE=0; break; fi
done
check "$ALIVE" "30 秒后仍存活（AppKit 自动终止已禁用）"
[ "$ALIVE" = "1" ] || { bad "进程被系统终止了"; tail -3 /tmp/hfx/hoverfocus.log; }

echo
echo "── 4. 真实悬停 → 前台切换 ──"
PA="$(/tmp/hfx/hfctl windows | awk -F'\t' '$3=="HFTargetA"{print $4}' | tr -d '(),' | awk -F' ' '{print $1+$3/2" "$2+$4/2}')"
PB="$(/tmp/hfx/hfctl windows | awk -F'\t' '$3=="HFTargetB"{print $4}' | tr -d '(),' | awk -F' ' '{print $1+$3/2" "$2+$4/2}')"
echo "     靶子A 中心=$PA   靶子B 中心=$PB"

# 先移到菜单栏，确保从「不触发」状态开始
"$CTL" warp 500 10 >/dev/null; sleep 0.6

"$CTL" warp $PA >/dev/null; sleep 1.5
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" = "HFTargetA" ] && echo 1 || echo 0)" "悬停靶子A → 前台变成 HFTargetA" "实际 ${F%%|*}"

"$CTL" warp $PB >/dev/null; sleep 1.5
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" = "HFTargetB" ] && echo 1 || echo 0)" "悬停靶子B → 前台变成 HFTargetB" "实际 ${F%%|*}"

echo
echo "── 5. 菜单栏不误抢 ──"
"$CTL" warp 500 10 >/dev/null; sleep 1.0
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" = "HFTargetB" ] && echo 1 || echo 0)" "移到菜单栏后前台保持 HFTargetB（没被抢）" "实际 ${F%%|*}"

echo
echo "── 6. 快速划过不误抢（dwell 生效）──"
# 必须用单进程 sweep：每个点起一个新进程的话，进程启动 ~20ms 会把「停 30ms」
# 放大到 200ms 以上，超过 dwell 之后聚焦反而是正确行为，测试会假失败。
FRONT_BEFORE_SWEEP="$(/tmp/hfx/hfctl front)"
PAX="${PA% *}"; PAY="${PA#* }"
"$CTL" sweep "$PAX" "$PAY" 500 10 8 30 >/dev/null
sleep 0.8
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" = "${FRONT_BEFORE_SWEEP%%|*}" ] && echo 1 || echo 0)" \
      "快速划过靶子A 8 次（每次仅停 30ms），前台未被抢走" \
      "${FRONT_BEFORE_SWEEP%%|*} -> ${F%%|*}"

echo
echo "── 7. 停在窗口上仍能切换（防「一刀切禁掉」）──"
"$CTL" warp $PA >/dev/null; sleep 1.5
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" = "HFTargetA" ] && echo 1 || echo 0)" "正常停留后切到 HFTargetA" "实际 ${F%%|*}"

echo
echo "── 8. 关闭 App 后不再抢焦点 ──"
kill "$APP_PID" 2>/dev/null; sleep 1
"$CTL" warp $PB >/dev/null; sleep 1.0
F="$(/tmp/hfx/hfctl front)"
check "$([ "${F%%|*}" != "HFTargetB" ] && echo 1 || echo 0)" "App 退出后不再切换前台" "实际 ${F%%|*}"

echo
echo "════════ 汇总 ════════"
echo "通过 $PASS / 失败 $FAIL / 跳过 $SKIP"
if [ "$FAIL" = "0" ]; then echo "结果: PASS ✅"; exit 0; else echo "结果: FAIL ❌"; exit 1; fi
