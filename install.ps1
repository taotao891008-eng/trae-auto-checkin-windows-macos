#Requires -Version 5.1
<#
  安装 Trae 每日签到（Windows）：
    1. 复制脚本到 %LOCALAPPDATA%\TraeCheckin
    2. 注册计划任务 TraeCheckin：
       - 触发器 A：登录/开机后 1 分钟（并每 30 分钟重试 24 小时，用于断网补签）
       - 触发器 B：每天 00:05（并每小时重试 24 小时，用于跨 0 点自动再签一次）
    3. 可选立即跑一次「只查询」验证

  用法：
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -CheckinTime "00:30"
    powershell -ExecutionPolicy Bypass -File install.ps1 -NoStart

  说明：
    - 计划任务以当前用户身份运行，不需要管理员权限
    - macOS 请使用仓库里的 macos/install.sh（与 Windows 安装脚本互不通用）
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

function Set-PrivateFileAcl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, "FullControl", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Host "  提示：未能收紧配置文件权限（$($_.Exception.Message)），请确认该文件仅本人可读。" -ForegroundColor Yellow
    }
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

try {
    $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Fail "配置文件解析失败：$($_.Exception.Message)"
}

# 补齐新增配置项，兼容旧版 config.json（保留用户已有值）
$defaults = [ordered]@{
    ApiHost               = "api.trae.cn"
    ProxyUrl              = ""
    CheckinTime           = "00:05"
    WaitForNetworkMinutes = 30
    RetryIntervalSeconds  = 30
    RequestTimeoutSeconds = 20
    NotifyOnFailure       = $true
    AuthToken             = ""
    AuthTokenProtected    = ""
    DeviceId              = ""
    ReqSource             = 1
}
foreach ($key in $defaults.Keys) {
    if (-not ($cfg.PSObject.Properties.Name -contains $key)) {
        $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
    }
}

if ($PSBoundParameters.ContainsKey("CheckinTime") -and $CheckinTime) {
    $cfg.CheckinTime = $CheckinTime
}
if (-not $cfg.CheckinTime) { $cfg.CheckinTime = "00:05" }
if ($cfg.CheckinTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
    Fail "签到时间格式不正确：$($cfg.CheckinTime)（应为 HH:mm，例如 00:05）"
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configFile -Encoding UTF8
Set-PrivateFileAcl -Path $configFile

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
Write-Host "  已启用 StartWhenAvailable：睡眠/关机错过了 00:05，唤醒或开机后会补跑"

$hasToken = [bool]($cfg.AuthTokenProtected -or $cfg.AuthToken -or $env:TRAE_CHECKIN_TOKEN)
if (-not $NoStart) {
    if (-not $hasToken) {
        Write-Host "已跳过立即验证：尚未配置令牌。" -ForegroundColor Yellow
        Write-Host "下一步（令牌不会回显、不会进日志、不会进对话）："
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$checkinPath`" -SetToken"
    } else {
        Write-Host "立即启动一次「只查询」验证（不会重复领积分）..."
        $p = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $checkinPath, "-Mode", "Status") `
            -Wait -PassThru -WindowStyle Hidden
        $code = $p.ExitCode
        $meaning = switch ($code) {
            0 { "成功（令牌有效）" }
            1 { "请求失败，看日志" }
            2 { "等待网络超时，看日志/代理设置" }
            3 { "未配置令牌或令牌失效" }
            4 { "配置或本地环境错误" }
            default { "未知" }
        }
        Write-Host "  退出码：$code（$meaning）"
        if ($code -ne 0) {
            Write-Host "  日志：$InstallDir\logs\checkin.log" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "日志：$InstallDir\logs\checkin.log"
Write-Host "当天完成标记：$InstallDir\state.json"
Write-Host "查看状态：powershell -ExecutionPolicy Bypass -File `"$checkinPath`" -Mode Status"
Write-Host "加密保存令牌：powershell -ExecutionPolicy Bypass -File `"$checkinPath`" -SetToken"
Write-Host "卸载：powershell -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
