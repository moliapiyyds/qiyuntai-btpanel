#!/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 仓库自检（拦语法类回归）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 本地和 CI 跑的是同一个：  sh tools/ci.sh
#
# 查 6 项：
#   1) shellcheck   —— 所有 .sh / .initd，-S warning，0 告警才算过
#   2) sh -n        —— 纯语法基线（不依赖 shellcheck 是否装上）
#   3) py_compile   —— tools/*.py
#   4) node --check —— 有 .js/.mjs/.cjs 才查；一个都没有会明确说出来，不静默跳过
#   5) 行尾         —— 设备侧脚本不能有 CRLF（设备上会跑出奇怪错误）
#   6) 编码         —— deploy.ps1 必须带 UTF-8 BOM
#                      （无 BOM 会被 PowerShell 5.1 按 GBK 解析而语法报错，实测踩过 5 次）
#
# 退出码：0 = 全过，1 = 有失败项
# ============================================================
set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
pass() { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [失败] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  [跳过] %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

# 受管文件清单：优先用 git（CI 和本地都适用），退化到 find
list_files() {
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files "$@"
        return
    fi
    # 没有 .git（比如从 release zip 解出来的目录）：逐个模式 find
    for pat in "$@"; do
        find . -path ./.git -prune -o -type f -name "$pat" -print | sed 's|^\./||'
    done
}

SH_FILES=$(list_files '*.sh' '*.initd')
PY_FILES=$(list_files '*.py')
JS_FILES=$(list_files '*.js' '*.mjs' '*.cjs')

# ---------- 1) shellcheck ----------
head_ "1) shellcheck（-S warning）"
if command -v shellcheck >/dev/null 2>&1; then
    SC_OUT=$(shellcheck -S warning -f gcc $SH_FILES 2>&1)
    if [ -z "$SC_OUT" ]; then
        pass "shellcheck 无告警（$(printf '%s\n' $SH_FILES | wc -l | tr -d ' ') 个文件）"
    else
        printf '%s\n' "$SC_OUT" | sed 's/^/         /'
        bad "shellcheck 有告警，见上"
    fi
else
    if [ "${CI:-}" = "true" ]; then
        bad "CI 环境里没有 shellcheck（本地可跳过，CI 不允许静默跳过）"
    else
        skip "没装 shellcheck。装：apt/dnf install shellcheck，或用官方静态二进制"
    fi
fi

# ---------- 2) sh -n 语法基线 ----------
head_ "2) sh -n 语法基线"
n_bad=0
for f in $SH_FILES; do
    if ! sh -n "$f" 2>/dev/null; then
        sh -n "$f" 2>&1 | sed 's/^/         /'
        bad "sh -n 失败: $f"
        n_bad=$((n_bad + 1))
    fi
done
[ "$n_bad" = 0 ] && pass "全部通过"

# ---------- 3) python py_compile ----------
head_ "3) python3 -m py_compile"
if command -v python3 >/dev/null 2>&1; then
    n_bad=0
    for f in $PY_FILES; do
        if ! python3 -m py_compile "$f" 2>/tmp/qyt_ci_py.err; then
            sed 's/^/         /' /tmp/qyt_ci_py.err
            bad "py_compile 失败: $f"
            n_bad=$((n_bad + 1))
        fi
    done
    rm -rf tools/__pycache__ __pycache__ /tmp/qyt_ci_py.err
    [ "$n_bad" = 0 ] && pass "$(printf '%s\n' $PY_FILES | wc -l | tr -d ' ') 个文件全部编译通过"
else
    if [ "${CI:-}" = "true" ]; then bad "CI 环境里没有 python3"; else skip "没有 python3"; fi
fi

# ---------- 4) node --check ----------
head_ "4) node --check（JS）"
if [ -z "$JS_FILES" ]; then
    skip "本仓库当前没有任何 .js/.mjs/.cjs 文件 —— 这一项没有作用对象（不是静默通过）"
elif command -v node >/dev/null 2>&1; then
    n_bad=0
    for f in $JS_FILES; do
        if ! node --check "$f" 2>&1 | sed 's/^/         /'; then
            bad "node --check 失败: $f"
            n_bad=$((n_bad + 1))
        fi
    done
    [ "$n_bad" = 0 ] && pass "全部通过"
else
    if [ "${CI:-}" = "true" ]; then bad "有 JS 文件但 CI 里没有 node"; else skip "有 JS 文件但本地没有 node"; fi
fi

# ---------- 5) 行尾：设备侧脚本不能有 CRLF ----------
head_ "5) 行尾检查（CRLF）"
CR=$(printf '\r')
n_bad=0
for f in $SH_FILES install/bt-panel-install.exp; do
    [ -f "$f" ] || continue
    if LC_ALL=C grep -q "$CR" "$f" 2>/dev/null; then
        bad "$f 含 CRLF（设备侧脚本必须是 LF）"
        n_bad=$((n_bad + 1))
    fi
done
[ "$n_bad" = 0 ] && pass "全部是 LF"

# ---------- 6) deploy.ps1 必须带 UTF-8 BOM ----------
head_ "6) deploy.ps1 编码（UTF-8 BOM）"
if [ -f deploy.ps1 ]; then
    BOM=$(head -c3 deploy.ps1 | od -An -tx1 | tr -d ' \n')
    if [ "$BOM" = "efbbbf" ]; then
        pass "前 3 字节 = efbbbf（带 BOM）"
    else
        bad "deploy.ps1 前 3 字节是 $BOM，不是 efbbbf —— 少了 BOM 会在 PowerShell 5.1 上语法报错"
    fi
else
    bad "找不到 deploy.ps1"
fi

# ---------- 7) installer.lock 的哈希格式 ----------
head_ "7) install/installer.lock 哈希格式"
if [ -f install/installer.lock ]; then
    n_bad=0
    n=0
    while read -r h _rest; do
        case "$h" in
            ''|'#'*) continue ;;
        esac
        n=$((n + 1))
        if ! printf '%s' "$h" | grep -Eq '^[0-9a-f]{64}$'; then
            bad "不是 64 位小写 hex: $h"
            n_bad=$((n_bad + 1))
        fi
    done < install/installer.lock
    if [ "$n" = 0 ]; then
        bad "installer.lock 里一条哈希都没有 —— 校验会永远不命中，等于没校验"
    elif [ "$n_bad" = 0 ]; then
        pass "$n 条哈希格式正确"
    fi
else
    bad "找不到 install/installer.lock"
fi

# ---------- 汇总 ----------
printf '\n============================================================\n'
if [ "$FAIL" = 0 ]; then
    printf ' 全部通过\n'
else
    printf ' 有 %s 项失败\n' "$FAIL"
fi
printf '============================================================\n'
exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
