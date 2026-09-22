## v1.2.5 — 2026-09-22

`versionCode = 10205`

这一版改的主体是**部署脚本**（`install/`）：把「文档里承诺了、脚本从没做过」的东西
一处一处补上。`module/` 的**代码逻辑没改**，只动了 `module.prop` 的版本号 ——
切版本号是为了让「tag / Release 附件」指向同一个提交。

> 下面这些条目相对 v1.2.4 的增量。Release 说明见 `docs/release-notes-v1.2.5.md`。

### `crond` / `tomcat` / `memcached` 的 init 脚本从来没被装进 chroot

* 实测（`/data/local/tmp/qyt_check_initd2.sh`）chroot 里 `/etc/init.d/` 只有
  `README`、`bt`、`nginx` 三项。于是逐个服务对账「这个 init 脚本谁给」：

  | 服务 | init 脚本来源 |
  |---|---|
  | `bt` `nginx` `mysqld` `php-fpm-82` | 宝塔安装器 / 组件安装脚本 |
  | `fail2ban` `redis` | 宝塔对应插件 |
  | `crond` `tomcat` `memcached` | **没有任何上游来源**，只能仓库自己写 |

* 后果不是报错，是**静默跳过**：`module/service.sh` 的 `start_svc` 在
  `/etc/init.d/<名字>` 不存在时只打印一行「跳过」，然后什么都不发生。
  `crond` 还有 `/usr/sbin/crond` 兜底，`tomcat` 和 `memcached` **没有兜底** ——
  也就是 Tomcat、Memcached 永远起不来，而启动日志看着一切正常。
* `install/crond.initd` 和 `install/tomcat.initd` **早就在仓库里，但没有任何脚本引用它们**，
  只出现在文档里。现在 `install/qiyuntai-install.sh` 的 `step_patch` 会把它们
  `cp` 进 `$ROOT/etc/init.d/` 并 `chmod 755`。
* 同一次对账里发现 `memcached` 连 `.initd` 都没有，补了 `install/memcached.initd`
  （openEuler 的 memcached 包只带 systemd 单元，chroot 里没有 systemd；宝塔那 9 个插件
  里也没有 memcached 插件），一并纳入 `step_patch` 的安装清单。
* 再往下追一层发现**连 memcached 这个二进制都没有来源**：面板 13.0.0 的
  `install_soft.sh` 里已经搜不到 memcached，openEuler 源里只有 1.6.22，而基线是 **1.6.45**
  装在 `/usr/local/memcached/bin/memcached`（2019 年那份宝塔 init 脚本写死的路径，
  也正是 README 里写的「面板商店判断装没装」的路径）。
  实测宝塔下载站上 **只有** `memcached-1.6.45.tar.gz` 返回 200（1.6.22 / 1.6.38 都是 404），
  所以基线那份就是从它编出来的。新增 `step_memcached`：照这个路径编 1.6.45
  （sha256 pin `d362c64e…`），编不出来才退回 dnf 的 1.6.22 并在日志里说明版本不同。
* **memcached 起不来的真因（实测定位）**：它的 init 脚本用 `-u memcached` 起
  （memcached 拒绝以 root 跑），而它降权时只做 `setgid/setuid`、**不带附加组**
  （`/proc/<pid>/status` 的 `Groups:` 是空的），于是 Android 的 paranoid-network
  过不去，bind 127.0.0.1:11211 报 `Permission denied` —— 而 init 脚本把输出吞了，
  只留一句「memcached 启动失败」。三种写法实测：
  「主组改 inet + `-u memcached`」成功、「`-u root`」成功、「只加附加组」失败。
  所以把 `memcached` 的**主组**改成 `inet`（三处：step_memcached / android-network-fix.sh /
  service.sh 开机兜底）。


### 新增「基线包对齐」步骤（`parity`）

* 手写脚本漏装是常态，读代码查不全，那就对数据：仓库里带一份
  `install/baseline-packages.txt`（删除前那台的 `rpm -qa` 输出，548 行 / 20899 字节，
  sha256 `4b3c870a…`，与设备上那份逐字节一致）。
* `parity` 按**包名**比对（版本会被源往前推：实测 glibc/libxml2/util-linux 等 20 来个
  名字相同版本不同），缺的先批量装、不行再逐个兜底，最后如实报告源里已经没有的那些名字。
* 实测这步补齐了 java-*-openjdk / jq / htop / bind-utils / libpcap 等一批基线里有的包。


### sshd 兜底通道（`:22`）同样是「文档里有、脚本里没有」

* `module/service.sh` 第 4.7 段会拿 `/etc/ssh/sshd_config_moli` 拉起 `/usr/sbin/sshd`，
  文档也写着它，但**没有任何脚本装 `openssh-server`，也没有任何脚本写这个配置文件**。
  实测：`step_deps` 的 dnf 清单里根本没有 openssh 相关的包。
* 基线（删除前那台）确认是活的：`netstat` 有 `0.0.0.0:22  LISTEN  …/sshd_config_mo`，
  `pkglist_pre.txt` 里有 `openssh-server-9.6p1-21.oe2403sp3`。也就是说它当年是手工装的。
* 现在：`step_deps` 加 `openssh-server openssh-clients`，`step_patch` 把
  `install/sshd_config_moli` 装到 `/etc/ssh/`，并在缺主机密钥时跑一次 `ssh-keygen -A`。
  配置文件内容是从删除前的备份 tarball 里原样取出来的 —— 365 字节，
  sha256 `951da0fbe8f7e6101582d61fd2778a4094fd4c536e6adf4e81fa992bd2e064d7`，与备份逐字节一致。
* 顺带：`--from-image` 的时候会**重新生成主机密钥**（`rm -f /etc/ssh/ssh_host_*` + `ssh-keygen -A`），
  否则同一个镜像刷多台设备会共用同一份主机密钥。

---

## v1.2.7 — 2026-09-22

`versionCode = 10207`

**只加部署入口，没动模块代码**（`module/` 里只有 `module.prop` 的版本号变了）——
装了 v1.2.6 的人不必为此更新模块。Release 说明见 `docs/release-notes-v1.2.7.md`。

### 三个平台都有一条命令

* 新增 **`deploy-linux.sh`**：Linux / macOS 侧的 `deploy.ps1` 等价入口，做的事完全一样
  （找 adb → 等设备 → 探 root → 推 `install/module/tools` 到 `/data/local/tmp/qyt-repo`
  → 手机上跑 `install/deploy.sh`）。参数 `--check` / `--push-only` / `--no-reboot` /
  `--adb` / `--dest` / `--serial`，`-h` 看帮助。用 bash 写但避开了 bash 4 特性（macOS 自带 3.2 能跑）。
  实测：`--check` 认设备与 root 正常、`--push-only` 推出 13+6+8 个文件、
  设备上那份 `module.prop` 是当前版本。
* 新增**纯手机终端一行**（不用电脑）：`busybox wget` 从 `codeload.github.com` 拉仓库 tar
  → `busybox tar --strip-components=1` 解开 → 直接跑 `install/deploy.sh`。
  实测：拉到 146,351 字节、解包后 `deploy.sh --check` 全绿。
* 预制镜像也能让手机自己下，但**这条不稳**：Release 附件走 `objects.githubusercontent.com`，
  实测同一 URL 有时下得动（482 字节与 235,001,052 字节都成功过），有时连着 5 次
  `Connection reset by peer`。而仓库 tarball 那条（`codeload.github.com`）复测 3 次全稳。
  所以「纯手机自举」可靠，「纯手机下镜像」要看运气 —— 文档里就是这么写的。

### 顺带改掉一处过时口径

文档里写了两天的「手机上的 `busybox wget` 连 `github.com` 会被重置，所以只能电脑侧准备」，
**2026-09-22 复测已经不成立**：`github.com` / `codeload.github.com` /
`raw.githubusercontent.com` / `api.github.com` 四个端点都能下（分别 146351 / 146351 /
24789 / 6344 字节）。README、`deploy.ps1`、`install/deploy.sh` 里的说法都改了，
并把 2026-09-21 那次的原始报错文本留着做对照 —— 结论会变，记录不该抹掉。

---

## v1.2.6 — 2026-09-22

`versionCode = 10206`

这一版是 **v1.2.5 之后继续深挖出来的东西**：同一套「拿基线数据反向对账」的办法，
又查出 4 个「文档有、实现没有」的缺口（Tomcat 软件本体、memcached 的组身份、
redis 插件、以及一批环境细节），另外修了部署链路自己的 5 个 bug（SSL 自动开启、
补丁打半截、`/sdcard` 是 CE 存储、`warn` 未定义、两行被粘成一行）。

**预制镜像也随这一版第一次正式发布**（`qyt-image.part-*` 两卷，2.07 GB），
镜像是这次从零重装、逐项对账之后打出来的，见 `docs/handover.md` §十。

### Tomcat 也是「没有任何来源」：插件只装插件文件

* 装完 9 个插件后 `/www/server/tomcat` **根本不存在**。原因：
  这个面板版本的 `install/` 下没有 tomcat 安装脚本（只有 install_soft.sh / public.sh /
  nginx.sh / fix_install.sh / d_node.pl），`class/tomcat.py` 只管 vhost，
  tomcat2（Java项目管理器）插件的 `install.sh` 是个空壳（正文就是 `echo '安装完成'`）。
  于是 `service.sh` 的 `start_svc tomcat` 永远「跳过」，而文档写着 Tomcat 9.0 是有的。
* 新增 `step_tomcat`：从 `archive.apache.org` 取 **apache-tomcat-9.0.62.tar.gz**
  （与基线 `catalina.jar` 的 9.0.62 同版本；实测该 URL 200，而 download.bt.cn 上
  几个 tomcat 路径都是 404、dlcdn/tuna 只留最新版），解到 `/www/server/tomcat`。
* 顺带修 `install/tomcat.initd` 的 `JAVA_HOME`：原来写死 `/www/server/java/jdk-17.0.8`
  —— 基线那台的目录是 `java-17-openjdk-17.0.20.8`，写死的那个根本不存在，
  一直靠回退侥幸能用；现在按「宝塔装的 JDK → rpm 的 OpenJDK → `/usr/bin/java` 反查」顺序找。

### redis 插件装不上：`plugin_install.py` 的两个坑

* **假跳过**：原来只看 `install_checks` 路径在不在。redis 的 `install_checks` 指的是
  **软件**路径 `/www/server/redis/runtest`（源码在那儿但没编译），那个文件在 →
  直接「已经安装过了，跳过」→ 插件的文件一个都没解包，面板里点开 redis 是 404，
  `/etc/init.d/redis` 也不存在。现在要求「install_checks **且** 插件目录」都在才算装过。
* **异步任务**：redis 走的是面板的任务队列，第一步只返回
  `{"status": true, "msg": "已将安装任务添加到队列!"}`，`temp/` 不会立刻出现 ——
  旧代码直接判「临时目录不存在，安装中止」。现在会等插件目录出现（`PLUGIN_WAIT`，默认 900 秒）。
* 结果：redis 插件装好，`redis-server`（**8.0.6**，店里的当前版本）+ `/etc/init.d/redis` 都在。

### `/sdcard` 是 CE 存储：手机重启后没解锁就推不上去

* 一键部署最后一步是 `reboot`，重启后手机停在锁屏 → vold 不建 `/mnt/user/0/primary` →
  `/sdcard` 直接 “No such file or directory”，`adb push` 全灭；此时 `/data/media/0` 里
  只能看到 fscrypt 的 22 字符加密名，**看着很像「存储坏了」**（详见 pitfalls §六.6）。
* 修法：推送/执行目录从 `/sdcard` 换成 **`/data/local/tmp/qyt-repo`**（DE 存储，锁屏可写），
  `deploy.ps1` 新增 `-Dest`；README / module/customize.sh / install/*.sh 里的路径与提示同步改。

### `install/qiyuntai-install.sh` 自己的两个 bug（都是「静默」型的）

* 用了 18 处 `warn` 但从没定义过它 —— 每条警告都是 `sh: warn: not found`，一条都打不出来
  （shellcheck 不管这个：它分不清「函数」还是「外部命令」）。
* 一次「删空行」的编辑把两行粘成了一行：
  `log "装 chroot 服务兼容层（…）"    sh "$REPO_DIR/install/chroot-compat-layer.sh"` ——
  语法完全合法，于是 `chroot-compat-layer.sh` **永远不会被执行**，
  兼容层（systemctl/service/start-stop-daemon/iptables-legacy）一个都不会装。
  `sh -n` 和 shellcheck 都拦不住这类错误。

### 面板自己会开 SSL，明文 http 连不上（这轮最毒的一个坑）

* 装完面板不到一小时，`task.py` 里那个 `interval=3600` 的 `check_panel_ssl`
  任务就会拉起 `script/panel_ssl_task.py` 给面板 IP 签自签证书并写 `data/ssl.pl=True`，
  面板从此**只收 HTTPS**。实测表现是：端口在 `LISTEN`、进程活着、日志干净，
  但明文 HTTP 连上就被 **reset**（curl 报 000，不是 404）——
  极易误判成「面板没起来 / 端口错 / 入口错」。
  本机是靠 `WSGI test_client` 直接打 app 拿到 200 才定位到「问题在传输层不在应用层」。
* 修法三层：删 `data/ssl.pl` → 把 `panel_ssl_task.py` 空壳化（原版留 `.moli-orig`）→
  删 `data/check_ssl_cron.pl`。修完实测：明文 HTTP + 浏览器 UA → **200**。
* `service.sh` 的开机自检现在 http 失败会补试一次 https（并提示面板开了 SSL），
  `action.sh` 与凭据文件里的地址按 `data/ssl.pl` 决定协议 —— 不再一律写 `http://`。

### 打补丁时缺 `node`，把补丁打成了「半截」

* `tools/moli_patch.py` 的前端几步要用 `node --check` 校验改过的 JS，而 `node` 在
  **新装环境里是后面才有的**（`nodejs` rpm）。实测（在刚装好的面板上跑）：
  `FileNotFoundError` 直接把脚本打断 —— 后端那几条已经改完文件并留了备份，
  前端那两条一条没做，日志里只有一段调用栈，`verify` 却显示「未生效」，
  很容易被当成「补丁打完了」。
* 两头堵：`moli_patch.py` 新增 `find_node()`（还找 `/www/server/nodejs/v*/bin/node`），
  没有 node 就**明确跳过 + 打印提示**，不写没校验过的 JS（改坏一个 JS 会把面板 UI 打死）；
  `step_deps` 加 `nodejs npm`，`step_patch` 打完补丁立刻跑一次 `verify`，
  把「未生效」的条目逐条打出来并告警。
* 修完后实测：装上 `nodejs`（v20.18.2，与基线一致）再重跑，8 条全部「正常」。

### `deploy.sh --from-image` 路径三处修正

* 拼接出来的整包（`/data/qyt-image.tar.xz`，几 GB）解包后没人删 → 现在解包成功即 `rm`。
* 镜像清单读的位置不对：`make_image.sh` 已改成把 `IMAGE-MANIFEST.txt` 写在镜像外面，
  这一头还只找镜像里面 → 改成优先找镜像目录、找不到再回退（兼容老镜像）。
* 镜像路径漏了新步骤 `parity` → 现在是 `creds → plugins → parity → patch → module`。

### `make_image.sh`：清单写到镜像外面

原来清单写在 `$ROOT/IMAGE-MANIFEST.txt`，而 `$ROOT` 就是下一行要 `tar` 的整棵树 ——
结果清单既被冻进镜像、又不在输出目录里所以上传命令带不上它，
而 README 与 Release 说明里都是把它当附件列的。

---

## v1.2.4 — 2026-09-21

`versionCode = 10204`

模块内容（`module/action.sh`、`module/uninstall.sh`、`module/README.md`）有改动，
所以升到 v1.2.4。**建议所有已装用户更新模块**：这一版修了 `action.sh` 的磁盘诊断
（原来因 `df` 取值方式在本机拿不到值，一直显示为空）、给 `uninstall.sh` 加了
`--purge` 安全开关、并把 `module/README.md` 与实际代码对齐（开机流程 11 项、9 个插件）。

> 下面这些条目相对 v1.2.3 的增量。

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
* **磁盘空间检查实测从来没生效过**：`df -k /data` 在本机的输出会因为设备名过长**折成三行**
  （第 2 行只有 `/dev/block/by-name/userdata`，数值在第 3 行），于是
  `awk 'NR==2{print $4}'` 取到空值 → `[ -n "$FREE_KB" ]` 为假 → 整个检查被静默跳过。
  `prepare-rootfs.sh` 里更糟：`[ "" -lt N ]` 会报 `integer expression expected` 并让检查失效；
  `action.sh` 的诊断行则显示为空。三处全改成 `df -P`（POSIX 输出，强制一个文件系统一行，
  实测 busybox 与 toybox 都支持），并且**取不到数值就直接失败**，不再「跳过检查」。
* `deploy.sh` 的空间门槛是 **6 GB**，而实测装完需要 **17.7 GB** —— 差 3 倍，
  空间不够的机器会一路过检查、装到一半爆在 `/data`。已按 20 GB 设门槛。

### CI

* 新增 `tools/ci.sh` + `.github/workflows/ci.yml`，本地和 CI 跑同一个脚本：
  `shellcheck -S warning` / `sh -n` / `python3 -m py_compile` / `node --check` /
  行尾 CRLF / `deploy.ps1` 的 UTF-8 BOM / `installer.lock` 哈希格式。
  用 `CI=true` 区分「本地没装工具可以跳过」和「CI 里必须装，不许静默跳过」。
* 已实测：注入 shell 语法错误、python 语法错误、CRLF、丢 BOM、坏哈希 5 类故障，
  全部被拦下（基线正常通过）。
* 顺带发现并修掉：`tools/__pycache__/*.pyc` 会被 `git add -A` 扫进版本库，已加 `.gitignore`。

### 修掉「一键部署装出来的环境，和文档承诺的不是同一个」

核对基线时发现的真问题，影响面比前面那些 bug 都大：

* **`step_plugins` 只装 1 个插件，文档承诺 9 个**。
  基线实测的插件清单是 `fail2ban / java_manager / jdk_manager / nodejs /
  pyenv_manager / pythonmamager / redis / supervisor / tomcat2`，而脚本里只有
  `plugin_install.py fail2ban` 一行。**旧环境里那 9 个是我当初手工装的，脚本从没同步。**
  后果：别人照 README 跑 `deploy.ps1`，拿到的是缺 redis / tomcat / supervisor / nodejs /
  JDK 的残缺环境；模块 `service.sh` 去拉起那 11 项服务时，缺的会被一项一项「跳过」，
  而**任何地方都不报错**，文档却写着都有。
  现在 `PLUGINS` 列全 9 个，逐条幂等（已存在就跳过）+ 逐条报结果，
  最后有缺失就 `fail`（不静默放过）。
* **`step_deps` 没装 redis / memcached**。现在补上一条独立的、允许失败的 dnf 兜底。
  注意版本差异：openEuler 源里是 `redis 7.2.15` / `memcached 1.6.22`，
  而基线记的是 `7.2.16` / `1.6.45` —— 说明旧环境那两份是面板插件自带的，
  dnf 只是兜底。
* **`deploy.ps1` 没推 `tools/`**。而 `step_plugins` 要 `tools/plugin_install.py`、
  `step_patch` 要 `tools/moli_patch.py` —— 缺了这两个步骤必然失败
  （实测 `/sdcard/tools` 存在但文件数 0）。现在推 `tools/`，并加了两个文件的落地检查。

### 修掉 `make_image.sh` 里一个会删掉整个 chroot 的写法

shellcheck 报的 SC2115：`rm -rf "$ROOT/$p"` 在 `$p` 为空时会展开成 `rm -rf "$ROOT/"`，
而本脚本是 root 跑的。现在清理项的路径为空 / 以 `/` 开头 / 含 `..` 就直接 `die`，
并且写成 `rm -rf "${ROOT:?}/${p:?}"` 双保险。

（这条是 **GitHub Actions 抓到并发了邮件**的 —— 本地 `tools/ci.sh` 同一个检查也报，
顺手就修了。CI 值回票价。）

### 预制镜像（`--from-image`）：不再依赖宝塔服务器

起因：从零装要碰一堆宝塔端点（安装器 / `panel6.zip` / pyenv bundle / 组件脚本 / 组件源码），
任何一个变了或没了，从零装就断。实测宝塔**确实长期保留历史版本**
（`update/LinuxPanel-9.5.0.zip`、`11.0.0.zip`、`13.0.0.zip` 都还在），但那是它的善意，不是承诺。

* 新增 `tools/make_image.sh`：把装好的环境冻成一个可分卷的 `tar.xz`。
  带硬门槛（**`$ROOT/` 下挂载数必须为 0** 才允许打包 —— 带着 `mount --bind /dev` 打包会把
  宿主设备节点打进镜像），带编译残留清理（MariaDB 构建树实测 8.8 GB），
  带 `IMAGE-MANIFEST.txt` 清单，带「分卷→拼接回读→比 sha256」的自校验。
* 新增 `deploy.sh --from-image <dir>`：拼接分卷 → 校验 sha256 → 解包 → 只跑
  `creds/plugins/patch/module`（跳过 dnf 和源码编译）。装一台约 10 分钟，零上游依赖。
* **镜像里存的是「未打补丁」的原版**。`make_image.sh` 打包前自动跑 `moli_patch.py revert`。
  理由：① 补丁是版本相关的（见下面三道守卫），冻进镜像就没法在不重建几 GB 镜像的前提下更新它；
  ② 部署时在**原版**上打补丁，`moli_patch/backup_*` 里才是真原版，回滚点才成立；
  ③ 补丁只改面板的 py/html/js，几秒钟的事。
* 新增 `moli_patch.py revert`：从最新 `backup_*` 还原成原版。带目录穿越守卫
  （备份名是相对路径用 `__` 拍平的，还原前校验目标仍在 `PANEL` 内）。
* **来自镜像时重新随机化身份**：镜像里烘的是打包那台机器的端口、安全入口、用户名，
  不重新随机，所有用同一镜像的人就完全一样。`step_credentials` 检测到 `.from-image` 标记时，
  重新随机 端口 / 安全入口 / 用户名 / 密码，并重启面板。

实测（WSL 里造假环境跑）：`revert` 还原正确、目录穿越被拒、可重复执行、无备份时退出 1；
分卷机制「改一字节 / 少一卷 / 逆序拼接」三种损坏都被 sha256 抓到，解压后逐字节一致。
分卷后缀是**字母序**（`part-aaa`、`part-aab`…），`cat` 时按字母序即原顺序。

### 其它实测修复与加固（安装路径 / 安全 / 工具链）

一键部署原来**跑不完**，这一串是逐个真跑出来的：

* **`step_rootfs` / `deploy.sh` 都没把「源」交给 `prepare-rootfs.sh`** ——
  它要求 `--url/--xz/--tar` 之一，只传 `--root` 会被它以「没给源」退出，
  一键部署必然卡在 rootfs 这一步。改法：给 `prepare-rootfs.sh` 加 `--mirror`
  （用它自己探好的下载器去镜像目录挑文件），两个调用点都传 `--mirror`。
  *教训：改调用点之前先 `grep` 出所有调用点 —— 第一次只改了一个，
    而一键部署走的是另一个，所以修完再跑还是同样的错。*
* **清华镜像对「文件下载」挑 User-Agent**（目录列表反而不挑）。实测用魔数判定：
  默认 UA 与 `Mozilla/5.0` 都是 **403 / 0 字节**，`Wget/1.21` 才通；
  官方 `repo.openeuler.org` 与华为云不挑。而 `fetch` 的 busybox 分支**不传 UA**、
  wget/curl 分支传 `Mozilla/5.0` —— 三种下载器全被 403。
  改法：主源换官方、清华降备用、busybox 分支带 UA、
  下载改成「多源依次试」并按大小验证（>1MB 才算成功 ——
  被拒时服务器可能返回小错误页而 `rc=0`，只看返回码会误判）。
* **`prepare-rootfs.sh` 的「验证 chroot」误报**：原来是
  `chroot $ROOT /bin/bash -c 'head -1 /etc/os-release'`，没设 PATH；
  宿主 PATH 是 `/system/bin:...`，在 chroot 里不存在 → `head: command not found`
  → 输出为空 → 报「chroot 进不去」。改成只用 bash 内建命令，失败时打真实报错。
* **`expect` 驱动自身的两个 bug**（都是真跑面板安装时才暴露）：
  ① 「未识别提问」用了 `-re {[^\r\n]{1,80}[：:]\s*$}` —— expect 的 `$` 匹配的是
  **缓冲区末尾**而不是行尾，而 `read -p` 的提示本来就不带换行，于是「一个完整提示」
  和「半个正在到达的行」在缓冲区里长得一样。实测撞上安装器第一行输出
  `cat: /etc/hostname: No such file or directory` 被分块投递、缓冲区停在 `cat: `，
  被当成提示直接失败。改成**两级判定**：静默 45 秒 **且** 尾部停在冒号上才算卡住。
  ② 超时分支读 `$expect_out(buffer)` 会 Tcl 报错 —— expect 只在**匹配成功**后才设置
  `expect_out`，超时时它不存在。改成从 `log_file` 记的日志尾部取。
* **破解补丁三道守卫**（补丁原来是纯模式匹配，没有任何版本判断）：
  ① `PANEL_VERIFIED` 版本白名单，不在名单里直接失败并要求人工核验后 `--force`；
  ② `moli_patch/.patched` 标记，已打过且校验全过就跳过重打（否则会把「已打补丁的文件」
  备份成「原版」，回滚点就假了）；
  ③ `do_verify()` 返回未生效项数，非 0 时退出码非 0 且不写标记 ——
  把原来「找不到补丁点只打一行 [跳过] 然后照样退出 0」的静默半成品变成明确失败。
* **`/dev` 事故（第二次）后加的两道安全开关**：`module/uninstall.sh` 原来在提示里
  直接教 `rm -rf /data/openeuler` —— 而 `$ROOT/dev` 是 `mount --bind /dev`，
  是宿主真实 `/dev` 的绑定挂载，挂着它 `rm -rf` 会删掉设备节点 → 黑屏
  （实测踩过两次）。现在 `uninstall.sh --purge` 会**先证明 `$ROOT/` 下挂载数为 0 再删**；
  `prepare-rootfs.sh --clean` 同理。默认提示也改成安全的做法。
* **`tools/verify_sync.sh` 加 Release 附件新鲜度检查**：原来只比「工作区 vs git 树」，
  测不出「`module/` 改了但忘了重打 zip / 覆盖附件」（实测漏过一次）。
  第一版比 zip 字节，结果**会误报** —— zip 的条目顺序随文件系统 readdir 变，
  同一份 module/ 在仓库里和复制到 `/tmp` 后打出的 sha256 不同。
  改成下载附件后用 python `zipfile` 与本地 `module/` **逐文件比内容**。
* **`tools/make_image.sh` 的组件路径**：`/www/server/nginx/sbin` 是
  `sbin -> /www/server/nginx/nginx/sbin` 的**绝对软链**，chroot 内能通、宿主侧不通
  （`docs/pitfalls.md` §二.3 早写了这个坑）。脚本是宿主侧跑的，直接判断会误报
  「组件没编译完」。改成「候选真实路径 → find 兜底」，并把解析结果写进镜像清单。
* **README 结构节漏文件**：新增 6 个文件后没同步。已补全，并给 `tools/ci.sh`
  加了第 8 项检查 —— 仓库结构节必须覆盖全部被跟踪文件，防止再漂移。
* **`module/README.md` 与实际代码不一致**：§二只列了 7 项服务（实际 11 项）、
  漏了 KernelSU 管理器注册与陈旧 pid 清理；§三没列那 9 个面板插件；
  §五的 init.d 列表只列 5 个。已全部对齐。
* **`deploy.ps1` 的自引用提示**：从别的目录调用时（例如免 clone 一行命令解包到 `%TEMP%`），
  收尾提示原来一律印 `.\deploy.ps1`，照抄会失败。现在按工作目录判断。

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
