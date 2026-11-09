#Requires -Version 5.1
<#
  Trae CN 每日签到（手工令牌版）

  安全边界：
    - 不读取 Trae 客户端的 storage.json，不解密任何登录态文件
    - 只读本工具自己的 config.json / state.json
    - 绝不回写 config.json，绝不把令牌上传到任何地方
    - 令牌只在内存中使用，日志和弹窗自动打码

  用法：
    powershell -ExecutionPolicy Bypass -File checkin.ps1
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -Mode Status
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -WaitMinutes 0

  退出码：
    0 = 成功 / 今日已签到 / 签到未启用
    1 = 签到请求失败
    2 = 等待网络超时
    3 = 未配置令牌或令牌无效/过期
    4 = 配置或本地环境错误
#>
[CmdletBinding()]
param(
    [ValidateSet("Auto", "Status")] [string]$Mode = "Auto",
    [string]$ConfigPath = "",
    [int]$WaitMinutes = -1,
    [switch]$DryRun,
    [switch]$NoNotify,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot "config.json" }
$LogDir = Join-Path $ScriptRoot "logs"
$LogFile = Join-Path $LogDir "checkin.log"
$StateFile = Join-Path $ScriptRoot "state.json"
$NotifyFlagDir = Join-Path $LogDir "notify"

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LogFile) {
        $len = (Get-Item -LiteralPath $LogFile).Length
        if ($len -gt 2MB) {
            $bak = "$LogFile.1"
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
            Move-Item -LiteralPath $LogFile -Destination $bak -Force
        }
    }
}

function Protect-Text {
    param([string]$Text)
    if (-not $Text) { return "" }
    $safe = $Text
    if ($script:SecretToken) {
        $safe = $safe.Replace($script:SecretToken, "***")
    }
    # 兜底：把形似 JWT 的长串统一打码
    return [regex]::Replace($safe, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', "***")
}

function Write-Log {
    param(
        [ValidateSet("INFO", "WARN", "ERROR")] [string]$Level,
        [string]$Message,
        [switch]$Echo
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, (Protect-Text $Message)
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($Echo -or $Mode -eq "Status") { Write-Host $line }
}

function Get-Config {
    $defaults = [ordered]@{
        ApiHost               = "api.trae.cn"
        CheckinTime           = "00:05"
        WaitForNetworkMinutes = 30
        RetryIntervalSeconds  = 30
        RequestTimeoutSeconds = 20
        NotifyOnFailure       = $true
        AuthToken             = ""
        DeviceId              = ""
        ReqSource             = 1
    }
    $cfg = [pscustomobject]$defaults
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) {
                if ($defaults.Contains($p.Name)) { $cfg.($p.Name) = $p.Value }
            }
        } catch {
            throw "配置文件解析失败：$($_.Exception.Message)"
        }
    }
    if (-not $cfg.ApiHost) { $cfg.ApiHost = "api.trae.cn" }
    return $cfg
}

# ---------- 当天完成状态（本地去重，成功当天不再调用接口） ----------
function Get-DayKey {
    # 签到按北京时间自然日计算（UTC+8）
    return [DateTime]::UtcNow.AddHours(8).ToString("yyyy-MM-dd")
}

function Get-DayState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Update-DayState {
    param([hashtable]$Changes)
    $data = [ordered]@{}
    $old = Get-DayState
    if ($old) {
        foreach ($p in $old.PSObject.Properties) { $data[$p.Name] = $p.Value }
    }
    foreach ($k in $Changes.Keys) { $data[$k] = $Changes[$k] }
    try {
        $data | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch {
        Write-Log -Level WARN -Message "写入本地状态失败：$($_.Exception.Message)"
    }
}

function Set-DayCompleted {
    param([int]$Credits = -1)
    Update-DayState -Changes @{
        lastSuccessDay = (Get-DayKey)
        lastSuccessAt  = [DateTime]::UtcNow.AddHours(8).ToString("yyyy-MM-dd HH:mm:ss") + " +08:00"
        lastCredits    = $Credits
    }
}

function Get-OrCreateDeviceId {
    $state = Get-DayState
    if ($state -and $state.deviceId) { return [string]$state.deviceId }
    $id = [guid]::NewGuid().ToString()
    Update-DayState -Changes @{ deviceId = $id }
    return $id
}

function Get-Auth {
    param($Cfg)
    $token = [string]$env:TRAE_CHECKIN_TOKEN
    $source = "环境变量 TRAE_CHECKIN_TOKEN"
    if (-not $token) {
        $token = [string]$Cfg.AuthToken
        $source = "config.json 的 AuthToken"
    }
    if (-not $token) { return $null }
    $device = [string]$Cfg.DeviceId
    if (-not $device) { $device = Get-OrCreateDeviceId }
    return [pscustomobject]@{
        Token    = $token.Trim()
        DeviceId = $device
        Source   = $source
    }
}

# ---------- 网络 ----------
function Test-ApiNetwork {
    param([string]$HostName, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, 443)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

function Invoke-CheckinApi {
    param(
        [string]$BaseHost,
        [string]$Path,
        [string]$Token,
        [string]$DeviceId,
        [int]$TimeoutSec,
        [int]$ReqSource
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri = "https://$BaseHost$Path"
    $headers = @{
        "Authorization" = "Cloud-IDE-JWT $Token"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
        "Origin"        = "https://www.trae.cn"
        "Referer"       = "https://www.trae.cn/"
    }
    if ($DeviceId) { $headers["x-device-id"] = $DeviceId }
    $body = '{"req_source":' + [string]$ReqSource + '}'

    try {
        $resp = Invoke-WebRequest -Uri $uri -Method POST -Headers $headers -Body $body -UseBasicParsing -TimeoutSec $TimeoutSec
        return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content; Error = "" }
    } catch {
        $ex = $_.Exception
        if ($ex.Response) {
            $code = 0
            try { $code = [int]$ex.Response.StatusCode } catch {}
            $bodyText = ""
            try {
                $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                $bodyText = $reader.ReadToEnd()
                $reader.Dispose()
            } catch {}
            return [pscustomobject]@{ StatusCode = $code; Body = $bodyText; Error = $ex.Message }
        }
        return [pscustomobject]@{ StatusCode = 0; Body = ""; Error = $ex.Message }
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# ---------- 通知 ----------
function Show-VisibleNotice {
    param([string]$Title, [string]$Message, [switch]$Force)
    if ($NoNotify -and -not $Force) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $safeTitle = [System.Security.SecurityElement]::Escape((Protect-Text $Title))
        $safeMessage = [System.Security.SecurityElement]::Escape((Protect-Text $Message))
        $xmlText = "<toast><visual><binding template=`"ToastGeneric`"><text>$safeTitle</text><text>$safeMessage</text></binding></visual></toast>"
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
        $appId = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return
    } catch {}
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup((Protect-Text $Message), 20, (Protect-Text $Title), 48) | Out-Null
    } catch {}
}

function Send-FailureNotice {
    param($Cfg, [string]$Type, [string]$Title, [string]$Message)
    if ($NoNotify -or -not $Cfg.NotifyOnFailure) { return }
    try {
        if (-not (Test-Path -LiteralPath $NotifyFlagDir)) {
            New-Item -ItemType Directory -Path $NotifyFlagDir -Force | Out-Null
        }
        $flag = Join-Path $NotifyFlagDir ("{0}-{1}.flag" -f (Get-Date -Format "yyyyMMdd"), $Type)
        if (Test-Path -LiteralPath $flag) { return }
        New-Item -ItemType File -Path $flag -Force | Out-Null
    } catch {}
    Show-VisibleNotice -Title $Title -Message $Message
}

# ---------- 主流程 ----------
function Invoke-Main {
    param($Cfg)

    Write-Log -Level INFO -Message ("开始运行：模式=$Mode" + $(if ($DryRun) { "（演练）" } else { "" }))

    if ($Cfg.WaitForNetworkMinutes -lt 0 -or $Cfg.RetryIntervalSeconds -lt 5) {
        Write-Log -Level ERROR -Message "配置无效：WaitForNetworkMinutes 必须 >= 0，RetryIntervalSeconds 必须 >= 5"
        return 4
    }

    # 本地去重：当天已成功签到则直接跳过，不再调用任何接口
    if ($Mode -eq "Auto" -and -not $DryRun -and -not $Force) {
        $today = Get-DayKey
        $dayState = Get-DayState
        if ($dayState -and $dayState.lastSuccessDay -eq $today) {
            Write-Log -Level INFO -Message ("当天已完成（$today，上次成功 $($dayState.lastSuccessAt)），本次触发跳过，未调用接口。")
            return 0
        }
    }

    $auth = Get-Auth -Cfg $Cfg
    if (-not $auth -or -not $auth.Token) {
        $msg = "尚未配置签到令牌。请按 README 把本次要用的 JWT 粘贴到 config.json 的 AuthToken（脚本不会读取 Trae 客户端的任何登录文件）。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "token" -Title "Trae 签到未配置令牌" -Message $msg
        return 3
    }
    $script:SecretToken = $auth.Token
    Write-Log -Level INFO -Message ("使用手工令牌，来源：$($auth.Source)。令牌已脱敏，不会写入日志。")

    # 网络等待
    $waitMin = if ($WaitMinutes -ge 0) { $WaitMinutes } else { [int]$Cfg.WaitForNetworkMinutes }
    $deadline = (Get-Date).AddMinutes($waitMin)
    $online = Test-ApiNetwork -HostName $Cfg.ApiHost -TimeoutMs 5000
    if (-not $online) {
        Write-Log -Level WARN -Message ("网络不可用，开始等待（最多 {0} 分钟，每 {1} 秒重试）" -f $waitMin, $Cfg.RetryIntervalSeconds)
        while (-not $online -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds ([int]$Cfg.RetryIntervalSeconds)
            $online = Test-ApiNetwork -HostName $Cfg.ApiHost -TimeoutMs 5000
        }
    }
    if (-not $online) {
        $msg = "等待网络超时（$waitMin 分钟）。计划任务会稍后自动重试，网络恢复后当天仍可补签。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "network" -Title "Trae 签到：暂时没有网络" -Message $msg
        return 2
    }
    Write-Log -Level INFO -Message "网络可用，开始查询签到状态"

    $timeout = [int]$Cfg.RequestTimeoutSeconds
    $statusResp = Invoke-CheckinApi -BaseHost $Cfg.ApiHost -Path "/trae/api/v2/ug/checkin_credits/status" `
        -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource)

    if ($statusResp.StatusCode -eq 0) {
        $msg = "查询签到状态失败：$($statusResp.Error)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "status" -Title "Trae 签到失败：状态查询" -Message $msg
        return 1
    }
    if ($statusResp.StatusCode -eq 401 -or $statusResp.StatusCode -eq 403) {
        $msg = "令牌无效或已过期（HTTP $($statusResp.StatusCode)）。请重新获取令牌并更新 config.json 的 AuthToken。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "auth" -Title "Trae 签到失败：令牌失效" -Message $msg
        return 3
    }
    if ($statusResp.StatusCode -ne 200) {
        $msg = "查询签到状态失败（HTTP $($statusResp.StatusCode)）：$($statusResp.Body)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "status" -Title "Trae 签到失败：状态查询" -Message $msg
        return 1
    }

    $status = ConvertFrom-JsonSafe -Text $statusResp.Body
    if (-not $status) {
        $msg = "签到状态响应无法解析：$($statusResp.Body)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "status" -Title "Trae 签到失败：响应异常" -Message $msg
        return 1
    }

    $statusCode = if ($status.code -ne $null) { [int]$status.code } else { 0 }
    if ($statusCode -eq 1001) {
        $msg = "令牌无效或已过期（code=1001）。请重新获取令牌并更新 config.json 的 AuthToken。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "auth" -Title "Trae 签到失败：令牌失效" -Message $msg
        return 3
    }
    if ($statusCode -ne 0) {
        $msg = "查询签到状态失败（code=$statusCode）：$($status.message)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "status" -Title "Trae 签到失败：状态查询" -Message $msg
        return 1
    }

    $checkedIn = [bool]$status.checked_in
    $credits = if ($status.credits -ne $null) { [int]$status.credits } else { 0 }
    $extra = if ($status.extra_credits -ne $null) { [int]$status.extra_credits } else { 0 }
    $enabled = if ($status.enable -ne $null) { [bool]$status.enable } else { $true }

    if ($checkedIn) {
        Write-Log -Level INFO -Message ("今日已签到，跳过领取。当前积分：{0}，额外：{1}" -f $credits, $extra)
        Set-DayCompleted -Credits ($credits + $extra)
        return 0
    }
    if (-not $enabled) {
        Write-Log -Level INFO -Message "签到功能当前未启用（enable=false），跳过。"
        return 0
    }
    if ($Mode -eq "Status" -or $DryRun) {
        Write-Log -Level INFO -Message ("今日未签到（enable=true，当前积分 {0}）。本次为只读模式，未执行领取。" -f $credits)
        return 0
    }

    Write-Log -Level INFO -Message "今日未签到，发起领取"
    $claimResp = Invoke-CheckinApi -BaseHost $Cfg.ApiHost -Path "/trae/api/v2/ug/checkin_credits/claim" `
        -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource)

    if ($claimResp.StatusCode -eq 0) {
        $msg = "签到请求失败：$($claimResp.Error)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "claim" -Title "Trae 签到失败" -Message $msg
        return 1
    }
    if ($claimResp.StatusCode -eq 401 -or $claimResp.StatusCode -eq 403) {
        $msg = "领取时令牌失效（HTTP $($claimResp.StatusCode)）。请重新获取令牌并更新 config.json。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "auth" -Title "Trae 签到失败：令牌失效" -Message $msg
        return 3
    }

    $claim = ConvertFrom-JsonSafe -Text $claimResp.Body
    $claimCode = if ($claim -and $claim.code -ne $null) { [int]$claim.code } else { -1 }
    $claimMsg = if ($claim -and $claim.message) { [string]$claim.message } else { "" }

    if ($claimResp.StatusCode -eq 200 -and $claimCode -eq 0) {
        $finalCredits = -1
        $detail = "签到成功（HTTP 200, code=0）"
        # 再查一次状态，记录本次实际积分（失败不影响成功结论）
        $after = Invoke-CheckinApi -BaseHost $Cfg.ApiHost -Path "/trae/api/v2/ug/checkin_credits/status" `
            -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource)
        if ($after.StatusCode -eq 200) {
            $afterObj = ConvertFrom-JsonSafe -Text $after.Body
            if ($afterObj -and $afterObj.credits -ne $null) {
                $c2 = [int]$afterObj.credits
                $e2 = if ($afterObj.extra_credits -ne $null) { [int]$afterObj.extra_credits } else { 0 }
                $finalCredits = $c2 + $e2
                $detail += "，今日积分 $c2（额外 $e2，合计 $finalCredits）"
            }
        }
        Write-Log -Level INFO -Message $detail
        Set-DayCompleted -Credits $finalCredits
        return 0
    }

    if ($claimCode -eq 1001) {
        $msg = "令牌无效或已过期（code=1001）。请重新获取令牌并更新 config.json 的 AuthToken。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "auth" -Title "Trae 签到失败：令牌失效" -Message $msg
        return 3
    }

    $msg = "签到未成功（HTTP $($claimResp.StatusCode)，code=$claimCode，message=$claimMsg）"
    Write-Log -Level ERROR -Message $msg
    Send-FailureNotice -Cfg $Cfg -Type "claim" -Title "Trae 签到失败" -Message $msg
    return 1
}

# ---------- 入口 ----------
Initialize-Log
$mutex = New-Object System.Threading.Mutex($false, "Local\TraeCheckin_Mutex")
$hasLock = $false
try {
    try { $hasLock = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $hasLock = $true }

    if (-not $hasLock) {
        Write-Log -Level WARN -Message "已有另一个签到实例在运行，本次退出。"
        exit 0
    }

    $exitCode = 4
    try {
        $cfg = Get-Config
        $exitCode = Invoke-Main -Cfg $cfg
    } catch {
        Write-Log -Level ERROR -Message ("运行异常：" + $_.Exception.Message)
        try {
            $fallbackCfg = [pscustomobject]@{ NotifyOnFailure = $true; ApiHost = "api.trae.cn" }
            Send-FailureNotice -Cfg $fallbackCfg -Type "exception" -Title "Trae 签到异常" -Message $_.Exception.Message
        } catch {}
        $exitCode = 1
    }

    Write-Log -Level INFO -Message "本次运行结束，退出码 $exitCode"
    exit $exitCode
} finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
}
