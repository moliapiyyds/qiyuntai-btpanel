# 栖云台 · 宝塔面板 —— 交付说明（2026-09-20 凌晨完工）

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
| Redis | **7.2.16**（宝塔托管） | `PONG`，监听 127.0.0.1:6379 |
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
版本          v1.2.3   (versionCode 10203)
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

---

## 七、发布与更新

仓库在 GitHub：`https://github.com/moliapiyyds/qiyuntai-btpanel`，本机 `D:\tc\recon\qiyuntai-repo` 是它的工作副本。

```bash
# 改完东西推上去
cd D:\tc\recon\qiyuntai-repo
git add -A && git commit -m "..." && git push origin main

# 只改了 module/ 里的东西时，必须重打 zip 并覆盖 Release 附件
bash tools/build_module_zip.sh
gh release upload v1.2.3 _dist/qiyuntai_btpanel-v1.2.3.zip --clobber

# 检查本地和远端有没有漏推
bash tools/verify_sync.sh
```

> 注意：`tools/verify_sync.sh` 只比「本地 vs git 远端」，
> **不会告诉你 Release 附件过期了** —— 所以只要动了 `module/`，就一定要重打 zip 并覆盖附件。
> （v1.2.3 出过一次这种：脚本推上去了，Release 里的 zip 还是旧的。）

---

## 八、运行提示

* 手机总内存 5.83 GB，MariaDB 编译峰值吃掉约 2 GB（编制期间我执行过 `am kill-all` 释放后台内存）；后续装大件前建议先清内存。
* dnf 装的 Redis（7.2.15）已被宝塔版（7.2.16）接管，包还在，没跑；如需干净可 `dnf remove redis`。

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
| Redis | 7.2.16 | `Redis server v=7.2.16` | 一致 |
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
