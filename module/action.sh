#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 模块「操作」按钮
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 点一下会：
#   1) 显示面板地址（本机 + 局域网）和登录账号密码（读凭据留档文件）
#   2) 显示各服务运行状态，没起来的顺手拉起来
#   3) 用手机浏览器打开面板
# 凭据文件：/data/openeuler/root/qiyuntai-panel-info.txt
# ============================================================
MODDIR=${0%/*}
ROOT=/data/openeuler
INFO=$ROOT/root/qiyuntai-panel-info.txt
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'

in_chroot() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1"; }

echo "==================== 栖云台 · 宝塔面板 ===================="

if [ ! -d "$ROOT/www/server/panel" ]; then
    echo "x 没找到 $ROOT/www/server/panel"
    echo "  请先按仓库 install/qiyuntai-install.sh 部署 openEuler chroot 与面板。"
    exit 1
fi

# ---------- 挂载（幂等）----------
mountpoint -q "$ROOT/proc"    || { mkdir -p "$ROOT/proc"; mount -t proc -o nosuid,nodev,noexec proc "$ROOT/proc"; }
mountpoint -q "$ROOT/sys"     || { mkdir -p "$ROOT/sys"; mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOT/sys"; }
mountpoint -q "$ROOT/dev"     || { mkdir -p "$ROOT/dev"; mount --bind /dev "$ROOT/dev"; }
mountpoint -q "$ROOT/dev/pts" || { mkdir -p "$ROOT/dev/pts"; mount -t devpts -o gid=5,mode=0620 devpts "$ROOT/dev/pts"; }

# ---------- 实时地址 ----------
PORT=$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)
PATHV=$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)
[ -z "$PORT" ] && PORT=8888
[ -z "$PATHV" ] && PATHV=/bt
IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[ -z "$IP" ] && IP=$(ip -4 addr 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | cut -d/ -f1 | head -1)
URL="http://127.0.0.1:${PORT}${PATHV}"

# ---------- 凭据文件：不存在就现场生成 ----------
if [ ! -f "$INFO" ]; then
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
        echo "  手机/设备内： http://127.0.0.1:${PORT}${PATHV}"
        echo "  局域网电脑 ： http://${IP}:${PORT}${PATHV}"
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

# ---------- 打印登录信息（地址按当前 IP 刷新）----------
echo ""
echo "【登录信息】"
if [ -f "$INFO" ]; then
    sed -e 's#http://[0-9][0-9.]*:[0-9]*/#http://'"$IP"':'"$PORT"'/#' "$INFO"
else
    echo "  凭据文件不存在：$INFO"
fi

echo ""
echo "【当前地址】"
echo "  手机/设备内： $URL"
[ -n "$IP" ] && echo "  局域网电脑 ： http://${IP}:${PORT}${PATHV}"
echo "  提示：必须用浏览器打开（curl 会被宝塔反爬虫拦成 404）"

# ---------- 服务状态 ----------
echo ""
echo "---------------- 服务状态 ----------------"
for s in bt nginx mysqld php-fpm-82 fail2ban crond redis memcached tomcat; do
    if in_chroot "[ -x /etc/init.d/$s ]"; then
        st=$(in_chroot "/etc/init.d/$s status >/dev/null 2>&1 && echo 运行中 || echo 未运行")
        case "$s" in
            nginx)     in_chroot "pgrep -x nginx >/dev/null 2>&1" && st="运行中" ;;
            crond)     in_chroot "pgrep -x crond >/dev/null 2>&1" && st="运行中" ;;
            mysqld)    in_chroot "pgrep -x mariadbd >/dev/null 2>&1" && st="运行中" ;;
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

# ---------- 面板自检 ----------
CODE=$(in_chroot "curl -sS -m 8 -A 'Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 Chrome/120.0 Safari/537.36' -o /dev/null -w '%{http_code}' $URL" 2>/dev/null)
echo ""
echo "面板自身响应： HTTP $CODE"

# ---------- 打开浏览器 ----------
am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1 \
    && echo "已尝试用浏览器打开面板…" \
    || echo "（自动打开失败，请手动在浏览器输入上面的地址）"

echo "=========================================================="
