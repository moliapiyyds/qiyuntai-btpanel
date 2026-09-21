#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 环境体检（设备上跑）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 为什么要有这个脚本：
#   「装全了没有」不能靠读安装脚本 —— 缺的东西不会报错，只会静默跳过。
#   这个脚本把「跟标准环境比一眼」变成一条命令：rpm 包清单对齐情况 +
#   11 项服务的 init 脚本/进程/端口 + 组件版本 + 面板状态 + 补丁状态。
#   其中 rpm 对比用的是仓库里的 install/baseline-packages.txt
#   （删除前那台的 rpm -qa，20899 字节 / 548 行，
#    sha256 4b3c870ad51d957f3c357aa97a96d921fde358264b77f9f2319d591eb2890f31）。
#
# 用法：sh tools/audit_env.sh [/path/to/baseline-packages.txt]
#       不给参数时依次找 /sdcard/install/baseline-packages.txt、脚本同目录的 ../install/
# 只读，不改任何东西。
# ============================================================
ROOT=/data/openeuler
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=busybox

SELF_DIR=$(dirname "$0")
BASE="$1"
if [ -z "$BASE" ]; then
    for c in /sdcard/install/baseline-packages.txt "$SELF_DIR/../install/baseline-packages.txt" "$SELF_DIR/baseline-packages.txt"; do
        [ -f "$c" ] && BASE="$c" && break
    done
fi

CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'
# 注意 2>&1：`nginx -v` / `java -version` 这类是往 stderr 打的，吞了 stderr 就什么都看不到
ic() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1" 2>&1; }
# 跑刚才落盘的 ltd/pro 探针（单独一个函数，免得嵌在字符串里被引号吃掉）
in_chroot_audit() { ic '/www/server/panel/pyenv/bin/python3 /tmp/audit_ltd.py' | tail -1; }

hr() { echo "===== $1 ====="; }

hr "0) 环境是否在位"
if [ -d "$ROOT" ]; then
    echo "  $ROOT 存在，已用 $(du -sm "$ROOT" 2>/dev/null | awk '{print $1}') MB"
else
    echo "  !! $ROOT 不存在 —— 还没装"
    exit 1
fi
echo "  挂载数（chroot 的 dev/proc/sys）：$(mount | grep -c " $ROOT/")"
echo "  来自预制镜像：$([ -f "$ROOT/.from-image" ] && echo 是 || echo 否)"

hr "1) rpm 包：和基线清单对齐情况"
if [ -n "$BASE" ] && [ -f "$BASE" ]; then
    echo "  基线清单：$BASE"
    echo "  ($(wc -l < "$BASE") 行, sha256 $($BB sha256sum "$BASE" | cut -d' ' -f1))"
    # 基线 <NEVRA> 去掉「版本-发布.架构」就是包名（rpm 的版本/发布里不允许出现 -）
    # 注意：不能用 `\|` 做 BRE 分支 —— Android 的 toybox sed 不支持，会静默什么都不匹配
    #（踩过：这条一开始写成 \(aarch64\|noarch\|x86_64\)，结果「基线包名 0 个」）
    WORK=/data/local/tmp/qyt_audit
    mkdir -p "$WORK" 2>/dev/null || WORK=.
    sed -n 's/^\(.*\)-[^-]*-[^-]*\.[A-Za-z0-9_]*$/\1/p' "$BASE" | sort -u > "$WORK/want.txt"
    ic 'rpm -qa --qf "%{NAME}\n"' | sort -u > "$WORK/have.txt"
    echo "  基线包名 $(wc -l < "$WORK/want.txt") 个 / 在位 $(comm -12 "$WORK/want.txt" "$WORK/have.txt" | wc -l) 个"
    MISS=$(comm -23 "$WORK/want.txt" "$WORK/have.txt")
    if [ -n "$MISS" ]; then
        echo "  !! 缺这些（当前软件源里可能已经没有）："
        printf '    %s\n' $MISS
    else
        echo "  OK 基线包名全部在位"
    fi
    echo "  当前 rpm 总数：$(ic 'rpm -qa' | wc -l)（基线 548）"
else
    echo "  找不到基线包清单，跳过（把 install/baseline-packages.txt 放到 /sdcard/install/ 下再来）"
fi

hr "2) 11 项服务：init 脚本 / 进程 / 端口"
# 进程判定一律用 **chroot 里的 procps-ng pgrep -x**（和 module/action.sh 的 diag 一致）。
# 为什么不用宿主的 busybox pgrep：两者的匹配对象不同 ——
#   procps-ng 4.0.4 的 `pgrep -x` 比的是 /proc/pid/comm（内核里的进程名）；
#   宿主 busybox 的 `pgrep -x` 比的是 cmdline/argv[0]。
# 而 nginx / sshd 这类守护进程会改写自己的进程标题（sshd 的等价 argv[0] 变成
# "sshd: /usr/sbin/sshd -f /etc/ssh/sshd_config_moli [listener] …"），
# 于是宿主 busybox `pgrep -x sshd` 明明 sshd 在跑却返回空 —— 实测踩过，
# 差点误判成「service.sh 的 sshd 检测是坏的」。
# 也不要用 `pgrep -f <名字>`：会把审计脚本自己的命令行也匹配上
# （脚本名里带 sshd 就会自匹配），这是实测到的假阳性。
# 取 pid：`pgrep -f <模式>` 会把 ic 自己那个 `bash -c "pgrep -f '<模式>'"` 也匹配上
#（它的 cmdline 里就含这个模式串），所以拿到候选后要把「cmdline 里带 pgrep 的」剔掉。
# 这是实测到的第二个假阳性来源。
proc_pid() {
    ic "pgrep -f '$1' 2>/dev/null | while read -r p; do
            c=\$(cat /proc/\$p/cmdline 2>/dev/null | tr '\\0' ' ')
            [ -n \"\$c\" ] || continue
            case \"\$c\" in *pgrep*) continue ;; esac
            echo \$p; break
        done" | tr -d '\r' | grep -E '^[0-9]+$'
}
proc_of() {
    case "$1" in
        # 这几个的 comm 不是服务名（面板是 python3、fail2ban-server 也是 python3、
        # tomcat 是 java），只能用 -f 匹配 cmdline 里的特征串
        bt)        proc_pid 'BT-Panel' ;;
        fail2ban)  proc_pid 'fail2ban-server' ;;
        tomcat)    proc_pid 'catalina.base=/www/server/tomcat' ;;
        mysqld)    ic 'pgrep -x mariadbd | head -1' ;;
        php-fpm-82) ic 'pgrep -x php-fpm | head -1' ;;
        # redis 的进程名是 redis-server，不是 redis（实测踩到：写成 pgrep -x redis
        # 会一直显示「进程✗」，而 6379 明明在监听）
        redis)     ic 'pgrep -x redis-server | head -1' ;;
        *)         ic "pgrep -x $1 | head -1" ;;
    esac
}
for s in bt nginx mysqld php-fpm-82 fail2ban crond redis memcached tomcat supervisord sshd; do
    case "$s" in
        supervisord|sshd) I="（无 init 脚本）" ;;
        *) [ -e "$ROOT/etc/init.d/$s" ] && I="init✓" || I="init✗" ;;
    esac
    pid=$(proc_of "$s" | tr -d '\r')
    [ -n "$pid" ] && P="进程✓ pid=$pid" || P="进程✗"
    printf '  %-12s %-14s %s\n' "$s" "$I" "$P"
done

echo "  端口监听："
$BB netstat -ltn 2>/dev/null | $BB grep -E ':(22|80|888|3306|6379|11211|8080|8005|8888) ' | while read -r line; do
    echo "    $line"
done

hr "3) 组件版本"
printf '  %-14s %s\n' "OpenResty"  "$(ic '/www/server/nginx/nginx/sbin/nginx -v' 2>&1 | tail -1)"
printf '  %-14s %s\n' "MariaDB"    "$(ic '/www/server/mysql/bin/mariadbd --version' | head -1)"
printf '  %-14s %s\n' "PHP"        "$(ic '/www/server/php/82/bin/php -v' | head -1)"
printf '  %-14s %s\n' "phpMyAdmin" "$(cat "$ROOT/www/server/phpmyadmin/version.pl" 2>/dev/null)"
printf '  %-14s %s\n' "Redis"      "$(ic '/www/server/redis/src/redis-server -v' | head -1)"
printf '  %-14s %s\n' "Memcached"  "$(ic '/usr/local/memcached/bin/memcached --version' | head -1)"
printf '  %-14s %s\n' "Tomcat"     "$(ic 'unzip -p /www/server/tomcat/lib/catalina.jar META-INF/MANIFEST.MF | grep Specification-Version' | tr -d '\r')"
printf '  %-14s %s\n' "Supervisor" "$(ic 'supervisord --version' | head -1)"
printf '  %-14s %s\n' "Python"     "$(ic 'python3 --version' | head -1)"
printf '  %-14s %s\n' "Node(管理器)" "$(ic '/www/server/nodejs/v20.18.3/bin/node -v' | head -1)"
printf '  %-14s %s\n' "Node(系统)"   "$(ic '/usr/bin/node -v' | head -1)"
printf '  %-14s %s\n' "java(默认)"   "$(ic 'java -version' 2>&1 | head -1)"

hr "4) 面板"
printf '  %-14s %s\n' "面板版本"  "$(grep -oE "g\.version[[:space:]]*=[[:space:]]*['\"][^'\"]+" "$ROOT/www/server/panel/class/common.py" 2>/dev/null | head -1 | sed "s/.*['\"]//")"
printf '  %-14s %s\n' "端口"      "$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)"
printf '  %-14s %s\n' "安全入口"  "$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)"
printf '  %-14s %s\n' "凭据文件"  "$([ -f "$ROOT/root/qiyuntai-panel-info.txt" ] && echo 有 || echo 没有)"
printf '  %-14s %s\n' "补丁标记"  "$([ -f "$ROOT/www/server/panel/moli_patch/.patched" ] && echo 已打 || echo 未打/已回滚)"
# ltd/pro 要真去调一次云端列表（补丁有没有生效就看这两个数：0 / -1）。
# 注意：这段 python 一次性写在临时文件里，别塞进 ic '... -c "…"' —— 引号会被吃掉，
# 实测报 `SyntaxError: invalid syntax`（而那看起来很像补丁坏了）。
cat > "$ROOT/tmp/audit_ltd.py" <<'EOS'
import sys, os, json
PANEL = '/www/server/panel'
os.chdir(PANEL); sys.path.insert(0, PANEL); sys.path.insert(0, os.path.join(PANEL, 'class'))
from flask import Flask
app = Flask(__name__); app.secret_key = 'moli-audit'
with app.test_request_context('/'):
    import panelPlugin
    d = panelPlugin.panelPlugin().get_cloud_list()
    print('ltd=%s pro=%s' % (d.get('ltd'), d.get('pro')))
EOS
echo "  ltd/pro：$(in_chroot_audit)"

hr "5) 面板插件（文档承诺 9 个）"
n=0
for p in fail2ban redis tomcat2 supervisor nodejs java_manager jdk_manager pyenv_manager pythonmamager; do
    if [ -d "$ROOT/www/server/panel/plugin/$p" ]; then
        n=$((n + 1)); printf '  OK   %s\n' "$p"
    else
        printf '  MISS %s\n' "$p"
    fi
done
echo "  在位 $n / 9"

hr "6) 自备文件（宝塔不提供，仓库提供）"
for f in etc/init.d/crond etc/init.d/tomcat etc/init.d/memcached etc/ssh/sshd_config_moli \
         usr/local/sbin/systemctl usr/local/sbin/service usr/local/sbin/start-stop-daemon \
         usr/local/sbin/iptables usr/local/sbin/ip6tables; do
    if [ -e "$ROOT/$f" ]; then printf '  OK   %s\n' "$f"; else printf '  MISS %s\n' "$f"; fi
done
echo "  sshd 主机密钥：$(ls "$ROOT"/etc/ssh/ssh_host_*_key 2>/dev/null | wc -l) 个"

hr "7) 磁盘"
df /data 2>/dev/null | tail -2
echo "  环境占用：$(du -sm "$ROOT" 2>/dev/null | awk '{print $1}') MB（基线 17.7 GB，含 8.8 GB 编译树）"
