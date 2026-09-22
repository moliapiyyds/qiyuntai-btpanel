#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 一键部署（自举）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 在手机 root shell 里跑，一条命令从零到能用：
#   su -c 'sh /data/local/tmp/qyt-repo/install/deploy.sh'   # deploy.ps1 默认推的位置
#   （放 /sdcard/install/deploy.sh 也行，但 /sdcard 是 CE 存储 ——
#     手机重启后没解锁一次就 "No such file or directory"，见 README）
#
# 默认走**预制镜像**（唯一交付路径，理由见下），它会：
#   1) 前置检查（root / aarch64 / 磁盘空间 / 工具 / SELinux）
#   2) 仓库：优先用本地已有的（$REPO 就是本文件所在目录的上一级），
#      本地没有才尝试从 GitHub 拉。**这条要注意口径会变**：
#        2026-09-21 实测手机上的 busybox wget 连 github.com 会被重置
#          （wget: got bad TLS record (len:0) ... Connection reset by peer），拉不动；
#        2026-09-22 复测同一台设备同一个 busybox：github.com / codeload /
#          raw.githubusercontent / api 都通了，Release 附件也下得动。
#      拉不动时会打印实测过的排错提示（见 fetch 失败那个分支）。
#   3) 找镜像分卷：先看 --from-image 给的目录，再看几个默认位置；
#      都没有就跑 install/fetch-image.sh 下载（断点续传 + 逐卷 sha256 + 重试）。
#      目标 /data/openeuler **非空就拒绝解包**（带着挂载 rm -rf 会删掉宿主真 /dev，
#      实测黑屏过两次），要先用 prepare-rootfs.sh --clean 清掉旧环境。
#   4) 解包 → 重新随机化端口/入口/密码/sshd 主机密钥 → plugins/parity/patch/module
#   5) 打印登录信息并重启
#
# 为什么默认是镜像、而不是从宝塔官方装（2026-09-22 定）：
#   官方安装器那条路的问题不是「补丁会坏」，而是**面板版本不在我们手里**：
#   它每次拉 bt 的当前版 —— 实测 2026-09-21 装到 13.0.0，2026-09-22 当天
#   就变成 13.1.0。我们的补丁是版本门禁的（tools/moli_patch.py 的
#   PANEL_VERIFIED），所以走官方源的一键部署会在 patch 步骤**明确失败**，
#   得人工核验一遍才能放行（实测 13.1.0 上锚点漂移 0/8：不是打不上，
#   是没核验过就不自动打）。镜像把面板版本冻住，交付物才可复现 ——
#   所以它承担全部交付职责，官方源那条退到 --from-source，只给作者重建环境用。
#
# 参数：
#   --check          只做前置检查，不装任何东西
#   --repo-only      只把仓库拉到本地，不装
#   --no-reboot      装完不自动重启
#   --repo-tar <f>   仓库用本地已推过来的 tar.gz（不连 GitHub）
#   --from-image <dir>  指定镜像分卷目录（里面放 qyt-image.part-*）；
#                       不给就自动找默认位置，找不到会自己下
#   --image-url <url>   镜像下载基址（自建镜像站/网盘直链都行；默认 GitHub Release）
#   --image-sha <sha>   额外指定镜像整包的 sha256（不给就用目录里的 SHA256SUMS.txt）
#   --no-fetch          分卷不在本地时**不要**自动下载，直接报错退出
#   --from-source       【作者重建环境用，别给用户跑】从 openEuler 源铺 rootfs +
#                       用宝塔官方安装器装面板 —— 面板版本随宝塔浮动，
#                       补丁可能因此拒绝执行（见上）
#   --url <tar.xz>      --from-source 下 rootfs 走指定 URL
#   --tar <file>        --from-source 下 rootfs 用本地已解压好的 docker tar
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
IMAGE_SRC=""
IMAGE_SHA=""
IMAGE_URL=""
DO_FETCH=1
DO_FROM_SOURCE=0

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
        --from-image) IMAGE_SRC="$2"; shift 2 ;;
        --image-url)  IMAGE_URL="$2"; shift 2 ;;
        --image-sha)  IMAGE_SHA="$2"; shift 2 ;;
        --no-fetch)   DO_FETCH=0; shift ;;
        --from-source) DO_FROM_SOURCE=1; shift ;;
        -h|--help)   sed -n '2,54p' "$0"; exit 0 ;;
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

# 必须用 df -P：实测本机 df -k /data 的输出会因为设备名过长折成三行
#   Filesystem / 1K-blocks Used Available Use% Mounted on
#   /dev/block/by-name/userdata              <- 第2行只有设备名
#                        117766144 ... /data  <- 第3行才是数值
# 于是 awk 'NR==2{print $4}' 拿到空值，[ -n "$FREE_KB" ] 为假，
# 整个磁盘检查被静默跳过（实测踩过）。拿不到数值就失败，不再「跳过检查」。
FREE_KB=$(df -P -k /data 2>/dev/null | awk 'NR==2{print $4}')
case "$FREE_KB" in
    ''|*[!0-9]*) die "取不到 /data 可用空间（df -P -k /data 输出异常：[$FREE_KB]），不敢继续" ;;
esac
# 实测装完占 /data/openeuler 约 17.7 GB，其中 MariaDB 编译构建树
# www/server/mysql/src 就占 8.8 GB。门槛按 20 GB 设（原来写 6 GB，差 3 倍）。
NEED_KB=20971520
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    die "/data 只剩 $((FREE_KB / 1024)) MB，不够：实测装完约 17.7 GB，建议先清到 ≥ $((NEED_KB / 1024)) MB 再跑。"
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
            warn "从 GitHub 下载失败。2026-09-21 实测过这个失败长什么样（当时手机上连 github.com 被重置）："
            warn "  wget: got bad TLS record (len:0) while expecting switch to encrypted traffic"
            warn "  wget: error getting response: Connection reset by peer"
            warn "但 2026-09-22 复测同一台设备是通的（github.com / codeload / api 都能下），"
            warn "所以现在失败更可能是：手机没网 / DNS 问题（看 /etc/resolv.conf）/ 走了代理。"
            echo
            echo "  也可以换成 codeload 直链（少一次跳转）："
            echo "      $BB wget -O /data/local/tmp/q.repo.tgz https://codeload.github.com/$REPO_SLUG/tar.gz/refs/heads/main"
            echo "      sh $0 --repo-tar /data/local/tmp/q.repo.tgz"
            echo
            echo "  或者在电脑侧一条命令（电脑拉好再推，最省事）："
            echo
            echo "      .\\deploy.ps1        （Windows）"
            echo "      ./deploy-linux.sh    （Linux / macOS）"
            echo
            echo "  或者手动推过来（推 /data/local/tmp —— /sdcard 是 CE 存储，"
            echo "  手机重启后没解锁一次就不可用）："
            echo
            echo "      git clone https://github.com/$REPO_SLUG.git"
            echo "      D=/data/local/tmp/qyt-repo; adb shell \"mkdir -p \$D\""
            echo "      adb push qiyuntai-btpanel/install/. \$D/install/"
            echo "      adb push qiyuntai-btpanel/module/.  \$D/module/"
            echo "      adb push qiyuntai-btpanel/tools/.   \$D/tools/"
            echo "      adb shell \"su -c 'sh \$D/install/deploy.sh'\""
            echo
            echo "  也可以把仓库打包推上来后用 --repo-tar 指定："
            echo "      adb push main.tar.gz /data/local/tmp/"
            echo "      sh $0 --repo-tar /data/local/tmp/main.tar.gz"
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

# ---------- 3) 铺环境：预制镜像（默认） 或 从源铺 rootfs（--from-source） ----------
if [ "$DO_FROM_SOURCE" = "0" ]; then
    echo
    echo "---- 用预制镜像铺环境（默认路径）----"

    # ① 定目录：--from-image 优先，否则按默认位置找现成的
    if [ -n "$IMAGE_SRC" ]; then
        [ -d "$IMAGE_SRC" ] || die "--from-image 要给一个目录（里面放 qyt-image.part-*），当前是：$IMAGE_SRC"
    else
        for d in /data/local/tmp/qyt-image /data/qyt_image /sdcard/qyt-image /storage/emulated/0/qyt-image; do
            if [ -n "$(ls "$d"/qyt-image.part-* 2>/dev/null)" ]; then
                IMAGE_SRC="$d"
                ok "自动找到镜像分卷：$IMAGE_SRC"
                break
            fi
        done
    fi

    # ② 没有就自己下（除非 --no-fetch）
    if [ -z "$IMAGE_SRC" ]; then
        if [ "$DO_FETCH" = "0" ]; then
            die "本地没有镜像分卷，且给了 --no-fetch。
      分卷要放在这些位置之一（或给 --from-image <目录>）：
        /data/local/tmp/qyt-image  /data/qyt_image  /sdcard/qyt-image
      电脑侧一条命令会自动下好并推进来：  .\\deploy.ps1   /   ./deploy-linux.sh"
        fi
        say "本地没有镜像分卷，开始下载（断点续传，可重复跑）"
        FETCH_ARGS=""
        [ -n "$IMAGE_URL" ] && FETCH_ARGS="-u $IMAGE_URL"
        # shellcheck disable=SC2086
        sh "$REPO/install/fetch-image.sh" -d /data/local/tmp/qyt-image $FETCH_ARGS \
            || die "取镜像失败（看上面日志）"
        IMAGE_SRC=/data/local/tmp/qyt-image
    fi

    NPART=$(ls "$IMAGE_SRC"/qyt-image.part-* 2>/dev/null | wc -l)
    [ "$NPART" -gt 0 ] || die "$IMAGE_SRC 里找不到 qyt-image.part-*"
    ok "找到 $NPART 个分卷"

    # 目标必须干净：带着挂载 rm -rf 会把宿主真实 /dev 删掉（黑屏，实测踩过两次）
    if [ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
        echo "  $ROOT 非空，说明这台设备已经有环境了。"
        echo "  镜像路线要先清干净（清之前自己确认数据都备份过了）："
        echo "      su -c 'sh $REPO/install/prepare-rootfs.sh --clean'"
        echo "      su -c 'sh $0 --from-image $IMAGE_SRC'"
        die "拒绝在非空目录上解包镜像"
    fi

    ARCH=/data/qyt-image.tar.xz
    say "拼接分卷 -> $ARCH"
    cat "$IMAGE_SRC"/qyt-image.part-* > "$ARCH" || die "拼接失败"
    ASZ=$(wc -c < "$ARCH" 2>/dev/null | tr -d ' ')
    [ -n "$ASZ" ] || ASZ=0
    # 别用 $((ASZ / 1048576)) 算这个显示值：shell 的 $(( )) 是 32 位有符号，
    # 2.2 GB（2227295452 > 2^31）会溢出成负数，屏幕上会打出「镜像大小：-1971 MB」
    # （实测踩到）。校验本身是字符串比较，不受影响；只是这个数字会吓人。
    ASZ_MB=$(awk -v b="$ASZ" 'BEGIN{printf "%.0f", b/1048576}')
    say "镜像大小：$ASZ_MB MB（$ASZ 字节）"

    # 校验顺序：--image-sha > 镜像目录里的 SHA256SUMS.txt > install/image.lock
    # （image.lock 是本仓库自带的锁表，分卷和整包哈希都记在里面，
    #   这样即使清单文件没下下来，也有可比对的权威值）
    WANT="$IMAGE_SHA"
    if [ -z "$WANT" ] && [ -f "$IMAGE_SRC/SHA256SUMS.txt" ]; then
        WANT=$(sed -n '1s/^sha256  \([0-9a-f]\{64\}\) .*/\1/p' "$IMAGE_SRC/SHA256SUMS.txt")
    fi
    if [ -z "$WANT" ] && [ -f "$REPO/install/image.lock" ]; then
        WANT=$(awk '$1=="whole"{s=$5} END{print s}' "$REPO/install/image.lock")
    fi
    if [ -n "$WANT" ]; then
        say "校验整包 sha256（约 2.2 GB / 半分钟，这步别跳过：解包会清掉旧环境）"
        GOT=$($BB sha256sum "$ARCH" | cut -d' ' -f1)
        [ "$WANT" = "$GOT" ] || die "镜像 sha256 不匹配（期望 $WANT，实得 $GOT）—— 拒绝解包"
        ok "sha256 校验通过"
    else
        warn "没有可用的 sha256（既无 SHA256SUMS.txt、也无 install/image.lock、也没给 --image-sha）"
        warn "跳过校验了 —— 这种情况不该出现，检查一下仓库是否完整"
    fi

    # 实测（HUAWEI PAR-AL00 / 麒麟 970）：busybox xz 是单线程，2.2 GB 压缩包
    # 解出 7983 MB 要 **约 15 分钟**。以前这里写「约 1-3 分钟」，是估的，不准。
    say "解包到 /data —— 约 15 分钟（busybox xz 单线程；别以为卡死了）"
    $BB xz -dc "$ARCH" | $BB tar -x -C /data || die "解包失败"
    [ -x "$ROOT/www/server/panel/BT-Panel" ] || die "解包完了但没找到 $ROOT/www/server/panel/BT-Panel"
    # 拼接出来的整包用完就删：它有几 GB，留着白占 /data（而且下次会重新拼）
    rm -f "$ARCH" && say "已删除拼接出来的 $ARCH"
    # 留个标记：凭据那一步要据此重新随机化端口/入口/用户名
    touch "$ROOT/.from-image"
    ok "镜像已解包"
    # 清单优先看镜像目录（make_image.sh 现在把它写在镜像外面）；
    # 老镜像是写在里面的（$ROOT/IMAGE-MANIFEST.txt），所以两条都试
    if [ -f "$IMAGE_SRC/IMAGE-MANIFEST.txt" ]; then
        echo "  --- 镜像清单 ---"; sed 's/^/    /' "$IMAGE_SRC/IMAGE-MANIFEST.txt"
    elif [ -f "$ROOT/IMAGE-MANIFEST.txt" ]; then
        echo "  --- 镜像清单（旧格式，在镜像里）---"; sed 's/^/    /' "$ROOT/IMAGE-MANIFEST.txt"
    fi
else
echo
echo "---- 从 openEuler 源铺 rootfs（--from-source：作者重建环境用）----"
warn "这条路会用**宝塔官方安装器**装面板，面板版本随宝塔浮动。"
warn "补丁是版本门禁的（tools/moli_patch.py 的 PANEL_VERIFIED），"
warn "装到没核验过的版本会在 patch 步骤失败，得人工核验后加 --force。"
warn "用户装机请走预制镜像（即不带 --from-source）。"
# 注意：prepare-rootfs.sh 自己不知道要装哪个文件，**必须给它源**，
# 否则它会以「没给源。用 --url / --xz / --tar 之一」退出，一键部署就卡在这。
# 默认那条以前只传了 --root（2026-09-21 实测复现），现在改传 --mirror，
# 由它自己用探好的下载器去镜像目录挑文件（且带多源回退，见 prepare-rootfs.sh）。
if [ -d "$ROOT/www/server/panel" ]; then
    ok "检测到已有面板环境（$ROOT），跳过 rootfs"
elif [ -n "$ROOTFS_URL" ]; then
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" --url "$ROOTFS_URL" || die "rootfs 准备失败"
elif [ -n "$ROOTFS_TAR" ]; then
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" --tar "$ROOTFS_TAR" || die "rootfs 准备失败"
else
    sh "$REPO/install/prepare-rootfs.sh" --root "$ROOT" --mirror || die "rootfs 准备失败"
fi
fi

# ---------- 4) 装面板 + 组件 + 插件 + 补丁 + 模块 ----------
echo
if [ "$DO_FROM_SOURCE" = "0" ]; then
    echo "---- 镜像已就位：重新随机化身份 + 对齐包清单 + 打补丁 + 装模块 ----"
    say "面板与组件已经在镜像里编译好了，跳过 dnf 和源码编译"
    # 注意顺序：先 creds（会重新随机化端口/入口/用户名与 sshd 主机密钥），
    # 再 plugins（9 个插件都在镜像里，会逐个跳过；顺带确认 memcached 二进制在）
    # → parity（按基线包清单核对一遍，镜像里是全的，正常情况下什么都不装）
    # → patch、module。补丁最后打，是因为镜像里存的是**未打补丁的原版**
    #   （见 tools/make_image.sh 的说明）。
    for st in creds plugins parity patch module; do
        say "== 步骤：$st =="
        sh "$REPO/install/qiyuntai-install.sh" "$st" || die "$st 步骤失败（看上面日志）"
    done
else
    echo "---- 装面板 / 组件 / 插件 / 补丁 / 模块 ----"
    say "这一步最慢（dnf + 源码编译 OpenResty/MariaDB/PHP），MariaDB 峰值约 2 GB 内存"
    sh "$REPO/install/qiyuntai-install.sh" all || die "部署脚本失败（看上面日志）"
fi

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
