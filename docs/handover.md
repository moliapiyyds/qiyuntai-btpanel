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
| 宝塔面板 | 9.5.0 (aarch64) | 登录页 200，进程 BT-Panel |
| Web | **OpenResty 1.31.1.1** | `nginx -v` → openresty/1.31.1.1，`nginx -t` ok，监听 80/888 |
| 数据库 | **MariaDB 10.11.16** | `select version()` → 10.11.16-MariaDB-log，监听 3306 |
| PHP | **8.2.33** | `php -v` → 8.2.33，php-fpm 运行，`/tmp/php-cgi-82.sock` |
| phpMyAdmin | **5.2** | `/www/server/phpmyadmin/version.pl` = 5.2 |
| Fail2ban | **2.6**（内含 fail2ban 1.1.0） | 封禁 203.0.113.9 → `f2b-sshd` 规则出现 → 解封消失 |
| Redis | **7.2.16**（宝塔托管） | `PONG`，监听 127.0.0.1:6379 |
| Node.js 管理器 | 2.8（宝塔插件） | 商店显示已安装/运行中 |
| 额外环境 | Python 3.13 + pip/venv、OpenJDK 17/11/8、Node 20.18 + npm 10.8、git、vim、htop、tmux、jq、sqlite3、gcc/make/cmake 编译链、rsync、tcpdump、lsof 等 | 逐个 `--version` 核对通过 |

商店「已安装」核对（脚本 `store_check.py`）：nginx / mysql / phpmyadmin / fail2ban / nodejs / redis 全部 **是**。
phpMyAdmin 那条显示「已停止」是宝塔语义（未对公网开放），不是没装。

---

## 三、面板改造（破解）—— 实测生效

| 需求 | 做法 | 验证 |
| --- | --- | --- |
| 显示**永久企业版** | `panelPlugin.get_cloud_list()` 返回前把 `ltd`/`pro` 覆盖为 **-2**（宝塔内部 -2 = 永久）；`expire_msg()` 打成空函数，屏蔽到期提醒 | 真调云端列表返回 `ltd=-2 pro=-2`；前端 `utils.js` 读 cookie `ltd_end=-2` → `advanced='ltd'` → 企业版 |
| **去除更新** | `script/upgrade_panel.py`、`upgrade_panel_optimized.py`、`polkit_upgrade.py`、`update.sh` 替换为空壳；清掉 crontab 更新任务 | 四个文件均为空壳（355 B），原文件在 `panel/moli_patch/backup_*/` |
| **免账号绑定** | `public.is_bind()` 恒返回 True；预置 `data/initBind.pl`、`data/bind.pl` | 实测 `public.is_bind() = True` |
| 补丁本体 | `/www/server/panel/moli_patch/moli_patch.py`（幂等，可重复执行） | 语法检查通过 |

> 服务端依赖的功能（SSL 签发、短信、云备份、需 bt.cn 鉴权的付费插件）本地伪造不了，属于宝塔服务器校验。

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
| 宝塔原版 lib.sh | `…/panel/install/lib.sh.bt-orig` |
| fail2ban 原 Debian 启动脚本 | `/data/openeuler/etc/init.d/fail2ban.debian-orig` |
| fail2ban 原 jail.local | `/data/openeuler/etc/fail2ban/jail.local.moli-orig` |
| 内核备份（此前） | `D:\PAR-AL00_…\my_backup\kernel.img` (md5 `ef5f17daaf4f0173ef5c71df6a706807`) |

---

## 七、明天要做的：上传 GitHub

仓库已经在本地整理好（**内容已实测过一遍**）：

```
D:\tc\recon\qiyuntai-repo\
  README.md                       对外说明（含注意事项/已验证清单/联系方式）
  LICENSE                         MIT
  module\                         模块（module.prop / service.sh / uninstall.sh / customize.sh / README.md）
  install\qiyuntai-install.sh     一键部署脚本（rootfs→chroot→面板→组件→插件→补丁→模块）
  install\chroot-compat-layer.sh  systemctl/service/start-stop-daemon/iptables-legacy 兼容层
  install\android-network-fix.sh  paranoid-network 修正（mysql/www/redis 入 inet 组）
  install\crond.initd             crond 的 SysV 启动脚本
  install\lib-shim.sh             宝塔 lib.sh 精简版（跳过无用的 openssl/mcrypt 源码编译）
  tools\moli_patch.py             面板改造补丁
  tools\plugin_install.py         宝塔插件安装器（免登录走官方下载接口）
  tools\store_check.py            商店「已安装」状态核对
  docs\pitfalls.md                踩坑记录（宝塔侧 + Android 侧，全实测结论）
```

上传步骤（明天执行）：
```powershell
cd D:\tc\recon\qiyuntai-repo
git init
git add -A
git commit -m "栖云台·宝塔面板 for Kirin970/HarmonyOS2 (KernelSU)"
git branch -M main
git remote add origin https://github.com/<你的账号>/qiyuntai-btpanel.git
git push -u origin main
```
（建议仓库名 `qiyuntai-btpanel`；要在 GitHub 上先建好空库，不要勾 README。）

---

## 八、还没验证 / 有风险的部分（诚实清单）

* 面板里 firewalld、Docker、邮件告警、SSL 证书签发、云备份、需要 bt.cn 鉴权的付费插件下载 —— 依赖 systemd/内核能力/宝塔服务器，未测，预计不可用或不可靠。
* 换机型适配未测：内核版本、SELinux 策略、KernelSU 版本不同都可能要重新调。
* 手机总内存 5.83 GB，MariaDB 编译峰值吃掉约 2 GB（编制期间我执行过 `am kill-all` 释放后台内存）；后续装大件前建议先清内存。
* 面板商店里 phpMyAdmin 显示「已停止」= 未开放公网访问，属正常；需要的话在面板里点"开放"。
* dnf 装的 Redis（7.2.15）已被宝塔版（7.2.16）接管，包还在，没跑；如需干净可 `dnf remove redis`（未做，怕影响其他依赖）。
