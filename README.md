# Trae CN Auto Check-in (Windows & macOS)

### 不想输命令？把这段话复制给 AI

> **复制 [INSTALL-WITH-TRAE.md](INSTALL-WITH-TRAE.md) 里的整段文字，发给你的 TRAE（或任何能执行命令的 AI 助手），它会自己完成下载、安装、注册开机与 00:05 触发、自检，并把结果回报给你。整段文本不包含任何真实令牌，只要求你在本机终端里自己粘贴一次。**

三步搞定：

1. 打开 [INSTALL-WITH-TRAE.md](INSTALL-WITH-TRAE.md)
2. 按你的系统（Windows / macOS）把对应那一段**整段复制**
3. 直接粘给你的 AI 助手，剩下的交给它

装完你会看到：计划任务 `TraeCheckin`（macOS 是 LaunchAgent `cn.trae.checkin`）、程序在 `%LOCALAPPDATA%\TraeCheckin`（macOS 在 `~/.local/share/trae-checkin`），AI 会跑一次状态自检，并把「装在哪、任务是否建成功、自检结果」报给你。

> **你不需要会命令行，不需要装任何东西，也不用把令牌发给任何人或任何 AI。** 令牌只在最后一步由你自己在终端里粘贴一次，加密后只存在你的电脑上。

---

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows | macOS](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey)
![Language: PowerShell](https://img.shields.io/badge/language-PowerShell-5391FE)

## 给技术用户的说明

Trae CN（Trae 中国版）**每天一次的自动签到**工具：Windows 用 PowerShell + 计划任务，macOS 用 bash + launchd，到点自动点一次客户端里的「签到」领积分（check-in / sign-in / points）。零依赖、不打包 exe、不加壳、不混淆。

**它不读你的凭据。** 不读取 Trae 客户端的 `storage.json`，不解密任何登录态文件，不回写客户端存储。你把自己的 `Cloud-IDE-JWT` 令牌粘贴到本工具自己的配置里，脚本只读这个文件；Windows 上可用 DPAPI 加密，macOS 上可放系统钥匙串。

Windows 版已实测（14 项自检），macOS 版代码已提供但**未在 Mac 真机实测**，见 [macos/README.md](macos/README.md)。

> **English**: A zero-dependency Trae CN daily check-in (sign-in / points) tool for Windows and macOS. On Windows it runs as a PowerShell scheduled task; on macOS as a bash + launchd LaunchAgent. It never reads the Trae client's login state — you paste your own token once, and it stays on your machine (Windows DPAPI or macOS Keychain). No EXE, no obfuscation, no third-party notification service, MIT licensed. Use only with your own single account; automating platform activities may violate the platform rules.

## 1. 设计取舍：为什么选「手工粘贴令牌」

需求里给了两个方案，这里说明为什么落地 A、以及为什么不是「粘贴 Cookie」：

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| **A（本项目采用）** | 用户手工把令牌粘贴到本地 `config.json`，脚本只读该文件，不回写、不上传，日志打码 | 行为完全可见：用户清楚自己提供了什么；出问题删掉 `config.json` 即可；不需要触碰客户端任何文件 |
| B | 脚本操作已登录的浏览器，只点按钮 | 不可行：签到入口只在桌面客户端内，网页端和手机端都没有签到按钮，没有可点的页面 |
| Cookie | 复制浏览器 Cookie | 不成立：该接口鉴权头是 `Authorization: Cloud-IDE-JWT <token>`，与 Cookie 无关，粘 Cookie 必然 401 |

所以：**A 是唯一既简单又透明、还能真正跑通的方式**。代价是令牌会过期，过期后需要重新粘贴一次；脚本会弹窗提醒。

## 2. 它做什么

- 开机/登录后自动签到，每天只成功签到一次
- 每天 00:05 自动再签一次（跨 0 点不依赖下一次开机）
- 没网时持续等待（睡眠轮询，不烧 CPU），网络恢复后当天补签
- 当天已成功签到后，后续触发直接跳过，不再请求接口
- 互斥量 + 文件锁双重保护：两个触发同时命中时，只有一个实例会调用接口
- 状态原子写入；本机日期异常时用接口响应头 `Date` 判断跨天
- 本地日志记录时间、结果和失败原因，超过 2MB 自动轮转为 `.1`；失败或令牌过期时本地弹窗/Toast，不静默失败
- 日志与通知里对令牌自动打码；令牌可用 Windows DPAPI 加密保存
- 网络失败会给出可操作提示（是否该配代理），请求超时与重试都有上限

## 3. 签到入口与接口（已核实）

- 入口：只存在于 **Trae CN / TRAE SOLO CN 桌面客户端**，头像菜单里的「签到」。网页版和手机端没有入口。
- 官方说明：<https://docs.trae.cn/ide_plans-and-billing>
- 接口：

  | 用途 | 方法与路径 |
  | --- | --- |
  | 查询状态 | `POST https://api.trae.cn/trae/api/v2/ug/checkin_credits/status` |
  | 领取积分 | `POST https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim` |

- 请求头：`Authorization: Cloud-IDE-JWT <token>`、`x-device-id`、`Content-Type: application/json`、`Origin/Referer: https://www.trae.cn/`
- 请求体：`{"req_source":1}`
- 该接口是幂等的：当天已签到再次调用 claim 仍返回 `code=0`。

## 4. 安全边界（重点）

- **不读取** Trae 客户端的 `storage.json`、`Local State` 或任何登录态文件
- **不解密** 客户端凭据信封，不涉及任何加密算法逆向
- **不回写** 客户端存储，不会把客户端登录搞掉
- 只读本工具目录下的 `config.json` / `state.json`
- 只访问 `api.trae.cn`，不向任何第三方发送数据
- 令牌只在内存中使用：写入日志前自动替换为 `***`，弹窗内容同样打码
- 只支持单账号自用；不处理多账号、不伪造设备、不绕过验证码

## 5. 前置条件

- Windows 10/11，Windows PowerShell 5.1（系统自带）
- 已安装并登录 Trae CN 或 TRAE SOLO CN 桌面端（仅用于获取令牌，运行签到不需要客户端开着）
- 不需要管理员权限；不需要 Node.js / Python

## 6. 获取令牌

令牌是一个 `Cloud-IDE-JWT` 串，从桌面客户端的网络请求里抄一次即可：

1. 打开 Trae CN 桌面客户端，确保已登录
2. 打开开发者工具（菜单「帮助 → 切换开发者工具」，或 `Ctrl+Shift+I`）
3. 切到 **Network** 面板，在客户端头像菜单点一次「签到」
4. 找到请求 `checkin_credits/status`（或 `claim`）
5. 在 Request Headers 里找 `Authorization: Cloud-IDE-JWT eyJ...`，复制 `eyJ...` 这一段（不含前缀）
6. 粘贴到 `config.json` 的 `AuthToken` 字段，保存

> 令牌等同账号凭据，**不要**贴到聊天、文档、截图或任何仓库。它只应保存在本机 `config.json`。

令牌会过期（通常几天到几周）。过期后脚本会弹窗提示「令牌失效」，重新按上面步骤抄一次即可。

## 7. 安装

```powershell
# 下载或克隆本仓库后，进入仓库目录
cd trae-auto-checkin-windows-macos
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安装脚本会：

1. 复制程序到 `%LOCALAPPDATA%\TraeCheckin`
2. 用 `config.example.json` 初始化 `config.json`
3. 注册当前用户的计划任务 `TraeCheckin`
4. 若尚未填写 `AuthToken`，会提示你先编辑配置，而不是拿空令牌去请求

配置好令牌后验证：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -Mode Status
```

查看日志：

```powershell
Get-Content "$env:LOCALAPPDATA\TraeCheckin\logs\checkin.log" -Tail 20
```

## 8. 调度与幂等

计划任务有两个触发器：

- **开机/登录后 1 分钟**（之后每 30 分钟重试一次，持续 24 小时，用于断网补签）
- **每天 00:05**（之后每小时重试一次，持续 24 小时，用于跨 0 点再签和断网补签）

`StartWhenAvailable=true`：休眠或关机错过 00:05，唤醒/开机后会补跑。

脚本内去重：

- 成功签到后写 `state.json` 的 `lastSuccessDay`，按**北京时间（UTC+8）自然日**计算，与系统本地时区无关
- 后续任何触发发现「当天已完成」就直接退出，**不再调用接口**
- 跨天判断优先用接口响应头里的服务器 `Date`；若本机时间与本机时区被改，以服务器日期为准并在日志中告警
- 日期跨过 0 点后，00:05 的触发会正常再签一次
- 本地记录的上次成功日期晚于今天（系统时间被回拨）时不会误跳过，仍按接口实际状态处理
- 互斥量（同会话）+ `checkin.lock` 文件锁（跨进程/跨会话）双重保护，第二个实例直接退出
- `state.json` 通过临时文件 + 原子替换写入，避免写一半损坏

断网处理：单次触发内按 `RetryIntervalSeconds` 用 `Start-Sleep` 睡眠轮询（不空转 CPU），直到 `WaitForNetworkMinutes` 用完；仍未恢复则退出码 2 并弹窗一次，后续计划任务触发继续补签。单次请求另有超时和最多 2 次尝试（仅对超时/5xx 重试）。

代理：默认直连；若系统需要代理，在 `config.json` 填 `ProxyUrl`（如 `http://127.0.0.1:10808`），或设置 `HTTPS_PROXY` 环境变量。脚本会检测代理端口连通性；PowerShell 5.1 不支持 SOCKS，请使用代理软件的 HTTP 混合端口。

## 9. 配置项

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `AuthToken` | 空 | 手工粘贴的 `Cloud-IDE-JWT` 令牌（明文；推荐改用 `AuthTokenProtected`） |
| `AuthTokenProtected` | 空 | 用 `-SetToken` / `-ProtectToken` 写入的 DPAPI 密文；与 `AuthToken` 二选一 |
| `DeviceId` | 空 | 留空即可，脚本会在 `state.json` 生成一个随机 UUID 并复用 |
| `ApiHost` | `api.trae.cn` | 接口域名，一般不用改 |
| `ProxyUrl` | 空 | HTTP 代理地址；留空时读取 `HTTPS_PROXY` / `HTTP_PROXY` |
| `CheckinTime` | `00:05` | 每日触发时间（重新运行 `install.ps1` 生效） |
| `WaitForNetworkMinutes` | 30 | 单次触发等待网络的最长分钟数（0..1440） |
| `RetryIntervalSeconds` | 30 | 等待网络时的重试间隔（5..600） |
| `RequestTimeoutSeconds` | 20 | 单次接口超时（5..120） |
| `NotifyOnFailure` | true | 失败/令牌过期是否本地弹窗 |
| `ReqSource` | 1 | 请求体里的 `req_source`，一般不用改 |

修改签到时间：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckinTime "00:30"
```

### 令牌怎么存更安全

推荐用 DPAPI（Windows 数据保护接口，当前用户范围）加密，而不是明文：

```powershell
# 交互式粘贴令牌（不回显），加密后写入 config.json，明文 AuthToken 会被清空
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -SetToken

# 如果之前已经手工把明文写进了 AuthToken，可原地加密
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -ProtectToken
```

DPAPI 密文只能被保存它的同一个 Windows 用户解密；换用户或换机器会解不开（脚本会报退出码 4 并提示重新保存）。卸载时密文随 `config.json` 一起删除。

环境变量 `TRAE_CHECKIN_TOKEN` 优先级最高，适合不想把令牌写盘的人（但计划任务以登录用户身份运行，需为该用户设置环境变量）。

> 关于 `DeviceId`：本工具不读客户端设备 ID，只在本机生成随机 UUID。若某些账号被平台绑定设备，签到可能失败，日志会给出具体 HTTP/code，便于判断。

## 10. 手动验证

```powershell
# 只查状态，不领取
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -Mode Status

# 忽略「当天已完成」标记，强制走完整流程
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -Force

# 演练：只查状态，不领取
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -DryRun
```

退出码：`0` 成功/已签到/未启用，`1` 签到请求失败，`2` 等待网络超时，`3` 未配置令牌或令牌失效，`4` 配置或本地环境错误。

## 11. 卸载

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\uninstall.ps1"
```

默认删除计划任务和安装目录（含日志、`state.json`、`config.json`，即令牌与 DPAPI 密文一并删除）。

- 只删任务、保留文件排查：`-KeepFiles`
- 目录含 `.git`（源码仓库）时会拒绝删除，避免误删源码
- 也可指定目录：`-InstallDir "D:\Tools\TraeCheckin"`

说明：DPAPI 密文存在 `config.json` 里，删掉该文件后密文即失效。DPAPI 的“用户级主密钥”由 Windows 为用户统一管理（`%APPDATA%\Microsoft\Protect`），无法只删本工具那一条，也不建议删除（会影响其他程序）。如果曾把 `TRAE_CHECKIN_TOKEN` 永久写进用户环境变量，卸载脚本会提示你删除的那一行命令。

一条命令退出：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\uninstall.ps1"
```

## 12. 被杀软拦截怎么办

本工具是明文 PowerShell，不下载代码、不修改系统设置，但「计划任务 + 访问网络 + 读写自身配置」仍可能被启发式引擎误报。正确做法：

1. **不要关闭杀毒软件**，不要给整个系统目录加白。
2. 只把 `%LOCALAPPDATA%\TraeCheckin` 加入排除项（Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 排除项 → 添加文件夹）。
3. 文件被隔离时，先从隔离区恢复，再加目录排除，然后重新运行 `install.ps1`。
4. 确认是误报可提交微软：<https://www.microsoft.com/en-us/wdsi/filesubmission>（选择「误报」，上传 `checkin.ps1`，说明用途与只访问 `api.trae.cn`）。
5. 其他杀软请走其官方「误报/例外」入口，不要使用破解版或来源不明的「白名单工具」。

## 13. 风险与合规

**一句话**：这只是把你每天手动点一次的「签到」按钮改成自动点一次，与人工操作等价；它不会给你带来超出人工点击的收益，也不做任何规避检测的处理。

**它是什么**

- **每天一次的自动点击**：同一北京自然日只成功调用一次领取接口，成功后当天不再发请求
- **等价于人工操作**：走的是客户端头像菜单里「签到」同一个接口，请求头/请求体与人工点击一致，不额外伪造字段
- **单账号自用**：只服务你本人一个账号

**它明确不做什么（也请不要改成那样）**

| 禁止行为 | 本工具的约束 |
| --- | --- |
| 多账号批量刷取 | 不提供账号池、不做账号轮换、配置只支持一个 `AuthToken` |
| 绕过限流 | 不并发轰炸、不缩短频率；失败按 `RetryIntervalSeconds` 睡眠重试，单次触发最多 2 次尝试，成功后当天停止 |
| 修改设备指纹 | 不伪造 `x-device-id`、不改 UA；`DeviceId` 只是本机随机 UUID |
| 规避检测 | 不搞代理池轮换、不模拟点击轨迹、不绕验证码；不读取/解密客户端登录态 |

**凭据只留在本机**

- 令牌写在 `config.json`（推荐用 `-SetToken` 存成 DPAPI 密文 `AuthTokenProtected`），不上传、不发任何第三方
- 日志与弹窗对令牌自动打码，绝不写入日志文件
- `config.json` 安装时自动收紧为「仅当前用户」权限；`.gitignore` 已排除它
- 不要把令牌贴到聊天、issue、截图或任何仓库

**风险提示**

> 自动签到**可能违反平台活动规则**，账号被风控、积分被回收、活动资格取消等后果由**使用者自行承担**。接口可能随客户端升级变化，本工具不做对抗性适配，只会明确报错，不会静默失败。
> 如果你的账号或所在地区的规则不允许自动化，请不要使用。

**随时退出（一条命令）**

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\uninstall.ps1"
```

会删除计划任务、安装目录、配置（含令牌与 DPAPI 密文）、状态与日志。

## 14. 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 提示「尚未配置令牌」 | 运行 `checkin.ps1 -SetToken` 加密写入，或编辑 `config.json` 的 `AuthToken` |
| 提示「令牌失效」（HTTP 401/403 或 `code=1001`） | 按第 6 节重新抄一次令牌，再用 `-SetToken` 保存 |
| 退出码 4，提示 DPAPI 解密失败 | 密文是别的用户/别的机器生成的，重新 `-SetToken` 保存一次 |
| 一直提示没有网络 | 只测试 `ApiHost:443`；公司代理/防火墙需放行，或填 `ProxyUrl` |
| 提示「疑似代理未配置」 | 系统里设了代理但脚本没拿到，填 `config.json` 的 `ProxyUrl`（HTTP 端口，PS 5.1 不支持 SOCKS） |
| 计划任务没跑 | 任务计划程序查看 `TraeCheckin` 的「上次运行结果」，确认用户已登录、未禁用 |
| 提示「本机时间早于上次签到日期」 | 系统时间被回拨，脚本不会误跳过，按服务器日期重新判断，日志里有告警 |
| 签到失败但状态查询正常 | 看日志里的 HTTP 状态与 `code`；可能账号被风控或活动未开放 |
| 弹窗没出来 | 日志里会有 `WARN ... 通知失败`，不影响签到结果；可改用 `-NoNotify` 静默 |

## 15. macOS（未实测）

Trae 官方文档确认有 macOS 客户端（macOS 12.0+，Apple Silicon 与 Intel 均支持）：

- 入门与系统要求：<https://docs.trae.cn/ide_get-started-with-trae>
- 套餐/积分与「签到」入口：<https://docs.trae.cn/ide_plans-and-billing>

官方文档没有区分 Windows 与 macOS 的签到入口和鉴权方式，签到同样在客户端头像菜单里，接口鉴权也是 `Authorization: Cloud-IDE-JWT <token>`。**但本机只有 Windows，macOS 那套脚本完全没有实测**，请按 [macos/README.md](macos/README.md) 里的「Mac 上待验证」清单自行验证。

- 调度：launchd LaunchAgent（登录时 + 每天 00:05）
- 实现：`macos/checkin.sh`（bash + curl），配置放 `~/.config/trae-checkin/config.env`，权限 `600`
- 安装：`bash macos/install.sh`；卸载：`bash macos/uninstall.sh`

## 16. 已验证内容（Windows）

自测环境：Windows + PowerShell 5.1，接口用本机 HTTPS mock（自签名证书，仅测试进程内跳过校验），真实接口仅用于错误令牌用例。14/14 通过：

| 编号 | 场景 | 结果 |
| --- | --- | --- |
| T1 | 正常签到（status→claim） | 退出码 0，`state.json` 写入当天日期与积分 |
| T2 | 当天重复触发 | 退出码 0，接口新增请求数 0 |
| T3 | 两个实例并发（开机 + 零点同时命中） | 只有一个实例调用接口，接口总请求 3 次（status/claim/复查） |
| T4 | 断网等待 | 退出码 2，等待 66s，进程 CPU 累计 0.73s（睡眠轮询不烧 CPU） |
| T5 | 真实接口 + 错误令牌 | 退出码 3，日志无令牌泄漏 |
| T6a | 系统时间回拨 | 不误跳过，日志告警后正常 claim |
| T6b | 服务器日期比本机快 1 天 | 按服务器日期落状态并告警 |
| T7a | `-SetToken`（DPAPI） | 密文 372 字符写入，明文 `AuthToken` 清空 |
| T7b | 用密文正常签到 | 退出码 0 |
| T7c | 密文被篡改 | 退出码 4，提示重新保存 |
| T8 | 日志超过 2MB | 轮转为 `checkin.log.1`，新日志重建 |
| T9a | `install.ps1` 安装 | 计划任务注册成功，配置初始化成功 |
| T9b | 未配置令牌运行 | 退出码 3，不发无效请求 |
| T9c | `uninstall.ps1` 卸载 | 任务、目录、锁文件、状态全部清除 |

未覆盖：真实成功签到（需要有效令牌，未在测试中使用真实账号令牌）；通知弹窗失败路径（仅代码审查，用 `WARN` 日志兜底）。

## 17. Related / Alternatives

同类工具（与本项目无关联，仅便于对比；功能范围与合规性请自行核实）：

| 项目 / 关键词 | 说明 |
| --- | --- |
| **TraeWorkAssistant** | 社区里功能更全的 Trae 辅助工具（含签到相关能力），在 GitHub 搜索 `TraeWorkAssistant` |
| GitHub 搜索 `trae checkin` | 可见若干 PowerShell / Python 实现，多数只覆盖 Windows |
| 通用做法 | Windows「计划任务 + PowerShell」、macOS「launchd + curl」；本项目就是这套组合的完整实现 |

本项目的定位差异：只做「每天一次的签到」，不读客户端凭据、不做多账号、不做代理池、不绕过限流；Windows 与 macOS 两套实现放在同一个仓库，配置项与退出码保持一致。

## 18. License

[MIT](LICENSE)
