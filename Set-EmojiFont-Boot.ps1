# Set-EmojiFont-Boot.ps1
# 开机早期由 SYSTEM 执行：强制替换 emoji 字体 + 恢复注册 + 清缓存 + 自删任务
# 用法（参数由 Register-BootTask.ps1 自动写入任务）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File Set-EmojiFont-Boot.ps1 -SourceFont <路径> -BackupDir <目录>
param(
    [Parameter(Mandatory = $true)][string]$SourceFont,
    [string]$BackupDir = (Join-Path $env:SystemDrive 'EmojiFontBackup')
)
$ErrorActionPreference = 'Continue'
$Log = Join-Path $BackupDir 'boot-replace.log'
$Dst = Join-Path $env:WINDIR 'Fonts\seguiemj.ttf'
$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$RegName = 'Segoe UI Emoji (TrueType)'
$RegData = 'seguiemj.ttf'
$TaskName = 'Replace-EmojiFont-Once'

if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }

function L($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Out-File $Log -Append -Encoding utf8 }

try {
    L "===== 开机替换开始 ====="

    if (-not (Test-Path $SourceFont)) {
        throw ("源字体不存在：" + $SourceFont)
    }

    # 1. 解除占用：停字体缓存服务
    Stop-Service FontCache -Force -ErrorAction SilentlyContinue
    L "FontCache 服务已停止"

    # 2. 接管所有权与 ACL
    takeown /F $Dst /A | Out-Null
    icacls $Dst /grant "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null
    L "已接管文件所有权与 ACL"

    # 3. 删除旧字体（断开 WinSxS 硬链接）
    if (Test-Path $Dst) {
        Remove-Item $Dst -Force -ErrorAction Stop
        L "旧字体已删除"
    }

    # 4. 拷贝新字体
    Copy-Item $SourceFont $Dst -Force -ErrorAction Stop
    L ("新字体已写入，大小 " + (Get-Item $Dst).Length + " 字节")

    # 5. 重新注册
    New-ItemProperty -Path $RegPath -Name $RegName -Value $RegData -PropertyType String -Force | Out-Null
    L "注册表已恢复注册"

    # 6. 清缓存
    Stop-Service FontCache -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache\*.dat" -Force -ErrorAction SilentlyContinue
    L "字体缓存已清理"

    # 7. 校验
    $ver = (Get-Item $Dst).VersionInfo.FileVersion
    $sz  = (Get-Item $Dst).Length
    L ("校验：FileVersion=" + $ver + "  Size=" + $sz)

    if ($sz -gt 10000000) {
        L "===== 替换成功（新字体 >10MB）。注意：内核字体表在下次会话创建时才加载新字体 ====="
    } else {
        L "===== 警告：文件大小异常，可能仍是旧字体 ====="
    }
}
catch {
    L ("失败：" + $_.Exception.Message)
    # 尽力恢复注册，避免停留在"无 emoji 字体"状态
    if (Test-Path $Dst) {
        New-ItemProperty -Path $RegPath -Name $RegName -Value $RegData -PropertyType String -Force | Out-Null
        L "已恢复注册（保留现状字体）"
    }
}
finally {
    # 8. 自删任务
    schtasks /Delete /TN $TaskName /F | Out-Null
    L "一次性任务已自删"
}
