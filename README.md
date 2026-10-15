# 校园网自动登录（Dr.COM / 城市热点 ePortal）

![Platform](https://img.shields.io/badge/platform-Windows%207%2F10%2F11-blue) ![Runtime](https://img.shields.io/badge/runtime-PowerShell%205.1%2B-5391FE) ![License](https://img.shields.io/badge/license-MIT-green) ![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

针对 **Dr.COM（城市热点）ePortal** 认证系统的 Windows 自动登录工具：**开机自启 + 断线自动重连**，断线约 4 秒恢复。纯 PowerShell 实现，**无任何第三方依赖**，不需要管理员权限。

> **已实测验证环境**：**江西职业技术大学**（Dr.COM 城市热点 ePortal，认证网关 `10.31.0.10:801`，本工具的默认配置即来自该校）。
> 同版本 ePortal 的其它学校理论上可直接使用：把 `config.json` 里的 `portal.host` 改成自己学校的认证网关地址即可。

## 特性

- **开机自动登录**：计划任务在登录 Windows 时拉起，常驻后台（无黑框窗口）
- **断线自动重连**：每 20 秒探测一次，掉线立刻重登，实测约 4 秒恢复
- **可靠掉线判定**：内容校验防透明劫持误判（见[原理](#原理)一节，这是本工具最核心的设计）
- **配置热重载**：改 `config.json` 约 20 秒内自动生效，无需重启
- **单实例互斥**：防止重复守护进程；日志带进程号
- **配置体检**：一键诊断"登录失败"是配置问题还是密码错误
- **零依赖、零安装**：解压即用，卸载只删任务

## 快速开始

### 1. 填账号密码

复制 `config.example.json` 为 `config.json`（与脚本同目录），用记事本填入：

```json
{
    "username": "你的账号@cmcc",
    "password": "你的密码",
    ...
}
```

> **运营商后缀别丢**：登录页显示的账号若带 `@cmcc` 后缀，说明走**中国移动**线路，`@cmcc` 必须带上。
> 其它后缀：`@telecom` 电信、`@unicom` 联通、不带后缀则是学校自有线路。

改完保存（编码保持 UTF-8 即可）。`config.json` 已在 `.gitignore` 中，凭据不会被提交。

### 2. 装开机自启

双击 **`安装-开机自启.bat`** → 按 `1`。

它会创建一个名为 `DrCom_AutoLogin` 的计划任务：

- 触发条件：**你登录 Windows 时**自动启动
- 权限：当前用户、普通权限，**不需要管理员**
- 启动后常驻后台（无黑框窗口），每 20 秒探测一次网络，一断线立刻重登

### 3. 日常使用

| 场景 | 操作 |
| --- | --- |
| 想立刻登录一次 | 双击 `登录一次.bat` |
| 查看是否在线 / 看日志 | 双击 `安装-开机自启.bat` → 按 `3` |
| 排查"登录失败"原因 | 双击 `体检.bat` |
| 不想用了 | 双击 `安装-开机自启.bat` → 按 `2` |

日志在 `drcom.log`，只记录时间和结果，**不会写入密码**。

## 命令行用法

```powershell
# 只看状态（含死代理检查）
powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Status

# 只跑一轮（在线就跳过）
powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Once

# 强制登录一次
powershell -ExecutionPolicy Bypass -File drcom-login.ps1 -Force

# 守护模式（断线重连，Ctrl+C 停止）
powershell -ExecutionPolicy Bypass -File drcom-login.ps1
```

## 原理

### 1. 认证接口

Dr.COM ePortal 首页内写明了认证参数（`authloginport=801`、`authloginpath=/eportal/?c=ACSetting&a=Login`、`authuserfield=DDDDD`）。实测确认：80 端口是旧版页面，`801` 端口是 EPortal 服务，真正的认证接口是：

```
GET http://10.31.0.10:801/eportal/portal/login
    ?callback=dr1003
    &login_method=1
    &user_account=账号@cmcc
    &user_password=密码
    &wlan_user_ip=内网IP
    &wlan_user_ipv6=
    &wlan_user_mac=本机MAC
    &wlan_ac_ip=
    &wlan_ac_name=
    &jsVersion=4.1.3
    &terminal_type=1
    &lang=zh-cn
```

返回 `{"result":1,"msg":"Portal协议认证成功！"}` 即成功；若本来就在线则返回 `已经在线`（脚本也当作成功）。

> `wlan_user_ip` / `wlan_user_mac` 实测**不是关键认证参数**，留空或填错也能认证成功。脚本仍会尽量填对，兼容性更好。

> 网关地址写在 `config.json` 的 `portal.host` 里。不同学校/园区的认证服务器地址若不同，改这里即可。

### 2. 判断是否断网：HTTP 可达 + 正文内容身份校验

**关键教训：不能只看 HTTP 状态码。**

校园网网关在**未认证**时会把很多请求**透明劫持**到认证页，此时 HTTP 状态码**仍然可能是 200**。如果只看状态码，脚本会误判成"在线"，于是**永远不触发登录**——这是开发过程中踩过的最大的坑：掉线 4 分多钟，守护进程一直以为在线，日志里一次登录尝试都没有。

另一个坑：**联网检测专用域名容易被校园网白名单放行**。像 `connect.rom.miui.com/generate_204`、`msftconnecttest.com` 这类地址，认证前也可能返回正常内容。

所以判定在线必须是**"HTTP 可达" + "正文包含约定的特征字符串"**两个条件同时成立。配置里给每个探测地址都写了 `expect`（期望出现的正文内容）：

```json
"onlineProbes": [
    { "url": "http://detectportal.firefox.com/success.txt",      "expect": "success" },
    { "url": "http://www.msftconnecttest.com/connecttest.txt",   "expect": "Microsoft Connect Test" },
    { "url": "http://captive.apple.com/hotspot-detect.html",     "expect": "Success" }
]
```

只要劫持页被返回，正文里就不会有这些特征串，判定立刻变成"离线"，登录随即触发。
**多个探测地址是"任意一个通过即算在线"**，避免单个站点故障导致误判。

> 想加自己的探测地址，照着格式加一条即可；`expect` 填该地址正常时正文里必然出现的字符串。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `config.example.json` | 配置模板（**复制为 `config.json` 并填入账号密码**） |
| `config.json` | 你的实际配置（含凭据，已被 `.gitignore` 排除） |
| `drcom-login.ps1` | 主脚本：探测、登录、守护循环（UTF-8 BOM 编码） |
| `安装-开机自启.bat` | 安装/卸载/查看状态的交互菜单（GBK 编码） |
| `登录一次.bat` | 手动登录一次（GBK 编码） |
| `体检.ps1` / `体检.bat` | 配置体检：快速定位"登录失败"原因 |
| `run-hidden.vbs` | 隐藏窗口启动脚本（计划任务调用它，避免弹黑框） |
| `drcom.log` | 运行日志，UTF-8 编码（自动生成，不入库） |

> **关于编码（改文件时请注意）**
> - 两个 `.bat` 用 **GBK + CRLF** 保存，开头有 `chcp 936`，中文菜单才能正常显示。
>   如果你用 VSCode 之类的编辑器改它们，**要存成 GBK/ANSI，并且保持 CRLF 换行**，存成 UTF-8 会变乱码。
> - `drcom-login.ps1` / `体检.ps1` 用 **UTF-8 带 BOM** 保存（Windows PowerShell 5.1 靠 BOM 识别中文）。
> - `config.json` 用 UTF-8 或 GBK 都行（脚本按 UTF-8 读，纯英文数字内容不受影响）。

## 资源占用

守护进程常驻后台，实测开销：

| 指标 | 数值 | 说明 |
| --- | --- | --- |
| CPU（全程平均） | **约 0.1%** | 实测 12 分钟内累计 CPU 仅增长 0.265 秒 |
| CPU（不含启动开销） | **约 0.05%** | 稳定运行时几乎为零，其余时间在 `Start-Sleep` 中完全不占 CPU |
| CPU（单次探测） | 约 2 ms | 只发一个 GET 请求下载小体积正文做内容校验 |
| 内存（工作集） | 约 67–86 MB | 主要是 Windows PowerShell 5.1 自身的基础开销，不是脚本逻辑 |
| 网络 | 约 0.4 KB / 20 秒 | 每 20 秒一个 GET 探测（正文校验） |
| 磁盘 | 只在状态变化时写一行日志 | 日志超过 `config.json` 的 `maxLogKB`（默认 256 KB）自动裁剪到最近 1000 行，裁剪带互斥锁防并发丢行 |

实测 12 分钟曲线：**工作集从 86.0 MB 降到 68.4 MB**，私有内存在 67.8–72.6 MB 之间小幅波动后趋于平稳，**没有持续增长**（无内存泄漏）。

**关于内存的说明**：早期版本每次探测用 `Invoke-WebRequest`，单次约 373 KB 内存、7.8 ms CPU，长期跑会持续吃内存到上百 MB。现在改用 `HttpWebRequest`（GET 请求 + 下载正文做内容校验），单次约 11 KB、2.1 ms，内存占用稳定。

**想进一步降低内存**：可以把 `config.json` 里的 `checkIntervalSec` 从 `20` 调大到 `60`，探测频率降低到 1/3，代价是断线后恢复要多等最多 40 秒。

## 排查

### 先分清两种"没网"

状态显示"在线"，但你觉得没网时，**先确认是哪种情况**——这是最容易混淆的地方：

| 现象 | 病因 | 处理 |
| --- | --- | --- |
| 脚本显示在线，但**浏览器一律打不开**，命令行 `ping www.baidu.com` 却正常 | **代理软件残留**（最常见） | 见下方"死代理"一节 |
| 脚本显示离线/登录失败，浏览器也打不开 | 真的是校园网掉线了 | 看日志里的失败原因 |
| 脚本显示在线，浏览器偶尔打不开 | 校园网本身抖动 | 等 20 秒看是否自动恢复 |

### 恢复速度与重试节奏

| 场景 | 行为 |
| --- | --- |
| 在线 | 每 20 秒探测一次，探测耗时约 0.8 秒（在线时命中第一个地址就结束） |
| 掉线 | 立刻探测 → 立刻登录，**实测 4 秒左右恢复** |
| 登录连续失败 | 退避 20→40→**60 秒封顶**，之后每分钟重试一次 |
| 探测地址全部超时（离线且网关也不可达） | 单轮最坏 3×4=12 秒（`probeTimeoutSec=4`） |

> **为什么退避封顶是 60 秒**：早期版本封顶 300 秒，意味着退避到顶后网络恢复也要等最多 5 分钟才重连，对频繁闪断的校园网体验很差。60 秒的代价只是持续故障时每分钟发一次登录请求（本地请求，很轻）。

### 死代理问题

现象：**脚本一直显示"在线"，但浏览器全部"无法访问"**。

原因：代理软件（Clash / v2rayN 等）退出后，系统代理设置仍指向 `127.0.0.1:10808` 这类**已经没人监听的端口**。而本脚本用 .NET `HttpWebRequest` 发请求，它**默认直连、不读系统代理**，所以脚本测出来是通的；浏览器读系统代理，就全被送去死端口。

确认方法（PowerShell 里执行）：

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer
```

`ProxyEnable = 1` 且 `ProxyServer` 指向一个没在运行的程序 → 就是这个问题。

处理（任选其一）：

1. **取消系统代理**：设置 → 网络和 Internet → 代理 → 关闭"使用代理服务器"；或 Internet 选项 → 连接 → 局域网设置 → 取消勾选"为 LAN 使用代理服务器"。
2. **重新启动代理软件**，让它重新监听那个端口。
3. 代理软件的 **TUN 模式**退出后可能残留虚拟网卡（比如 `vgate0`、`SSTAP`、`TAP-Windows`）。异常时到"设备管理器 → 网络适配器"里禁用掉。

脚本会在 `-Status` 时**自动检查**这类问题并给出告警。

### 其它常见情况

- **日志显示"登录失败: 无法获取用户认证账号"** → `username` 没填或填空。
- **日志显示"AC认证失败"或"密码错误"** → 账号密码错，或运营商后缀不对；先跑 `体检.bat` 定位。
- **登录返回成功但外网仍不通** → 学校可能限制多设备/绑定 MAC，需要在自助服务里下线旧设备。
- **换了网络环境（比如从宿舍换到教学楼）** → 内网 IP 会变，脚本每次登录前都会重新读取网关页，通常无需干预；若换到完全不同的认证服务器，改 `config.json` 里的 `portal.host` / `portal.port` 即可。
- **想确认任务真的在跑** → 任务管理器里搜 `powershell`，或看 `drcom.log` 是否持续写入（在线时心跳约 30 分钟一行）。

## 已知限制

| 限制 | 说明 | 应对 |
| --- | --- | --- |
| **一个账号只能在一台机器上用** | 若学校限制并发会话，两台机器用同一账号会**互相踢下线、反复抢登录** | 各用各的账号，或只在一台机器开启自动登录 |
| **换网络环境可能要改配置** | 网关地址写在 `config.json` 的 `portal.host` 里；教学楼/宿舍的认证服务器若不同，需改这里 | 日志出现"无法连接到远程服务器"且网关页也打不开时，先确认网关地址 |
| **密码明文存储** | `config.json` 里是明文密码 | 自行注意文件权限；本脚本不上传任何数据 |
| **密码随 GET 请求提交** | ePortal 协议本身是 GET 接口，密码出现在登录 URL 的查询串里（网关侧 access log 可见） | 协议限制无法避免；仅在校内网关链路上，风险有限 |
| **探测地址可能被白名单放行** | 联网检测类域名（部分校园网会放行）单独用不可靠 | 脚本已用**内容校验**（`expect` 字段）规避，并配了 3 个地址互为备份 |
| **日志长时间为空** | 在线时不写日志（只在状态变化、心跳、失败时写） | 已有心跳（约 30 分钟一行）证明进程存活 |

## 备选方案

如果不想用脚本：搜索安装**哆点（Dr.COM）官方客户端**，登录后勾选"记住密码 + 自动登录"，效果类似（但会常驻一个官方客户端）。

## 免责声明

本项目仅用于**对你自己拥有使用权的网络环境**做认证自动化，请遵守所在学校/单位的规定与账号协议。使用本项目产生的任何后果由使用者自行承担。

## License

[MIT](LICENSE)
