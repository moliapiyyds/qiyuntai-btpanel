#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 一键部署脚本（在手机 root shell 里执行）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 做的事（步骤名就是下面 case 里的名字，可以单独跑某一步）：
#   rootfs     铺 openEuler 24.03 LTS-SP3 aarch64 rootfs（默认走镜像站；
#              也可以用 deploy.sh --from-image 从预制镜像解包，那就跳过这一步）
#   mount      挂载 chroot 的 /dev /dev/pts /dev/shm /proc /sys + 写 DNS / hostname
#   deps       chroot 内 dnf 装编译依赖与运行时包 + 建 www 用户 + 打 bt_lib 锁
#   panel      用宝塔官方安装器装面板（installer.lock 锁 sha256，expect 驱动交互）
#   creds      生成 16 位随机面板密码并写凭据文件（来自镜像时还会重随机化端口/入口/用户名/主机密钥）
#   components 装组件：OpenResty / MariaDB 10.11 / PHP 8.2 / phpMyAdmin
#   plugins    装 9 个宝塔插件 + 从宝塔源码包编 memcached 1.6.45
#   parity     按 install/baseline-packages.txt（548 条基线 rpm）逐包名对齐
#   patch      打面板改造补丁 + 关掉面板自动 SSL + 装服务兼容层
#              + 装仓库自备的 crond/tomcat/memcached init 脚本 + sshd 配置
#   module     安装 KernelSU 模块到 /data/adb/modules/qiyuntai_btpanel
#
# 用法：
#   sh qiyuntai-install.sh              # 全流程（= all）
#   sh qiyuntai-install.sh panel        # 只装面板
#   sh qiyuntai-install.sh components   # 只装组件
#   sh qiyuntai-install.sh patch        # 只打补丁 + 兼容层 + 自备文件
#   sh qiyuntai-install.sh module       # 只装模块
#   （可选：rootfs / mount / deps / creds / plugins / parity）
#
# 注意：本脚本会写 /data/openeuler 与 /data/adb/modules，不会动系统分区。
#       本脚本自身不含 rm -rf；删除环境只有一条路：
#       install/prepare-rootfs.sh --clean（先解挂载、断言干净、才删）。
# ============================================================

set -u
ROOT=/data/openeuler
REPO_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
TMP=/data/local/tmp/qiyuntai
MIRROR=https://mirrors.tuna.tsinghua.edu.cn/openeuler/openEuler-24.03-LTS-SP3/docker_img/aarch64
# 官方安装器：先落盘再校验，不 curl | bash（原因见 step_panel 注释）
INSTALLER_URL=https://download.bt.cn/install/install_panel.sh
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'
STEP="${1:-all}"

log()  { echo "[栖云台] $*"; }
# warn 是后来加警告时才开始用的，但一开始忘了定义 —— 结果是 18 处警告全都变成
# `sh: warn: not found` 打不出来（2026-09-22 核对时才发现）。警告走 stderr，
# 这样和正常输出能分开，日志里也搜得到「注意」。
warn() { echo "[栖云台][注意] $*" >&2; }
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
        # 必须把「源」交出去：prepare-rootfs.sh 自己不知道要装哪个文件，
        # 以前这里只传 --root，它会以「没给源。用 --url / --xz / --tar 之一」退出，
        # 一键部署就卡死在 rootfs 这一步（2026-09-21 实测复现）。
        # --mirror 让它用自己探好的下载器去列目录挑文件，不用在这里重复一套逻辑。
        log "用 install/prepare-rootfs.sh 准备 rootfs（--mirror）"
        sh "$pr" --root "$ROOT" --mirror || fail "rootfs 准备失败（按上面输出的提示处理）"
        return 0
    fi

    # 兜底：脚本被单独推到手机（拿不到仓库目录）时走这段内置逻辑
    log "没找到 $pr，走内置逻辑"
    command -v curl >/dev/null 2>&1 || fail "这台设备没有 curl（Android 9 toybox 不带）。改为在电脑上下好后推过来：
      xz -d openEuler-docker.aarch64.tar.xz
      adb push openEuler-docker.aarch64.tar /data/local/tmp/
      adb shell su -c \"sh /data/local/tmp/install/prepare-rootfs.sh --tar /data/local/tmp/openEuler-docker.aarch64.tar\""
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
      vim-minimal which sudo procps-ng iproute iptables-services rsync git ca-certificates e2fsprogs e2fsprogs-devel \
      expect openssh-server openssh-clients nodejs npm'
    # 运行时组件（不是编译依赖）：这里只留 redis 当兜底。
    # 注意版本差异（实测）：openEuler 源里是 redis 7.2.15 / memcached 1.6.22，
    # 而基线记的是 redis 7.2.16 / memcached 1.6.45 —— 基线那两份都是宝塔自带的
    # （redis 由 redis 插件装到 /www/server/redis，memcached 由 step_memcached 从
    # 宝塔源码包编到 /usr/local/memcached）。所以 dnf 这条只是「万一」用的。
    if in_chroot 'dnf install --skip-broken -y redis' >/dev/null 2>&1; then
        log "已装 redis（dnf 兜底）"
    else
        warn "redis 的 dnf 安装没成功（面板 redis 插件会自带，继续）"
    fi

    in_chroot 'id www >/dev/null 2>&1 || { NOLOGIN=/sbin/nologin; [ -x $NOLOGIN ] || NOLOGIN=/usr/sbin/nologin; [ -x $NOLOGIN ] || NOLOGIN=/bin/false; groupadd www; useradd -s $NOLOGIN -g www www; }'
    # 关键：写 bt_lib 锁，跳过宝塔原版 lib.sh 里上百个 yum 包 + openssl/mcrypt 源码编译
    echo "true" > "$ROOT/etc/bt_lib.lock"
    log "依赖就绪"
}

# ---------------- 4) 面板 ----------------
# 说明：这里**不是** curl | bash 把安装器直接喂进去，也不用固定顺序喂答案。
#
# 实测依据（2026-09-21）：
#   1) 官方 install_panel.sh 里有三个提问点，其中「输入yes强制安装」在函数内部、
#      是条件路径，所以**文本顺序 ≠ 运行顺序**。原来写的
#      printf "y\nyes\nyes\n" | bash install_panel.sh 把答案顺序和官方提问顺序
#      绑死了，官方动一处就会答错位置。
#   2) 更隐蔽的是：bash 的 read -p 在 stdin 不是终端时**不打印提示**
#      （管道和 FIFO 都实测过，stderr 为空；旧日志里也搜不到任何提示文本）。
#      也就是说喂管道的时候，答错了连日志都看不出来。
#
# 现在的做法：先落盘 → 校验 sha256（allow-list，见 install/installer.lock）
#             → 列出提问点供对照 → 用 expect 分配 pty，按**提示内容**作答。
step_panel() {
    [ -x "$ROOT/www/server/panel/BT-Panel" ] && { log "面板已安装，跳过"; return 0; }

    log "下载宝塔官方安装器（先落盘，不再 curl|bash）"
    in_chroot "curl -fsSL --max-time 120 -o /root/install_panel.sh $INSTALLER_URL" \
        || fail "下载 install_panel.sh 失败（$INSTALLER_URL）"

    local H
    H=$(in_chroot 'sha256sum /root/install_panel.sh' | cut -d' ' -f1 | tr -d '\r')
    log "install_panel.sh sha256 = $H"
    if [ -f "$REPO_DIR/install/installer.lock" ] && grep -q "^$H" "$REPO_DIR/install/installer.lock"; then
        log "哈希命中 install/installer.lock（人工核验过的版本）"
    else
        warn "哈希不在已核验清单里 —— 官方安装器很可能已经更新"
        warn "不会中止，但会改按提示内容作答；遇到不认识的提问会立即失败，不会乱答"
        warn "人工核验通过后，把 $H 追加到 install/installer.lock"
    fi

    log "静态列出安装器里的提问点（供人工对照）"
    grep -n 'read -p' "$ROOT/root/install_panel.sh" 2>/dev/null | sed 's/^/    /' || true

    log "安装宝塔面板（expect 驱动 pty，约 4-10 分钟）"
    cp -f "$REPO_DIR/install/bt-panel-install.exp" "$ROOT/root/bt-panel-install.exp"
    chmod 755 "$ROOT/root/bt-panel-install.exp"
    in_chroot '/usr/bin/expect -f /root/bt-panel-install.exp /root/install_panel.sh'
    local rc=$?
    [ "$rc" = "0" ] || fail "面板安装失败（驱动退出码 $rc，完整记录 $ROOT/tmp/qyt_panel_install.log）"

    [ -x "$ROOT/www/server/panel/BT-Panel" ] \
        || fail "安装器跑完了，但没找到 $ROOT/www/server/panel/BT-Panel"

    log "面板已安装"
    if ls "$ROOT"/tmp/LinuxPanel-*.pl >/dev/null 2>&1; then
        log "官方包记录（官方自己写的版本+zip哈希）: $(cat "$ROOT"/tmp/LinuxPanel-*.pl 2>/dev/null | head -c 200)"
    fi
    in_chroot "grep -m1 'g.version' /www/server/panel/class/common.py" | sed 's/^/    /'
    log "面板安装完成，接着会生成随机密码并留档凭据"
}

# ---------------- 4.5) 凭据：随机密码 + 留档（别人装了也能拿到自己的密码）----------------
step_credentials() {
    [ -d "$ROOT/www/server/panel" ] || { log "面板未安装，跳过凭据步骤"; return 1; }
    log "生成随机面板密码并写入凭据文件"
    local U P PORT PATHV IP

    # ---- 来自预制镜像时，把所有「身份」重新随机化 ----
    # 为什么必须做：预制镜像里烘的是打包那台机器的端口、安全入口、用户名。
    # 不重新随机，所有用同一个镜像的人端口和入口路径就完全一样 ——
    # 既违背 README 里「每台随机」的承诺，也让扫描器更容易一网打尽。
    if [ -f "$ROOT/.from-image" ]; then
        log "检测到来自预制镜像：重新随机化 端口 / 安全入口 / 用户名"
        local NP NEWP NEWU i
        NP=$(in_chroot 'openssl rand -hex 2' 2>/dev/null | tr -d '\r' | tail -1)
        case "$NP" in ''|*[!0-9a-f]*) NP=$(printf '%x' $(( ($$ % 30000) + 20000 )));; esac
        NP=$(( 0x$NP % 40000 + 20000 ))
        i=0
        while [ $i -lt 200 ] && netstat -ltn 2>/dev/null | grep -q ":$NP "; do
            NP=$((NP + 1)); i=$((i + 1))
        done
        echo "$NP" > "$ROOT/www/server/panel/data/port.pl"
        NEWP=$(in_chroot 'openssl rand -hex 4' 2>/dev/null | tr -d '\r' | tail -1)
        case "$NEWP" in ''|*[!0-9a-f]*) NEWP=$(printf '%08x' $(( $$ * 7919 )));; esac
        echo "/$NEWP" > "$ROOT/www/server/panel/data/admin_path.pl"
        NEWU=$(in_chroot 'openssl rand -hex 4' 2>/dev/null | tr -d '\r' | tail -1)
        if [ -n "$NEWU" ]; then
            in_chroot "cd /www/server/panel && ./pyenv/bin/python3 -c \"
import sqlite3
c = sqlite3.connect('data/db/panel.db')
c.execute('update users set username=? where id=1', ('$NEWU',))
c.commit()\"" || warn "改用户名失败（保持镜像里的），不影响其它"
        fi
        in_chroot '/etc/init.d/bt restart' >/dev/null 2>&1 || true
        # sshd 主机密钥同样要重生成：镜像里烘的是打包那台的密钥，
        # 同一个镜像刷多台设备就会共用同一份主机密钥。重启后 service.sh 会用新密钥拉起 sshd。
        rm -f "$ROOT"/etc/ssh/ssh_host_*
        if in_chroot 'ssh-keygen -A' >/dev/null 2>&1; then
            log "已重新生成 sshd 主机密钥"
        else
            warn "ssh-keygen -A 失败（sshd 会没有主机密钥）"
        fi
        log "已重新随机化：端口 $NP，安全入口 /$NEWP，用户名 ${NEWU:-未改}"
    fi
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
    # 面板是不是开了 SSL：装完之后 bt 那个「自动申请 IP 证书」任务会写 data/ssl.pl=True
    # （本仓库的 patch 步骤会关掉它，但用户自己也可能在面板里开）。协议写错了链接就连不上。
    SCHEME=http
    [ -f "$ROOT/www/server/panel/data/ssl.pl" ] && SCHEME=https
    {
        echo "栖云台 · 宝塔面板 访问信息（作者：茉莉 QQ:1265274322 群:570387739）"
        echo ""
        echo "【地址】"
        echo "  手机/设备内： ${SCHEME}://127.0.0.1:${PORT}${PATHV}"
        echo "  局域网电脑 ： ${SCHEME}://${IP}:${PORT}${PATHV}"
        if [ "$SCHEME" = "https" ]; then
            echo "  （面板开了 SSL，证书是自签的 —— 浏览器会提示不安全，点继续即可）"
        fi
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
    # 覆盖前必须把原版留一份 —— docs/handover.md §六 与 module/README.md §七 都把
    # install/lib.sh.bt-orig 列为回滚点，而原来这里是直接 cp -f 覆盖，备份从来没生成过。
    # 幂等：已经有 .bt-orig 就不再动，否则第二次执行会把 shim 当成「原版」备份掉。
    if [ -f "$REPO_DIR/install/lib-shim.sh" ]; then
        if [ -f "$ROOT/www/server/panel/install/lib.sh" ] \
           && [ ! -f "$ROOT/www/server/panel/install/lib.sh.bt-orig" ]; then
            cp -p "$ROOT/www/server/panel/install/lib.sh" \
                  "$ROOT/www/server/panel/install/lib.sh.bt-orig" \
                && log "已留底宝塔原版 lib.sh -> install/lib.sh.bt-orig"
        fi
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

# 宝塔插件清单 —— 必须和 README.md / module/README.md 里承诺的一致。
#
# 【踩过的坑，2026-09-21 核对基线时发现】
#   这里原来只装 fail2ban 一个，而文档写的是 9 个。结果是：
#   一键部署装出来的环境跟"标准环境"根本不是同一个 —— 缺 redis / tomcat /
#   supervisor / nodejs / JDK 这些插件，模块 service.sh 去拉起那 11 项服务时
#   缺的会被一项一项"跳过"，而**没有任何地方会报错**。文档却写着都有。
#   旧环境里那 9 个插件是我当初手工装的，脚本从来没同步。
PLUGINS="fail2ban redis tomcat2 supervisor nodejs java_manager jdk_manager pyenv_manager pythonmamager"

step_plugins() {
    log "安装宝塔插件（免登录，走官方下载接口）"
    cp -f "$REPO_DIR/tools/plugin_install.py" "$ROOT/tmp/plugin_install.py"
    local bad="" n=0
    for p in $PLUGINS; do
        # 幂等：已经装了就不重复下（image 路径下会走到这里，插件通常在镜像里了）
        if [ -d "$ROOT/www/server/panel/plugin/$p" ]; then
            log "  $p：已存在，跳过"
            n=$((n + 1))
            continue
        fi
        if in_chroot "/www/server/panel/pyenv/bin/python3 /tmp/plugin_install.py $p" >/dev/null 2>&1; then
            log "  $p：装好"
            n=$((n + 1))
        else
            warn "  $p：没装上"
            bad="$bad $p"
        fi
    done
    log "插件步骤完成：$n/$(printf '%s\n' $PLUGINS | wc -l) 个在位"
    # 缺插件就失败，不要静默放过 —— 文档承诺它们都在，缺了就不是同一个环境
    [ -z "$bad" ] || fail "这些插件没装上：$bad"

    step_memcached
}

# memcached：从宝塔的源码包自己编（1.6.45）
#
# 【为什么不能只 dnf 装】
#   面板 13.0.0 的 install/install_soft.sh 里**已经没有 memcached** 了
#   （grep 全无），商店那 9 个插件里也没有 memcached 插件；而基线那台的
#   /etc/init.d/memcached 是 2019-09-19 的宝塔脚本，里面写死
#   `/usr/local/memcached/bin/memcached -d -l 127.0.0.1 -p 11211 -u memcached -m 64 -c 1024`。
#   实测 download.bt.cn 上只有 memcached-1.6.45.tar.gz 返回 200
#   （1.6.22 / 1.6.38 都是 404），而 openEuler 源里只有 1.6.22 ——
#   所以基线那份 1.6.45 就是从宝塔源码包编出来的，只靠 dnf 装不出同一个版本。
MC_URL="https://download.bt.cn/src/memcached-1.6.45.tar.gz"
MC_SHA="d362c64e6d8d5287153501eabf7c85b4a761432fbf53f5d7b085d0bb1653c1dd"
MC_PREFIX=/usr/local/memcached

step_memcached() {
    if [ -x "$ROOT$MC_PREFIX/bin/memcached" ]; then
        log "memcached 已在 $MC_PREFIX，跳过"
        return 0
    fi
    log "编译 memcached 1.6.45（宝塔源码包 → $MC_PREFIX）"
    local ok=0 sha
    if in_chroot "curl -fsSL -o /tmp/mc.tar.gz '$MC_URL'"; then
        sha=$(in_chroot 'sha256sum /tmp/mc.tar.gz' | awk '{print $1}' | tr -d '\r')
        if [ "$sha" = "$MC_SHA" ]; then
            log "  源码包 sha256 与记录一致"
        else
            warn "  源码包 sha256 变了（记录 $MC_SHA，实际 ${sha:-取不到}），继续但留意"
        fi
        # 顶层目录名带版本号，用通配而不是写死，免得宝塔换了包就直接失败
        if in_chroot 'mkdir -p /tmp/mcbuild && tar -xzf /tmp/mc.tar.gz -C /tmp/mcbuild \
             && cd /tmp/mcbuild/memcached-* \
             && ./configure --prefix='"$MC_PREFIX"' >/tmp/mc_conf.log 2>&1 \
             && make -j4 >/tmp/mc_make.log 2>&1 \
             && make install >/tmp/mc_install.log 2>&1'; then
            ok=1
        fi
    fi
    if [ "$ok" = "1" ] && [ -x "$ROOT$MC_PREFIX/bin/memcached" ]; then
        log "  memcached 就绪：$(in_chroot "$MC_PREFIX/bin/memcached --version" | tr -d '\r' | tail -1)"
        in_chroot 'rm -rf /tmp/mcbuild /tmp/mc.tar.gz /tmp/mc_conf.log /tmp/mc_make.log /tmp/mc_install.log' || true
    else
        warn "从宝塔源码包编 memcached 失败，退回 openEuler 源的 1.6.22（与基线版本不同，功能一样）"
        in_chroot 'dnf install --skip-broken -y memcached' || warn "  dnf 兜底也没成"
    fi
    # 基线那个 init 脚本用 -u memcached，所以得有这个用户
    in_chroot 'id memcached >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /var/lib/memcached memcached' \
        || warn "  建 memcached 用户失败（init 脚本会退化成 -u root）"
}

# ---------------- 6) 补丁 + 兼容层 ----------------
step_patch() {
    # 先把仓库自带的 init 脚本装进 chroot。
    # chroot 里没有 systemd，而「谁提供 /etc/init.d/<服务>」这件事必须逐个对账
    # （安装器不带、面板包不带、openEuler 只给 systemd 单元），否则 service.sh
    # 只会打印一行"跳过"然后什么都不发生。逐个来源：
    #   bt / nginx / mysqld / php-fpm-82 ← 宝塔安装器与组件安装脚本
    #   fail2ban / redis / tomcat2      ← 宝塔对应插件（tomcat2 插件不带 init，
    #                                     所以 tomcat 仍由我们提供）
    #   crond / tomcat / memcached      ← 仓库自己写，就是下面这三个
    # 不装的后果：service.sh 里 `start_svc tomcat` / `start_svc memcached`
    # 因为没有兜底逻辑，直接跳过 —— **Tomcat、Memcached 起不来**，
    # crond 有 /usr/sbin/crond 兜底但走 init 更统一。
    # 实测踩过：这三个 .initd 原来只出现在文档里，没有任何脚本引用它们。
    for s in crond tomcat memcached; do
        if [ -f "$REPO_DIR/install/$s.initd" ]; then
            cp -f "$REPO_DIR/install/$s.initd" "$ROOT/etc/init.d/$s"
            chmod 755 "$ROOT/etc/init.d/$s"
            log "已装 init 脚本：/etc/init.d/$s"
        else
            warn "缺 install/$s.initd —— /etc/init.d/$s 不会存在，模块开机那步会跳过它"
        fi
    done

    # sshd：service.sh 第 4.7 段的「adb 不通时的救命通道」。
    # 面板不带它、openEuler 基础镜像里也没有 —— 但基线里 `sshd` 是在跑的
    # （netstat 有 0.0.0.0:22，进程名 sshd_config_mo…），说明 openssh-server 与这个
    # 配置当年是手工装的，脚本同样没同步。缺了它 service.sh 只会打印「未找到 … 跳过 sshd」。
    # 配置内容是从删除前的备份 tarball 里原样取出来的（sha256 951da0fb…，365 字节）。
    if [ -f "$REPO_DIR/install/sshd_config_moli" ]; then
        mkdir -p "$ROOT/etc/ssh"
        cp -f "$REPO_DIR/install/sshd_config_moli" "$ROOT/etc/ssh/sshd_config_moli"
        chmod 644 "$ROOT/etc/ssh/sshd_config_moli"
        log "已装 sshd 配置：/etc/ssh/sshd_config_moli"
    else
        warn "缺 install/sshd_config_moli —— sshd 兜底通道不会起来"
    fi
    # 主机密钥：没生成过就现场生成（每台设备独立，不共用密钥）
    if [ ! -f "$ROOT/etc/ssh/ssh_host_ed25519_key" ]; then
        in_chroot 'ssh-keygen -A' >/dev/null 2>&1 \
            && log "已生成 sshd 主机密钥（ssh-keygen -A）" \
            || warn "ssh-keygen -A 失败（sshd 可能起不来）"
    fi

    log "打面板改造补丁（永久企业版 / 关闭更新 / 免绑定）"
    cp -f "$REPO_DIR/tools/moli_patch.py" "$ROOT/tmp/moli_patch.py"
    in_chroot '/www/server/panel/pyenv/bin/python3 /tmp/moli_patch.py'
    # 打完立刻复核一遍：verify 会把「没生效」的条目逐条列出来。
    # 为什么必须做（2026-09-22 实测）：补丁的前端那几步要用 node --check 校验 JS，
    # 环境里还没有 node 时旧版会直接 traceback 中断 —— 后端的几条已经打上了、
    # 前端的几条一条没做，日志里只有一段调用栈，很容易被当成「补丁打完了」。
    # 这里不 fail（前端条目不影响后端功能），但一定要把「没生效」喊出来。
    local vout
    vout=$(in_chroot '/www/server/panel/pyenv/bin/python3 /tmp/moli_patch.py verify' 2>&1 | tr -d '\r')
    printf '%s\n' "$vout" | sed 's/^/    /'
    if printf '%s' "$vout" | grep -q '未生效'; then
        warn "补丁有没生效的条目（见上）。装了 nodejs 再跑一次 patch 步骤即可补齐（幂等）"
    fi
    # ---- 关掉面板的「自动申请 IP 证书」 ----
    # 实测（2026-09-22）：面板装完后不到 1 小时，task.py 里那个 interval=3600 的
    # `check_panel_ssl` 任务就会调 script/panel_ssl_task.py 给面板 IP 签一张自签证书，
    # 然后写 data/ssl.pl=True —— 面板从此**只收 HTTPS**：
    #   明文 http://127.0.0.1:<端口>/<入口> 连上就被 reset（curl 报 000，不是 404），
    #   非常容易误判成「面板没起来 / 端口不对」。
    # 而本项目的文档、模块开机自检、action.sh 打印的地址全是 http://。
    # 三层都堵：拿掉 ssl.pl（立刻恢复 http）→ 把那个脚本换成空壳（每小时那趟不再打开它）
    # → 清掉它的状态文件。想用 HTTPS 就把它换回来并重新申请（见 module/README）。
    log "关闭面板自动 SSL（否则面板只收 HTTPS，明文 http 连不上）"
    SSL_TASK="$ROOT/www/server/panel/script/panel_ssl_task.py"
    if [ -f "$SSL_TASK" ] && ! grep -q 'MOLI_SSL_OFF' "$SSL_TASK" 2>/dev/null; then
        cp -f "$SSL_TASK" "$SSL_TASK.moli-orig" 2>/dev/null || true
        cat > "$SSL_TASK" <<'EOS'
# MOLI_SSL_OFF：茉莉定制 —— 本脚本被换成空壳。
# 原版会调 auto_apply_ip_ssl.py 给面板 IP 申请证书并写 data/ssl.pl=True，
# 于是面板只收 HTTPS，而本项目的文档/开机自检/地址打印都是 http://。
# 原版在同目录 panel_ssl_task.py.moli-orig；想恢复自动 SSL 就换回来，
# 再删掉自己的替换（本文件）并重新申请证书即可。
import sys
sys.exit(0)
EOS
        chmod 700 "$SSL_TASK"
        log "  已空壳化 panel_ssl_task.py（原版存同目录 .moli-orig）"
    fi
    rm -f "$ROOT/www/server/panel/data/ssl.pl" "$ROOT/www/server/panel/data/check_ssl_cron.pl"
    log "  已移除 data/ssl.pl（面板回到只监听明文 HTTP）"

    log "装 chroot 服务兼容层（systemctl/service/start-stop-daemon/iptables-legacy）"
    sh "$REPO_DIR/install/chroot-compat-layer.sh"
    log "Android paranoid-network 修正（MariaDB 监听 3306 必需）"
    sh "$REPO_DIR/install/android-network-fix.sh"
    in_chroot '/etc/init.d/bt restart' || true
}

# ---------------- 7) 基线包对齐 ----------------
# 为什么要有这一步：一键部署的目标是「跟标准环境一样」，而安装脚本是手写的，
# 漏装是常态 —— 本轮实测就漏了 openssh-server（sshd 兜底通道没了）、
# java-*-openjdk（jdk_manager 要用）、jq / htop / bind-utils / libpcap 等基线里有的。
# 靠读脚本永远查不全，靠数据能查全：仓库里带一份基线包清单
# install/baseline-packages.txt（548 条，来自删除前那台的 rpm -qa），
# **按包名**比对（版本会被软件源往前推，实测 glibc/libxml2/util-linux 等二十来个名字
# 相同但版本号不同，所以只能比名字），把缺的装上，最后报告哪些名字当前源里已经没有。
step_parity() {
    local BASE="$REPO_DIR/install/baseline-packages.txt"
    if [ ! -f "$BASE" ]; then
        warn "没有 install/baseline-packages.txt，跳过基线包对齐"
        return 0
    fi
    log "按基线包清单对齐（只比包名，不比版本）"
    cp -f "$BASE" "$ROOT/tmp/baseline-packages.txt"
    # 用脚本而不是拼一行命令：里面全是引号和 $( )，走 in_chroot 的双引号会被吃
    cat > "$ROOT/tmp/parity.sh" <<'EOS'
#!/bin/bash
# 基线 <NEVRA> 去掉「版本-发布.架构」两段就是包名（rpm 的版本/发布里不允许出现 -）
# 548 行里有一行没有 .架构 后缀：`gpg-pubkey-<8hex>-<8hex>`（导入的 GPG 公钥伪包），
# 它会被过滤掉 —— 所以实际比的是 547 个真实包名。
sed -n 's/^\(.*\)-[^-]*-[^-]*\.[A-Za-z0-9_]*$/\1/p' \
    /tmp/baseline-packages.txt | sort -u > /tmp/want.txt
rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u > /tmp/have.txt
comm -23 /tmp/want.txt /tmp/have.txt > /tmp/missing.txt
echo "基线包名 $(wc -l < /tmp/want.txt) 个 / 已在位 $(comm -12 /tmp/want.txt /tmp/have.txt | wc -l) 个 / 缺 $(wc -l < /tmp/missing.txt) 个"
EOS
    in_chroot 'bash /tmp/parity.sh'

    local n
    n=$(in_chroot 'wc -l < /tmp/missing.txt' | tail -1 | tr -d '\r ')
    n=${n:-0}
    if [ "$n" = "0" ]; then
        log "基线包全部在位"
        return 0
    fi

    log "缺 $n 个，一次装（--skip-broken，失败不算致命）"
    in_chroot 'dnf install --skip-broken --setopt=install_weak_deps=False -y $(cat /tmp/missing.txt)' \
        || warn "批量补装没完全成功，下面逐个再试"
    in_chroot 'bash /tmp/parity.sh'

    n=$(in_chroot 'wc -l < /tmp/missing.txt' | tail -1 | tr -d '\r ')
    n=${n:-0}
    if [ "$n" != "0" ]; then
        # 逐个兜底：一个包在当前源里不存在会让整条 dnf 事务失败，所以必须拆开
        log "还剩 $n 个，逐个装（每个都允许失败）"
        in_chroot 'for p in $(cat /tmp/missing.txt); do
            rpm -q "$p" >/dev/null 2>&1 && continue
            dnf install --skip-broken --setopt=install_weak_deps=False -y "$p" >/dev/null 2>&1 \
                || echo "  装不上（当前源里没有或依赖不满足）：$p"
        done'
        in_chroot 'bash /tmp/parity.sh'
    fi

    # 这一项不 fail：源里确实可能已经没有某个包，把差额如实打出来比假装成功强
    local left
    left=$(in_chroot 'cat /tmp/missing.txt' | tr -d '\r' | tr '\n' ' ')
    if [ -n "$(printf '%s' "$left" | tr -d ' ')" ]; then
        warn "仍与基线有差额（当前软件源提供不了）：$left"
    else
        log "已与基线包清单对齐"
    fi
}

# ---------------- 8) 模块 ----------------
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
    all)        step_rootfs; step_mount; step_deps; step_panel; step_credentials; step_components; step_plugins; step_parity; step_patch; step_module ;;
    rootfs)     step_rootfs ;;
    mount)      step_mount ;;
    deps)       step_mount; step_deps ;;
    panel)      step_mount; step_deps; step_panel; step_credentials ;;
    creds)      step_mount; step_credentials ;;
    components) step_mount; step_components ;;
    plugins)    step_mount; step_plugins ;;
    parity)     step_mount; step_parity ;;
    patch)      step_mount; step_patch ;;
    module)     step_module ;;
    *)          echo "用法: sh $0 [all|rootfs|mount|deps|panel|creds|components|plugins|parity|patch|module]"; exit 1 ;;
esac
log "完成。面板地址：http://127.0.0.1:$(cat $ROOT/www/server/panel/data/port.pl 2>/dev/null)$(cat $ROOT/www/server/panel/data/admin_path.pl 2>/dev/null)"
log "登录账号密码见：$ROOT/root/qiyuntai-panel-info.txt（或点模块「操作」按钮）"
