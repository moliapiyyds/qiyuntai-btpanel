# 栖云台 · 宝塔面板 v1.2.5

`versionCode = 10205` · 2026-09-22

把 **宝塔 Linux 面板** 装进安卓手机：`openEuler 24.03 LTS-SP3 (aarch64)` chroot +
宝塔官方组件，用 **KernelSU 模块** 开机自动挂载并拉起全部服务。

> 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / Android 9 / 内核 4.9.148）

---

## 这一版在修什么

一句话：**把「文档里承诺了、部署脚本从没做过」的东西一处一处补上。**

v1.2.4 交付之后我把删除前那台的环境整个对了一遍账，方法是拿三样「基线实测数据」
反查脚本 —— 基线的 `rpm -qa` 清单、基线的 `/etc/init.d/` 列表、基线的 `netstat` 端口。
**只看脚本永远查不出这类问题**，因为缺的东西不会报错，只会静默跳过。
查出来四类：

| # | 缺什么 | 后果 | 现在怎么补 |
|---|---|---|---|
| 1 | `/etc/init.d/{crond,tomcat,memcached}` | `service.sh` 的 `start_svc` 见不到文件只打印一行「跳过」，**Tomcat / Memcached 永远起不来而日志看着正常** | 仓库自带 `.initd`，`step_patch` 装进 chroot |
| 2 | `openssh-server` + `/etc/ssh/sshd_config_moli` | adb 不通时唯一的救命通道（`:22`）起不来 | `step_deps` 装包 + 新增 `install/sshd_config_moli` |
| 3 | memcached 的**二进制** | 面板里 Memcached 永远显示「未安装」 | 从宝塔源码包编 1.6.45 到 `/usr/local/memcached` |
| 4 | 一批基线里有的 rpm（java / jq / htop / bind-utils / libpcap …） | 环境跟标准环境不是同一个 | 新增 `step_parity`：按 548 条基线包清单自动对齐 |

### 1) 三个 init 脚本：仓库里躺着，但没有任何脚本引用

`module/service.sh` 开机要拉起 11 项服务，逐个对「它的 `/etc/init.d/<名>` 谁提供」：

| 服务 | init 脚本来源 |
|---|---|
| `bt` `nginx` `mysqld` `php-fpm-82` | 宝塔安装器 / 组件安装脚本 |
| `fail2ban` `redis` | 宝塔对应插件 |
| `crond` `tomcat` `memcached` | **没有任何上游来源** |

`install/crond.initd` 和 `install/tomcat.initd` 早就在仓库里，但**只出现在文档里**，
没有任何脚本把它们 `cp` 进 chroot。`memcached` 更彻底 —— 连 `.initd` 都没有。
现在三个都由 `step_patch` 安装。

失败方式是**静默**的：`start_svc` 见不到文件就打印一行「跳过」然后返回，不报错也不返回非零。

### 2) sshd 兜底通道

`module/service.sh` 第 4.7 段用 `/etc/ssh/sshd_config_moli` 拉起 `/usr/sbin/sshd`，
文档也写着，但既没有脚本装 `openssh-server`，也没有脚本写这个配置文件。
基线里它是活的（`netstat` 有 `0.0.0.0:22`，`pkglist_pre.txt` 有 `openssh-server-9.6p1-21`）。

现在 `step_deps` 装 `openssh-server openssh-clients`，`step_patch` 装配置并在缺主机密钥时
跑一次 `ssh-keygen -A`。配置文件是**从删除前的备份 tarball 里原样取出来的**：

```
365 字节  sha256 951da0fbe8f7e6101582d61fd2778a4094fd4c536e6adf4e81fa992bd2e064d7
```

`--from-image` 时还会 `rm -f /etc/ssh/ssh_host_*` + `ssh-keygen -A` **重新生成主机密钥**，
否则同一个镜像刷多台设备会共用同一份密钥。

### 3) memcached：连二进制都没有来源

上一轮补了 init 脚本，再往下问「这个二进制哪来的」，发现同样没人管：

* 面板 13.0.0 的 `install/install_soft.sh` 里**已经搜不到 memcached**
* 商店那 9 个插件里也没有 memcached 插件
* openEuler 源里只有 **1.6.22**，而基线是 **1.6.45**，装在 `/usr/local/memcached/bin/memcached`
  —— 那正是从备份 tarball 里取出的 **2019-09-19 那份宝塔 init 脚本**写死的路径，
  也正是 README 里写的「面板商店判断 Memcached 装没装看这个路径」

实测宝塔下载站：`memcached-1.6.45.tar.gz` → **200**，`1.6.22` / `1.6.38` → **404**。
所以基线那份就是这个源码包编的。新增 `step_memcached` 照原路径编 1.6.45：

```
1,272,659 字节  gzip 魔数 1f8b  顶层目录 memcached-1.6.45
sha256 d362c64e6d8d5287153501eabf7c85b4a761432fbf53f5d7b085d0bb1653c1dd（pin 在脚本里）
```

编不出来才退回 dnf 的 1.6.22，**并在日志里明说版本与基线不同** —— 不假装一样。

### 4) 新增「基线包对齐」步骤（`parity`）

手写脚本漏装是常态，读代码查不全，那就对数据：仓库里带一份
`install/baseline-packages.txt`，就是删除前那台的 `rpm -qa` 输出，

```
548 行 / 20899 字节
sha256 4b3c870ad51d957f3c357aa97a96d921fde358264b77f9f2319d591eb2890f31
```

（与设备上那份逐字节一致，可以自己核。）

`parity` 步骤按**包名**比对（版本会被软件源往前推 —— 实测 `glibc`/`libxml2`/`util-linux`
等 20 来个名字相同版本不同，所以只能比名字），缺的先批量 `dnf install`、
不行再逐个兜底装，最后**如实报告当前源里已经没有的那些名字**，而不是假装装全了。

---

## 这个 zip 里是什么

```
module.prop      模块信息（v1.2.5 / 10205）
customize.sh     安装时执行（检测环境、给脚本加执行位）
service.sh       开机流程（挂载 chroot → 拉起 11 个服务 → 面板自检）
action.sh        模块「执行」按钮：打印地址账号密码 / 补拉服务 / 诊断
uninstall.sh     只停服务 + 解挂载，**不删 /data/openeuler**；--purge 才是安全删除
README.md        使用说明
```

`module/` 的**代码逻辑相对 v1.2.4 没有改动**，只有 `module.prop` 的版本号跟着升了。
切这个版本号是为了让 **tag / Release 附件 / 预制镜像** 三者指向同一个提交 ——
否则镜像里的脚本是 main、tag 却停在 v1.2.4，附件与源码对不上。

---

## 安装

### 1) 装面板环境

电脑上（需要 `adb`，能连 GitHub）：

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

一键跑完：推文件 → 铺 openEuler rootfs → 装面板 → 源码编译组件
→ 装 9 个面板插件 → 基线包对齐 → 打补丁 → 装模块 → 重启。**约 2 小时**。

### 2) 装 / 更新模块

```sh
adb push qiyuntai_btpanel-v1.2.5.zip /sdcard/
adb shell "su -c '/data/adb/ksud module install /sdcard/qiyuntai_btpanel-v1.2.5.zip'"
```

* `ksud` 在 **`/data/adb/ksud`**（不在 `PATH` 里）
* 解包到 `/data/adb/modules_update/<id>`，执行 `customize.sh`，**重启后生效**
* 也可以在 KernelSU 管理器里「从本地安装」选这个 zip

> 手工装**别用** `cp -r module /data/adb/modules/qiyuntai_btpanel` ——
> 目标目录已存在时 `cp -r` 会嵌套成 `…/qiyuntai_btpanel/module/module.prop`，模块加载不了。
> 要用 `cp` 就这么写：`mkdir -p 目标 && cp -f module/* 目标/`

重启后点模块的「执行」按钮，地址、账号、密码会直接打印出来。

---

## 装完是什么样（与基线逐项对比）

| 项 | 值 |
|---|---|
| 面板 | 宝塔 **13.0.0**（改造后永久企业版、关闭更新、免绑定） |
| 组件 | OpenResty **1.31.1.1** / MariaDB **10.11.16** / PHP **8.2.33** / phpMyAdmin **5.2** |
| 缓存与队列 | Redis **7.2.16**（插件版）/ Memcached **1.6.45**（宝塔源码包编） |
| Tomcat | **9.0**（`catalina.jar` 9.0.62） |
| 面板插件 | **9 个**：fail2ban redis tomcat2 supervisor nodejs java_manager jdk_manager pyenv_manager pythonmamager |
| 开机服务 | **11 项**：bt nginx mysqld php-fpm-82 fail2ban crond redis memcached tomcat + supervisord + sshd |
| 端口 | 80 / 888 / 3306 / 6379 / 11211 / 8080 / 8005 / 22 / 面板随机高位端口 |
| rpm 包 | 按基线 548 条对齐（`parity` 步骤，差额会在安装日志里列出） |
| 磁盘 | 环境约 **17.7 GB**（`www/server/mysql/src` 的编译树会被镜像清理掉，不会进镜像） |

---

## 校验

```
qiyuntai_btpanel-v1.2.5.zip   SHA256  <见 Release 附件说明>
```

预制镜像分卷的校验和在同一次 Release 的 `SHA256SUMS.txt` 里；
`install/deploy.sh --from-image` 会自己重算并比对，**对不上拒绝铺环境**。

---

## 已知限制（都实测过）

* 只在 **HUAWEI PAR-AL00（麒麟 970 / Android 9 / KernelSU-Next 3.3.0）** 上验证过，
  其它机型不保证；`cgroup` / `SELinux` 策略差异可能导致某个服务起不来。
* 首次装环境要**源码编译** MariaDB（约 1.5 小时，峰值吃 2 GB 内存）与 PHP。
  想快就用预制镜像，10 分钟级。
* `memcached` 只有宝塔源码包这条路能给到基线版本（1.6.45）；
  宝塔哪天把那个 tarball 下架，脚本会退回 dnf 的 1.6.22 并打警告。
* 宝塔官方安装器 `install_panel.sh` 的 sha256 锁在 `install/installer.lock`：
  官方一改脚本就会**拒绝安装**（而不是拿没核验过的脚本硬跑）。要升就比对后改这个文件。
* 这个环境的用途是「在自己手机上跑一个面板」，**不保证兼容**所有机型与后续的
  Android / 宝塔版本；升级前请先看 `CHANGELOG.md` 与 `docs/pitfalls.md`。
