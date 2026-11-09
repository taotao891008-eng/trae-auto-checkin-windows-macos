# 把安装直接交给你的 TRAE

不想自己敲命令？复制下面**整段文字**，发给你正在用的 TRAE（或任何能执行命令的 AI 助手）。它会自己下载、安装、注册开机与 00:05 触发、跑自检，最后把结果回报给你。

- 你只需要做一件事：在**你自己的终端**里粘贴一次令牌。令牌**不要**发进对话。
- 下面两段文本都**不含任何真实令牌**，只写了「Cloud-IDE-JWT」这个名称。

---

## Windows（复制这一段）

```text
你好，请帮我在 Windows 上安装并配置一个「Trae 每日签到」小工具。你负责执行命令和检查结果，我负责在本机自己粘贴令牌。

背景（不用我再解释）：
- 仓库地址：https://github.com/taotao891008-eng/trae-auto-checkin
- 它是纯 PowerShell 的 Windows 工具，每天自动点一次 Trae 桌面客户端里的「签到」，和人工点一次等价。
- 安全边界：它不读取 Trae 客户端的任何文件（不碰 storage.json、不解密登录态），只读自己安装目录下的 config.json；令牌只留在本机，日志自动打码，不上传任何数据。

请按顺序做这几件事：

1) 下载
   把仓库克隆到临时目录，例如：
   git clone https://github.com/taotao891008-eng/trae-auto-checkin.git "%TEMP%\trae-auto-checkin"
   如果本机没有 git，就用浏览器下载 ZIP 解压到同一位置。

2) 安装
   在仓库目录里执行：
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   目标：程序装到 %LOCALAPPDATA%\TraeCheckin，并注册当前用户的计划任务「TraeCheckin」。

3) 确认触发时间
   任务应有两个触发器：
   - 登录后 1 分钟（之后每 30 分钟重试，持续 24 小时，用于断网补签）
   - 每天 00:05（北京时间，之后每小时重试，持续 24 小时）
   并且允许「错过计划时间后尽快启动」。用下面的命令自查：
   schtasks /query /tn TraeCheckin /v /fo LIST

4) 令牌（这一步必须由我本人操作，你不要经手令牌）
   安装完先停下，告诉我在我自己的终端窗口里运行：
   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -SetToken
   然后由我粘贴我的 Cloud-IDE-JWT 令牌（输入不回显，回车后会用 Windows DPAPI 加密写入本机 config.json）。
   请注意：
   - 你需要向我索取的是「Cloud-IDE-JWT」令牌，但绝对不能让我把令牌发到对话里，也不要把它写进任何命令、日志或其他地方。
   - 令牌只应存在我本机的配置文件里，不要贴进聊天记录、截图或仓库。
   - 如果我没有令牌，请告诉我怎么在 Trae 客户端里抄一次：帮助 → 切换开发者工具 → Network 面板 → 点一次「签到」→ 在请求头 Authorization 里复制 Cloud-IDE-JWT 后面那段。

5) 验证成功
   a. 运行：
      powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\checkin.ps1" -Mode Status
      退出码 0 = 成功/今日已签到/未启用；2 = 等网络超时；3 = 令牌没配好或已失效；4 = 配置或环境错误。
   b. 查看日志最后 10 行：
      Get-Content "$env:LOCALAPPDATA\TraeCheckin\logs\checkin.log" -Tail 10
      确认没有报错，且日志里没有出现令牌明文。
   c. 再运行一次同样的 Status，确认当天不会重复请求（应直接跳过）。

6) 失败了怎么回报
   不要反复重试，最多再试 1 次。然后把这三样发给我：
   - 完整报错原文
   - 退出码
   - 日志最后 10 行
   并说明你的判断（例如：网络/代理问题、令牌失效、权限问题）。不要关闭杀毒软件，也不要改脚本源码去「绕过」错误。
   如果本机需要代理，请提醒我在 config.json 里填 ProxyUrl（例如 http://127.0.0.1:10808）。

7) 卸载方式（以后随时可用）
   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TraeCheckin\uninstall.ps1"
   它会删除计划任务、安装目录、配置（含令牌与 DPAPI 密文）、状态和日志。

做完请向我回报三件事：
1. 装在哪个目录（完整路径）
2. 计划任务是否创建成功（任务名 + 两个触发器的实际时间）
3. 自检结果（Status 的退出码 + 日志里是否有报错）
```

---

## macOS（复制这一段，**未实测**）

```text
你好，请帮我在 macOS 上安装并配置「Trae 每日签到」小工具。重要前提：这套 macOS 脚本作者没有在真机上实测过，所以请你边做边核对，遇到问题如实告诉我，不要假装成功。

背景：
- 仓库地址：https://github.com/taotao891008-eng/trae-auto-checkin
- macOS 相关文件在仓库的 macos/ 目录，用 bash + curl 实现。
- 安全边界：不读取 Trae 客户端任何文件，只读 ~/.config/trae-checkin/ 下的配置；令牌只留在本机（文件权限 600 或系统钥匙串），日志自动打码。

请按顺序做：

1) 下载
   git clone https://github.com/taotao891008-eng/trae-auto-checkin.git ~/Downloads/trae-auto-checkin
   没有 git 就用浏览器下载 ZIP，解压到同一位置。

2) 安装
   cd ~/Downloads/trae-auto-checkin
   bash macos/install.sh
   目标：
   - 程序：~/.local/share/trae-checkin/checkin.sh
   - 配置：~/.config/trae-checkin/config.env（权限 600）
   - 计划任务：~/Library/LaunchAgents/cn.trae.checkin.plist
   - 触发器：登录时一次 + 每天 00:05
   如果 install.sh 报「只能在 macOS 上运行」或 launchctl 报错，请把原文发我。

3) 令牌（这一步由我本人操作，你不要经手令牌）
   安装完先停下，让我在自己的终端里运行：
   bash ~/Downloads/trae-auto-checkin/macos/install.sh --set-token
   或存进钥匙串、配置文件不落明文：
   bash ~/Downloads/trae-auto-checkin/macos/install.sh --use-keychain
   然后由我粘贴我的 Cloud-IDE-JWT 令牌。
   请注意：
   - 你要向我索取的是「Cloud-IDE-JWT」令牌，但绝对不能让我把令牌发到对话里。
   - 令牌只应保存在我本机的配置或钥匙串里，不要写进聊天、日志、截图或仓库。
   - 如果我没有令牌，请告诉我怎么在 Trae for Mac 客户端里抄一次：开发者工具 → Network 面板 → 点一次「签到」→ 在请求头 Authorization 里复制 Cloud-IDE-JWT 后面那段。

4) 验证成功
   a. 只查询状态：
      ~/.local/share/trae-checkin/checkin.sh status
      退出码 0 = 正常；2 = 网络等待超时；3 = 令牌没配好或失效；4 = 配置或环境错误。
   b. 确认任务已加载：
      launchctl print gui/$(id -u)/cn.trae.checkin | head -30
   c. 看日志最后 10 行：
      tail -10 ~/.config/trae-checkin/logs/checkin.log
      确认没有报错、没有令牌明文。

5) 失败了怎么回报
   不要反复重试超过 1 次。把报错原文、退出码、日志最后 10 行发给我，并说明你的判断。
   macOS 首次运行可能被系统拦截或提示授权；如果 launchctl 不生效，请如实说明是哪一步失败，不要自己改写任务配置。

6) 卸载
   bash ~/Downloads/trae-auto-checkin/macos/uninstall.sh
   想保留配置可加 --keep-config。

做完请向我回报三件事：
1. 装在哪（程序、配置、plist 的完整路径）
2. LaunchAgent 是否加载成功（launchctl print 输出摘要 + 两个触发时间）
3. 自检结果（status 的退出码 + 日志里是否有报错）
```

---

给动手的人：macOS 这套脚本在仓库里是**新增文件**（不是新分支），作者只在 Windows 上验证过 Windows 部分。Mac 侧请按 [macos/README.md](macos/README.md) 的「Mac 上待验证」清单逐条确认。
