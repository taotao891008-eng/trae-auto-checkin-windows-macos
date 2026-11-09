#Requires -Version 5.1
<#
  卸载 Trae 每日签到：删除计划任务，并清理安装目录。

  用法：
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepFiles
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -InstallDir "D:\Tools\TraeCheckin"

  说明：
    - 默认会删除计划任务和安装目录（含日志、当天完成标记、本地配置）
    - -KeepFiles 只删计划任务，保留文件，便于排查
    - 如果目录里有 .git（说明这是源码仓库而不是安装目录），默认拒绝删除
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
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
} else {
    Write-Host "计划任务不存在：$TaskName"
}

if ($KeepFiles) {
    Write-Host "已保留安装目录：$InstallDir"
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
if ($InstallDir -match '^[A-Za-z]:$' -or $InstallDir -eq $env:USERPROFILE -or $InstallDir -eq $env:LOCALAPPDATA) {
    Write-Host "拒绝对系统目录执行删除：$InstallDir" -ForegroundColor Red
    exit 1
}

# 先删除可以立即删除的内容，目录本身交给后台命令延时删除（避免当前目录占用）
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

Write-Host "卸载完成：计划任务已移除，文件已清理。" -ForegroundColor Green
