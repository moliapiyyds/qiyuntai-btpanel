#!/system/bin/sh
# ============================================================
# 栖云台 · openEuler rootfs 一键准备
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 把 openEuler 24.03 LTS-SP3 aarch64 的 docker 镜像铺成 chroot 根文件系统。
# 只做「铺 rootfs」这一件事；装面板请接着跑 install/qiyuntai-install.sh。
#
# 用法（设备上 root 执行）：
#   sh prepare-rootfs.sh --mirror                     # 自动从清华镜像挑文件并下载（一键部署走这条）
#   sh prepare-rootfs.sh --url <tar.xz 的 URL>        # 从网络下（手机需能上网）
#   sh prepare-rootfs.sh --xz  /sdcard/xxx.tar.xz     # 用已经下好的压缩包
#   sh prepare-rootfs.sh --tar /sdcard/xxx.tar        # 用已经解压好的 docker tar
#   sh prepare-rootfs.sh --root /data/oe_test --tar ... # 铺到别的目录（安全试跑用）
#   sh prepare-rootfs.sh --list                       # 只列出清华镜像上的可用文件
#   sh prepare-rootfs.sh --unmount                    # 只解挂载（删除前必做）
#   sh prepare-rootfs.sh --clean                      # 解挂载+确认干净+删除（安全的删法；
#                                                     #   挂载还在时 rm -rf 会毁掉手机 /dev）
#
# 默认目标目录：/data/openeuler
#
# 【安全护栏】目标目录里已经有 www/server/panel 时直接拒绝执行，
#   绝不覆盖已经装好的面板。要重铺请自己先改名或换 --root。
# ============================================================
set -u

ROOT=/data/openeuler
# 主源用官方（实测：默认 UA 也能下文件）。
# 清华镜像对**文件下载**挑 User-Agent —— busybox 默认 UA 和 Mozilla/5.0 都直接 403，
# 只有 Wget/1.21 能过（目录列表反而不挑）。踩过，所以放备用。
MIRROR_BASE="https://repo.openeuler.org/openEuler-24.03-LTS-SP3/docker_img/aarch64"
MIRROR_ALTS="https://mirrors.huaweicloud.com/openeuler/openEuler-24.03-LTS-SP3/docker_img/aarch64 https://mirrors.tuna.tsinghua.edu.cn/openeuler/openEuler-24.03-LTS-SP3/docker_img/aarch64"
SRC_URL=""
SRC_URL_ALT=""
SRC_XZ=""
SRC_TAR=""
DO_LIST=0
DO_UNMOUNT=0
DO_MIRROR=0
DO_CLEAN=0
LAYER_DIR=/data/oe_layer

die() { echo "x $*" >&2; exit 1; }
say() { echo "  $*"; }

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --url)  SRC_URL="$2"; shift 2 ;;
        --xz)   SRC_XZ="$2";  shift 2 ;;
        --tar)  SRC_TAR="$2"; shift 2 ;;
        --root) ROOT="$2";    shift 2 ;;
        --list) DO_LIST=1;    shift ;;
        --mirror) DO_MIRROR=1; shift ;;
        --unmount) DO_UNMOUNT=1; shift ;;
        --clean) DO_CLEAN=1;  shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "未知参数：$1（-h 看用法）" ;;
    esac
done

echo "==================== 栖云台 · rootfs 准备 ===================="

[ "$(id -u)" = "0" ] || die "需要 root（KernelSU/Magisk 的 su）"
say "目标目录：$ROOT"

# ---------- 工具探测 ----------
BUSYBOX=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
    [ -x "$b" ] && BUSYBOX="$b" && break
done
if [ -n "$BUSYBOX" ]; then
    TAR="$BUSYBOX tar"; XZ="$BUSYBOX xz"
    say "用 busybox：$BUSYBOX"
else
    TAR="tar"; XZ="xz"
    say "用系统自带 tar/xz（toybox）"
fi

DL=""
for c in curl wget; do command -v "$c" >/dev/null 2>&1 && DL="$c" && break; done
# 实测：Android 9 的 toybox 既没有 curl 也没有 wget；此时退回 busybox wget
if [ -z "$DL" ] && [ -n "$BUSYBOX" ] && $BUSYBOX wget --help >/dev/null 2>&1; then
    DL="busybox"
fi
[ -n "$DL" ] && say "下载工具：$DL" || say "没有 curl/wget/busybox wget（用 --xz/--tar 走本地文件即可）"

# 统一的取文件：fetch <url> <输出文件|->   （- 表示输出到 stdout）
fetch() {
    URL="$1"; OUT_="$2"
    case "$DL" in
        curl)
            if [ "$OUT_" = "-" ]; then curl -sSL --fail -A 'Mozilla/5.0' "$URL"
            else curl -sSL --fail -A 'Mozilla/5.0' -o "$OUT_" "$URL"; fi
            ;;
        wget)
            if [ "$OUT_" = "-" ]; then wget -q -O - -U 'Mozilla/5.0' "$URL"
            else wget -O "$OUT_" -U 'Mozilla/5.0' "$URL"; fi
            ;;
        busybox)
            # 必须带 UA：实测清华对文件下载挑 User-Agent，不带（或带 Mozilla/5.0）直接 403
            if [ "$OUT_" = "-" ]; then $BUSYBOX wget -q -U 'Wget/1.21' -O - "$URL"
            else $BUSYBOX wget -U 'Wget/1.21' -O "$OUT_" "$URL"; fi
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------- 解挂载（幂等）----------
# 脚本为验证 chroot 会往 $ROOT 里挂 proc/sys/dev/dev/pts/dev/shm，
# 退出前必须解掉：否则后续 rm -rf 会报 "Device or resource busy"（实测踩到过），
# 重跑也会因为挂载点已存在而行为异常。
unmount_all() {
    for m in sys proc dev/shm dev/pts dev; do
        if mountpoint -q "$ROOT/$m" 2>/dev/null; then
            umount -l "$ROOT/$m" 2>/dev/null || umount "$ROOT/$m" 2>/dev/null
            echo "  已解挂载 $ROOT/$m"
        fi
    done
}

if [ "$DO_UNMOUNT" = "1" ]; then
    echo ""
    echo "---- 解挂载 $ROOT ----"
    unmount_all
    echo "完成。"
    exit 0
fi

# ---------- --clean：解挂载 -> 确认干净 -> 删除（安全的删除方式） ----------
# 为什么还要专门给个开关：$ROOT/dev 是 `mount --bind /dev`，也就是宿主真实
# /dev 的绑定挂载。挂载还活着时 rm -rf，rm 会走进真实 /dev 把设备节点删掉，
# /dev/null 变成普通文件 -> zygote 打不开 -> 手机黑屏。
# 实测踩过两次（2026-09-21，第二次是对另一个 chroot 目录做 rm -rf）。
if [ "$DO_CLEAN" = "1" ]; then
    echo ""
    echo "---- 清理 $ROOT ----"
    # 防呆（这一段会 rm -rf，值得多写几行）：--root 必须是「足够具体的目录」，
    # 且不能是几个一删就要命的地方。别指望自己永远不手抖。
    case "$ROOT" in
        ''|/|/data|/data/adb|/data/local|/sdcard|/system|/storage|*..*)
            die "拒绝执行：--root 给的路径不安全（[$ROOT]）—— 这一段会 rm -rf 它" ;;
    esac
    if [ "$(printf '%s' "$ROOT" | tr -cd '/' | wc -c)" -lt 2 ]; then
        die "拒绝执行：--root 至少要具体到 /data/<名字> 这一层（当前 [$ROOT]）"
    fi
    unmount_all
    LEFT=$(mount | grep -c "$ROOT/")
    if [ "$LEFT" != "0" ]; then
        echo "x 拒绝删除：$ROOT 下面还有 $LEFT 个挂载"
        mount | grep "$ROOT/"
        echo "  先手动解挂载，或再跑一次 --clean。"
        exit 1
    fi
    say "挂载已确认干净，开始删除"
    rm -rf "$ROOT"
    if [ -d "$ROOT" ]; then
        echo "x 删除不完整，仍残留：$(ls "$ROOT" 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
    echo "完成。"
    exit 0
fi

# 上次跑挂过就先解掉，保证可重入
unmount_all >/dev/null 2>&1

# ---------- 只列清单 ----------
if [ "$DO_LIST" = "1" ]; then
    echo ""
    echo "清华镜像目录：$MIRROR_BASE/"
    if [ -z "$DL" ]; then
        die "没有 curl/wget/busybox wget，无法在线列出。请用浏览器打开上面的地址自行挑文件。"
    fi
    fetch "$MIRROR_BASE/" - 2>/dev/null | grep -oE '[A-Za-z0-9._-]+\.tar\.xz' | sort -u
    echo ""
    echo "用法：sh $0 --url $MIRROR_BASE/<上面挑的文件名>"
    echo "提示：本机实测 Android 9 的 toybox 没有 curl/wget，走的是 busybox wget；"
    echo "      如果 busybox 的 wget 没编 TLS，https 会失败 —— 那就改在电脑上下好再推过来。"
    exit 0
fi

# ---------- 只给了 --mirror：自己到镜像目录里挑出 rootfs 文件 ----------
# 为什么需要这一段：本脚本自己不知道调用方想装哪个文件，而调用方
# （install/qiyuntai-install.sh 的 step_rootfs）以前只传了 --root，
# 于是这里会以「没给源。用 --url / --xz / --tar 之一」退出 ——
# 一键部署必然卡死在 rootfs 这一步（2026-09-21 实测复现）。
# 现在调用方传 --mirror，这里用上面已经探好的 $DL 去列目录挑文件。
if [ "$DO_MIRROR" = "1" ] && [ -z "$SRC_URL" ] && [ -z "$SRC_XZ" ] && [ -z "$SRC_TAR" ]; then
    echo ""
    echo "---- 从镜像目录挑 rootfs ----"
    if [ -z "$DL" ]; then
        die "没有 curl/wget/busybox wget，无法列目录。请改用 --url/--xz/--tar 显式给源。"
    fi
    say "镜像：$MIRROR_BASE/"
    ALL=$(fetch "$MIRROR_BASE/" - 2>/dev/null | grep -oE '[A-Za-z0-9._-]+\.tar\.xz' | sort -u)
    IDX=$(printf '%s\n' "$ALL" | grep -x 'openEuler-docker\.aarch64\.tar\.xz' | head -1)
    [ -n "$IDX" ] || IDX=$(printf '%s\n' "$ALL" | grep -E '^openEuler' | head -1)
    if [ -n "$IDX" ]; then
        say "选中：$IDX"
    else
        # 拿不到目录列表时退回已知文件名（清华镜像 openEuler-24.03-LTS-SP3 实测就是这个）
        IDX="openEuler-docker.aarch64.tar.xz"
        say "取不到目录列表，退回已知文件名：$IDX"
    fi
    SRC_URL="$MIRROR_BASE/$IDX"
    SRC_URL_ALT=""
    for M in ${MIRROR_ALTS:-}; do
        SRC_URL_ALT="$SRC_URL_ALT $M/$IDX"
    done
    say "主源：$SRC_URL"
    say "备用：${SRC_URL_ALT:-（无）}"
fi

# ---------- 安全护栏 ----------
if [ -d "$ROOT/www/server/panel" ]; then
    echo ""
    echo "x 拒绝执行：$ROOT/www/server/panel 已存在，这里已经有装好的面板。"
    echo "  本脚本不覆盖已有环境。要铺到别处： --root /data/oe_test"
    echo "  确实要重铺：先 mv $ROOT ${ROOT}.old_$(date +%Y%m%d_%H%M) 再重跑"
    exit 1
fi

# ---------- 取到 tar ----------
WORK=/data/oe_download
mkdir -p "$WORK" || die "建不了 $WORK"

if [ -n "$SRC_URL" ]; then
    FN=$(basename "$SRC_URL")
    OUT="$WORK/$FN"
    echo ""
    echo "---- 下载 $FN ----"
    [ -n "$DL" ] || die "URL 模式需要 curl 或 wget"
    if [ -f "$OUT" ] && [ -s "$OUT" ]; then
        say "已存在，跳过下载：$OUT ($(du -h "$OUT" 2>/dev/null | cut -f1))"
    else
        # 依次试主源和备用源。不能只看 fetch 的返回码：被拒绝时有些服务器
        # 会返回一个很小的错误页而 rc=0，所以下完还要看大小（<1MB 一律视为失败）。
        # 实测：清华对文件下载挑 UA，官方源和华为云不挑。
        OK=0
        for U in "$SRC_URL" ${SRC_URL_ALT:-}; do
            say "试源：$U"
            if fetch "$U" "$OUT" && [ -s "$OUT" ]; then
                SZ=$(wc -c < "$OUT" 2>/dev/null || echo 0)
                if [ "$SZ" -gt 1048576 ]; then
                    say "下载成功：$((SZ / 1024 / 1024)) MB"
                    OK=1
                    break
                fi
                say "只拿到 $SZ 字节（疑似被拒），换下一个源"
            else
                say "这个源没成功，换下一个源"
            fi
            rm -f "$OUT"
        done
        [ "$OK" = "1" ] || die "所有源都下不下来。可在电脑上下好再 --xz/--tar 推过来"
    fi
    case "$FN" in
        *.tar.xz) SRC_XZ="$OUT" ;;
        *.tar)    SRC_TAR="$OUT" ;;
        *)        SRC_XZ="$OUT" ;;
    esac
fi

if [ -n "$SRC_XZ" ]; then
    [ -f "$SRC_XZ" ] || die "找不到 $SRC_XZ"
    echo ""
    echo "---- 解压 xz ----"
    say "源：$SRC_XZ ($(du -h "$SRC_XZ" 2>/dev/null | cut -f1))"
    OUTTAR="${SRC_XZ%.xz}"
    if [ -f "$OUTTAR" ]; then
        say "已存在解压结果，跳过：$OUTTAR"
    else
        if $XZ -d -k "$SRC_XZ" 2>/dev/null && [ -f "$OUTTAR" ]; then
            say "xz 解压完成 → $OUTTAR"
        elif $TAR -xJf "$SRC_XZ" -C "$WORK" 2>/dev/null; then
            say "用 tar -J 一步解出（走的是 tar 的 xz 支持）"
        else
            echo "x xz 解压失败。"
            echo "  这台设备的 tar/xz 可能不支持 xz。请在电脑上先解好再推进来："
            echo "    xz -d openEuler-docker.aarch64.tar.xz"
            echo "    adb push openEuler-docker.aarch64.tar /sdcard/"
            echo "    adb shell su -c \"sh $0 --tar /sdcard/openEuler-docker.aarch64.tar\""
            exit 1
        fi
    fi
    [ -f "$OUTTAR" ] && SRC_TAR="$OUTTAR"
fi

[ -n "$SRC_TAR" ] || die "没给源。用 --url / --xz / --tar 之一（-h 看用法）"
[ -f "$SRC_TAR" ] || die "找不到 $SRC_TAR"

# ---------- 空间检查 ----------
echo ""
echo "---- 空间检查 ----"
# 必须用 df -P：本机 df -k /data 会因设备名过长折成三行，NR==2 取到空值，
# 后面 [ "" -lt N ] 会报 integer expression expected 并让检查失效（实测踩过）。
AVAIL_KB=$(df -P -k /data 2>/dev/null | awk 'NR==2{print $4}')
case "$AVAIL_KB" in
    ''|*[!0-9]*) die "取不到 /data 可用空间（df -P -k /data 输出异常：[$AVAIL_KB]）" ;;
esac
TAR_KB=$(( $(wc -c < "$SRC_TAR" 2>/dev/null || echo 0) / 1024 ))
say "docker tar：$((TAR_KB / 1024)) MB     /data 可用：$((AVAIL_KB / 1024)) MB"
# 解压后约为 tar 的 2.5 倍（layer + 合并后的 rootfs）。
# 注意这里只管 rootfs 那一步：全部装完后 /data/openeuler 实测约 17.7 GB，
# 整体门槛由 install/deploy.sh 的前置检查按 20 GB 把关。
NEED_KB=$(( TAR_KB * 25 / 10 ))
if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    die "空间可能不够：这一步预计需要 $((NEED_KB / 1024)) MB，/data 只剩 $((AVAIL_KB / 1024)) MB。
     提醒：全部装完后 /data/openeuler 实测约 17.7 GB，整体建议留足 20 GB。"
fi
say "空间够用"

# ---------- 解开 docker 层 ----------
echo ""
echo "---- 解开 docker 层 ----"
rm -rf "$LAYER_DIR"; mkdir -p "$LAYER_DIR" || die "建不了 $LAYER_DIR"
$TAR -xf "$SRC_TAR" -C "$LAYER_DIR" || die "解 docker tar 失败"
say "已解开到 $LAYER_DIR"

if [ ! -f "$LAYER_DIR/manifest.json" ]; then
    echo "！没看到 manifest.json，可能不是 docker 镜像 tar。"
    echo "  目录内容："
    ls "$LAYER_DIR" | head -n 20 | sed 's/^/    /'
    die "无法确定层结构，已停在这里（原始文件都还在，没有动 $ROOT）"
fi

# manifest.json 里 Layers 是 ["<sha>/layer.tar", ...]，**顺序不能乱**：
# 后面的层覆盖前面的层。所以这里按出现顺序取，不能用 sort -u。
FLAT=$(tr -d '\n\r ' < "$LAYER_DIR/manifest.json")
LAYERS=$(echo "$FLAT" | sed 's/.*"Layers":\[//; s/\].*//' | tr ',' '\n' | tr -d '"' | grep 'layer\.tar$')
if [ -z "$LAYERS" ]; then
    echo "！manifest.json 里没解析出 Layers，退化为按目录名扫描（顺序不保证）"
    LAYERS=$(cd "$LAYER_DIR" && ls -d */layer.tar 2>/dev/null | sort)
fi
[ -n "$LAYERS" ] || die "没找到 layer.tar"

# 写成文件再读：管道里的 while 是子 shell，里面 exit 退不出整个脚本
LAYER_LIST=/data/oe_layers.txt
echo "$LAYERS" > "$LAYER_LIST"
N=$(wc -l < "$LAYER_LIST")
say "共 $N 个层，按顺序叠加到 $ROOT"

mkdir -p "$ROOT" || die "建不了 $ROOT"
I=0
while read -r L; do
    [ -z "$L" ] && continue
    I=$((I + 1))
    echo "  [$I/$N] $L"
    $TAR -xf "$LAYER_DIR/$L" -C "$ROOT" || die "叠加层失败：$L"
done < "$LAYER_LIST"
rm -f "$LAYER_LIST"

# ---------- 基础收尾 ----------
echo ""
echo "---- 基础收尾 ----"
mkdir -p "$ROOT/etc" "$ROOT/dev" "$ROOT/dev/pts" "$ROOT/dev/shm" "$ROOT/proc" "$ROOT/sys" "$ROOT/root" 2>/dev/null
cat > "$ROOT/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF
say "已写 DNS：/etc/resolv.conf"

if ! grep -q '^inet:x:3003:' "$ROOT/etc/group" 2>/dev/null; then
    echo 'inet:x:3003:' >> "$ROOT/etc/group"
    say "已补 inet 组（Android paranoid-network 要求，缺了 mysqld/redis 会 bind 失败）"
# 补 /etc/hostname：docker 基础镜像里没有这个文件，宝塔安装器一上来就
#   cat: /etc/hostname: No such file or directory
# 虽然无害，但会让日志第一行就是红字，也干扰排查。
if [ ! -s "$ROOT/etc/hostname" ]; then
    echo "openeuler" > "$ROOT/etc/hostname" 2>/dev/null && say "已补 /etc/hostname"
fi
fi

# ---------- 验证 ----------
echo ""
echo "---- 验证 chroot ----"
mountpoint -q "$ROOT/proc"    || mount -t proc  -o nosuid,nodev,noexec proc  "$ROOT/proc" 2>/dev/null
mountpoint -q "$ROOT/sys"     || mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOT/sys" 2>/dev/null
mountpoint -q "$ROOT/dev"     || mount --bind /dev "$ROOT/dev" 2>/dev/null
mountpoint -q "$ROOT/dev/pts" || mount -t devpts -o gid=5,mode=0620 devpts "$ROOT/dev/pts" 2>/dev/null
mountpoint -q "$ROOT/dev/shm" || mount -t tmpfs -o nosuid,nodev tmpfs "$ROOT/dev/shm" 2>/dev/null

# 这里必须只用 bash 内建命令：宿主 shell 的 PATH 是 /system/bin:...，
# 在 chroot 里根本不存在，用 head/cat 会 "command not found"，
# 输出为空就被误判成「chroot 进不去」（实测踩过，白排查一轮）。
OSOUT=$(chroot "$ROOT" /bin/bash -c 'IFS= read -r l < /etc/os-release; printf "%s" "$l"' 2>&1)
case "$OSOUT" in
    ""|*"command not found"*|*"No such file"*)
        echo "！chroot 进不去。检查："
        echo "    ls $ROOT/bin/bash   （rootfs 是否完整）"
        echo "    上面 5 个挂载点是否都挂上"
        echo "    dmesg | tail        （看 SELinux 是否拦截）"
        [ -n "$OSOUT" ] && echo "    实际报错：$OSOUT"
        ;;
    *)
        say "chroot 可用：$OSOUT"
        ;;
esac

rm -rf "$LAYER_DIR"
say "临时层目录已清理（下载文件留在 $WORK，重跑可复用）"

echo ""
echo "==================== rootfs 就绪 ===================="
echo "注意：/proc /sys /dev /dev/pts /dev/shm 已经挂在 $ROOT 下并**故意留着**，"
echo "      下一步安装脚本要 chroot 进去用。如果你要删掉这个 rootfs，先解挂载："
echo "        sh $0 --root $ROOT --unmount"
echo "      （不然 rm -rf 会报 \"Device or resource busy\"；重跑本脚本会自动先解挂载）"
echo ""
echo "下一步（在电脑上执行）："
echo "  1) adb push install/qiyuntai-install.sh /sdcard/"
echo "  2) adb shell su -c \"sh /sdcard/qiyuntai-install.sh\"     # chroot 内装面板 + 组件 + 打补丁"
echo "  3) 刷 KernelSU 模块 qiyuntai_btpanel，重启"
echo "  4) 重启后点模块的「执行」按钮拿地址账号密码"
echo "=========================================================="
