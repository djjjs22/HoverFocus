#!/bin/bash
#  HoverFocus — 安装到 /Applications（app-shell 维护）
#  ─────────────────────────────────────────────────────────────────────────
#  做四件事：
#    1. 构建（make app），必要时先创建自签证书
#    2. 拷到 /Applications/HoverFocus.app（先停掉正在跑的旧版本）
#    3. 提示辅助功能权限步骤
#    4. 启动
#
#  安全规则：
#    - **绝不碰 AutoFocus.app**。它是用户日常在用的工具，本脚本只操作
#      /Applications/HoverFocus.app。脚本里连一个写 AutoFocus 的路径都没有。
#    - 覆盖已存在的 /Applications/HoverFocus.app 之前会确认（非交互模式下会说明并继续，
#      但会先把旧版本备份到 .bak，绝不静默丢东西）。
#
#  用法：
#    bash Scripts/install.sh              # 交互式安装
#    bash Scripts/install.sh --yes        # 不询问，直接覆盖
#    bash Scripts/install.sh --no-launch  # 装完不自动启动
#  ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT/build/HoverFocus.app"
DEST_APP="/Applications/HoverFocus.app"
DEST_BACKUP="/Applications/HoverFocus.app.bak"
BUNDLE_ID="com.lunasama.HoverFocus"

ASSUME_YES=0
LAUNCH_AFTER=1
for arg in "$@"; do
  case "$arg" in
    --yes|-y)   ASSUME_YES=1 ;;
    --no-launch) LAUNCH_AFTER=0 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不认识的参数：${arg}（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

log()  { echo "[install] $*"; }
warn() { echo "[install][警告] $*" >&2; }
fail() { echo "[install][错误] $*" >&2; exit 1; }

# ── 0. 安全检查：绝不操作 AutoFocus ─────────────────────────────────────
case "$DEST_APP" in
  *AutoFocus*) fail "内部错误：目标路径包含 AutoFocus，脚本拒绝继续（${DEST_APP}）" ;;
esac
if [ -e "/Applications/AutoFocus.app" ]; then
  log "检测到 /Applications/AutoFocus.app（用户日常在用）—— 本脚本不会动它。"
  if pgrep -x AutoFocus >/dev/null 2>&1; then
    warn "AutoFocus 正在运行。它和 HoverFocus 都会抢键盘焦点，同时跑会互相干扰。"
    warn "建议先退出 AutoFocus（不影响它的安装，只是别让它和 HoverFocus 同时生效）。"
  fi
fi

# ── 1. 构建 ─────────────────────────────────────────────────────────────
log "== 1/5 构建 =="
if [ ! -f "$HOME/Library/Keychains/hoverfocus-signing.keychain-db" ]; then
  log "还没有自签证书 —— 先创建（不需要 sudo，不弹框）"
  if bash "$ROOT/Scripts/make-signing-cert.sh"; then
    log "自签证书就绪：重新构建后「辅助功能」授权不会失效"
  else
    warn "自签证书创建失败，将继续构建（会用 ad-hoc 签名，每次重建后需要重新授权）"
  fi
else
  # 幂等：已存在就走一遍解锁 + partition list 修复
  bash "$ROOT/Scripts/make-signing-cert.sh" >/dev/null 2>&1 || \
    warn "自签证书检查/修复失败，继续构建（可能退回 ad-hoc 签名）"
fi

bash "$ROOT/Scripts/build.sh"
[ -d "$SRC_APP" ] || fail "构建产物不存在：$SRC_APP"

# ── 2. 停掉正在跑的旧版本 ───────────────────────────────────────────────
log "== 2/5 停止正在运行的 HoverFocus =="
# 只停「即将被替换的那一份」（/Applications 下的），按完整路径匹配。
# ⛔ 不要 `pkill -x HoverFocus`：那会连带杀掉并发的 build/ 开发实例或用户另外起的实例。
# 记下「本来在跑」这个事实：--no-launch 时结束时必须如实告诉用户工具被停了，
# 不能让他发现自己日常用的东西「莫名其妙没了」。
WAS_RUNNING=0
DEST_BIN="$DEST_APP/Contents/MacOS/HoverFocus"
# 杀之前断言模式足够具体（VERIFICATION.md §11.2 规则 4）。
# 危险的不是「空模式」—— macOS 的 pgrep/pkill 会直接报错拒绝空模式（exit 2），走不到匹配；
# 真正危险的是**过宽但非空**的模式（例如退化成 "/"，实测会匹配几百个进程）。
case "$DEST_BIN" in
  */Applications/HoverFocus.app/Contents/MacOS/HoverFocus) ;;
  *) echo "内部错误：pkill 模式异常（${DEST_BIN}），拒绝执行" >&2; exit 1 ;;
esac
if pgrep -f "$DEST_BIN" >/dev/null 2>&1; then
  WAS_RUNNING=1
  log "停止 /Applications 里的旧实例：$(pgrep -f "$DEST_BIN" | tr '\n' ' ')"
  pkill -f "$DEST_BIN" 2>/dev/null || true
  sleep 1
  log "已停止旧实例（${DEST_APP}）"
else
  log "没有正在运行的旧实例"
fi

# 提醒但不杀：build/ 下的开发实例（避免误伤正在调试/验收的会话）
if pgrep -f "$ROOT/build/HoverFocus.app/Contents/MacOS/HoverFocus" >/dev/null 2>&1; then
  warn "检测到 build/ 下的开发实例仍在运行 —— 本脚本不会杀它（避免误伤验收/调试），"
  warn "但两个实例会互相抢键盘焦点，建议手动退出其中一个。"
fi

# ── 3. 拷贝到 /Applications ─────────────────────────────────────────────
log "== 3/5 安装到 $DEST_APP =="
if [ -d "$DEST_APP" ]; then
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf "已存在 %s，要覆盖吗？旧版本会备份到 %s [y/N] " "$DEST_APP" "$DEST_BACKUP"
      read -r answer
      case "$answer" in
        y|Y|yes|YES) ;;
        *) log "已取消，未改动 /Applications"; exit 0 ;;
      esac
    else
      warn "已存在 ${DEST_APP}；非交互模式（没有 tty）→ 备份旧版本后覆盖。"
      warn "不想覆盖请加 --help 看用法，或手动先移走。"
    fi
  fi
  rm -rf "$DEST_BACKUP"
  if mv "$DEST_APP" "$DEST_BACKUP" 2>/dev/null; then
    log "旧版本已备份到 $DEST_BACKUP"
  else
    warn "备份旧版本失败（可能没有写权限），继续尝试直接覆盖"
  fi
fi

# ditto 保留签名与权限位（cp -R 有时会破坏 bundle 里的扩展属性）
if ! ditto "$SRC_APP" "$DEST_APP" 2>/dev/null; then
  if ! cp -R "$SRC_APP" "$DEST_APP" 2>/dev/null; then
    fail "拷贝到 /Applications 失败 —— 可能需要管理员权限。请手动执行：
       sudo ditto '$SRC_APP' '$DEST_APP'"
  fi
fi
log "已安装：$DEST_APP"

# ── 4. 校验签名 ─────────────────────────────────────────────────────────
log "== 4/5 校验 =="
DR="$(codesign -d -r- "$DEST_APP" 2>&1 | tail -1 || true)"
case "$DR" in
  *"certificate leaf"*) log "签名 OK（基于证书指纹，重建后授权依然有效）" ;;
  *cdhash*) warn "安装的是 ad-hoc 签名：以后每次重建都需要重新在系统设置里勾选 HoverFocus" ;;
  *) warn "签名校验输出异常：$DR" ;;
esac
codesign --verify "$DEST_APP" 2>&1 | sed 's/^/   /' || warn "codesign --verify 报告了问题（自签证书未受系统信任时属正常）"

# ── 5. 权限步骤 + 启动 ──────────────────────────────────────────────────
log "== 5/5 权限与启动 =="
cat <<'PERM'

  ┌─ 关于权限（重要：默认不需要任何权限）────────────────────────────┐
  │ HoverFocus 默认用「轮询光标位置」监听，**不需要授予任何权限**。    │
  │ 装完直接就能用：鼠标悬停到窗口上，键盘焦点就会切过去。             │
  │                                                                  │
  │ 授予「辅助功能」权限是**可选的精度增强**：                         │
  │   · 不授权 → 命中测试为「窗口列表」模式：分屏场景精确，            │
  │              窗口重叠 / 圆角 / 透明区域可能判错。                  │
  │   · 授权后 → 命中测试升级为 AX 精确模式，重叠和圆角都对；          │
  │              并且可以另外选用低延迟的 CGEventTap 监听方式。        │
  │                                                                  │
  │ 想授权：点菜单栏的 HoverFocus 图标 →「授予辅助功能权限…」，        │
  │ 然后在 系统设置 → 隐私与安全性 → 辅助功能 里勾选 HoverFocus。      │
  │ 授权后**不需要重启**，1 秒内自动生效。                             │
  └──────────────────────────────────────────────────────────────────┘

PERM

if [ "$LAUNCH_AFTER" -eq 1 ]; then
  log "启动 HoverFocus…"
  open "$DEST_APP"
  sleep 1
  # 按完整路径确认「刚装好的这一份」起来了。
  # 不能按进程名判：build/ 下可能还有开发实例，那样会误报成功。
  if pgrep -f "$DEST_APP/Contents/MacOS/HoverFocus" >/dev/null 2>&1; then
    log "✅ 已启动。菜单栏应该出现了 HoverFocus 图标。"
  else
    warn "进程没起来。用下面这条命令看原因："
    warn "  log show --last 2m --predicate 'subsystem == \"com.lunasama.HoverFocus\"' --style compact"
  fi
else
  log "已按要求跳过启动（--no-launch）。手动启动：open '$DEST_APP'"
  if [ "$WAS_RUNNING" -eq 1 ]; then
    # 不许静默：本来在跑、被我们停了、又没起回来，必须说清楚
    warn "⚠️ 安装前 $DEST_APP 本来正在运行，已被本脚本停止，且按 --no-launch 没有重新启动。"
    warn "   要恢复：open '$DEST_APP'"
  fi
fi

echo
log "安装完成。常用命令："
echo "   make run        构建并启动（开发用，跑 build/ 里的）"
echo "   make kill       停止 build/ 下的开发实例（不影响 /Applications）"
echo "   make quit       停止已安装到 /Applications 的那一份（会提示怎么重新启动）"
echo "   诊断信息        菜单栏图标 → 诊断信息 → 复制完整诊断信息到剪贴板"
if [ -d "$DEST_BACKUP" ]; then
  echo "   （旧版本备份在 ${DEST_BACKUP}，确认新版没问题后可以删掉）"
fi
