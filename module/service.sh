#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板  ——  开机自启（KernelSU 模块）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 作用：等系统启动完成后
#   1) 给 openEuler chroot 挂好 /dev /dev/pts /dev/shm /proc /sys
#   2) 写入 chroot 内 DNS
#   3) 依次拉起 宝塔面板 / nginx(OpenResty) / MariaDB / PHP-FPM / Fail2ban
# 所有动作幂等，重复执行安全。
# ============================================================

MODDIR=${0%/*}
ROOT=/data/openeuler
LOG=$MODDIR/boot.log
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -f "$LOG" ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

log "===== 栖云台启动流程开始 ====="

if [ ! -d "$ROOT/www/server/panel" ]; then
    log "错误：找不到 $ROOT/www/server/panel，跳过启动"
    exit 0
fi

# ---------- 1) 等待系统启动完成 ----------
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 150 ]; do
    sleep 2
    i=$((i + 1))
done
log "系统启动状态：boot_completed=$(getprop sys.boot_completed 2>/dev/null) 等待轮次=$i"
sleep 3

# ---------- 2) 挂载 chroot ----------
mnt() {
    mpoint="$1"; shift
    if mountpoint -q "$mpoint" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$mpoint" 2>/dev/null
    if "$@"; then
        log "挂载成功 $mpoint"
    else
        log "挂载失败 $mpoint （$*）"
    fi
}

mnt "$ROOT/dev"         mount --bind /dev "$ROOT/dev"
mnt "$ROOT/dev/pts"     mount -t devpts -o gid=5,mode=0620 devpts "$ROOT/dev/pts"
mnt "$ROOT/dev/shm"     mount -t tmpfs -o mode=1777 tmpfs "$ROOT/dev/shm"
mnt "$ROOT/proc"        mount -t proc -o nosuid,nodev,noexec proc "$ROOT/proc"
mnt "$ROOT/sys"         mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOT/sys"

# ---------- 3) DNS（chroot 内需要能解析域名）----------
D1=$(getprop net.dns1 2>/dev/null)
D2=$(getprop net.dns2 2>/dev/null)
{
    echo "nameserver 223.5.5.5"
    echo "nameserver 119.29.29.29"
    case "$D1" in *:*|"") ;; *) echo "nameserver $D1" ;; esac
    case "$D2" in *:*|"") ;; *) echo "nameserver $D2" ;; esac
} > "$ROOT/etc/resolv.conf" 2>/dev/null
log "已写入 DNS: $(tr '\n' ' ' < "$ROOT/etc/resolv.conf" 2>/dev/null)"

# ---------- 3.5) KernelSU 管理器注册（重要）----------
# 现象：管理器 App 显示「不支持 | 未集成」＋「不支持非 GKI 内核」，
#       但 ksud/su/模块其实都正常。
# 实测原因：内核里的 manager appid 是未设置状态（ksud debug info 看不到，
#       set-manager 时打印 "4294967295 -> 10166" 即为证据），管理器拿不到 root
#       → 查不到内核状态 → 退化成那句误导性的「非 GKI」提示。
# 本机内核是 CONFIG_KSU_DEBUG=y 的 non-GKI(legacy) 自编译内核，所以这里开机补注册。
if command -v ksud >/dev/null 2>&1; then
    if [ -d /data/app/com.rifsxd.ksunext-* ] || [ -d /data/app/me.weishu.kernelsu-* ]; then
        MGR=""
        [ -d /data/app/com.rifsxd.ksunext-* ] && MGR="com.rifsxd.ksunext"
        if [ -n "$MGR" ]; then
            OUT=$(ksud debug set-manager "$MGR" 2>&1)
            log "KernelSU 管理器注册 [$MGR]: $OUT"
        fi
    fi
fi

# ---------- 4) 启动 chroot 内服务 ----------
run_in() {
    chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1" >> "$LOG" 2>&1
    return $?
}

start_svc() {
    svc="$1"; desc="$2"
    if run_in "[ -x /etc/init.d/$svc ]"; then
        log "启动 $desc ($svc)"
        run_in "/etc/init.d/$svc start"
    else
        log "跳过 $desc：/etc/init.d/$svc 不存在"
    fi
}

# ---------- 4.5) Android paranoid-network 前置修正 ----------
# 实测：Android 内核的 paranoid-network 只允许 root 或 AID_INET(gid 3003) 组进程
# 创建 AF_INET socket。chroot 里的 mysql/redis 等服务账号默认不在该组，会启动失败：
#   mariadbd: "Failed to create a socket for IPv4 '0.0.0.0': errno: 13 / No TCP address could be bound to"
# 这里开机兜底：补组 + 校正 MariaDB 数据目录属主（幂等）。
if run_in "[ -f /etc/group ]"; then
    run_in "grep -q '^inet:' /etc/group || echo 'inet:x:3003:' >> /etc/group"
    for u in mysql www redis; do
        if run_in "id $u >/dev/null 2>&1"; then
            if ! run_in "id -nG $u 2>/dev/null | tr ' ' '\n' | grep -qx inet"; then
                log "修正：把 $u 用户加入 inet(gid 3003) 组"
                run_in "usermod -aG inet $u"
            fi
        fi
    done
    if run_in "[ -d /www/server/data ]"; then
        run_in "chown -R mysql:mysql /www/server/data 2>/dev/null"
    fi
fi

# ---------- 4.6) 清理陈旧 pid 文件 ----------
# chroot 的 /var/run 落在 /data 上，重启不清空；陈旧 pid 文件会让 init 脚本
# 误判「服务已在运行」而跳过启动（实测踩过：crond 开机没起来）。
# 用 exe 匹配而不是 comm：`#!` 脚本进程的 comm 就是脚本名，会误判。
run_in 'for f in /var/run/*.pid; do
    [ -e "$f" ] || continue
    p=$(cat "$f" 2>/dev/null)
    n=$(basename "$f" .pid)
    e=$(readlink /proc/$p/exe 2>/dev/null)
    if [ -n "$p" ] && [ "$(basename "$e" 2>/dev/null)" = "$n" ]; then
        :
    else
        rm -f "$f"
    fi
done' && log "陈旧 pid 文件已清理"

start_svc bt       "宝塔面板"
start_svc nginx    "Nginx/OpenResty"
start_svc mysqld   "MariaDB"
start_svc php-fpm-82 "PHP 8.2 FPM"
start_svc fail2ban "Fail2ban"
start_svc crond    "计划任务 crond"
start_svc redis    "Redis（宝塔托管）"
start_svc memcached "Memcached"
start_svc tomcat   "Tomcat"

# Supervisor 进程守护管理器（插件，没有 init 脚本，用面板 pyenv 里的 supervisord 直接拉）
if run_in "[ -x /www/server/panel/pyenv/bin/supervisord ] && [ -f /etc/supervisor/supervisord.conf ]"; then
    if ! run_in "pgrep -x supervisord >/dev/null 2>&1"; then
        log "启动 supervisord（进程守护管理器）"
        run_in "/www/server/panel/pyenv/bin/supervisord -c /etc/supervisor/supervisord.conf >/dev/null 2>&1"
    else
        log "supervisord 已在运行"
    fi
fi

# crond 兜底：openEuler 只带 /usr/sbin/crond，没有 /etc/init.d/crond
if ! run_in "[ -x /etc/init.d/crond ]"; then
    if run_in "[ -x /usr/sbin/crond ]"; then
        log "crond 无 init 脚本，直接拉起 /usr/sbin/crond"
        run_in "mkdir -p /var/spool/cron /var/run /var/log; touch /var/spool/cron/root; pgrep -x crond >/dev/null || /usr/sbin/crond -s"
    fi
fi

# Redis 兜底：如果宝塔版没装，就把 dnf 装的 redis-server 拉起来
if ! run_in "[ -x /etc/init.d/redis ]"; then
    if run_in "[ -x /usr/bin/redis-server ]"; then
        if ! run_in "pgrep -x redis-server >/dev/null"; then
            log "启动 Redis（系统版）"
            run_in "mkdir -p /var/lib/redis; nohup /usr/bin/redis-server --daemonize yes >/dev/null 2>&1"
        fi
    fi
fi

# ---------- 5) 自检 ----------
sleep 5
PORT=$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)
PATHV=$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)
log "面板端口=$PORT 入口=$PATHV"
if run_in "curl -sS -m 8 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36' -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT}${PATHV}"; then
    log "面板自检：已响应"
else
    log "面板自检：未响应（请看 $ROOT/www/server/panel/logs/error.log）"
fi
log "===== 栖云台启动流程结束 ====="
