#!/bin/bash
#  HoverFocus 构建脚本
#
#  为什么不用 swift build：本机 Command Line Tools 安装不一致 ——
#  /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib
#  (Sep 2) 不导出 PackageDescription.swiftmodule (Oct 9) 需要的符号，
#  任何 swift package / swift build / swift test 都会在编译 manifest 时链接失败。
#  所以这里用 swiftc 直接单次编译：所有源文件编进同一个模块（因此源文件之间不要互相 import）。
#
#  用法：
#    Scripts/build.sh              # 构建 build/HoverFocus.app
#    Scripts/build.sh --run        # 构建并启动
#    Scripts/build.sh --no-sign    # 跳过签名（排障用）
#
#  签名：优先用 Scripts/make-signing-cert.sh 创建的自签证书（DR 稳定，
#  辅助功能授权不会因重建失效）；没有就退回 ad-hoc 并**明确警告**，不静默降级。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/HoverFocus.app"
MIN_MACOS="13.0"
ARCH="$(uname -m)"
BUNDLE_ID="com.lunasama.HoverFocus"

# ── 参数 ────────────────────────────────────────────────────────────────
RUN_AFTER_BUILD=0
SKIP_SIGN=0
for arg in "$@"; do
  case "$arg" in
    --run)     RUN_AFTER_BUILD=1 ;;
    --no-sign) SKIP_SIGN=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "不认识的参数：${arg}（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

# 自签证书（与 Scripts/make-signing-cert.sh 保持一致）
SIGN_ID="${HOVERFOCUS_SIGN_ID:-HoverFocus Dev}"
KEYCHAIN_PATH="$HOME/Library/Keychains/hoverfocus-signing.keychain-db"
PASSWORD_FILE="$HOME/Library/Application Support/HoverFocus/signing-keychain-password"

# ── 构建锁 ──────────────────────────────────────────────────────────────
#  四个 agent / 多个终端共用同一个 build/ 与同一个 .app，并发构建会互相 clobber
#  （表现是莫名其妙的 "input file was modified during the build" 或半个 bundle）。
#  用 mkdir 的原子性做互斥，等不到就明确报错，绝不无限期死等。
LOCK="$BUILD/.build.lock"
LOCK_TIMEOUT_ITERS=240          # 240 × 0.5s = 120s
LOCK_HELD=0

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -rf "$LOCK" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
trap release_lock EXIT INT TERM

acquire_lock() {
  local waited=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    if [ "$waited" -ge "$LOCK_TIMEOUT_ITERS" ]; then
      echo "错误：等待构建锁超过 $((LOCK_TIMEOUT_ITERS / 2)) 秒仍未拿到。" >&2
      if [ -f "$LOCK/pid" ]; then
        echo "      当前持锁进程：PID $(cat "$LOCK/pid" 2>/dev/null || echo '?')" >&2
      fi
      echo "      可能是另一个 make app 正在跑，或者上一次构建异常中断留下了锁。" >&2
      echo "      确认没有其它构建在跑之后，删掉这个目录即可：rm -rf '$LOCK'" >&2
      exit 1
    fi
    if [ $((waited % 10)) -eq 0 ]; then
      echo "   等待其它构建释放锁…（$((waited / 2))s）"
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  LOCK_HELD=1
  echo "$$" > "$LOCK/pid" 2>/dev/null || true
}

mkdir -p "$BUILD"
acquire_lock

CORE_SRC=("$ROOT"/Sources/HoverFocusCore/*.swift)
APP_SRC=("$ROOT"/Sources/HoverFocus/*.swift)

if [ ! -e "${APP_SRC[0]}" ]; then
  echo "错误：找不到 Sources/HoverFocus/*.swift" >&2
  exit 1
fi
if [ ! -e "${CORE_SRC[0]}" ]; then
  echo "错误：找不到 Sources/HoverFocusCore/*.swift" >&2
  exit 1
fi

# 编译前后对比源文件指纹：用来区分「代码写错了」和「别人正在改文件」
source_fingerprint() {
  stat -f '%m %z %N' "${CORE_SRC[@]}" "${APP_SRC[@]}" 2>/dev/null | sort
}

echo "== [1/5] 编译（${ARCH}, macOS ${MIN_MACOS}+） =="
FP_BEFORE="$(source_fingerprint)"
LOG="$BUILD/.swiftc.log"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

set +e
swiftc \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-name HoverFocus \
  "${CORE_SRC[@]}" "${APP_SRC[@]}" \
  -o "$APP/Contents/MacOS/HoverFocus" > "$LOG" 2>&1
SWIFTC_STATUS=$?
set -e

if [ "$SWIFTC_STATUS" -ne 0 ]; then
  echo "编译失败。编译器输出：" >&2
  sed 's/^/  /' "$LOG" >&2
  if [ "$(source_fingerprint)" != "$FP_BEFORE" ]; then
    echo "" >&2
    echo "⚠️  注意：编译期间有源文件被修改了。" >&2
    echo "    这不是代码错误，而是并发编辑（别的 agent / 编辑器正在写 Sources/）。" >&2
    echo "    等对方写完重跑 make app 即可。" >&2
  fi
  exit 1
fi

echo "== [2/5] 组装 bundle =="
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "== [3/5] 签名 =="
SIGNED_WITH_CERT=0
if [ "$SKIP_SIGN" -eq 1 ]; then
  echo "   已按要求跳过签名（--no-sign）"
else
  # 自签证书可用吗？（用专用钥匙串，避免弹钥匙串授权框）
  if [ -f "$KEYCHAIN_PATH" ] \
     && security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$SIGN_ID"; then
    if [ -f "$PASSWORD_FILE" ]; then
      security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    if codesign --keychain "$KEYCHAIN_PATH" --force --sign "$SIGN_ID" \
         --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1; then
      SIGNED_WITH_CERT=1
      echo "   使用自签证书签名：$SIGN_ID"
    else
      echo "   ⚠️  自签证书签名失败，退回 ad-hoc。建议重跑：bash Scripts/make-signing-cert.sh" >&2
    fi
  fi

  if [ "$SIGNED_WITH_CERT" -eq 0 ]; then
    echo "   ⚠️  未找到可用的「${SIGN_ID}」自签证书，退回 ad-hoc 签名。"
    echo "      后果：每次重新构建后 cdhash 都变，系统设置里的「辅助功能」授权会失效，需要重新勾选。"
    echo "      修法：bash Scripts/make-signing-cert.sh（不需要 sudo，不弹框）"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  fi
fi

echo "== [4/5] 校验签名 =="
# 证书签名时 codesign -dv 没有 "Signature=" 行（只有 ad-hoc 才有），所以不能用它判断，
# 必须同时看 DR 和 flags，否则会把「证书签名」误报成未知、把 ad-hoc 漏过去。
# 注意：CDHash / Authority 只在 --verbose=4 的输出里才有，普通 -dv 不打印这两行
CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if [ "$SIGNED_WITH_CERT" -eq 1 ] && echo "$CODESIGN_INFO" | grep -qi 'adhoc'; then
  # 静默退化成 ad-hoc 是最坏的失败方式：用户以为修好了，其实授权还是会丢
  echo "   ❌ codesign 报告的是 ad-hoc 签名，证书没生效！" >&2
  echo "$CODESIGN_INFO" | sed 's/^/      /' >&2
  echo "      请跑 bash Scripts/make-signing-cert.sh 后重试。" >&2
  exit 1
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /' || true

DR="$(codesign -d -r- "$APP" 2>&1 | tail -1 || true)"
if echo "$CODESIGN_INFO" | grep -qi 'adhoc'; then
  echo "   Signature=adhoc（临时签名）"
else
  echo "   Signature=证书签名"
fi
echo "   签名身份: $(echo "$CODESIGN_INFO" | awk -F= '/^Authority=/{print $2; exit}')"
echo "   cdhash: $(echo "$CODESIGN_INFO" | awk -F= '/^CDHash=/{print $2}')"
echo "   指定要求: $DR"
case "$DR" in
  *"certificate leaf"*)
    echo "   ✅ 指定要求基于证书指纹 —— 重新构建后辅助功能授权依然有效" ;;
  *cdhash*)
    echo "   ⚠️  指定要求是 cdhash —— 每次重建后辅助功能授权都会失效（跑 Scripts/make-signing-cert.sh 可修）" ;;
esac

echo "== [5/5] 完成 =="
echo "   app:  $APP"
echo "   自检: $APP/Contents/MacOS/HoverFocus --selftest"
echo "   权限: make probe（build/hf-probe）"

if [ "$RUN_AFTER_BUILD" -eq 1 ]; then
  echo "== 启动 =="
  # 只停 **build/ 里的旧开发实例**（按完整路径匹配）。
  # ⛔ 绝不能 `pkill -x HoverFocus`：用户的 /Applications/HoverFocus.app 进程名也叫 HoverFocus，
  #    按名杀会把用户正在日常使用的工具一起杀掉 —— 这件事已经真实发生过（见
  #    docs/VERIFICATION.md §11）。按 "$APP/..." 全路径匹配，就不会匹配到 /Applications 那份。
  BUILD_BIN="$APP/Contents/MacOS/HoverFocus"
  # 杀之前断言模式足够具体（VERIFICATION.md §11.2 规则 4）。
  # 危险的不是「空模式」—— macOS 的 pgrep/pkill 会直接报错拒绝空模式（exit 2），走不到匹配；
  # 真正危险的是**过宽但非空**的模式（例如退化成 "/"，实测会匹配几百个进程）。
  case "$BUILD_BIN" in
    */build/HoverFocus.app/Contents/MacOS/HoverFocus) ;;
    *) echo "内部错误：pkill 模式异常（${BUILD_BIN}），拒绝执行" >&2; exit 1 ;;
  esac
  pkill -f "$BUILD_BIN" 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
