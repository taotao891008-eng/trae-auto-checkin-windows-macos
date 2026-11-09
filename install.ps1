#Requires -Version 5.1
<#
  安装 Trae 每日签到：
    1. 复制脚本到 %LOCALAPPDATA%\TraeCheckin
    2. 注册计划任务 TraeCheckin：
       - 触发器 A：登录/开机后 1 分钟（并每 30 分钟重试 24 小时，用于断网补签）
       - 触发器 B：每天 00:05（并每小时重试 24 小时，用于跨 0 点自动再签一次）
    3. 可选立即启动一次做验证

  用法：
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -CheckinTime "00:30"
    powershell -ExecutionPolicy Bypass -File install.ps1 -NoStart

  说明：
    - 计划任务以当前用户身份运行，不需要管理员权限
    - 不需要关闭杀毒软件；如被拦截，请参考 README 的加白名单流程
#>
[CmdletBinding()]
param(
    [string]$CheckinTime = "",
    [string]$TaskName = "TraeCheckin",
    [string]$InstallDir = "",
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA "TraeCheckin" }

function Fail([string]$Message) {
    Write-Host "[失败] $Message" -ForegroundColor Red
    exit 1
}

Write-Host "安装目录：$InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# 复制程序文件（脚本与说明每次覆盖更新）
foreach ($name in @("checkin.ps1", "uninstall.ps1", "README.md")) {
    $src = Join-Path $SourceDir $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $name) -Force
    }
}

# 配置文件：已存在则保留用户设置，否则使用示例配置初始化
$configFile = Join-Path $InstallDir "config.json"
if (-not (Test-Path -LiteralPath $configFile)) {
    $srcConfig = Join-Path $SourceDir "config.example.json"
    if (-not (Test-Path -LiteralPath $srcConfig)) { $srcConfig = Join-Path $SourceDir "config.json" }
    if (-not (Test-Path -LiteralPath $srcConfig)) { Fail "缺少 config.example.json" }
    Copy-Item -LiteralPath $srcConfig -Destination $configFile -Force
}

$cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($PSBoundParameters.ContainsKey("CheckinTime") -and $CheckinTime) {
    $cfg.CheckinTime = $CheckinTime
}
if (-not $cfg.CheckinTime) { $cfg.CheckinTime = "00:05" }
if ($cfg.CheckinTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
    Fail "签到时间格式不正确：$($cfg.CheckinTime)（应为 HH:mm，例如 00:05）"
}
$cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8

$checkinPath = Join-Path $InstallDir "checkin.ps1"
$userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
$now = Get-Date
$startBoundary = $now.ToString("yyyy-MM-dd") + "T" + $cfg.CheckinTime + ":00"

$argsText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $checkinPath + '"'

$xml = @"
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>TraeCheckin</Author>
    <Description>Trae 每日签到（本地运行，仅访问 api.trae.cn；每天只成功签到一次，跨 0 点自动再签）。</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <UserId>$(& $esc $userName)</UserId>
      <Delay>PT1M</Delay>
    </LogonTrigger>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $esc $userName)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(& $esc $argsText)</Arguments>
      <WorkingDirectory>$(& $esc $InstallDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

try {
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
} catch {
    Fail "注册计划任务失败：$($_.Exception.Message)"
}

# 记录任务名，供 uninstall.ps1 读取（避免自定义 TaskName 时卸载删错任务）
Set-Content -LiteralPath (Join-Path $InstallDir "taskname.txt") -Value $TaskName -Encoding UTF8

Write-Host "计划任务已注册：$TaskName" -ForegroundColor Green
Write-Host "  触发器 1：登录/开机后 1 分钟，之后每 30 分钟重试一次（持续 24 小时）"
Write-Host "  触发器 2：每天 $($cfg.CheckinTime)，之后每小时重试一次（持续 24 小时）"
Write-Host "  已启用 StartWhenAvailable：台式机休眠/关机错过了 00:05，唤醒或开机后会补跑"

if (-not $NoStart) {
    if (-not $cfg.AuthToken -and -not $env:TRAE_CHECKIN_TOKEN) {
        Write-Host "已跳过立即验证：尚未配置 AuthToken。" -ForegroundColor Yellow
        Write-Host "请编辑 $configFile，把令牌填入 AuthToken，然后重新运行 install.ps1 或直接运行 -Mode Status 验证。"
    } else {
        Write-Host "立即启动一次做验证（只查询，不会重复领积分）..."
        try {
            Start-ScheduledTask -TaskName $TaskName
            Start-Sleep -Seconds 12
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            Write-Host ("  上次运行结果：" + $info.LastTaskResult)
        } catch {
            Write-Host "  启动验证失败：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "日志：$InstallDir\logs\checkin.log"
Write-Host "当天完成标记：$InstallDir\state.json"
Write-Host "查看状态：powershell -ExecutionPolicy Bypass -File `"$checkinPath`" -Mode Status"
