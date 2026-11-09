#!/bin/bash
# 安装 Trae 每日签到（macOS，未实测）
#
# 安装内容：
#   ~/.local/share/trae-checkin/checkin.sh     程序
#   ~/.config/trae-checkin/config.env          配置（权限 600）
#   ~/Library/LaunchAgents/cn.trae.checkin.plist   LaunchAgent
#
# LaunchAgent 触发：登录时一次 + 每天 00:05 一次。
#
# 用法：
#   ./install.sh                    # 只安装，稍后自己填令牌
#   ./install.sh --set-token        # 安装后交互式粘贴令牌（不回显）
#   ./install.sh --use-keychain     # 令牌存进钥匙串，配置文件不落明文
#   ./install.sh --set-token --use-keychain   # 同上，只问一次

set -u

LABEL="cn.trae.checkin"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SHARE_DIR="$HOME/.local/share/trae-checkin"
CONFIG_DIR="$HOME/.config/trae-checkin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "这个脚本只能在 macOS 上运行；Windows 请用仓库根目录的 install.ps1。" >&2
    exit 1
fi

SET_TOKEN=0
USE_KEYCHAIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --set-token) SET_TOKEN=1 ;;
        --use-keychain) USE_KEYCHAIN=1 ;;
        *)
            echo "未知参数：$1" >&2
            echo "可用参数：--set-token / --use-keychain" >&2
            exit 1 ;;
    esac
    shift
done

mkdir -p "$SHARE_DIR" "$CONFIG_DIR/logs" "$HOME/Library/LaunchAgents"
install -m 700 "$ROOT/checkin.sh" "$SHARE_DIR/checkin.sh"

if [ ! -f "$CONFIG_DIR/config.env" ]; then
    install -m 600 "$ROOT/config.example.env" "$CONFIG_DIR/config.env"
    echo "已创建配置：$CONFIG_DIR/config.env"
else
    echo "保留已有配置：$CONFIG_DIR/config.env"
fi
chmod 700 "$CONFIG_DIR"
chmod 600 "$CONFIG_DIR/config.env"

# 生成 LaunchAgent（替换占位符，避免把用户路径硬编码进仓库文件）
sed -e "s|__SCRIPT__|$SHARE_DIR/checkin.sh|g" \
    -e "s|__LOG_DIR__|$CONFIG_DIR/logs|g" \
    "$ROOT/cn.trae.checkin.plist" > "$PLIST"
chmod 644 "$PLIST"

# 重新加载（macOS 11+ 用 bootstrap，老系统回退 load）
launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
if ! launchctl bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1; then
    launchctl unload -w "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST" 2>/dev/null || {
        echo "LaunchAgent 加载失败，请检查 $PLIST" >&2
        exit 1
    }
fi

echo "LaunchAgent 已加载：$LABEL"
echo "  触发器：登录时一次 + 每天 00:05"
echo "  说明：Mac 在 00:05 处于睡眠时，launchd 会在唤醒后补跑一次"

if [ "$USE_KEYCHAIN" = "1" ]; then
    printf '粘贴 Cloud-IDE-JWT 令牌（不含前缀，输入不回显）：'
    IFS= read -r -s token_input
    echo
    if [ -z "$token_input" ]; then
        echo "没有读到令牌，跳过（可稍后重新运行 --use-keychain）。" >&2
    else
        if /usr/bin/security add-generic-password -U -s "trae-checkin-token" -a "$USER" -w "$token_input" >/dev/null 2>&1; then
            sed -i '' 's/^USE_KEYCHAIN=.*/USE_KEYCHAIN="1"/' "$CONFIG_DIR/config.env"
            sed -i '' 's/^AUTH_TOKEN=.*/AUTH_TOKEN=""/' "$CONFIG_DIR/config.env"
            echo "令牌已存入钥匙串（服务名 trae-checkin-token），配置文件里不保留明文。"
        else
            echo "写入钥匙串失败，请改用 ./install.sh --set-token。" >&2
        fi
        token_input=""
    fi
elif [ "$SET_TOKEN" = "1" ]; then
    "$SHARE_DIR/checkin.sh" set-token
fi

echo ""
echo "配置文件：$CONFIG_DIR/config.env"
echo "日志：$CONFIG_DIR/logs/checkin.log"
echo "立即验证（只查询）：$SHARE_DIR/checkin.sh status"
echo "查看任务：launchctl print gui/$UID_NUM/$LABEL"
echo "卸载：$ROOT/uninstall.sh"
