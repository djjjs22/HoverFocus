#!/bin/bash
#  脚本静态检查
#
#  为什么需要这个：bash 会把「$VAR 紧跟一个多字节字符」里的中文首字节**吞进变量名**，
#  在 `set -u` 下直接报 `DEST_APP?: unbound variable` 并以非 0 退出。
#  这个 bug 已经真实发生过三次：
#    ① install.sh：脚本在「停止旧实例」之后静默退出，App 看起来装好了其实没装；
#    ② 重写脚本后又引入 4 处，`make install` 再次静默失败；
#    ③ 本文件自己的自测段（`$CHECK）`）。
#  后果很隐蔽：脚本半途中止，但前面已经打印了一堆成功信息。
#
#  所以这里做三件事：
#    ① `bash -n` 语法检查
#    ② 扫描「$VAR + 非 ASCII」写法
#    ③ **给扫描器做自测** —— 一个永远通过的检查等于没有检查；
#       一个总喊狼来了的检查会被无视，也等于没有检查。两者都要防。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

# ── 扫描器：只写一份，第 2、3 步共用 ────────────────────────────────────────
# 用法：scan <含 Scripts/ 的目录>
# 输出：每个命中一行「文件:行号 变量名」，末行 __FOUND__=N
scan() {
python3 - "$1" <<'PY'
import re, sys, glob, os

HEREDOC = re.compile(rb'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')

def _walk(line: bytes, drop_single_quoted: bool) -> bytes:
    """按 shell 的引号规则走一遍，产出「需要被检查」的文本。

    drop_single_quoted=True  → 单引号内容丢掉（它不展开，不该被检查）
    drop_single_quoted=False → 单引号内容保留（用来找 heredoc 定界符，
                               因为 `<<'PY'` 的定界符本身就在单引号里）
    """
    out = bytearray()
    i, n = 0, len(line)
    in_single = in_double = False
    while i < n:
        c = line[i:i+1]
        if in_single:
            if drop_single_quoted:
                if c == b"'":
                    in_single = False
                i += 1
                continue
            out += c
            if c == b"'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == b'\\':
                out += line[i:i+2]
                i += 2
                continue
            if c == b'"':
                in_double = False
            out += c
            i += 1
            continue
        if c == b'\\':
            i += 2
            continue
        if c == b"'":
            in_single = True
            i += 1
            continue
        if c == b'"':
            in_double = True
            out += c
            i += 1
            continue
        if c == b'#' and (i == 0 or line[i-1:i] in (b' ', b'\t', b';', b'|', b'&', b'(')):
            break
        out += c
        i += 1
    return bytes(out)


def scannable(line: bytes) -> bytes:
    """只留真正会做变量展开的 shell 代码：去注释、去单引号内容、保留双引号内容。

    不去注释会假阳性（注释里写「不要用 $VAR」也会被判错）；
    不去单引号也会假阳性（单引号里 shell 不展开）。
    """
    return _walk(line, drop_single_quoted=True)

def shell_code_lines(data: bytes):
    """逐行产出「真正会被 bash 执行的代码行」，跳过 heredoc 正文。

    heredoc（`<<'PY'` … `PY`）里的内容是别的语言的源码，bash 不做变量展开，
    所以不能按 shell 规则扫描 —— 否则本文件里的 Python 文档字符串会被自己误报。
    """
    heredoc = None
    for i, line in enumerate(data.split(b'\n'), 1):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        yield i, line
        m = HEREDOC.search(_walk(line, drop_single_quoted=False))
        if m:
            heredoc = m.group(1)

pat = re.compile(rb'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])')
root = sys.argv[1]
found = 0
for f in sorted(glob.glob(os.path.join(root, 'Scripts', '*.sh'))):
    data = open(f, 'rb').read()
    for i, line in shell_code_lines(data):
        m = pat.search(scannable(line))
        if m:
            found += 1
            print(f"   ❌ {os.path.basename(f)}:{i}  ${m.group(1).decode()} 紧跟中文 → 请写成 ${{...}}")
print(f"__FOUND__={found}")
PY
}

echo "== 1. 语法检查（bash -n）=="
for f in "$ROOT"/Scripts/*.sh "$ROOT"/Makefile; do
  [ -f "$f" ] || continue
  if [ "${f##*.}" = "sh" ]; then
    if bash -n "$f" 2>/dev/null; then
      echo "   ✅ $(basename "$f")"
    else
      echo "   ❌ $(basename "$f") 语法错误"
      bash -n "$f" 2>&1 | sed 's/^/      /'
      FAIL=1
    fi
  fi
done

echo
echo "== 2. 扫描「\$VAR 紧跟多字节字符」（会导致 unbound variable 静默中止）=="
HITS="$(scan "$ROOT")"
echo "$HITS" | grep -v "^__FOUND__="
if echo "$HITS" | grep -q "__FOUND__=[1-9]"; then
  FAIL=1
else
  echo "   ✅ 没有这种写法"
fi

echo
echo "== 3. 扫描器自测（防「永远通过」也防「总喊狼来了」）=="
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT
mkdir -p "$SELFTEST_DIR/Scripts"
# ① 真错误：变量名后直接跟中文 → 必须检出
printf 'DEST="x"\necho "$DEST；装好了"\n' > "$SELFTEST_DIR/Scripts/bad.sh"
# ② 注释里提到这种写法 → 不得检出（假阳性来源）
printf '# 注意：不要写 $VAR，要写 ${VAR}\necho "ok"\n' > "$SELFTEST_DIR/Scripts/comment.sh"
# ③ 单引号里 → 不展开，不得检出
printf "echo 'literal \$VAR 中文'\n" > "$SELFTEST_DIR/Scripts/single.sh"
# ④ 正确写法 → 不得检出
printf 'DEST="x"\necho "${DEST}；装好了"\n' > "$SELFTEST_DIR/Scripts/good.sh"
# ⑤ heredoc 正文里（别的语言源码）→ 不得检出
printf 'cat <<%s\nx = "$VAR 中文"\nPY\n' "'PY'" > "$SELFTEST_DIR/Scripts/heredoc.sh"
CHECK="$(scan "$SELFTEST_DIR" | grep -v '^__FOUND__=' | sed 's/.*❌ //; s/:.*//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$CHECK" = "bad.sh" ]; then
  echo "   ✅ 真错误检出；注释 / 单引号 / heredoc / 正确写法均不误报"
else
  echo "   ❌ 自测失败：期望只命中 bad.sh，实际命中「${CHECK}」"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结果: PASS ✅"
  exit 0
else
  echo "结果: FAIL ❌"
  exit 1
fi
