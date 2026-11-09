#!/bin/bash
# 卸载 Trae 每日签到（macOS，未实测）
#
# 默认清理：
#   1. LaunchAgent：cn.trae.checkin（launchctl bootout）
#   2. ~/Library/LaunchAgents/cn.trae.checkin.plist
#   3. ~/.local/share/trae-checkin（程序）
#   4. ~/.config/trae-checkin（配置、状态、日志，含明文令牌）
#   5. 钥匙串条目 trae-checkin-token（如果曾使用 --use-keychain）
#
# 用法：
#   ./uninstall.sh                # 全部清理
#   ./uninstall.sh --keep-config  # 保留 ~/.config/trae-checkin（排查用）

set -u

LABEL="cn.trae.checkin"
SHARE_DIR="$HOME/.local/share/trae-checkin"
CONFIG_DIR="$HOME/.config/trae-checkin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
KEEP_CONFIG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-config) KEEP_CONFIG=1 ;;
        *)
            echo "未知参数：$1" >&2
            exit 1 ;;
    esac
    shift
done

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
launchctl unload -w "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

if [ "$KEEP_CONFIG" = "1" ]; then
    rm -rf "$SHARE_DIR"
    echo "已删除程序与 LaunchAgent，保留配置目录：$CONFIG_DIR"
    echo "注意：其中的 config.env 可能仍有明文令牌，确认不再使用后请手动删除。"
else
    rm -rf "$SHARE_DIR" "$CONFIG_DIR"
    echo "已删除程序、配置、状态与日志。"
fi

if /usr/bin/security find-generic-password -s "trae-checkin-token" >/dev/null 2>&1; then
    /usr/bin/security delete-generic-password -s "trae-checkin-token" >/dev/null 2>&1 || true
    echo "已删除钥匙串条目 trae-checkin-token。"
fi

echo "卸载完成。"
