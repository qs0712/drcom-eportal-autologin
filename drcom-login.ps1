<#
    Dr.COM (城市热点) 校园网自动登录 / 断线重连
    适配 http://10.31.0.10/  (认证接口 http://10.31.0.10:801/eportal/portal/login)

    用法:
        powershell -ExecutionPolicy Bypass -File drcom-login.ps1            # 守护循环: 断线自动登录
        powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Once      # 只跑一轮(在线则跳过)
        powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Force     # 无论在线与否都登录一次
        powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Status    # 只查状态

    账号密码写在同目录 config.json 里, 本脚本不存储凭据。
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Force,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

# 控制台输出编码与系统代码页对齐（Windows 中文版为 936/GBK）。
# 否则在 .bat 里调用时，中文日志会因为 PowerShell 默认按 UTF-8 输出而显示成乱码。
try {
    $ansiCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    $consoleEncoding = [System.Text.Encoding]::GetEncoding($ansiCp)
    [Console]::OutputEncoding = $consoleEncoding
    $OutputEncoding = $consoleEncoding
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogPath = Join-Path $ScriptDir 'drcom.log'

# 单实例互斥：防止计划任务和手动双击同时跑出两个守护进程（会重复发登录请求）。
# -Status / -Once / -Force 属于一次性调用，不加锁。
$script:Mutex = $null
if (-not ($Status -or $Once -or $Force)) {
    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\DrComAutoLoginDaemon', [ref]$createdNew)
    if (-not $createdNew) {
        Write-Host '已有自动登录进程在运行，本次退出。'
        $script:Mutex.Dispose()
        exit 0
    }
}

# ---------------------------------------------------------------- 日志
# 日志里带上进程号：万一将来出现两个守护进程同时写日志，
# 一眼就能从 PID 区分开（正常情况应该始终是同一个 PID）。
$script:MyPid = $PID

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $script:MyPid, $Message
    Write-Host $line
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        # 裁剪阈值来自 config.json 的 maxLogKB（默认 1024）；超限时裁到最近 1000 行。
        # 裁剪用命名互斥锁 + 双重检查：-Status/-Once 等一次性调用也会写日志，
        # 避免两个进程同时进入"读 Tail→写回"窗口互相覆盖丢行。
        $maxKB = if ($script:MaxLogKB) { [int]$script:MaxLogKB } else { 1024 }
        if ((Get-Item -LiteralPath $LogPath).Length -gt ($maxKB * 1KB)) {
            $trimMutex = New-Object System.Threading.Mutex($false, 'Global\DrComLogTrim')
            try {
                if ($trimMutex.WaitOne(2000)) {
                    if ((Get-Item -LiteralPath $LogPath).Length -gt ($maxKB * 1KB)) {
                        $keep = Get-Content -LiteralPath $LogPath -Tail 1000
                        Set-Content -LiteralPath $LogPath -Value $keep -Encoding UTF8
                    }
                    $trimMutex.ReleaseMutex()
                }
            } finally {
                $trimMutex.Dispose()
            }
        }
    } catch { }
}

# ---------------------------------------------------------------- 配置
function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到配置文件: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($cfg.username) -or [string]::IsNullOrWhiteSpace($cfg.password)) {
        throw "请先编辑 $ConfigPath , 填入 username 和 password 后再运行。"
    }
    # 日志裁剪阈值随配置加载/热重载一起刷新（config.json 的 maxLogKB，默认 1024）
    $script:MaxLogKB = if ($cfg.maxLogKB) { [int]$cfg.maxLogKB } else { 1024 }
    return $cfg
}

# ---------------------------------------------------------------- 网络探测
function Get-PortalParams {
    <# 从认证网关首页提取 wlan_user_ip / wlan_user_mac / ac_ip 等参数。
       未登录时该页跳转到认证页, 参数同样存在。 #>
    param([string]$PortalHost = '10.31.0.10')
    $result = @{ ip = ''; ipv6 = ''; mac = ''; acip = ''; acname = '' }
    $resp = $null
    try {
        # 用 HttpWebRequest 替代 WebClient：显式 5 秒超时。WebClient 没有超时属性
        # （默认约 100 秒），网关"半死"（吞包不回）时登录流程会被它拖住，
        # 断线恢复速度明显变慢。
        $req = [System.Net.HttpWebRequest]::Create("http://$PortalHost/")
        $req.Timeout = 5000
        $req.ReadWriteTimeout = 5000
        $req.AllowAutoRedirect = $true   # 未登录时该页跳转到认证页，参数同样存在
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::GetEncoding('gb2312'))
        $html = $sr.ReadToEnd()
        $sr.Close()
    } catch {
        Write-Log "读取网关首页失败: $($_.Exception.Message)" 'WARN'
        return $result
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }   # 异常路径也要释放，否则长期运行会漏连接
    }
    foreach ($pair in @{ ip = 'v4ip'; ipv6 = 'v6ip'; mac = 'mac'; acip = 'wlanacip'; acname = 'wlanacname' }.GetEnumerator()) {
        $m = [regex]::Match($html, "$($pair.Value)\s*=\s*'([^']*)'")
        if ($m.Success) { $result[$pair.Key] = $m.Groups[1].Value.Trim() }
    }
    # 网关页取不到 ip / mac 就退回本机网卡
    $macClean = ($result.mac -replace '[^0-9A-Fa-f]', '')
    if ([string]::IsNullOrWhiteSpace($result.ip) -or $result.ip -eq '000.000.000.000.' -or [string]::IsNullOrWhiteSpace($macClean)) {
        $local = Get-LocalIdentity
        if ([string]::IsNullOrWhiteSpace($result.ip) -or $result.ip -eq '000.000.000.000.') { $result.ip = $local.ip }
        if ([string]::IsNullOrWhiteSpace($macClean)) { $result.mac = $local.mac }
    }
    $result.mac = ($result.mac -replace '[^0-9A-Fa-f]', '')
    return $result
}

function Get-LocalIdentity {
    <# 本机内网 IPv4 + 网卡 MAC #>
    $out = @{ ip = ''; mac = '' }
    try {
        $candidates = @()
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            if ($ni.NetworkInterfaceType -notin 'Ethernet', 'Wireless80211') { continue }
            $props = $ni.GetIPProperties()
            $gw = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ipStr = $ua.Address.ToString()
                if ($ipStr -like '169.254.*') { continue }
                $candidates += [pscustomobject]@{
                    Ip     = $ipStr
                    Mac    = $ni.GetPhysicalAddress().ToString()
                    HasGw  = ($gw.Count -gt 0)
                    IsPrivate = ($ipStr -like '10.*' -or $ipStr -like '192.168.*' -or $ipStr -like '172.*')
                }
            }
        }
        $pick = $candidates | Sort-Object -Property @{E = { $_.HasGw }; Descending = $true }, @{E = { $_.IsPrivate }; Descending = $true } | Select-Object -First 1
        if ($pick) { $out.ip = $pick.Ip; $out.mac = $pick.Mac }
    } catch { }
    return $out
}

function Test-Url-Once {
    <# 探测单个地址，并校验响应内容的"身份"。

       为什么必须校验内容：校园网网关在未认证时会把很多请求**透明劫持**到认证页，
       此时 HTTP 状态码仍然可能是 200，只看状态码会误判成"在线"，
       结果脚本永远不触发登录（这是本脚本踩过的最坑的一个问题）。

       所以这里要求正文里出现约定的关键字（比如 "Microsoft Connect Test"），
       劫持返回的认证页 HTML 里不会有这些字，就能可靠地判定为离线。

       返回 $true=通 / $false=不通。 #>
    param([string]$Url, [string]$Expect = '', [int]$TimeoutSec = 6)

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'                  # 必须 GET：HEAD 拿不到正文，无法校验身份
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $false      # 被网关劫持时通常是 3xx，直接判离线
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
        $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        if ($code -ge 300) { return $false }   # 3xx = 被重定向到认证页

        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        $sr.Close()

        if ([string]::IsNullOrWhiteSpace($Expect)) { return ($code -lt 400) }
        return ($body -like "*$Expect*")
    } catch {
        return $false
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function Get-ProbeList {
    <# 兼容两种配置写法：
       新: "onlineProbes": [ { "url": "...", "expect": "..." } ]   ← 校验内容身份，推荐
       旧: "probeUrls":    [ "..." ]                                ← 只看状态码，易被白名单误判 #>
    param($Cfg)
    $list = @()
    if ($Cfg.onlineProbes) {
        foreach ($p in @($Cfg.onlineProbes)) {
            if ($p -and $p.url) { $list += @{ url = "$($p.url)"; expect = "$($p.expect)" } }
        }
    } elseif ($Cfg.probeUrls) {
        foreach ($u in @($Cfg.probeUrls)) {
            if (-not [string]::IsNullOrWhiteSpace($u)) { $list += @{ url = "$u"; expect = '' } }
        }
    }
    return $list
}

function Test-Online {
    param($Cfg)
    $timeout = if ($Cfg.probeTimeoutSec) { [int]$Cfg.probeTimeoutSec } else { 6 }
    foreach ($p in (Get-ProbeList -Cfg $Cfg)) {
        if (Test-Url-Once -Url $p.url -Expect $p.expect -TimeoutSec $timeout) { return $true }
    }
    return $false
}

function Get-OnlineProbe {
    <# 返回第一个"内容校验通过"的探测地址，让在线结论可追溯 #>
    param($Cfg)
    $timeout = if ($Cfg.probeTimeoutSec) { [int]$Cfg.probeTimeoutSec } else { 6 }
    foreach ($p in (Get-ProbeList -Cfg $Cfg)) {
        if (Test-Url-Once -Url $p.url -Expect $p.expect -TimeoutSec $timeout) { return $p.url }
    }
    return ''
}

function Test-ProxyProblem {
    <# 识别"网络本身是通的，但浏览器被残留的代理设置坑了"这种典型故障。

       本脚本用 .NET HttpWebRequest 探测，它默认直连、不读 WinINET 系统代理；
       而浏览器和多数应用会读系统代理。所以代理软件(Clash / v2rayN 等)退出后，
       若代理设置仍指向一个没人监听的端口，就会出现矛盾现象：
           脚本认为在线，浏览器却一律"无法访问"。
       这里把这种情况识别出来并明确告警，避免和校园网认证问题混淆。 #>
    $warnings = @()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $s = Get-ItemProperty -Path $key -ErrorAction Stop
        $enabled = ($s.ProxyEnable -eq 1)
        $server = "$($s.ProxyServer)"
        $pac = "$($s.AutoConfigURL)"

        if ($enabled -and -not [string]::IsNullOrWhiteSpace($server)) {
            $m = [regex]::Match($server, '(?:^|;|=)(?:https?=)?(?:[\w\.\-]+):(\d{2,5})')
            if ($m.Success) {
                $port = [int]$m.Groups[1].Value
                $alive = $false
                try {
                    $cli = New-Object System.Net.Sockets.TcpClient
                    $iar = $cli.BeginConnect('127.0.0.1', $port, $null, $null)
                    $alive = $iar.AsyncWaitHandle.WaitOne(1000)
                    if ($alive) { $cli.EndConnect($iar) }
                    $cli.Close()
                } catch { $alive = $false }

                if (-not $alive) {
                    $warnings += "系统代理指向 $server，但该端口没有程序在监听（代理软件已退出）。这会导致浏览器全部打不开，而本脚本仍显示在线。"
                    $warnings += "处理办法：Internet 选项→连接→局域网设置，取消勾选『为 LAN 使用代理服务器』；或重新启动代理软件。"
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($pac) -and $pac -notmatch '^https?://') {
            $warnings += "系统配置了自动代理脚本(AutoConfigURL=$pac)，异常时也会导致浏览器打不开网页。"
        }
    } catch { }

    # Wintun / TAP 隧道网卡：代理软件的 TUN 模式退出后可能残留，干扰流量
    try {
        $tunnels = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|TAP-Windows|WireGuard|OpenVPN' })
        foreach ($t in $tunnels) {
            $warnings += "隧道网卡『$($t.Name)』($($t.InterfaceDescription))处于启用状态，可能是代理/VPN 软件残留，异常时建议禁用。"
        }
    } catch { }

    return $warnings
}

# ---------------------------------------------------------------- 登录
function Invoke-PortalLogin {
    param($Cfg, [string]$SessionId)
    $host_ = $Cfg.portal.host
    $port = if ($Cfg.portal.port) { [int]$Cfg.portal.port } else { 801 }

    $q = New-Object System.Collections.Specialized.NameValueCollection
    $q.Add('callback', 'dr1003')
    $q.Add('login_method', '1')
    $q.Add('user_account', $Cfg.username.Trim())
    $q.Add('user_password', $Cfg.password)
    $q.Add('wlan_user_ip', $SessionId.ip)
    $q.Add('wlan_user_ipv6', $SessionId.ipv6)
    $q.Add('wlan_user_mac', $SessionId.mac)
    $q.Add('wlan_ac_ip', $SessionId.acip)
    $q.Add('wlan_ac_name', $SessionId.acname)
    $q.Add('jsVersion', '4.1.3')
    $q.Add('terminal_type', '1')
    $q.Add('lang', 'zh-cn')
    $q.Add('v', (Get-Random -Minimum 1000 -Maximum 9999).ToString())

    $parts = @()
    foreach ($k in $q.AllKeys) {
        $parts += ('{0}={1}' -f $k, [Uri]::EscapeDataString($q[$k]))
    }
    $url = "http://${host_}:${port}/eportal/portal/login?" + ($parts -join '&')

    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec 15 -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'; 'Referer' = "http://$host_/" }
        $body = $r.Content
    } catch {
        Write-Log "登录请求异常: $($_.Exception.Message)" 'WARN'
        return $false
    }

    $body = $body.Trim()
    $jsonText = $body
    $m = [regex]::Match($body, '^[A-Za-z_$][\w$]*\((.*)\);?$', 'Singleline')
    if ($m.Success) { $jsonText = $m.Groups[1].Value }

    $ok = $false
    $msg = $body
    try {
        $obj = $jsonText | ConvertFrom-Json
        $msg = $obj.msg
        $ret = "$($obj.ret_code)"
        if ([int]$obj.result -eq 1) { $ok = $true }
        elseif ($ret -eq '2' -or ($obj.msg -match '已经在线')) { $ok = $true }   # 已在线视为成功
    } catch {
        if ($body -match '认证成功|已经在线') { $ok = $true }
    }

    if ($ok) {
        Write-Log "登录成功: $msg" 'OK'
    } else {
        # 失败时把"用的是哪个账号、密码几位"写出来，方便立刻判断是不是配置填错。
        # 绝不写密码本身。
        $acct = "$($Cfg.username)".Trim()
        $plen = "$($Cfg.password)".Length
        Write-Log "登录失败: $msg  (本次使用的账号『$acct』, 密码长度 $plen 位)" 'ERROR'
        if ($msg -match '密码错误|密码不正确') {
            Write-Log "提示: 密码错误说明 config.json 里的密码不对（注意核对运营商后缀 @cmcc/@telecom/@unicom）。" 'WARN'
            Write-Log "      守护进程支持热重载，改完 config.json 约 20 秒内自动生效；若仍未生效再重启守护进程。" 'WARN'
        }
    }
    # 不回传任何含密码的内容到日志
    return $ok
}

# ---------------------------------------------------------------- 主流程
try {
    $cfg = Get-Config
} catch {
    Write-Log $_.Exception.Message 'FATAL'
    exit 2
}

if ($Status) {
    $online = Test-Online -Cfg $cfg
    $sid = Get-PortalParams -PortalHost $cfg.portal.host
    Write-Log "状态: $(if ($online) { '在线' } else { '离线' })  IP=$($sid.ip)  MAC=$($sid.mac)"
    if ($online) {
        $probe = Get-OnlineProbe -Cfg $cfg
        Write-Log "验证依据: 成功访问 $probe"
        Write-Log "提示: 此结论来自本机直连测试。若浏览器仍打不开网页，多半是系统代理设置问题，不是校园网认证问题。"
    }
    foreach ($w in (Test-ProxyProblem)) { Write-Log "代理检查: $w" 'WARN' }
    exit $(if ($online) { 0 } else { 1 })
}

$failStreak = 0
$lastOnlineState = $null   # 用于记录"在线↔离线"的状态翻转

function Write-ProbeDetail {
    <# 断网时把每个探测地址的实测结果写进日志。
       没有这个就很难判断"到底是真断网，还是探测被白名单放行了"。 #>
    param($Cfg)
    $timeout = if ($Cfg.probeTimeoutSec) { [int]$Cfg.probeTimeoutSec } else { 6 }
    foreach ($p in (Get-ProbeList -Cfg $Cfg)) {
        $r = Test-Url-Once -Url $p.url -Expect $p.expect -TimeoutSec $timeout
        $verdict = if ($r) { '可达' } else { '不可达' }
        $exp = if ([string]::IsNullOrWhiteSpace($p.expect)) { '(不校验内容)' } else { "期望内容『$($p.expect)』" }
        Write-Log "  探测 $($p.url) → $verdict  $exp" 'WARN'
    }
}

# 心跳计数器：每 N 轮循环写一行"我还活着"
$script:Heartbeat = 0
$script:HeartbeatEvery = 90   # 90 轮 × 每轮约 20 秒 ≈ 30 分钟（心跳只证明进程存活，日志量降到原来的 1/6）

try {
    while ($true) {
        # ---- 配置热重载 ----
        # 守护进程常驻内存，如果启动后再去改 config.json（比如改错了密码又改回来），
        # 不重载的话它会一直用旧凭据，表现为"手动登录能成功、自动登录报密码错误"。
        # 用内容哈希判断，而不是文件的修改时间——时间戳可能因为各种原因不变或不准。
        try {
            $cfgHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm MD5).Hash
            if ($script:CfgHash -and $cfgHash -ne $script:CfgHash) {
                Write-Log '检测到 config.json 内容有变化, 重新加载账号配置…' 'WARN'
                $cfg = Get-Config
                $failStreak = 0                                  # 刚改完配置，给一次立刻重试的机会
                Write-Log "配置已重载 (账号: $($cfg.username))" 'OK'
            }
            $script:CfgHash = $cfgHash
        } catch {
            Write-Log "读取配置失败: $($_.Exception.Message)" 'WARN'
        }

        $online = Test-Online -Cfg $cfg

        # 心跳：在线期间也周期性写一行，用于确认守护进程确实活着、循环在跑。
        # （掉线/恢复属于状态翻转，另有专门日志；这里只是"我还活着"的凭证）
        $script:Heartbeat++
        if ($script:Heartbeat -ge $script:HeartbeatEvery) {
            $script:Heartbeat = 0
            $probe = if ($online) { Get-OnlineProbe -Cfg $cfg } else { '' }
            $state = if ($online) { "在线 ($probe)" } else { '离线' }
            Write-Log "心跳: 守护进程运行中, 当前状态 $state" 'INFO'
        }

        # 只在状态翻转时记一笔，避免刷屏
        if ($lastOnlineState -ne $online) {
            if ($online) {
                if ($lastOnlineState -eq $false) {
                    $p = Get-OnlineProbe -Cfg $cfg
                    $secs = if ($script:OfflineAt) { [math]::Round(((Get-Date) - $script:OfflineAt).TotalSeconds, 1) } else { 0 }
                    Write-Log "网络已恢复 (内容校验通过: $p)  本次中断约 ${secs} 秒" 'OK'
                    $script:OfflineAt = $null
                }
            } else {
                if (-not $script:OfflineAt) { $script:OfflineAt = Get-Date }
                Write-Log '检测到断网 (所有探测地址的内容校验均未通过)' 'WARN'
                Write-ProbeDetail -Cfg $cfg
            }
            $lastOnlineState = $online
        }

        if ($online -and -not $Force) {
            $failStreak = 0
            if ($Once) {
                $probe = Get-OnlineProbe -Cfg $cfg
                Write-Log "网络正常, 无需登录。"
                Write-Log "验证依据: 成功访问 $probe (内容校验通过)"
                Write-Log "提示: 若浏览器仍打不开网页, 请检查系统代理设置(代理软件退出后会残留死代理)。" 'INFO'
                exit 0
            }
            Start-Sleep -Seconds ([int]$cfg.checkIntervalSec)
            continue
        }

        if ($Force -or -not $online) {
            if (-not $online) { Write-Log '尝试登录…' 'WARN' }
            $loginStart = Get-Date
            $sid = Get-PortalParams -PortalHost $cfg.portal.host
            $ok = Invoke-PortalLogin -Cfg $cfg -SessionId $sid
            $loginMs = [math]::Round(((Get-Date) - $loginStart).TotalMilliseconds)
            if ($ok) {
                $failStreak = 0
                Write-Log "登录耗时 ${loginMs} 毫秒" 'OK'
                Start-Sleep -Seconds 3
                $probe = Get-OnlineProbe -Cfg $cfg
                if ($probe) { Write-Log "联网确认通过 (成功访问 $probe)" 'OK' }
                else {
                    Write-Log '登录返回成功但外网仍不通, 稍后重试。' 'WARN'
                    foreach ($w in (Test-ProxyProblem)) { Write-Log "可能原因: $w" 'WARN' }
                }
            } else {
                $failStreak++
            }
        }

        if ($Once -or $Force) { exit $(if ($ok) { 0 } else { 1 }) }

        if ($failStreak -ge 3) {
            # 退避上限 60 秒。原来是 300 秒，但那样一旦退避到顶，
            # 网络恢复后最多要等 5 分钟才会重试，对频繁闪断的校园网体验很差。
            # 60 秒的代价只是持续故障时每分钟发一次登录请求（本地请求，很轻）。
            $wait = [Math]::Min(60, 20 * $failStreak)
            Write-Log "连续失败 $failStreak 次, 等待 ${wait}s 后重试(请检查账号密码/是否被限制)。" 'WARN'
            Start-Sleep -Seconds $wait
        } else {
            Start-Sleep -Seconds ([int]$cfg.checkIntervalSec)
        }
    }
} finally {
    # 退出（含 Ctrl+C）时释放单实例锁
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        try { $script:Mutex.Dispose() } catch { }
    }
}
