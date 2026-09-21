#!/system/bin/sh
# ============================================================
# 栖云台 · Android paranoid-network 修正（MariaDB 必需）
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ============================================================
# 实测结论：Android 内核带 paranoid-network 限制——
#   只有 root 或 AID_INET(gid=3003) 组的进程才能创建 AF_INET socket。
#   chroot 里的 mysql 用户（uid 1001）默认不在该组，于是 mariadbd 启动时报：
#     [Warning] Failed to create a socket for IPv4 '0.0.0.0': errno: 13
#     [ERROR] No TCP address could be bound to
#     [ERROR] Aborting
#   把 mysql 加进 gid 3003 的组后，3306 正常监听。
# 同理：任何在 chroot 里以非 root 身份跑、需要监听 TCP 的服务都要这么做。
# ============================================================

R=/data/openeuler
CH="chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8"

if [ ! -f "$R/etc/group" ]; then
    echo "找不到 $R/etc/group，跳过"
    exit 0
fi

# 1) 确保存在 gid 3003 的 inet 组
if ! grep -q '^inet:' "$R/etc/group"; then
    echo 'inet:x:3003:' >> "$R/etc/group"
    echo "已添加 inet 组(gid 3003)"
fi

# 2) 把 chroot 里需要监听 TCP 的服务账号加进 inet 组
#    memcached 要特殊处理，是 2026-09-22 实测出来的：
#    它的 init 脚本用 `-u memcached` 起（memcached 拒绝以 root 跑），而 memcached
#    降权时只做 setgid/setuid、**不带附加组**（实测进程里 `Groups:` 是空的），
#    所以光 `usermod -aG inet` 不生效 —— 必须把它的**主组**设成 inet(3003)，
#    否则 bind 127.0.0.1:11211 直接失败，日志里只有一句：
#      failed to listen on one of interface(s) 127.0.0.1: Permission denied
for u in mysql www redis; do
    $CH /bin/bash -c "id $u >/dev/null 2>&1 && usermod -aG inet $u" 2>/dev/null
done
$CH /bin/bash -c "id memcached >/dev/null 2>&1 && usermod -g inet memcached" 2>/dev/null

# 3) 校正 MariaDB 数据目录属主（幂等；只在目录存在时执行）
$CH /bin/bash -c "[ -d /www/server/data ] && chown -R mysql:mysql /www/server/data" 2>/dev/null

echo "mysql 身份: $($CH /bin/bash -c 'id mysql 2>/dev/null')"
echo "www   身份: $($CH /bin/bash -c 'id www 2>/dev/null')"
echo "redis 身份: $($CH /bin/bash -c 'id redis 2>/dev/null')"
echo "memcached 身份: $($CH /bin/bash -c 'id memcached 2>/dev/null')"
echo "network-fix 完成"
