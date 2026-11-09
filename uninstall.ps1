#Requires -Version 5.1
<#
  卸载 Trae 每日签到：停止并删除计划任务，清理安装目录与本地令牌。

  用法：
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepFiles
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -InstallDir "D:\Tools\TraeCheckin"

  说明：
    - 默认删除计划任务和安装目录（含日志、当天完成标记、config.json，即令牌一并删除）
    - -KeepFiles 只删计划任务，保留文件，便于排查
    - 如果目录里有 .git（说明这是源码仓库而不是安装目录），默认拒绝删除
    - DPAPI 加密的令牌密文就存在 config.json 里，删掉该文件即失效；
      DPAPI 的“用户级主密钥”由 Windows 为用户统一管理（%APPDATA%\Microsoft\Protect），
      无法只删本工具那一条，也不建议删（会影响其他程序）。
#>
[CmdletBinding()]
param(
    [string]$TaskName = "",
    [string]$InstallDir = "",
    [switch]$KeepFiles,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $InstallDir) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# 优先使用安装时记录的任务名，避免自定义 TaskName 时卸载删错任务
if (-not $TaskName) {
    $marker = Join-Path $InstallDir "taskname.txt"
    if (Test-Path -LiteralPath $marker) {
        $TaskName = (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim()
    }
    if (-not $TaskName) { $TaskName = "TraeCheckin" }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    try {
        if ($task.State -eq "Running") {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    } catch {}
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
    } catch {
        Write-Host "删除计划任务失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "请以管理员身份运行，或在任务计划程序中手动删除 $TaskName。"
        exit 1
    }
} else {
    Write-Host "计划任务不存在：$TaskName"
}

if ($env:TRAE_CHECKIN_TOKEN) {
    Write-Host "注意：当前会话设置了环境变量 TRAE_CHECKIN_TOKEN。" -ForegroundColor Yellow
    Write-Host "如果它是你为长期使用而永久设置的，请自行删除（用户级）："
    Write-Host '  [Environment]::SetEnvironmentVariable("TRAE_CHECKIN_TOKEN", $null, "User")'
}

if ($KeepFiles) {
    Write-Host "已保留安装目录：$InstallDir"
    Write-Host "其中 config.json 仍可能含有令牌密文；确认不再使用后，删除该文件即可让密文失效。"
    exit 0
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Host "安装目录不存在，无需清理：$InstallDir"
    exit 0
}

# 安全检查：避免误删源码仓库、盘符根目录或用户主目录
if ((Test-Path -LiteralPath (Join-Path $InstallDir ".git")) -and -not $Force) {
    Write-Host "检测到 .git 目录，$InstallDir 看起来是源码仓库，已拒绝删除。" -ForegroundColor Yellow
    Write-Host "如确认要删除，请显式传入 -Force，或手动删除该目录。"
    exit 1
}
if ($InstallDir -match '^[A-Za-z]:$' -or $InstallDir -eq $env:USERPROFILE -or $InstallDir -eq $env:LOCALAPPDATA -or
    $InstallDir -eq (Join-Path $env:USERPROFILE "Documents") -or $InstallDir -eq [System.IO.Path]::GetPathRoot($InstallDir)) {
    Write-Host "拒绝对系统目录执行删除：$InstallDir" -ForegroundColor Red
    exit 1
}

# 先删除可以立即删除的内容（含 logs、notify 标记、state.json、锁文件、DPAPI 密文所在 config.json）
Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
    catch { Write-Host "未能删除：$($_.FullName)（$($_.Exception.Message)）" -ForegroundColor Yellow }
}

# 用 loopback ping 制造几秒延时，等本进程释放目录后再删除（127.0.0.1 仅作延时，不访问外部网络）
$cmdLine = '/c ping -n 4 127.0.0.1 >nul & rmdir /s /q "' + $InstallDir + '"'
try {
    Start-Process -FilePath (Join-Path $env:SystemRoot "System32\cmd.exe") -ArgumentList $cmdLine -WindowStyle Hidden | Out-Null
    Write-Host "安装目录将在后台清理：$InstallDir"
} catch {
    Write-Host "后台清理启动失败，请手动删除：$InstallDir" -ForegroundColor Yellow
}

Write-Host "卸载完成：计划任务已移除、文件已清理、DPAPI 密文随 config.json 删除。" -ForegroundColor Green
