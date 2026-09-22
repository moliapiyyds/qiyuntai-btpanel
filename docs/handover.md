# 栖云台 · 宝塔面板 —— 交付说明（2026-09-20 凌晨完工；2026-09-22 从零重装复核，见 §十）

> 设备：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / 内核 4.9.148 / aarch64）
> KernelSU-Next 3.3.0 + NeoZygisk　|　chroot：openEuler 24.03 LTS-SP3 aarch64（/data/openeuler）
> 作者：茉莉　QQ:1265274322　官方Q群:570387739

---

## 一、面板访问（已实测）

| 项 | 值 |
| --- | --- |
| 局域网地址 | `http://<手机IP>:<端口>/<入口>` |
| 设备内地址 | `http://127.0.0.1:<端口>/<入口>` |
| 账号 / 密码 | 安装时随机生成，见下方读取方式 |
| 端口 / 入口 | `/data/openeuler/www/server/panel/data/{port.pl,admin_path.pl}` |

> 本机的真实地址与口令**不写进这个文件**（仓库是公开的）。
> 本机实况记录在 `docs/private-deployment.md`（已 `.gitignore`，只在本地存在）。
>
> 不知道自己这台的值？三个办法：
> 1. 点模块的「执行」按钮 —— 会打印地址、账号、密码，并用浏览器打开面板
> 2. 读凭据留档：`cat /data/openeuler/root/qiyuntai-panel-info.txt`（root 权限，600）
> 3. 直接读配置：`cat .../panel/data/port.pl` 和 `.../panel/data/admin_path.pl`

* 从电脑实测：`HTTP=200 用时=0.82s`。
* 必须用**浏览器**打开；`curl` 默认 UA 会被宝塔反爬虫丢 404（宝塔自身行为）。
* 首次登录请立刻改密码和端口。忘记密码：chroot 后执行 `bt`。

---

## 二、装了什么（全部用宝塔官方脚本/插件，商店里正常显示）

| 组件 | 版本 | 实测证据 |
| --- | --- | --- |
| 宝塔面板 | **13.0.0** (aarch64) | `class/common.py` 的 `g.version` 与 `/tmp/LinuxPanel-13.0.0.pl` 两处一致 |
| Web | **OpenResty 1.31.1.1** | `nginx -v` → openresty/1.31.1.1，`nginx -t` ok，监听 80/888 |
| 数据库 | **MariaDB 10.11.16** | `select version()` → 10.11.16-MariaDB-log，监听 3306 |
| PHP | **8.2.33** | `php -v` → 8.2.33，php-fpm 运行，`/tmp/php-cgi-82.sock` |
| phpMyAdmin | **5.2** | `/www/server/phpmyadmin/version.pl` = 5.2 |
| Fail2ban | 插件 **2.6**（内含 fail2ban **1.1.1.dev1**） | 封禁 203.0.113.9 → `f2b-sshd` 规则出现 → 解封消失 |
| Redis | **8.0.6**（宝塔 redis 插件装的；基线那台是 7.2.16，商店已下架） | `redis-server -v`，监听 127.0.0.1:6379 |
| Node.js 管理器 | 2.8（宝塔插件） | 插件 `info.json` 的 `versions` = 2.8，商店显示已安装/运行中 |
| Tomcat | **9.0** | `catalina.jar` MANIFEST 的 `Specification-Version: 9.0`，插件名 `tomcat2` |
| Supervisor | **4.2.4** | `supervisord --version` |
| Memcached | **1.6.45** | `memcached --version` |
| 额外环境 | Python **3.13.14** + pip 26.2、OpenJDK **1.8.0_502 / 11.0.32.9 / 17.0.20.8**、Node **v20.18.3**（宝塔管理器内置）/ **v20.18.2**（系统 `/usr/bin/node`）+ npm **10.8.2**、git 2.43.0、vim 9.0、htop 3.3.0、tmux 3.3a、jq 1.8.2、sqlite3 3.42.0、gcc 12.3.1 / make 4.4.1 / cmake 3.27.9、rsync 3.2.7、tcpdump(libpcap 1.10.4)、lsof 4.99.3 | 逐个 `--version` 核对通过（2026-09-21 复核） |

商店「已安装」核对（脚本 `store_check.py`）：nginx / mysql / phpmyadmin / fail2ban / nodejs / redis 全部 **是**。

---

## 三、面板改造（破解）—— 实测生效

| 需求 | 做法 | 验证 |
| --- | --- | --- |
| 显示**永久企业版** | `panelPlugin.get_cloud_list()` 返回前把 `ltd`/`pro` 覆盖为 **`ltd=0` / `pro=-1`**，并配合数据层补丁改 `get_pd()`；`expire_msg()` 打成空函数，屏蔽到期提醒。**注：不是 -2** —— -2 在前端对应「已过期」，而 0 会被后端 `if not ltd: ltd=-1` 吞掉，所以必须连数据层一起打 | 真调云端列表返回 `ltd=0 pro=-1`；前端 `utils.js` 读 cookie `ltd_end=0` → `0 > -1` 成立 → `advanced='ltd'` → 企业版 |
| **去除更新** | `script/upgrade_panel.py`、`upgrade_panel_optimized.py`、`polkit_upgrade.py`、`update.sh` 替换为空壳；清掉 crontab 更新任务 | 四个文件均为空壳（355 B），原文件在 `panel/moli_patch/backup_*/` |
| **免账号绑定** | `public.is_bind()` 恒返回 True；预置 `data/initBind.pl`、`data/bind.pl` | 实测 `public.is_bind() = True` |
| 补丁本体 | `/www/server/panel/moli_patch/moli_patch.py`（幂等，可重复执行） | 语法检查通过 |


---

## 四、KernelSU 模块

```
id            qiyuntai_btpanel
name          栖云台·宝塔面板
版本          v1.2.7   (versionCode 10207)
作者          茉莉 QQ:1265274322  官方Q群:570387739
目录          /data/adb/modules/qiyuntai_btpanel/
日志          /data/adb/modules/qiyuntai_btpanel/boot.log
```

`service.sh` 开机流程（幂等）：等 `sys.boot_completed` → 挂载 /dev /dev/pts /dev/shm /proc /sys → 写 DNS
→ Android paranoid-network 修正（`mysql`/`redis`/`www` 加入 `inet` 组 + 校正 MariaDB 数据目录属主）
→ 清理陈旧 pid 文件 → 启动
**bt / nginx / MariaDB / php-fpm-82 / fail2ban / crond / redis / memcached / tomcat / supervisord**
→ sshd 兜底（第 4.7 段，`/etc/ssh/sshd_config_moli`，监听 `:22`）→ 面板自检。

> `sshd` 那段是**救命通道**：adb 不通时它是唯一入口，所以放在服务链最后并且幂等
> （已在跑就只记日志，不重复拉起）。

`uninstall.sh`：**只停服务 + 解挂载，不删 /data/openeuler**。

`action.sh`（模块「执行」按钮）支持四种模式：

| 调用 | 行为 |
| --- | --- |
| `action.sh` | 打印地址账号密码 + 补拉未起的服务 + 用浏览器打开面板（KSU 按钮走这个） |
| `action.sh start` | 只补拉服务 |
| `action.sh diag` | 只做诊断：挂载点 / chroot 可用性 / inet 组 / 服务进程 / 端口 / 面板自检 / boot.log 报错 / 磁盘 / 破解补丁，**不重启任何服务** |
| `action.sh info` | 只打印登录信息 |

出问题第一件事就跑 `sh /data/adb/modules/qiyuntai_btpanel/action.sh diag`。
另外主流程下面板自检若不是 `HTTP 200`，会自动附上一份诊断摘要。

### 重启实测

**v1.0.0 时期（2026-09-20 04:50，第 3 次重启）**

```
[04:50:09] 启动 Nginx/OpenResty (nginx) → Starting nginx... done
[04:50:09] 启动 MariaDB (mysqld)        → SUCCESS!
[04:50:12] 启动 PHP 8.2 FPM (php-fpm-82)→ Starting php-fpm done
[04:50:12] 启动 Fail2ban (fail2ban)     → Server ready
[04:50:16] 启动 计划任务 crond (crond)   → crond 已在运行
[04:50:16] 启动 Redis（宝塔托管）        → Starting redis success!
[04:50:23] 面板自检：已响应（HTTP=200）
```

**v1.2.3（2026-09-21 19:12，非正常关机后的恢复启动 —— 这次是硬断电重启）**

```
[19:12:42] php-fpm        → done
[19:12:42] fail2ban       → Server ready / 启动完成
[19:12:46] crond          → 启动完成
[19:12:52] redis          → Starting redis success!
[19:12:53] memcached      → done
[19:12:53] tomcat         → 启动完成
[19:12:59] supervisord    → 启动完成
[19:13:01] sshd           → 监听 :22
```

重启后：端口 80 / 888 / 3306 / 6379 / 11211 / 8080 / 22 与面板端口全部在监；
MariaDB、Redis、PHP、OpenResty、fail2ban、Tomcat 全部可连。
`/dev/null` 等设备节点由内核 ueventd 重建（`crw-rw-rw- 1,3`），数据分区一个字节没动。

---

## 五、踩到的两个硬坑（已解决，写进模块兜底了）

1. **Android paranoid-network**：内核只允许 root 或 AID_INET(**gid 3003**) 组进程创建 AF_INET socket。
   chroot 里 `mysql`(uid 1001)、`redis`(uid 996) 默认不在该组 → mariadbd 报
   `Failed to create a socket for IPv4 '0.0.0.0': errno: 13 / No TCP address could be bound to`。
   修法：`echo 'inet:x:3003:' >> /etc/group; usermod -aG inet mysql redis`（模块每次开机兜底）。
2. **内核不支持 nf_tables、也没有 ipset**：`iptables -N` 报 `Address family not supported by protocol`；
   改用 `iptables-legacy`（可用），并在 `/usr/local/sbin/iptables` 放包装；Fail2ban 的
   `banaction` 由 `firewallcmd-ipset` 改成 `iptables-multiport`。
   另外 chroot 里没有 systemd，补了 `/usr/local/sbin/{systemctl,service,start-stop-daemon}` 兼容层
   （映射到 `/etc/init.d/*`），面板才能启停服务。

---

## 六、回滚点 / 备份

| 内容 | 位置 |
| --- | --- |
| 面板破解前的原文件 | `/data/openeuler/www/server/panel/moli_patch/backup_*/` |
| 宝塔原版 lib.sh | `…/panel/install/lib.sh.bt-orig` —— **实测宝塔 13.0.0 的面板包不带 `install/lib.sh`**，我们的 shim 是新建的，所以本机这个文件**不存在**。`step_components` 的留底逻辑本身是对的（只在原版存在时才留底），只是对这个面板版本没有原版可留 |
| fail2ban 原 Debian 启动脚本 | `/data/openeuler/etc/init.d/fail2ban.debian-orig` |
| fail2ban 原 jail.local | `/data/openeuler/etc/fail2ban/jail.local.moli-orig` |
| 内核备份（此前） | `D:\PAR-AL00_…\my_backup\kernel.img` (md5 `ef5f17daaf4f0173ef5c71df6a706807`) |
| **删除前那台的整份备份**（2026-09-21 22:14） | 设备上 `/data/qyt_backup_20260921/`：`openeuler.tar.zst` 5,976,843,781 字节 sha256 `51159325d30c3789ca986767482bfde42586120a4597207b78f62c4e0d06d2df`、`BASELINE_pre.txt`（磁盘/目录/组件版本/init.d/端口快照）、`pkglist_pre.txt`（548 条 rpm 清单，已作为 `install/baseline-packages.txt` 进仓库）、`module_qiyuntai_btpanel/`（当时的模块） |
| **预制镜像**（2026-09-22 重装后产出） | `/data/qyt_image/`：`qyt-image.part-*` 分卷 + `SHA256SUMS.txt` + `IMAGE-MANIFEST.txt`，同时上传到 Release |

---

## 七、发布与更新

仓库在 GitHub：`https://github.com/moliapiyyds/qiyuntai-btpanel`，本机 `D:\tc\recon\qiyuntai-repo` 是它的工作副本。

### 哪些改动要发版本、哪些不用（2026-09-22 定的规矩）

| 改动 | 要不要升版本 / 发 Release | 用户怎么拿到 |
|---|---|---|
| `module/` 里的东西（`service.sh` / `action.sh` / `customize.sh` / `uninstall.sh` / `README.md`） | **要**：改 `module.prop` 的 version/versionCode、重打 zip、发 Release | 刷新的模块 zip |
| `install/` 部署脚本、`tools/` 工具、文档（README / docs / CHANGELOG） | **不用**：提交推 `main` 就行 | 一键命令拉的就是 `main`（`refs/heads/main`），立刻生效 |

> 所以「`HEAD` 比最新 tag 新几个提交」是**正常的**，不是不一致 —— `tools/verify_sync.sh`
> 比的也是 `module/` 的内容，它只看模块那一条线。tag 依然是对应那一刻的完整快照，
> 想钉住某个版本就拉 `refs/tags/vX.Y.Z`（纯手机那条命令把 `main` 换成 tag 路径即可）。

### 日常改动

```bash
cd /mnt/d/tc/recon/qiyuntai-repo        # WSL 里；Windows 侧是 D:\tc\recon\qiyuntai-repo
bash tools/ci.sh                        # 先本地跑一遍 9 项自检
git add -A && git commit -m "..." && git push origin main
bash tools/verify_sync.sh               # 收尾核对
```

`tools/verify_sync.sh` 查**两件事**：

1. 本地 vs git 远端逐文件 sha（看有没有漏推）
2. **Release 附件新鲜度** —— 按 `module/module.prop` 里的 `version` 找到对应 tag 的 Release，
   下载附件，和本地 `module/` **逐文件比内容**
   （比内容不比 zip 字节：zip 的条目顺序随文件系统 readdir 变，同一份 module/ 在仓库里和
   复制到 `/tmp` 后打出的 sha256 不同 —— 第一版比字节会误报。）

退出码：`0` 全一致 / `2` git 树不一致 / `3` Release 附件过期或取不到。

> v1.2.3 出过一次「脚本推上去了，Release 里的 zip 还是旧的」——
> 当时 verify_sync 只看 git 树，看不出来；第 2 项检查就是为此加的。

### 发新版本（`module/` 内容有改动时才需要）

```bash
# 1) 改 module/module.prop 的 version 与 versionCode
# 2) 同步文档里的版本号：CHANGELOG（把「未发布」改成新版本号）、README 的模块安装示例、
#    本文件第「一、面板访问」上方的版本行，并新增 docs/release-notes-vX.Y.Z.md
# 3) 提交推送
git add -A && git commit -m "切 vX.Y.Z：..." && git push origin main

# 4) 打 zip（版本号从 module.prop 读，脚本会自检 zip 里的 module.prop 对不对）
bash tools/build_module_zip.sh

# 5) 建 tag + Release + 传附件
git tag -a vX.Y.Z -m "栖云台 · 宝塔面板 vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z -R moliapiyyds/qiyuntai-btpanel \
    --title "栖云台 · 宝塔面板 vX.Y.Z" \
    --notes-file "<docs/release-notes-vX.Y.Z.md 的 Windows 路径>" --target main
gh release upload vX.Y.Z _dist/qiyuntai_btpanel-vX.Y.Z.zip -R moliapiyyds/qiyuntai-btpanel --clobber

# 6) 收尾核对（会去查新 Release 的附件）
bash tools/verify_sync.sh
```

> **两个坑**：
> * `gh.exe` 是 Windows 程序，**不认 WSL 的 `/mnt/...` 路径** —— 传文件给它要先 `wslpath -w`。
> * 上了新版本之后，**旧 Release 的附件要保持是它那个 tag 的源码内容**。
>   切版本时如果发现旧的附件是「用新内容打的」（附件和 tag 对不上），
>   用 `git worktree add /tmp/v<旧版本> <旧tag>` 把旧源码检出来重打一次再覆盖。
>   v1.2.3 → v1.2.4 这次就这么处理的。

---

## 八、运行提示

* 手机总内存 5.83 GB，MariaDB 编译峰值吃掉约 2 GB（编制期间我执行过 `am kill-all` 释放后台内存）；后续装大件前建议先清内存。
* dnf 装的 Redis（7.2.15）已被宝塔版（7.2.16）接管，包还在，没跑；如需干净可 `dnf remove redis`。
* Memcached 同理但方向相反：**dnf 源里只有 1.6.22**，基线要的是 1.6.45，所以
  `step_memcached` 从宝塔源码包编到 `/usr/local/memcached`（面板判断它装没装就是看这个路径）；
  dnf 那份只在源码包下架、编不出来时兜底，且日志里会明说版本不同。

---

## 九、版本复核记录（2026-09-21）

> 目的：把文档里写的组件版本跟**设备上的真实运行环境**逐条对一遍。
> 复核方式：在 chroot 里逐个跑版本命令，不用文档里的旧值。

### 复核命令

```sh
ROOT=/data/openeuler
CHENV='HOME=/root PATH=/www/server/panel/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm LANG=C.UTF-8'
ic() { chroot "$ROOT" /usr/bin/env -i $CHENV /bin/bash -c "$1"; }

ic '/www/server/nginx/sbin/nginx -v'                    # OpenResty
ic '/www/server/mysql/bin/mariadbd --version'           # MariaDB
ic '/www/server/php/82/bin/php -v'                      # PHP
ic 'cat /www/server/phpmyadmin/version.pl'              # phpMyAdmin
ic 'fail2ban-client --version'                          # Fail2ban（上游版本）
ic 'cat /www/server/panel/plugin/fail2ban/info.json'    # Fail2ban（插件版本）
ic '/www/server/redis/src/redis-server -v'              # Redis
ic 'cat /www/server/panel/plugin/nodejs/info.json'      # Node.js 管理器插件版本
ic 'unzip -p /www/server/tomcat/lib/catalina.jar META-INF/MANIFEST.MF | grep Specification-Version'  # Tomcat
ic 'supervisord --version'                              # Supervisor
ic 'memcached --version'                                # Memcached
ic 'python3 --version; java -version; javac -version; node -v; npm -v'
```

### 结果

| 组件 | 文档原值 | 实测 | 处理 |
| --- | --- | --- | --- |
| OpenResty | 1.31.1.1 | `openresty/1.31.1.1` | 一致 |
| MariaDB | 10.11.16 | `10.11.16-MariaDB-log for Linux on aarch64` | 一致 |
| PHP | 8.2.33 | `PHP 8.2.33 (NTS)` | 一致 |
| phpMyAdmin | 5.2 | `/www/server/phpmyadmin/version.pl` = `5.2` | 一致 |
| Redis | 7.2.16（2026-09-21 基线） | `Redis server v=7.2.16` | 一致；**2026-09-22 重装时商店只给 8.x 了**，见 §十 |
| Node.js 管理器 | 2.8 | 插件 `info.json` 的 `versions` = `2.8` | 一致 |
| Fail2ban 插件 | 2.6 | 插件 `info.json` 的 `versions` = `2.6` | 一致 |
| **Fail2ban 上游** | **1.1.0** | **`Fail2Ban v1.1.1.dev1`** | **已改正** |
| **Node.js 内置** | **v20.18.3** | **两个都对，指的不是同一个东西**：宝塔管理器 `/www/server/nodejs/v20.18.3/bin/node -v` → `v20.18.3`；系统 `/usr/bin/node -v` → `v20.18.2` | **已澄清** |
| **JDK（java环境管理器）** | **17.0.8** | **`javac 17.0.20`**，目录 `java-17-openjdk-17.0.20.8` | **已改正** |
| Python | 3.13 | `Python 3.13.14`，pip 26.2 | 已补精确值 |
| Java（系统 dnf） | 17 / 11 / 8 | 目录里确实三个都在：`1.8.0_502` / `11.0.32.9` / `17.0.20.8`。**默认 `java` 指向 8**（BiSheng build），**默认 `javac` 指向 17** | 已补说明 |
| **Tomcat** | **文档未列** | **`Specification-Version: 9.0`**（插件名 `tomcat2`） | **已补** |
| **Supervisor** | **文档未列** | **`4.2.4`** | **已补** |
| **Memcached** | **文档未列** | **`1.6.45`** | **已补** |
| git / vim / htop / tmux / jq / sqlite3 | 只写了名字 | 2.43.0 / 9.0 / 3.3.0 / 3.3a / 1.8.2 / 3.42.0 | 已补版本 |
| gcc / make / cmake | 「完整编译链」 | 12.3.1 (openEuler) / 4.4.1 / 3.27.9 | 已补版本 |
| rsync / tcpdump / lsof | 只写了名字 | 3.2.7 / libpcap 1.10.4 / 4.99.3 | 已补版本 |

### 结论

* 组件的**大版本号**（OpenResty / MariaDB / PHP / phpMyAdmin / Redis / Node 管理器 / Fail2ban 插件）**全部对得上**。
* 两处**小版本号写错了**（Fail2ban 上游 1.1.0→**1.1.1.dev1**、JDK 17.0.8→**17.0.20.8**），已改正。
* Node 那条原先判成「写错」，其实是**测错了对象**：`v20.18.3` 是宝塔 Node 管理器内置的，`v20.18.2` 是系统 `/usr/bin/node`。两个都对，现已分别注明。
* 三个组件**文档漏写了**（Tomcat 9.0 / Supervisor 4.2.4 / Memcached 1.6.45），已补。

面板自身的版本号可以从面板界面确认：登录后首页右下角，或「设置 → 面板信息」。

---

## 十、v1.2.6 从零重装复核（2026-09-22）

> 本节记录的是 v1.2.6 那次重装（换成预制镜像那版是 v1.2.6 的镜像）。
> **v1.2.7 只加了部署入口（`deploy-linux.sh` + 纯手机一行）和文档，环境一个字节没变**，
> 所以这一节的结论对 v1.2.7 同样成立。

> **目的**：老板要求「删掉我这个设备已经有的环境（先备份在手机的其他位置），重新跑看看
> 是否可以真的一键部署，部署的和正确的是否真的一样」。所以这一节是**从零重装**的记录，
> 不是把旧环境的结果抄一遍；方法也不是「读一遍脚本觉得没问题」，而是拿基线数据反向对账。

### 10.1 过程与耗时

| 步骤 | 结果 |
|---|---|
| 备份删除前的环境 | `/data/qyt_backup_20260921/`：`openeuler.tar.zst` **5,976,843,781 字节** sha256 `51159325d30c3789ca986767482bfde42586120a4597207b78f62c4e0d06d2df`，外加 `BASELINE_pre.txt`（快照）、`pkglist_pre.txt`（548 条 rpm 清单）、`module_qiyuntai_btpanel/`（当时的模块） |
| 清空 `/data/openeuler` | 走 `prepare-rootfs.sh --clean`（先解挂载、断言挂载数为 0 才删） |
| 一键部署 | `deploy.ps1` → 推 `install/ module/ tools/` → 手机侧 `deploy.sh` → rootfs → dnf → 面板 → 组件（OpenResty / MariaDB / PHP / phpMyAdmin）→ 自动重启。**约 3 小时 40 分**，其中 MariaDB 源码编译是长杆 |
| 补齐（看门狗自动做） | `deps` / `plugins`(9 个 + memcached 编译 + Tomcat 铺设) / `parity` / `patch` / `module` |
| 打预制镜像 | `make_image.sh`：清理前 17706 MB → 清理后 7983 MB，xz -T0 -1 → 整包 2,227,295,452 字节，分 2 卷 |
| 从镜像重装 | 清空后 `deploy.sh --from-image` → 手动跑模块 `service.sh` → 逐项核对 |

### 10.2 对账结果（全部实测）

| 项 | 基线 | 重装后 | 结论 |
|---|---|---|---|
| 面板 | 13.0.0 | **13.0.0** | 一致 |
| OpenResty | 1.31.1.1 | **1.31.1.1** | 一致 |
| MariaDB | 10.11.16 | **10.11.16** | 一致 |
| PHP | 8.2.33 | **8.2.33** | 一致 |
| phpMyAdmin | 5.2 | **5.2** | 一致 |
| Redis | 7.2.16 | **8.0.6** | **不同** —— 商店的 redis 现在只给 8.x（8.0/8.2/8.4/8.6/8.8/7.4），7.2 已下架，本地固定不了 |
| Memcached | 1.6.45 | **1.6.45** | 一致（从宝塔源码包编的同一版） |
| Tomcat | 9.0（catalina 9.0.62） | **9.0（9.0.62）** | 一致（Apache 归档取的同版本） |
| Supervisor | 4.2.4 | **4.2.4** | 一致 |
| Node（系统 / 管理器） | v20.18.2 / v20.18.3 | **v20.18.2 / v20.18.3** | 一致 |
| java（默认） | 1.8.0_502 | **1.8.0_502** | 一致 |
| 面板插件 | 9 个 | **9 个** | 一致 |
| rpm 包 | 548 条 | 基线 547 个包名**全在位**（总数 551） | **逐名对齐**（多的 4 个是部署自己用的：expect 等） |
| 环境占用 | 17.7 GB | **17706 MB（17.7 GB）** | 一致 |
| 开机服务 | 11 项 | **11 项全起**（init✓ + 进程✓） | 一致 |
| 端口 | 80/888/3306/6379/11211/8080/8005/22 | **全部 LISTEN** | 一致 |
| 面板自检 | HTTP 200 | **HTTP 200**（明文 http + 浏览器 UA） | 一致 |
| 破解状态 | ltd=0 / pro=-1 | **ltd=0 / pro=-1** | 一致 |

**从镜像装的那一遍额外验证的**：

* **冷启动实测**（2026-09-22 08:00，真 `reboot` 之后没有做任何手动操作）：
  `boot_completed=1` 后模块自己跑完 `service.sh` —— 日志里 fail2ban → crond → redis →
  memcached → Tomcat（`用 JAVA_HOME=/usr/lib/jvm/java-17`）→ supervisord →
  sshd（`启动成功，监听 :22`）→ 面板自检（`已响应（http://127.0.0.1:20318/b93838db）`）
  全部成功；开机 3 分钟后 `netstat` 有 80/888/3306/6379/11211/8080/8005/22 八个端口在听，
  面板 HTTP 200，`audit_env.sh` 的 11 项服务全部 `init✓ 进程✓`。
* 端口 / 安全入口 / 用户名 / 密码 **每次都不一样** —— 三次实测分别是
  `26358 + /7318e9d4`（从零装）、`33733 + /b5cffaa3`（第一次 from-image）、
  `20318 + /b93838db`（重打镜像后的 from-image），
  凭据文件里的用户名/密码也是每台一套（`openssl rand`）→ 镜像里烘的身份确实被重新随机化了。
* sshd 主机密钥在 `--from-image` 时重新生成（3 个密钥文件都是新的）。
* `make_image.sh` 存的是**未打补丁的原版**：从镜像装完立刻查 `moli_patch/.patched`
  是「已打」（部署时打的），而镜像里的 `moli_patch/` 已被 revert 后清掉。
* 服务启动日志（`boot.log`）从「跳过 crond/redis/memcached/tomcat、未找到 sshd 配置」
  变成 11 项全部启动成功 —— 这两个状态在同一条 `boot.log` 里能直接对比出来。

### 10.3 差额说明（不假装没有）

1. **Redis 8.0.6 vs 基线 7.2.16**：宝塔商店的决定，不是本地能固定的。文档已按 8.0.6 写，
   并在 §九 那张历史表里标注了这一点。
2. **rpm 总数 551 vs 548**：基线 548 行里有 1 行是 `gpg-pubkey` 伪包（没有 .arch 后缀，
   比对时被滤掉），实际比的是 547 个包名，全在位；多出来的 4 个是本项目自己要用的
   （`expect` 等），parity 步骤只做「补齐」不做「删除」。
3. **bt 管理的 node 版本**（`/www/server/nodejs/v20.18.3`）第一版镜像里没有 ——
   因为 nodejs 插件只装插件文件、版本要另外装。发现后加了 `step_node`，
   重打镜像并重新做了端到端验证（现在这版镜像里有，161 MB）。

### 10.4 这一轮查出来并修掉的问题

`CHANGELOG.md` 的 v1.2.5 / v1.2.6 两节 + `docs/pitfalls.md` 里逐条有记录，共 14 类，
其中「文档有、实现没有」的 4 类（init 脚本、sshd、memcached 二进制、Tomcat 软件本体）、
「静默失败」的 5 类（补丁打半截、面板自动 SSL、`warn` 未定义、两行粘成一行、
`--from-image` 清单读错位置），以及部署链路自身的 5 类。

**一句话结论**：从零一键部署能跑通，装出来的环境与基线**逐项一致**（rpm 包名、
组件版本、9 个插件、11 项服务、端口、补丁状态），只有 Redis 大版本跟着宝塔商店往前走了；
预制镜像这条路也端到端验证过，且身份每次重新随机化。

---

## 十一、交付路线改成一镜像到底 + 端到端实测（2026-09-22 晚）

### 11.1 为什么改（起因是一次实测）

用户要求「把面板卸了、用一键脚本重装一次」，实测结果：

| 日期 | 官方安装器脚本 sha256 | 装出来的面板版本 |
|---|---|---|
| 2026-09-21 | `95ed59e4…`（命中 `installer.lock`） | `13.0.0` |
| 2026-09-22 | `95ed59e4…`（**同一个**，仍命中） | **`13.1.0`** |

安装器脚本没变、**面板包变了**（官方更新于 2026/09/18）。补丁是版本门禁的
（`PANEL_VERIFIED = ['13.0.0']`），所以当天走官方源的一键部署会在 `patch` 步骤明确失败。

加 `--force` 实测：**13.1.0 上锚点漂移 0/8**（8 项校验全正常、4 个 py 文件语法 OK、
254 个 JS 版本戳更新）。所以问题**不是「补丁会坏」，而是「面板版本不在我们手里」** ——
交付物不可复现，宝塔每发一版都要人工重核验一遍。**结论：默认只走预制镜像。**

### 11.2 端到端实测（清环境 → 从镜像铺 → 重启 → 核对）

全程在 HUAWEI PAR-AL00 上跑，日志 `/data/local/tmp/qyt_e2e.log`：

| 阶段 | 命令 | 结果 | 耗时 |
|---|---|---|---|
| 清旧环境 | `prepare-rootfs.sh --clean` | exit 0；宿主 `/dev` 完好（256 项、`/dev/null` 仍是字符设备 1,3、`/dev/socket` 29、`getprop` 正常） | ~1 分钟 |
| 取件核对 | `fetch-image.sh --check` | 2 卷 + 整包 sha256 全通过 | ~1 分钟 |
| 铺镜像 | `deploy.sh --from-image … --no-reboot` | **exit 0**；分卷拼接 + 整包 sha256 校验通过 → 解包 7983 MB | **约 12 分钟**（busybox xz 单线程） |
| 身份随机化 | 同上（creds 步骤） | 第 4 组：端口 `58571` / 入口 `/5c009129` / 用户 `5311b8b3` | — |
| 插件 | 同上（plugins） | 9/9 在位，memcached / Tomcat / Node 都判定已存在 | ~1 分钟 |
| 基线对齐 | 同上（parity） | **基线包名 547 个 / 已在位 547 个 / 缺 0 个** | ~30 秒 |
| 补丁 | 同上（patch） | `.patched` = `panel=13.0.0 patch=r1` | ~20 秒 |
| 模块 | 同上（module） | 装到 `/data/adb/modules/qiyuntai_btpanel` | — |
| 重启 | `sync; reboot` | 开机自启：**nginx 10 / mariadbd 1 / php-fpm 11 / redis 1 / memcached 1 / tomcat-java 1 / sshd 1 / BT-Panel 1** | ~2 分钟 |
| 面板 | 浏览器 UA 打入口 | **HTTP 200**，`<title>宝塔Linux面板</title>`；同一条 URL 用裸 `curl` 仍是 404（反爬，符合 §一.6） | — |

**总耗时约 15 分钟**（清环境 → 重启后可用），其中解包占 12 分钟。
面板版本是镜像里冻的 **13.0.0**（不是官方当前的 13.1.0）—— 这正是改路线的目的。

### 11.3 这一轮查出来并修掉的问题

1. **`prepare-rootfs.sh --clean` 惰性卸载后删不干净**（`rm: Directory not empty`，残留空的 `dev`）：
   `umount -l` 摘掉挂载后，挂载点目录要等引用释放才能删。现在重试 6 次 + `rmdir` 空挂载点。
   *注意安全设计本身是有效的*：宿主 `/dev` 全程完好，`deploy.sh` 也按设计拒绝了在非空目录上解包。
2. **shell `$(( ))` 是 32 位有符号**：`2227295452 / 1048576` 溢出，屏幕上打出「镜像大小：-1971 MB」。
   校验本身是字符串比较、没受影响；显示值改用 `awk` 算（`deploy.sh` / `fetch-image.sh` / `make_image.sh` 三处）。
3. **`--tries` 试满就 `rm` 半截文件** —— 等于在最需要续传的时候把续传数据删掉。现在只有
   「大小对但哈希不对」才删。
4. **`make_image.sh` 默认每卷 1900 MB 太大**：那是为上传省的。镜像成了唯一交付路径后，
   下载端更难伺候（手机直连 GitHub 会撞上 `github.com` 那一跳间歇性超时），默认改成 **500 MB**。
   同时它会**直接打印可粘贴的 `install/image.lock` 行**，免得手抄 64 位哈希。
5. **`.ps1` 用编辑工具改完会丢 BOM** → PowerShell 5.1 按 GBK 解析报一堆假语法错（`tools/ci.sh`
   第 6 项就是查这个，已复现一次）。

### 11.4 已知但没解决（诚实清单）

* 手机直连 GitHub 下 2.2 GB 仍是**看运气**：实测同一 URL 5 次全 timeout、几分钟后同样跑到 11 MB/s。
  脚本能续传+重试（`--tries 0` 一直磨），但**要稳还是得用电脑侧**。
* v1.2.6 那份镜像是 2 卷（1900 MB + 224 MB），**没有按新的 500 MB 重打**（重发 2.2 GB 不值当）。
  下次重打镜像时会自动按 500 MB 分。
* 解包 12 分钟是 `busybox xz` 单线程的极限；chroot 里的 `xz -T0` 多线程快得多，
  但铺镜像的时候 chroot 还没解出来（鸡生蛋问题），没做绕法。
