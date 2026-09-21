# 栖云台 · 宝塔面板 v1.2.6

`versionCode = 10206` · 2026-09-22

把 **宝塔 Linux 面板** 装进安卓手机：`openEuler 24.03 LTS-SP3 (aarch64)` chroot +
宝塔官方组件，用 **KernelSU 模块** 开机自动挂载并拉起全部服务。

> 实测机型：HUAWEI PAR-AL00（nova 3 / 麒麟 970 / 鸿蒙 2.0 / Android 9 / 内核 4.9.148）

---

## 这一版的两个交付物

1. **模块 zip**（`qiyuntai_btpanel-v1.2.6.zip`）—— 开机挂载 chroot、拉起 11 项服务、
   自检面板；`service.sh` / `action.sh` 有几处实测修出来的改动（见下）。
2. **预制镜像**（`qyt-image.part-aaa` + `qyt-image.part-aab`，共 2.07 GB）——
   这次**从零重装、逐项对账**之后打出来的环境，装第二台约 10 分钟，
   而且完全不依赖宝塔的服务器。

---

## 模块这边改了什么

* **`service.sh` 4.5 段补 `memcached` 的组身份**：memcached 的 init 脚本用
  `-u memcached` 起（它拒绝以 root 跑），而它降权时只做 `setgid/setuid`、**不带附加组**
  ——所以光 `usermod -aG inet` 不生效，必须把它的**主组**改成 `inet`。
  不改的话它 bind 127.0.0.1:11211 会被 Android 的 paranoid-network 拒绝。
* **`service.sh` 的开机自检会补试 HTTPS**：面板可能被 bt 那个「自动申请 IP 证书」
  任务切成只收 HTTPS（写了 `data/ssl.pl`），那时明文 http 连上会被 reset ——
  现在会补试一次 `curl -k https`，并在日志里说清楚「面板 SSL 是开着的 / 怎么关」。
* **`action.sh` 的地址按实际协议打印**：读 `data/ssl.pl` 决定 `http://` 还是 `https://`，
  并且 `httpcode()` 加 `-k`（自签证书否则拿不到状态码）。
* **`customize.sh` 的引导文案路径修正**：`prepare-rootfs.sh` / `qiyuntai-install.sh`
  都在 `install/` 下，而且推荐推到 `/data/local/tmp/qyt-repo`（见下）。
* `module/README.md` 与实现对齐（Redis 版本、Tomcat 来源、卸载用 `--purge`）。

---

## 部署脚本这边改了什么（详细记录在 CHANGELOG / docs/pitfalls.md）

同一套「拿基线数据反向对账」的办法又查出 4 个缺口，加上链路自己的 5 个 bug：

| # | 问题 | 后果 | 现在 |
|---|---|---|---|
| 1 | **Tomcat 软件本体没有任何来源**：面板这个版本 `install/` 下没有 tomcat 安装脚本，`tomcat2` 插件的 `install.sh` 是空壳 | `/www/server/tomcat` 根本不存在，`start_svc tomcat` 永远「跳过」 | 新增 `step_tomcat`：从 Apache 归档取 **apache-tomcat-9.0.62**（与基线同版本）解到 `/www/server/tomcat` |
| 2 | **memcached 的组身份不对** | bind 被拒，只留一句「memcached 启动失败」 | 把它主组改成 `inet`（`step_memcached` / `android-network-fix.sh` / `service.sh` 三处） |
| 3 | **redis 插件装不上**：`plugin_install.py` 只看软件路径就判「已安装」+ 面板把安装排进异步任务队列 | 插件目录、`/etc/init.d/redis` 都没有 | 判「已安装」要求插件目录也在；异步任务会等（`PLUGIN_WAIT`，默认 900 秒） |
| 4 | **`/sdcard` 是 CE 存储** | 手机重启后没解锁一次，`/sdcard` 就不可用 → `adb push` 全灭（而部署最后一步就是重启） | 推送/执行目录换到 `/data/local/tmp/qyt-repo`（DE 存储），`deploy.ps1` 新增 `-Dest` |
| 5 | **面板自己会开 SSL** | 明文 http 连上被 reset（不是 404），极易误判成「面板没起来」 | `step_patch` 三层关掉（删 `ssl.pl` + 空壳 `panel_ssl_task.py` + 删 `check_ssl_cron.pl`） |
| 6 | **打补丁时缺 `node`** | 补丁只打了后端、前端那两条没做，日志里只有一段调用栈 | `moli_patch.py` 没 node 就明确跳过并报出；`step_deps` 加 `nodejs npm`；打完立刻 `verify` |
| 7 | **`install/qiyuntai-install.sh` 用了 18 处 `warn` 但没定义** | 所有警告都是 `sh: warn: not found`，一条都打不出来 | 补上 `warn()`（走 stderr） |
| 8 | **一次编辑把两行粘成一行** | `chroot-compat-layer.sh` 永远不会执行 → 兼容层一个都不装 | 修回两行（这类错误 `sh -n`/shellcheck 都拦不住） |
| 9 | `--from-image` 拼接出来的整包不删、清单读错位置、漏了 `parity` | 白占几 GB / 清单看不到 / 包清单不对齐 | 三处都修，现在是 `creds → plugins → parity → patch → module` |

---

## 装法

### 1) 用预制镜像装（最快，约 10 分钟）

```powershell
# 1) 下载镜像两卷 + 校验和 + 清单
& gh release download v1.2.6 --repo moliapiyyds/qiyuntai-btpanel --pattern 'qyt-image*' --dir .\qyt_image
& gh release download v1.2.6 --repo moliapiyyds/qiyuntai-btpanel --pattern 'SHA256SUMS.txt' --dir .\qyt_image
& gh release download v1.2.6 --repo moliapiyyds/qiyuntai-btpanel --pattern 'IMAGE-MANIFEST.txt' --dir .\qyt_image

# 2) 推到手机（约 2 GB，走 USB；推 /data/local/tmp，不用 /sdcard —— 手机锁屏时 /sdcard 不可用）
adb shell "mkdir -p /data/local/tmp/qyt_image"
adb push .\qyt_image\. /data/local/tmp/qyt_image/

# 3) 先把仓库推上去（install/ module/ tools/ 必须在同一层）
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1 -PushOnly

# 4) 手机上：先空出 /data/openeuler，再从镜像铺
$D='/data/local/tmp/qyt-repo'
adb shell "su -c 'sh $D/install/prepare-rootfs.sh --clean'"
adb shell "su -c 'sh $D/install/deploy.sh --from-image /data/local/tmp/qyt_image'"
```

`--from-image` 会自己 `cat` 分卷 → 重算 sha256 与 `SHA256SUMS.txt` 比对 →
**对不上就直接停下、不铺环境**。铺完会重新随机化端口/入口/用户名/密码与 sshd 主机密钥。

### 2) 从零装（约 2 小时，源码编译 OpenResty / MariaDB / PHP）

```powershell
git clone https://github.com/moliapiyyds/qiyuntai-btpanel.git
cd qiyuntai-btpanel
.\deploy.ps1
```

### 3) 只装 / 更新模块

```sh
adb push qiyuntai_btpanel-v1.2.6.zip /data/local/tmp/
adb shell "su -c '/data/adb/ksud module install /data/local/tmp/qiyuntai_btpanel-v1.2.6.zip'"
```

* `ksud` 在 **`/data/adb/ksud`**（不在 `PATH` 里）
* 解包到 `/data/adb/modules_update/<id>`，执行 `customize.sh`，**重启后生效**
* 也可以在 KernelSU 管理器里「从本地安装」选这个 zip

重启后点模块的「执行」按钮，地址、账号、密码会直接打印出来。

---

## 附件与校验

| 文件 | 大小 | sha256 |
|---|---|---|
| `qiyuntai_btpanel-v1.2.6.zip`（模块） | 20,787 B | `a9b1ee0029fdf3d3237622775578c635d712d68c1ff65a58f0ac103a06ad60eb` |
| `qyt-image.part-aaa` | 1,992,294,400 B | `e113c6653c81a764b8bc84ad3be9a8e1ee66377f0f59266b111a1358820a4130` |
| `qyt-image.part-aab` | 235,001,052 B | `672b6bab1a9b8dcd31dff35a6f66bfa8be8c65827e454eb26dc403059e6f7ee2` |
| 整包（两卷拼起来） | 2,227,295,452 B | `9f846cfa1ded8767d0b7e33722eb7546b7db08a8ddc70604fca60e04e7d4e284` |
| `SHA256SUMS.txt` | — | 上面三个值都在里面（第一行是整包） |
| `IMAGE-MANIFEST.txt` | 1068 B | 打包时间 / 面板版本 / 清理前后大小 / 组件真实路径 / rpm 包数 |

---

## 装完是什么样（与基线逐项对比）

| 项 | 值 |
|---|---|
| 面板 | 宝塔 **13.0.0**（改造后永久企业版 `ltd=0 / pro=-1`、关闭更新、免绑定） |
| 组件 | OpenResty **1.31.1.1** / MariaDB **10.11.16** / PHP **8.2.33** / phpMyAdmin **5.2** |
| 缓存与队列 | Redis **8.0.6**（redis 插件当前版本；基线那台是 7.2.16，商店已下架）/ Memcached **1.6.45**（宝塔源码包编） |
| Tomcat | **9.0**（`catalina.jar` 9.0.62，从 Apache 归档取） |
| 面板插件 | **9 个**：fail2ban redis tomcat2 supervisor nodejs java_manager jdk_manager pyenv_manager pythonmamager |
| 开机服务 | **11 项**：bt nginx mysqld php-fpm-82 fail2ban crond redis memcached tomcat + supervisord + sshd |
| rpm 包 | 基线 548 条**逐名对齐**（`parity` 步骤，实测「基线包名 547 / 在位 547 / 缺 0」；总数 551，多出的是部署自己用的几个） |
| chroot 大小 | 装完 **17.7 GB**（与基线一致）；镜像里已清掉编译残留 → **7.98 GB**（含 bt 管理的 node v20.18.3） |

---

## 已知限制（都实测过）

* 只在 **HUAWEI PAR-AL00（麒麟 970 / Android 9 / KernelSU-Next 3.3.0）** 上验证过，
  其它机型不保证。
* **手机重启后要先解锁一次**，否则 `/sdcard`（CE 存储）不可用 —— 所以本项目的推送路径
  都用 `/data/local/tmp`。见 `docs/pitfalls.md` §六.6。
* 面板 SSL 默认关着（本项目把它关了，因为文档/自检都是 `http://`）。想用 HTTPS
  就在面板里开，地址跟着改成 `https://`，模块自检会自己适配。
* `memcached` 只有宝塔源码包那条路能给到基线版本（1.6.45）；宝塔哪天把那个 tarball
  下架，脚本会退回 dnf 的 1.6.22 并打警告。
* 宝塔官方安装器 `install_panel.sh` 的 sha256 锁在 `install/installer.lock`：
  官方一改脚本就会**拒绝安装**（而不是拿没核验过的脚本硬跑）。
* Redis 的版本会跟着宝塔商店走（这次是 8.0.6，基线是 7.2.16）——
  这是商店侧的变化，不是本地能固定的。
