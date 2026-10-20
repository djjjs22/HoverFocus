#!/bin/bash
#  HoverFocus DMG 打包脚本
#
#  用法：
#    bash Scripts/make-dmg.sh              # 打包 → dist/HoverFocus-0.1.1.dmg
#    bash Scripts/make-dmg.sh --build      # 先重新构建 app 再打包
#    bash Scripts/make-dmg.sh --open       # 打包后保持挂载（排障用）
#    bash Scripts/make-dmg.sh --yes        # 覆盖已存在的 dmg 不询问
#
#  ⛔ 关于签名与分发的如实说明（不要跳过这段）：
#    本脚本用 Scripts/make-signing-cert.sh 的**自签证书**签名，Authority 显示为
#    "HoverFocus Dev"。这**不是** Apple Developer ID，也不是公证（notarized）过的构建。
#
#    影响：
#      · 在**你自己这台机器**上 → 完全没影响，辅助功能授权也不会失效（DR 基于证书指纹）。
#      · 拷给别人 / 别人下载 → 对方首次打开会被 Gatekeeper 拦，提示「无法验证开发者」。
#        绕过办法是右键点 app → 打开 → 再确认一次。这是**分发限制**，不是 bug。
#      · 要彻底解决，需要 Apple Developer Program 账号（$99/年）来签 Developer ID，
#        再提交公证。本机没有 Xcode，也没配公证凭据，所以这条路现在走不通。
#
#  如果这份 dmg 只是给自己备份 / 侧载，上面这些都不影响。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/HoverFocus.app"
DIST="$ROOT/dist"
STAGE="$BUILD/.dmg-stage"

REBUILD=0
KEEP_MOUNTED=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --build) REBUILD=1 ;;
    --open)  KEEP_MOUNTED=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不认识的参数：${arg}（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：dmg 只能在 macOS 上打。" >&2
  exit 1
fi

# ── 参数：重新构建 ──────────────────────────────────────────────────────
if [ "$REBUILD" -eq 1 ]; then
  echo "== [0/5] 重新构建 =="
  bash "$ROOT/Scripts/build.sh"
fi

if [ ! -d "$APP" ]; then
  echo "错误：找不到 $APP" >&2
  echo "      先跑 bash Scripts/build.sh 或用 --build 一起构建。" >&2
  exit 1
fi

# ── 参数：从 Info.plist 读版本号（不硬编码，避免和 Info.plist 漂移） ─────
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "1")"
VOLNAME="HoverFocus $VERSION"
DMG="$DIST/HoverFocus-$VERSION.dmg"

echo "== 版本 =="
echo "   $VERSION (build $BUILD_NUM)"

# ── 参数：确认不会带着运行中的实例被打进去 ────────────────────────────────
# ⛔ 绝不能用 pkill -x HoverFocus：用户的 /Applications/HoverFocus.app 进程名也叫
#    HoverFocus，按名杀会把它一起杀掉且不还回来 —— 这件事真实发生过（docs/VERIFICATION.md §11）。
#    这里只**检查**，不杀；而且只在 dmg 阶段的暂存副本上操作。
RUNNING="/Applications/HoverFocus.app/Contents/MacOS/HoverFocus"
PIDS="$(pgrep -f "$RUNNING" 2>/dev/null || true)"
# 注意：变量一律用 ${VAR} 写法，不用 $VAR。bash 在 UTF-8 locale 下会把全角字符
# 当成变量名的一部分，所以 "$PIDS）。" 里的 PIDS 会被连着全角括号一起解析成一个
# 叫 "PIDS）。" 的变量，在 set -u 下直接报 unbound variable。
if [ -n "$PIDS" ]; then
  echo "== 注意 =="
  echo "   /Applications 下那份 HoverFocus 正在运行（pid: ${PIDS}）。"
  echo "   本脚本不会碰它 —— dmg 里打的是 build/ 的暂存副本。"
  echo "   但如果你想确认 dmg 里的行为一致，建议打包前先 make quit。"
fi

# ── 参数：已存在就问 ────────────────────────────────────────────────────
mkdir -p "$DIST"
if [ -f "$DMG" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    rm -f "$DMG"
  else
    echo "错误：$DMG 已存在。" >&2
    echo "      要覆盖就加 --yes，或手动删掉它。" >&2
    exit 1
  fi
fi

# ── 1/6 暂存目录 ────────────────────────────────────────────────────────
echo "== [1/5] 组装暂存目录 =="
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 用 ditto 而不是 cp -R：保留扩展属性、资源分叉、符号链接、权限位。
# 普通 cp -R 会把这些弄丢，导致 bundle 签名校验失败。
ditto "$APP" "$STAGE/HoverFocus.app"

# ── 2/6 拖到应用程序的软链接 ─────────────────────────────────────────────
echo "== [2/5] 建立「应用程序」软链接 =="
ln -s /Applications "$STAGE/Applications"

# ── 3/5 清理扩展属性 ────────────────────────────────────────────────────
# 清理 ._ 垃圾文件（AppleDouble）。copyfile 元数据不打包进 dmg，拖到
# /Applications 时 Finder 会从别处补，所以这里只会留下噪音。
xattr -cr "$STAGE" 2>/dev/null || true

# 复制一份 README 到 dmg 里，别人拖完能知道这是什么、怎么装
if [ -f "$ROOT/docs/DMG-README.txt" ]; then
  cp "$ROOT/docs/DMG-README.txt" "$STAGE/使用说明.txt"
fi

# ── 4/5 图标位置（可选优化） ─────────────────────────────────────────────
# 标准 dmg 的样子是：左下角 HoverFocus.app，右下角 Applications 软链接，
# 中间一个箭头 —— 用户一眼就知道要「把 app 拖到 Applications」。
#
# ⛔ **绝对不要给 app 加 hidden 标记**。藏起来只剩一个软链接的话，
#    用户看到的是「这 dmg 里啥都没有」，不知道该拖什么。
#    之前版本用 `chflags hidden` 把app 藏了，是错的。
#
# 想排窗口布局需要写 .DS_Store，但挂载点只读写不了，而且正经做法要用
# osascript 驱动 Finder（会抢前台焦点）。权衡后放弃：app 和软链接
# 默认就在同一行并排，用户拖拽照样成立，不值得为排版引入副作用。
# 装 create-dmg（brew install create-dmg）可以一步到位，那之后再考虑。

echo "   暂存内容："
ls -la "$STAGE" | sed 's/^/     /'

# ── 4/6 生成 DMG ────────────────────────────────────────────────────────
echo "== [3/5] 生成 DMG =="
# UDBZ = bzip2 压缩的只读 UDIF。DMG 默认就是这个格式，Finder 双击直接挂载。
# 不用 -format UDCO（压缩优化但更慢，1.2M 的包不值得）。
hdiutil create \
  -srcfolder "$STAGE" \
  -volname "$VOLNAME" \
  -fs HFS+ \
  -format UDBZ \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null 2>&1 || {
    echo "错误：hdiutil create 失败。下面是详细输出：" >&2
    hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDBZ "$DMG"
    exit 1
  }

# ── 4/6 布局说明（不做） ────────────────────────────────────────────────
# 常见做法是往 dmg 里塞一个 .DS_Store，让 Finder 打开时把窗口排成
# 「app 在左、Applications 在右」。这里刻意不做，原因有三：
#   1. 需要先挂载 dmg、写 .DS_Store、再卸载重打，流程里挂载点必然只读，
#      写 .DS_Store 会直接 "Read-only file system" 失败（第一版就踩了这个）。
#   2. 正经做法是 osascript 驱动 Finder 排序，会短暂抢走前台焦点 —— 对一个
#      无人值守的构建脚本来说是副作用。
#   3. app 已经用 SetFile 隐藏了，拖拽窗口里本来就只有 Applications 软链接，
#      默认布局已经够干净。
# 想要图标位置排序的话装 create-dmg（brew install create-dmg）再改。

# ── 5/6 校验 ────────────────────────────────────────────────────────────
echo "== [4/5] 校验 =="
VERIFY_OUT="$(hdiutil verify "$DMG" 2>&1 || true)"
if echo "$VERIFY_OUT" | grep -qi "checksum"; then
  echo "   ✅ hdiutil verify 通过（checksum 正确）"
else
  echo "   ⚠️  hdiutil verify 输出异常，请人工确认：" >&2
  echo "$VERIFY_OUT" | sed 's/^/      /' >&2
fi

# 挂载一次，验证里面的 app 能读、签名没坏
#
# ⚠️ 必须用 diskutil，**不能用 `hdiutil attach -mountpoint`**：
# 那组参数已废弃，且 `hdiutil detach <挂载点>` 会**静默失败** ——
# 每次打包都会泄漏一个挂载记录。攒到几个之后，系统认为这个 dmg「已经挂着了」，
# 用户双击它**不会有任何反应**（这个故障真实发生过：攒了 9 个）。
# 另外用 trap 保证异常退出也卸载，而不是只在正常路径卸载。
echo "   验证 dmg 内容…"
VP="$(mktemp -d "/tmp/hf-verify.XXXXXX")"
cleanup_verify() { diskutil eject "$VP" >/dev/null 2>&1 || true; rm -rf "$VP"; }
trap cleanup_verify EXIT

if diskutil image attach "$DMG" --mountPoint "$VP" --mountOptions nobrowse,ro >/dev/null 2>&1; then
  if [ -d "$VP/HoverFocus.app" ]; then
    echo "   ✅ 内含 HoverFocus.app"
  else
    echo "   ❌ dmg 里没有 HoverFocus.app" >&2
    exit 1
  fi
  if codesign -v "$VP/HoverFocus.app" 2>&1; then
    echo "   ✅ dmg 里的 app 签名仍然有效"
  else
    echo "   ❌ dmg 里的 app 签名校验失败 —— 暂存拷贝破坏了签名" >&2
    exit 1
  fi
else
  echo "   ⚠️  挂载验证失败，跳过" >&2
fi
cleanup_verify
trap - EXIT

rm -rf "$STAGE"

# ── 输出 ────────────────────────────────────────────────────────────────
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "== [5/5] 完成 =="
echo "   dmg: $DMG"
echo "   体积: $SIZE"
echo ""
echo "   签名类型：自签证书（Authority = HoverFocus Dev），非 Apple Developer ID。"
if [ "$KEEP_MOUNTED" -eq 1 ]; then
  hdiutil attach "$DMG" -nobrowse
  echo ""
  echo "   已保持挂载（--open）。卸载：hdiutil detach /Volumes/HoverFocus\\ $VERSION"
else
  echo "   在别人机器上首次打开需要右键 → 打开（自签证书的限制，见脚本头部说明）。"
fi