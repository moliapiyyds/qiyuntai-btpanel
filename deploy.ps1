# ============================================================
# 栖云台 · 宝塔面板 —— PC 侧一键部署
# 作者：茉莉  QQ:1265274322  官方Q群:570387739
# ------------------------------------------------------------
# 在电脑上运行（需要 adb；手机已 root、已装 KernelSU/Magisk）：
#
#   .\deploy.ps1
#
# 它做四件事：
#   1) 找 adb、等设备、确认手机上能拿到 root
#   2) 把 install/ module/ tools/ 推到手机（必须在同一层目录），
#      默认推到 /data/local/tmp/qyt-repo —— **不是 /sdcard**，原因见下面「推送到哪」那段
#      tools/ 是必须的：step_plugins 要用 tools/plugin_install.py、
#      step_patch 要用 tools/moli_patch.py
#   3) 预制镜像分卷：电脑上下（约 2.2 GB，下完 adb push 到 /data/local/tmp/qyt-image）。
#      手机上已经有且校验通过就跳过。**这是交付的唯一路径** —— 不走宝塔官方安装器了，
#      理由见 README「为什么不走宝塔官方源」。
#   4) 在手机上跑 install/deploy.sh --from-image —— 解包 → 重新随机化端口/入口/密码/
#      sshd 主机密钥 → 插件 → 基线包对齐 → 打补丁 → 装 KernelSU 模块 → 重启。约 10 分钟。
#      （目标 /data/openeuler 非空会拒绝解包：先跑 install/prepare-rootfs.sh --clean）
#
# 参数：
#   -Check          只检查设备和环境，不推送、不安装
#   -PushOnly       只推文件（仓库 + 镜像分卷）到手机，不安装
#   -NoReboot       装完不自动重启手机
#   -Adb <path>     指定 adb 路径（默认自动找）
#   -Dest <path>    仓库推到哪儿（默认 /data/local/tmp/qyt-repo）
#   -ImageDir <path>   镜像分卷放手机哪儿（默认 /data/local/tmp/qyt-image）
#   -ImageUrl <url>    镜像从哪下（默认 GitHub Release；自建镜像站/网盘直链都行）
#
# 电脑侧缓存：分卷下到 _dist\image\（已在 .gitignore 里），校验通过后不重复下。
#
# 关于 root：脚本先试 `adb shell id`，已经是 uid=0 就直接执行；
# 否则才退回 `su -c`。两种都拿不到 root 才报错。
# （实测 KernelSU-Next 的 adbd 常常本身就是 root，这时设备上根本没有 su 命令。）
#
# 为什么仓库在电脑侧准备而不是手机上拉：
#   2026-09-21 实测手机上的 busybox wget 连 github.com 会被重置
#   （wget: got bad TLS record ... Connection reset by peer），所以做成了「电脑拉好再推」。
#   2026-09-22 复测同一台设备：github.com / codeload / raw / api 都通了，
#   手机上自己拉也行（README 首页「纯手机终端」那节就是那条路）。
#   电脑侧仍然更省事：不用在手机上装终端，不用解锁屏幕，推完直接跑。
#   另外 Linux / macOS 侧等价入口是 deploy-linux.sh（改一个记得改另一个）。
#
# 注意：本文件必须保存为「UTF-8 带 BOM」，否则 PowerShell 5.1 按 GBK 解析会语法报错。
# ============================================================
param(
    [switch]$Check,
    [switch]$PushOnly,
    [switch]$NoReboot,
    [string]$Adb = '',
    [string]$Dest = '',
    [string]$ImageDir = '',
    [string]$ImageUrl = ''
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SU = ''

# 镜像分卷放手机哪儿 / 电脑侧缓存目录（缓存已在 .gitignore 里）
if (-not $ImageDir) { $ImageDir = '/data/local/tmp/qyt-image' }
$ImageCache = Join-Path $RepoRoot '_dist\image'

# 推送到哪：默认 /data/local/tmp/qyt-repo。
# 为什么不用 /sdcard（2026-09-22 实测踩到）：/sdcard 是 **CE 存储**
#   （ro.crypto.state=encrypted、ro.crypto.type=file），手机重启后只要没解锁一次，
#   vold 就不会建 /mnt/user/0/primary，`/sdcard` 直接 "No such file or directory"，
#   adb push 全灭（而是 /data/media/0 里只能看到 fscrypt 的 22 字符加密文件名，
#   看着像"存储坏了"，其实是没解锁）。
#   一键部署的最后一步就是重启手机 —— 所以「装完再推一次」必然踩到。
#   /data/local/tmp 是 DE 存储：锁屏能写、重启也在。
if (-not $Dest) { $Dest = '/data/local/tmp/qyt-repo' }

# 自引用提示：从别的目录调用（例如 %TEMP%）时，要给能直接复制的完整路径
$hint = if ((Get-Location).Path.TrimEnd('\') -eq $RepoRoot.TrimEnd('\')) { '.\deploy.ps1' } else { "& `"$RepoRoot\deploy.ps1`"" }

function Say($m)  { Write-Host "  $m" }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [失败] $m" -ForegroundColor Red; exit 1 }

Write-Host "=========================================================="
Write-Host " 栖云台 · 宝塔面板  一键部署（PC 侧）"
Write-Host " 作者：茉莉  QQ:1265274322  官方Q群:570387739"
Write-Host "=========================================================="
Write-Host ""

# ---------- 1) 找 adb ----------
Write-Host "---- 找 adb ----"
if (-not $Adb) {
    $cands = @(
        (Join-Path $RepoRoot 'tools\adb\adb.exe'),
        'D:\tc\tools\adb\adb.exe',
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        'C:\platform-tools\adb.exe'
    )
    foreach ($c in $cands) { if (Test-Path $c) { $Adb = $c; break } }
    if (-not $Adb) {
        $w = Get-Command adb -ErrorAction SilentlyContinue
        if ($w) { $Adb = $w.Source }
    }
}
if (-not $Adb -or -not (Test-Path $Adb)) {
    Die "找不到 adb。装 platform-tools 后用 -Adb <路径> 指定，或把 adb 放进 tools\adb\adb.exe"
}
Ok "adb: $Adb"

if (-not (Test-Path (Join-Path $RepoRoot 'install\deploy.sh'))) {
    Die "当前目录不像仓库根目录（缺 install\deploy.sh）：$RepoRoot"
}

# ---------- 2) 等设备 ----------
Write-Host ""
Write-Host "---- 等设备 ----"
& $Adb start-server 2>&1 | Out-Null
$devs = (& $Adb devices 2>&1) -join "`n"
if ($devs -notmatch '\sdevice\s*$') {
    Warn "没看到已连接的设备。"
    Write-Host "     USB：插线并在手机上允许调试；或先 adb connect 手机IP:5555"
    if ($Check) { Die "设备未就绪（-Check 到此结束）" }
    Say "等设备出现（最多 60 秒）…"
    & $Adb wait-for-device 2>&1 | Out-Null
    $devs = (& $Adb devices 2>&1) -join "`n"
}
if ($devs -notmatch '\sdevice\s*$') { Die "设备仍未就绪。adb devices 输出：`n$devs" }
$serial = (($devs -split "`n") | Where-Object { $_ -match '\sdevice\s*$' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
Ok "设备: $serial"

function RemoteRun([string]$cmd) {
    if ($script:SU) {
        & $Adb -s $serial shell "su -c '$cmd'" 2>&1
    } else {
        & $Adb -s $serial shell $cmd 2>&1
    }
}

# ---------- 3) 拿 root ----------
Write-Host ""
Write-Host "---- 检查 root ----"
$idOut = (RemoteRun "id") -join ' '
if ($idOut -match 'uid=0') {
    $script:SU = ''
    Ok "adb 已经是 root（直接执行，不需要 su）"
} else {
    $suOut = (& $Adb -s $serial shell "su -c id" 2>&1) -join ' '
    if ($suOut -match 'uid=0') {
        $script:SU = 'su -c '
        Ok "su 可用"
    } else {
        Die "拿不到 root。`n     adb shell id -> $idOut`n     su -c id     -> $suOut`n     请在 KernelSU / Magisk 里给本机 adb 授权 su"
    }
}

$arch = ((RemoteRun "uname -m") -join ' ').Trim()
if ($arch -notmatch 'aarch64|arm64') { Die "手机架构是 $arch，本项目只支持 aarch64" }
Ok "架构 $arch"

$free = (RemoteRun "df -k /data") -join "`n"
$freeLine = ($free -split "`n" | Where-Object { $_ -match '/data' } | Select-Object -First 1)
if ($freeLine) { Ok "磁盘: $($freeLine.Trim())" }

if ($Check) {
    Write-Host ""
    Write-Host "---- -Check 结束，什么都没推送 / 安装 ----"
    Write-Host "正式部署： $hint"
    exit 0
}

# ---------- 4) 推文件 ----------
Write-Host ""
Write-Host "---- 推送到手机 ----"
# 推到哪儿：默认 /data/local/tmp/qyt-repo，**不是 /sdcard**（2026-09-22 实测踩到）。
# /sdcard 是 CE 存储（ro.crypto.state=encrypted、type=file）：手机重启后只要**没解锁一次**，
# vold 就不建 /mnt/user/0/primary，`/sdcard` 直接 "No such file or directory"，
# adb push 全部失败。而一键部署的最后一步就是重启手机 ——
# 于是「装完再推一次」这种操作必然踩到。/data/local/tmp 是 DE 存储，锁屏也能写、重启也在。
# 想用 /sdcard（手机已解锁时也能用）：.\deploy.ps1 -Dest /sdcard/qyt-repo
RemoteRun "mkdir -p $Dest/install $Dest/module $Dest/tools" | Out-Null
& $Adb -s $serial push (Join-Path $RepoRoot 'install\.') "$Dest/install/" 2>&1 | Select-Object -Last 1
& $Adb -s $serial push (Join-Path $RepoRoot 'module\.')  "$Dest/module/"  2>&1 | Select-Object -Last 1
# tools/ 也必须推：install/qiyuntai-install.sh 的 step_plugins 要用
# tools/plugin_install.py、step_patch 要用 tools/moli_patch.py。
# 以前没推 tools/，那两步会因为找不到文件而失败（而且 step_plugins 原来只装 fail2ban，
# 失败还可能被忽略过去）。
& $Adb -s $serial push (Join-Path $RepoRoot 'tools\.')   "$Dest/tools/"   2>&1 | Select-Object -Last 1
RemoteRun "chmod 755 $Dest/install/*.sh $Dest/module/*.sh $Dest/tools/*.sh" | Out-Null
# 数文件个数在 PowerShell 这边做：命令里写 $(...) 会被 PS 本地展开，传不过去
$nIns = @((RemoteRun "ls $Dest/install") | Where-Object { $_ -and $_.Trim() }).Count
$nMod = @((RemoteRun "ls $Dest/module")  | Where-Object { $_ -and $_.Trim() }).Count
$nTool = @((RemoteRun "ls $Dest/tools")  | Where-Object { $_ -and $_.Trim() }).Count
Ok "已推送：$Dest/install $nIns 个，module $nMod 个，tools $nTool 个（并已置执行位）"
if ($nIns -lt 5 -or $nMod -lt 5 -or $nTool -lt 3) {
    Die "推送数量不对（install=$nIns module=$nMod tools=$nTool），检查 adb push 输出。若目标在 /sdcard，先确认手机已解锁一次（/sdcard 是 CE 存储，锁屏时不可用）"
}
# 缺这两个，step_plugins / step_patch 必然失败，早报比晚报好
foreach ($need in @('plugin_install.py', 'moli_patch.py')) {
    $r = RemoteRun "test -f $Dest/tools/$need && echo yes || echo no"
    if (($r | Out-String) -notmatch 'yes') { Die "手机上缺 $Dest/tools/$need —— step_plugins/step_patch 会失败" }
}

# ---------- 4.5) 预制镜像分卷 ----------
# 交付只剩这一条路（理由见 README「为什么不走宝塔官方源」），所以电脑这条路必须
# 把 2.2 GB 分卷一起准备好：电脑下得快也稳，下完 adb push 过去。
# 手机上已经有了（且校验通过）就跳过 —— 重跑是安全的。
Write-Host ""
Write-Host "---- 预制镜像分卷 ----"
$imgOk = $false
RemoteRun "sh $Dest/install/fetch-image.sh -d $ImageDir --check" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Ok "手机上分卷已就绪且校验通过（跳过下载与推送）"
    $imgOk = $true
}
if (-not $imgOk) {
    $lock = Join-Path $RepoRoot 'install\image.lock'
    if (-not (Test-Path $lock)) { Die "缺 install\image.lock（镜像哈希清单，取件和校验都靠它）" }
    $rows = @(Get-Content $lock -Encoding UTF8 | Where-Object { $_ -match '^image\s' })
    if ($rows.Count -eq 0) { Die "install\image.lock 里没有 image 数据行" }
    $tag = ($rows[-1] -split '\s+')[1]
    $parts = @()
    foreach ($r in $rows) {
        $f = $r -split '\s+'
        if ($f[1] -eq $tag) { $parts += [pscustomobject]@{ name = $f[2]; size = [int64]$f[3]; sha = $f[4] } }
    }
    if ($parts.Count -eq 0) { Die "install\image.lock 里没有 tag=$tag 的分卷" }
    if (-not $ImageUrl) { $ImageUrl = "https://github.com/moliapiyyds/qiyuntai-btpanel/releases/download/$tag" }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Die "找不到 curl.exe（Windows 10 1803+ 自带）。装一个 curl 或改用 deploy-linux.sh"
    }
    New-Item -ItemType Directory -Force -Path $ImageCache | Out-Null
    Say "镜像 tag ：$tag"
    Say "缓存目录 ：$ImageCache（已下好且校验通过的会跳过，可以反复跑）"
    Say "手机目标 ：$ImageDir"

    function Test-Part($path, $size, $sha) {
        if (-not (Test-Path $path)) { return $false }
        if ((Get-Item $path).Length -ne $size) { return $false }
        if (-not $sha) { return $true }
        return ((Get-FileHash $path -Algorithm SHA256).Hash -eq $sha.ToUpper())
    }

    foreach ($p in $parts) {
        $f = Join-Path $ImageCache $p.name
        if (Test-Part $f $p.size $p.sha) { Ok "$($p.name) 已在缓存里且校验通过"; continue }
        Say "下载 $($p.name)（$([int]($p.size / 1MB)) MB，断点续传）"
        $try = 0
        while ($true) {
            & curl.exe -L --fail -C - --connect-timeout 20 --retry 2 --retry-delay 3 --progress-bar -o $f "$ImageUrl/$($p.name)" 2>&1 | Out-Null
            if (Test-Part $f $p.size $p.sha) { break }
            $try++
            if ($try -ge 8) {
                Die "$($p.name) 下不动或校验不过（缓存：$f）。
      删掉那个文件再重跑；或者 -ImageUrl <基址> 换源；
      或者干脆让手机自己下：手机上跑 install/fetch-image.sh --tries 0"
            }
            $have = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
            Warn "第 $try 次没成（已下 $([int]($have / 1MB)) MB），续传重试"
            Start-Sleep -Seconds 2
        }
        Ok "$($p.name) 下载完成并校验通过"
    }

    # 顺手把两个小清单也取下来（给 deploy.sh 打印清单用，非致命）
    foreach ($extra in @('SHA256SUMS.txt', 'IMAGE-MANIFEST.txt')) {
        $fe = Join-Path $ImageCache $extra
        if (-not (Test-Path $fe)) {
            & curl.exe -L --fail -s -o $fe "$ImageUrl/$extra" 2>&1 | Out-Null
        }
    }

    Say "推到手机 $ImageDir（2.2 GB 走 USB，看着进度条等它）"
    RemoteRun "mkdir -p $ImageDir" | Out-Null
    foreach ($p in $parts) {
        & $Adb -s $serial push (Join-Path $ImageCache $p.name) "$ImageDir/$($p.name)" 2>&1 | Select-Object -Last 1
    }
    foreach ($extra in @('SHA256SUMS.txt', 'IMAGE-MANIFEST.txt')) {
        $fe = Join-Path $ImageCache $extra
        if (Test-Path $fe) { & $Adb -s $serial push $fe "$ImageDir/$extra" 2>&1 | Select-Object -Last 1 }
    }
    RemoteRun "sh $Dest/install/fetch-image.sh -d $ImageDir --check" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Die "推到手机后校验没通过。看细节：
      $Adb -s $serial shell `"sh $Dest/install/fetch-image.sh -d $ImageDir --check`""
    }
    Ok "手机上分卷已就绪（校验通过）"
}

if ($PushOnly) {
    Write-Host ""
    Write-Host "---- -PushOnly：文件已推好，没有安装 ----"
    Write-Host "继续（手机上执行）："
    Write-Host "   $Adb -s $serial shell `"sh $Dest/install/deploy.sh --from-image $ImageDir`""
    Write-Host "或者在这里直接跑： $hint"
    exit 0
}

# ---------- 5) 在手机上跑 ----------
Write-Host ""
Write-Host "---- 手机上开始部署（从预制镜像铺）----"
Write-Host "     约 10 分钟：解包 + 重新随机化身份 + 插件/基线对齐/补丁/模块"
Write-Host "     如果这一步说 /data/openeuler 非空，先清旧的："
Write-Host "       $Adb -s $serial shell `"su -c 'sh $Dest/install/prepare-rootfs.sh --clean'`""
Write-Host ""
$extra = " --from-image $ImageDir"
if ($NoReboot) { $extra = "$extra --no-reboot" }
RemoteRun "sh $Dest/install/deploy.sh$extra"
$rc = $LASTEXITCODE

Write-Host ""
if ($rc -eq 0) {
    Write-Host "=========================================================="
    Write-Host " 完成。手机重启后会拉起全部服务。"
    Write-Host ""
    Write-Host " 拿地址账号密码："
    Write-Host "   $Adb -s $serial shell `"/data/adb/ksud module action qiyuntai_btpanel`""
    Write-Host " 出问题先诊断："
    Write-Host "   $Adb -s $serial shell `"sh /data/adb/modules/qiyuntai_btpanel/action.sh diag`""
    Write-Host "=========================================================="
} else {
    Die "手机上的部署脚本返回 $rc，看上面日志"
}
