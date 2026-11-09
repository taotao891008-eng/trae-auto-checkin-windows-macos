# macOS 版（**未实测**）

> ⚠️ **重要：本目录下的脚本作者没有 Mac 真机，完全没有实测过。** 它们通过了 `bash -n` 语法检查和 plist XML 校验，但没有在 macOS 上跑过一次真实的 `launchctl bootstrap` 和签到请求。
> Windows 部分（仓库根目录的 `install.ps1` / `checkin.ps1`）已实测 14 项。请把这里的代码当成「可审查的初稿」，按下面的清单在 Mac 上逐条验证后再长期使用。

## 1. 官方信息（已核实）

| 项目 | 结论 | 来源 |
| --- | --- | --- |
| 是否有 macOS 客户端 | 有，要求 macOS 12.0+，支持 Apple Silicon 与 Intel | <https://docs.trae.cn/ide_get-started-with-trae> |
| 签到入口 | 客户端头像菜单里的「签到」 | <https://docs.trae.cn/ide_plans-and-billing> |
| 鉴权方式是否与 Windows 一致 | 官方文档未区分平台；接口同样是 `Authorization: Cloud-IDE-JWT <token>` | 官方文档未明说，**未抓包确认** |

也就是说：**入口位置与鉴权方式「应该」一致，但没有在 Mac 上抓包验证过**。如果 Mac 版的请求头或接口路径不同，`status` 会返回 401/403 或非 0 的 `code`，日志会写清楚，不会静默失败。

## 2. 文件清单

| 文件 | 作用 |
| --- | --- |
| `checkin.sh` | 主脚本（bash + curl），签到、去重、等待网络、日志打码、通知 |
| `config.example.env` | 配置模板 |
| `cn.trae.checkin.plist` | LaunchAgent 模板，安装时替换路径占位符 |
| `install.sh` | 安装：拷程序、建配置（600）、生成并加载 LaunchAgent |
| `uninstall.sh` | 卸载：卸任务、删 plist、删程序目录、可选保留配置、删钥匙串项 |

安装后的位置：

```text
~/Library/LaunchAgents/cn.trae.checkin.plist     # 调度
~/.local/share/trae-checkin/checkin.sh           # 程序（700）
~/.config/trae-checkin/config.env                # 配置（600）
~/.config/trae-checkin/state.env                 # 当天状态（600）
~/.config/trae-checkin/logs/checkin.log          # 日志（600，超 2MB 轮转）
```

## 3. 安装

```bash
cd trae-auto-checkin-windows-macos
bash macos/install.sh                 # 只安装，稍后自己配令牌
bash macos/install.sh --set-token     # 安装后交互式粘贴令牌（不回显）
bash macos/install.sh --use-keychain  # 令牌存系统钥匙串，配置文件不落明文
```

`--use-keychain` 使用 `security add-generic-password`（服务名 `trae-checkin-token`），并把配置里的 `AUTH_TOKEN` 清空、`USE_KEYCHAIN` 置 1。

令牌优先级：环境变量 `TRAE_CHECKIN_TOKEN` > 钥匙串 > `config.env` 明文。

## 4. 调度

LaunchAgent `cn.trae.checkin`：

- `RunAtLoad`：登录/加载时跑一次
- `StartCalendarInterval` 每天 `00:05` 跑一次
- `StartWhenAvailable` 等价行为由 launchd 自带：Mac 在 00:05 睡眠时，唤醒后会补跑
- `ThrottleInterval` 120 秒，避免异常时疯狂重启

## 5. Mac 上待验证清单（请按顺序做，并把结果留档）

1. **入口**：打开 Trae for Mac，头像菜单里是否有「签到」。没有就说明 Mac 版入口不同，先别继续。
2. **抓一次真实请求**：开发者工具（Electron 客户端一般是菜单「帮助 → 切换开发者工具」或 `Cmd+Option+I`）→ Network → 点一次签到 → 确认请求路径是 `/trae/api/v2/ug/checkin_credits/status`、请求头是 `Authorization: Cloud-IDE-JWT ...`。**不要**把令牌复制进任何聊天或 issue。
3. **安装**：`bash macos/install.sh` 是否成功；`~/Library/LaunchAgents/cn.trae.checkin.plist` 是否生成，`plutil -lint` 是否 OK。
4. **加载**：`launchctl print gui/$(id -u)/cn.trae.checkin | head -30` 是否有输出、`state` 是否为 `running`/已注册，两个触发时间是否符合预期。
5. **只读自检**：`~/.local/share/trae-checkin/checkin.sh status` 的退出码是 0 还是 3（未配令牌时为 3，配好后应为 0）。
6. **真实签到一次**：删掉 `~/.config/trae-checkin/state.env` 后运行 `checkin.sh`，看客户端积分是否 +1，日志是否写「签到成功」。
7. **去重**：紧接着再跑一次，应输出「当天已完成」且接口无新请求。
8. **睡眠唤醒**：把 Mac 在 00:05 前合盖睡眠，第二天唤醒后看日志是否有一次补跑。
9. **时区**：把系统时区改成非中国时区，确认：① 日志里的日期仍按 UTC+8 判断（脚本内部固定 `TZ=Asia/Shanghai`）；② 触发器是「本机本地 00:05」，系统时区不是北京时会偏离北京时间（这是当前设计，没有额外补偿）。
10. **代理**：如需代理，在 `config.env` 填 `PROXY_URL="http://127.0.0.1:10808"`，确认 `nc -z` 能通、curl 能走代理。
11. **通知**：断网或令牌失效时，是否弹出系统通知；失败时日志是否有 `WARN 通知发送失败`。
12. **卸载**：`bash macos/uninstall.sh` 后，plist、程序目录、配置目录是否都没了（用 `--keep-config` 时配置应保留）。

任何一项不符合，请把「哪一步 + 报错原文 + 日志最后 10 行」反馈到 issue，不要直接改脚本上线。

## 6. 与 Windows 版的差异

| 能力 | Windows | macOS |
| --- | --- | --- |
| 令牌加密 | Windows DPAPI（当前用户） | 系统钥匙串（`security`）或 600 权限文件 |
| 并发锁 | 互斥量 + `checkin.lock` | `mkdir` 原子锁 + PID 失效检测 |
| 网络等待 | `Start-Sleep` 轮询 | `sleep` 轮询 |
| 服务器日期兜底 | 响应头 `Date` | 响应头 `Date`（`date -j -f` 解析） |
| 日志轮转 | 2MB → `.1` | 2MB → `.1` |
| 通知 | Toast，失败回退 WScript.Popup | `osascript display notification` |

## 7. 已知限制

- **未实测**：如上，所有 launchd / curl / 通知行为都需要你在 Mac 上确认。
- `curl --retry` 对 POST 的重试可能重复提交领取请求；接口是幂等的（当天重复 claim 仍返回 `code=0`），但如果 Mac 上实测发现重复扣减或报错，请去掉 `--retry`。
- 没有实现 DPAPI 那种「绑定用户+机器」的本地加密，钥匙串方案依赖登录用户的 keychain 解锁状态（锁屏但仍登录时可读）。
- 首次运行可能被 Gatekeeper/quarantine 拦一下：脚本是纯文本，没有签名，`bash macos/install.sh` 一般可直接运行；若提示「无法验证开发者」，用「系统设置 → 隐私与安全性 → 仍要打开」，不要全局关闭 Gatekeeper。

## 8. 卸载

```bash
bash macos/uninstall.sh                # 任务 + plist + 程序 + 配置 + 钥匙串项
bash macos/uninstall.sh --keep-config  # 保留 ~/.config/trae-checkin
```
