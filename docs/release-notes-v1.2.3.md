# 栖云台 · 宝塔面板 v1.2.3

把**宝塔 Linux 面板**装进安卓手机的 KernelSU 模块。
底层是 openEuler 24.03 LTS-SP3 aarch64 chroot，开机自动挂载并拉起全部服务。

作者：**茉莉**　QQ：**1265274322**　官方Q群：**570387739**

---

## 这个 zip 里是什么

```
module.prop      模块信息
customize.sh     安装时执行（检测环境、给脚本加执行位）
service.sh       开机流程（挂载 chroot → 拉起 11 个服务 → 面板自检）
action.sh        模块「执行」按钮：打印地址账号密码 / 补拉服务 / 诊断
uninstall.sh     只停服务 + 解挂载，**不删 /data/openeuler**
README.md        使用说明
```

## 安装

模块本身**只管开机自启**，不含 chroot 环境。所以顺序是：

**第 1 步 —— 铺 rootfs（约 400 MB）**

```sh
# 方式 A：设备能上网，直接下
sh /sdcard/prepare-rootfs.sh --url <清华镜像的 openEuler-docker.aarch64.tar.xz 地址>
# 列可用文件：sh /sdcard/prepare-rootfs.sh --list

# 方式 B：电脑上下好再推（Android 9 的 toybox 没有 curl/wget/xz，这条更稳）
xz -d openEuler-docker.aarch64.tar.xz
adb push openEuler-docker.aarch64.tar /sdcard/
adb shell "su -c 'sh /sdcard/prepare-rootfs.sh --tar /sdcard/openEuler-docker.aarch64.tar'"
```

**第 2 步 —— 装面板与组件**

```sh
adb push install/ /sdcard/install/
adb shell "su -c 'sh /sdcard/install/qiyuntai-install.sh'"
```

**第 3 步 —— 刷本模块，重启**

**第 4 步 —— 点模块的「执行」按钮**，拿地址、账号、密码。

> 没先铺 rootfs 就刷模块也不会坏 —— `customize.sh` 会告警，开机流程会等环境就绪。

## v1.2.3 改了什么

### 模块

* **新增 sshd 兜底通道**（`service.sh` 第 4.7 段）：用 `/etc/ssh/sshd_config_moli` 拉起 sshd（`:22`），幂等。
  意义：adb 不通时它是唯一入口。
* **开机服务扩到 11 项**：补齐 `memcached / tomcat / supervisord`。
* **KernelSU 管理器认领加固**：写内核参数兜底，不依赖 `ksud` 是否就绪。
* **陈旧 pid 文件清理**：非正常关机后避免「已在运行」误判。
* **`action.sh` 新增诊断模式**：

  ```sh
  sh /data/adb/modules/qiyuntai_btpanel/action.sh diag
  ```

  检查挂载点 / chroot 可用性 / `inet` 组 / 服务进程 / 端口监听 / 面板自检 /
  `boot.log` 报错行 / 磁盘 / 破解补丁，**不重启任何服务**。
  另外主流程下面板自检不是 200 时会自动附诊断摘要。
* **`customize.sh` 修 bug**：原来漏给 `action.sh` 加执行位，「执行」按钮可能点不动。

### 安装脚本

* **新增 `install/prepare-rootfs.sh`**：rootfs 一键准备
  * 按 `manifest.json` 的**顺序**叠加 docker 层（原逻辑「取最大文件当 layer」多层镜像会解错）
  * 下载工具按 `curl → wget → busybox wget` 探测（实测 Android 9 两个都没有）
  * 退出打印解挂载提示 / 支持 `--unmount` / 目标目录已有面板就**拒绝执行**
* `install/qiyuntai-install.sh` 的 `step_rootfs` 改为委托上面那个脚本，保留内置逻辑兜底。
* 新增 `install/crond.initd`、`install/tomcat.initd`。

### 文档

* 新增 `CHANGELOG.md`
* `docs/handover.md` 对齐 v1.2.3，补 v1.2.3 重启实测日志
* `docs/pitfalls.md` 新增第六节：`adb shell su -c` 引号陷阱、
  **含 bind 挂载的目录禁止直接 `rm -rf`**（这个会把 `/dev` 删掉导致黑屏）、
  Android 9 toybox 没有 `curl`/`xz`
* 全部文档**脱敏**：去掉真实内网地址、面板入口、账号密码（仓库是公开的）
* 新增 `tools/verify_sync.sh`：本地 vs 远端逐文件比对，防再出现「本地改了没推上去」

---

## 环境要求

* **arm64 (aarch64)** 设备
* KernelSU / KernelSU-Next / Magisk（支持模块脚本的）
* 内核支持 `mount --bind` / `chroot` / `proc` / `sysfs` / `devpts` / `tmpfs`（Android 4.4+ 基本都满足）
* `/data` 留够 **10 GB**（rootfs + 面板与组件装完约 4-6 GB）

## 适用性

* 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / EMUI 9.1 / 内核 4.9.148 / aarch64）
* **不保证兼容所有机型**。32 位设备、x86 平板不适用。
* 部分 OEM 的 SELinux 策略更严格时，可能需要额外放宽策略。

## 卸载

```sh
# KernelSU / Magisk 管理器里卸载模块即可
```

`uninstall.sh` **只停服务 + 解挂载，不删 `/data/openeuler`** ——
你的网站、数据库、面板配置全部保留。要彻底删除请自己确认后执行 `rm -rf /data/openeuler`。

## 已知问题

* 面板里依赖 bt.cn 服务端校验的功能（SSL 签发、短信、云备份、需鉴权的付费插件）本地伪造不了
* 文档里的组件版本号来自交付时的实测，后续未逐项复核
