#!/usr/bin/env bash
# ============================================================
# 栖云台 · 宝塔面板 —— Linux / macOS 侧一键部署（PC 侧）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 在 Linux / macOS 上跑（需要 adb；手机已 root、已装 KernelSU/Magisk）：
#
#   ./deploy-linux.sh
#
# 它做的事和 Windows 侧的 deploy.ps1 完全一样（这两个脚本是等价的，改一个记得改另一个）：
#   1) 找 adb、等设备、确认手机上能拿到 root
#   2) 把 install/ module/ tools/ 推到手机同一层目录
#      默认推到 /data/local/tmp/qyt-repo —— **不是 /sdcard**：
#      /sdcard 是 CE 存储，手机重启后没解锁一次就 "No such file or directory"
#      （vold 不建 /mnt/user/0/primary），而一键部署的最后一步就是重启手机。
#      /data/local/tmp 是 DE 存储：锁屏能写、重启也在。
#   3) 预制镜像分卷：电脑上下（约 2.2 GB，下完 adb push 到 /data/local/tmp/qyt-image）。
#      手机上已经有且校验通过就跳过。**这是交付的唯一路径** ——
#      不走宝塔官方安装器了，理由见 README「为什么不走宝塔官方源」。
#   4) 在手机上跑 install/deploy.sh --from-image —— 解包 → 重新随机化端口/入口/密码/
#      sshd 主机密钥 → 插件 → 基线包对齐 → 打补丁 → 装模块 → 重启。约 10 分钟。
#      （目标 /data/openeuler 非空会拒绝解包：先 su -c 'sh install/prepare-rootfs.sh --clean'）
#   5) 收尾提示
#
# 参数：
#   -c, --check        只体检（设备 / root / 架构 / 磁盘），不推不装
#   -p, --push-only    只推文件（仓库 + 镜像分卷），不安装
#   -n, --no-reboot    装完不重启手机
#   -a, --adb <路径>   指定 adb（默认 PATH 与常见安装位置里找）
#   -d, --dest <路径>  仓库推到哪儿（默认 /data/local/tmp/qyt-repo）
#   -i, --image-dir <路径>  镜像分卷放手机哪儿（默认 /data/local/tmp/qyt-image）
#       --image-url <基址>  镜像从哪下（默认 GitHub Release；自建镜像站/网盘直链都行）
#   -s, --serial <序列号>  多台设备时指定
#   -h, --help         看帮助
#
# 电脑侧缓存：分卷下到 _dist/image/（已在 .gitignore 里），校验通过后不重复下。
#
# 为什么 bash 而不是 sh：要用数组与 ${BASH_SOURCE[0]}。macOS 自带 bash 3.2 也能跑
# （所以下面没用 bash 4 的 mapfile/关联数组）。
# ============================================================
set -u

SELF="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$SELF")" && pwd)"
ADB_BIN="${ADB:-}"
DEST="/data/local/tmp/qyt-repo"
IMAGE_DIR="/data/local/tmp/qyt-image"
IMAGE_URL=""
IMAGE_CACHE="$REPO_ROOT/_dist/image"
CHECK=0
PUSH_ONLY=0
NO_REBOOT=0
SERIAL=""
SU=""

die()  { printf '  [失败] %s\n' "$*" >&2; exit 1; }
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [警告] %s\n' "$*"; }
say()  { printf '  %s\n' "$*"; }

# ---------- 每个分卷的尺寸 / 哈希（用于电脑侧校验）----------
size_of() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
dl_pc() {  # dl_pc <url> <out>   断点续传
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -C - --connect-timeout 20 --retry 2 --retry-delay 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -c -O "$2" "$1"
    else
        return 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check)     CHECK=1; shift ;;
        -p|--push-only) PUSH_ONLY=1; shift ;;
        -n|--no-reboot) NO_REBOOT=1; shift ;;
        -a|--adb)       ADB_BIN="${2:-}"; shift 2 ;;
        -d|--dest)      DEST="${2:-}"; shift 2 ;;
        -s|--serial)    SERIAL="${2:-}"; shift 2 ;;
        -i|--image-dir) IMAGE_DIR="${2:-}"; shift 2 ;;
        --image-url)    IMAGE_URL="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,45p' "$SELF"; exit 0 ;;
        *)              die "不认识的参数：$1（-h 看帮助）" ;;
    esac
done

echo "=========================================================="
echo " 栖云台 · 宝塔面板  一键部署（Linux/macOS 侧）"
echo " 作者：茉莉  QQ:1265274322  官方Q群:570387739"
echo "=========================================================="
echo

# ---------- 1) 找 adb ----------
echo "---- 找 adb ----"
if [ -z "$ADB_BIN" ]; then
    for c in "$REPO_ROOT/tools/adb/adb" /usr/local/bin/adb /usr/bin/adb \
             "$HOME/Android/Sdk/platform-tools/adb" "$HOME/Library/Android/sdk/platform-tools/adb" \
             /opt/android-sdk/platform-tools/adb /opt/homebrew/bin/adb; do
        [ -x "$c" ] && ADB_BIN="$c" && break
    done
fi
[ -n "$ADB_BIN" ] || ADB_BIN="$(command -v adb 2>/dev/null || true)"
[ -n "$ADB_BIN" ] && [ -x "$ADB_BIN" ] || die "找不到 adb。装 platform-tools 后用 -a <路径> 指定（Debian/Ubuntu：apt install android-tools-adb；macOS：brew install android-platform-tools）"
ok "adb: $ADB_BIN"

[ -f "$REPO_ROOT/install/deploy.sh" ] || die "当前目录不像仓库根目录（缺 install/deploy.sh）：$REPO_ROOT"

# ---------- 2) 等设备 ----------
echo
echo "---- 等设备 ----"
"$ADB_BIN" start-server >/dev/null 2>&1 || true
devs="$("$ADB_BIN" devices 2>&1 || true)"
if ! printf '%s\n' "$devs" | grep -qE '[[:space:]]device$'; then
    warn "没看到已连接的设备"
    say "USB：插线并在手机上允许调试；或先 $ADB_BIN connect 手机IP:5555"
    if [ "$CHECK" = "1" ]; then die "设备未就绪（--check 到此结束）"; fi
    say "等设备出现（最多 60 秒）…"
    "$ADB_BIN" wait-for-device >/dev/null 2>&1 || true
    devs="$("$ADB_BIN" devices 2>&1 || true)"
fi
printf '%s\n' "$devs" | grep -qE '[[:space:]]device$' || die "设备仍未就绪。adb devices 输出：
$devs"

if [ -z "$SERIAL" ]; then
    SERIAL="$(printf '%s\n' "$devs" | grep -E '[[:space:]]device$' | head -1 | awk '{print $1}')"
fi
[ -n "$SERIAL" ] || die "解析不出设备序列号"
ok "设备: $SERIAL"

# 手机侧执行（root 就直接跑，否则套 su -c）
remote() {
    if [ -n "$SU" ]; then
        "$ADB_BIN" -s "$SERIAL" shell "su -c '$1'" 2>&1
    else
        "$ADB_BIN" -s "$SERIAL" shell "$1" 2>&1
    fi
}

# ---------- 3) 拿 root ----------
echo
echo "---- 检查 root ----"
if remote 'id' | grep -q 'uid=0'; then
    SU=""
    ok "adb 已经是 root（KernelSU-Next 的 adbd 常常本身就是 root，这很正常）"
else
    if remote 'su -c id' | grep -q 'uid=0'; then
        SU="1"
        ok "用 su 拿到了 root"
    else
        die "拿不到 root。确认手机已解锁、已装 KernelSU/Magisk 并在管理器里给 shell 授权"
    fi
fi

arch="$(remote 'uname -m' | tr -d '\r' | tail -1)"
case "$arch" in
    aarch64|arm64) ok "架构 $arch" ;;
    *) warn "架构是 $arch，不是 aarch64 —— 这套东西是给 arm64 设备的" ;;
esac
# 注意：Android 自带的 toybox `df` **没有 -m**（只有 -k / -P / -h），所以用 -k 再换算。
# （busybox 的 df 支持 -m，但手机侧这条命令走的是 toybox，别混着写。）
free_mb="$(remote 'df -P -k /data 2>/dev/null | tail -1 | awk "{printf \"%d\", \$4/1024}"' | tr -d '\r' | tail -1)"
say "/data 可用：${free_mb:-未知} MB（装完约占 17.7 GB，镜像约 8 GB）"

if [ "$CHECK" = "1" ]; then
    echo
    echo "---- --check 结束，什么都没推送 / 安装 ----"
    echo "正式部署： ./deploy-linux.sh"
    exit 0
fi

# ---------- 4) 推文件 ----------
echo
echo "---- 推送到手机 ----"
# 推到 /data/local/tmp（DE 存储），原因见文件头。想用 /sdcard（手机已解锁时也能用）：
#   ./deploy-linux.sh -d /sdcard/qyt-repo
remote "mkdir -p $DEST/install $DEST/module $DEST/tools" >/dev/null 2>&1
"$ADB_BIN" -s "$SERIAL" push "$REPO_ROOT/install/." "$DEST/install/" 2>&1 | tail -1
"$ADB_BIN" -s "$SERIAL" push "$REPO_ROOT/module/."  "$DEST/module/"  2>&1 | tail -1
# tools/ 必须推：step_plugins 要用 tools/plugin_install.py、step_patch 要用 tools/moli_patch.py
"$ADB_BIN" -s "$SERIAL" push "$REPO_ROOT/tools/."   "$DEST/tools/"   2>&1 | tail -1
remote "chmod 755 $DEST/install/*.sh $DEST/module/*.sh $DEST/tools/*.sh" >/dev/null 2>&1

n_ins="$(remote "ls $DEST/install" | grep -c . || true)"
n_mod="$(remote "ls $DEST/module"  | grep -c . || true)"
n_tool="$(remote "ls $DEST/tools"  | grep -c . || true)"
ok "已推送：$DEST/install $n_ins 个，module $n_mod 个，tools $n_tool 个（并已置执行位）"
if [ "${n_ins:-0}" -lt 5 ] || [ "${n_mod:-0}" -lt 5 ] || [ "${n_tool:-0}" -lt 3 ]; then
    die "推送数量不对（install=$n_ins module=$n_mod tools=$n_tool）。若目标在 /sdcard，先确认手机已解锁一次（/sdcard 是 CE 存储，锁屏时不可用）"
fi
for need in plugin_install.py moli_patch.py; do
    remote "test -f $DEST/tools/$need && echo yes || echo no" | grep -q yes \
        || die "手机上缺 $DEST/tools/$need —— step_plugins/step_patch 会失败"
done

# ---------- 4.5) 预制镜像分卷 ----------
# 交付只剩这一条路（理由见 README「为什么不走宝塔官方源」），所以电脑这条路
# 必须把 2.2 GB 的分卷一起准备好：电脑下得快也稳，下完 adb push 过去。
# 手机上已经有了（且校验通过）就跳过 —— 重跑是安全的。
echo
echo "---- 预制镜像分卷 ----"
if remote "sh $DEST/install/fetch-image.sh -d $IMAGE_DIR --check" >/dev/null 2>&1; then
    ok "手机上分卷已就绪且校验通过（跳过下载与推送）"
else
    LOCK="$REPO_ROOT/install/image.lock"
    [ -f "$LOCK" ] || die "缺 $LOCK（镜像的哈希清单，取件和校验都靠它）"
    TAG="$(awk '$1=="image"{t=$2} END{print t}' "$LOCK")"
    [ -n "$TAG" ] || die "$LOCK 里没有 image 数据行"
    [ -n "$IMAGE_URL" ] || IMAGE_URL="https://github.com/moliapiyyds/qiyuntai-btpanel/releases/download/$TAG"
    mkdir -p "$IMAGE_CACHE" || die "建不了缓存目录 $IMAGE_CACHE"
    say "镜像 tag ：$TAG"
    say "缓存目录 ：$IMAGE_CACHE（已下好且校验通过的会跳过，可以反复跑）"
    say "手机目标 ：$IMAGE_DIR"

    parts="$(awk -v t="$TAG" '$1=="image" && $2==t {print $3}' "$LOCK")"
    [ -n "$parts" ] || die "$LOCK 里没有 tag=$TAG 的分卷"
    for p in $parts; do
        want_size="$(awk -v t="$TAG" -v p="$p" '$1=="image" && $2==t && $3==p {print $4}' "$LOCK")"
        want_sha="$(awk -v t="$TAG" -v p="$p" '$1=="image" && $2==t && $3==p {print $5}' "$LOCK")"
        f="$IMAGE_CACHE/$p"
        if [ -f "$f" ] && [ "$(size_of "$f")" = "$want_size" ] && [ "$(sha_of "$f")" = "$want_sha" ]; then
            ok "$p 已在缓存里且校验通过"
            continue
        fi
        say "下载 $p（$((want_size / 1048576)) MB，断点续传）"
        tries=0
        while : ; do
            if dl_pc "$IMAGE_URL/$p" "$f" \
               && [ "$(size_of "$f")" = "$want_size" ] \
               && [ "$(sha_of "$f")" = "$want_sha" ]; then
                break
            fi
            tries=$((tries + 1))
            if [ "$tries" -ge 8 ]; then
                die "$p 下不动或校验不过（缓存：$f）。
      删掉那个文件再重跑；或者 --image-url <基址> 换源；
      或者干脆让手机自己下：手机上跑 install/fetch-image.sh --tries 0"
            fi
            have="$(size_of "$f" 2>/dev/null || echo 0)"
            warn "第 $tries 次没成（已下 $((have / 1048576)) MB），续传重试"
            sleep 2
        done
        ok "$p 下载完成并校验通过"
    done

    # 顺手把两个小清单也取下来（给 deploy.sh 打印清单用，非致命）
    for extra in SHA256SUMS.txt IMAGE-MANIFEST.txt; do
        [ -f "$IMAGE_CACHE/$extra" ] || dl_pc "$IMAGE_URL/$extra" "$IMAGE_CACHE/$extra" >/dev/null 2>&1 || true
    done

    say "推到手机 $IMAGE_DIR（2.2 GB 走 USB，看着进度条等它）"
    remote "mkdir -p $IMAGE_DIR" >/dev/null 2>&1
    for p in $parts; do
        "$ADB_BIN" -s "$SERIAL" push "$IMAGE_CACHE/$p" "$IMAGE_DIR/$p" 2>&1 | tail -1
    done
    for extra in SHA256SUMS.txt IMAGE-MANIFEST.txt; do
        [ -f "$IMAGE_CACHE/$extra" ] && "$ADB_BIN" -s "$SERIAL" push "$IMAGE_CACHE/$extra" "$IMAGE_DIR/$extra" 2>&1 | tail -1
    done
    remote "sh $DEST/install/fetch-image.sh -d $IMAGE_DIR --check" >/dev/null 2>&1 \
        || die "推到手机后校验没通过。看细节：
      $ADB_BIN -s $SERIAL shell \"sh $DEST/install/fetch-image.sh -d $IMAGE_DIR --check\""
    ok "手机上分卷已就绪（校验通过）"
fi

if [ "$PUSH_ONLY" = "1" ]; then
    echo
    echo "---- --push-only：文件已推好，没有安装 ----"
    echo "继续（手机上执行）："
    echo "   $ADB_BIN -s $SERIAL shell \"sh $DEST/install/deploy.sh --from-image $IMAGE_DIR\""
    exit 0
fi

# ---------- 5) 在手机上跑 ----------
echo
echo "---- 手机上开始部署（从预制镜像铺）----"
echo "     约 10 分钟：解包 + 重新随机化身份 + 插件/基线对齐/补丁/模块"
echo "     如果这一步说 /data/openeuler 非空，先清旧的："
echo "       $ADB_BIN -s $SERIAL shell \"su -c 'sh $DEST/install/prepare-rootfs.sh --clean'\""
echo
extra=" --from-image $IMAGE_DIR"
[ "$NO_REBOOT" = "1" ] && extra="$extra --no-reboot"
remote "sh $DEST/install/deploy.sh$extra"
rc=$?

echo
if [ "$rc" = "0" ]; then
    echo "=========================================================="
    echo " 完成。重启后点模块「执行」按钮拿地址账号密码"
    echo "=========================================================="
else
    die "手机侧部署返回码 $rc —— 看上面输出，或手机上跑： sh /data/adb/modules/qiyuntai_btpanel/action.sh diag"
fi
