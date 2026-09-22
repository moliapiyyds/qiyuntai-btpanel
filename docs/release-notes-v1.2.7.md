# 栖云台 · 宝塔面板 v1.2.7

`versionCode = 10207` · 2026-09-22

这一版只加**部署入口**，没动模块代码（`module/` 里只有 `module.prop` 的版本号变了）——
所以模块本身可以不用更新，装了 v1.2.6 的话继续用就行。

## 加了什么

之前只有 Windows 侧一条命令（`deploy.ps1`），现在三个平台都能一条命令部署：

| 你在哪 | 一条命令 | 说明 |
|---|---|---|
| **Windows** | `.\deploy.ps1` | 一直都有 |
| **Linux / macOS** | `./deploy-linux.sh` | **新增**，与 `deploy.ps1` 等价（`--check` / `--push-only` / `--no-reboot` / `--adb` / `--dest` / `--serial`） |
| **只有手机** | 一行 root 终端命令（见下） | **新增**，不经过电脑：拉仓库 → 解包 → 跑 `install/deploy.sh` |

纯手机那一行（KernelSU/Magisk 自带终端、Termux、`adb shell` 都行）：

```sh
su -c 'BB=$(ls /data/adb/ksu/bin/busybox /data/adb/magisk/busybox 2>/dev/null|head -1); T=/data/local/tmp/qyt.tgz; $BB wget -O $T https://codeload.github.com/moliapiyyds/qiyuntai-btpanel/tar.gz/refs/heads/main && mkdir -p /data/local/tmp/qyt-repo && $BB tar -xzf $T -C /data/local/tmp/qyt-repo --strip-components=1 && sh /data/local/tmp/qyt-repo/install/deploy.sh'
```

预制镜像也能让手机自己下（实测 Release 附件下得动，整卷 235,001,052 字节）：

```sh
su -c 'BB=$(ls /data/adb/ksu/bin/busybox /data/adb/magisk/busybox 2>/dev/null|head -1); D=/data/local/tmp/qyt_image; V=v1.2.6; mkdir -p $D; for p in aaa aab; do $BB wget -O $D/qyt-image.part-$p https://github.com/moliapiyyds/qiyuntai-btpanel/releases/download/$V/qyt-image.part-$p; done; $BB wget -O $D/SHA256SUMS.txt https://github.com/moliapiyyds/qiyuntai-btpanel/releases/download/$V/SHA256SUMS.txt; sh /data/local/tmp/qyt-repo/install/deploy.sh --from-image $D'
```

## 顺带修掉一处过时口径（重要）

文档里一直写着「手机上的 `busybox wget` 连 `github.com` 会被重置，所以只能电脑侧准备」。
**这条已经不成立了**，2026-09-22 在同一台设备、同一个 busybox 上复测：

| 端点 | 结果 |
|---|---|
| `github.com`（archive tar.gz） | **146,351 字节** ✓ |
| `codeload.github.com` | **146,351 字节** ✓ |
| `raw.githubusercontent.com` | **24,789 字节** ✓ |
| `api.github.com` | **6,344 字节** ✓ |
| Release 附件（`qyt-image.part-aab`） | **235,001,052 字节** ✓ |

所以「电脑侧准备」现在的定位是**更省事**（不用在手机上装终端、不用解锁屏幕），
而不是「手机做不到」。README、`deploy.ps1`、`install/deploy.sh` 里的说明都按这个改了，
并保留了 2026-09-21 那次的原始报错文本作为对照 —— 结论会变，但记录不该抹掉。

## 附件

| 文件 | 大小 | sha256 |
|---|---|---|
| `qiyuntai_btpanel-v1.2.7.zip`（模块，代码与 v1.2.6 相同） | 21,333 B | `9eff1e0f4dd29ef329c630bdbc858d9a86d8827fa7eb907f2c735b1925ee39d9` |

预制镜像与 v1.2.6 那一版**内容完全相同**（没有重新打包），放在 v1.2.6 的 Release 里：

| 文件 | 大小 | sha256 |
|---|---|---|
| `qyt-image.part-aaa` | 1,992,294,400 B | `e113c6653c81a764b8bc84ad3be9a8e1ee66377f0f59266b111a1358820a4130` |
| `qyt-image.part-aab` | 235,001,052 B | `672b6bab1a9b8dcd31dff35a6f66bfa8be8c65827e454eb26dc403059e6f7ee2` |
| 整包（两卷拼起来） | 2,227,295,452 B | `9f846cfa1ded8767d0b7e33722eb7546b7db08a8ddc70604fca60e04e7d4e284` |

> 为什么镜像不重发：这一版只改了部署脚本与文档，环境内容一个字节没变；
> 重发一遍 2.2 GB 只是浪费。`--from-image` 的校验和还是上面这三个值。
