#!/system/bin/sh
# ============================================================
# 栖云台 · 预制镜像打包（把装好的环境冻成一个可分卷的 tar.xz）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 为什么要有这个：
#   从零装要碰一堆宝塔端点（安装器 / panel6.zip / pyenv bundle / 组件脚本 / 组件源码），
#   任何一个变了或没了，从零装就断。实测宝塔确实长期保留历史版本
#   （update/LinuxPanel-9.5.0.zip 和 11.0.0.zip 都还在），但那是它的善意不是承诺。
#   所以：装好一次，冻成一个镜像，以后重装 = 解包，10 分钟，零上游依赖。
#
# 【重要设计决定】镜像里存的是**打过补丁之前**的状态
#   （rootfs + dnf 依赖 + 面板 + 编译好的组件），破解补丁留到部署时打。
#   理由：
#     1) 补丁是版本相关的（tools/moli_patch.py 的补丁点是按 13.0.0 实测的），
#        冻进镜像就没法在不重建 5GB 镜像的前提下更新补丁。
#     2) 部署时在**原版**上打补丁，moli_patch/backup_* 里才是真原版，回滚点才成立。
#        在已打补丁的环境里重打，备份出来的会是"已打补丁的文件"。
#     3) 补丁只改面板的 py/html/js，几秒钟的事，不打进镜像没有任何损失。
#   所以打包前会**自动把补丁回退**（moli_patch.py revert），并把 moli_patch/ 清掉。
#
# 用法（设备上 root，环境已装好）：
#   sh tools/make_image.sh                      # 默认输出到 /data/qyt_image
#   sh tools/make_image.sh --out /sdcard/qyt_image
#   sh tools/make_image.sh --no-clean           # 不清理编译残留（镜像会大很多）
#   sh tools/make_image.sh --part-mb 1900       # 每卷大小（GitHub 附件上限 2GiB）
#
# 退出码：0 成功；1 前置条件不满足（含"还有挂载没解"）；2 打包过程失败
# ============================================================
set -u

ROOT=/data/openeuler
OUT=/data/qyt_image
PART_MB=1900                 # GitHub Release 单附件上限 2 GiB，留点余量
DO_CLEAN=1
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'

say()  { echo "  $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [警告] $*"; }
die()  { echo "  [失败] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --part-mb) PART_MB="$2"; shift 2 ;;
        --no-clean) DO_CLEAN=0; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) die "未知参数：$1（-h 看用法）" ;;
    esac
done

echo "============================================================"
echo " 栖云台 · 预制镜像打包"
echo "============================================================"

# ---------- 工具 ----------
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
    [ -x "$b" ] && BB="$b" && break
done
[ -n "$BB" ] || die "找不到 busybox（tar/xz/split/sha256sum 都靠它）"
say "busybox：$BB"

ic() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1"; }

# ---------- 前置检查 ----------
echo ""
echo "---- 前置检查 ----"

# 1) 挂载必须先解干净。这是硬门槛：
#    $ROOT/dev 是 `mount --bind /dev`（宿主真实 /dev 的绑定挂载），
#    带着挂载打包会把宿主设备节点打进镜像；带着挂载 rm -rf 更会毁掉手机 /dev
#    （2026-09-21 踩过两次，症状是黑屏）。
LEFT=$(mount | $BB grep -c "$ROOT/")
if [ "$LEFT" != "0" ]; then
    echo "  当前挂在 $ROOT 下的："
    mount | $BB grep "$ROOT/"
    die "还有 $LEFT 个挂载没解。先： sh install/prepare-rootfs.sh --unmount"
fi
ok "没有挂载残留（$ROOT/ 下 0 个）"

[ -x "$ROOT/www/server/panel/BT-Panel" ] || die "面板没装好（找不到 BT-Panel）"

# 2) 组件必须都编译完，否则冻出来的是个半成品
#
# 路径不能用 chroot 内那套：/www/server/nginx/sbin 是
# `sbin -> /www/server/nginx/nginx/sbin` 的**绝对软链**，chroot 内能通、
# 宿主侧不通（本脚本是宿主侧跑的）。实测直接判断 /www/server/nginx/sbin/nginx
# 会误报"组件没编译完"。所以：候选真实路径 -> 再 find 兜底。
resolve_bin() {
    for p in "$@"; do
        [ -e "$ROOT/$p" ] && { echo "$p"; return 0; }
    done
    echo ""
}
NGX=$(resolve_bin www/server/nginx/nginx/sbin/nginx www/server/nginx/sbin/nginx)
[ -n "$NGX" ] || NGX=$(cd "$ROOT" && find www/server/nginx -maxdepth 4 -type f -name nginx 2>/dev/null | head -1)
MYD=$(resolve_bin www/server/mysql/bin/mariadbd)
[ -n "$MYD" ] || MYD=$(cd "$ROOT" && find www/server/mysql -maxdepth 4 -type f -name mariadbd 2>/dev/null | head -1)
PHPB=$(resolve_bin www/server/php/82/bin/php)
[ -n "$PHPB" ] || PHPB=$(cd "$ROOT" && find www/server/php -maxdepth 5 -type f -name php 2>/dev/null | head -1)

MISSING=""
[ -n "$NGX" ]  || MISSING="$MISSING nginx"
[ -n "$MYD" ]  || MISSING="$MISSING mariadbd"
[ -n "$PHPB" ] || MISSING="$MISSING php"
if [ -n "$MISSING" ]; then
    die "这些组件还没编译完，不能冻：$MISSING（找过的候选路径见本脚本 resolve_bin）"
fi
ok "组件都在：nginx=$NGX  mariadbd=$MYD  php=$PHPB"

# 3) 面板版本（补丁适配判据，写进清单）
PVER=$(sed -n "s/.*g\.version *= *'\([^']*\)'.*/\1/p" "$ROOT/www/server/panel/class/common.py" 2>/dev/null | head -1)
say "面板版本：${PVER:-（读不到）}"
PANELHASH=$(cat "$ROOT"/tmp/LinuxPanel-*.pl 2>/dev/null | head -c 300)
[ -n "$PANELHASH" ] && say "官方包记录：$PANELHASH"

echo ""
echo "---- 停 chroot 内服务 ----"
for s in bt nginx mysqld php-fpm-82 fail2ban redis memcached tomcat crond; do
    ic "[ -x /etc/init.d/$s ] && /etc/init.d/$s stop" >/dev/null 2>&1
    printf '  stop %-12s\n' "$s"
done
ic "/www/server/panel/pyenv/bin/supervisord -c /etc/supervisor/supervisord.conf shutdown" >/dev/null 2>&1
say "supervisord shutdown"
sleep 2

# ---------- 回退补丁（镜像必须存未打补丁的状态）----------
echo ""
echo "---- 回退破解补丁（镜像里要留原版）----"
if [ -f "$ROOT/www/server/panel/moli_patch/moli_patch.py" ] || [ -d "$ROOT/www/server/panel/moli_patch" ]; then
    if ic "/www/server/panel/pyenv/bin/python3 /www/server/panel/moli_patch/moli_patch.py revert" 2>&1 | sed 's/^/    /'; then
        ok "补丁已回退"
    else
        warn "revert 没成功 —— 请人工确认后再打包（否则镜像是打过补丁的，回滚点会假）"
        warn "要继续打包请加 --no-clean 之外的确认，或先手工恢复 moli_patch/backup_* 里的文件"
        die "镜像必须是未打补丁状态，停手"
    fi
    rm -rf "$ROOT/www/server/panel/moli_patch"
    say "已清掉 moli_patch/（备份目录也一并清掉，反正镜像里是原版）"
else
    say "没有 moli_patch/，本来就是原版"
fi

# ---------- 清理编译残留 ----------
echo ""
echo "---- 清理编译残留 ----"
BEFORE=$($BB du -sm "$ROOT" 2>/dev/null | $BB cut -f1)
say "清理前：${BEFORE} MB"

if [ "$DO_CLEAN" = "1" ]; then
    # 每一行都注明为什么可以删（都是"编译时的中间产物，运行时不需要"）
    for d in \
        "www/server/mysql/src:MariaDB 编译构建树（本次实测 8.8 GB，最大的浪费）" \
        "www/server/mysql/mysql-test:MariaDB 测试套件（运行不需要）" \
        "www/server/mysql/sql-bench:MariaDB 压测脚本" \
        "var/cache/dnf:dnf 包缓存" \
        "var/cache/yum:yum 包缓存" \
        "root/.cache:pip 等缓存" \
        ; do
        p="${d%%:*}"; why="${d#*:}"
        # 双保险：路径为空、以 / 开头、或含 .. 就绝不动手。
        # 为什么：`rm -rf "$ROOT/$p"` 在 $p 为空时会变成 `rm -rf "$ROOT/"`，
        # 也就是把整个 chroot 删掉 —— 而本脚本是 root 跑的（shellcheck SC2115 报的就是这个）。
        case "$p" in
            ''|/*|*..*) die "内部错误：清理项路径异常：[${p}]" ;;
        esac
        if [ -e "$ROOT/$p" ]; then
            SZ=$($BB du -sm "$ROOT/$p" 2>/dev/null | $BB cut -f1)
            rm -rf "${ROOT:?}/${p:?}"
            printf '  删除 %-42s %6s MB  （%s）\n' "$p" "$SZ" "$why"
        fi
    done
    # 编译源码包：留着没用（重装会用镜像，不会再编译）
    for f in www/server/mysql/src.tar.gz www/server/mysql/mysql-*.tar.gz; do
        case "$f" in ''|/*|*..*) continue ;; esac
        [ -e "$ROOT/$f" ] && { SZ=$($BB du -sm "$ROOT/$f" 2>/dev/null | $BB cut -f1); rm -f "${ROOT:?}/${f:?}"; printf '  删除 %-42s %6s MB\n' "$f" "$SZ"; }
    done
    # 面板的临时文件（保留 LinuxPanel-*.pl：那是官方包的哈希记录，是溯源证据）
    find "$ROOT/tmp" -maxdepth 1 -type f ! -name 'LinuxPanel-*' -exec rm -f {} + 2>/dev/null
    say "已清 /tmp 下非溯源文件"
    # .o/.a 之类的散落目标文件
    N=$(find "$ROOT/www/server" -name '*.o' 2>/dev/null | wc -l)
    if [ "$N" != "0" ]; then
        find "$ROOT/www/server" -name '*.o' -delete 2>/dev/null
        say "已删 $N 个散落的 .o"
    fi
else
    warn "--no-clean：保留全部编译残留（镜像会大很多）"
fi

AFTER=$($BB du -sm "$ROOT" 2>/dev/null | $BB cut -f1)
say "清理后：${AFTER} MB（省了 $((BEFORE - AFTER)) MB）"

# ---------- 写清单 ----------
echo ""
echo "---- 写镜像清单 ----"
MANI="$ROOT/IMAGE-MANIFEST.txt"
{
    echo "=== 栖云台预制镜像清单 ==="
    echo "打包时间     : $($BB date '+%Y-%m-%d %H:%M:%S')"
    echo "面板版本     : ${PVER:-未知}"
    echo "官方包记录   : ${PANELHASH:-未知}"
    echo "内核         : $(uname -a)"
    echo "chroot 大小  : ${AFTER} MB"
    echo "清理情况     : 清理前 ${BEFORE} MB -> 清理后 ${AFTER} MB（省 $((BEFORE - AFTER)) MB）"
    echo "补丁状态     : **未打补丁（原版）** —— 破解补丁在部署时由 tools/moli_patch.py 打"
    echo "解包目标     : /data/openeuler（tar 里第一层目录名就是 openeuler）"
    echo "解包后要做的 : 解到 /data -> 跑 qiyuntai-install.sh 的 creds/plugins/patch/module"
    echo "               （端口/入口/密码要在那一步重新随机化，不能照用镜像里的）"
    echo ""
    echo "--- 组件真实路径（宿主侧视角；chroot 内还有 sbin 软链） ---"
    echo "nginx    : /$NGX"
    echo "mariadbd : /$MYD"
    echo "php      : /$PHPB"
    echo ""
    echo "--- rpm 包数 ---"
    ic "rpm -qa | wc -l" 2>/dev/null
    echo ""
    echo "--- 顶层条目 ---"
    $BB ls "$ROOT"
} > "$MANI" 2>&1
ok "已写 $MANI"

# ---------- 打包 ----------
echo ""
echo "---- 打包（tar | xz -T0，这一步最慢）----"
mkdir -p "$OUT" || die "建不了 $OUT"
ARCH="$OUT/openeuler.tar.xz"
rm -f "$ARCH"
T0=$($BB date +%s)
# 用 chroot 里的 xz（支持 -T0 多线程），输出走 stdout 由宿主重定向 ——
# 这样压缩器在 chroot 里、产物落在宿主目录，不用往被归档的树里写文件。
if $BB tar -c -C /data openeuler 2>"$OUT/tar.err" | chroot "$ROOT" /usr/bin/xz -T0 -1 -c > "$ARCH" 2>"$OUT/xz.err"; then
    ok "打包完成"
else
    $BB tail -3 "$OUT/tar.err" 2>/dev/null | sed 's/^/    tar: /'
    die "打包失败（看 $OUT/tar.err / $OUT/xz.err）"
fi
T1=$($BB date +%s)
SIZE=$($BB stat -c %s "$ARCH" 2>/dev/null)
ok "产物 $ARCH  $($BB awk -v s="$SIZE" 'BEGIN{printf "%.1f", s/1048576}') MB  耗时 $((T1 - T0)) 秒"

# ---------- 分卷 ----------
echo ""
echo "---- 分卷（GitHub 单附件 2GiB 上限，按 ${PART_MB} MB 切）----"
rm -f "$OUT"/qyt-image.part-*
# 不用 split -d（busybox 的 split 不一定支持数字后缀），用字母后缀，
# 按字典序 cat 拼回来正好是原顺序。
$BB split -b "${PART_MB}m" -a 3 "$ARCH" "$OUT/qyt-image.part-" >/dev/null 2>&1 \
    || die "split 失败"
NPART=0
for f in "$OUT"/qyt-image.part-*; do
    [ -f "$f" ] || continue
    NPART=$((NPART + 1))
    printf '  %-46s %s\n' "$(basename "$f")" "$($BB awk -v s="$($BB stat -c %s "$f")" 'BEGIN{printf "%.1f MB", s/1048576}')"
done
ok "共 $NPART 卷"

# ---------- 校验 ----------
echo ""
echo "---- 校验：把分卷拼回来，比对 sha256 ----"
WHOLE=$($BB sha256sum "$ARCH" | $BB cut -d' ' -f1)
CAT=$($BB cat "$OUT"/qyt-image.part-* | $BB sha256sum | $BB cut -d' ' -f1)
if [ "$WHOLE" = "$CAT" ]; then
    ok "拼回来的 sha256 与整包一致"
else
    die "拼回来的 sha256 不一致：整包=$WHOLE 拼回=$CAT"
fi

# ---------- 产出信息 ----------
echo ""
{
    echo "sha256  $WHOLE  openeuler.tar.xz  （$(basename "$ARCH")，分 $NPART 卷）"
    echo "# 拼接方式：cat qyt-image.part-* > openeuler.tar.xz   （字母序即原顺序）"
    echo "# 校验：    sha256sum 应等于上面的值"
    echo "# 单卷 sha256："
    for f in "$OUT"/qyt-image.part-*; do
        echo "$($BB sha256sum "$f")"
    done
} > "$OUT/SHA256SUMS.txt"
ok "已写 $OUT/SHA256SUMS.txt"

echo ""
echo "============================================================"
echo " 完成"
echo " 镜像整包 : $ARCH（$(($SIZE / 1048576)) MB）"
echo " 分卷     : $OUT/qyt-image.part-*（$NPART 卷）"
echo " 清单     : $MANI"
echo " 校验     : $OUT/SHA256SUMS.txt"
echo ""
echo " 上传 Release（在电脑上）："
echo "   gh release upload <tag> $OUT/qyt-image.part-* $OUT/SHA256SUMS.txt \\"
echo "      -R moliapiyyds/qiyuntai-btpanel"
echo "============================================================"
exit 0
