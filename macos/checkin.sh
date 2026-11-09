#!/bin/bash
# Trae CN 每日签到（macOS 版，未实测）
#
# 安全边界：
#   - 不读取 Trae 客户端的任何登录态文件，只读本工具自己的配置/状态
#   - 令牌只在内存中使用，日志与通知自动打码
#   - 只访问 api.trae.cn，不向第三方发送任何数据
#
# 用法：
#   ./checkin.sh                # 正常签到（当天已成功则跳过）
#   ./checkin.sh status         # 只查询，不领取
#   ./checkin.sh dry-run        # 只查询，不领取
#   ./checkin.sh set-token      # 交互式粘贴令牌（不建议贴进任何对话）
#   ./checkin.sh --wait 0       # 本次不等待网络
#   ./checkin.sh --force        # 忽略“当天已完成”标记
#
# 退出码：0 成功/已签到/未启用，1 请求失败，2 等待网络超时，
#         3 未配置令牌或令牌失效，4 配置或环境错误

set -u

CONFIG_DIR="${TRAE_CHECKIN_CONFIG_DIR:-$HOME/.config/trae-checkin}"
CONFIG_FILE="$CONFIG_DIR/config.env"
STATE_FILE="$CONFIG_DIR/state.env"
LOG_DIR="$CONFIG_DIR/logs"
LOG_FILE="$LOG_DIR/checkin.log"
LOCK_DIR="$CONFIG_DIR/run.lock"
NOTIFY_DIR="$CONFIG_DIR/notify"
MAX_LOG_BYTES=2097152

# 默认配置（可被 config.env 覆盖）
API_HOST="api.trae.cn"
PROXY_URL=""
WAIT_FOR_NETWORK_MINUTES=30
RETRY_INTERVAL_SECONDS=30
REQUEST_TIMEOUT_SECONDS=20
NOTIFY_ON_FAILURE=1
AUTH_TOKEN=""
DEVICE_ID=""
REQ_SOURCE=1
USE_KEYCHAIN=0
KEYCHAIN_SERVICE="trae-checkin-token"

LAST_SUCCESS_DAY=""
LAST_SUCCESS_AT=""
LAST_CREDITS=""

MODE="auto"
WAIT_OVERRIDE=""
NO_NOTIFY=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        set-token) MODE="set-token" ;;
        status) MODE="status" ;;
        dry-run) MODE="dry-run" ;;
        --wait)
            [ $# -ge 2 ] || { echo "缺少 --wait 的数值" >&2; exit 4; }
            WAIT_OVERRIDE="$2"; shift ;;
        --force) FORCE=1 ;;
        --no-notify) NO_NOTIFY=1 ;;
    esac
    shift
done

mkdir -p "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null
chmod 700 "$CONFIG_DIR" 2>/dev/null

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null
else
    echo "缺少配置文件：$CONFIG_FILE" >&2
    echo "请先运行 install.sh，或复制 config.example.env 到该路径。" >&2
    exit 4
fi

if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null
fi

# ---------- 日志 ----------
redact() {
    local text="$1"
    if [ -n "${AUTH_TOKEN:-}" ]; then
        text="${text//$AUTH_TOKEN/***}"
    fi
    printf '%s' "$text" | sed -E 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{8,}/***/g'
}

log() {
    local level="$1"
    shift
    local message
    message="$(redact "$*")"
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" | tr -d ' ')" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    printf '[%s] [%s] %s\n' "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null
}

# ---------- 通知 ----------
notify() {
    local title="$1"
    local message="$2"
    local type="$3"
    [ "$NOTIFY_ON_FAILURE" = "1" ] || return 0
    [ "$NO_NOTIFY" = "1" ] && return 0
    mkdir -p "$NOTIFY_DIR" 2>/dev/null
    local flag="$NOTIFY_DIR/$(TZ=Asia/Shanghai date +%Y%m%d)-$type.flag"
    [ -f "$flag" ] && return 0
    : > "$flag" 2>/dev/null
    local clean_title clean_message
    clean_title="${title//\"/}"
    clean_message="${message//\"/}"
    clean_message="${clean_message//\\/}"
    if ! /usr/bin/osascript -e "display notification \"$clean_message\" with title \"$clean_title\"" >/dev/null 2>>"$LOG_FILE"; then
        log WARN "通知发送失败（osascript），错误已写入日志"
    fi
}

# ---------- 锁 ----------
LOCK_ACQUIRED=0
acquire_lock() {
    local waited=0 pid
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        if [ "$waited" -ge 3 ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo $$ > "$LOCK_DIR/pid"
    LOCK_ACQUIRED=1
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
    return 0
}

# ---------- 状态 ----------
read_day() {
    TZ=Asia/Shanghai date '+%Y-%m-%d'
}

write_state() {
    local day="$1"
    local credits="$2"
    local tmp="$STATE_FILE.tmp"
    {
        printf 'LAST_SUCCESS_DAY="%s"\n' "$day"
        printf 'LAST_SUCCESS_AT="%s +08:00"\n' "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')"
        printf 'LAST_CREDITS="%s"\n' "$credits"
        printf 'DEVICE_ID="%s"\n' "$DEVICE_ID"
    } > "$tmp" || return 1
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE_FILE"
}

# ---------- 网络与接口 ----------
proxy_host=""
proxy_port=""
if [ -n "$PROXY_URL" ]; then
    tmp="${PROXY_URL#*://}"
    tmp="${tmp%%/*}"
    tmp="${tmp##*@}"
    proxy_host="${tmp%%:*}"
    proxy_port="${tmp##*:}"
    [ "$proxy_port" = "$tmp" ] && proxy_port=80
fi

api_host_only="${API_HOST%%:*}"
api_port=443
case "$API_HOST" in
    *:*) api_port="${API_HOST##*:}" ;;
esac

test_network() {
    if [ -n "$proxy_host" ]; then
        /usr/bin/nc -z -w 5 "$proxy_host" "$proxy_port" >/dev/null 2>&1
    else
        /usr/bin/nc -z -w 5 "$api_host_only" "$api_port" >/dev/null 2>&1
    fi
}

API_CODE=""
API_BODY=""
API_DATE=""
API_ERR=""

api_post() {
    local path="$1"
    local header_file="$CONFIG_DIR/.headers.tmp"
    local error_file="$CONFIG_DIR/.curl.err"
    local -a args
    args=(
        -sS
        --max-time "$REQUEST_TIMEOUT_SECONDS"
        --retry 2
        --retry-delay 3
        --retry-connrefused
        -X POST "https://$API_HOST$path"
        -H "Authorization: Cloud-IDE-JWT $AUTH_TOKEN"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -H "Origin: https://www.trae.cn"
        -H "Referer: https://www.trae.cn/"
        --data "{\"req_source\":$REQ_SOURCE}"
        -D "$header_file"
        -w '\n%{http_code}'
    )
    if [ -n "$DEVICE_ID" ]; then
        args+=(-H "x-device-id: $DEVICE_ID")
    fi
    if [ -n "$PROXY_URL" ]; then
        args+=(-x "$PROXY_URL")
    fi

    local response rc
    response="$(curl "${args[@]}" 2>"$error_file")"
    rc=$?
    API_CODE="${response##*$'\n'}"
    API_BODY="${response%$'\n'*}"
    API_DATE="$(grep -i '^date:' "$header_file" 2>/dev/null | head -n 1 | cut -d' ' -f2- | tr -d '\r')"
    API_ERR="$(cat "$error_file" 2>/dev/null)"
    rm -f "$header_file" "$error_file"
    return $rc
}

json_get() {
    local key="$1"
    local json="$2"
    printf '%s' "$json" | sed -n -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|[0-9]+|true|false).*/\1/p" | head -n 1 | tr -d '"'
}

http_date_epoch() {
    local raw="$1"
    [ -n "$raw" ] || return 1
    LC_ALL=C TZ=UTC /bin/date -j -f "%a, %d %b %Y %H:%M:%S GMT" "$raw" "+%s" 2>/dev/null
}

# ---------- set-token ----------
if [ "$MODE" = "set-token" ]; then
    printf '粘贴 Cloud-IDE-JWT 令牌（不含前缀，输入不回显）：'
    IFS= read -r -s token_input
    echo
    if [ -z "$token_input" ]; then
        echo "没有读到令牌，已取消。" >&2
        exit 4
    fi
    tmp="$CONFIG_FILE.tmp"
    {
        printf 'API_HOST="%s"\n' "$API_HOST"
        printf 'PROXY_URL="%s"\n' "$PROXY_URL"
        printf 'WAIT_FOR_NETWORK_MINUTES="%s"\n' "$WAIT_FOR_NETWORK_MINUTES"
        printf 'RETRY_INTERVAL_SECONDS="%s"\n' "$RETRY_INTERVAL_SECONDS"
        printf 'REQUEST_TIMEOUT_SECONDS="%s"\n' "$REQUEST_TIMEOUT_SECONDS"
        printf 'NOTIFY_ON_FAILURE="%s"\n' "$NOTIFY_ON_FAILURE"
        printf 'REQ_SOURCE="%s"\n' "$REQ_SOURCE"
        printf 'USE_KEYCHAIN="0"\n'
        printf 'KEYCHAIN_SERVICE="%s"\n' "$KEYCHAIN_SERVICE"
        printf 'AUTH_TOKEN="%s"\n' "$token_input"
        printf 'DEVICE_ID="%s"\n' "${DEVICE_ID:-}"
    } > "$tmp" || { echo "写入配置失败" >&2; exit 4; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    token_input=""
    echo "已保存到 $CONFIG_FILE（权限 600，仅本人可读）。"
    echo "提示：也可以把令牌存进钥匙串（见 macos/README.md），避免明文落盘。"
    exit 0
fi

# ---------- 参数校验 ----------
validate_int() {
    case "$2" in
        ''|*[!0-9]*) log ERROR "配置无效：$1=$2"; exit 4 ;;
    esac
}
validate_int "WaitForNetworkMinutes" "$WAIT_FOR_NETWORK_MINUTES"
validate_int "RetryIntervalSeconds" "$RETRY_INTERVAL_SECONDS"
validate_int "RequestTimeoutSeconds" "$REQUEST_TIMEOUT_SECONDS"
if [ "$WAIT_FOR_NETWORK_MINUTES" -gt 1440 ]; then
    log ERROR "WaitForNetworkMinutes 必须 <= 1440"
    exit 4
fi
if [ "$RETRY_INTERVAL_SECONDS" -lt 5 ] || [ "$RETRY_INTERVAL_SECONDS" -gt 600 ]; then
    log ERROR "RetryIntervalSeconds 必须在 5..600"
    exit 4
fi
if [ "$REQUEST_TIMEOUT_SECONDS" -lt 5 ] || [ "$REQUEST_TIMEOUT_SECONDS" -gt 120 ]; then
    log ERROR "RequestTimeoutSeconds 必须在 5..120"
    exit 4
fi

log INFO "开始运行：模式=$MODE"

if ! acquire_lock; then
    log WARN "另一个实例正在运行，本次退出（未调用接口）。"
    exit 0
fi

local_day="$(read_day)"

if [ "$MODE" = "auto" ] && [ "$FORCE" = "0" ] && [ -n "${LAST_SUCCESS_DAY:-}" ] && [ "$LAST_SUCCESS_DAY" = "$local_day" ]; then
    log INFO "当天已完成（$local_day，上次成功 ${LAST_SUCCESS_AT:-未知}），本次跳过。"
    exit 0
fi

# 令牌：环境变量 > 钥匙串 > 配置明文
token_from_config="${AUTH_TOKEN:-}"
AUTH_TOKEN=""
if [ -n "${TRAE_CHECKIN_TOKEN:-}" ]; then
    AUTH_TOKEN="$TRAE_CHECKIN_TOKEN"
fi
if [ -z "$AUTH_TOKEN" ] && [ "$USE_KEYCHAIN" = "1" ]; then
    AUTH_TOKEN="$(/usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w 2>/dev/null || true)"
fi
if [ -z "$AUTH_TOKEN" ]; then
    AUTH_TOKEN="$token_from_config"
fi
if [ -z "${AUTH_TOKEN:-}" ]; then
    log ERROR "未配置令牌。请运行 install.sh 后执行 checkin.sh set-token，把令牌只保存在本机。"
    notify "Trae 签到未配置令牌" "请在本机运行 checkin.sh set-token 粘贴令牌，不要贴进聊天记录。" "token"
    exit 3
fi

if [ -z "${DEVICE_ID:-}" ]; then
    DEVICE_ID="$(/usr/bin/uuidgen 2>/dev/null || date +%s)"
    write_state "${LAST_SUCCESS_DAY:-}" "${LAST_CREDITS:-}"
    log INFO "已生成本机设备标识（仅本机使用）。"
fi

wait_minutes="$WAIT_FOR_NETWORK_MINUTES"
if [ -n "$WAIT_OVERRIDE" ]; then
    wait_minutes="$WAIT_OVERRIDE"
    validate_int "WaitMinutes" "$wait_minutes"
fi

if [ -n "$PROXY_URL" ]; then
    log INFO "使用代理：$PROXY_URL"
fi

if ! test_network; then
    tip="网络不可用，开始等待（最多 ${wait_minutes} 分钟，每 ${RETRY_INTERVAL_SECONDS} 秒重试）。"
    [ -z "$PROXY_URL" ] && tip="$tip 如果本机需要代理，请在 config.env 填写 PROXY_URL（如 http://127.0.0.1:10808）。"
    log WARN "$tip"
    deadline=$(( $(date +%s) + wait_minutes * 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$RETRY_INTERVAL_SECONDS"
        if test_network; then
            break
        fi
    done
fi

if ! test_network; then
    log ERROR "等待网络超时（${wait_minutes} 分钟）。launchd 会按计划再次触发，网络恢复后当天仍可补签。"
    notify "Trae 签到：暂时没有网络" "已等待 ${wait_minutes} 分钟仍未连通，稍后会自动重试。" "network"
    exit 2
fi
log INFO "网络可用，开始查询签到状态"

api_post "/trae/api/v2/ug/checkin_credits/status"
status_code="$API_CODE"
status_body="$API_BODY"
status_error="$API_ERR"

# 服务器时间兜底
effective_day="$local_day"
if [ -n "$API_DATE" ]; then
    server_epoch="$(http_date_epoch "$API_DATE" || true)"
    if [ -n "$server_epoch" ]; then
        server_day="$(TZ=Asia/Shanghai date -r "$server_epoch" '+%Y-%m-%d' 2>/dev/null)"
        skew=$(( server_epoch - $(date +%s) ))
        if [ -n "$server_day" ] && [ "$server_day" != "$local_day" ]; then
            log WARN "本机日期（$local_day）与服务器日期（$server_day）不一致，跨天判断改用服务器日期，请检查系统时间与时区。"
            effective_day="$server_day"
        elif [ "$skew" -gt 600 ] || [ "$skew" -lt -600 ]; then
            log WARN "本机时间与服务器相差约 $(( skew / 60 )) 分钟，建议校准系统时间。"
        fi
    fi
fi

if [ "$MODE" = "auto" ] && [ "$FORCE" = "0" ] && [ "${LAST_SUCCESS_DAY:-}" = "$effective_day" ]; then
    log INFO "当天已完成（服务器日期 $effective_day），本次不再领取。"
    exit 0
fi

if [ -z "$status_code" ] || [ "$status_code" = "000" ]; then
    log ERROR "查询签到状态失败：${status_error:-网络错误}"
    notify "Trae 签到失败：状态查询" "无法连接签到接口，详见本机日志。" "status"
    exit 1
fi

case "$status_code" in
    401|403)
        log ERROR "令牌无效或已过期（HTTP $status_code）。请重新运行 checkin.sh set-token。"
        notify "Trae 签到失败：令牌失效" "令牌已失效，请在本机重新粘贴令牌。" "auth"
        exit 3 ;;
    200) ;;
    *)
        log ERROR "查询签到状态失败（HTTP $status_code）：$status_body"
        notify "Trae 签到失败：状态查询" "接口返回异常，详见本机日志。" "status"
        exit 1 ;;
esac

code="$(json_get code "$status_body")"
if [ "$code" = "1001" ]; then
    log ERROR "令牌无效或已过期（code=1001）。请重新运行 checkin.sh set-token。"
    notify "Trae 签到失败：令牌失效" "令牌已失效，请在本机重新粘贴令牌。" "auth"
    exit 3
fi
if [ -n "$code" ] && [ "$code" != "0" ]; then
    log ERROR "查询签到状态失败（code=$code）：$(json_get message "$status_body")"
    notify "Trae 签到失败：状态查询" "接口返回 code=$code，详见本机日志。" "status"
    exit 1
fi

checked_in="$(json_get checked_in "$status_body")"
enabled="$(json_get enable "$status_body")"
credits="$(json_get credits "$status_body")"
extra_credits="$(json_get extra_credits "$status_body")"
[ -n "$credits" ] || credits=0
[ -n "$extra_credits" ] || extra_credits=0

if [ "$checked_in" = "true" ]; then
    log INFO "今日已签到，跳过领取。当前积分：$credits，额外：$extra_credits"
    write_state "$effective_day" "$((credits + extra_credits))"
    exit 0
fi
if [ "$enabled" = "false" ]; then
    log INFO "签到功能当前未启用（enable=false），跳过。"
    exit 0
fi
if [ "$MODE" = "status" ] || [ "$MODE" = "dry-run" ]; then
    log INFO "今日未签到（当前积分 $credits）。本次为只读模式，未执行领取。"
    exit 0
fi

log INFO "今日未签到，发起领取"
api_post "/trae/api/v2/ug/checkin_credits/claim"
claim_code="$API_CODE"
claim_body="$API_BODY"
claim_error="$API_ERR"

if [ -z "$claim_code" ] || [ "$claim_code" = "000" ]; then
    log ERROR "签到请求失败：${claim_error:-网络错误}"
    notify "Trae 签到失败" "领取请求没有成功，详见本机日志。" "claim"
    exit 1
fi
case "$claim_code" in
    401|403)
        log ERROR "领取时令牌失效（HTTP $claim_code），请重新运行 set-token。"
        notify "Trae 签到失败：令牌失效" "令牌已失效，请在本机重新粘贴令牌。" "auth"
        exit 3 ;;
esac

claim_json_code="$(json_get code "$claim_body")"
if [ "$claim_code" = "200" ] && [ "$claim_json_code" = "0" ]; then
    final_credits=-1
    api_post "/trae/api/v2/ug/checkin_credits/status"
    if [ "$API_CODE" = "200" ]; then
        c2="$(json_get credits "$API_BODY")"
        e2="$(json_get extra_credits "$API_BODY")"
        [ -n "$c2" ] || c2=0
        [ -n "$e2" ] || e2=0
        final_credits=$((c2 + e2))
        log INFO "签到成功，今日积分 $c2（额外 $e2，合计 $final_credits）"
    else
        log INFO "签到成功（HTTP 200, code=0），积分查询未成功，不影响签到结论"
    fi
    write_state "$effective_day" "$final_credits"
    exit 0
fi

if [ "$claim_json_code" = "1001" ]; then
    log ERROR "令牌无效或已过期（code=1001），请重新运行 set-token。"
    notify "Trae 签到失败：令牌失效" "令牌已失效，请在本机重新粘贴令牌。" "auth"
    exit 3
fi

log ERROR "签到未成功（HTTP $claim_code，code=$claim_json_code，message=$(json_get message "$claim_body")）"
notify "Trae 签到失败" "领取接口返回异常，详见本机日志。" "claim"
exit 1
