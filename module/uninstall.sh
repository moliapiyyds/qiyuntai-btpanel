#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板  ——  卸载脚本
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 【重要】本脚本只做两件事：
#   1) 尽力停掉正在跑的服务
#   2) 解挂载 chroot 的 /dev /dev/pts /dev/shm /proc /sys
# 绝对不会删除 /data/openeuler（你的网站、数据库、面板全在里面）。
#
# 【要彻底删除】用本脚本的 --purge，**不要直接 rm -rf /data/openeuler**：
#   chroot 的 /dev 是 `mount --bind /dev`，也就是**宿主真实 /dev 的绑定挂载**。
#   挂载还活着时执行 rm -rf，rm 会走进真实 /dev 把设备节点删掉，
#   /dev/null 变成普通文件，zygote 打不开就崩 —— 表现是**手机直接黑屏**。
#   实测踩过两次（2026-09-21）。--purge 会先确认挂载干净，再删。
# ============================================================

# MODDIR：绝对路径调用（KSU/Magisk 就是这么调的）和手工相对调用都要能用
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
ROOT=/data/openeuler
LOG=$MODDIR/uninstall.log
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "===== 开始卸载（只解挂载，不删数据）====="

# ---------- 1) 停服务 ----------
if [ -d "$ROOT/etc/init.d" ]; then
    for s in fail2ban php-fpm-82 mysqld nginx bt crond; do
        if [ -x "$ROOT/etc/init.d/$s" ]; then
            log "停止 $s"
            chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "/etc/init.d/$s stop" >> "$LOG" 2>&1
        fi
    done
fi

# Redis
if [ -x "$ROOT/usr/bin/redis-cli" ]; then
    log "停止 Redis"
    chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "redis-cli shutdown nosave" >> "$LOG" 2>&1
fi

sleep 2

# ---------- 2) 解挂载（逆序）----------
um() {
    mpoint="$1"
    if mountpoint -q "$mpoint" 2>/dev/null; then
        if umount -l "$mpoint" 2>/dev/null; then
            log "已解挂载 $mpoint"
        else
            log "解挂载失败 $mpoint"
        fi
    else
        log "无需解挂载 $mpoint"
    fi
}

um "$ROOT/sys"
um "$ROOT/proc"
um "$ROOT/dev/shm"
um "$ROOT/dev/pts"
um "$ROOT/dev"

# ---------- 3) --purge：确认挂载干净后彻底删除 ----------
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ "$PURGE" = "1" ] && [ -d "$ROOT" ]; then
    # 硬门槛：先证明 $ROOT 下面没有任何挂载残留。
    # chroot 的 /dev 是宿主真实 /dev 的绑定挂载；挂载还在时 rm -rf 会走进
    # 真实 /dev 删设备节点 -> /dev/null 变普通文件 -> zygote 崩 -> 手机黑屏。
    LEFT=$(mount | grep -c "$ROOT/")
    if [ "$LEFT" != "0" ]; then
        log "拒绝清理：$ROOT 下面还有 $LEFT 个挂载"
        mount | grep "$ROOT/" >> "$LOG" 2>&1
        echo "栖云台：拒绝清理 —— $ROOT 下面还有 $LEFT 个挂载，先解挂载再删。"
        mount | grep "$ROOT/"
        exit 1
    fi
    log "挂载已确认干净，开始删除 $ROOT"
    echo "栖云台：挂载已确认干净，正在删除 $ROOT …"
    rm -rf "$ROOT"
    if [ -d "$ROOT" ]; then
        log "删除不完整，仍残留：$(ls "$ROOT" 2>/dev/null | tr '\n' ' ')"
        echo "栖云台：删除不完整，还有残留，看 $LOG。"
        exit 1
    fi
    log "已彻底删除 $ROOT"
    echo "栖云台：已彻底删除 /data/openeuler。"
    exit 0
fi

# ---------- 4) 默认：只解挂载，保留数据 ----------
if [ -d "$ROOT" ]; then
    SZ=$(du -sh "$ROOT" 2>/dev/null | awk '{print $1}')
    log "数据已保留：$ROOT （$SZ），未删除任何文件"
fi
log "===== 卸载完成 ====="
echo "栖云台：只解挂载，/data/openeuler 数据已保留。"
echo ""
echo "要彻底删除，**不要直接 rm -rf /data/openeuler**："
echo "  chroot 的 /dev 是宿主真实 /dev 的绑定挂载。挂载还在时 rm -rf 会走进真实"
echo "  /dev 把设备节点删掉（/dev/null 变普通文件 -> zygote 崩 -> 手机黑屏）。"
echo "  实测踩过两次。"
echo ""
echo "安全做法二选一："
echo "  1) sh \$0 --purge                    # 本脚本会先确认挂载干净再删"
echo "  2) 手动两步："
echo "       mount | grep -c $ROOT/          # 必须输出 0，不是 0 就先解挂载"
echo "       rm -rf $ROOT                    # 确认输出 0 之后才删"
exit 0
