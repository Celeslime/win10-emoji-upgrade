<#
.SYNOPSIS
    注册一个 SYSTEM 权限的一次性开机任务，在系统启动早期强制替换 emoji 字体。

.DESCRIPTION
    适用场景：Set-EmojiFont.ps1 -Phase Commit 多次因「文件被占用 / 访问被拒绝」失败。
    尤其是开启了快速启动（HiberbootEnabled=1）的机器，重启替换登记
    （PendingFileRenameOperations）会被快速启动的内核休眠恢复跳过，
    此时开机任务是唯一可靠通道。

    任务执行内容（见 Set-EmojiFont-Boot.ps1）：
    停字体缓存服务 -> 接管文件所有权 -> 删除旧字体 -> 拷入新字体 ->
    恢复注册表 -> 清理缓存 -> 自删任务。全程写日志到 <BackupDir>\boot-replace.log。

    注册后必须用「重启」（shutdown /r 或开始菜单的重启），
    不要用「关机再开机」——快速启动下那不是真重启。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Register-BootTask.ps1 -SourceFont .\seguiemj.ttf
    shutdown /r /t 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFont,

    [string]$BackupDir = (Join-Path $env:SystemDrive 'EmojiFontBackup'),

    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Set-EmojiFont-Boot.ps1'),

    [string]$TaskName = 'Replace-EmojiFont-Once'
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[ERROR] 需要管理员权限' -ForegroundColor Red
    exit 1
}

$SourceFont = (Resolve-Path $SourceFont).Path
$ScriptPath = (Resolve-Path $ScriptPath).Path
if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }

# 校验源字体
$src = Get-Item $SourceFont
if ($src.Length -lt 10000000) {
    Write-Host ('[WARN] 源字体只有 {0} 字节，不像 Windows 11 的 seguiemj.ttf（约 12MB），确认文件是否正确' -f $src.Length) -ForegroundColor Yellow
}

$action = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -SourceFont "{1}" -BackupDir "{2}"' -f $ScriptPath, $SourceFont, $BackupDir

schtasks /Create /TN $TaskName /TR $action /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null

# 回读确认
$query = schtasks /Query /TN $TaskName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] 开机任务已注册：$TaskName" -ForegroundColor Green
    Write-Host "     源字体  : $SourceFont"
    Write-Host "     日志位置: $BackupDir\boot-replace.log"
    Write-Host ''
    Write-Host '现在执行真重启（不要关机再开机）：' -ForegroundColor Cyan
    Write-Host '    shutdown /r /t 5' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '重启回来后运行 Set-EmojiFont.ps1 -Phase Verify 校验。' -ForegroundColor Cyan
    Write-Host '重要：替换发生在开机后、会话创建前，所以本次重启就是最终一次，无需再重启。' -ForegroundColor Cyan
    Write-Host '（校验若仍显示旧版本，再重启一次即可——内核字体表在会话创建时加载。）' -ForegroundColor Cyan
}
else {
    Write-Host '[ERROR] 任务注册失败：' -ForegroundColor Red
    $query | Out-String | Write-Host
    exit 1
}
