#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 模块安装时执行（KernelSU / Magisk 兼容）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# MODDIR：绝对路径调用（KSU/Magisk 就是这么调的）和手工相对调用都要能用
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
ROOT=/data/openeuler

# 确保所有脚本可执行
# 注意 action.sh 必须在内：模块「执行」按钮就是跑它，漏了会点不动
for f in service.sh uninstall.sh customize.sh action.sh; do
    [ -f "$MODDIR/$f" ] && chmod 755 "$MODDIR/$f" 2>/dev/null
done
mkdir -p "$MODDIR/bin" 2>/dev/null

echo "=========================================="
echo " 栖云台 · 宝塔面板"
echo " 作者：茉莉  QQ:1265274322  群:570387739"
echo "=========================================="

if [ -d "$ROOT/www/server/panel" ]; then
    echo "OK  检测到已有面板环境（$ROOT），重启后会自动拉起全部服务。"
    echo ""
    echo "重启完成后："
    echo "  1) 点模块的「执行」按钮 —— 打印地址、账号、密码，并用浏览器打开面板"
    echo "  2) 出问题先跑诊断： sh $MODDIR/action.sh diag"
else
    echo "!!  未检测到 $ROOT/www/server/panel"
    echo ""
    echo "说明 chroot 环境或面板还没部署。模块本身已经装好（开机流程会等环境就绪），"
    echo "但需要先把 openEuler 铺好再重启。最省事是在电脑上跑一次 deploy.ps1；"
    echo "要手搓的话（文件已经推到 /data/local/tmp/qyt-repo，用 /sdcard 也行 —— 但 /sdcard"
    echo "是 CE 存储，重启后没解锁一次就不可用）："
    echo ""
    echo "  # 1) 铺 rootfs（--mirror 让它自己到镜像站挑文件；也可 --url 指定具体地址）"
    echo "  sh /data/local/tmp/qyt-repo/install/prepare-rootfs.sh --mirror"
    echo ""
    echo "  # 2) 装面板 + 组件 + 插件 + 补丁（all 会按顺序全做）"
    echo "  sh /data/local/tmp/qyt-repo/install/qiyuntai-install.sh all"
    echo ""
    echo "  # 3) 重启"
    echo "  reboot"
    echo ""
    echo "也可以一步到位（手机侧自举）： sh /data/local/tmp/qyt-repo/install/deploy.sh"
    echo "完整步骤见 module/README.md 与仓库根 README.md。"
fi
