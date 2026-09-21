#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板  ——  卸载脚本
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 【重要】本脚本只做两件事：
#   1) 尽力停掉正在跑的服务
#   2) 解挂载 chroot 的 /dev /dev/pts /dev/shm /proc /sys
# 绝对不会删除 /data/openeuler（你的网站、数据库、面板全在里面）。
# 想彻底删除请自己确认后执行：rm -rf /data/openeuler
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

# ---------- 3) 数据保留声明 ----------
if [ -d "$ROOT" ]; then
    SZ=$(du -sh "$ROOT" 2>/dev/null | awk '{print $1}')
    log "数据已保留：$ROOT （$SZ），未删除任何文件"
    log "如需彻底清理：rm -rf $ROOT"
fi
log "===== 卸载完成 ====="
echo "栖云台：只解挂载，/data/openeuler 数据已保留。"
echo "如需彻底删除：rm -rf /data/openeuler"
exit 0
