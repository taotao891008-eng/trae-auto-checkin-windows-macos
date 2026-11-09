#Requires -Version 5.1
<#
  Trae CN 每日签到（手工令牌版）

  安全边界：
    - 不读取 Trae 客户端的 storage.json，不解密任何登录态文件
    - 只读本工具自己的 config.json / state.json
    - 绝不把令牌上传到任何地方；日志和弹窗自动打码
    - 支持用 Windows DPAPI（当前用户）加密保存令牌，密文只在本机

  用法：
    powershell -ExecutionPolicy Bypass -File checkin.ps1
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -Mode Status
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -WaitMinutes 0
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -SetToken
    powershell -ExecutionPolicy Bypass -File checkin.ps1 -ProtectToken

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
    [switch]$Force,
    [switch]$ProtectToken,
    [switch]$SetToken
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
$LockFile = Join-Path $ScriptRoot "checkin.lock"
$StateLockFile = Join-Path $ScriptRoot "state.lock"
$NotifyFlagDir = Join-Path $LogDir "notify"

$script:MaxLogBytes = 2MB
$script:LogBytes = 0
$script:SecretToken = ""
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------- 日志 ----------
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
    } catch {}
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    $len = 0
    try { $len = (Get-Item -LiteralPath $LogFile).Length } catch { return }
    if ($len -le $script:MaxLogBytes) { return }
    $bak = "$LogFile.1"
    try {
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
        Move-Item -LiteralPath $LogFile -Destination $bak -Force
        $script:LogBytes = 0
    } catch {}
}

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Rotate-LogIfNeeded
    if (Test-Path -LiteralPath $LogFile) {
        try { $script:LogBytes = (Get-Item -LiteralPath $LogFile).Length } catch { $script:LogBytes = 0 }
        Set-PrivateFileAcl -Path $LogFile
    }
}

function Protect-Text {
    param([string]$Text)
    if (-not $Text) { return "" }
    $safe = $Text
    if ($script:SecretToken) {
        $safe = $safe.Replace($script:SecretToken, "***")
    }
    # 兜底：形似 JWT 的长串统一打码，避免异常信息里带出凭据
    return [regex]::Replace($safe, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}', "***")
}

function Write-Log {
    param(
        [ValidateSet("INFO", "WARN", "ERROR")] [string]$Level,
        [string]$Message,
        [switch]$Echo
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, (Protect-Text $Message)
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        $script:LogBytes += [System.Text.Encoding]::UTF8.GetByteCount($line) + 2
        if ($script:LogBytes -gt $script:MaxLogBytes) { Rotate-LogIfNeeded }
    } catch {}
    if ($Echo -or $Mode -eq "Status") { Write-Host $line }
}

# ---------- 配置 ----------
function Get-Config {
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
    if ($cfg.ApiHost -notmatch '^[A-Za-z0-9.-]+(:[0-9]{1,5})?$') {
        throw "ApiHost 不合法：$($cfg.ApiHost)"
    }
    return $cfg
}

function Get-RawConfigObject {
    if (Test-Path -LiteralPath $ConfigPath) {
        try { return (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { throw "配置文件解析失败：$($_.Exception.Message)" }
    }
    return [pscustomobject]@{}
}

function Write-JsonAtomic {
    param([string]$Path, $Object, [switch]$Private)
    $json = $Object | ConvertTo-Json -Depth 6
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    $done = $false
    for ($i = 0; $i -lt 6 -and -not $done; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                [System.IO.File]::Replace($tmp, $Path, [NullString]::Value, $true)
            } else {
                [System.IO.File]::Move($tmp, $Path)
            }
            $done = $true
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 150
        }
    }
    if (-not $done) { throw "写入 $Path 失败（文件被占用）" }
    if ($Private) { Set-PrivateFileAcl -Path $Path }
}

function Save-ConfigObject {
    param($Object)
    Write-JsonAtomic -Path $ConfigPath -Object $Object -Private
}

# ---------- 令牌保护（Windows DPAPI，当前用户） ----------
function Protect-Secret {
    param([string]$Plain)
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("TraeCheckin.v1")
    $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($cipher)
}

function Unprotect-Secret {
    param([string]$Base64)
    Add-Type -AssemblyName System.Security
    $cipher = [Convert]::FromBase64String($Base64)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("TraeCheckin.v1")
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Set-ProtectedTokenInConfig {
    param([string]$Token)
    $obj = Get-RawConfigObject
    $b64 = Protect-Secret -Plain $Token
    if ($obj.PSObject.Properties.Name -contains "AuthTokenProtected") {
        $obj.AuthTokenProtected = $b64
    } else {
        $obj | Add-Member -NotePropertyName "AuthTokenProtected" -NotePropertyValue $b64
    }
    if ($obj.PSObject.Properties.Name -contains "AuthToken") {
        $obj.AuthToken = ""
    } else {
        $obj | Add-Member -NotePropertyName "AuthToken" -NotePropertyValue ""
    }
    Save-ConfigObject -Object $obj
}

function Read-TokenFromConsole {
    $secure = Read-Host -AsSecureString "粘贴 Cloud-IDE-JWT 令牌（不含前缀，输入不会回显）"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    return $plain.Trim()
}

# ---------- 当天完成状态（按北京时间自然日去重） ----------
function Get-DayKey {
    # 固定按 UTC+8 计算，避免用户改本地时区后误判跨天
    return [DateTime]::UtcNow.AddHours(8).ToString("yyyy-MM-dd")
}

function Get-DayState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Invoke-StateLocked {
    param([scriptblock]$Action, [int]$WaitMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    $fs = $null
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($StateLockFile, 'OpenOrCreate', 'ReadWrite', 'None')
            break
        } catch {
            if ((Get-Date) -ge $deadline) { throw "状态文件被其他实例占用超过 ${WaitMs}ms" }
            Start-Sleep -Milliseconds 200
        }
    }
    try { return (& $Action) }
    finally { try { $fs.Dispose() } catch {} }
}

function Update-DayState {
    param([hashtable]$Changes)
    try {
        Invoke-StateLocked {
            $data = [ordered]@{}
            $old = Get-DayState
            if ($old) {
                foreach ($p in $old.PSObject.Properties) { $data[$p.Name] = $p.Value }
            }
            foreach ($k in $Changes.Keys) { $data[$k] = $Changes[$k] }
            Write-JsonAtomic -Path $StateFile -Object $data -Private
        }
    } catch {
        Write-Log -Level WARN -Message "写入本地状态失败：$($_.Exception.Message)"
    }
}

function Set-DayCompleted {
    param([string]$DayKey, [int]$Credits = -1)
    Update-DayState -Changes @{
        lastSuccessDay = $DayKey
        lastSuccessAt  = [DateTime]::UtcNow.AddHours(8).ToString("yyyy-MM-dd HH:mm:ss") + " +08:00"
        lastCredits    = $Credits
    }
}

function Test-DayCompleted {
    param([string]$DayKey)
    $state = Get-DayState
    return [bool]($state -and $state.lastSuccessDay -eq $DayKey)
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
        $protected = [string]$Cfg.AuthTokenProtected
        if ($protected) {
            try {
                $token = Unprotect-Secret -Base64 $protected
                $source = "config.json 的 AuthTokenProtected（DPAPI 加密）"
            } catch {
                return [pscustomobject]@{
                    Token = ""; DeviceId = ""; Source = ""
                    Error = "无法解密 AuthTokenProtected（DPAPI 只能由保存它的同一 Windows 用户解密）。请用 -SetToken 重新保存，或改用环境变量。"
                }
            }
        }
    }
    if (-not $token) {
        $token = [string]$Cfg.AuthToken
        $source = "config.json 的 AuthToken（明文）"
    }
    if (-not $token) { return $null }
    $device = [string]$Cfg.DeviceId
    if (-not $device) { $device = Get-OrCreateDeviceId }
    return [pscustomobject]@{
        Token    = $token.Trim()
        DeviceId = $device
        Source   = $source
        Error    = ""
    }
}

# ---------- 代理 ----------
function Resolve-Proxy {
    param([string]$Configured)
    $raw = [string]$Configured
    if (-not $raw) { $raw = [string]$env:HTTPS_PROXY }
    if (-not $raw) { $raw = [string]$env:HTTP_PROXY }
    if (-not $raw) {
        return [pscustomobject]@{ Url = ""; Host = ""; Port = 0; Invalid = $false; Reason = "" }
    }
    $raw = $raw.Trim()
    if ($raw -notmatch '^(http|https|socks5h?|socks4a?)://') { $raw = "http://$raw" }
    if ($raw -match '^socks') {
        return [pscustomobject]@{
            Url = ""; Host = ""; Port = 0; Invalid = $true
            Reason = "PowerShell 5.1 不支持 SOCKS 代理。请改用代理软件的 HTTP 混合端口（如 http://127.0.0.1:10808），或填写 ProxyUrl。"
        }
    }
    try {
        $u = [Uri]$raw
        if (-not $u.Host) { throw "缺少主机名" }
        $port = $u.Port
        if ($port -le 0) { $port = 80 }
        return [pscustomobject]@{ Url = $raw; Host = $u.Host; Port = $port; Invalid = $false; Reason = "" }
    } catch {
        return [pscustomobject]@{
            Url = ""; Host = ""; Port = 0; Invalid = $true
            Reason = "ProxyUrl 格式不正确：$raw（示例 http://127.0.0.1:10808）"
        }
    }
}

# ---------- 网络 ----------
function Test-ApiNetwork {
    param([string]$HostName, [string]$ProxyHost, [int]$ProxyPort, [int]$TimeoutMs = 5000)
    $target = $HostName
    $port = 443
    if ($HostName -match '^([^:]+):(\d+)$') {
        $target = $matches[1]
        $port = [int]$matches[2]
    }
    if ($ProxyHost) { $target = $ProxyHost; $port = $ProxyPort }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($target, $port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

function ConvertFrom-HttpDate {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try {
        $utc = [DateTime]::Parse($Raw, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        return [pscustomobject]@{
            DayKey      = $utc.AddHours(8).ToString("yyyy-MM-dd")
            SkewMinutes = [int][math]::Round(($utc - [DateTime]::UtcNow).TotalMinutes)
        }
    } catch {
        return $null
    }
}

function Invoke-CheckinApi {
    param(
        [string]$BaseHost,
        [string]$Path,
        [string]$Token,
        [string]$DeviceId,
        [int]$TimeoutSec,
        [int]$ReqSource,
        [string]$ProxyUrl,
        [int]$MaxAttempts = 2
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

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $reqArgs = @{
                Uri = $uri; Method = "POST"; Headers = $headers; Body = $body
                UseBasicParsing = $true; TimeoutSec = $TimeoutSec
            }
            if ($ProxyUrl) { $reqArgs["Proxy"] = $ProxyUrl }
            $resp = Invoke-WebRequest @reqArgs
            $dateHeader = ""
            try { $dateHeader = [string]$resp.Headers["Date"] } catch {}
            return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content; Error = ""; ServerDate = $dateHeader }
        } catch {
            $ex = $_.Exception
            $result = $null
            if ($ex.Response) {
                $code = 0
                try { $code = [int]$ex.Response.StatusCode } catch {}
                $dateHeader = ""
                try { $dateHeader = [string]$ex.Response.Headers["Date"] } catch {}
                $bodyText = ""
                try {
                    $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                    $bodyText = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch {}
                $result = [pscustomobject]@{ StatusCode = $code; Body = $bodyText; Error = $ex.Message; ServerDate = $dateHeader }
            } else {
                $result = [pscustomobject]@{ StatusCode = 0; Body = ""; Error = $ex.Message; ServerDate = "" }
            }
            $transient = ($result.StatusCode -eq 0 -or $result.StatusCode -eq 408 -or $result.StatusCode -ge 500)
            if ($transient -and $attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds 4
                continue
            }
            return $result
        }
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
    if ($NoNotify -and -not $Force) { return $true }
    $errors = @()
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
        return $true
    } catch {
        $errors += "Toast：" + $_.Exception.Message
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup((Protect-Text $Message), 20, (Protect-Text $Title), 48) | Out-Null
        return $true
    } catch {
        $errors += "Popup：" + $_.Exception.Message
    }
    Write-Log -Level WARN -Message ("通知发送失败（已记录，不静默吞掉）：" + ($errors -join "；"))
    return $false
}

function Send-FailureNotice {
    param($Cfg, [string]$Type, [string]$Title, [string]$Message)
    if ($NoNotify -or -not $Cfg.NotifyOnFailure) { return }
    try {
        if (-not (Test-Path -LiteralPath $NotifyFlagDir)) {
            New-Item -ItemType Directory -Path $NotifyFlagDir -Force | Out-Null
        }
        $flag = Join-Path $NotifyFlagDir ("{0}-{1}.flag" -f (Get-DayKey).Replace("-", ""), $Type)
        if (Test-Path -LiteralPath $flag) { return }
        New-Item -ItemType File -Path $flag -Force | Out-Null
    } catch {
        Write-Log -Level WARN -Message ("写入通知去重标记失败：$($_.Exception.Message)")
    }
    [void](Show-VisibleNotice -Title $Title -Message $Message)
}

# ---------- 主流程 ----------
function Invoke-Main {
    param($Cfg)

    Write-Log -Level INFO -Message ("开始运行：模式=$Mode" + $(if ($DryRun) { "（演练）" } else { "" }))

    if ($Cfg.WaitForNetworkMinutes -lt 0 -or $Cfg.WaitForNetworkMinutes -gt 1440) {
        Write-Log -Level ERROR -Message "配置无效：WaitForNetworkMinutes 必须在 0..1440 之间"
        return 4
    }
    if ($Cfg.RetryIntervalSeconds -lt 5 -or $Cfg.RetryIntervalSeconds -gt 600) {
        Write-Log -Level ERROR -Message "配置无效：RetryIntervalSeconds 必须在 5..600 之间"
        return 4
    }
    if ($Cfg.RequestTimeoutSeconds -lt 5 -or $Cfg.RequestTimeoutSeconds -gt 120) {
        Write-Log -Level ERROR -Message "配置无效：RequestTimeoutSeconds 必须在 5..120 之间"
        return 4
    }

    $localDay = Get-DayKey

    # 本地去重：当天已成功签到则直接跳过，不再调用任何接口
    if ($Mode -eq "Auto" -and -not $DryRun -and -not $Force) {
        $dayState = Get-DayState
        if ($dayState -and $dayState.lastSuccessDay -eq $localDay) {
            Write-Log -Level INFO -Message ("当天已完成（$localDay，上次成功 $($dayState.lastSuccessAt)），本次触发跳过，未调用接口。")
            return 0
        }
        if ($dayState -and $dayState.lastSuccessDay) {
            $last = [string]$dayState.lastSuccessDay
            if ($last -gt $localDay) {
                Write-Log -Level WARN -Message "本地记录的上次成功日期（$last）晚于当前日期（$localDay），可能是系统时间被回拨；本次不跳过，按接口实际状态处理（领取接口本身幂等）。"
            }
        }
    }

    $proxy = Resolve-Proxy -Configured $Cfg.ProxyUrl
    if ($proxy.Invalid) {
        Write-Log -Level WARN -Message $proxy.Reason
    } elseif ($proxy.Url) {
        Write-Log -Level INFO -Message ("使用代理：$($proxy.Url)")
    }

    $auth = Get-Auth -Cfg $Cfg
    if ($auth -and $auth.Error) {
        Write-Log -Level ERROR -Message $auth.Error
        Send-FailureNotice -Cfg $Cfg -Type "token" -Title "Trae 签到：令牌无法解密" -Message $auth.Error
        return 4
    }
    if (-not $auth -or -not $auth.Token) {
        $msg = "尚未配置签到令牌。请运行 checkin.ps1 -SetToken 按提示粘贴令牌（只保存在本机配置；脚本不会读取 Trae 客户端的任何登录文件）。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "token" -Title "Trae 签到未配置令牌" -Message $msg
        return 3
    }
    $script:SecretToken = $auth.Token
    Write-Log -Level INFO -Message ("使用手工令牌，来源：$($auth.Source)。令牌已脱敏，不会写入日志。")

    # 网络等待（有代理时检测代理端口，否则直连 443）
    $waitMin = if ($WaitMinutes -ge 0) { $WaitMinutes } else { [int]$Cfg.WaitForNetworkMinutes }
    $deadline = (Get-Date).AddMinutes($waitMin)
    $online = Test-ApiNetwork -HostName $Cfg.ApiHost -ProxyHost $proxy.Host -ProxyPort $proxy.Port -TimeoutMs 5000
    if (-not $online) {
        $tip = "网络不可用，开始等待（最多 {0} 分钟，每 {1} 秒重试）" -f $waitMin, $Cfg.RetryIntervalSeconds
        if (-not $proxy.Url) {
            $tip += "。如果本机需要代理才能访问外网，请在 config.json 填写 ProxyUrl（例如 http://127.0.0.1:10808），或设置 HTTPS_PROXY 环境变量。"
        }
        Write-Log -Level WARN -Message $tip
        while (-not $online -and (Get-Date) -lt $deadline) {
            # Start-Sleep 不占 CPU；不会空转
            Start-Sleep -Seconds ([int]$Cfg.RetryIntervalSeconds)
            $online = Test-ApiNetwork -HostName $Cfg.ApiHost -ProxyHost $proxy.Host -ProxyPort $proxy.Port -TimeoutMs 5000
        }
    }
    if (-not $online) {
        $msg = "等待网络超时（$waitMin 分钟）。计划任务会稍后自动重试，网络恢复后当天仍可补签。"
        if (-not $proxy.Url) { $msg += " 若使用代理，请配置 ProxyUrl。" }
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "network" -Title "Trae 签到：暂时没有网络" -Message $msg
        return 2
    }
    Write-Log -Level INFO -Message "网络可用，开始查询签到状态"

    # 服务器时间兜底：本机时间被改/时区异常时，以接口响应头 Date 判断跨天
    $effectiveDay = $localDay
    $timeout = [int]$Cfg.RequestTimeoutSeconds
    $statusResp = Invoke-CheckinApi -BaseHost $Cfg.ApiHost -Path "/trae/api/v2/ug/checkin_credits/status" `
        -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource) -ProxyUrl $proxy.Url

    $srv = ConvertFrom-HttpDate -Raw $statusResp.ServerDate
    if ($srv) {
        $effectiveDay = $srv.DayKey
        if ($effectiveDay -ne $localDay) {
            Write-Log -Level WARN -Message ("本机日期（$localDay）与服务器日期（$effectiveDay）不一致，跨天判断改用服务器日期。请检查系统时间与时区。")
        } elseif ([math]::Abs($srv.SkewMinutes) -gt 10) {
            Write-Log -Level WARN -Message ("本机时间与服务器相差约 $($srv.SkewMinutes) 分钟，建议校准系统时间。")
        }
    } elseif ($statusResp.StatusCode -ne 0) {
        Write-Log -Level WARN -Message "响应里没有可用的 Date 头，跨天判断使用本机 UTC+8 日期。"
    }

    # 服务器日期确认后再次去重，避免等待网络期间跨过 0 点后重复领取
    if ($Mode -eq "Auto" -and -not $DryRun -and -not $Force -and (Test-DayCompleted -DayKey $effectiveDay)) {
        Write-Log -Level INFO -Message ("当天已完成（服务器日期 $effectiveDay），本次不再领取。")
        return 0
    }

    if ($statusResp.StatusCode -eq 0) {
        $msg = "查询签到状态失败：$($statusResp.Error)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "status" -Title "Trae 签到失败：状态查询" -Message $msg
        return 1
    }
    if ($statusResp.StatusCode -eq 401 -or $statusResp.StatusCode -eq 403) {
        $msg = "令牌无效或已过期（HTTP $($statusResp.StatusCode)）。请运行 checkin.ps1 -SetToken 重新保存令牌。"
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
        $msg = "令牌无效或已过期（code=1001）。请运行 checkin.ps1 -SetToken 重新保存令牌。"
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
        Set-DayCompleted -DayKey $effectiveDay -Credits ($credits + $extra)
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

    # 领取前用服务器日期再确认一次，避免长等待跨过 0 点后重复领取
    if (Test-DayCompleted -DayKey $effectiveDay) {
        Write-Log -Level INFO -Message ("当天已完成（$effectiveDay），取消领取。")
        return 0
    }

    Write-Log -Level INFO -Message "今日未签到，发起领取"
    $claimResp = Invoke-CheckinApi -BaseHost $Cfg.ApiHost -Path "/trae/api/v2/ug/checkin_credits/claim" `
        -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource) -ProxyUrl $proxy.Url

    if ($claimResp.StatusCode -eq 0) {
        $msg = "签到请求失败：$($claimResp.Error)"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "claim" -Title "Trae 签到失败" -Message $msg
        return 1
    }
    if ($claimResp.StatusCode -eq 401 -or $claimResp.StatusCode -eq 403) {
        $msg = "领取时令牌失效（HTTP $($claimResp.StatusCode)）。请运行 checkin.ps1 -SetToken 重新保存令牌。"
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
            -Token $auth.Token -DeviceId $auth.DeviceId -TimeoutSec $timeout -ReqSource ([int]$Cfg.ReqSource) -ProxyUrl $proxy.Url
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
        Set-DayCompleted -DayKey $effectiveDay -Credits $finalCredits
        return 0
    }

    if ($claimCode -eq 1001) {
        $msg = "令牌无效或已过期（code=1001）。请运行 checkin.ps1 -SetToken 重新保存令牌。"
        Write-Log -Level ERROR -Message $msg
        Send-FailureNotice -Cfg $Cfg -Type "auth" -Title "Trae 签到失败：令牌失效" -Message $msg
        return 3
    }

    $msg = "签到未成功（HTTP $($claimResp.StatusCode)，code=$claimCode，message=$claimMsg）"
    Write-Log -Level ERROR -Message $msg
    Send-FailureNotice -Cfg $Cfg -Type "claim" -Title "Trae 签到失败" -Message $msg
    return 1
}

function Enter-RunLock {
    param([int]$WaitMs = 3000)
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    while ($true) {
        try {
            return [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
        } catch {
            if ((Get-Date) -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 300
        }
    }
}

# ---------- 入口 ----------
Initialize-Log

# 令牌维护模式：只在命令行交互使用，不进入签到流程
if ($SetToken -or $ProtectToken) {
    try {
        if ($SetToken) {
            $plain = Read-TokenFromConsole
            if (-not $plain) { throw "没有读到令牌，已取消。" }
            if ($plain.Length -lt 20 -or $plain -notmatch '^[A-Za-z0-9._-]+$') {
                throw "输入内容不像 Cloud-IDE-JWT 令牌（应只包含字母、数字、点、下划线、短横线，且长度 >= 20）。"
            }
            Set-ProtectedTokenInConfig -Token $plain
            $plain = $null
            Write-Host "[完成] 令牌已用 Windows DPAPI（当前用户）加密保存到 $ConfigPath" -ForegroundColor Green
            Write-Host "       配置里不保留明文；只有当前 Windows 用户能解密。"
            exit 0
        }
        $raw = Get-RawConfigObject
        $plain = [string]$raw.AuthToken
        if (-not $plain) {
            if ($raw.PSObject.Properties.Name -contains "AuthTokenProtected" -and $raw.AuthTokenProtected) {
                Write-Host "config.json 已经使用 AuthTokenProtected 加密保存，无需重复处理。"
                exit 0
            }
            throw "config.json 里没有 AuthToken 明文可加密。请先运行 -SetToken。"
        }
        Set-ProtectedTokenInConfig -Token $plain
        Write-Host "[完成] 已加密保存令牌，并清空 config.json 中的 AuthToken 明文。" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -Level ERROR -Message ("令牌维护失败：" + $_.Exception.Message)
        exit 4
    }
}

$mutex = New-Object System.Threading.Mutex($false, "Local\TraeCheckin_Mutex")
$hasLock = $false
$runLock = $null
try {
    try { $hasLock = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $hasLock = $true }

    if (-not $hasLock) {
        Write-Log -Level WARN -Message "已有另一个签到实例在运行，本次退出。"
        exit 0
    }

    # 跨会话/跨进程的兜底文件锁，避免同一时刻重复调用接口
    $runLock = Enter-RunLock
    if (-not $runLock) {
        Write-Log -Level WARN -Message "另一个实例正在运行（文件锁被占用），本次退出，未调用接口。"
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
    if ($runLock) { try { $runLock.Dispose() } catch {} }
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
}
