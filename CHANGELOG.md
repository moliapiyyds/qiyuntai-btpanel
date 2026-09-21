# 更新日志

> **关于 v1.2.3 之前**：当时这个目录还不是 git 仓库，发布靠逐文件调 GitHub Contents API，
> 所以没有逐版本的记录。下面只写我在文件内容、文件时间戳和提交信息里**能核实**的东西，
> 核实不了的一律不写 —— 与其编一份好看的假历史，不如承认这段没有记录。

---

## v1.2.3 — 2026-09-20

`versionCode = 10203`

### 模块

* **开机自动拉起 sshd**：`service.sh` 新增第 4.7 段「SSH 兜底通道」。
  用 `/etc/ssh/sshd_config_moli` 启动（监听 `:22`），并且是幂等的
  —— 已经在跑就只记一条日志，不重复拉起。
  这条通道的意义：adb 不通时（比如这次 `/dev` 出问题）它是唯一的救命入口。
* **开机服务扩充到 11 项**：在原有的 `bt / nginx / MariaDB / php-fpm-82 / fail2ban / crond / redis`
  之外补齐 `memcached / tomcat / supervisord`，sshd 单独兜底。
* **KernelSU 管理器认领加固**：写内核参数兜底，不依赖 `ksud` 是否已经就绪
  （实测开机日志 `KernelSU 管理器已注册 [com.rifsxd.ksunext appid=10166]`）。
* **陈旧 pid 文件清理**：非正常关机后 `crond`/`redis` 的 pid 文件会残留，
  开机时先清掉再启动，避免「已在运行」的误判。
* `module.prop` 描述改为：`点「执行」看地址账号密码｜卸载不删数据｜端口密码每台随机｜不保证兼容所有机型`
* **修 `MODDIR` 推导**：原来四个脚本都写 `MODDIR=${0%/*}`，当 `$0` 不含 `/` 时
  （手工 `cd 模块目录 && sh action.sh`）会退化成文件名本身，拼出的路径变成
  `action.sh/action.sh`。实测在诊断提示里出现过 `sh customize.sh/action.sh diag`。
  现在改成：绝对路径调用走 `${0%/*}`，相对调用走 `cd $(dirname $0) && pwd`。
* **`customize.sh` 补 `action.sh` 的执行位**：原来只 chmod 了
  `service.sh / uninstall.sh / customize.sh`，模块「执行」按钮可能因为缺执行位点不动。

### 安装脚本

* 新增 `install/crond.initd`、`install/tomcat.initd` —— chroot 里没有 systemd，
  这两个服务的 init 脚本由仓库提供，否则 `systemctl start crond` 兼容层没有可映射的目标。

---

## v1.2.2 及更早

**无逐版本记录。** 已知在这个阶段落地的东西（按文件时间戳与提交信息推断，非逐版本归属）：

* 首次交付：openEuler 24.03 LTS-SP3 aarch64 chroot + 宝塔面板 9.5.0 + 破解补丁
* 组件安装：OpenResty / MariaDB 10.11 / PHP 8.2 / phpMyAdmin 5.2 / Fail2ban / Redis / Node.js 管理器
* `chroot-compat-layer.sh`：`systemctl` / `service` / `start-stop-daemon` / `iptables-legacy` 兼容层
* `android-network-fix.sh`：Android paranoid-network 的 `inet` 组修正
* `docs/pitfalls.md`：踩坑记录（宝塔侧 / Android 侧）
* `tools/`：`moli_patch.py`（面板改造补丁，幂等）、`plugin_install.py`、`store_check.py`

---

## 待办（还没做的）

* `docs/handover.md` 里有些内容是 v1.0.0 时期写的，与当前代码有偏差，正在对齐
* 没有自动化测试；「装完能不能用」目前靠 `action.sh diag` 人工确认
