# 栖云台 · 宝塔面板（安卓 aarch64 · KernelSU 模块）

把 **宝塔 Linux 面板** 装进安卓手机：`openEuler 24.03 LTS-SP3 (aarch64)` chroot + 宝塔官方组件，用 **KernelSU 模块** 开机自动挂载并拉起全部服务。

> 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / Android 9 / 内核 4.9.148）
> 适用范围与限制见下面「五、适用性」。

```
作者：茉莉        QQ：1265274322
官方 Q 群：570387739
```

---

## 一、这套东西是什么

| 层 | 内容 |
| --- | --- |
| 底层 | openEuler 24.03 LTS-SP3 aarch64 chroot，落在 `/data/openeuler`（约 400 MB 起，装完组件约 4-6 GB） |
| 面板 | 宝塔面板（aarch64 版），端口/入口**安装时随机**（每台机器不同，见下文「怎么访问」），已解锁**永久企业版**、**关闭更新**、**免 bt.cn 绑定** |
| 环境组件 | **OpenResty 1.31.1.1**、**MariaDB 10.11.16**、**PHP 8.2.33**、**phpMyAdmin 5.2**、**Redis 7.2.16**、**Memcached 1.6.45**、**Tomcat 9.0**、**Supervisor 4.2.4** |
| 管理插件 | Fail2ban 2.6、Node.js版本管理器 2.8（内置 node **v20.18.2**）、java环境管理器 / jdk_manager（内置 JDK **17.0.20.8**）、Python项目管理器（`pythonmamager`）、python环境管理器（`pyenv_manager`）、Supervisor 进程管理器、Tomcat（`tomcat2`）、Redis |
| 额外环境 | Python 3.13.14 + pip/venv、OpenJDK 17.0.20.8 / 11.0.32.9 / 1.8.0_502、Node.js v20.18.2 + npm 10.8.2、git/vim/htop/tmux/jq/sqlite3、完整编译链、iptables-legacy |
| 开机自启 | KernelSU 模块 `qiyuntai_btpanel`：挂 chroot → 写 DNS → 修正 Android 网络限制 → 依次拉起 **面板/nginx/MariaDB/PHP-FPM/Fail2ban/crond/Redis/Memcached/Tomcat/supervisord** → 自检 |

---

## 二、怎么访问 / 账号密码在哪

| 场景 | 地址 |
| --- | --- |
| 设备内 / 手机浏览器 | `http://127.0.0.1:<端口>/<入口>` |
| 同一 WiFi 的电脑 | `http://手机IP:<端口>/<入口>` |

> `<端口>`、`<入口>`、账号、密码都是**安装时随机生成**的，每台设备都不一样。
> 查自己的值：点模块「执行」按钮，或读 `/data/openeuler/root/qiyuntai-panel-info.txt`。

**怎么拿到自己的地址和账号密码**（三种方式任意一种）：

1. **点模块的「执行」按钮** —— 直接打印地址 + 用户名 + 密码（最省事）
2. 看凭据文件：
   ```sh
   cat /data/openeuler/root/qiyuntai-panel-info.txt     # root 权限 600
   ```
3. 面板自己的命令行（菜单第 14 项也能看）：
   ```sh
   chroot /data/openeuler /bin/bash
   python3 /www/server/panel/tools.py
   #   (5) 改密码  (6) 改用户名  (8) 改端口  (28) 改安全入口  (14) 查看面板默认信息
   ```

* 手机 IP：设置 → WLAN → 当前网络。
* 端口 / 入口随时可查：
  ```sh
  cat /data/openeuler/www/server/panel/data/port.pl
  cat /data/openeuler/www/server/panel/data/admin_path.pl
  ```
* **必须浏览器访问**：宝塔有反爬虫，`curl` 默认 UA 会被丢 404（面板自身行为，不是故障）。
* 随机化：端口/入口/用户名由宝塔安装器随机；**密码由 `install/qiyuntai-install.sh` 用 `openssl rand -hex 8` 生成 16 位随机**并写入凭据文件 → 不会出现"全网同一个密码"。

---

## 三、安装步骤（从零）

> 需要：已 root（KernelSU / Magisk）、`su` 可用、`/data` 有 ≥8 GB 空闲、能连外网。

```sh
# 1) 取 openEuler aarch64 rootfs（清华镜像，约 39 MB）
#    https://mirrors.tuna.tsinghua.edu.cn/openeuler/openEuler-24.03-LTS-SP3/docker_img/aarch64/
#    文件名形如 openEuler-docker.aarch64.tar.xz
xz -d openEuler-docker.aarch64.tar.xz
mkdir -p /data/openeuler
tar -xf openEuler-docker.aarch64.tar -C /data/oe_layer
# 把 layer 里的文件系统解到 /data/openeuler（具体见 install/qiyuntai-install.sh）

# 2) 挂载 chroot
/data/adb/modules/qiyuntai_btpanel/service.sh    # 或按 install 脚本里的 mount 段手动挂

# 3) 一键部署（chroot 内装面板 + 组件 + 打补丁）
sh install/qiyuntai-install.sh

# 4) 装模块
cp -r module /data/adb/modules/qiyuntai_btpanel
chmod 755 /data/adb/modules/qiyuntai_btpanel/*.sh
# 重启手机，服务自动起来
```

详细的分步说明见 `install/` 目录下的脚本注释。

---

## 四、注意事项（重点）

1. **首次登录立刻改密码与端口**（面板设置里改，或用 `tools.py` 的 (5)(8) 项），别把端口直接暴露公网。
2. **这不是完整服务器**：
   * **iptables**：本机内核不支持 nf_tables，仓库在 `/usr/local/sbin/iptables` 放了指向 `iptables-legacy` 的包装，Fail2ban 的 `banaction` 改为 `iptables-multiport`（内核无 ipset，默认的 `firewallcmd-ipset` 用不了）。换设备时若你的内核支持 nf_tables，可自行改回。
   * chroot 里**没有 systemd**：仓库内置 `/usr/local/sbin/{systemctl,service,start-stop-daemon}` 兼容层，把 systemd 动作映射到 `/etc/init.d/*`，面板才能启停服务。
   * **Android paranoid-network**：内核只允许 root 或 AID_INET(gid 3003) 组成员创建 AF_INET socket，所以 `mysql`/`redis` 用户必须加进 `inet` 组，否则 MariaDB/Redis 起不来（`install/android-network-fix.sh` 会做，模块每次开机也会兜底）。
3. **装组件要用宝塔自己的脚本**。宝塔商店判断「已安装」看的是云端列表里写死的 `install_checks` 路径（Nginx → `/www/server/nginx/sbin/nginx`，MySQL → `/www/server/mysql/bin/mysql`，PHP → `/www/server/php/{版本}/bin/php`，插件 → `/www/server/panel/plugin/<名字>`，Memcached → `/usr/local/memcached/bin/memcached`，Tomcat → `/www/server/tomcat/bin/catalina.sh`）。用 `dnf` 装 nginx/mariadb 的话，面板里永远显示「未安装」也没法启停。
4. **插件只装一个，别装互斥的**：`nodejs`(Node.js版本管理器) 与 `pm2`(PM2管理器) 功能重复会打架；装了插件还要把它的"托管对象"装上，否则进插件界面是空的（例如 nodejs 插件要在里面装一个 node 版本，jdk_manager 要在里面装一个 JDK）。
5. **Tomcat 版本选择**：宝塔的 `tomcat.sh` 在 aarch64 上会因为要下 **x86_64 的 JDK rpm** 而让 `jsvc` 编译失败 —— 用仓库里的 `install/tomcat.initd`（显式指定 JDK，走 `catalina.sh`）即可正常启停；**Tomcat 11 在 ARM 上不要装**（脚本写死下 x64 JDK）。
6. **内存**：MariaDB 编译峰值约 2 GB，装大件前先释放内存，否则编译进程会被系统杀。
7. **耗电发热**：常驻服务，建议插电使用；不想用了在 KernelSU 管理器里禁用模块即可。
8. **卸载只解挂载、不删 `/data/openeuler`**。

---

## 五、适用性（Android 版本 / 机型）

**能用的前提**（三条同时满足）：

1. **arm64 (aarch64) 设备** —— 根文件系统就是 aarch64 的 openEuler；32 位设备、x86 平板不适用。
2. **已 root，且装了 KernelSU 或 Magisk** —— 模块靠 `/data/adb/modules/<id>/service.sh` 在开机后跑脚本。
   * KernelSU-Next 官方只发 GKI 内核的 `.ko`；非 GKI 老内核（如 4.9/4.14）需要**自己编译带传统驱动（manual hook）的内核**。
   * **管理器首页显示「不支持 / 未集成」「不支持非 GKI 内核」时，先别急着刷内核** —— 实测这是**管理器没在内核里注册**（内核不持久化 manager appid，重启后回到未注册）：App 拿不到 root → 查不到内核状态 → 界面就退化成那句误导性提示。修法 `ksud debug set-manager com.rifsxd.ksunext`（需内核 `CONFIG_KSU_DEBUG=y`）。**本模块 `service.sh` 已内置这一步（带 3 次重试），每次开机会自动注册**；完整排查证据见 `docs/pitfalls.md` 第四节。
3. **内核支持 mount / chroot / proc / sysfs / devpts / tmpfs** —— Android 4.4+ 基本都满足；需要能 `mount --bind`，部分 OEM 的 SELinux 策略更严格时可能要放宽策略。

**Android 版本**：9 ~ 16 在原理上都能跑（本项目在 Android 9 / 内核 4.9.148 上完整实测），因为用到的都是 Linux 层能力，不依赖 Android 版本：

* Android 12+ 有 phantom process killer，会杀"由 App 派生"的后台进程；本模块的服务是 KernelSU 的 `service.sh`（root/daemon 上下文）拉起的，不属被杀的 App 进程组。
* Android 13+ 对 `/data` 的 SELinux 更严；如遇到 mount 被拒，先看 `dmesg | grep avc`。

**本机实测机型**：HUAWEI PAR-AL00（Kirin 970 / 鸿蒙 2.0 / 内核 4.9.148 / Android 9）。

---

## 六、仓库结构

```
module/                  KernelSU 模块（刷这个）
  module.prop             模块信息（id / 版本 / 作者）
  customize.sh            安装时执行：检测环境、给脚本加执行位
  service.sh              开机流程：挂载 chroot → 拉起 11 个服务 → 面板自检
  action.sh               模块「执行」按钮：凭据 / 补拉服务 / diag 诊断
  uninstall.sh            只停服务 + 解挂载，不删 /data/openeuler
  README.md               模块使用说明

install/                 设备上执行的部署脚本
  prepare-rootfs.sh       铺 openEuler rootfs（按 manifest.json 顺序叠层）
  qiyuntai-install.sh     一键装：rootfs → 挂载 → 面板 → 组件 → 补丁 → 模块
  chroot-compat-layer.sh  systemctl/service/start-stop-daemon/iptables-legacy 兼容层
  android-network-fix.sh  paranoid-network 的 inet 组修正
  crond.initd             chroot 缺这两个 init 脚本，crond/tomcat 起不来
  tomcat.initd
  lib-shim.sh

tools/                   辅助脚本
  moli_patch.py           面板改造补丁（永久企业版 / 关闭更新 / 免绑定），幂等
  plugin_install.py       宝塔插件安装器（走官方下载接口，无需登录面板）
  store_check.py          核对商店「已安装」状态
  build_module_zip.sh     打可刷模块 zip（带版本自检）
  verify_sync.sh          本地 vs 远端逐文件比对

docs/                    说明与记录
  handover.md             交付说明（含版本复核记录）
  pitfalls.md             踩坑记录（全部为实测结论）
  release-notes-v1.2.3.md 该版本的 Release 说明
  private-deployment.md   本机真实地址与口令（已 gitignore，不进仓库）

CHANGELOG.md              更新日志
```

---

## 七、实测记录

**实测通过（2026-09-20 本机）**
* 面板安装、登录页 `HTTP 200`、局域网访问 `http://手机IP:<端口>/<入口>` → 200
* OpenResty **1.31.1.1** 源码编译，`nginx -t` 通过，监听 80 / 888
* MariaDB **10.11.16** 编译安装，`select version()` → `10.11.16-MariaDB-log`，监听 3306
* PHP **8.2.33** 编译安装，php-fpm 运行，`/tmp/php-cgi-82.sock` 就绪
* phpMyAdmin **5.2**，`/www/server/phpmyadmin/version.pl` = `5.2`
* Fail2ban **2.6** 插件（内含 fail2ban 1.1.1.dev1）：启动 → 封禁 `203.0.113.9` → `iptables-legacy` 出现 `f2b-sshd` 规则 → 解封后规则消失
* 补丁生效：`get_soft_list` 返回 `ltd=-2 / pro=-2`（面板显示企业版·永久）、`is_bind()` 恒真、升级脚本已空壳
* 商店状态核对：nginx / mysql(MySQL 卡片) / php-8.2 / phpmyadmin / fail2ban / nodejs 全部 **已安装**
* **两次重启实测**：模块自动挂载 chroot、写 DNS、拉起 bt / nginx / MariaDB / php-fpm-82 / fail2ban / crond / Redis，
  面板自检 `HTTP=200`，端口 80/888/3306 与面板端口全部监听（日志见 `boot.log`）


---

## 八、联系方式

```
作者：茉莉
QQ：1265274322
官方 Q 群：570387739
```
