# 栖云台 · 宝塔面板（安卓 aarch64 · KernelSU 模块）

把 **宝塔 Linux 面板** 装进安卓手机：`openEuler 24.03 LTS-SP3 (aarch64)` chroot + 宝塔官方组件，用 **KernelSU 模块** 开机自动挂载并拉起全部服务。

> 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / Android 9 / 内核 4.9.148）
> 适用范围与限制见下面「五、适用性」。

```
作者：茉莉        QQ：1265274322
官方 Q 群：570387739
```

---

## 一键部署（复制即用）

前置：手机 **arm64**、已 root（KernelSU / KernelSU-Next / Magisk）、`/data` 空闲 **≥ 20 GB**。

交付走 **预制镜像**：整套 openEuler + 宝塔环境（面板、组件、9 个插件都编译好了）打包成 2.2 GB 的镜像，
装一台约 **10 分钟**。面板版本**冻在镜像里**（13.0.0），不受宝塔发版影响，也不需要连宝塔的服务器。

> 为什么不再从宝塔官方装：见下面「为什么不走宝塔官方源」。

### 电脑是 Windows

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

不想 clone 的**一行**（下 zip → 解包 → 直接跑）：

```powershell
$d="$env:TEMP\qyt"; Invoke-WebRequest -UseBasicParsing 'https://github.com/moliapiyyds/qiyuntai-btpanel/archive/refs/heads/main.zip' -OutFile "$d.zip"; Expand-Archive "$d.zip" $d -Force; & "$d\qiyuntai-btpanel-main\deploy.ps1"
```

### 电脑是 Linux / macOS

```bash
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
./deploy-linux.sh            # 参数与 deploy.ps1 等价：--check / --push-only / --no-reboot / --adb / --dest
```

没有 adb 的话：Debian/Ubuntu `sudo apt install android-tools-adb`，macOS `brew install android-platform-tools`。
（`deploy-linux.sh` 与 `deploy.ps1` 是两个等价入口，做的事完全一样，改一个记得改另一个。）

**电脑侧是最稳的一条路**：2.2 GB 的镜像由电脑下（Release 附件在电脑上很稳），下完自动 `adb push` 到手机再装。

### 没有电脑：纯手机终端（一行）

在手机上用 root 终端（KernelSU/Magisk 自带的、或者 Termux `su -c`、或者 `adb shell` 都行）：

```sh
su -c 'BB=$(ls /data/adb/ksu/bin/busybox /data/adb/magisk/busybox 2>/dev/null|head -1); T=/data/local/tmp/qyt.tgz; $BB wget -O $T https://codeload.github.com/moliapiyyds/qiyuntai-btpanel/tar.gz/refs/heads/main && mkdir -p /data/local/tmp/qyt-repo && $BB tar -xzf $T -C /data/local/tmp/qyt-repo --strip-components=1 && sh /data/local/tmp/qyt-repo/install/fetch-image.sh && sh /data/local/tmp/qyt-repo/install/deploy.sh'
```

它串起来的是三步，每步都能单独重跑（**重跑是安全的**）：

| 步骤 | 干什么 | 重跑会怎样 |
|---|---|---|
| 拉 `codeload.github.com` 的仓库 tar | 解到 `/data/local/tmp/qyt-repo` | 覆盖，无所谓 |
| `install/fetch-image.sh` | 下 2.2 GB 镜像分卷到 `/data/local/tmp/qyt-image`，逐卷 + 整包核 sha256 | 已下好的**跳过**；下坏的自动删掉重下；断线**断点续传** |
| `install/deploy.sh` | 解包 → 随机化端口/入口/密码/sshd 密钥 → 插件/基线对齐/补丁/模块 → 重启 | 目标 `/data/openeuler` 非空会**拒绝**解包（要先清，见下） |

**想先只体检**：把最后那句换成 `sh /data/local/tmp/qyt-repo/install/deploy.sh --check`。

> 手机直连 GitHub 下 2.2 GB 偶尔会断（Release 附件走 `objects.githubusercontent.com`，
> 实测有时 5 次都 `Connection reset by peer`）。`fetch-image.sh` 会**断点续传 + 重试 5 次**，
> 实在下不动就换电脑侧那条路，或者手动把分卷推进 `/data/local/tmp/qyt-image` 再跑 `--check` 验一下。

### 为什么不走宝塔官方源

2026-09-22 定：**一键部署只走预制镜像**。原因是官方安装器那条路「面板版本不在我们手里」：

- 官方安装器每次拉的是宝塔的**当前**版本。实测 2026-09-21 装到 `13.0.0`，**2026-09-22 当天就变成 `13.1.0`**。
- 我们的补丁是**版本门禁**的（`tools/moli_patch.py` 里的 `PANEL_VERIFIED`）。装到没核验过的版本，
  它会直接失败并提示「要人工核验后加 `--force`」—— 这是故意的：补丁按「文件路径 + 函数名 +
  代码片段」打，静默打出半个（企业版显出来了、关更新却没生效）比彻底失败更坏。
- 于是走官方源的一键部署会在 `patch` 步骤**失败**，得人工核验一遍才能放行。

> 顺带一个实测数据：`13.1.0` 上补丁的**锚点漂移是 0/8**（8 项校验全正常、4 个 py 文件语法 OK）。
> 所以问题**不是「补丁会坏」**，而是「版本不可控 → 交付物不可复现 → 每次发版都要重核验一遍」。
> 镜像解决的是这个。

镜像还顺带解决两件事：**不依赖宝塔服务器**（有人卡在 `download.bt.cn` 解析不到，见下）、
装一台从约 2 小时压到约 **10 分钟**。

> **重跑是安全的**：面板 / 组件 / 插件 / 模块 / init 脚本都已装好的会自动跳过
> （实测 `components` 步骤重跑 **1 秒**跑完，不会重新编译）。
> 这条是 2026-09-22 修的 —— 以前 `step_components` 是无条件执行，重跑一次要再等一个多小时。
> 参数（`-Check` / `-PushOnly` / `-NoReboot` / `-Adb` / `-Dest`）、分步部署 → 见「三、部署」。

### 【作者用】从源重建环境（`--from-source`，别给用户跑）

镜像里的环境是这么造出来的：铺 openEuler rootfs → 用**宝塔官方安装器**装面板 → 装组件（源码编译）
→ 装 9 个插件 → 基线包对齐 → 打补丁 → 打包成镜像。重建时在手机 root shell 里：

```sh
su -c 'sh /data/local/tmp/qyt-repo/install/deploy.sh --from-source'          # 约 2 小时
su -c 'sh /data/local/tmp/qyt-repo/tools/make_image.sh --out /data/qyt_image' # 打包
```

`--from-source` 是**唯一**还会碰宝塔服务器的路径，所以下面这段排错仍然有效：

> ⚠️ **从源装需要能连上宝塔的服务器 `download.bt.cn`**（安装器和面板包都从那儿下，
> 这一步没法用别的源替代）。实测有人卡在这里，而且**前面的步骤全过了**：
>
> ```
> [栖云台] 下载宝塔官方安装器（先落盘，不再 curl|bash）
> curl: (6) Could not resolve host: download.bt.cn
> ```
>
> 这**不代表**你整台手机 DNS 坏了 —— 同一份日志里 `dnf` 刚用同一个 `/etc/resolv.conf`
> 从 openEuler 镜像装完 292 个包。它更像**单个域名**解析不到（DNS 污染 / 运营商拦截 /
> 梯子的 split-DNS）。三条出路：
>
> 1. 在电脑或手机浏览器上把安装器下好，推过去再重跑（脚本会优先用它，不再联网下）：
>    ```sh
>    curl -fsSL -o install_panel.sh https://download.bt.cn/install/install_panel.sh
>    adb push install_panel.sh /data/local/tmp/
>    adb shell "su -c 'sh /data/local/tmp/qyt-repo/install/qiyuntai-install.sh panel'"
>    # 别的路径也行： … install/qiyuntai-install.sh panel --installer /别的/install_panel.sh
>    ```
> 2. 换网络（Wi-Fi ↔ 流量）再试；挂了梯子/VPN 的话关掉再试一次。
> 3. **直接走预制镜像**（用户装机就该走这条）—— 它完全不碰宝塔服务器。
>
> 装到这一步失败**不会白费**：rootfs、依赖都装好了，补上安装器再跑一次 `panel` 步骤就继续了
> （脚本自己会把失败原因、当前 DNS 状态、以及上面这三条出路都打出来）。

> 重建完记得把新镜像的哈希追加到 `install/image.lock`（分卷 + 整包都要），
> 否则 `fetch-image.sh` / `deploy.sh` 的校验会**拒绝**新镜像。添加流程写在这个文件头部。

---

## 一、这套东西是什么

| 层 | 内容 |
| --- | --- |
| 底层 | openEuler 24.03 LTS-SP3 aarch64 chroot，落在 `/data/openeuler`（**实测装完 17.7 GB**，其中 MariaDB 编译构建树 `www/server/mysql/src` 占 8.8 GB，删掉可回收） |
| 面板 | 宝塔面板 **13.0.0**（aarch64 版），端口/入口**安装时随机**（每台机器不同，见下文「怎么访问」），已解锁**永久企业版**、**关闭更新**、**免 bt.cn 绑定** |
| 环境组件 | **OpenResty 1.31.1.1**、**MariaDB 10.11.16**、**PHP 8.2.33**、**phpMyAdmin 5.2**、**Redis 8.0.6**（宝塔 redis 插件当前版本）、**Memcached 1.6.45**、**Tomcat 9.0**（9.0.62，Apache 归档）、**Supervisor 4.2.4** |
| 管理插件 | Fail2ban 2.6、Node.js版本管理器 2.8（内置 node **v20.18.3**）、java环境管理器 / jdk_manager（内置 JDK **17.0.20.8**）、Python项目管理器（`pythonmamager`）、python环境管理器（`pyenv_manager`）、Supervisor 进程管理器、Tomcat（`tomcat2`）、Redis |
| 额外环境 | Python 3.13.14 + pip/venv、OpenJDK 17.0.20.8 / 11.0.32.9 / 1.8.0_502、Node.js **v20.18.3**（宝塔管理器内置）/ **v20.18.2**（系统 `/usr/bin/node`）+ npm 10.8.2、git/vim/htop/tmux/jq/sqlite3、完整编译链、iptables-legacy |
| 开机自启 | KernelSU 模块 `qiyuntai_btpanel`：挂 chroot → 写 DNS → 修正 Android 网络限制 → 依次拉起 **11 项**：面板/nginx/MariaDB/PHP-FPM/Fail2ban/crond/Redis/Memcached/Tomcat + supervisord + sshd（adb 不通时的兜底通道） → 自检 |

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
* **面板 SSL 默认关着**：bt 的「自动申请 IP 证书」任务会在装完后自动写 `data/ssl.pl=True`，
  面板就只收 HTTPS，明文 `http://…` 连上会被 reset（不是 404）。部署脚本会把这个任务
  空壳化并删掉 `ssl.pl`，所以上面写的是 `http://`；如果你自己在面板里开了 SSL，
  就改用 `https://`（自签证书，浏览器会提示不安全）。
* 随机化：端口/入口/用户名由宝塔安装器随机；**密码由 `install/qiyuntai-install.sh` 用 `openssl rand -hex 8` 生成 16 位随机**并写入凭据文件 → 不会出现"全网同一个密码"。

---

## 三、部署

> 前提：**arm64 设备**、已 root（KernelSU-Next / KernelSU / Magisk 都行）、`/data` 空闲 **≥ 20 GB**（实测装完占 17.7 GB）。
> 全程只写 `/data/openeuler` 与 `/data/adb/modules`，不动系统分区。

### 一键部署：完整参数与流程

电脑上执行（电脑要能连 GitHub，且装了 adb）：

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

**就这一条。** 脚本会自动做完：

```
1) 找 adb → 等设备 → 确认手机上能拿到 root → 查架构与磁盘
2) 把 install/ module/ tools/ 推到手机（同一层目录）
3) 预制镜像分卷：电脑下到 _dist/image/（校验通过不重复下）→ adb push 到手机
   → 在手机上再核一遍 sha256。手机上已经有且校验通过就整段跳过
4) 在手机上跑 install/deploy.sh --from-image，自动完成：
     校验分卷（sha256 对不上就拒绝解包）
     → 解包（约 15 分钟，busybox xz 单线程）
     → 重新随机化端口 / 安全入口 / 用户名 / 密码 / sshd 主机密钥
     → 9 个面板插件核对 → 基线包对齐（按 install/baseline-packages.txt 逐名补齐）
     → 打补丁（永久企业版 / 关闭更新 / 免绑定）+ 服务兼容层 + 装 3 个自备 init 脚本 + sshd 配置
     → 装 KernelSU 模块
5) 自动重启手机（重启后模块的 service.sh 拉起 11 个服务）
```

装一台约 **10 分钟**（镜像里面板和组件都已编译好，跳过 dnf 与全部源码编译）。
从源装（`--from-source`，作者重建环境用）才是约 2 小时、**MariaDB 编译峰值约 2 GB 内存**。

| 参数 | 作用 |
| --- | --- |
| `-Check` | 只体检（设备 / root / 架构 / 磁盘），不推不装 |
| `-PushOnly` | 只把仓库与镜像分卷推到手机，安装你自己来 |
| `-NoReboot` | 装完不自动重启 |
| `-Adb <路径>` | 指定 adb（默认自动找 `tools\adb\adb.exe`、`PATH`、常见安装位置） |
| `-ImageDir <路径>` | 镜像分卷放手机哪儿（默认 `/data/local/tmp/qyt-image`） |
| `-ImageUrl <url>` | 镜像从哪下（默认 GitHub Release；自建镜像站/网盘直链都行） |

`deploy-linux.sh` 是等价入口（`--check` / `--push-only` / `--no-reboot` / `--adb` / `--dest` /
`--image-dir` / `--image-url`）。`install/deploy.sh` 自己另有一组参数：
`--from-image <dir>` / `--image-url` / `--image-sha` / `--no-fetch` / `--no-reboot`，
以及作者用的 `--from-source`。

**不想 clone 的，一行搞定**（PowerShell）：

```powershell
$d="$env:TEMP\qyt"; Invoke-WebRequest -UseBasicParsing 'https://github.com/moliapiyyds/qiyuntai-btpanel/archive/refs/heads/main.zip' -OutFile "$d.zip"; Expand-Archive "$d.zip" $d -Force; & "$d\qiyuntai-btpanel-main\deploy.ps1"
```

> **为什么推荐在电脑侧准备？** 因为**镜像那 2.2 GB** 这一环，手机侧看运气：
> * **仓库 tarball（`codeload.github.com`）很稳** —— 连试 3 次全成功（每次 153,364 字节）。
>   纯手机自举靠它，这条路可靠。
> * **Release 附件不稳，而且是间歇性的**（2026-09-22 同一天量到两边极端）：
>   * 18:52~18:56：同一份脚本、同一条 URL，`part-aaa` **5 次全部** `download timed out`，
>     一个字节都没传（用 chroot 的 curl 探到 `Failed to connect to github.com port 443 after 15001 ms`）；
>   * 19:00 之后：同样的 URL，**30 秒下了 337 MB**（≈11 MB/s），3 分钟下完整卷。
>   * 注意坏的是 **`github.com` 那一跳**，CDN（`185.199.x.x`）那一跳是通的。
> * 所以手机侧自举是「能下就下」：`fetch-image.sh` 会断点续传 + 重试，`--tries 0` 一直磨。
>   想稳就走电脑侧。清华镜像（`--from-source` 铺 rootfs 的来源）一直都能连。

### 分步部署（想自己控制的用这个）

> **推到 `/data/local/tmp` 而不是 `/sdcard`**：`/sdcard` 是 **CE 存储**
> （`ro.crypto.state=encrypted`、`ro.crypto.type=file`），手机**重启后只要没解锁一次**，
> vold 就不会建 `/mnt/user/0/primary` —— `/sdcard` 直接 "No such file or directory"，
> adb push 全灭；此时 `/data/media/0` 里只能看到 fscrypt 的 22 字符加密文件名，
> 看着特别像"存储坏了"，其实只是没解锁。一键部署最后一步就是重启手机，所以这个坑很容易踩。
> `/data/local/tmp` 是 DE 存储：锁屏能写、重启也在。

```sh
# 1) 推文件（install/ module/ tools/ 必须在同一层目录）
D=/data/local/tmp/qyt-repo
adb shell "mkdir -p $D"
adb push install/ $D/install/
adb push module/  $D/module/
adb push tools/   $D/tools/          # step_plugins 要 plugin_install.py、step_patch 要 moli_patch.py

# 2) 体检，不装任何东西
adb shell "su -c 'sh $D/install/deploy.sh --check'"

# 3) 全自动装（--no-reboot 可以装完不重启）
adb shell "su -c 'sh $D/install/deploy.sh'"
```

（`deploy.ps1` 默认就是这么推的；想推到别处用 `-Dest <路径>`。）

`install/deploy.sh` 也可以单独用：

| 参数 | 作用 |
| --- | --- |
| `--check` | 只做前置检查 |
| `--repo-only` | 只把仓库拉到本地（手机上） |
| `--repo-tar <文件>` | 仓库用本地已推过来的 tar.gz，不连 GitHub |
| `--url <tar.xz>` | rootfs 走指定 URL |
| `--tar <文件>` | rootfs 用本地已解压好的 docker tar |
| `--from-image <目录>` | **用预制镜像铺环境**（目录里放 `qyt-image.part-*`）：跳过 dnf 和全部源码编译，约 10 分钟；铺完会重随机化端口/入口/用户名与 sshd 主机密钥，并按基线包清单核对一遍（镜像里是全的，正常什么都不装） |
| `--image-sha <sha>` | 额外指定镜像整包 sha256（不给就用目录里的 `SHA256SUMS.txt`） |
| `--no-reboot` | 装完不重启 |

`install/prepare-rootfs.sh` 也有几个独立开关：

| 参数 | 作用 |
| --- | --- |
| `--mirror` | 自动到镜像目录挑 rootfs 文件并下载（一键部署走这条） |
| `--unmount` | 只解挂载（**删除 chroot 前必须先做这个**） |
| `--clean` | 解挂载 → 确认干净 → 删除。**安全的删法**，别直接 `rm -rf` |

> 手机上只有 `busybox` 可用（没有 curl / wget / xz），所以：
> **rootfs 能从清华镜像下**（HTTP/HTTPS 都行），**仓库不能从 GitHub 下**。
> 想完全在手机上自举，先把仓库打包推上去再用 `--repo-tar`。

### 预制镜像（**唯一交付路径**）

从源装要碰一堆宝塔的端点（安装器 / panel6.zip / pyenv bundle / 组件脚本 / 组件源码），
任何一环变了或没了、或者面板换版本了，从源装就断。所以：**装好一次，冻成镜像，以后重装 = 解包。**

三种拿法，按推荐顺序：

**① 电脑侧一键（最稳）** —— 电脑下 2.2 GB（网络好），下完自动推进手机：

```powershell
.\deploy.ps1                       # Windows
./deploy-linux.sh                  # Linux / macOS
```

它会下到 `_dist/image/`（已在 `.gitignore` 里）缓存住，**校验通过就不重复下**，
然后推到手机 `/data/local/tmp/qyt-image`，并在手机上核一遍 sha256 才算完。

**② 纯手机（手机自己下）** —— 断点续传 + 逐卷校验 + 重试：

```sh
su -c 'sh /data/local/tmp/qyt-repo/install/fetch-image.sh'
# 直连 GitHub 撞上坏窗口就让它自己磨（可以挂着去睡觉）：
su -c 'sh /data/local/tmp/qyt-repo/install/fetch-image.sh --tries 0'
```

**③ 从一台已经装好的设备直接拿（完全不经过网络）**：

```sh
# 在已经装好的那台上
sh tools/make_image.sh --out /data/qyt_image
# 在电脑上
adb -s <旧机器> pull /data/qyt_image ./qyt_image
adb -s <新机器> push ./qyt_image/. /data/local/tmp/qyt-image/
```

> 哈希清单在 `install/image.lock`（分卷 + 整包都记着）。取件脚本和 `deploy.sh` 都拿它核对：
> **对不上就拒绝解包**，不会铺出一个坏环境。换镜像时要把新哈希追加进去（流程写在文件头部）。

拿到分卷之后（手机上）：

```sh
D=/data/local/tmp/qyt-repo
su -c "sh $D/install/prepare-rootfs.sh --clean"          # 目标非空才需要；别直接 rm -rf
su -c "sh $D/install/deploy.sh --from-image /data/local/tmp/qyt-image"
```

* 跳过 **dnf + 全部源码编译**，从 ~2 小时降到 **~10 分钟**，且不连宝塔的服务器
* 镜像里存的是**未打补丁的原版**，破解补丁在部署时打（补丁要跟面板版本走，冻进去就没法单独更新；
  而且只有对原版打，`moli_patch/backup_*/` 里才是真原版，回滚点才成立）
* **端口 / 安全入口 / 用户名 / 密码 / sshd 主机密钥会在部署时重新随机** —— 镜像里烘的是打包那台机器的值，
  不重新随机，所有用同一镜像的人就完全一样
* 前置：目标 `/data/openeuler` 必须为空；非空时先 `sh install/prepare-rootfs.sh --clean`（**别直接 `rm -rf`**，
  带着挂载删会连宿主的真 `/dev` 一起删掉，实测黑屏过两次）

**现成的镜像在哪**：模块 zip 和预制镜像**分开发** —— 模块 zip 在最新 Release（**v1.2.7**），
**预制镜像在 v1.2.6 的 Release** 里（v1.2.7 只改了部署脚本与文档，环境一个字节没变，所以没重发那 2.2 GB）。
`install/image.lock` 里记的 `tag` 就是「镜像所在的 Release」，`fetch-image.sh` / `deploy.ps1` / `deploy-linux.sh`
都按它拼下载地址，不用你手填。

> 手机直连 GitHub 下 2.2 GB 会碰到 `github.com` 那一跳**间歇性连不上**
> （实测 `curl: (28) Failed to connect to github.com port 443 after 15001 ms`，
> 同一时刻 CDN 那一跳 `185.199.x.x` 是通的）。所以取件脚本是「重试 + 断点续传 +
> 失败**保留半截文件**」，`--tries 0` 就是无限磨。真嫌慢就走电脑那条。

### 只想装 / 更新模块（环境已经好了）

```powershell
adb push qiyuntai_btpanel-v1.2.7.zip /data/local/tmp/
adb shell "su -c '/data/adb/ksud module install /data/local/tmp/qiyuntai_btpanel-v1.2.7.zip'"
```

* `ksud` 的真实路径是 **`/data/adb/ksud`**（不在 `PATH` 里）
* 解包到 `/data/adb/modules_update/<id>`，执行 `customize.sh`，**重启后生效**
* KernelSU 管理器里「从本地安装」选同一个 zip 也一样

> 手工装**别用** `cp -r module /data/adb/modules/qiyuntai_btpanel` ——
> 目标目录已存在时 `cp -r` 会嵌套成 `…/qiyuntai_btpanel/module/module.prop`，模块加载不了（实测如此）。
> 要用 `cp` 就这么写：`mkdir -p 目标 && cp -f module/* 目标/`

### 装完怎么用

```sh
# 拿地址、账号、密码（三种都行）
adb shell "su -c '/data/adb/ksud module action qiyuntai_btpanel'"
adb shell "su -c 'cat /data/openeuler/root/qiyuntai-panel-info.txt'"
# 或 KernelSU 管理器里点模块的「执行」按钮

# 出问题先诊断
adb shell "su -c 'sh /data/adb/modules/qiyuntai_btpanel/action.sh diag'"
```

`diag` 检查：挂载点 / chroot 可用性 / `inet` 组 / 服务进程 / 端口监听 / 面板自检 /
磁盘 / `boot.log` 报错行 / 面板关键文件 / 破解补丁，**不重启任何服务**。

### 卸载

```sh
adb shell "su -c '/data/adb/ksud module uninstall qiyuntai_btpanel'"
```

`uninstall.sh` **只停服务 + 解挂载，不删 `/data/openeuler`** —— 网站、数据库、面板配置全部保留。

要彻底删掉，**别直接 `rm -rf /data/openeuler`**：chroot 里 `dev` / `proc` / `sys` 是
`mount --bind` 进来的，带着挂载 `rm -rf` 会**顺着 bind 把宿主机的 `/dev` 删掉**
（这个坑踩过两次，见 `docs/pitfalls.md` §六.2 / §六.4，第一次是黑屏、得靠 `mknod` 重建设备节点 +
`echo b > /proc/sysrq-trigger` 才救回来）。用这两条：

```sh
# 只删环境（先解挂 → 断言挂载数为 0 → 再删）
adb shell "su -c 'sh /sdcard/install/prepare-rootfs.sh --clean'"
# 或者用模块自带的 --purge（同样带断言）
adb shell "su -c 'sh /data/adb/modules/qiyuntai_btpanel/uninstall.sh --purge'"
```

---

详细的分步说明见 `install/` 目录下的脚本注释。

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
deploy.ps1               Windows 侧一键部署（找 adb → 推仓库 → 下+推镜像分卷 → 手机上装）
deploy-linux.sh          Linux / macOS 侧一键部署（与 deploy.ps1 等价：--check/--push-only/--no-reboot/--adb/--dest/--image-dir/--image-url）
install/deploy.sh        手机侧一键部署总入口（默认走预制镜像；--from-source 才是从源铺）
                         ← 纯手机终端那条路最后就调它（见首页「纯手机终端」）

module/                  KernelSU 模块（刷这个）
  module.prop             模块信息（id / 版本 / 作者）
  customize.sh            安装时执行：检测环境、给脚本加执行位
  service.sh              开机流程：挂载 chroot → 拉起 11 个服务 → 面板自检
  action.sh               模块「执行」按钮：凭据 / 补拉服务 / diag 诊断
  uninstall.sh            只停服务 + 解挂载，不删 /data/openeuler
  README.md               模块使用说明

install/                 设备上执行的部署脚本
  deploy.sh               一键部署总入口（默认从预制镜像铺；--check / --repo-only /
                          --from-image / --image-url / --no-fetch / --no-reboot 等）
  fetch-image.sh          取预制镜像分卷（断点续传 + 逐卷 sha256 + 重试；--tries 0 = 一直试）
  image.lock              预制镜像的哈希清单（分卷 + 整包），取件与解包前都按它核对
  prepare-rootfs.sh       铺 openEuler rootfs（按 manifest.json 顺序叠层）；--clean 清环境
  qiyuntai-install.sh     分步安装：rootfs → 挂载 → 依赖 → 面板 → 凭据 → 组件 → 插件 → 基线包对齐 → 补丁 → 模块
  chroot-compat-layer.sh  systemctl/service/start-stop-daemon/iptables-legacy 兼容层
  android-network-fix.sh  paranoid-network 的 inet 组修正
  crond.initd             chroot 没有 systemd、宝塔也不给这三个，缺了就起不来
  tomcat.initd           （install/qiyuntai-install.sh 的 patch 步骤会装进 /etc/init.d）
  memcached.initd
  sshd_config_moli        sshd 兜底通道（:22）的配置，面板/openEuler 都不带，基线里那台是手工装的
  lib-shim.sh            替换面板原版 lib.sh 的最小依赖兜底（避免重复编译 openssl/mcrypt）
  bt-panel-install.exp   驱动宝塔官方安装器：分配 pty、按「提示内容」作答（不依赖提问顺序）
                         —— 只在 --from-source 重建环境时用得到
  installer.lock         已人工核验过的 install_panel.sh 的 sha256 白名单（同上）
  baseline-packages.txt  标准环境的 548 个 rpm 包清单（parity 步骤按它对齐，只比包名）
                         sha256 4b3c870ad51d957f3c357aa97a96d921fde358264b77f9f2319d591eb2890f31
                         与删除前那台的 `rpm -qa` 输出逐字节一致（20899 字节）

tools/                   辅助脚本
  moli_patch.py           面板改造补丁（永久企业版 / 关闭更新 / 免绑定），幂等
  plugin_install.py       宝塔插件安装器（走官方下载接口，无需登录面板）
  store_check.py          核对商店「已安装」状态
  build_module_zip.sh     打可刷模块 zip（带版本自检）
  verify_sync.sh          本地 vs 远端比对 + Release 附件新鲜度（比内容，不比 zip 字节）
  make_image.sh           把装好的环境冻成可分卷镜像（预制宝塔，见「三、部署」）
  audit_env.sh            环境体检：rpm 对齐 / 11 项服务 / 组件版本 / 面板与插件 / 自备文件
  ci.sh                   仓库自检：shellcheck / sh -n / py_compile / CRLF / BOM / 哈希格式

docs/                    说明与记录
  handover.md             交付说明（含版本复核记录）
  pitfalls.md             踩坑记录（全部为实测结论）
  release-notes-v1.2.7.md 当前版本的 Release 说明
  release-notes-v1.2.6.md 上一版（历史保留）
  release-notes-v1.2.5.md 更早的一版（历史保留）
  release-notes-v1.2.4.md 更早的一版（历史保留）
  release-notes-v1.2.3.md 更早的一版（历史保留）
  private-deployment.md   本机真实地址与口令（已 gitignore，不进仓库）

CHANGELOG.md              更新日志
.github/workflows/ci.yml  GitHub Actions：调 tools/ci.sh（本地同一个脚本）
.shellcheckrc             关掉 mksh 扩展误报（SC3043：Android 的 /system/bin/sh 支持 local）
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
* 补丁生效：`get_soft_list` 返回 `ltd=0 / pro=-1`（面板显示企业版·永久）。**不是 -2** —— 原因见 `docs/pitfalls.md` §一.7、`is_bind()` 恒真、升级脚本已空壳
* 商店状态核对：nginx / mysql(MySQL 卡片) / php-8.2 / phpmyadmin / fail2ban / nodejs 全部 **已安装**
* **两次重启实测**（2026-09-20，当时开机服务只有 7 项）：模块自动挂载 chroot、写 DNS、拉起 bt / nginx / MariaDB / php-fpm-82 / fail2ban / crond / Redis，
  面板自检 `HTTP=200`，端口 80/888/3306 与面板端口全部监听（日志见 `boot.log`）。
  v1.2.3 起服务扩到 **11 项**（补 Memcached / Tomcat / supervisord / sshd），
  完整重装后的逐项复核见 `docs/handover.md`。


---

## 八、联系方式

```
作者：茉莉
QQ：1265274322
官方 Q 群：570387739
```
