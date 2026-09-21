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

**一键部署（推荐）** —— 电脑上执行（电脑能连 GitHub、有 adb）：

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

脚本会自动：找 adb → 等设备 → 确认 root → 推 `install/` 和 `module/` → 在手机上跑
`install/deploy.sh`（铺 rootfs → 装面板/组件/插件/补丁 → 装模块）→ 重启手机。

参数：`-Check` 只体检 / `-PushOnly` 只推文件 / `-NoReboot` 不自动重启 / `-Adb <路径>`。

分步来也可以：

```sh
adb push install/ /sdcard/install/
adb push module/  /sdcard/module/
adb shell "su -c 'sh /sdcard/install/deploy.sh --check'"    # 先体检
adb shell "su -c 'sh /sdcard/install/deploy.sh'"            # 全自动装
```

**只想要模块（环境已经好了）？** 直接刷这个 zip：

```sh
adb push qiyuntai_btpanel-v1.2.3.zip /sdcard/
adb shell "su -c '/data/adb/ksud module install /sdcard/qiyuntai_btpanel-v1.2.3.zip'"
```

拿地址账号密码：

```sh
adb shell "su -c '/data/adb/ksud module action qiyuntai_btpanel'"
```

出问题先诊断：

```sh
adb shell "su -c 'sh /data/adb/modules/qiyuntai_btpanel/action.sh diag'"
```

> `ksud` 在 `/data/adb/ksud`（不在 PATH 里）。手工装**别用** `cp -r module 目标` ——
> 目标已存在时会嵌套成 `目标/module/module.prop`，模块加载不了。

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
* **修 `MODDIR` 推导**：四个脚本原来都写 `MODDIR=${0%/*}`，当 `$0` 不含 `/`
  （手工 `cd 模块目录 && sh action.sh`）时会退化成文件名本身，
  拼出来的路径变成 `action.sh/action.sh`。实测在诊断提示里出现过这一串。
  现在绝对路径调用走 `${0%/*}`，相对调用走 `cd $(dirname $0) && pwd`。

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

