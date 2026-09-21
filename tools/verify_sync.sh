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
#   2) Release 附件新鲜度 —— 下载 Release 附件，把它里面的文件与本地 module/
#      逐个比 sha256。module/ 改了但忘了重发附件，只有这一项能发现
#      （实测就这么漏过一次：附件还是 17306 字节，重打的已经 17419）。
#      为什么比内容不比 zip 字节：zip 的条目顺序随文件系统 readdir 变，
#      实测同一份 module/ 在仓库里和复制到 /tmp 后打出的 zip sha256 不同。
#
# 依赖：gh（已登录）、python3、git、curl
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
# 做法：从 api.github.com 下回 Release 附件（约 17 KB，实测 2-3 秒），
# 把它里面的文件与本地 module/ 逐个比 sha256。
# 不比对 zip 字节：zip 条目顺序随文件系统变，字节级比对会误报。
REL_RC=0
echo
echo "=== Release 附件新鲜度 ==="
PROP="$ROOT/module/module.prop"
if [ ! -f "$PROP" ]; then
    echo "  跳过：找不到 module/module.prop"
else
    # module.prop 里 version 自带 v（version=v1.2.3），所以 tag 就是它本身，
    # 附件名是 qiyuntai_btpanel-<version>.zip。别再补一个 v（实测踩过，
    # 会拼出 qiyuntai_btpanel-vv1.2.3.zip 这种不存在的名字）。
    TAG=$(sed -n 's/^version=//p' "$PROP" | tr -d '\r' | head -1)
    ASSET="qiyuntai_btpanel-$TAG.zip"
    AID=$("$GH" api "repos/$REPO/releases/tags/$TAG" \
        --jq ".assets[] | select(.name==\"$ASSET\") | .id" 2>/dev/null | tr -d '\r' | head -1)
    if [ -z "$AID" ]; then
        echo "  ?? Release $TAG 里没有附件 $ASSET，或者 tag/assets 取不到"
        REL_RC=3
    else
        TOK=$("$GH" auth token 2>/dev/null | tr -d '\r\n')
        rm -f /tmp/qyt_asset.zip
        CODE=$(curl -sSL -m 60 -H "Authorization: token $TOK" \
            -H "Accept: application/octet-stream" -o /tmp/qyt_asset.zip \
            -w '%{http_code}' \
            "https://api.github.com/repos/$REPO/releases/assets/$AID" 2>/dev/null)
        if [ "$CODE" != "200" ] || [ ! -s /tmp/qyt_asset.zip ]; then
            echo "  ?? 下载附件失败（HTTP $CODE）"
            REL_RC=3
        else
            python3 - "$ROOT/module" /tmp/qyt_asset.zip "$ASSET" <<'PY'
import hashlib, os, sys, zipfile

moddir, zpath, asset = sys.argv[1], sys.argv[2], sys.argv[3]

def sha256(b):
    return hashlib.sha256(b).hexdigest()

local = {}
for name in sorted(os.listdir(moddir)):
    p = os.path.join(moddir, name)
    if os.path.isfile(p):
        with open(p, 'rb') as f:
            local[name] = sha256(f.read())

with zipfile.ZipFile(zpath) as z:
    remote = {}
    for info in z.infolist():
        if info.is_dir():
            continue
        n = info.filename
        if n.startswith('module/'):
            n = n[len('module/'):]
        remote[n] = sha256(z.read(info))

missing = sorted(set(local) - set(remote))
extra   = sorted(set(remote) - set(local))
diff    = sorted(n for n in set(local) & set(remote) if local[n] != remote[n])

print("  附件 %s 里有 %d 个文件，本地 module/ 有 %d 个" % (asset, len(remote), len(local)))
if not missing and not extra and not diff:
    print("  一致：附件内容与本地 module/ 逐文件相同")
    sys.exit(0)

print("  !! Release 附件与本地 module/ 不一致：")
for n in missing:
    print("     附件里缺：%s（本地有）" % n)
for n in extra:
    print("     附件里多：%s（本地没有）" % n)
for n in diff:
    print("     内容不同：%-16s 本地 %s / 附件 %s" % (n, local[n][:12], remote[n][:12]))
print("     修：重打 zip 后覆盖附件")
print("         sh tools/build_module_zip.sh && gh release upload %s _dist/%s -R %s --clobber"
      % (asset.split('qiyuntai_btpanel-')[1][:-4] if 'qiyuntai_btpanel-' in asset else 'TAG',
         asset, os.environ.get('REPO', 'moliapiyyds/qiyuntai-btpanel')))
sys.exit(3)
PY
            PY_RC=$?
            [ "$PY_RC" = "3" ] && REL_RC=3
            rm -f /tmp/qyt_asset.zip
        fi
    fi
fi

echo
if [ "$REL_RC" -gt "$TREE_RC" ]; then exit "$REL_RC"; else exit "$TREE_RC"; fi
