#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 模块「操作」按钮
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 用法：
#   action.sh            显示地址账号密码 + 补拉未起的服务 + 用浏览器打开（KSU「执行」按钮走这个）
#   action.sh start      只补拉服务，不开浏览器
#   action.sh diag       只做诊断：挂载/服务/端口/面板自检/日志报错/磁盘，不重启任何服务
#   action.sh info       只显示登录信息
#
# 出问题时先跑：  sh /data/adb/modules/qiyuntai_btpanel/action.sh diag
#
# 凭据文件：/data/openeuler/root/qiyuntai-panel-info.txt
# 启动日志：/data/adb/modules/qiyuntai_btpanel/boot.log
# ============================================================
# MODDIR：绝对路径调用（KSU/Magisk 就是这么调的）和手工相对调用都要能用
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
ROOT=/data/openeuler
INFO=$ROOT/root/qiyuntai-panel-info.txt
BOOTLOG=$MODDIR/boot.log
SERVICES="bt nginx mysqld php-fpm-82 fail2ban crond redis memcached tomcat"
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'

MODE="${1:-run}"

in_chroot() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1"; }

echo "==================== 栖云台 · 宝塔面板 ===================="
echo "模式：$MODE   时间：$(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -d "$ROOT/www/server/panel" ]; then
    echo ""
    echo "x 没找到 $ROOT/www/server/panel"
    echo "  说明 chroot 环境或面板还没部署。"
    echo "  先按 install/prepare-rootfs.sh 铺 rootfs，再按 install/qiyuntai-install.sh 装面板。"
    exit 1
fi

# ---------- 挂载（幂等）----------
mountpoint -q "$ROOT/proc"    || { mkdir -p "$ROOT/proc";    mount -t proc  -o nosuid,nodev,noexec proc  "$ROOT/proc"; }
mountpoint -q "$ROOT/sys"     || { mkdir -p "$ROOT/sys";     mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOT/sys"; }
mountpoint -q "$ROOT/dev"     || { mkdir -p "$ROOT/dev";     mount --bind /dev "$ROOT/dev"; }
mountpoint -q "$ROOT/dev/pts" || { mkdir -p "$ROOT/dev/pts"; mount -t devpts -o gid=5,mode=0620 devpts "$ROOT/dev/pts"; }
mountpoint -q "$ROOT/dev/shm" || { mkdir -p "$ROOT/dev/shm"; mount -t tmpfs -o nosuid,nodev tmpfs "$ROOT/dev/shm"; }

# ---------- 实时地址 ----------
PORT=$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)
PATHV=$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)
[ -z "$PORT" ]  && PORT=8888
[ -z "$PATHV" ] && PATHV=/bt
IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[ -z "$IP" ] && IP=$(ip -4 addr 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | cut -d/ -f1 | head -1)
# 协议按面板实际配置来：bt 那个「自动申请 IP 证书」任务会写 data/ssl.pl=True，
# 面板就只收 HTTPS（那时 http 连上会被 reset、curl 退出码 56，看着像面板没起来）。
SCHEME=http
[ -f "$ROOT/www/server/panel/data/ssl.pl" ] && SCHEME=https
URL="${SCHEME}://127.0.0.1:${PORT}${PATHV}"

httpcode() {
    # -k：面板自签证书时不去校验证书链，否则拿不到状态码
    in_chroot "curl -sSk -m 8 -A 'Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 Chrome/120.0 Safari/537.36' -o /dev/null -w '%{http_code}' $1" 2>/dev/null | tail -1
}

# ---------- 凭据文件：不存在就现场生成 ----------
if [ ! -f "$INFO" ] && [ "$MODE" != "diag" ]; then
    mkdir -p "$ROOT/root"
    U=$(in_chroot 'cd /www/server/panel && ./pyenv/bin/python3 -c "
import sqlite3
c=sqlite3.connect(\"data/db/panel.db\")
r=list(c.execute(\"select username from users where id=1\"))
print(r[0][0] if r else \"\")"' 2>/dev/null | tr -d '\r' | tail -1)
    P=$(grep -a "^ *password:" "$ROOT/tmp/bt_install.log" 2>/dev/null | tail -1 | awk '{print $2}')
    [ -z "$P" ] && P="(安装时未保存，请用 tools.py 菜单(5) 重置)"
    {
        echo "栖云台 · 宝塔面板 访问信息（作者：茉莉 QQ:1265274322 群:570387739）"
        echo ""
        echo "【地址】"
        echo "  手机/设备内： ${SCHEME}://127.0.0.1:${PORT}${PATHV}"
        echo "  局域网电脑 ： ${SCHEME}://${IP}:${PORT}${PATHV}"
        echo ""
        echo "【账号】"
        echo "  用户名：${U}"
        echo "  密码：  ${P}"
        echo ""
        echo "【改密码/端口/入口】"
        echo "  chroot ${ROOT} /bin/bash"
        echo "  python3 /www/server/panel/tools.py   # (5)改密码 (6)改用户名 (8)改端口 (28)改安全入口"
    } > "$INFO"
    chmod 600 "$INFO"
fi

# ============================================================
# 诊断模式
# ============================================================
diag() {
    echo ""
    echo "================ 诊断 ================"

    echo ""
    echo "---- 1) chroot 挂载点 ----"
    for m in proc sys dev dev/pts dev/shm; do
        if mountpoint -q "$ROOT/$m"; then
            printf "  %-10s 已挂载\n" "$m"
        else
            printf "  %-10s ！！未挂载\n" "$m"
        fi
    done

    echo ""
    echo "---- 2) chroot 可用性 ----"
    if V=$(in_chroot 'cat /etc/os-release 2>/dev/null | head -1' 2>/dev/null) && [ -n "$V" ]; then
        echo "  OK  $V"
    else
        echo "  ！！chroot 进不去（rootfs 损坏 / 挂载缺失 / SELinux 拦截）"
    fi

    echo ""
    echo "---- 3) 网络组修正（Android paranoid-network）----"
    G=$(in_chroot 'grep -c "^inet:x:3003:" /etc/group 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$G" = "1" ]; then
        echo "  OK  /etc/group 里有 inet:x:3003:"
        for u in mysql redis memcached www; do
            if in_chroot "id -nG $u 2>/dev/null | tr ' ' '\n' | grep -qx inet" 2>/dev/null; then
                printf "  OK  %-10s 在 inet 组\n" "$u"
            else
                printf "  ！！%-10s 不在 inet 组  → 它 bind TCP 会失败 (errno 13)\n" "$u"
            fi
        done
    else
        echo "  ！！没有 inet:x:3003:  → 需要: echo 'inet:x:3003:' >> /etc/group && usermod -aG inet mysql redis memcached www"
    fi

    echo ""
    echo "---- 4) 服务进程 ----"
    # 探测逻辑与下面的补拉逻辑保持一致（bt 实际进程是 python3，不能用 pgrep -x BT-Panel）
    for s in $SERVICES; do
        st=$(in_chroot "/etc/init.d/$s status >/dev/null 2>&1 && echo run || echo down" 2>/dev/null | tr -d '\r')
        case "$s" in
            nginx)     in_chroot "pgrep -x nginx >/dev/null 2>&1"     && st=run ;;
            crond)     in_chroot "pgrep -x crond >/dev/null 2>&1"     && st=run ;;
            mysqld)    in_chroot "pgrep -x mariadbd >/dev/null 2>&1"  && st=run ;;
            memcached) in_chroot "pgrep -x memcached >/dev/null 2>&1" && st=run ;;
            tomcat)    in_chroot "pgrep -f 'catalina.base=/www/server/tomcat' >/dev/null 2>&1" && st=run ;;
            bt)        in_chroot "pgrep -f 'BT-Panel' >/dev/null 2>&1" && st=run ;;
        esac
        pid=$(in_chroot "pgrep -f '$s' 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
        if [ "$st" = "run" ]; then
            printf "  %-14s 运行中 %s\n" "$s" "${pid:+(pid $pid)}"
        else
            printf "  %-14s ！！未运行\n" "$s"
        fi
    done
    # supervisord / sshd 不在 init.d 体系里，单独看
    for s in supervisord sshd; do
        pid=$(in_chroot "pgrep -x $s 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
        [ -n "$pid" ] && printf "  %-14s 运行中 (pid %s)\n" "$s" "$pid" \
                      || printf "  %-14s ！！未运行\n" "$s"
    done

    echo ""
    echo "---- 5) 端口监听 ----"
    for p in 80 443 888 3306 6379 11211 8080 "$PORT" 22; do
        [ -z "$p" ] && continue
        if in_chroot "netstat -tln 2>/dev/null | grep -q ':$p '" 2>/dev/null; then
            printf "  %-6s 监听中\n" "$p"
        else
            printf "  %-6s 未监听\n" "$p"
        fi
    done

    echo ""
    echo "---- 6) 面板自检 ----"
    C=$(httpcode "$URL")
    echo "  $URL  →  HTTP ${C:-无响应}"
    case "$C" in
        200) echo "  OK  面板正常" ;;
        000|"") echo "  ！！面板没响应：看上面 bt 服务是否运行、端口是否监听" ;;
        404) echo "  ？！404：入口路径不对（读 data/admin_path.pl），或用了 curl 默认 UA 被宝塔反爬虫拦" ;;
        *)   echo "  ！！HTTP $C：看 /www/server/panel/logs/error.log" ;;
    esac

    echo ""
    echo "---- 7) 磁盘占用 ----"
    # df -P：本机 df 输出会因设备名过长折行，NR==2 取不到数据（实测踩过）
    echo "  /data 挂载点剩余：$(df -P -h /data 2>/dev/null | awk 'NR==2{print $4" / "$2" ("$5")"}')"
    if [ "$DIAG_DU" = "1" ]; then
        echo "  正在算 $ROOT 占用（大目录会慢十几秒）…"
        SZ=$(du -sh "$ROOT" 2>/dev/null | awk '{print $1}')
        echo "  $ROOT 占用：${SZ:-未知}"
    else
        echo "  $ROOT 占用：设 DIAG_DU=1 再跑一次可统计（约 17.7 GB，会慢）"
    fi

    echo ""
    echo "---- 8) boot.log 里的异常行（最近 200 行内过滤）----"
    if [ -f "$BOOTLOG" ]; then
        BAD=$(tail -n 200 "$BOOTLOG" | grep -niE '警告|失败|failed|error|not found|denied|refused' | tail -n 15)
        if [ -n "$BAD" ]; then
            echo "$BAD" | sed 's/^/  /'
        else
            echo "  没有明显异常行"
        fi
        echo ""
        echo "  最近 5 行："
        tail -n 5 "$BOOTLOG" | sed 's/^/    /'
    else
        echo "  没有 $BOOTLOG（模块可能还没跑过开机流程）"
    fi

    echo ""
    echo "---- 9) 面板关键文件 ----"
    for f in data/port.pl data/admin_path.pl data/db/panel.db data/initBind.pl data/bind.pl; do
        if [ -e "$ROOT/www/server/panel/$f" ]; then
            printf "  OK      %s\n" "$f"
        else
            printf "  ！！缺失 %s\n" "$f"
        fi
    done

    echo ""
    echo "---- 10) 破解补丁 ----"
    if [ -f "$ROOT/www/server/panel/moli_patch/moli_patch.py" ]; then
        L=$(in_chroot 'cd /www/server/panel && ./pyenv/bin/python3 -c "
import public
print(\"is_bind=\", public.is_bind())
"' 2>/dev/null | tr -d '\r' | tail -1)
        echo "  补丁文件在：moli_patch/moli_patch.py"
        echo "  $L"
    else
        echo "  ！！没找到 moli_patch/moli_patch.py，破解补丁未装"
    fi

    echo ""
    echo "================ 诊断结束 ================"
}

# ============================================================
# 各模式
# ============================================================
case "$MODE" in
diag)
    diag
    exit 0
    ;;
esac

# ---------- 打印登录信息 ----------
echo ""
echo "【登录信息】"
if [ -f "$INFO" ]; then
    # 凭据文件里烘的是打补丁那会儿写的地址；面板协议/局域网 IP 可能已经变了，
    # 这里把协议与 IP:端口 换成当前的（凭据文件本身不动）
    sed -e 's#https\?://[0-9][0-9.]*:[0-9]*/#'"$SCHEME"'://'"$IP"':'"$PORT"'/#' "$INFO"
else
    echo "  凭据文件不存在：$INFO"
fi

echo ""
echo "【当前地址】"
echo "  手机/设备内： $URL"
[ -n "$IP" ] && echo "  局域网电脑 ： ${SCHEME}://${IP}:${PORT}${PATHV}"
echo "  提示：必须用浏览器打开（curl 会被宝塔反爬虫拦成 404）"
echo "  诊断：$MODDIR/action.sh diag"

if [ "$MODE" = "info" ]; then
    echo "=========================================================="
    exit 0
fi

# ---------- 服务状态（顺便补拉）----------
echo ""
echo "---------------- 服务状态 ----------------"
for s in $SERVICES; do
    if in_chroot "[ -x /etc/init.d/$s ]"; then
        st=$(in_chroot "/etc/init.d/$s status >/dev/null 2>&1 && echo 运行中 || echo 未运行")
        case "$s" in
            nginx)     in_chroot "pgrep -x nginx >/dev/null 2>&1"     && st="运行中" ;;
            crond)     in_chroot "pgrep -x crond >/dev/null 2>&1"     && st="运行中" ;;
            mysqld)    in_chroot "pgrep -x mariadbd >/dev/null 2>&1"  && st="运行中" ;;
            memcached) in_chroot "pgrep -x memcached >/dev/null 2>&1" && st="运行中" ;;
            tomcat)    in_chroot "pgrep -f 'catalina.base=/www/server/tomcat' >/dev/null 2>&1" && st="运行中" ;;
        esac
        printf "  %-14s %s\n" "$s" "$st"
        if [ "$st" = "未运行" ]; then
            in_chroot "/etc/init.d/$s start" >/dev/null 2>&1
            printf "  %-14s 已尝试重新启动\n" ""
        fi
    fi
done

# sshd（不在 init.d 体系里，单独兜底）
if in_chroot "pgrep -x sshd >/dev/null 2>&1"; then
    printf "  %-14s %s\n" "sshd" "运行中"
elif [ -f "$ROOT/etc/ssh/sshd_config_moli" ]; then
    in_chroot "/usr/sbin/sshd -f /etc/ssh/sshd_config_moli" >/dev/null 2>&1
    sleep 1
    if in_chroot "pgrep -x sshd >/dev/null 2>&1"; then
        printf "  %-14s %s\n" "sshd" "已拉起"
    else
        printf "  %-14s %s\n" "sshd" "！！启动失败"
    fi
fi

# ---------- 面板自检 ----------
CODE=$(httpcode "$URL")
echo ""
echo "面板自身响应： HTTP ${CODE:-无响应}"

if [ "$CODE" != "200" ]; then
    echo ""
    echo ">> 面板没返回 200，自动附上诊断摘要（完整版：$MODDIR/action.sh diag）"
    diag
    echo "=========================================================="
    exit 1
fi

# ---------- 打开浏览器 ----------
am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1 \
    && echo "已尝试用浏览器打开面板…" \
    || echo "（自动打开失败，请手动在浏览器输入上面的地址）"

echo "=========================================================="
