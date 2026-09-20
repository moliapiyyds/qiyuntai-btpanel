#!/system/bin/sh
# ============================================================
# 栖云台 · 宝塔面板 —— 模块安装时执行（KernelSU / Magisk 兼容）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
MODDIR=${0%/*}
ROOT=/data/openeuler

# 确保脚本可执行
for f in service.sh uninstall.sh customize.sh; do
    [ -f "$MODDIR/$f" ] && chmod 755 "$MODDIR/$f" 2>/dev/null
done
mkdir -p "$MODDIR/bin" 2>/dev/null

if [ -d "$ROOT/www/server/panel" ]; then
    echo "栖云台：检测到已有面板环境（$ROOT），重启后会自动拉起。"
else
    echo "栖云台：警告——未检测到 $ROOT/www/server/panel，请先部署 openEuler chroot。"
fi
