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

## 四、KernelSU：管理器显示「不支持 / 未集成」（2026-09-20 修正版结论）

**症状**（管理器首页）：

```
不支持 | 未集成
不支持非 GKI 内核。请将 KernelSU-Next 传统驱动程序集成到您的内核中！
管理器版本 v3.3.0 (33214-2)
内核版本   4.9.148-...-Moli-KSUNext (aarch64)
```

此时 `su` 能用、`ksud` 能用、模块照常加载、dmesg 里 KSU 的 ioctl 正常。

> ⚠️ 本节早期版本把原因写成「内核不持久化 manager appid」，**那个判断不完整**。
> 2026-09-20 抓到内核日志后修正如下：内核**每次开机都会自己扫一遍认领管理器**，
> 只是那次扫描会失败，而失败后不会自动补扫。

### 真正的原因（两条，都有内核日志）

管理器由 `KernelSU/kernel/manager/throne_tracker.c` 认领：启动早期读
`/data/system/packages.list` 建 uid 表，再遍历 `/data/app` 找签名匹配的 `base.apk`，
命中即 `Crowning manager: <pkg>(uid=NNNNN)`，把 `ksu_manager_appid` 设为该 uid。

**原因 1：那次扫描会因瞬时错误整体失败，而失败后不再补扫**

```
# 成功的那次开机（dmesg.old.log）
[ 29.71] PackageManager: KernelSU: Searching manager...
[ 29.71] KernelSU: Found new base.apk at path: /data/app/com.rifsxd.ksunext-.../base.apk, is_manager: 1
[ 29.71] KernelSU: Crowning manager: com.rifsxd.ksunext(uid=10166)
[ 29.71] KernelSU: Search manager finished
[ 37.58] ksud: ksu_manager_appid set to 10166

# 失败的那次开机（dmesg.log）—— 同一个 APK，这次打不开
[ 30.08] PackageManager: KernelSU: Searching manager...
[ 30.08] KernelSU: open /data/app/com.rifsxd.ksunext-0YOQJR30e8CocabA90DtXQ==/base.apk error.
[ 30.08] KernelSU: Found new base.apk at path: ..., is_manager: 0
[ 30.17] KernelSU: Search manager finished          ← 没人被认领，就此结束
```

原版重试策略是 `10 次 × 100ms`（约 1 秒）后放弃；本内核又没编 `KSU_LSM_HOOKS`，
`on_boot_completed()` 里那次补扫触发不到 → **整轮开机都不会再认领**。

**原因 2：误判「已卸载」后会注销 appid，而且注销后当场不重扫**

```c
if (!manager_exist) {                        // packages.list 里没找到管理器那一行
    if (ksu_is_manager_appid_valid()) {
        ksu_invalidate_manager_uid();        // 把已验证的 appid 清掉
        goto prune;                          // ← 直接结束，不当场重扫
    }
    search_manager("/data/app", 2, &uid_list);
}
```

`/data/system/packages.list` 是 Android 边装边重写的文件，扫描撞上重写中的半截内容
就会「查无此行」→ 误判成"已卸载"→ 注销。注销之后**必须等下一次包安装/卸载事件**
才会重新扫描 —— 这就是「**卸载一个应用就恢复**」的真实机制。

### 修法（两头堵，均已落地）

内核侧（`Moli-Kernel-PAR-AL00` 仓库的 `patches/0002-ksu-throne-tracker-manager-rescan-retry.patch`）：

| 改动 | 说明 |
| --- | --- |
| 解析坏行不再 `break` | 原来一行异常就把整张 uid 表截断，改为跳过该行 `continue` |
| 注销后立刻重扫 | 去掉 `goto prune`，注销后当场再搜一次，误判可自愈 |
| 未认领则重试 | 搜完仍未认领 → 返回 false 走重试；预算 10×100ms → 30 次（前 10 次 100ms、之后 1s，约 20 秒窗口） |

用户态兜底（本模块 `service.sh`）：直接写内核参数，**不依赖 ksud 二进制是否已就绪**
（这次故障里 `ksud debug set-manager` 正是报 `No such file or directory` 才没兜住）：

```sh
KSUPARAM=/sys/module/kernelsu/parameters/ksu_debug_manager_appid   # 带 setter 的 module_param，写入即生效
A=$(awk '$1=="com.rifsxd.ksunext"{print $2; exit}' /data/system/packages.list)
[ "$(cat $KSUPARAM)" = "$A" ] || echo "$A" > "$KSUPARAM"
```

appid 从 `packages.list` 现取，所以**管理器重装/更新导致 uid 变化也不会失效**；
未生效则转后台每 5 秒重试，最多 2 分钟。

### 快速判断当前状态

```bash
su -c 'cat /sys/module/kernelsu/parameters/ksu_debug_manager_appid'   # 应为管理器 uid，而不是 4294967295
su -c 'grep ksunext /data/system/packages.list'                       # 对照这里的 uid
su -c 'dmesg | grep -E "Crowning manager|base.apk error"'
```

### 顺带澄清（仍然成立）

* 管理器版本(33214) 比内核版本(33193) 新，**不是**不支持的原因；两者用 uapi 通信，本例 uapi=2 一致。
* `ksud debug info` 里看不到 manager 信息，别拿它当判据。
* 这句提示跟"内核有没有 GKI"没关系，别被那句话带偏去刷 GKI 内核。

---

## 五、打开《王者荣耀》必自动重启 —— 内核 panic（`net_hw_hook_localout`）

**症状**：打开王者荣耀 → 黑屏重启，`getprop sys.resettype` = `abnormal:AP_S_PANIC`，**可复现**。

**一句话根因**：华为内核里 `drivers/huawei_platform/net/hw_netfilter/nf_hw_hook.S`
（**编译器生成的汇编**，替代 `.c` 发布）硬编码了 `struct sock` 的字段偏移（`sk_socket` = 744）。
自制内核打开了 `CONFIG_NAMESPACES`（连带 `CONFIG_NET_NS`），使 `possible_net_t skc_net`
从 **0 字节变成 8 字节** → `struct sock` 内其后所有成员**整体后移 8 字节** →
钩子读到的不再是 `sk_socket`，而是 `sk_tsflags`/`sk_shutdown`/填充字节，当作指针解引用即 panic。

```
PC is at net_hw_hook_localout+0x170/0x22c     x0 = 0x0000000000030000
故障地址 00030018                              0x03 正是 sk_shutdown(SHUTDOWN_MASK) 那一字节
调用链：tcp_write_timer → … → __tcp_retransmit_skb → __tcp_transmit_skb → 该钩子
```

**修法**：内核关掉 `CONFIG_NAMESPACES`（回到原厂 stock config 状态），并用编译探针断言
`offsetof(struct sock, sk_socket)==744` 等 10 项与原厂布局完全一致才允许打包。
实测刷入后打开王者荣耀不再重启，`/sys/fs/pstore` 为空。

完整证据链（oops 原文、逐条指令偏移、两套配置的布局探针比对表、复现条件、回滚方式）见
**`Moli-Kernel-PAR-AL00` 仓库的 `docs/panic-net_hw_hook_localout.md`**。

**通用教训**：内核树里存在「编译器生成的 `.S`」时，config 中任何影响核心结构体布局的开关
都不能随手打开 —— 偏移是编译期烘进二进制的，改 config 等于悄悄改变访存语义，**编译器不会报任何错**。

---

## 六、部署 / 救援侧的坑（2026-09-21 补）

### 1. `adb shell su -c "A; B"` 会吃掉引号，后半段变成非 root 执行

**现象**：脚本明明写了 `id -u` 检查 root，却报「需要 root」。

**原因**：`adb shell` 会把参数拼成一个字符串丢给设备端 shell 重新解析，
所以 `adb shell su -c "rm -rf /x; sh /sdcard/y.sh"` 到设备上变成
`su -c rm` + `-rf /x` + `;` + `sh /sdcard/y.sh` ——
`su -c` 只拿到了 `rm`，**后面那条 `sh` 是普通 shell 用户（uid 2000）跑的**。

**正确写法**：整条远端命令再包一层双引号，让设备端 shell 看到 `su -c '...'`

```sh
# 错
adb shell su -c "for m in a b; do umount /x/$m; done; rm -rf /x"
# 对
adb shell "su -c 'for m in a b; do umount /x/\$m; done; rm -rf /x'"
```

**判别方法**：在脚本里打印 `id`。如果看到 `uid=2000(shell)` 就说明引号掉了。

> 补充：这套设备上 `adb root` 模块会让 adbd 落在 `u:r:su:s0`，此时 `pm` / `am` / `cmd`
> 会报 `Failed transaction (2147483646)`（binder 跨域拒绝）。
> 需要 `pm`/`am` 时把 adbd 切回 shell 域，或者干脆用 root 直接读写文件。

### 2. 含 bind 挂载的目录树**绝对不能**直接 `rm -rf`  ← 这次把 `/dev` 删了

**事故**：在 `/data/oe_test` 下挂过 `mount --bind /dev`、`mount -t proc` 等用于验证 chroot。
清理时先 `umount -l`（lazy）紧接着 `rm -rf /data/oe_test`，`rm` 走进了 bind 过来的**真实 `/dev`**，
删掉了字符设备节点。

**后果**（不是立刻炸，是慢慢烂）：
* `/dev/null` 被后续进程按普通文件重新创建（54 字节），SELinux 标签是 `device` 而不是 `null_device`
* `zygote` 打开 `/dev/null` 被拒 → **应用进程起不来 → 桌面进程消失 → 黑屏、按键无响应、控制中心下不来**
* 长按电源键连关机菜单都不弹（`system_server` 也死了）
* 内核没 panic、adb 还活着 —— 所以看起来像"死机"，其实是框架全灭

**证据**（出问题时先看这两个）：

```sh
# 1) 设备节点是不是变成普通文件了（应该是 c 开头）
ls -l /dev/null /dev/zero /dev/random /dev/urandom /dev/ptmx
# 2) SELinux 拒绝日志，tclass=file 而不是 chr_file 就说明是普通文件
dmesg | grep 'name="null"'
# avc: denied { read write } for pid=... name="null" dev="tmpfs"
#      scontext=u:r:zygote:s0 tcontext=u:object_r:device:s0 tclass=file
```

**修法**：`/dev` 是内存文件系统（devtmpfs/tmpfs），**重启即由 ueventd 重建**，
数据分区一个字节不动。长按电源 20 秒强制重启即可，不需要刷机、不需要恢复出厂。
重启后核对：`ls -l /dev/null` 应显示 `crw-rw-rw- 1, 3`。

**规矩**（写进脚本了）：
* 任何 `rm -rf` 之前，先确认目标树下没有活着的挂载点：`mount | grep <目标>`
* 解挂载后再删；`umount -l` 之后要确认 `mountpoint -q` 已经为假再动手
* `install/prepare-rootfs.sh` 已加：跑之前先自动解挂载、提供 `--unmount`、
  且目标目录里已有 `www/server/panel` 时**直接拒绝执行**，绝不覆盖已装好的环境

### 3. Android 9 的 toybox 既没有 `curl` 也没有 `xz`

`install/qiyuntai-install.sh` 原来的 `step_rootfs` 用 `curl` 下载、用 `xz -d` 解压 ——
**在这台设备上跑不通**（`command -v curl` / `xz` 都为空），当初是手工铺的 rootfs。

现在 `step_rootfs` 优先调用 `install/prepare-rootfs.sh`，后者按
`curl → wget → busybox wget` 的顺序找下载工具（实测命中
`/data/adb/ksu/bin/busybox wget`），`xz` 缺失时明确提示改在电脑上解压后 `--tar` 推过来。

**通用教训**：写装机脚本别假设 Android 侧有 GNU 工具链。
`toybox` 的能力集随机型/版本变化，能用的东西先 `command -v` 探一遍再决定分支。
