# 踩坑记录（全部为实测结论）

> 设备：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / 内核 4.9.148 / aarch64）
> 环境：KernelSU-Next 3.3.0（uapi 2）+ NeoZygisk + openEuler 24.03 LTS-SP3 chroot

---

## 一、宝塔面板侧

### 1. 商店「已安装」不是看你装没装，而是看路径
`class/panelPlugin.py` 的 `check_status()` 里：
```python
softInfo['setup'] = os.path.exists(softInfo['install_checks'])
```
`install_checks` 是**云端列表里写死的路径**：

| 组件 | install_checks |
| --- | --- |
| Nginx / OpenResty | `/www/server/nginx/sbin/nginx` |
| MySQL / MariaDB | `/www/server/mysql/bin/mysql` |
| PHP | `/www/server/php/{VERSION}/bin/php`（`set_coexist` 展开） |
| phpMyAdmin | `/www/server/phpmyadmin/version.pl` |
| Redis | `/www/server/redis/runtest` |
| 插件类（Fail2ban 等） | `/www/server/panel/plugin/<名字>` |

**结论：必须用宝塔自己的安装脚本装**，用 dnf 装 nginx/mariadb 面板永远显示「未安装」，也无法启停。

### 2. OpenResty 不是独立条目
它是 **Nginx 卡片里的一个"版本"**：`versions[].m_version` 取值为
`openresty` / `openresty127` / `openresty129` / `openresty131`
（对应 1.25.3.2 / 1.27.1.2 / 1.29.2.5 / 1.31.1.1）。
安装就是 `bash install_soft.sh 0 install nginx openresty131`。

### 3. MariaDB 在 MySQL 卡片里
`versions[].m_version` = `mariadb_10.11` / `mariadb_11.3` / `mariadb_11.8` / `mariadb_12.3` 等。
安装：`bash install_soft.sh 0 install mysql mariadb_10.11`。

### 4. 「Fail2ban 2.6」是插件版本，不是上游版本
云端列表里该条目的 `versions[0]` 是 `m_version=2` + `version=6` → 显示 2.6，
插件包里自带上游 fail2ban 1.1.0。上游 fail2ban 本身没有 2.6 这个版本号。

### 5. 插件包可以免登录下载
`class/panelPlugin.py: __download_plugin()` 走的是
```
POST https://api.bt.cn/down/download_plugin
payload = public.get_user_info() + {name, version, os}
```
即使**没有绑定 bt.cn 账号**（`uid=-1`、`access_key='F'*48`、serverid 本地生成），
返回也是 `HTTP 200` + `File-size: 649185` + 正常 ZIP。
所以本仓库的 `tools/plugin_install.py` 直接调面板自己的
`install_plugin()`（下载+解包）→ `input_package()`（执行 install.sh）两步装插件。

### 6. 面板反爬虫
`BTPanel/__init__.py` 里有 `if public.is_spider(): return abort(404)`。
`curl` 默认 UA 访问面板入口会得到宝塔自己的 404 页（`Server: nginx` 是它伪装的）。
浏览器 UA 即正常 200。

### 7. 破解点（本仓库做法）
* **等级显示**：前端 `utils.js` 用 cookie 判断——
  ```js
  bt.set_cookie('ltd_end', rdata.ltd)   // 来自 plugin/get_soft_list 响应
  if (ltd_end === -2 || ltd_end > -1) advanced = 'ltd'   // 企业版
  ```
  语言表里 `web_end_time: '永久'`，即 `-2` 就代表永久。
  所以补丁在 `panelPlugin.get_cloud_list()` 返回前把 `ltd`/`pro` 覆盖成 `-2`，
  同时把 `expire_msg()` 打成空函数（避免出现"授权剩余天数"提示）。
* **免绑定**：`public.is_bind()` 直接返回 `True`，并预置 `data/initBind.pl`、`data/bind.pl`。
* **去更新**：`script/upgrade_panel.py`、`script/upgrade_panel_optimized.py`、
  `script/polkit_upgrade.py`、`update.sh` 全部替换为空壳（备份在
  `panel/moli_patch/backup_*/`），并清掉 crontab 里的面板更新任务。

### 8. 注意 MariaDB 编译吃内存
`make -j6` 编 MariaDB 10.11（带 rocksdb/mroonga 引擎）峰值会吃掉 2 GB 左右；
设备总内存 5.83 GB、可用 3 GB 时能过，但装东西前最好先释放内存。

---

## 二、chroot / Android 侧

### 1. 内核不支持 nf_tables，也没有 ipset
```
iptables v1.8.9 (nf_tables): TABLE_ADD failed (Address family not supported by protocol): table filter
ipset v7.19: Kernel error received: Invalid argument
```
而 `iptables-legacy -N/-X` 正常，还能看到 Android 自己的 33 条链。
→ 本仓库在 `/usr/local/sbin/iptables` 放了包装（exec `/usr/sbin/iptables-legacy`），
并把 Fail2ban 的 `banaction` 改成 `iptables-multiport`。
**实测**：封禁 `203.0.113.9` 后 `iptables-legacy -S` 出现 `f2b-sshd` 规则，解封后消失。

### 2. chroot 里没有 systemd
`systemctl` 二进制存在（openEuler 自带），但没有 systemd 在跑，命令失败；
`/etc/init.d/fail2ban` 还是 Debian 上游脚本，依赖 `start-stop-daemon` 与 `/lib/lsb/init-functions`（都不存在）。
→ 本仓库提供三个兼容层（`/usr/local/sbin/`）：
`systemctl`（动作映射到 `/etc/init.d/*`）、`service`、`start-stop-daemon`。
面板进程的 PATH 是 `/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`，
`/usr/local/sbin` 在 `/usr/bin` **之前**，所以兼容层能正确遮蔽真 systemctl。

### 3. chroot 里的绝对路径符号链接，在宿主看不到
宝塔把 OpenResty 装在 `/www/server/nginx/nginx`，然后建
`sbin -> /www/server/nginx/nginx/sbin` 这样的绝对软链。
从**宿主**（Android 侧）`ls /data/openeuler/www/server/nginx/sbin/nginx` 会报"不存在"，
从 **chroot 内**访问却是好的。验证宝塔路径一定要在 chroot 里做。

### 4. 宝塔安装器的几个门
* `install_panel.sh` 的 `System_Check()` 会检测 `mysqld` / `php-fpm` / `nginx` / `apache`
  进程中是否有不位于 `/www/server/` 的实例——在手机上会**误判宿主里的进程**。
  部署前先把其它环境的 nginx（例如青龙面板自带的）停掉。
* 交互提示：第一处要输入 `y`，后面两处要输入 `yes`（大小写敏感）。
* `Add_lib_Install()` 被 `X86_CHECK=$(uname -m|grep x86_64)` 挡住，aarch64 直接跳过。
* aarch64 下载的是 pyenv 的 `cpython-3.13.14-aarch64-unknown-linux-gnu-bundle.tar.gz`。

### 5. 其它坑
* `chroot` 不会重置环境变量，要用
  `chroot $ROOT /usr/bin/env -i HOME=/root PATH=... LANG=C.UTF-8 /bin/bash -c '...'`。
* `/etc/resolv.conf` 要自己写（宿主 `net.dns1` 可能是链路本地 IPv6）。
* Android 的 toybox 工具有坑：`grep -o 'a\|b'` 不可靠要用 `-E`；`sort -rh` 不支持；
  `awk strtonum()` 没有。
* 在宿主用 `adb shell "su -c '...'"` 拼复杂命令极易被引号吃掉，
  可靠做法是**把脚本 push 上去再执行**。

---

## 三、MariaDB 起不来？两个 Android 特有的坑（都踩过）

### 1. paranoid-network：非 root 不能建 AF_INET socket
chroot 里用 `/etc/init.d/mysqld start`（`mysqld_safe` 会降到 `mysql` 用户，uid 1001）启动，
日志里是：
```
[Warning] Failed to create a socket for IPv6 '::': errno: 13.
[Warning] Failed to create a socket for IPv4 '0.0.0.0': errno: 13.
[ERROR] No TCP address could be bound to
[ERROR] Aborting
```
`errno 13 = EACCES`，而同时用 **root** 手动跑 `./bin/mariadbd --user=root ...` 却能
`ready for connections`、3306 正常监听 —— 说明不是端口/配置问题，是 **Android 内核的
paranoid-network 限制**：只允许 root 或 AID_INET(**gid 3003**) 组的进程创建 AF_INET socket。

修法（本仓库 `install/android-network-fix.sh` 做的事）：
```sh
grep -q '^inet:' /etc/group || echo 'inet:x:3003:' >> /etc/group
usermod -aG inet mysql
```
之后 `/etc/init.d/mysqld start` → `SUCCESS!`，`mysql -uroot -e "select version()"`
→ `10.11.16-MariaDB-log`。

> 同理：chroot 里任何**非 root 身份**、又要监听 TCP 的服务都得这么处理。

### 2. 数据目录属主被 root 污染
调试时用 root 跑过一次 `mariadbd`，`/www/server/data/mysql-bin.000003`
和 `mysql-bin.state` 归了 `root:root`（`-rw-rw----`），再切回 `mysql` 用户启动就报：
```
[ERROR] mariadbd: File './mysql-bin.000003' not found (Errcode: 13 "Permission denied")
[ERROR] Can't init tc log
[ERROR] Aborting
```
`chown -R mysql:mysql /www/server/data` 后恢复正常（模块 `service.sh` 每次开机都会兜底 chown）。

---

## 四、KernelSU：管理器显示「不支持 / 未集成」其实不是内核问题

**症状**（管理器首页）：
```
不支持 | 未集成
不支持非 GKI 内核。请将 KernelSU-Next 传统驱动程序集成到您的内核中！
管理器版本 v3.3.0 (33214-2)
内核版本   4.9.148-...-Moli-KSUNext (aarch64)
```
但此时 `su` 能用、`ksud` 能用、模块照常加载、dmesg 里 KSU 的 ioctl 正常。

**实测原因（不是 GKI 的事）**：
内核里的 **manager appid 没有持久化**，重启后回到「未注册」状态 → 内核不把管理器 App 当成"管理器"
→ App 拿不到 root → 查不到内核状态 → 界面退化成那句误导性的「非 GKI」提示。

铁证就是 `set-manager` 的打印：**每次开机第一次执行都是 `4294967295 -> 10166`**
（`4294967295 = 0xFFFFFFFF` = 未设置），紧接着再执行一次就变成 `10166 -> 10166`：

```
[10:04:48] KernelSU 管理器注册: set manager appid: 4294967295 -> 10166   ← 开机，未注册
[10:15:37] KernelSU 管理器注册: set manager appid: 4294967295 -> 10166   ← 又重启，还是未注册
（手动再跑）                     set manager appid: 10166 -> 10166        ← 已注册
```

**解决**（需要内核 `CONFIG_KSU_DEBUG=y`，非 GKI 自编译内核一般都会开）：
```sh
ksud debug set-manager com.rifsxd.ksunext      # 用管理器的包名
# 之后管理器首页会变成：
#   工作中 | BUILT-IN (LEGACY) | Version: v3.2.0-legacy (33193-2)
#   超级用户 2 / 模块 9 / Hook 模式 Manual
```

**必须每次开机都做**（因为内核不持久化），所以本项目的模块 `service.sh` 里内置了这一步，
还带 3 次重试 —— 首次执行可能因为应用数据目录未就绪而失败（实测见过
`Error: stat /data/data/com.rifsxd.ksunext`）。

**顺带澄清几个容易误判的点**：
* 管理器版本(33214) 比内核版本(33193) 新，**不是**不支持的原因；两者用 uapi 通信，本例 uapi=2 一致。
* `ksud debug info` 里看不到 manager 信息，别拿它当判据；要看就用 `set-manager` 的打印。
* 这个提示跟"内核有没有 GKI"没关系，别被那句话带偏去刷内核。


