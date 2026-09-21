# 栖云台 · 宝塔面板

> 把 **宝塔 Linux 面板** 装进安卓手机：通过 KernelSU 模块把 **openEuler 24.03 LTS-SP3 (aarch64) chroot** 开机自动挂载并拉起面板与全部组件，手机变随身服务器。
>
> 适用于已 root（KernelSU / Magisk）的 arm64 安卓设备。
> **可能存在未知错误，不保证兼容所有机型。**

```
作者：茉莉        QQ：1265274322
官方 Q 群：570387739
```

---

## 〇、模块「操作」按钮（最重要）

> 管理器的模块简介**只显示一行**（超出会变成省略号），所以完整信息放在「操作」按钮和本文件里。

模块自带 `action.sh`，在 KernelSU 管理器里点模块的**操作**按钮会：

1. 打印**面板地址 + 登录账号 + 登录密码**（读凭据文件，见下）
2. 逐个显示服务状态，发现没起来的会自动拉起来
3. 直接用手机浏览器打开面板

### 登录凭据在哪里

```
/data/openeuler/root/qiyuntai-panel-info.txt      # 权限 600，只有 root 能读
```

点「操作」按钮就是**读这个文件并打印**；文件不存在时，`action.sh` 会自动从安装日志/面板数据库里补出来。

### 端口 / 入口 / 账号 / 密码都是随机的

| 项 | 谁生成 | 说明 |
| --- | --- | --- |
| 端口 | 宝塔安装器随机 | 几位数随机（不是默认的 8888） |
| 入口路径 | 宝塔安装器随机 | 形如 `/` + 8 位随机串 |
| 用户名 | 宝塔安装器随机 | 8 位随机串 |
| 密码 | **安装脚本用 openssl 生成 16 位随机** | 每台设备都不一样 |

> 也就是说：**每台设备装出来都不一样**，不会出现"全网同一个密码"的问题。
> 换设备重装 = 重新随机一次，凭据重新写进上面那个文件。
> 文档里不写任何一台机器的真实值 —— 本机实况记在本地 `docs/private-deployment.md`（不进仓库）。

### 怎么改密码 / 端口 / 入口

```sh
chroot /data/openeuler /bin/bash
python3 /www/server/panel/tools.py
#   (5) 修改面板密码      (6) 修改面板用户名
#   (8) 改面板端口        (28) 修改面板安全入口
#   (14) 查看面板默认信息   ← 也能看地址和账号
```

非交互改密码（脚本里用）：

```sh
cd /www/server/panel && ./pyenv/bin/python3 -c "import tools; tools.set_panel_pwd('新密码', True)"
```

### 安全建议

* 首次登录后**立刻改成自己的密码**（面板设置里改，或用上面第 (5) 项）。
* 不要在路由器上把这个端口映射到公网；只在内网用。
* 凭据文件在 `/data/openeuler/root/`，是 root 权限 600，普通 App 读不到。

---

## 一、怎么访问面板

| 场景 | 地址 |
| --- | --- |
| 手机本机 / Termux / 设备内 | `http://127.0.0.1:<端口>/<入口>` |
| 同一 WiFi 下的电脑、平板 | `http://手机IP:<端口>/<入口>` |

* 手机 IP 在「设置 → WLAN → 当前网络」里看。
* `<端口>` 和 `<入口>` 每台机器不同，存这两个文件里，随时可查：

```sh
cat /data/openeuler/www/server/panel/data/port.pl        # 端口
cat /data/openeuler/www/server/panel/data/admin_path.pl  # 入口
```

* 懒得看文件？点模块的「执行」按钮，会直接把完整地址账号密码打印出来。

* **必须用浏览器打开**：宝塔有反爬虫，`curl` 默认 UA 会被直接丢 404（这是宝塔本身的行为，不是故障）。

### 忘记密码怎么办

```sh
# 进 chroot
chroot /data/openeuler /bin/bash
# 改密码 / 改端口 / 改入口（跟着提示走）
bt
# 或者直接指定
bt 5      # 修改面板密码
bt 8      # 修改面板端口
bt 6      # 修改面板入口
```

---

## 二、开机自动拉起哪些服务

模块 `service.sh` 在系统启动完成后依次执行（幂等，重复执行安全）：

1. 挂载 chroot：`/dev`、`/dev/pts`、`/dev/shm`、`/proc`、`/sys`
2. 写入 chroot 内 `/etc/resolv.conf`（DNS 取自 `net.dns1/dns2`，缺省补 223.5.5.5）
3. 修正 MariaDB 前置条件（把 `mysql` 用户加入 `inet` 组 = Android AID_INET 3003；校正数据目录属主）
4. 依次启动：**宝塔面板 → Nginx/OpenResty → MariaDB → PHP 8.2 FPM → Fail2ban → crond → Redis**
5. 自检面板端口是否响应（完整浏览器 UA），结果写进 `boot.log`

启动日志：`/data/adb/modules/qiyuntai_btpanel/boot.log`

### 重启实测结果（本机，2026-09-20 04:34）

```
[04:34:59] 系统启动状态：boot_completed=1 等待轮次=7
[04:35:02] 挂载成功 /data/openeuler/dev …（dev/pts、dev/shm、proc、sys 全部成功）
[04:35:02] 已写入 DNS: nameserver 223.5.5.5 119.29.29.29
[04:35:02] 启动 宝塔面板 (bt)          → Starting Bt-Panel.... done
[04:35:22] 启动 Nginx/OpenResty (nginx) → Starting nginx... done
[04:35:22] 启动 MariaDB (mysqld)        → SUCCESS!
[04:35:25] 启动 PHP 8.2 FPM (php-fpm-82)→ Starting php-fpm done
[04:35:25] 启动 Fail2ban (fail2ban)     → Server ready
[04:35:29] 启动 Redis
[04:35:34] 面板自检：已响应
```

重启后复核：面板 `HTTP=200`；端口 **80 / 888 / 3306** 与面板端口全部在监听；
`select version()` → `10.11.16-MariaDB-log`；`fail2ban-client status` → 2 个 jail（sshd、ftpd）。

> 提醒：`/etc/init.d/nginx status` 在运行时会打印 `already running.` 但返回码是 1，
> 这是宝塔自带脚本的写法，不代表 nginx 没跑（用 `ss -lntp` 或看端口更准）。

---

## 三、内置环境

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| 宝塔面板 | 9.5.0（aarch64 版） | 已解锁**永久企业版**、已**关闭更新**、**免账号绑定** |
| Web 服务器 | **OpenResty 1.31.1.1**（宝塔 nginx 卡片的 openresty 版本） | 源码编译，`/www/server/nginx` |
| 数据库 | **MariaDB 10.11 LTS** | 宝塔「MySQL」卡片里的 `mariadb_10.11` |
| PHP | **8.2** | `/www/server/php/82`，php-fpm |
| phpMyAdmin | **5.2** | `/www/server/phpmyadmin` |
| Fail2ban | **2.6**（插件版，内含 fail2ban 1.1.0） | 已实测可封禁/解封 IP |
| Redis | 7.2 | dnf 安装，开机自动拉起 |
| Python | 3.13（面板 pyenv）+ 系统 python3 + pip/venv | |
| Java | OpenJDK 17 / 11 / 8 | |
| Node.js | 20.18 + npm 10.8 | |
| 其他 | git、vim、htop、tmux、jq、sqlite3、rsync、lsof、net-tools、tcpdump、gcc/make/cmake 编译链 | |

以上组件都是**用宝塔官方脚本/官方插件安装的**，所以在面板「软件商店 → 已安装」里能正常显示、能启停。

---

## 四、注意事项（务必看）

1. **首次登录立刻改密码和端口**。面板设置 → 面板端口 / 面板密码；不要把端口直接暴露到公网。
2. **这是 Android 内核 4.9 上的 chroot，不是完整服务器**：
   * 内核**不支持 nf_tables**，所以 `iptables` 统一走 **legacy 表**（模块已在 `/usr/local/sbin/iptables` 做了指向 `iptables-legacy` 的包装），Fail2ban 的 `banaction` 也已改成 `iptables-multiport`（本内核**没有 ipset**，原版默认的 `firewallcmd-ipset` 用不了）。
   * chroot 里**没有 systemd**：模块内置了 `/usr/local/sbin/systemctl`、`service`、`start-stop-daemon` 兼容层，把 systemd 动作映射到 `/etc/init.d/*`，面板才能正常启停服务。
   * 面板里的「系统防火墙（firewalld）」「Docker」等功能在 Android 上不可用或不可靠，别指望。
   * **服务端功能无法伪造**：SSL 证书签发、短信、云备份、需要 bt.cn 账号的付费插件下载/授权等，仍然依赖宝塔服务器，断网或未登录时不可用——这是服务端校验，本地改不了。
3. **别删 `/data/openeuler`**。面板、网站、数据库全在里面；模块卸载脚本只解挂载，不删数据。
4. **手机内存只有 5.7 GB**。MariaDB + PHP-FPM + 面板同时跑会占 1 GB 左右，装/编译新软件前建议先释放内存，否则编译进程可能被系统杀掉。
5. **耗电与发热**：这是常驻服务，建议插着电用；不用时可以在 KernelSU 管理器里关掉本模块。
6. **改端口后记得同步防火墙/自检**：模块自检只是 curl 一次 127.0.0.1，改端口不影响它（端口是从 `data/port.pl` 读的）。

---

## 五、常用命令

```sh
# 进 chroot
chroot /data/openeuler /bin/bash

# 服务管理（chroot 内）
/etc/init.d/bt start|stop|restart
/etc/init.d/nginx start|stop|restart
/etc/init.d/mysqld start|stop|restart
/etc/init.d/php-fpm-82 start|stop|restart
/etc/init.d/fail2ban start|stop|restart

# 也可以直接用兼容层
systemctl restart nginx

# 看面板日志
tail -f /data/openeuler/www/server/panel/logs/error.log
tail -f /data/adb/modules/qiyuntai_btpanel/boot.log

# 看一眼当前跑着哪些服务
ps -ef | grep -E "BT-Panel|nginx|mysqld|php-fpm|fail2ban"
```

---

## 六、卸载

在 KernelSU 管理器里卸载本模块，或者手动：

```sh
sh /data/adb/modules/qiyuntai_btpanel/uninstall.sh
```

* 卸载脚本**只停服务 + 解挂载**，`/data/openeuler` 原样保留。
* 想彻底清理：`rm -rf /data/openeuler`（**确认不再需要里面的网站/数据库再执行**）。

---

## 七、回滚点

| 内容 | 位置 |
| --- | --- |
| 面板原始文件备份（破解前） | `/data/openeuler/www/server/panel/moli_patch/backup_*/` |
| 宝塔原版 lib.sh | `/data/openeuler/www/server/panel/install/lib.sh.bt-orig` |
| fail2ban 原 Debian 启动脚本 | `/data/openeuler/etc/init.d/fail2ban.debian-orig` |
| fail2ban 原 jail.local | `/data/openeuler/etc/fail2ban/jail.local.moli-orig` |
| 破解补丁本体 | `/data/openeuler/www/server/panel/moli_patch/moli_patch.py`（可重复执行） |

---

## 八、联系方式

```
作者：茉莉
QQ：1265274322
官方 Q 群：570387739
```

装完有问题先看 `boot.log` 和面板 `logs/error.log`，把报错发群里。
