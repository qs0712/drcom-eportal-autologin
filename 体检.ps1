# 校园网自动登录 - 配置体检
# 用途：快速判断"登录失败"是配置问题还是密码错误
# 用法：powershell -ExecutionPolicy Bypass -File 体检.ps1

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $dir 'config.json'

try {
    $ansiCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding($ansiCp)
} catch { }

function Line { param($t) Write-Host $t }
function OK   { param($t) Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn { param($t) Write-Host "  [警告] $t" -ForegroundColor Yellow }
function Bad  { param($t) Write-Host "  [错误] $t" -ForegroundColor Red }

Line '=========================================='
Line '   校园网自动登录 - 配置体检'
Line '=========================================='
Line ''

# ---------- 1. 配置文件检查 ----------
Line '【1】配置文件'

if (-not (Test-Path -LiteralPath $cfgPath)) {
    Bad "找不到 $cfgPath"
    Read-Host '按回车退出'
    exit 1
}

$bytes = [IO.File]::ReadAllBytes($cfgPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if ($hasBom) {
    Warn '文件带 UTF-8 BOM。Windows PowerShell 5.1 可能解析出错，建议用记事本"另存为"选 ANSI 编码。'
} else {
    OK '编码正常（无 BOM）'
}

try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    OK 'JSON 格式正确'
} catch {
    Bad "JSON 解析失败：$($_.Exception.Message)"
    Line '      常见原因：多了/少了逗号、引号不配对、用了中文引号。'
    Read-Host '按回车退出'
    exit 1
}

# 账号
$user = "$($cfg.username)"
Line ''
Line '【2】账号'
Line "  读到: [$user]"
if ([string]::IsNullOrWhiteSpace($user)) {
    Bad '账号是空的'
} else {
    if ($user -ne $user.Trim()) {
        Warn '账号首尾有空格，会导致认证失败！请删掉空格。'
    }
    if ($user -match '@') {
        $suffix = $user.Substring($user.IndexOf('@'))
        OK "运营商后缀: $suffix"
        Line '      核对：@cmcc=移动  @telecom=电信  @unicom=联通'
        Line '      后缀错了会报"密码错误"——因为服务器认为你在用别的运营商账号。'
    } else {
        Warn '账号没有 @运营商 后缀。若你的账号需要后缀（移动/电信/联通），会报"密码错误"。'
    }
    if ($user -match '[\u4e00-\u9fff]') {
        Bad '账号里有中文字符，明显不对'
    }
}

# 密码
$pwd = "$($cfg.password)"
Line ''
Line '【3】密码'
if ([string]::IsNullOrWhiteSpace($pwd)) {
    Bad '密码是空的'
} else {
    OK "密码长度 $($pwd.Length) 位（内容不显示）"
    if ($pwd -ne $pwd.Trim()) { Warn '密码首尾有空格，会导致认证失败！' }
    if ($pwd -match '@') { Warn '密码里含 @ 符号，请确认是否本来就该有' }
}

# ---------- 4. 守护进程状态 ----------
Line ''
Line '【4】守护进程'
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*drcom-login.ps1*' -and $_.CommandLine -notlike '*CimInstance*' })
if ($procs.Count -eq 0) {
    Warn '没有发现守护进程在运行（开机自启可能没装）'
} else {
    foreach ($p in $procs) {
        $age = [math]::Round(((Get-Date) - $p.CreationDate).TotalMinutes, 1)
        OK "PID $($p.ProcessId)  启动于 $($p.CreationDate.ToString('MM-dd HH:mm:ss'))  已运行 $age 分钟"
    }
    $oldest = ($procs | Sort-Object CreationDate | Select-Object -First 1)
    $cfgTime = (Get-Item -LiteralPath $cfgPath).LastWriteTime
    Line "  配置文件最后修改: $($cfgTime.ToString('MM-dd HH:mm:ss'))"
    if ($cfgTime -gt $oldest.CreationDate) {
        OK '配置文件的修改时间晚于守护进程启动时间。'
        Line '      → 主脚本支持热重载（每轮循环检测 config.json 内容哈希，约 20 秒内自动生效），无需重启。'
        Line '      → 若几分钟后自动登录仍在报旧凭据的错，再重启守护进程：'
        Line '        运行「安装-开机自启.bat」选 [2] 卸载，再选 [1] 安装。'
    }
}

# ---------- 5. 直接试一次登录 ----------
Line ''
Line '【5】实测登录一次（用当前配置里的账号密码）'
Line '  正在请求认证服务器...'

$hostAddr = "$($cfg.portal.host)"
$port = if ($cfg.portal.port) { [int]$cfg.portal.port } else { 801 }

# 取本机内网 IP 和 MAC
$ip = ''; $mac = ''
try {
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        if ($ni.NetworkInterfaceType -notin 'Ethernet', 'Wireless80211') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $s = $ua.Address.ToString()
            if ($s -like '169.254.*') { continue }
            if (-not $ip) { $ip = $s; $mac = $ni.GetPhysicalAddress().ToString() }
        }
    }
} catch { }

Line "  本机 IP: $ip   MAC: $mac"

$q = New-Object System.Collections.Specialized.NameValueCollection
$q.Add('callback', 'dr1003')
$q.Add('login_method', '1')
$q.Add('user_account', $user)
$q.Add('user_password', $pwd)
$q.Add('wlan_user_ip', $ip)
$q.Add('wlan_user_ipv6', '')
$q.Add('wlan_user_mac', $mac)
$q.Add('wlan_ac_ip', '')
$q.Add('wlan_ac_name', '')
$q.Add('jsVersion', '4.1.3')
$q.Add('terminal_type', '1')
$q.Add('lang', 'zh-cn')

$parts = @()
foreach ($k in $q.AllKeys) { $parts += ('{0}={1}' -f $k, [Uri]::EscapeDataString($q[$k])) }
$url = "http://${hostAddr}:${port}/eportal/portal/login?" + ($parts -join '&')

try {
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 15 -UseBasicParsing
    $body = $r.Content.Trim()
    Line "  服务器返回: $body"
    if ($body -match '认证成功' -or $body -match '已经在线') {
        OK '账号密码正确，认证服务器接受了本次登录！'
        Line ''
        Line '  => 如果你的守护进程仍在报"密码错误"，说明它还在用旧凭据，'
        Line '     请按上面【4】的办法重启守护进程（卸载再安装）。'
    } elseif ($body -match '密码错误|密码不正确') {
        Bad '认证服务器明确回复"密码错误" —— 是密码本身不对。'
        Line '     请到校园网自助服务确认密码，或到 http://10.31.0.10/ 手动登录试一次。'
    } else {
        Warn '返回了其它结果，请把上面这行"服务器返回"的内容发出来。'
    }
} catch {
    Bad "请求失败：$($_.Exception.Message)"
    Line "     检查 config.json 里的 portal.host 是否为 $hostAddr（当前值），以及本机是否连在校园网上。"
}

Line ''
Read-Host '按回车退出'
