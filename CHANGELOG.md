# 更新日志

> **关于 v1.2.3 之前**：当时这个目录还不是 git 仓库，发布靠逐文件调 GitHub Contents API，
> 所以没有逐版本的记录。下面只写我在文件内容、文件时间戳和提交信息里**能核实**的东西，
> 核实不了的一律不写 —— 与其编一份好看的假历史，不如承认这段没有记录。

---

## 未发布（相对 v1.2.3）

### 一键部署

* **新增 PC 侧 `deploy.ps1`** —— 在电脑上一条命令跑完：找 adb → 等设备 → 探 root
  （实测 KernelSU-Next 的 adbd 常常本身就是 root，这时设备上根本没有 `su` 命令，所以先探再决定加不加 `su -c`）
  → 推 `install/` + `module/` → 在手机上执行 `install/deploy.sh`。
  参数 `-Check` / `-PushOnly` / `-NoReboot` / `-Adb <路径>`。
  **必须存成 UTF-8 带 BOM**：实测 PowerShell 5.1 会把无 BOM 的 UTF-8 当 GBK 解析，
  中文被拆坏后撞上字符串终止符和保留的 `<` 运算符，直接语法报错。
* **新增手机侧 `install/deploy.sh`（自举）** —— 前置检查（root / aarch64 / 磁盘 / 工具 / SELinux）
  → 本地没有完整仓库就自己从 GitHub 拉 main 并解包 → 铺 openEuler rootfs
  → 装面板/组件/插件/打补丁 → 装 KernelSU 模块 → 打印凭据并重启。
  参数 `--check` / `--repo-only` / `--repo-tar` / `--url` / `--tar` / `--no-reboot`。
* **README 首页把一键命令提到最前面** —— 原来埋在「三、部署」里，要滚过两节才看得到。

### 面板安装器：不再耦合官方提问顺序

* 原来 `step_panel` 是 `printf "y\nyes\nyes\n" | bash install_panel.sh`，把答案顺序和官方
  提问顺序绑死了。实测官方脚本三个提问点里，「输入yes强制安装」在函数内部、是条件路径，
  **文本顺序 ≠ 运行顺序**，官方动一处就会答错位置。
* 更隐蔽的是：bash 的 `read -p` 在 stdin 不是终端时**根本不打印提示**（管道和 FIFO 都实测过，
  stderr 为空；旧安装日志里也搜不到任何提示文本），所以喂管道时答错了连日志都看不出来。
* 现在：安装器先落盘 → sha256 对 `install/installer.lock`（人工核验过的哈希清单）
  → 静态列出提问点供对照 → 用 `expect` 分配 pty，**按提示内容**作答
  （`install/bt-panel-install.exp`）；遇到不认识的提问直接失败，而不是乱答一个。
  `step_deps` 相应加了 `expect`。

### 修掉的实测缺陷

* **`lib.sh` 覆盖前没有备份**：`docs/handover.md` §六 与 `module/README.md` §七 都把
  `install/lib.sh.bt-orig` 列为回滚点，实测该文件**根本不存在**（`step_components` 是直接
  `cp -f` 覆盖，从来没生成过备份）。现在覆盖前自动留底，并且幂等 —— 已有 `.bt-orig` 就不再动，
  避免第二次执行把 shim 当成「原版」备份掉。
* `prepare-rootfs.sh` 的 `STAGE` 是死变量（只赋值、全文件无引用）。
* `tomcat.initd` 的 `JAVA_HOME` 回退写法把 `$(...)` 全裸着（4 条 shellcheck 告警），已改写。
* `step_plugins` 里只有一个元素的 `for` 循环，改成直接 `cp`。

### CI

* 新增 `tools/ci.sh` + `.github/workflows/ci.yml`，本地和 CI 跑同一个脚本：
  `shellcheck -S warning` / `sh -n` / `python3 -m py_compile` / `node --check` /
  行尾 CRLF / `deploy.ps1` 的 UTF-8 BOM / `installer.lock` 哈希格式。
  用 `CI=true` 区分「本地没装工具可以跳过」和「CI 里必须装，不许静默跳过」。
* 已实测：注入 shell 语法错误、python 语法错误、CRLF、丢 BOM、坏哈希 5 类故障，
  全部被拦下（基线正常通过）。
* 顺带发现并修掉：`tools/__pycache__/*.pyc` 会被 `git add -A` 扫进版本库，已加 `.gitignore`。

### 文档口径统一（2026-09-21 复核）

* `ltd`/`pro`：三处文档写 **-2**，实际代码是 **`ltd=0` / `pro=-1`**（`tools/moli_patch.py`）。
  已按代码改正，并说明为什么不能用 -2（-2 在前端对应「已过期」，0 会被后端 `if not ltd` 吞掉，
  必须配合数据层补丁）。
* 面板版本：三处文档写 **9.5.0**，实测是 **13.0.0**（`class/common.py` 的 `g.version` 与
  `/tmp/LinuxPanel-13.0.0.pl` 两处一致）。
* Node：原来判成「`v20.18.3` 写错、应为 `v20.18.2`」，其实是**两个都对、指的不是同一个东西** ——
  `v20.18.3` 是宝塔 Node 管理器内置的（`/www/server/nodejs/v20.18.3/bin/node`），
  `v20.18.2` 是系统 `/usr/bin/node`。
* 磁盘：README 写「装完约 4-6 GB、`/data` 空闲 ≥ 8-10 GB」，实测装完 **17.7 GB**
  （其中 `www/server/mysql/src` 这个编译构建树占 8.8 GB），已改为 ≥ 20 GB。
* `fail2ban-server -V` 打印的 `1.1.1.1` 是 `version.replace('.dev','.')` 归一化的结果，
  真实版本 `1.1.1.dev1` —— 已在 pitfalls 注明，免得被当成版本写错。

### 文档

* `docs/pitfalls.md` 补「面板反爬虫 UA 分界线」实测：`is_spider()` 命中时返回伪装成
  `Server: nginx` 的 404，**且不写请求日志**，极易误判成面板故障；同时理清另外两个会
  输出同一个 404 页的来源（安全入口下非入口路径、未登录走 `error_not_login()`）。
* 组件版本按实测复核并改正（Fail2ban 上游版本、Node、JDK 等），修正章节编号。

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

* 首次交付：openEuler 24.03 LTS-SP3 aarch64 chroot + 宝塔面板 + 破解补丁
  （面板版本当时记为 9.5.0，2026-09-21 复核实际是 **13.0.0**，已改正）
* 组件安装：OpenResty / MariaDB 10.11 / PHP 8.2 / phpMyAdmin 5.2 / Fail2ban / Redis / Node.js 管理器
* `chroot-compat-layer.sh`：`systemctl` / `service` / `start-stop-daemon` / `iptables-legacy` 兼容层
* `android-network-fix.sh`：Android paranoid-network 的 `inet` 组修正
* `docs/pitfalls.md`：踩坑记录（宝塔侧 / Android 侧）
* `tools/`：`moli_patch.py`（面板改造补丁，幂等）、`plugin_install.py`、`store_check.py`

---
