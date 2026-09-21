#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 一键部署（自举）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 在手机 root shell 里跑，一条命令从零到能用：
#   su -c 'sh /data/local/tmp/qyt.sh'
#
# 它会：
#   1) 前置检查（root / aarch64 / 磁盘空间 / 工具 / SELinux）
#   2) 本地没有完整仓库就自己从 GitHub 拉 main 分支并解包
#   3) 铺 openEuler rootfs（已有面板环境会跳过）
#   4) 装面板 + 组件 + 插件 + 打补丁 + 装 KernelSU 模块
#   5) 打印登录信息并重启
#
# 参数：
#   --check          只做前置检查，不装任何东西
#   --repo-only      只把仓库拉到本地，不装
#   --no-reboot      装完不自动重启
#   --url <tar.xz>   rootfs 走指定 URL
#   --tar <file>     rootfs 用本地已解压好的 docker tar
#   --repo-tar <f>   仓库用本地已推过来的 tar.gz（不连 GitHub）
#
# 全程只写 /data/openeuler 与 /data/adb/modules，不动系统分区；
# 卸载模块只解挂载，不删数据。
# ============================================================
set -u

REPO_SLUG=moliapiyyds/qiyuntai-btpanel
REPO_BRANCH=main
TARBALL="https://github.com/$REPO_SLUG/archive/refs/heads/$REPO_BRANCH.tar.gz"
WORK=/data/local/tmp/qiyuntai
ROOT=/data/openeuler

DO_CHECK=0
DO_REPO_ONLY=0
DO_REBOOT=1
ROOTFS_URL=""
ROOTFS_TAR=""
REPO_TAR=""

say()  { echo "  $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [警告] $*"; }
die()  { echo "  [失败] $*" >&2; exit 1; }

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --check)     DO_CHECK=1; shift ;;
        --repo-only) DO_REPO_ONLY=1; shift ;;
        --no-reboot) DO_REBOOT=0; shift ;;
        --url)       ROOTFS_URL="$2"; shift 2 ;;
        --tar)       ROOTFS_TAR="$2"; shift 2 ;;
        --repo-tar)  REPO_TAR="$2"; shift 2 ;;
        -h|--help)   sed -n '2,28p' "$0"; exit 0 ;;
        *) die "未知参数：$1（-h 看用法）" ;;
    esac
done

echo "=========================================================="
echo " 栖云台 · 宝塔面板  一键部署"
echo " 作者：茉莉  QQ:1265274322  官方Q群:570387739"
echo "=========================================================="
echo

# ---------- 工具探测 ----------
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
    [ -x "$b" ] && BB="$b" && break
done

# 下载：记录「种类」而不是拼命令字符串（拼字符串再引号会当成一个文件名）
DL_KIND=""
if command -v curl >/dev/null 2>&1; then DL_KIND=curl
elif command -v wget >/dev/null 2>&1; then DL_KIND=wget
elif [ -n "$BB" ]; then DL_KIND=bbwget
fi

# 解 tar.gz
TAR_KIND=tar
[ -n "$BB" ] && TAR_KIND=bbtar

fetch() {   # fetch <url> <outfile>
    case "$DL_KIND" in
        curl)   curl -sSL --fail -o "$2" "$1" ;;
        wget)   wget -q -O "$2" "$1" ;;
        bbwget) "$BB" wget -q -O "$2" "$1" ;;
        *)      return 1 ;;
    esac
}

untargz() { # untargz <file> <destdir>
    case "$TAR_KIND" in
        tar)   tar -xzf "$1" -C "$2" ;;
        bbtar) "$BB" tar -xzf "$1" -C "$2" ;;
    esac
}

# ---------- 1) 前置检查 ----------
echo "---- 前置检查 ----"

[ "$(id -u)" = "0" ] || die "需要 root。用 su 执行：su -c 'sh $0'"
ok "root 身份"

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) ok "架构 $ARCH" ;;
    *) die "只支持 aarch64（当前 $ARCH）；32 位设备与 x86 平板不适用" ;;
esac

FREE_KB=$(df -k /data 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 6291456 ]; then
    die "/data 只剩 $((FREE_KB / 1024)) MB，不够（装完组件约 4-6 GB，建议 ≥ 10 GB）"
fi
ok "/data 可用 $((FREE_KB / 1024)) MB"

if [ -n "$BB" ]; then ok "busybox：$BB"; else warn "没有 busybox —— 下载/解压能力受限"; fi
case "$DL_KIND" in
    "")     warn "没有 curl / wget / busybox wget —— 只能走本地文件模式" ;;
    bbwget) ok "下载工具：busybox wget" ;;
    *)      ok "下载工具：$DL_KIND" ;;
esac
ok "解压工具：$([ "$TAR_KIND" = bbtar ] && echo busybox\ tar || echo tar)"

if mountpoint -q "$ROOT/proc" 2>/dev/null; then
    ok "chroot 已挂载（环境在跑）"
else
    ok "chroot 未挂载（首次部署）"
fi

if [ "$DO_CHECK" = "1" ]; then
    echo
    echo "---- 只做了检查，没装任何东西 ----"
    echo "正式部署：su -c 'sh $0'"
    exit 0
fi

# ---------- 2) 拿到仓库 ----------
echo
echo "---- 准备仓库 ----"
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
REPO=""

if [ -f "$SELF_DIR/../install/qiyuntai-install.sh" ] && [ -d "$SELF_DIR/../module" ]; then
    REPO=$(cd "$SELF_DIR/.." && pwd)
    ok "用本地仓库：$REPO"
else
    say "本地没有完整仓库，从 GitHub 拉 $REPO_BRANCH 分支"
    [ -n "$DL_KIND" ] || die "没有下载工具，无法自举。
      改用电脑侧一条命令（电脑能连 GitHub）：  .\\deploy.ps1"
    mkdir -p "$WORK" || die "建不了 $WORK"

    if [ -n "$REPO_TAR" ]; then
        # 用本地已经推过来的 tarball
        [ -f "$REPO_TAR" ] || die "找不到 $REPO_TAR"
        say "用本地 tarball：$REPO_TAR"
        cp -f "$REPO_TAR" "$WORK/repo.tar.gz" || die "复制 tarball 失败"
    else
        say "下载 $TARBALL"
        if ! fetch "$TARBALL" "$WORK/repo.tar.gz"; then
            echo
            warn "从 GitHub 下载失败。实测手机上的 busybox wget 连 github.com 会被重置："
            warn "  wget: got bad TLS record (len:0) while expecting switch to encrypted traffic"
            warn "  wget: error getting response: Connection reset by peer"
            echo
            echo "  改用电脑侧一条命令（电脑能连 GitHub，手机只负责装）："
            echo
            echo "      .\\deploy.ps1"
            echo
            echo "  或者手动推过来："
            echo
            echo "      git clone https://github.com/$REPO_SLUG.git"
            echo "      adb push qiyuntai-btpanel/install/. /sdcard/install/"
            echo "      adb push qiyuntai-btpanel/module/.  /sdcard/module/"
            echo "      adb shell \"su -c 'sh /sdcard/install/deploy.sh'\""
            echo
            echo "  也可以把仓库打包推上来后用 --repo-tar 指定："
            echo "      adb push main.tar.gz /sdcard/"
            echo "      sh $0 --repo-tar /sdcard/main.tar.gz"
            exit 1
        fi
    fi
    [ -s "$WORK/repo.tar.gz" ] || die "下下来是空文件"
    ok "已就绪 $(du -k "$WORK/repo.tar.gz" 2>/dev/null | cut -f1) KB"

    rm -rf "$WORK/src"
    mkdir -p "$WORK/src" || die "建不了 $WORK/src"
    untargz "$WORK/repo.tar.gz" "$WORK/src" || die "解包失败（tar 不支持 gz？在电脑上解好再推）"
    REPO=$(ls -d "$WORK/src"/*/ 2>/dev/null | head -1)
    [ -n "$REPO" ] || die "解包后没找到目录"
    REPO=${REPO%/}
    ok "解包到 $REPO"
fi

[ -f "$REPO/module/module.prop" ] || die "$REPO/module/module.prop 不存在，仓库不完整"
chmod 755 "$REPO"/install/*.sh "$REPO"/module/*.sh 2>/dev/null
ok "仓库就绪：$(grep -m1 '^version=' "$REPO/module/module.prop" | cut -d= -f2-)"

if [ "$DO_REPO_ONLY" = "1" ]; then
    echo
    echo "---- 只拉了仓库，没装 ----"
    echo "继续：su -c 'sh $REPO/install/deploy.sh'"
    exit 0
fi

# ---------- 3) 铺 rootfs ----------
echo
echo "---- 铺 openEuler rootfs ----"
if [ -d "$ROOT/www/server/panel" ]; then
    ok "检测到已有面板环境（$ROOT），跳过 rootfs"
elif [ -n "$ROOTFS_URL" ]; then
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" --url "$ROOTFS_URL" || die "rootfs 准备失败"
elif [ -n "$ROOTFS_TAR" ]; then
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" --tar "$ROOTFS_TAR" || die "rootfs 准备失败"
else
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" || die "rootfs 准备失败"
fi

# ---------- 4) 装面板 + 组件 + 插件 + 补丁 + 模块 ----------
echo
echo "---- 装面板 / 组件 / 插件 / 补丁 / 模块 ----"
say "这一步最慢（dnf + 源码编译 OpenResty/MariaDB/PHP），MariaDB 峰值约 2 GB 内存"
sh "$REPO/install/qiyuntai-install.sh" all || die "部署脚本失败（看上面日志）"

# ---------- 5) 收尾 ----------
echo
echo "---- 登录信息 ----"
INFO=$ROOT/root/qiyuntai-panel-info.txt
if [ -f "$INFO" ]; then
    cat "$INFO"
else
    warn "没生成 $INFO —— 重启后点模块「执行」按钮就能看到"
fi

echo
echo "=========================================================="
echo " 部署完成"
echo "=========================================================="
echo " 重启后会自动拉起全部服务。之后常用："
echo "   看地址账号密码： su -c '/data/adb/ksud module action qiyuntai_btpanel'"
echo "   出问题先诊断：   su -c 'sh /data/adb/modules/qiyuntai_btpanel/action.sh diag'"
echo "=========================================================="

if [ "$DO_REBOOT" = "1" ]; then
    echo
    say "3 秒后自动重启（不想重启加 --no-reboot）"
    sleep 3
    sync
    reboot
fi
