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

# MODDIR：绝对路径调用（KSU/Magisk 就是这么调的）和手工相对调用都要能用
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
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

# ---------- 3.5) KernelSU 管理器注册（重要，必须每次开机做）----------
# 现象：管理器 App 显示「不支持 | 未集成」＋「不支持非 GKI 内核」。
# 实测根因（2026-09-20 从内核日志定位）：
#   1) 内核只在开机早期由 throne_tracker 扫 /data/app 认领管理器一次。那次扫描
#      实测会因 base.apk 打开失败的**瞬时**错误整体失败：
#         KernelSU: Searching manager...
#         KernelSU: open /data/app/com.rifsxd.ksunext-.../base.apk error.
#         KernelSU: Search manager finished          <- 没人被认领
#      之后不再自动补扫（本内核未编 KSU_LSM_HOOKS，开机完成事件补扫不触发），
#      于是一直「不认识」管理器，直到装/卸任意应用触发包事件才会重扫。
#   2) 内核旧逻辑还会在 packages.list 不完整时误判“管理器已卸载”并注销 appid，
#      而且注销后当场不重扫（goto prune），同样要等下一次包事件才可能恢复。
# 两头堵：
#   内核侧：throne_tracker 补丁（坏行不截断 / 注销后立刻重扫 / 未认领则重试 30 次）
#   用户态：这里把 appid 直接写内核参数，不依赖 ksud 二进制是否已就绪
#           （ksu_debug_manager_appid 是带 setter 的 module_param，写入即生效）
MGR_PKG=""
for p in com.rifsxd.ksunext me.weishu.kernelsu org.matrix.vector.manager; do
    if ls -d /data/app/$p-* >/dev/null 2>&1; then MGR_PKG="$p"; break; fi
done
KSUPARAM=/sys/module/kernelsu/parameters/ksu_debug_manager_appid

ksu_mgr_appid() {
    if command -v awk >/dev/null 2>&1; then
        awk -v p="$MGR_PKG" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null
        return
    fi
    while read -r _n _u _r; do
        [ "$_n" = "$MGR_PKG" ] && { echo "$_u"; return; }
    done < /data/system/packages.list
}

# 返回 0 表示内核已认出管理器
ksu_mgr_set() {
    A=$(ksu_mgr_appid)
    [ -z "$A" ] && return 1
    [ "$(cat "$KSUPARAM" 2>/dev/null)" = "$A" ] && return 0
    [ -w "$KSUPARAM" ] && echo "$A" > "$KSUPARAM" 2>/dev/null
    [ "$(cat "$KSUPARAM" 2>/dev/null)" = "$A" ] && return 0
    if command -v ksud >/dev/null 2>&1; then
        ksud debug set-manager "$MGR_PKG" >/dev/null 2>&1
        [ "$(cat "$KSUPARAM" 2>/dev/null)" = "$A" ] && return 0
    fi
    return 1
}

if [ -n "$MGR_PKG" ]; then
    if ksu_mgr_set; then
        log "KernelSU 管理器已注册 [$MGR_PKG appid=$(ksu_mgr_appid)]"
    else
        log "KernelSU 管理器尚未生效（参数=$(cat $KSUPARAM 2>/dev/null)），转后台重试最多 2 分钟"
        (
            i=0
            while [ $i -lt 24 ]; do
                sleep 5
                if ksu_mgr_set; then
                    log "KernelSU 管理器注册成功（后台第 $((i+1)) 次）[$MGR_PKG appid=$(ksu_mgr_appid)]"
                    break
                fi
                i=$((i+1))
            done
            if [ $i -ge 24 ]; then
                log "KernelSU 管理器注册失败：$MGR_PKG appid=$(ksu_mgr_appid) 参数=$(cat $KSUPARAM 2>/dev/null)"
            fi
        ) &
    fi
else
    log "未找到 KernelSU 管理器 App，跳过注册"
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
# 创建 AF_INET socket。chroot 里的 mysql/redis/memcached 等服务账号默认不在该组，
# 会启动失败：
#   mariadbd: "Failed to create a socket for IPv4 '0.0.0.0': errno: 13 / No TCP address could be bound to"
#   memcached: 绑 127.0.0.1:11211 失败（init 脚本只会打印一句「启动失败」，没有任何 errno）
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
    # memcached 要改**主组**，不是加附加组：它降权时只 setgid/setuid、不带附加组，
    # 实测进程的 Groups 是空的 → 只加 -aG 不生效，bind 会 EACCES（见 pitfalls §二）
    if run_in "id memcached >/dev/null 2>&1"; then
        if ! run_in "id -gn memcached 2>/dev/null | grep -qx inet"; then
            log "修正：把 memcached 用户的主组改为 inet(gid 3003)"
            run_in "usermod -g inet memcached"
        fi
    fi
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

# ---------- 4.7) SSH 兜底通道（adb 不可用时唯一的救命通道，务必保留）----------
SSHD_CFG_OUT="$ROOT/etc/ssh/sshd_config_moli"
SSHD_CFG_IN="/etc/ssh/sshd_config_moli"
if [ -f "$SSHD_CFG_OUT" ]; then
    if run_in "pgrep -x sshd >/dev/null"; then
        log "sshd 已在运行，监听 :22"
    else
        log "启动 sshd（配置 $SSHD_CFG_IN）"
        run_in "/usr/sbin/sshd -f $SSHD_CFG_IN"
        sleep 2
        if run_in "pgrep -x sshd >/dev/null"; then
            log "sshd 启动成功，监听 :22"
        else
            log "警告：sshd 启动失败，检查 $SSHD_CFG_OUT 与主机密钥"
        fi
    fi
else
    log "未找到 $SSHD_CFG_OUT，跳过 sshd"
fi

# ---------- 5) 自检 ----------
sleep 5
PORT=$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)
PATHV=$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)
log "面板端口=$PORT 入口=$PATHV"
# 自检两种协议都试：面板可能被 bt 那个「自动申请 IP 证书」任务切成只收 HTTPS
# （写了 /www/server/panel/data/ssl.pl=True），那时明文 http 连上就被 reset，
# 而 curl 的退出码是 56 —— 只看 http 会误报「未响应」。
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
if run_in "curl -sS -m 8 -A '$UA' -o /dev/null http://127.0.0.1:${PORT}${PATHV}"; then
    log "面板自检：已响应（http://127.0.0.1:${PORT}${PATHV}）"
elif run_in "curl -sSk -m 8 -A '$UA' -o /dev/null https://127.0.0.1:${PORT}${PATHV}"; then
    log "面板自检：已响应，但只收 HTTPS —— 面板 SSL 是开着的（data/ssl.pl）"
    log "          请用 https://127.0.0.1:${PORT}${PATHV} 访问；证书是自签的会有浏览器告警"
    log "          想关掉：chroot $ROOT rm -f /www/server/panel/data/ssl.pl && /etc/init.d/bt restart"
else
    log "面板自检：未响应（请看 $ROOT/www/server/panel/logs/error.log）"
fi
log "===== 栖云台启动流程结束 ====="
