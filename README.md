# trae-auto-checkin

> **English**: A lightweight, zero-dependency PowerShell tool for Windows that performs the daily Trae CN check-in. **It never reads the Trae client's login state** — you paste your own token into a local config file, and the script only reads that file. It waits for the network to come back instead of giving up, runs once per Beijing calendar day, triggers at logon and 00:05, writes a local masked log, and shows a local notification when the token expires or a check-in fails. No EXE, no obfuscation, no third-party notification service, MIT licensed. Use only with your own single account; automating platform activities may violate the platform rules.

一个面向 Windows 的 Trae CN 每日签到小工具。纯 PowerShell，不打包 exe、不加壳、不混淆、无第三方运行时依赖。

**它不读你的凭据。** 不读取 Trae 客户端的 `storage.json`，不解密任何登录态文件，不回写客户端存储。你把自己的令牌粘贴到本工具自己的 `config.json`，脚本只读这个文件。

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
- 没网时持续等待，网络恢复后当天补签，而不是重试几次就放弃
- 当天已成功签到后，后续触发直接跳过，不再请求接口
- 本地日志记录时间、结果和失败原因；失败或令牌过期时本地弹窗/Toast，不静默失败
- 日志与通知里对令牌自动打码

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
cd trae-auto-checkin
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

- 成功签到后写 `state.json` 的 `lastSuccessDay`，按**北京时间自然日**计算
- 后续任何触发发现「当天已完成」就直接退出，**不再调用接口**
- 日期跨过 0 点后，00:05 的触发会正常再签一次
- 互斥量防止两个触发同时运行

断网处理：单次触发内按 `RetryIntervalSeconds` 反复检测 `api.trae.cn:443`，直到 `WaitForNetworkMinutes` 用完；仍未恢复则退出码 2 并弹窗一次，后续计划任务触发继续补签。

## 9. 配置项

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `AuthToken` | 空 | **必填**。手工粘贴的 `Cloud-IDE-JWT` 令牌 |
| `DeviceId` | 空 | 留空即可，脚本会在 `state.json` 生成一个随机 UUID 并复用 |
| `ApiHost` | `api.trae.cn` | 接口域名，一般不用改 |
| `CheckinTime` | `00:05` | 每日触发时间（重新运行 `install.ps1` 生效） |
| `WaitForNetworkMinutes` | 30 | 单次触发等待网络的最长分钟数 |
| `RetryIntervalSeconds` | 30 | 等待网络时的重试间隔（最小 5） |
| `RequestTimeoutSeconds` | 20 | 单次接口超时 |
| `NotifyOnFailure` | true | 失败/令牌过期是否本地弹窗 |
| `ReqSource` | 1 | 请求体里的 `req_source`，一般不用改 |

修改签到时间：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckinTime "00:30"
```

环境变量 `TRAE_CHECKIN_TOKEN` 优先级高于 `config.json`，适合不想把令牌写盘的人（但计划任务以登录用户身份运行，需为该用户设置环境变量）。

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

默认删除计划任务和安装目录（含日志、`state.json`、`config.json`，即令牌一并删除）。

- 只删任务、保留文件排查：`-KeepFiles`
- 目录含 `.git`（源码仓库）时会拒绝删除，避免误删源码
- 也可指定目录：`-InstallDir "D:\Tools\TraeCheckin"`

## 12. 被杀软拦截怎么办

本工具是明文 PowerShell，不下载代码、不修改系统设置，但「计划任务 + 访问网络 + 读写自身配置」仍可能被启发式引擎误报。正确做法：

1. **不要关闭杀毒软件**，不要给整个系统目录加白。
2. 只把 `%LOCALAPPDATA%\TraeCheckin` 加入排除项（Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 排除项 → 添加文件夹）。
3. 文件被隔离时，先从隔离区恢复，再加目录排除，然后重新运行 `install.ps1`。
4. 确认是误报可提交微软：<https://www.microsoft.com/en-us/wdsi/filesubmission>（选择「误报」，上传 `checkin.ps1`，说明用途与只访问 `api.trae.cn`）。
5. 其他杀软请走其官方「误报/例外」入口，不要使用破解版或来源不明的「白名单工具」。

## 13. 风险与合规

- 这是对平台活动的**自动化**操作。平台用户协议可能不鼓励或禁止自动化领取奖励，账号被风控、积分被回收等后果由使用者自行承担。
- 本项目只做「查询状态 + 领取签到」，不绕过验证码、不伪造设备、不多账号刷取、不修改客户端。
- 接口可能随客户端升级变化；工具会明确报错，不会静默失败。
- 令牌明文保存在本机 `config.json`。请确认该文件权限仅限本人，不要把令牌提交进任何仓库（本仓库 `.gitignore` 已排除 `config.json`）。
- 请保持克制：成功当天即停止请求接口，不要改成高频轮询。

## 14. 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 日志/弹窗提示「尚未配置令牌」 | 编辑 `config.json` 的 `AuthToken` |
| 提示「令牌失效」（HTTP 401/403 或 `code=1001`） | 按第 6 节重新抄一次令牌 |
| HTTP 403 | 令牌无权限或账号状态异常，重新登录客户端后再取令牌 |
| 一直提示没有网络 | 只测试 `api.trae.cn:443`；公司代理/防火墙需放行 |
| 计划任务没跑 | 任务计划程序查看 `TraeCheckin` 的「上次运行结果」，确认用户已登录 |
| 签到失败但状态查询正常 | 看日志里的 HTTP 状态与 `code`；可能账号被风控或活动未开放 |

## 15. License

[MIT](LICENSE)
