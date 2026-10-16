<#
.SYNOPSIS
    在 Windows 10 上用 Windows 11 的 Segoe UI Emoji 字体替换系统 emoji 字体（可回滚）。

.DESCRIPTION
    分六个阶段执行，默认是只读预览，不加 -Apply 不会改动任何东西：
      Preview    只读检查（无需管理员）
      Prepare    备份原字体 + 导出注册表 + 接管所有权（需管理员）
      Unregister 解除字体注册，让文件不被占用（需管理员，之后需重启）
      Commit     写入新字体 + 恢复注册 + 清理字体缓存（需管理员，之后需重启）
      Verify     检查当前生效的字体版本与表情覆盖
      Rollback   还原备份字体与注册表（需管理员，之后需重启）

    推荐：
      - 常规路径是 Prepare -> Unregister -> 重启 -> Commit -> 重启 -> Verify；
      - 若 Commit 多次因文件被占用失败，改用 Register-BootTask.ps1 注册
        SYSTEM 开机任务（Set-EmojiFont-Boot.ps1），一次重启完成替换。

    注意：请自行从一台 Windows 11 电脑拷贝 C:\Windows\Fonts\seguiemj.ttf，
    或从官方 Win11 ISO 的 sources\install.wim 中提取。本仓库不分发该字体。

.PARAMETER SourceFont
    新字体文件路径（Windows 11 的 seguiemj.ttf），默认取脚本同目录下的 seguiemj.ttf。

.PARAMETER BackupDir
    备份目录，存放原字体、注册表导出与日志，默认 C:\EmojiFontBackup。

.PARAMETER Phase
    执行阶段，默认 Preview。

.PARAMETER Apply
    确认执行开关。不加此开关时，除 Preview/Verify 外的阶段一律拒绝执行。

.EXAMPLE
    # 1) 预览（只读，普通权限即可）
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1

    # 2) 管理员：备份 + 接管所有权
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Prepare

    # 3) 管理员：解除注册
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Unregister
    # -> 完整重启一次

    # 4) 管理员：写入新字体并恢复注册
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Commit
    # -> 再次重启（内核字体表只在会话创建时加载，这次重启不能省）

    # 5) 校验
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Phase Verify

    # 随时回滚
    powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Rollback
#>
[CmdletBinding()]
param(
    [string]$SourceFont = (Join-Path $PSScriptRoot 'seguiemj.ttf'),
    [string]$BackupDir = (Join-Path $env:SystemDrive 'EmojiFontBackup'),
    [ValidateSet('Preview', 'Prepare', 'Unregister', 'Commit', 'Verify', 'Rollback')]
    [string]$Phase = 'Preview',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$SystemFont = Join-Path $env:WINDIR 'Fonts\seguiemj.ttf'
$RegKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Fonts'
)
$RegName = 'Segoe UI Emoji (TrueType)'
$RegData = 'seguiemj.ttf'
$Probes = @(0x1F9CB, 0x1FAE0, 0x1FA77, 0x1FA89, 0x1FAC6)
$ProbeNames = @('bubble tea E13', 'melting face E14', 'pink heart E15', 'harp E16', 'fingerprint E17')
$LogFile = Join-Path $BackupDir 'set-emoji-font.log'

function Write-Step {
    param([string]$Text, [string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = '[{0}] [{1}] {2}' -f $stamp, $Level, $Text
    if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'OK') { Write-Host $line -ForegroundColor Green }
    else { Write-Host $line }
    if (Test-Path $BackupDir) {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FontInfo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    try {
        $gt = [Windows.Media.GlyphTypeface]::new([Uri]::new($Path))
    }
    catch {
        return [PSCustomObject]@{
            Path = $Path; Version = '无法解析'; Family = '?'
            SizeMB = [math]::Round((Get-Item $Path).Length / 1MB, 2)
            Probes = 0; Hash = (Get-FileHash $Path -Algorithm SHA256).Hash.Substring(0, 16)
        }
    }
    $ver = '未知'
    $verVals = @($gt.VersionStrings.Values)
    if ($verVals.Count -gt 0) { $ver = ([string]$verVals[0]).Trim() }
    $fam = '?'
    if ($gt.FamilyNames -and $gt.FamilyNames.Count -gt 0) {
        $fam = (@($gt.FamilyNames.Values))[0]
    }
    $hit = @($Probes | Where-Object { $gt.CharacterToGlyphMap.ContainsKey($_) }).Count
    return [PSCustomObject]@{
        Path    = $Path
        Version = $ver
        Family  = $fam
        SizeMB  = [math]::Round((Get-Item $Path).Length / 1MB, 2)
        Probes  = $hit
        Hash    = (Get-FileHash $Path -Algorithm SHA256).Hash.Substring(0, 16)
    }
}

function Get-RegState {
    $rows = @()
    foreach ($k in $RegKeys) {
        $v = (Get-ItemProperty -Path $k -Name $RegName -ErrorAction SilentlyContinue).$RegName
        $has = $null -ne $v
        $rows += [PSCustomObject]@{ Registry = $k; Registered = $has; Value = $v }
    }
    return $rows
}

function Show-FontTable {
    param([object[]]$Items)
    $rows = @()
    foreach ($i in $Items) {
        if ($null -eq $i) { continue }
        $rows += [PSCustomObject]@{
            Font        = $i.Path
            Version     = $i.Version
            Family      = $i.Family
            SizeMB      = $i.SizeMB
            'NewEmoji'  = ('{0}/5' -f $i.Probes)
            SHA256x16   = $i.Hash
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

function Stop-FontCache {
    foreach ($svc in @('FontCache', 'FontCache3.0.0.0')) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            if ($s.Status -eq 'Running') {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Write-Step ("已停止服务 {0}" -f $svc) 'OK'
            }
        }
        catch { Write-Step ("跳过服务 {0}：{1}" -f $svc, $_.Exception.Message) 'WARN' }
    }
    $cacheDir = Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    if (Test-Path $cacheDir) {
        $removed = 0
        foreach ($f in @(Get-ChildItem -Path $cacheDir -Filter '*.dat' -ErrorAction SilentlyContinue)) {
            try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
        Write-Step ("已清理字体缓存文件 {0} 个" -f $removed) 'OK'
    }
}

function Set-PendingReplace {
    param([string]$Source, [string]$Target)
    $reg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $cur = @((Get-ItemProperty -Path $reg -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations)
    $cur = @($cur | Where-Object { $_ })
    $entry = @(('\??\' + $Source), ('\??\' + $Target))
    Set-ItemProperty -Path $reg -Name 'PendingFileRenameOperations' -Value ($cur + $entry) -Type MultiString
    $check = @((Get-ItemProperty -Path $reg -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations)
    $hits = @($check | Where-Object { $_ -match 'seguiemj' }).Count
    Write-Step ('已登记「重启时替换」，回读校验：写入 {0}/2 条记录' -f $hits) 'WARN'
    Write-Step '警告：若系统开启了快速启动，重启替换可能不被执行。建议改用 Register-BootTask.ps1' 'WARN'
}

# ============================ 主流程 ============================
Write-Host ''
Write-Step ('阶段：{0}    Apply 开关：{1}' -f $Phase, $Apply.IsPresent)

$isAdmin = Test-Admin
$src = Get-FontInfo -Path $SourceFont
$sys = Get-FontInfo -Path $SystemFont

if ($Phase -eq 'Preview') {
    Write-Step '只读预览模式，不会改动任何东西' 'OK'
    Write-Host ''
    Write-Host '—— 字体文件对比 ——'
    Show-FontTable @($sys, $src)
    Write-Step ('当前权限：管理员 = {0}' -f $isAdmin) 'INFO'

    Write-Host '—— 注册表状态 ——'
    Get-RegState | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    if ($null -eq $src) {
        Write-Step ('找不到新字体文件：{0}' -f $SourceFont) 'ERROR'
        Write-Step '请把 Windows 11 的 seguiemj.ttf 放到脚本同目录，或用 -SourceFont 指定路径' 'INFO'
        exit 1
    }

    Write-Host '—— 新字体表情探测 ——'
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    $gt = [Windows.Media.GlyphTypeface]::new([Uri]::new($SourceFont))
    for ($i = 0; $i -lt $Probes.Count; $i++) {
        $ok = $gt.CharacterToGlyphMap.ContainsKey($Probes[$i])
        $tag = '缺失'
        if ($ok) { $tag = '存在' }
        Write-Host ('   U+{0:X5}  {1,-20} {2}' -f $Probes[$i], $ProbeNames[$i], $tag)
    }

    Write-Host ''
    Write-Host '—— 计划执行的动作 ——'
    Write-Host ('   1) 备份原字体到 {0}' -f $BackupDir)
    Write-Host  '   2) 导出字体注册表项'
    Write-Host  '   3) 解除 Segoe UI Emoji 注册 -> 重启'
    Write-Host ('   4) 用 {0} 覆盖系统字体，恢复注册，清理字体缓存 -> 重启' -f $SourceFont)
    Write-Host  '   5) Verify 校验；不满意执行 Rollback'
    Write-Host ''
    Write-Step '确认无误后，以管理员身份执行：-Apply -Phase Prepare' 'OK'
    exit 0
}

if ($Phase -eq 'Verify') {
    Write-Host '—— 当前系统 emoji 字体 ——'
    Show-FontTable @($sys)
    Get-RegState | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    $gt = [Windows.Media.GlyphTypeface]::new([Uri]::new($SystemFont))
    for ($i = 0; $i -lt $Probes.Count; $i++) {
        $ok = $gt.CharacterToGlyphMap.ContainsKey($Probes[$i])
        $tag = '缺失'
        if ($ok) { $tag = '存在' }
        Write-Host ('   U+{0:X5}  {1,-20} {2}' -f $Probes[$i], $ProbeNames[$i], $tag)
    }
    exit 0
}

if (-not $Apply) {
    Write-Step ('阶段 {0} 会改动系统文件，必须显式加 -Apply 才会执行' -f $Phase) 'ERROR'
    Write-Step '先不加参数运行一次可查看只读预览' 'INFO'
    exit 1
}
if (-not $isAdmin) {
    Write-Step '需要管理员权限：请用「以管理员身份运行」的 PowerShell 重新执行' 'ERROR'
    exit 1
}

switch ($Phase) {

    'Prepare' {
        if ($null -eq $src) { Write-Step ('找不到新字体文件：{0}' -f $SourceFont) 'ERROR'; exit 1 }
        if ($src.Family -notlike '*Segoe UI Emoji*') {
            Write-Step ('源文件字族不是 Segoe UI Emoji：{0}' -f $src.Family) 'ERROR'; exit 1
        }
        if ($src.Probes -lt 5) {
            Write-Step ('源文件缺少新表情字形（命中 {0}/5），拒绝执行' -f $src.Probes) 'ERROR'; exit 1
        }

        if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }
        Write-Step ('备份目录：{0}' -f $BackupDir) 'OK'

        $bak = Join-Path $BackupDir 'seguiemj.ttf.original'
        if (-not (Test-Path $bak)) {
            Copy-Item -Path $SystemFont -Destination $bak -Force
            Write-Step ('已备份原字体 -> {0}' -f $bak) 'OK'
        }
        else {
            Write-Step '原字体备份已存在，保留最早的一份' 'WARN'
        }

        Get-RegState | Export-Clixml -Path (Join-Path $BackupDir 'fonts-registry.xml') -Force
        foreach ($k in $RegKeys) {
            $regPath = $k.Replace('HKLM:', 'HKLM')
            try {
                & reg.exe export $regPath (Join-Path $BackupDir ('fonts-' + ($RegKeys.IndexOf($k)) + '.reg')) /y | Out-Null
            }
            catch { Write-Step ('注册表导出失败（可忽略）：{0}' -f $_.Exception.Message) 'WARN' }
        }
        Write-Step '已导出字体注册表' 'OK'

        $meta = [PSCustomObject]@{
            time       = (Get-Date).ToString('s')
            old_version = $sys.Version
            old_hash    = $sys.Hash
            old_size_mb = $sys.SizeMB
            new_version = $src.Version
            new_hash    = $src.Hash
            new_path    = $SourceFont
        }
        $meta | ConvertTo-Json | Set-Content -Path (Join-Path $BackupDir 'backup-info.json') -Encoding UTF8
        Write-Step '已写入备份说明 backup-info.json' 'OK'

        Write-Step '接管系统字体文件所有权…'
        & takeown.exe /f $SystemFont /a | Out-Null
        & icacls.exe $SystemFont /grant '*S-1-5-32-544:F' | Out-Null
        Write-Step '所有权已接管（Administrators 完全控制）' 'OK'

        Write-Step 'Prepare 完成。下一步执行 -Apply -Phase Unregister' 'OK'
    }

    'Commit' {
        $bak = Join-Path $BackupDir 'seguiemj.ttf.original'
        if (-not (Test-Path $bak)) {
            Write-Step ('没有找到备份 {0}，为安全起见拒绝执行' -f $bak) 'ERROR'; exit 1
        }
        $metaPath = Join-Path $BackupDir 'backup-info.json'
        $expected = $null
        if (Test-Path $metaPath) {
            $expected = ((Get-Content $metaPath -Raw | ConvertFrom-Json)).new_hash
        }

        Stop-FontCache

        $now = Get-FontInfo -Path $SystemFont
        $targetOk = ($null -ne $expected -and $now.Hash -eq $expected)

        if (-not $targetOk) {
            if (-not (Test-Path $SourceFont)) {
                Write-Step ('源字体不存在且系统字体还不是目标版本：{0}' -f $SourceFont) 'ERROR'
                exit 1
            }
            try {
                if (Test-Path $SystemFont) {
                    Remove-Item -Path $SystemFont -Force -ErrorAction Stop
                    Write-Step '已删除旧字体文件（断开 WinSxS 硬链接，而非原地覆写）' 'OK'
                }
                Copy-Item -Path $SourceFont -Destination $SystemFont -Force -ErrorAction Stop
                Write-Step '新字体已写入 C:\Windows\Fonts\seguiemj.ttf' 'OK'
            }
            catch {
                Write-Step ('直接替换失败：{0}' -f $_.Exception.Message) 'WARN'
                if (-not (Test-Path $SystemFont)) {
                    Copy-Item -Path $bak -Destination $SystemFont -Force -ErrorAction SilentlyContinue
                    Write-Step '已先恢复原字体，保证系统不缺文件' 'OK'
                }
                Set-PendingReplace -Source $SourceFont -Target $SystemFont
                Write-Step '建议改用 Register-BootTask.ps1 走开机任务替换（PFRO 不可靠）' 'WARN'
                exit 0
            }
            $now = Get-FontInfo -Path $SystemFont
        }
        else {
            Write-Step '系统字体已是目标版本，跳过复制' 'OK'
        }

        Write-Step ('当前系统字体版本：{0}（哈希 {1}）' -f $now.Version, $now.Hash) 'OK'
        if ($null -ne $expected -and $now.Hash -ne $expected) {
            Write-Step '写入后的哈希与目标不一致，暂不注册，请排查后重试' 'ERROR'
            exit 1
        }

        foreach ($k in $RegKeys) {
            $cur = (Get-ItemProperty -Path $k -Name $RegName -ErrorAction SilentlyContinue).$RegName
            if (-not $cur) {
                New-ItemProperty -Path $k -Name $RegName -Value $RegData -PropertyType String -Force | Out-Null
                Write-Step ('已恢复注册：{0}' -f $k) 'OK'
            }
        }
        Stop-FontCache
        Write-Step 'Commit 完成。请重启系统后执行 -Phase Verify 校验' 'OK'
    }

    'Unregister' {
        Write-Step '解除 Segoe UI Emoji 注册（完成 Commit 前 emoji 显示会暂时异常）' 'WARN'
        Stop-FontCache
        foreach ($k in $RegKeys) {
            if ((Get-ItemProperty -Path $k -Name $RegName -ErrorAction SilentlyContinue).$RegName) {
                Remove-ItemProperty -Path $k -Name $RegName -Force
                Write-Step ('已解除注册：{0}' -f $k) 'OK'
            }
        }
        Write-Step 'Unregister 完成。请重启，然后执行 -Apply -Phase Commit' 'OK'
    }

    'Rollback' {
        $bak = Join-Path $BackupDir 'seguiemj.ttf.original'
        if (-not (Test-Path $bak)) { Write-Step ('找不到备份 {0}' -f $bak) 'ERROR'; exit 1 }
        Stop-FontCache
        try {
            Copy-Item -Path $bak -Destination $SystemFont -Force -ErrorAction Stop
            Write-Step '已还原原字体' 'OK'
        }
        catch {
            Write-Step ('直接还原失败：{0}' -f $_.Exception.Message) 'WARN'
            Set-PendingReplace -Source $bak -Target $SystemFont
        }
        foreach ($k in $RegKeys) {
            $cur = (Get-ItemProperty -Path $k -Name $RegName -ErrorAction SilentlyContinue).$RegName
            if (-not $cur) {
                New-ItemProperty -Path $k -Name $RegName -Value $RegData -PropertyType String -Force | Out-Null
                Write-Step ('已恢复注册：{0}' -f $k) 'OK'
            }
        }
        Stop-FontCache
        $now = Get-FontInfo -Path $SystemFont
        Write-Step ('当前系统字体版本：{0}' -f $now.Version) 'OK'
        Write-Step 'Rollback 完成，请重启系统' 'OK'
    }
}
