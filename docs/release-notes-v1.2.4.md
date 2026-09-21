# 栖云台 · 宝塔面板 v1.2.4

`versionCode = 10204` · 2026-09-21

把 **宝塔 Linux 面板** 装进安卓手机：`openEuler 24.03 LTS-SP3 (aarch64)` chroot +
宝塔官方组件，用 **KernelSU 模块** 开机自动挂载并拉起全部服务。

> 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / Android 9 / 内核 4.9.148）

---

## 这个 zip 里是什么

```
module.prop      模块信息
customize.sh     安装时执行（检测环境、给脚本加执行位）
service.sh       开机流程（挂载 chroot → 拉起 11 个服务 → 面板自检）
action.sh        模块「执行」按钮：打印地址账号密码 / 补拉服务 / 诊断
uninstall.sh     只停服务 + 解挂载，**不删 /data/openeuler**；--purge 才是安全删除
README.md        使用说明
```

**只需要这一个 zip**：`service.sh` 会挂挂载、拉服务。面板环境本身用
仓库里的 `deploy.ps1` / `install/deploy.sh` 装。

---

## 安装

### 1) 装面板环境（没装过的先做这步）

电脑上（需要 `adb`，能连 GitHub）：

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

一键跑完：推文件 → 铺 openEuler rootfs → 装面板 → 源码编译组件
→ 装 9 个面板插件 → 打补丁 → 装模块 → 重启。**约 2 小时**。

> 装第二台可以先打预制镜像再用 `install/deploy.sh --from-image`，约 10 分钟，
> 且完全不依赖宝塔的服务器。见仓库 README「预制镜像」。

### 2) 装 / 更新模块

```sh
adb push qiyuntai_btpanel-v1.2.4.zip /sdcard/
adb shell "su -c '/data/adb/ksud module install /sdcard/qiyuntai_btpanel-v1.2.4.zip'"
```

* `ksud` 在 **`/data/adb/ksud`**（不在 `PATH` 里）
* 解包到 `/data/adb/modules_update/<id>`，执行 `customize.sh`，**重启后生效**
* 也可以在 KernelSU 管理器里「从本地安装」选这个 zip

> 手工装**别用** `cp -r module /data/adb/modules/qiyuntai_btpanel` ——
> 目标目录已存在时 `cp -r` 会嵌套成 `…/qiyuntai_btpanel/module/module.prop`，模块加载不了。
> 要用 `cp` 就这么写：`mkdir -p 目标 && cp -f module/* 目标/`

重启后点模块的「执行」按钮，地址、账号、密码会直接打印出来。

---

## v1.2.4 改了什么

### 模块

* **`action.sh` 的磁盘诊断修好了**：原来用 `df -k /data | awk 'NR==2{print $4}'`，
  而本机 `df` 的输出会因为设备名过长**折成三行**，`NR==2` 取到的是设备名那行 →
  拿到空值 → 磁盘那一栏一直显示空。改用 `df -P`（POSIX 输出，强制一个文件系统一行）。
* **`uninstall.sh` 新增 `--purge`**：原来在提示里直接教 `rm -rf /data/openeuler` ——
  而 chroot 的 `/dev` 是 `mount --bind /dev`（宿主真实 `/dev` 的绑定挂载），
  挂着它 `rm -rf` 会删掉设备节点、**手机黑屏**（实测踩过两次）。
  现在 `--purge` 会**先证明 `$ROOT/` 下挂载数为 0，再删**；不为 0 直接拒绝并打印挂载表。
  默认提示也改成了安全的做法。
* **`README.md`（模块内）与实际代码对齐**：§二开机流程原来只列 7 项服务（实际 11 项）、
  漏了 KernelSU 管理器注册与陈旧 pid 清理；§三没列那 9 个面板插件；§五的 init.d 列表只列 5 个。

### 仓库侧（不属于这个 zip，但会影响部署）

* **一键部署原来跑不完**，这一版修掉一串真 bug：`step_rootfs` / `deploy.sh` 都没给
  `prepare-rootfs.sh` 传「源」、清华镜像对文件下载挑 User-Agent（403）、
  `prepare-rootfs.sh` 的「验证 chroot」用 `head` 但不设 PATH 而误报、
  `expect` 驱动的两个自身 bug。
* **`step_plugins` 原来只装 1 个插件，文档承诺 9 个** —— 装出来的环境是残缺的
  （缺 redis / tomcat / supervisor / nodejs / JDK），而且缺的服务只是被"跳过"、
  没有任何地方报错。现在装全 9 个，有缺失就失败。
* **`deploy.ps1` 原来没推 `tools/`** —— 而 `step_plugins` 要 `plugin_install.py`、
  `step_patch` 要 `moli_patch.py`，缺了必然失败。
* **破解补丁加三道守卫**：面板版本白名单、已打过就跳过、未生效项当门槛
  （原来找不到补丁点只打一行 `[跳过]` 然后照样退出 0，会装出四不像）。
* **新增预制镜像**（`tools/make_image.sh` + `deploy.sh --from-image`）：装好一次冻成镜像，
  以后重装 = 解包，约 10 分钟、零上游依赖。镜像里存**未打补丁的原版**，
  部署时再打补丁，并在部署时**重新随机化端口/安全入口/用户名/密码**。
* **新增极简 CI**（`tools/ci.sh` + GitHub Actions）：shellcheck / 语法 / py_compile /
  行尾 / BOM / 哈希格式 / README 结构节覆盖 / 字符层面检查，共 9 项。

---

## 环境要求

* **arm64 设备**，已 root（KernelSU-Next / KernelSU / Magisk 都行）
* `/data` 空闲 **≥ 20 GB**（实测装完 17.7 GB；其中 MariaDB 编译构建树 8.8 GB 运行时可删）
* Android 9 起（实测 Android 9 / 内核 4.9.148）

---

## 适用性

* 实测只覆盖 **PAR-AL00（nova 3 / 麒麟 970 / Android 9 / 内核 4.9.148）** 这一台。
* 换机型要重新确认三件事：内核版本、SELinux 策略、KernelSU 版本。
  内核没有 `nf_tables`/`ipset` 的话 Fail2ban 得走 iptables-legacy（本模块已这么配）。
* 不保证兼容所有机型。

---

## 卸载

```sh
# KernelSU / Magisk 管理器里卸载模块即可（只解挂载，不删数据）
```

要**彻底删除**面板环境：

```sh
sh /data/adb/modules/qiyuntai_btpanel/uninstall.sh --purge
```

它会先确认挂载干净再删。**不要直接 `rm -rf /data/openeuler`** —— 见上面 v1.2.4 的说明。
