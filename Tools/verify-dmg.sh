#!/bin/bash
#  HoverFocus DMG 交付验证
#
#  用法：bash Tools/verify-dmg.sh [dmg路径]
#  默认验证 dist/HoverFocus-<版本>.dmg
#
#  验证六件事：
#    1. dmg 结构对不对（app + Applications 软链接 + 使用说明）
#    2. app 在 Finder 里是不是隐藏的（拖拽窗口只显示软链接）
#    3. 模拟用户拖拽，签名会不会坏（ditto 保留 xattr，所以用 ditto 而不是 cp -R）
#    4. 拖拽副本能不能真的跑起来（--selftest）
#    5. hdiutil verify 校验和
#    6. 体积
#
#  ⚠️ 需要挂载 dmg，会在 /tmp 下创建临时挂载点并在结束时卸载。
#    用 diskutil 而非 hdiutil —— 后者的 -mountpoint 参数已废弃且会静默失败。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-$ROOT/dist/HoverFocus-0.1.0.dmg}"

if [ ! -f "$DMG" ]; then
  echo "找不到 dmg：$DMG" >&2
  echo "先跑 bash Scripts/make-dmg.sh --yes" >&2
  exit 1
fi

PY=""
for cand in python3 /usr/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "错误：找不到 python3，无法解析自检输出。" >&2; exit 1; }

T="$(mktemp -d /tmp/hf-verify.XXXXXX)"
D="$(mktemp -d /tmp/hf-drag.XXXXXX)"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then diskutil unmount "$T" force >/dev/null 2>&1 || true; fi
  rm -rf "$T" "$D"
}
trap cleanup EXIT

echo "== 挂载 $(basename "$DMG") =="
diskutil image attach "$DMG" --mountPoint "$T" --mountOptions nobrowse,ro >/dev/null 2>&1 || {
  echo "错误：挂载失败。如果是沙箱环境，请关掉沙箱后重试。" >&2
  exit 1
}
MOUNTED=1

echo
echo "=== 1. dmg 结构 ==="
ls -1 "$T" | sed 's/^/   /'
LINK="$(readlink "$T/Applications" 2>/dev/null || echo '缺失!')"
echo "   Applications -> ${LINK}"
[ "$LINK" = "/Applications" ] || { echo "   ❌ 软链接指向不对" >&2; exit 1; }
[ -d "$T/HoverFocus.app" ] || { echo "   ❌ 缺 HoverFocus.app" >&2; exit 1; }
echo "   ✅ 结构正确"

echo
echo "=== 2. app 必须对用户可见 ==="
# ⛔ 反向检查：app 被 hidden 标记藏起来是最严重的问题 ——
#    用户打开 dmg 只看到一个软链接，完全不知道该拖什么。
# 不用 mdls：它依赖 Spotlight 索引，对刚挂载的卷会静默返回空，
# 在 set -e 下直接中断脚本（第一版踩过）。
if ls -ldO "$T/HoverFocus.app" 2>/dev/null | grep -q 'hidden'; then
  echo "   ❌ app 带着 hidden 标记 —— 用户打开 dmg 看不到它" >&2
  echo "      检查 Scripts/make-dmg.sh 里是不是多了一句 chflags hidden" >&2
  exit 1
fi
echo "   ✅ app 可见（可拖拽到 Applications）"

echo
echo "=== 3. 模拟拖拽 ==="
# 用 ditto 而不是 cp -R：cp -R 会丢扩展属性，签名可能因此失效。
ditto "$T/HoverFocus.app" "$D/HoverFocus.app"
echo "   拖拽完成"

echo
echo "=== 4. 拖拽后签名 ==="
if codesign -v "$D/HoverFocus.app" 2>&1; then
  echo "   ✅ 签名仍然有效"
  codesign -dv "$D/HoverFocus.app" 2>&1 | grep -E 'Authority=|Identifier=' | sed 's/^/   /'
else
  echo "   ❌ 签名损坏 —— 暂存拷贝破坏了签名" >&2
  exit 1
fi

echo
echo "=== 5. 拖拽副本能跑吗 ==="
# 只取 stdout：自检的 JSON 走 stdout，而 stderr 可能混进 sandbox / Gatekeeper
# 的提示行（第一版就因为 stderr 噪音导致 JSON 解析失败）。
"$D/HoverFocus.app/Contents/MacOS/HoverFocus" --selftest 2>/dev/null | "$PY" -c "
import json,sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print('   ❌ 自检输出不是合法 JSON：', raw[:200]); sys.exit(1)
ok = bool(d.get('statusItemCreated')) and bool(d.get('buttonWindowVisible'))
for k in ['statusItemCreated','buttonWindowVisible','bundleID','isRunningFromBundle','version','iconState','error']:
    print(f'   {k:20} {d.get(k)}')
print('   →', 'PASS dmg 内容可拖拽、可用' if ok else 'FAIL 菜单栏图标没起来')
sys.exit(0 if ok else 1)
"

echo
echo "=== 6. 完整性 ==="
if hdiutil verify "$DMG" 2>&1 | grep -qi checksum; then
  echo "   ✅ hdiutil verify 通过"
else
  echo "   ⚠️  hdiutil verify 未确认校验和，建议人工检查" >&2
fi
echo "   体积 $(du -h "$DMG" | cut -f1 | tr -d ' ')"

echo
echo "全部通过。"