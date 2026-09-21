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
#   2) 把 install/ 和 module/ 推到手机（同一层目录）
#   3) 在手机上跑 install/deploy.sh —— 剩下的全自动：
#        铺 rootfs → 装面板/组件/插件/补丁 → 装 KernelSU 模块 → 重启
#   4) 收尾提示
#
# 参数：
#   -Check        只检查设备和环境，不推送、不安装
#   -PushOnly     只推文件到手机，不安装
#   -NoReboot     装完不自动重启手机
#   -Adb <path>   指定 adb 路径（默认自动找）
#
# 关于 root：脚本先试 `adb shell id`，已经是 uid=0 就直接执行；
# 否则才退回 `su -c`。两种都拿不到 root 才报错。
# （实测 KernelSU-Next 的 adbd 常常本身就是 root，这时设备上根本没有 su 命令。）
#
# 为什么仓库在电脑侧准备而不是手机上拉：
#   实测手机上的 busybox wget 连 github.com 会被重置
#   （wget: got bad TLS record ... Connection reset by peer），
#   电脑有 git/curl 正常访问。所以电脑拉好再推过去。
#
# 注意：本文件必须保存为「UTF-8 带 BOM」，否则 PowerShell 5.1 按 GBK 解析会语法报错。
# ============================================================
param(
    [switch]$Check,
    [switch]$PushOnly,
    [switch]$NoReboot,
    [string]$Adb = ''
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SU = ''

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
    Write-Host "正式部署： .\deploy.ps1"
    exit 0
}

# ---------- 4) 推文件 ----------
Write-Host ""
Write-Host "---- 推送到手机 ----"
RemoteRun "mkdir -p /sdcard/install /sdcard/module" | Out-Null
& $Adb -s $serial push (Join-Path $RepoRoot 'install\.') /sdcard/install/ 2>&1 | Select-Object -Last 1
& $Adb -s $serial push (Join-Path $RepoRoot 'module\.')  /sdcard/module/  2>&1 | Select-Object -Last 1
RemoteRun "chmod 755 /sdcard/install/*.sh /sdcard/module/*.sh" | Out-Null
# 数文件个数在 PowerShell 这边做：命令里写 $(...) 会被 PS 本地展开，传不过去
$nIns = @((RemoteRun "ls /sdcard/install") | Where-Object { $_ -and $_.Trim() }).Count
$nMod = @((RemoteRun "ls /sdcard/module")  | Where-Object { $_ -and $_.Trim() }).Count
Ok "已推送：install/ $nIns 个文件，module/ $nMod 个文件（并已置执行位）"
if ($nIns -lt 5 -or $nMod -lt 5) { Die "推送数量不对，检查 adb push 输出" }

if ($PushOnly) {
    Write-Host ""
    Write-Host "---- -PushOnly：文件已推好，没有安装 ----"
    Write-Host "继续（手机上执行）："
    Write-Host "   $Adb -s $serial shell `"sh /sdcard/install/deploy.sh`""
    Write-Host "或者在这里直接跑： .\deploy.ps1"
    exit 0
}

# ---------- 5) 在手机上跑 ----------
Write-Host ""
Write-Host "---- 手机上开始部署 ----"
Write-Host "     这一步最慢：dnf 装编译依赖 + 源码编译 OpenResty / MariaDB / PHP"
Write-Host "     MariaDB 编译峰值约 2 GB 内存，装之前最好清一下后台"
Write-Host ""
$extra = ''
if ($NoReboot) { $extra = ' --no-reboot' }
RemoteRun "sh /sdcard/install/deploy.sh$extra"
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
