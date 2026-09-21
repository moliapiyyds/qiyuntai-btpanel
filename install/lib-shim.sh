#!/bin/bash
# shellcheck disable=SC1090  # source 的是宝塔面板自带的 public.sh，不在本仓库里
# shellcheck disable=SC2034  # Is_64bit / CONFIGURE_BUILD_TYPE 是给面板脚本读的，本文件不直接用
# ============================================================
# 栖云台 · 宝塔依赖安装脚本（本机适配版 shim）
# 部署时覆盖 /www/server/panel/install/lib.sh
#   —— 覆盖前由 install/qiyuntai-install.sh 自动把原版留一份为同目录 lib.sh.bt-orig
#      （幂等：已经存在 .bt-orig 就不再动，避免二次执行把 shim 当成「原版」备份掉）
# ------------------------------------------------------------
# 为什么换掉原版：
#   原版 lib.sh 会 yum 安装上百个包（很多在 openEuler 上不存在，会让整条
#   dnf 事务失败），还会源码编译 openssl-1.0.2u / pcre / curl / mhash /
#   libmcrypt / mcrypt / libiconv / freetype —— 这些在 aarch64 + PHP8.2 的
#   组合里并不需要（PHP8 分支用的是系统 openssl/curl），纯属浪费 20-30 分钟。
#   本 shim 只做最小兜底：设好下载地址、创建 www 用户、保证目录存在。
#   依赖由 dnf 预装（见 install/qiyuntai-install.sh 的 step_deps）。
# ============================================================
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/root/bin
export PATH
public_file=/www/server/panel/install/public.sh
[ -f "$public_file" ] && . $public_file
if [ -z "${NODE_URL}" ]; then download_Url="https://download.bt.cn"; else download_Url=$NODE_URL; fi
export download_Url
mkdir -p /www/server /root
Is_64bit=$(getconf LONG_BIT)
if [ -z "${cpuCore}" ]; then cpuCore=$(getconf _NPROCESSORS_ONLN); fi
if [ -z "${cpuCore}" ]; then cpuCore=1; fi
if ! id www >/dev/null 2>&1; then
    groupadd www 2>/dev/null
    useradd -s /sbin/nologin -g www www 2>/dev/null || useradd -s /bin/false -g www www 2>/dev/null
fi
CONFIGURE_BUILD_TYPE="--build=arm-linux"
echo "shim lib.sh: download_Url=${download_Url} cpuCore=${cpuCore}"
