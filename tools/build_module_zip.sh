#!/bin/bash
# ============================================================
# 打 KernelSU / Magisk 可刷模块 zip
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 产出：_dist/qiyuntai_btpanel-v<版本>.zip
#       文件直接放在 zip 根目录（module.prop 必须在根，这是模块格式要求）
#
# 用法：bash tools/build_module_zip.sh
# ============================================================
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/module"
DIST="$ROOT/_dist"

[ -f "$M/module.prop" ] || { echo "x 找不到 $M/module.prop"; exit 1; }

VER=$(grep -m1 '^version=' "$M/module.prop" | cut -d= -f2-)
ID=$(grep -m1 '^id=' "$M/module.prop" | cut -d= -f2-)
[ -n "$VER" ] || { echo "x module.prop 里读不到 version"; exit 1; }

OUT="$DIST/${ID}-${VER}.zip"
mkdir -p "$DIST"
rm -f "$OUT"

echo "=== 打包 $ID $VER ==="
echo "  来源：$M"
echo "  产出：$OUT"

# -X 去掉多余文件属性；文件放根目录
( cd "$M" && zip -X -q -r "$OUT" . -x '.*' -x '*/.*' )

echo
echo "=== zip 内容 ==="
unzip -l "$OUT"

echo
echo "=== 版本自检 ==="
ZP=$(unzip -p "$OUT" module.prop 2>/dev/null | grep -m1 '^version=' | cut -d= -f2-)
if [ "$ZP" = "$VER" ]; then
    echo "  OK  zip 里的 module.prop version = $ZP"
else
    echo "  !!  zip 里读到的版本是 '$ZP'，与 '$VER' 不一致"; exit 1
fi
if unzip -l "$OUT" | grep -q 'module.prop' && unzip -l "$OUT" | grep -q 'service.sh' \
   && unzip -l "$OUT" | grep -q 'customize.sh'; then
    echo "  OK  关键文件（module.prop / customize.sh / service.sh）都在根目录"
else
    echo "  !!  缺少关键文件"; exit 1
fi

echo
echo "=== 产物 ==="
ls -l "$OUT"
md5sum "$OUT"
sha256sum "$OUT"
echo "$OUT"
