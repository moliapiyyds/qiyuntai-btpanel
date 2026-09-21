#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 一键部署脚本（在手机 root shell 里执行）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 做的事：
#   1) 下载 openEuler 24.03 LTS-SP3 aarch64 rootfs（清华镜像）
#   2) 解出文件系统到 /data/openeuler
#   3) 挂载 chroot 的 /dev /dev/pts /dev/shm /proc /sys
#   4) chroot 内 dnf 预装编译依赖 + 创建 www 用户 + 打 bt_lib 锁
#   5) 用宝塔官方 install_panel.sh 安装面板
#   6) 装组件：OpenResty(nginx) / MariaDB / PHP8.2 / phpMyAdmin5.2 / Fail2ban
#   7) 打面板改造补丁（永久企业版 / 关闭更新 / 免绑定）+ 服务兼容层
#   8) 安装 KernelSU 模块
#
# 用法：
#   sh qiyuntai-install.sh              # 全流程
#   sh qiyuntai-install.sh panel        # 只装面板
#   sh qiyuntai-install.sh components   # 只装组件
#   sh qiyuntai-install.sh patch        # 只打补丁 + 兼容层
#   sh qiyuntai-install.sh module       # 只装模块
#
# 注意：本脚本会写 /data/openeuler 与 /data/adb/modules，不会动系统分区。
#       全程无 rm -rf，卸载模块也只解挂载。
# ============================================================

set -u
ROOT=/data/openeuler
REPO_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
TMP=/data/local/tmp/qiyuntai
MIRROR=https://mirrors.tuna.tsinghua.edu.cn/openeuler/openEuler-24.03-LTS-SP3/docker_img/aarch64
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'
STEP="${1:-all}"

log()  { echo "[栖云台] $*"; }
fail() { echo "[栖云台][失败] $*"; exit 1; }

in_chroot() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1"; }

need_root() {
    [ "$(id -u)" = "0" ] || fail "请用 root 执行（su -c 'sh $0'）"
}

# ---------------- 1) rootfs ----------------
step_rootfs() {
    [ -d "$ROOT/www/server/panel" ] && { log "已存在 $ROOT/www/server/panel，跳过 rootfs 部署"; return 0; }

    # 优先用 install/prepare-rootfs.sh：它处理了 toybox 既没有 curl 也没有 xz 的情况
    # （实测 Android 9 上 curl/wget/xz 都不存在，只有 busybox），
    # 而且按 manifest.json 的顺序叠加 docker 层，多层镜像也不会解错顺序。
    pr="$REPO_DIR/install/prepare-rootfs.sh"
    if [ -f "$pr" ]; then
        log "用 install/prepare-rootfs.sh 准备 rootfs"
        sh "$pr" --root "$ROOT" || fail "rootfs 准备失败（按上面输出的提示处理）"
        return 0
    fi

    # 兜底：脚本被单独推到 /sdcard（拿不到仓库目录）时走这段内置逻辑
    log "没找到 $pr，走内置逻辑"
    command -v curl >/dev/null 2>&1 || fail "这台设备没有 curl（Android 9 toybox 不带）。改为在电脑上下好后推过来：
      xz -d openEuler-docker.aarch64.tar.xz
      adb push openEuler-docker.aarch64.tar /sdcard/
      adb shell su -c \"sh /sdcard/prepare-rootfs.sh --tar /sdcard/openEuler-docker.aarch64.tar\""
    command -v xz >/dev/null 2>&1 || fail "这台设备没有 xz。改为在电脑上先 xz -d，再按上面的方式推 .tar 过来。"

    mkdir -p "$TMP"
    log "查找镜像目录…"
    idx=$(curl -sS -m 30 "$MIRROR/" | grep -oE 'openEuler-docker\.aarch64\.tar\.xz' | head -1)
    [ -n "$idx" ] || fail "镜像目录里没找到 openEuler-docker.aarch64.tar.xz（网络或镜像路径变了）"
    log "下载 rootfs（约 40 MB）…"
    curl -L --connect-timeout 20 -m 900 -o "$TMP/oe.tar.xz" "$MIRROR/$idx" || fail "下载失败"
    log "解压…"
    xz -d -T0 "$TMP/oe.tar.xz" || fail "xz 解压失败"
    mkdir -p "$TMP/layer"
    tar -xf "$TMP/oe.tar" -C "$TMP/layer" || fail "tar 解包失败"
    # docker 镜像 tar 里 layer 是 blobs/sha256/<hash>，取最大的那个当 rootfs
    layer=$(find "$TMP/layer" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
    [ -n "$layer" ] || layer="$TMP/oe.tar"
    mkdir -p "$ROOT"
    tar -xf "$layer" -C "$ROOT" || fail "layer 解包失败"
    rm -f "$TMP/oe.tar"
    log "rootfs 就绪：$ROOT"
}

# ---------------- 2) 挂载 ----------------
step_mount() {
    log "挂载 chroot 文件系统"
    mountpoint -q "$ROOT/dev"      || { mkdir -p "$ROOT/dev" && mount --bind /dev "$ROOT/dev"; }
    mountpoint -q "$ROOT/dev/pts"  || { mkdir -p "$ROOT/dev/pts" && mount -t devpts -o gid=5,mode=0620 devpts "$ROOT/dev/pts"; }
    mountpoint -q "$ROOT/dev/shm"  || { mkdir -p "$ROOT/dev/shm" && mount -t tmpfs -o mode=1777 tmpfs "$ROOT/dev/shm"; }
    mountpoint -q "$ROOT/proc"     || { mkdir -p "$ROOT/proc" && mount -t proc -o nosuid,nodev,noexec proc "$ROOT/proc"; }
    mountpoint -q "$ROOT/sys"      || { mkdir -p "$ROOT/sys" && mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOT/sys"; }

    # DNS
    {
        echo "nameserver 223.5.5.5"
        echo "nameserver 119.29.29.29"
        [ -n "$(getprop net.dns1 2>/dev/null)" ] && echo "nameserver $(getprop net.dns1)"
        [ -n "$(getprop net.dns2 2>/dev/null)" ] && echo "nameserver $(getprop net.dns2)"
    } > "$ROOT/etc/resolv.conf"

    # 宝塔需要的两个前置文件
    [ -f "$ROOT/var/bt_setupPath.conf" ] || echo "/www" > "$ROOT/var/bt_setupPath.conf"
    [ -f "$ROOT/etc/redhat-release" ]    || echo "openEuler release 24.03 (LTS-SP3)" > "$ROOT/etc/redhat-release"
    log "挂载完成"
}

# ---------------- 3) 依赖 ----------------
step_deps() {
    log "预装编译依赖 + 创建 www 用户"
    in_chroot 'dnf install --skip-broken --setopt=install_weak_deps=False -y \
      gcc gcc-c++ make cmake autoconf automake libtool bison flex patch file wget curl unzip zip tar xz \
      bzip2 bzip2-devel zlib zlib-devel openssl openssl-devel pcre pcre-devel pcre2 pcre2-devel \
      libxml2 libxml2-devel libxslt libxslt-devel expat-devel gettext gettext-devel readline-devel \
      ncurses ncurses-devel libaio libaio-devel libcap libcap-devel diffutils net-tools psmisc lsof cronie crontabs \
      gmp gmp-devel libevent libevent-devel krb5 krb5-devel c-ares c-ares-devel \
      libjpeg-turbo libjpeg-turbo-devel libpng libpng-devel freetype freetype-devel gd gd-devel \
      oniguruma oniguruma-devel libwebp libwebp-devel libvpx libvpx-devel libsodium libsodium-devel \
      glib2 glib2-devel libstdc++ libstdc++-devel perl perl-devel perl-Data-Dumper \
      vim-minimal which sudo procps-ng iproute iptables-services rsync git ca-certificates e2fsprogs e2fsprogs-devel'
    in_chroot 'id www >/dev/null 2>&1 || { NOLOGIN=/sbin/nologin; [ -x $NOLOGIN ] || NOLOGIN=/usr/sbin/nologin; [ -x $NOLOGIN ] || NOLOGIN=/bin/false; groupadd www; useradd -s $NOLOGIN -g www www; }'
    # 关键：写 bt_lib 锁，跳过宝塔原版 lib.sh 里上百个 yum 包 + openssl/mcrypt 源码编译
    echo "true" > "$ROOT/etc/bt_lib.lock"
    log "依赖就绪"
}

# ---------------- 4) 面板 ----------------
step_panel() {
    [ -x "$ROOT/www/server/panel/BT-Panel" ] && { log "面板已安装，跳过"; return 0; }
    log "安装宝塔面板（约 4-10 分钟）"
    in_chroot 'cd /root && curl -fsSL -o install_panel.sh https://download.bt.cn/install/install_panel.sh && printf "y\nyes\nyes\n" | bash install_panel.sh' \
        2>&1 | tee "$ROOT/tmp/bt_install.log"
    log "面板安装完成，接着会生成随机密码并留档凭据"
}

# ---------------- 4.5) 凭据：随机密码 + 留档（别人装了也能拿到自己的密码）----------------
step_credentials() {
    [ -d "$ROOT/www/server/panel" ] || { log "面板未安装，跳过凭据步骤"; return 1; }
    log "生成随机面板密码并写入凭据文件"
    local U P PORT PATHV IP
    U=$(in_chroot 'cd /www/server/panel && ./pyenv/bin/python3 -c "
import sqlite3
c=sqlite3.connect(\"data/db/panel.db\")
r=list(c.execute(\"select username from users where id=1\"))
print(r[0][0] if r else \"\")"' 2>/dev/null | tr -d '\r' | tail -1)
    # 用 chroot 里的 openssl 生成 16 位随机密码（每台设备都不一样）
    P=$(in_chroot 'openssl rand -hex 8' 2>/dev/null | tr -d '\r' | tail -1)
    [ -z "$P" ] && P=$(in_chroot 'head -c 8 /dev/urandom | od -An -tx1 | tr -d " \n"' 2>/dev/null | tail -1)
    if [ -n "$P" ]; then
        in_chroot "cd /www/server/panel && ./pyenv/bin/python3 -c \"import tools; tools.set_panel_pwd('$P', True)\"" || true
    fi
    PORT=$(cat "$ROOT/www/server/panel/data/port.pl" 2>/dev/null)
    PATHV=$(cat "$ROOT/www/server/panel/data/admin_path.pl" 2>/dev/null)
    IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    mkdir -p "$ROOT/root"
    {
        echo "栖云台 · 宝塔面板 访问信息（作者：茉莉 QQ:1265274322 群:570387739）"
        echo ""
        echo "【地址】"
        echo "  手机/设备内： http://127.0.0.1:${PORT}${PATHV}"
        echo "  局域网电脑 ： http://${IP}:${PORT}${PATHV}"
        echo ""
        echo "【账号】（每台设备独立随机）"
        echo "  用户名：${U}"
        echo "  密码：  ${P}"
        echo ""
        echo "【改密码/端口/入口】"
        echo "  chroot ${ROOT} /bin/bash"
        echo "  python3 /www/server/panel/tools.py   # (5)改密码 (6)改用户名 (8)改端口 (28)改安全入口"
        echo ""
        echo "【提示】必须用浏览器打开；curl 会被宝塔反爬虫拦成 404。"
    } > "$ROOT/root/qiyuntai-panel-info.txt"
    chmod 600 "$ROOT/root/qiyuntai-panel-info.txt"
    log "凭据已写入 $ROOT/root/qiyuntai-panel-info.txt（模块「操作」按钮会显示它）"
}


# ---------------- 5) 组件 ----------------
step_components() {
    log "用宝塔官方脚本安装组件（源码编译，耗时较长）"
    # lib.sh 换成本仓库的 shim：依赖已由 dnf 装好，避免重复编译 openssl/curl/mcrypt
    if [ -f "$REPO_DIR/install/lib-shim.sh" ]; then
        cp -f "$REPO_DIR/install/lib-shim.sh" "$ROOT/www/server/panel/install/lib.sh"
        chmod 755 "$ROOT/www/server/panel/install/lib.sh"
    fi
    in_chroot 'cd /www/server/panel/install && \
      bash install_soft.sh 0 install nginx openresty131 && \
      bash install_soft.sh 0 install mysql mariadb_10.11 && \
      bash install_soft.sh 0 install php 8.2 && \
      bash install_soft.sh 0 install phpmyadmin 5.2'
    log "组件安装命令已执行（结果见各自输出）"
}

step_plugins() {
    log "安装宝塔插件：Fail2ban（免登录，走官方下载接口）"
    for f in "$REPO_DIR"/tools/plugin_install.py; do
        cp -f "$f" "$ROOT/tmp/plugin_install.py"
    done
    in_chroot '/www/server/panel/pyenv/bin/python3 /tmp/plugin_install.py fail2ban'
}

# ---------------- 6) 补丁 + 兼容层 ----------------
step_patch() {
    log "打面板改造补丁（永久企业版 / 关闭更新 / 免绑定）"
    cp -f "$REPO_DIR/tools/moli_patch.py" "$ROOT/tmp/moli_patch.py"
    in_chroot '/www/server/panel/pyenv/bin/python3 /tmp/moli_patch.py'
    log "装 chroot 服务兼容层（systemctl/service/start-stop-daemon/iptables-legacy）"
    sh "$REPO_DIR/install/chroot-compat-layer.sh"
    log "Android paranoid-network 修正（MariaDB 监听 3306 必需）"
    sh "$REPO_DIR/install/android-network-fix.sh"
    in_chroot '/etc/init.d/bt restart' || true
}

# ---------------- 7) 模块 ----------------
step_module() {
    log "安装 KernelSU 模块"
    local D=/data/adb/modules/qiyuntai_btpanel
    mkdir -p "$D"
    cp -f "$REPO_DIR"/module/* "$D"/
    chmod 755 "$D"/*.sh
    chmod 644 "$D/module.prop" "$D/README.md"
    log "模块已装到 $D，重启后自动拉起服务"
}

need_root
case "$STEP" in
    all)        step_rootfs; step_mount; step_deps; step_panel; step_credentials; step_components; step_plugins; step_patch; step_module ;;
    rootfs)     step_rootfs ;;
    mount)      step_mount ;;
    deps)       step_mount; step_deps ;;
    panel)      step_mount; step_deps; step_panel; step_credentials ;;
    creds)      step_mount; step_credentials ;;
    components) step_mount; step_components ;;
    plugins)    step_mount; step_plugins ;;
    patch)      step_mount; step_patch ;;
    module)     step_module ;;
    *)          echo "用法: sh $0 [all|rootfs|mount|deps|panel|creds|components|plugins|patch|module]"; exit 1 ;;
esac
log "完成。面板地址：http://127.0.0.1:$(cat $ROOT/www/server/panel/data/port.pl 2>/dev/null)$(cat $ROOT/www/server/panel/data/admin_path.pl 2>/dev/null)"
log "登录账号密码见：$ROOT/root/qiyuntai-panel-info.txt（或点模块「操作」按钮）"
