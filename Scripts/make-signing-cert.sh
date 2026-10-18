#!/bin/bash
#  HoverFocus — 自签代码签名证书（app-shell 维护）
#  ─────────────────────────────────────────────────────────────────────────
#  为什么需要这个：
#    ad-hoc 签名（codesign --sign -）没有稳定的身份。系统「辅助功能」授权是按
#    指定要求（Designated Requirement）记账的，ad-hoc 的 DR 是 `cdhash H"..."` ——
#    每次重新编译 cdhash 都变，于是用户每次 make app 之后都要去系统设置里
#    重新勾一遍 HoverFocus。这在一个要反复重建的开发期里非常折磨人。
#
#    用自签证书签名后，DR 变成：
#      identifier "com.lunasama.HoverFocus" and certificate leaf = H"<证书指纹>"
#    证书不变 → DR 不变 → 辅助功能授权在重新构建后依然有效。
#
#  实现要点（都是踩过的坑，别改）：
#    1. 用一个**专用钥匙串**（~/Library/Keychains/hoverfocus-signing.keychain-db），
#       不用登录钥匙串。原因：codesign 从登录钥匙串取私钥会弹 SecurityAgent 的
#       「输入登录密码」模态框，脚本会挂死，而且 Agent 没法点那个框。
#       专用钥匙串的密码由本脚本自己生成并保存，可以非交互解锁。
#    2. 必须调 `security set-key-partition-list`。只 import 不设 partition list 的话，
#       codesign 依然会弹框（实测：codesign 卡住不返回）。
#    3. p12 必须用 PBE-SHA1-3DES + macalg sha1 导出。OpenSSL 3 默认用 AES-256-CBC +
#       PBKDF2，macOS 的 security 读不了，会报 "MAC verification failed"。
#       而且密码不能为空（空密码在 OpenSSL 3 与 macOS 之间语义不一致）。
#    4. 证书**不需要**被系统信任。实测：未信任的自签证书 codesign 也能正常签，
#       签名不是 ad-hoc（flags=0x0、Signature size>0），DR 也是稳定的。
#       所以本脚本不需要 sudo、不需要 add-trusted-cert、不弹任何框。
#
#  用法：
#    bash Scripts/make-signing-cert.sh              # 创建/修复（幂等）
#    bash Scripts/make-signing-cert.sh --check      # 只检查是否可用（exit 0/1）
#    bash Scripts/make-signing-cert.sh --unlock     # 解锁钥匙串（build.sh 用）
#    bash Scripts/make-signing-cert.sh --keychain-path  # 打印钥匙串路径
#    bash Scripts/make-signing-cert.sh --uninstall  # 删除证书与钥匙串（可逆）
#  ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

IDENTITY="HoverFocus Dev"
KEYCHAIN_NAME="hoverfocus-signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}"
SUPPORT_DIR="$HOME/Library/Application Support/HoverFocus"
PASSWORD_FILE="${SUPPORT_DIR}/signing-keychain-password"
CERT_DAYS=3650

# 临时工作目录（里面有私钥），无论成功失败都要清掉
WORK_DIR=""
cleanup_workdir() {
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  WORK_DIR=""
}
trap cleanup_workdir EXIT

log()  { echo "[make-signing-cert] $*"; }
warn() { echo "[make-signing-cert][警告] $*" >&2; }
fail() { echo "[make-signing-cert][错误] $*" >&2; exit 1; }

# ── 前置检查 ────────────────────────────────────────────────────────────
command -v openssl  >/dev/null 2>&1 || fail "找不到 openssl（macOS 自带 /usr/bin/openssl，请检查 PATH）"
command -v security >/dev/null 2>&1 || fail "找不到 security 命令（系统自带的钥匙串工具，不该缺）"
command -v codesign >/dev/null 2>&1 || fail "找不到 codesign（请先装 Command Line Tools：xcode-select --install）"

# ── 基础操作 ────────────────────────────────────────────────────────────
# 钥匙串里是否有「证书 + 私钥」都齐的身份
have_identity() {
  [ -f "${KEYCHAIN_PATH}" ] || return 1
  security find-identity -p codesigning "${KEYCHAIN_PATH}" 2>/dev/null | grep -q "${IDENTITY}"
}

read_password() {
  [ -f "${PASSWORD_FILE}" ] || return 1
  cat "${PASSWORD_FILE}"
}

unlock_keychain() {
  local pass
  pass="$(read_password)" || return 1
  security unlock-keychain -p "$pass" "${KEYCHAIN_PATH}" >/dev/null 2>&1
}

# 把专用钥匙串加进用户搜索列表（幂等；不改动已有的其它钥匙串）
ensure_search_list() {
  local current=() line cleaned
  while IFS= read -r line; do
    cleaned="${line#"${line%%[![:space:]]*}"}"   # 去左空白
    cleaned="${cleaned%\"}"; cleaned="${cleaned#\"}"  # 去引号
    [ -n "$cleaned" ] && current+=("$cleaned")
  done < <(security list-keychains -d user 2>/dev/null || true)

  local k
  for k in "${current[@]:-}"; do
    [ -n "$k" ] || continue
    if [ "$k" = "${KEYCHAIN_PATH}" ]; then
      return 0    # 已经在列表里
    fi
  done

  security list-keychains -d user -s "${current[@]:-}" "${KEYCHAIN_PATH}" >/dev/null 2>&1 \
    || warn "把签名钥匙串加进搜索列表失败（不影响构建，build.sh 会显式指定 --keychain）"
}

ensure_partition_list() {
  local pass
  pass="$(read_password)" || fail "读不到钥匙串密码：${PASSWORD_FILE}"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "${KEYCHAIN_PATH}" >/dev/null 2>&1 \
    || fail "设置 partition list 失败 —— codesign 取私钥时会弹框卡住。请重跑本脚本。"
}

# 真签一个二进制来验证：只看 find-identity 不够，要确认签名不是 ad-hoc、
# 且指定要求是稳定的「certificate leaf」而不是易变的 cdhash。
verify_signing() {
  local probe
  probe="$(mktemp "${TMPDIR:-/tmp}/hoverfocus-signprobe.XXXXXX")"
  cp /bin/ls "$probe" || { rm -f "$probe"; return 1; }
  chmod +w "$probe"

  if ! codesign --keychain "${KEYCHAIN_PATH}" --force --sign "${IDENTITY}" --identifier com.lunasama.HoverFocus "$probe" >/dev/null 2>&1; then
    rm -f "$probe"
    return 1
  fi

  local dr flags
  dr="$(codesign -d -r- "$probe" 2>&1 || true)"
  flags="$(codesign -dv "$probe" 2>&1 | grep -E '^CodeDirectory' || true)"
  rm -f "$probe"

  case "${dr}" in
    *"certificate leaf"*) ;;
    *) warn "签名后的指定要求里没有 certificate leaf，说明退化成了 ad-hoc：
${dr}"; return 1 ;;
  esac

  case "${flags}" in
    *adhoc*) warn "codesign 仍然产出 ad-hoc 签名：${flags}"; return 1 ;;
  esac

  return 0
}

# ── 创建 / 修复 ─────────────────────────────────────────────────────────
create_keychain() {
  local kcpass="$1"
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1 || true
  security create-keychain -p "$kcpass" "${KEYCHAIN_PATH}" >/dev/null 2>&1 \
    || fail "创建钥匙串失败：${KEYCHAIN_PATH}（检查 ~/Library/Keychains 是否可写）"
  # 6 小时不活动后自动上锁；build.sh 每次构建前会用保存的密码解锁
  security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}" >/dev/null 2>&1 || true
  security unlock-keychain -p "$kcpass" "${KEYCHAIN_PATH}" >/dev/null 2>&1 \
    || fail "解锁新建钥匙串失败"
}

generate_and_import() {
  local kcpass="$1"
  local p12pass
  p12pass="$(openssl rand -hex 24)"

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/hoverfocus-cert.XXXXXX")"
  WORK_DIR="$work"    # 交给 EXIT trap 清理（含失败路径，别留私钥在 /tmp）

  cat > "$work/openssl.cnf" <<'OPENSSL_CNF'
[ req ]
distinguished_name = dn
x509_extensions    = codesign_ext
prompt             = no
[ dn ]
CN = HoverFocus Dev
[ codesign_ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
OPENSSL_CNF

  log "生成自签证书（RSA 2048，有效期 ${CERT_DAYS} 天）…"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days "${CERT_DAYS}" -config "$work/openssl.cnf" >/dev/null 2>&1 \
    || fail "openssl 生成证书失败"

  # PBE-SHA1-3DES + macalg sha1 是给 macOS security 读的，不是安全降级：
  # 这是本地开发签名用的临时证书，不参与分发。见文件头说明第 3 条。
  openssl pkcs12 -export -out "$work/cert.p12" \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -passout "pass:$p12pass" -name "${IDENTITY}" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
    || fail "openssl 导出 p12 失败"

  log "导入到专用钥匙串…"
  security import "$work/cert.p12" -k "${KEYCHAIN_PATH}" -P "$p12pass" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 \
    || fail "导入证书失败（钥匙串：${KEYCHAIN_PATH}）"

  # 立刻清掉临时私钥
  rm -rf "$work"
  WORK_DIR=""
}

ensure_ready() {
  local kcpass

  if [ -f "${PASSWORD_FILE}" ]; then
    kcpass="$(cat "${PASSWORD_FILE}")"
  else
    kcpass="$(openssl rand -hex 24)"
    mkdir -p "${SUPPORT_DIR}"
    ( umask 077; printf '%s' "$kcpass" > "${PASSWORD_FILE}" ) \
      || fail "写钥匙串密码文件失败：${PASSWORD_FILE}"
    log "已生成钥匙串密码并保存到：${PASSWORD_FILE}（权限 0600）"
  fi

  if have_identity; then
    log "已存在身份「${IDENTITY}」，跳过创建（幂等）"
    unlock_keychain || fail "解锁已有钥匙串失败：${KEYCHAIN_PATH}"
    ensure_partition_list
    ensure_search_list
    return 0
  fi

  if [ -f "${KEYCHAIN_PATH}" ]; then
    warn "钥匙串存在但里面没有可用的「${IDENTITY}」身份，重建"
  fi

  create_keychain "$kcpass"
  generate_and_import "$kcpass"
  ensure_partition_list
  ensure_search_list

  have_identity || fail "导入后仍然找不到身份「${IDENTITY}」，创建失败"
}

# ── 子命令 ──────────────────────────────────────────────────────────────
cmd_check() {
  if ! have_identity; then
    echo "未就绪：找不到签名身份「${IDENTITY}」（钥匙串：${KEYCHAIN_PATH}）"
    exit 1
  fi
  unlock_keychain || { echo "未就绪：钥匙串无法解锁"; exit 1; }
  if verify_signing; then
    echo "就绪：${IDENTITY} @ ${KEYCHAIN_PATH}"
    exit 0
  fi
  echo "未就绪：签名验证失败（可能是 partition list 丢失或私钥不可用）"
  exit 1
}

cmd_uninstall() {
  log "卸载自签证书与专用钥匙串…"
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1 && log "已删除钥匙串 ${KEYCHAIN_PATH}" || log "钥匙串不存在，跳过"

  # 从搜索列表里摘掉
  local current=() line cleaned
  while IFS= read -r line; do
    cleaned="${line#"${line%%[![:space:]]*}"}"
    cleaned="${cleaned%\"}"; cleaned="${cleaned#\"}"
    [ -n "$cleaned" ] || continue
    [ "$cleaned" = "${KEYCHAIN_PATH}" ] && continue
    current+=("$cleaned")
  done < <(security list-keychains -d user 2>/dev/null || true)
  if [ "${#current[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${current[@]}" >/dev/null 2>&1 || true
  fi

  rm -f "${PASSWORD_FILE}"
  log "完成。build.sh 会退回 ad-hoc 签名（辅助功能授权会随重建失效）。"
}

cmd_help() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  --check)        cmd_check ;;
  --unlock)       unlock_keychain && log "钥匙串已解锁：${KEYCHAIN_PATH}" || fail "解锁失败：${KEYCHAIN_PATH}" ;;
  --keychain-path) echo "${KEYCHAIN_PATH}" ;;
  --uninstall)    cmd_uninstall ;;
  -h|--help)      cmd_help ;;
  "")
    ensure_ready
    if verify_signing; then
      log "✅ 签名身份可用：${IDENTITY}"
      log "   钥匙串：${KEYCHAIN_PATH}"
      log "   指定要求（辅助功能授权就靠它稳定）："
      local_probe="$(mktemp "${TMPDIR:-/tmp}/hoverfocus-dr.XXXXXX")"
      cp /bin/ls "$local_probe" && codesign --keychain "${KEYCHAIN_PATH}" --force --sign "${IDENTITY}" --identifier com.lunasama.HoverFocus "$local_probe" >/dev/null 2>&1
      codesign -d -r- "$local_probe" 2>&1 | sed 's/^/     /' || true
      rm -f "$local_probe"
      log "   现在可以跑 make app 了，构建会自动用这个证书签名。"
    else
      fail "证书已创建但签名验证失败，请把上面的报错发出来"
    fi
    ;;
  *) fail "不认识的参数：${1}（用 --help 看用法）" ;;
esac
