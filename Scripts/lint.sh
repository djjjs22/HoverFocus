#!/bin/bash
#  脚本静态检查
#
#  为什么需要这个：本机 bash 在非 UTF-8 locale 下会把「$VAR 紧跟一个多字节字符」
#  （例如 `${DEST_APP}；`、`${BUILD_BIN}（` 这种**正确写法**；错误写法是变量名后面直接跟中文）里的中文首字节**吞进变量名**，
#  在 `set -u` 下直接报 `DEST_APP?: unbound variable` 并以非 0 退出。
#  这个 bug 已经真实发生过两次：
#    ① install.sh 第一次：脚本在「停止旧实例」之后静默退出，App 看起来装好了其实没装；
#    ② 重写脚本后又引入 4 处，`make install` 再次静默失败。
#  后果很隐蔽：安装/构建脚本半途中止，但前面已经打印了一堆成功信息。
#
#  所以这里做两件事：① `bash -n` 语法检查；② 扫描这类「$VAR + 非 ASCII」写法。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "== 1. 语法检查（bash -n）=="
for f in "$ROOT"/Scripts/*.sh "$ROOT"/Makefile; do
  [ -f "$f" ] || continue
  case "$f" in
    *Makefile) make -n -f "$f" kill >/dev/null 2>&1 || true ;;
  esac
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
HITS=$(python3 - "$ROOT" <<'PY'
import re, sys, glob, os
root = sys.argv[1]
pat = re.compile(rb'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])')
found = 0
for f in sorted(glob.glob(os.path.join(root, 'Scripts', '*.sh'))):
    data = open(f, 'rb').read()
    for i, line in enumerate(data.split(b'\n'), 1):
        if pat.search(line):
            found += 1
            print(f"   ❌ {os.path.basename(f)}:{i}  ${pat.search(line).group(1).decode()} 紧跟中文 → 请写成 ${{...}}")
print(f"__FOUND__={found}")
PY
)
echo "$HITS" | grep -v "^__FOUND__=" 
if echo "$HITS" | grep -q "__FOUND__=[1-9]"; then
  FAIL=1
else
  echo "   ✅ 没有这种写法"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结果: PASS ✅"
  exit 0
else
  echo "结果: FAIL ❌"
  exit 1
fi
