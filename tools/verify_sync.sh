#!/bin/bash
# ============================================================
# 本地文件 vs GitHub 远端 —— 逐文件比对（只比 sha，不下载内容）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 为什么需要这个：以前发布靠 publish_qiyuntai.ps1 逐文件调 Contents API，
# 没有 diff 就没有「漏了哪个文件」的检查 —— v1.2.3 就漏推过 module/service.sh
# （本地 10696 字节、远端还是 9987 字节的旧版，装到别人机器上开机不拉 sshd）。
#
# 用法：
#   bash tools/verify_sync.sh            # 比对，只报告
#   bash tools/verify_sync.sh --list     # 顺带打印远端文件清单
#
# 查两件事：
#   1) 工作区 vs git 远端逐文件 sha（看有没有漏推）
#   2) Release 附件新鲜度 —— module/ 改了但没重打 zip / 没覆盖附件，
#      只有这一项能发现（实测就这么漏过一次：附件 17306 字节，重打的已 17419）
#
# 依赖：gh（已登录）、python3、git、sha256sum
# 可用环境变量覆盖：GH / REPO / BRANCH
# 退出码：0 全部一致；2 git 树不一致；3 Release 附件过期/取不到
# ============================================================
set -u

GH="${GH:-/mnt/c/Program Files/GitHub CLI/gh.exe}"
REPO="${REPO:-moliapiyyds/qiyuntai-btpanel}"
BRANCH="${BRANCH:-main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE=/tmp/qyt_remote_tree.json
SHOW_LIST=0
[ "${1:-}" = "--list" ] && SHOW_LIST=1

[ -x "$GH" ] || { echo "x 找不到 gh：$GH（用 GH=/path/to/gh 覆盖）"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "x 需要 python3"; exit 1; }

echo "=== 远端：$REPO@$BRANCH ==="
"$GH" api "repos/$REPO/git/trees/$BRANCH?recursive=1" > "$TREE" 2>/tmp/qyt_gh_err || {
    echo "x 取远端文件树失败："; cat /tmp/qyt_gh_err; exit 1
}

# 本地文件清单：优先用 git（会尊重 .gitignore），否则退回 find
cd "$ROOT" || exit 1
if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files > /tmp/qyt_local_files.txt
    MODE="git ls-files"
else
    find . -type f -not -path './.git/*' | sed 's|^\./||' | sort > /tmp/qyt_local_files.txt
    MODE="find（不看 .gitignore）"
fi
echo "=== 本地：$ROOT（$MODE） ==="
echo

python3 - "$TREE" /tmp/qyt_local_files.txt "$ROOT" "$SHOW_LIST" <<'PY'
import json, subprocess, sys, os

tree_json, local_list, root, show = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == '1'

d = json.load(open(tree_json, encoding='utf-8-sig'))
remote = {e['path']: e.get('sha') for e in d.get('tree', []) if e['type'] == 'blob'}

local = [l.strip() for l in open(local_list, encoding='utf-8') if l.strip()]

if show:
    print("远端文件清单：")
    for p in sorted(remote):
        print("  %s" % p)
    print()

missing  = []   # 本地没有，远端有
diff     = []   # 两边都有但内容不同
only_loc = []   # 本地有，远端没有

for rel in sorted(local):
    try:
        sha = subprocess.run(['git', 'hash-object', os.path.join(root, rel)],
                             capture_output=True, text=True, check=True).stdout.strip()
    except Exception as e:
        print("  [WARN] 算不出 sha：%s (%s)" % (rel, e)); continue
    if rel not in remote:
        only_loc.append(rel)
    elif remote[rel] != sha:
        diff.append(rel)

for rel in sorted(remote):
    if rel not in local:
        missing.append(rel)

print("=" * 64)
if diff:
    print("!! 内容不同（本地改了但没推上去）—— %d 个：" % len(diff))
    for p in diff:
        lsz = os.path.getsize(os.path.join(root, p))
        print("   %-40s 本地 %d 字节" % (p, lsz))
else:
    print("内容不同的文件：无")

if only_loc:
    print("!! 只在本地有（没推上去）—— %d 个：" % len(only_loc))
    for p in only_loc: print("   %s" % p)
else:
    print("只在本地有的文件：无")

if missing:
    print("?? 只在远端有（本地删了但没同步）—— %d 个：" % len(missing))
    for p in missing: print("   %s" % p)
else:
    print("只在远端有的文件：无")
print("=" * 64)

if not diff and not only_loc and not missing:
    print(">> 本地与远端完全一致")
    sys.exit(0)
print(">> 不一致，需要推送或同步")
sys.exit(2)
PY
TREE_RC=$?

# ---------- Release 附件新鲜度 ----------
# 为什么单独查这一项：上面只比「工作区 vs git 树」，而 module/ 改了之后
# 忘记重打 zip、或忘记覆盖 Release 附件，git 树是完全看不出来的。
# GitHub 的 release asset 带 digest 字段（sha256），并且 build_module_zip.sh
# 对同一份内容产出可复现的 zip（实测两次构建 sha256 相同），所以能直接逐字节比。
REL_RC=0
echo
echo "=== Release 附件新鲜度 ==="
if [ ! -f "$ROOT/tools/build_module_zip.sh" ]; then
    echo "  跳过：找不到 tools/build_module_zip.sh"
else
    # 先清掉旧产物，免得把上一次的 zip 当成这次的
    rm -f "$ROOT"/_dist/qiyuntai_btpanel-*.zip 2>/dev/null
    sh "$ROOT/tools/build_module_zip.sh" >/tmp/qyt_build_zip.log 2>&1
    ZIP=$(ls -t "$ROOT"/_dist/qiyuntai_btpanel-*.zip 2>/dev/null | head -1)
    if [ -z "$ZIP" ] || [ ! -f "$ZIP" ]; then
        echo "  !! 重打 zip 失败（看 /tmp/qyt_build_zip.log）"
        REL_RC=3
    else
        # 附件名就是 zip 文件名，tag 由它去掉前缀和 .zip 反推。
        # 注意：module.prop 里 version 本身就带 v（version=v1.2.3），
        # 所以不能写成 "v$version"，否则会拼出 qiyuntai_btpanel-vv1.2.3.zip
        # 这种不存在的名字，检查会误报「重打失败」（实测踩过）。
        ASSET=$(basename "$ZIP")
        TAG=${ASSET#qiyuntai_btpanel-}
        TAG=${TAG%.zip}
        LOCAL_SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
        REMOTE_SHA=$("$GH" api "repos/$REPO/releases/tags/$TAG" \
            --jq ".assets[] | select(.name==\"$ASSET\") | .digest" 2>/dev/null \
            | sed 's/^sha256://' | tr -d '\r' | head -1)
        if [ -z "$REMOTE_SHA" ]; then
            echo "  ?? Release $TAG 里没有附件 $ASSET（或取不到 digest）"
            REL_RC=3
        elif [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
            echo "  一致：$ASSET  sha256=${LOCAL_SHA:0:16}…"
        else
            echo "  !! Release 附件过期：$ASSET"
            echo "     本地重打的 zip : $LOCAL_SHA"
            echo "     Release 上的   : $REMOTE_SHA"
            echo "     修：gh release upload $TAG \"$ZIP\" -R $REPO --clobber"
            REL_RC=3
        fi
    fi
fi

echo
if [ "$REL_RC" -gt "$TREE_RC" ]; then exit "$REL_RC"; else exit "$TREE_RC"; fi
