#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 预制镜像取件
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 干什么：把预制镜像的分卷拿到 /data/local/tmp/qyt-image，
#         逐卷核对 sha256（清单在 install/image.lock），然后交给
#         install/deploy.sh --from-image 解包。
#
# 为什么单独一个脚本：
#   镜像现在是**唯一交付路径**（官方安装器那条路会让面板版本随宝塔浮动，
#   我们的补丁是版本门禁的，见 install/image.lock 顶部的说明）。
#   唯一路径上的下载就必须自己扛住断线：断点续传 + 逐卷校验 + 重试，
#   而不是「下一半然后解包出一个坏环境」。
#
# 用法：
#   sh install/fetch-image.sh                       # 默认下到 /data/local/tmp/qyt-image
#   sh install/fetch-image.sh -d /data/qyt_image    # 指定目录
#   sh install/fetch-image.sh -f /sdcard/qyt-image  # 用本地已有的分卷（拷过来）
#   sh install/fetch-image.sh -u <基址>             # 换源（自建镜像站/网盘直链）
#   sh install/fetch-image.sh -t v1.2.5             # 取旧 tag 的镜像
#   sh install/fetch-image.sh --check               # 只校验已有分卷，不下载
#
# 参数：
#   -d, --dest <dir>      落盘目录（默认 /data/local/tmp/qyt-image）
#   -f, --from <dir>      从本地目录拷（不联网）
#   -u, --base-url <url>  下载基址（默认 GitHub Release；末尾不要带 /）
#   -t, --tag <tag>       指定 Release tag（默认取 image.lock 里最后一条）
#   -l, --lock <file>     指定清单（默认与本脚本同目录的 image.lock）
#       --tries <n>       每个分卷最多试几次（默认 12；**0 = 一直试到成功**）
#                         手机直连 GitHub 时 github.com 那一跳会间歇性连不上
#                         （实测 curl: (28) Failed to connect ... Timeout was reached，
#                         busybox wget 同样；但 CDN 那个 185.199.x.x 是通的），
#                         撞上坏窗口时唯一有效的办法就是等一下再续传。挂 0 让它自己磨。
#       --only <名字>     只取某一个分卷（单个卷重试时用；名字见 install/image.lock）
#       --no-verify       跳过 sha256 校验（**不建议**，只在校验太慢时临时用）
#       --check           只校验，不下载不拷贝
#   -h, --help            看这段
#
# 放在 /data/local/tmp 是故意的：/sdcard 是 CE 存储，手机没解锁时不可用。
# 空间要求：分卷本身约 2.2 GB，deploy.sh 解包时还会拼一份 2.2 GB，峰值约 4.5 GB。
# ============================================================
set -u

REPO_SLUG=moliapiyyds/qiyuntai-btpanel
DEST=/data/local/tmp/qyt-image
FROM_DIR=""
BASE_URL=""
TAG=""
LOCK=""
TRIES=12
ONLY=""
DO_VERIFY=1
DO_CHECK=0

say()  { echo "  $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [警告] $*"; }
die()  { echo "  [失败] $*" >&2; exit 1; }
hr()   { echo "----------------------------------------------------------"; }

# ---------- 定位清单 ----------
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$SELF_DIR" ] || SELF_DIR=$(pwd)
LOCK="$SELF_DIR/image.lock"

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dest)     DEST="$2"; shift 2 ;;
        -f|--from)     FROM_DIR="$2"; shift 2 ;;
        -u|--base-url) BASE_URL="$2"; shift 2 ;;
        -t|--tag)      TAG="$2"; shift 2 ;;
        -l|--lock)     LOCK="$2"; shift 2 ;;
        --tries)       TRIES="$2"; shift 2 ;;
        --only)        ONLY="$2"; shift 2 ;;
        --no-verify)   DO_VERIFY=0; shift ;;
        --check)       DO_CHECK=1; shift ;;
        -h|--help)     sed -n '2,42p' "$0"; exit 0 ;;
        *) die "未知参数：$1（-h 看用法）" ;;
    esac
done

echo "=========================================================="
echo " 栖云台 · 预制镜像取件"
echo " 作者：茉莉  QQ:1265274322  官方Q群:570387739"
echo "=========================================================="
echo

[ -f "$LOCK" ] || die "找不到清单 $LOCK（它和本脚本同目录，是 image.lock）"

# ---------- 工具 ----------
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
    [ -x "$b" ] && BB="$b" && break
done

# sha256：优先 busybox（toybox 的 sha256sum 有的机型没有）
SHACMD=""
if [ -n "$BB" ] && "$BB" sha256sum </dev/null >/dev/null 2>&1; then
    SHACMD="$BB sha256sum"
elif command -v sha256sum >/dev/null 2>&1; then
    SHACMD="sha256sum"
fi

DL_KIND=""
if command -v curl >/dev/null 2>&1; then
    DL_KIND=curl
elif command -v wget >/dev/null 2>&1; then
    DL_KIND=wget
elif [ -n "$BB" ]; then
    DL_KIND=bbwget
fi

shasum_of() {  # shasum_of <file>  -> 打印 sha256
    $SHACMD "$1" 2>/dev/null | awk '{print $1}'
}

dl() {  # dl <url> <outfile>   断点续传；失败返回非 0
    case "$DL_KIND" in
        curl)   curl -L --fail -C - --connect-timeout 20 --retry 2 --retry-delay 3 \
                     --progress-bar -o "$2" "$1" ;;
        wget)   wget -c -T 30 -O "$2" "$1" ;;
        bbwget) "$BB" wget -c -T 30 -O "$2" "$1" ;;
        *)      return 1 ;;
    esac
}

# ---------- 读清单 ----------
# 默认用清单里**最后一条** image 行所属的 tag（新的追加在末尾 = 默认用它）
LOCK_TAG=$(awk '$1=="image"{t=$2} END{print t}' "$LOCK")
[ -n "$LOCK_TAG" ] || die "$LOCK 里没有 image 数据行"
[ -n "$TAG" ] || TAG="$LOCK_TAG"

PARTS=$(awk -v t="$TAG" '$1=="image" && $2==t {print $3}' "$LOCK")
[ -n "$PARTS" ] || die "$LOCK 里没有 tag=$TAG 的分卷记录"
if [ -n "$ONLY" ]; then
    case " $PARTS " in
        *" $ONLY "*) PARTS="$ONLY" ;;
        *) die "--only 给的名字不在清单里：$ONLY（清单里是：$PARTS）" ;;
    esac
    say "只取：$ONLY"
fi

WHOLE_LINE=$(awk -v t="$TAG" '$1=="whole" && $2==t {print $3, $4, $5}' "$LOCK")

PART_N=0
for _ in $PARTS; do PART_N=$((PART_N + 1)); done

say "清单      ：$LOCK"
say "镜像 tag  ：$TAG"
say "分卷      ：$PART_N 个"
say "落盘目录  ：$DEST"
if [ -n "$FROM_DIR" ]; then
    say "本地来源  ：$FROM_DIR"
elif [ -z "$BASE_URL" ]; then
    BASE_URL="https://github.com/$REPO_SLUG/releases/download/$TAG"
    say "下载基址  ：$BASE_URL（默认）"
else
    say "下载基址  ：$BASE_URL"
fi
if [ "$DO_VERIFY" = "1" ] && [ -z "$SHACMD" ]; then
    warn "没有 sha256sum 可用 —— 强制关掉校验（只有大小对得上，安全性打折）"
    DO_VERIFY=0
fi
[ "$DO_VERIFY" = "1" ] && say "校验      ：sha256（逐卷 + 整包）" || warn "校验      ：已关闭"
echo

if [ "$DO_CHECK" = "0" ]; then
    mkdir -p "$DEST" || die "建不了 $DEST"
    if [ -n "$FROM_DIR" ]; then
        [ -d "$FROM_DIR" ] || die "--from 给的目录不存在：$FROM_DIR"
    elif [ -z "$DL_KIND" ]; then
        die "没有 curl / wget / busybox，下载不了。
      改用电脑侧取件后推过来：
        D=/data/local/tmp/qyt-image; adb shell \"mkdir -p \$D\"
        adb push qyt-image.part-* \$D/
        adb shell \"su -c 'sh /data/local/tmp/qyt-repo/install/fetch-image.sh --check'\"
      或把分卷放到手机里用 --from <目录>。"
    fi
    # 空间：分卷 + deploy.sh 拼的那份
    NEED_KB=4718592   # 4.5 GB 上限
    FREE_KB=$(df -P -k "$DEST" 2>/dev/null | awk 'NR==2{print $4}')
    case "$FREE_KB" in
        ''|*[!0-9]*) warn "取不到 $DEST 的可用空间，跳过空间检查" ;;
        *) if [ "$FREE_KB" -lt "$NEED_KB" ]; then
               warn "$DEST 只剩 $((FREE_KB / 1024)) MB。分卷约 2.2 GB，解包时还要拼一份 2.2 GB，"
               warn "     峰值约 4.5 GB —— 空间不够会在解包那步炸，建议先清。"
           else
               ok "可用空间 $((FREE_KB / 1024)) MB"
           fi ;;
    esac
fi

# ---------- 逐卷取 ----------
FAILED=""
N=0
for P in $PARTS; do
    N=$((N + 1))
    WANT_SIZE=$(awk -v t="$TAG" -v p="$P" '$1=="image" && $2==t && $3==p {print $4}' "$LOCK")
    WANT_SHA=$(awk -v t="$TAG" -v p="$P" '$1=="image" && $2==t && $3==p {print $5}' "$LOCK")
    F="$DEST/$P"

    hr
    say "[$N/$PART_N] $P  （$((WANT_SIZE / 1048576)) MB）"

    # 已就绪？直接跳过（重跑是安全的）
    if [ -f "$F" ]; then
        GOT_SIZE=$(wc -c < "$F" 2>/dev/null | tr -d ' ')
        if [ "$GOT_SIZE" = "$WANT_SIZE" ] && [ "$DO_VERIFY" = "0" ]; then
            ok "已存在且大小一致（未校验哈希）"
            continue
        fi
        if [ "$DO_VERIFY" = "1" ] && [ "$GOT_SIZE" = "$WANT_SIZE" ]; then
            say "已在且大小一致，校验哈希…"
            if [ "$(shasum_of "$F")" = "$WANT_SHA" ]; then
                ok "已就绪，校验通过"
                continue
            fi
            warn "哈希不对（文件被改过或下坏了），删掉重取"
            rm -f "$F"
        elif [ "$GOT_SIZE" != "$WANT_SIZE" ]; then
            say "已有部分文件 $((GOT_SIZE / 1048576)) MB / $((WANT_SIZE / 1048576)) MB"
        fi
    fi

    if [ "$DO_CHECK" = "1" ]; then
        FAILED="$FAILED $P"
        warn "缺这一卷（--check 模式不下载）"
        continue
    fi

    # 本地拷贝模式
    if [ -n "$FROM_DIR" ]; then
        SRC="$FROM_DIR/$P"
        [ -f "$SRC" ] || { FAILED="$FAILED $P"; warn "$FROM_DIR 里没有 $P"; continue; }
        say "从 $SRC 拷贝…"
        cp -f "$SRC" "$F" || die "拷贝 $P 失败"
    else
        # 下载：重试 + 续传。
        # 为什么要有「一直试」：手机直连 GitHub 时 github.com 那一跳会**间歇性**
        # 连不上（实测 curl: (28) Failed to connect to github.com port 443 after
        # 15001 ms；busybox wget 一样），但 CDN 那一跳（185.199.x.x）是通的。
        # 撞上坏窗口时唯一有效的办法是等一下再续传 —— 不是换命令、更不是重下。
        TRY=1
        while : ; do
            if [ "$TRIES" != "0" ] && [ "$TRY" -gt "$TRIES" ]; then
                break
            fi
            if [ "$TRIES" = "0" ]; then
                say "下载（第 $TRY 次，一直试到成功；断点续传）"
            else
                say "下载（第 $TRY/$TRIES 次，断点续传）"
            fi
            if dl "$BASE_URL/$P" "$F"; then
                break
            fi
            HAVE=0
            [ -f "$F" ] && HAVE=$(wc -c < "$F" 2>/dev/null | tr -d ' ')
            warn "这次没下完。已落盘 $((HAVE / 1048576)) MB / $((WANT_SIZE / 1048576)) MB"
            warn "  半截文件保留在 $F —— 下次接着传，不会从头来"
            TRY=$((TRY + 1))
            sleep 3
        done
    fi

    # 校验
    [ -f "$F" ] || { FAILED="$FAILED $P"; warn "$P 没有落盘"; continue; }
    GOT_SIZE=$(wc -c < "$F" 2>/dev/null | tr -d ' ')
    if [ "$GOT_SIZE" != "$WANT_SIZE" ]; then
        # 这里**故意不删**：留着半截才能续传，删了就是白下。
        # （以前这里是 rm -f，等于把断点续传的价值抹掉了。）
        warn "$P 只下到 $((GOT_SIZE / 1048576)) MB / $((WANT_SIZE / 1048576)) MB"
        warn "  半截文件保留：$F"
        FAILED="$FAILED $P"
        continue
    fi
    if [ "$DO_VERIFY" = "1" ]; then
        say "校验哈希…"
        GOT_SHA=$(shasum_of "$F")
        if [ "$GOT_SHA" != "$WANT_SHA" ]; then
            warn "$P 哈希不匹配！"
            warn "  期望 $WANT_SHA"
            warn "  实得 $GOT_SHA"
            rm -f "$F"
            FAILED="$FAILED $P"
            continue
        fi
        ok "大小 + 哈希都对"
    else
        ok "大小对（未校验哈希）"
    fi
done

# ---------- 整包校验 ----------
if [ -z "$FAILED" ] && [ "$DO_VERIFY" = "1" ] && [ -n "$WHOLE_LINE" ] && [ -z "$ONLY" ]; then
    hr
    say "整包校验（分卷按字母序拼接后算一次 sha256，约 2.2 GB，几十秒）"
    W_NAME=$(echo "$WHOLE_LINE" | awk '{print $1}')
    W_SIZE=$(echo "$WHOLE_LINE" | awk '{print $2}')
    W_SHA=$(echo "$WHOLE_LINE" | awk '{print $3}')
    # 用 awk 算 MB，不用 $(( ))：shell 的 $(( )) 是 32 位有符号，
    # 2.2 GB 的字节数（> 2^31）会溢出成负数（实测打出过「-1971 MB」）。
    W_MB=$(awk -v b="$W_SIZE" 'BEGIN{printf "%.0f", b/1048576}')
    cat "$DEST"/qyt-image.part-* 2>/dev/null | $SHACMD 2>/dev/null | awk '{print $1}' > "$DEST/.whole.sha"
    GOT_W=$(cat "$DEST/.whole.sha" 2>/dev/null)
    rm -f "$DEST/.whole.sha"
    if [ "$GOT_W" = "$W_SHA" ]; then
        ok "整包 $W_NAME 校验通过（$W_MB MB）"
    else
        warn "整包哈希不匹配：期望 $W_SHA，实得 [$GOT_W]"
        FAILED="$FAILED <whole>"
    fi
fi

# ---------- 顺带把清单文件取下来（给 deploy.sh 打印用，非致命）----------
if [ -z "$FAILED" ] && [ "$DO_CHECK" = "0" ] && [ -z "$FROM_DIR" ]; then
    for extra in SHA256SUMS.txt IMAGE-MANIFEST.txt; do
        if [ ! -f "$DEST/$extra" ]; then
            dl "$BASE_URL/$extra" "$DEST/$extra" >/dev/null 2>&1 \
                && say "已取 $extra" \
                || warn "$extra 没取到（不影响部署）"
        fi
    done
fi

# ---------- 结果 ----------
echo
hr
if [ -n "$FAILED" ]; then
    warn "这些分卷没到手：$FAILED"
    echo
    echo "  好消息：半截文件都留着，**直接再跑同一条命令**就会接着传，不会从头来。"
    echo "  手机直连 GitHub 不稳（github.com 那一跳会间歇性连不上），两个办法："
    echo "    磨：加 --tries 0 让它一直试（可以挂着去睡觉）"
    echo "        sh $0 -d $DEST --tries 0"
    echo "    或者干脆用电脑下（电脑网络好，下完自动推进手机）："
    echo "        .\\deploy.ps1        （Windows）"
    echo "        ./deploy-linux.sh    （Linux / macOS）"
    echo
    echo "  其它排错："
    echo "    1) 看 DNS：cat /etc/resolv.conf"
    if [ -n "$BB" ]; then
        echo "    2) 探一下能不能连："
        echo "       $BB wget -O /dev/null -T 10 $BASE_URL/SHA256SUMS.txt; echo \$?"
    fi
    echo "    3) 手动推进来："
    echo "       D=$DEST; adb shell \"mkdir -p \$D\""
    echo "       adb push qyt-image.part-* \$D/"
    echo "       adb shell \"su -c 'sh /data/local/tmp/qyt-repo/install/fetch-image.sh --check'\""
    echo "    4) 分卷已经在手机别处：--from /那个/目录"
    echo "    5) 换源：-u <基址>（自建镜像站、网盘直链都行，只要目录结构和 Release 一样）"
    echo "    6) 从一台已经装好的设备直接拿（不经过网络）：在那边跑"
    echo "       sh tools/make_image.sh --out /data/qyt_image  然后 adb pull 分卷过来"
    hr
    die "取件未完成"
fi

echo " 取件完成：$DEST"
ls -la "$DEST" 2>/dev/null | sed 's/^/    /'
echo
echo " 下一步："
echo "   1) 这台设备已经有环境的话，先清干净（会删掉 /data/openeuler，先确认备份）："
echo "        su -c 'sh $SELF_DIR/prepare-rootfs.sh --clean'"
echo "   2) 铺镜像（约 10 分钟，会重新随机化端口/入口/密码/sshd 主机密钥）："
echo "        su -c 'sh $SELF_DIR/deploy.sh --from-image $DEST'"
echo "  （不加 --from-image 也行：deploy.sh 默认就会找 $DEST）"
hr
