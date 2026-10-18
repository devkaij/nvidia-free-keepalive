#!/usr/bin/env bash
# =============================================================
# 魔搭创空间保活 - 一键安装脚本（Linux）
#
# 用法：
#   bash setup-keepalive.sh --url 'https://<xxx>-<space>.ms.show/healthz'
#   bash setup-keepalive.sh --url '...' --interval 5 --timeout 180
#   sudo bash setup-keepalive.sh --url '...' --system
#   bash setup-keepalive.sh --uninstall
#   sudo bash setup-keepalive.sh --uninstall --system
#
# 默认（用户级，无需 root）：
#   脚本  ~/.local/bin/ms-keepalive.sh
#   配置  ~/.config/ms-keepalive/ms-keepalive.conf
#   日志  ~/ms-keepalive/keepalive.log
#   调度  用户 crontab（每 INTERVAL 分钟）
#
# --system（系统级，需要 root）：
#   脚本  /usr/local/bin/ms-keepalive.sh
#   配置  /etc/ms-keepalive.conf
#   日志  /var/log/ms-keepalive.log
#   调度  systemd timer（无 systemd 时退化为 /etc/cron.d）
# =============================================================
set -euo pipefail

URL=""
INTERVAL=5
TIMEOUT=180
MODE="user"
ACTION="install"

print_usage() {
  cat <<'USAGE'
用法：
  bash setup-keepalive.sh --url 'https://<xxx>-<space>.ms.show/healthz' [--interval 5] [--timeout 180]
  sudo bash setup-keepalive.sh --url '...' --system        # 系统级安装
  bash setup-keepalive.sh --uninstall                      # 卸载（配合 --system 卸载系统级）

参数：
  --url URL        必填。创空间公网地址，建议带 /healthz 路径。
  --interval N     心跳间隔（分钟），默认 5。
  --timeout S      单次请求超时（秒），默认 180（覆盖冷启动）。
  --system         安装为系统级（systemd timer / cron.d），需要 root。
  --uninstall      卸载。
  -h, --help       显示帮助。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --system) MODE="system"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; print_usage; exit 1 ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1; }

write_keepalive_script() {
  local dest="$1"
  cat > "$dest" <<'KEEPALIVE'
#!/usr/bin/env bash
# 魔搭创空间保活心跳脚本（由 setup-keepalive.sh 安装，配置见 ms-keepalive.conf）
set -u

CONF="${MS_KEEPALIVE_CONF:-}"
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  for c in "$HOME/.config/ms-keepalive/ms-keepalive.conf" /etc/ms-keepalive.conf; do
    if [ -f "$c" ]; then CONF="$c"; break; fi
  done
fi
if [ -n "$CONF" ] && [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

TARGET_URL="${TARGET_URL:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
LOG_FILE="${LOG_FILE:-$HOME/ms-keepalive/keepalive.log}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-1048576}"

if [ -z "$TARGET_URL" ]; then
  echo "ms-keepalive: 未配置 TARGET_URL（请检查 $CONF）" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
TS="$(date '+%F %T %z')"

if command -v curl >/dev/null 2>&1; then
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time "$TIMEOUT_SECONDS" -L "$TARGET_URL" 2>/dev/null)" || true
  [ -n "$OUT" ] || OUT="000 0"
  CODE="${OUT%% *}"
  TIMEV="${OUT##* }"
  LOG_LINE="$TS http=$CODE time=${TIMEV}s url=$TARGET_URL"
else
  START="$(date +%s)"
  if wget -q -O /dev/null --timeout="$TIMEOUT_SECONDS" --tries=1 "$TARGET_URL" 2>/dev/null; then
    LOG_LINE="$TS http=200 time=$(( $(date +%s) - START ))s url=$TARGET_URL"
  else
    LOG_LINE="$TS http=000 time=$(( $(date +%s) - START ))s wget-failed url=$TARGET_URL"
  fi
fi

printf '%s\n' "$LOG_LINE" >> "$LOG_FILE"
printf '%s\n' "$LOG_LINE"

if [ -f "$LOG_FILE" ]; then
  SIZE="$(wc -c < "$LOG_FILE" | tr -d ' ')"
  if [ "$SIZE" -gt "$MAX_LOG_BYTES" ]; then
    tail -c $((MAX_LOG_BYTES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
fi

exit 0
KEEPALIVE
  chmod +x "$dest"
}

write_conf() {
  local conf="$1" log="$2"
  cat > "$conf" <<EOF
# 魔搭创空间保活配置（由 setup-keepalive.sh 于 $(date '+%F %T') 生成）
TARGET_URL="$URL"
TIMEOUT_SECONDS=$TIMEOUT
LOG_FILE="$log"
MAX_LOG_BYTES=1048576
EOF
  chmod 600 "$conf"
}

run_test() {
  local bin="$1" log="$2"
  echo
  echo "== 立即试跑一次（首次若遇到空间冷启动，可能需要 1~3 分钟，属正常）=="
  "$bin" || true
  echo "== 日志末尾 =="
  tail -n 3 "$log" 2>/dev/null || echo "（暂无日志）"
}

install_user() {
  local bin_dir="$HOME/.local/bin"
  local conf_dir="$HOME/.config/ms-keepalive"
  local log_dir="$HOME/ms-keepalive"
  mkdir -p "$bin_dir" "$conf_dir" "$log_dir"

  write_keepalive_script "$bin_dir/ms-keepalive.sh"
  write_conf "$conf_dir/ms-keepalive.conf" "$log_dir/keepalive.log"

  if ! need_cmd crontab; then
    echo "错误：未找到 crontab 命令，无法配置用户级定时任务。" >&2
    echo "请安装 cron（Debian/Ubuntu: sudo apt install cron；RHEL 系: sudo dnf install cronie），" >&2
    echo "或改用系统级安装：sudo bash $0 --url '$URL' --system" >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v '# ms-keepalive' > "$tmp" || true
  echo "*/$INTERVAL * * * * $bin_dir/ms-keepalive.sh >/dev/null 2>&1 # ms-keepalive" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"

  echo "[OK] 用户级保活已安装"
  echo "  心跳目标 : $URL"
  echo "  间隔     : 每 $INTERVAL 分钟（用户 crontab）"
  echo "  脚本     : $bin_dir/ms-keepalive.sh"
  echo "  配置     : $conf_dir/ms-keepalive.conf"
  echo "  日志     : $log_dir/keepalive.log"
  run_test "$bin_dir/ms-keepalive.sh" "$log_dir/keepalive.log"
}

install_system() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：--system 需要 root 权限，请用 sudo 运行。" >&2
    exit 1
  fi

  write_keepalive_script /usr/local/bin/ms-keepalive.sh
  write_conf /etc/ms-keepalive.conf /var/log/ms-keepalive.log

  if need_cmd systemctl && [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/ms-keepalive.service <<EOF
[Unit]
Description=ModelScope Studio keepalive ping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=MS_KEEPALIVE_CONF=/etc/ms-keepalive.conf
ExecStart=/usr/local/bin/ms-keepalive.sh
EOF

    cat > /etc/systemd/system/ms-keepalive.timer <<EOF
[Unit]
Description=Run ModelScope Studio keepalive every ${INTERVAL} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ms-keepalive.timer
    echo "[OK] 系统级保活已安装（systemd timer）"
    systemctl list-timers ms-keepalive.timer --no-pager 2>/dev/null || true
  else
    echo "*/$INTERVAL * * * * root /usr/local/bin/ms-keepalive.sh >/dev/null 2>&1 # ms-keepalive" > /etc/cron.d/ms-keepalive
    chmod 644 /etc/cron.d/ms-keepalive
    echo "[OK] 系统级保活已安装（/etc/cron.d/ms-keepalive）"
  fi

  echo "  心跳目标 : $URL"
  echo "  间隔     : 每 $INTERVAL 分钟"
  echo "  脚本     : /usr/local/bin/ms-keepalive.sh"
  echo "  配置     : /etc/ms-keepalive.conf"
  echo "  日志     : /var/log/ms-keepalive.log"
  run_test /usr/local/bin/ms-keepalive.sh /var/log/ms-keepalive.log
}

uninstall_user() {
  if need_cmd crontab; then
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v '# ms-keepalive' > "$tmp" || true
    crontab "$tmp" || true
    rm -f "$tmp"
  fi
  rm -f "$HOME/.local/bin/ms-keepalive.sh"
  rm -rf "$HOME/.config/ms-keepalive"
  echo "[OK] 已卸载用户级保活（日志目录 ~/ms-keepalive 保留，可手动删除）"
}

uninstall_system() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：--system --uninstall 需要 root 权限，请用 sudo 运行。" >&2
    exit 1
  fi
  if need_cmd systemctl; then
    systemctl disable --now ms-keepalive.timer 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/ms-keepalive.timer /etc/systemd/system/ms-keepalive.service
  if need_cmd systemctl; then systemctl daemon-reload 2>/dev/null || true; fi
  rm -f /etc/cron.d/ms-keepalive /usr/local/bin/ms-keepalive.sh /etc/ms-keepalive.conf
  echo "[OK] 已卸载系统级保活（日志 /var/log/ms-keepalive.log 保留，可手动删除）"
}

# ---------- 主流程 ----------
if [ "$ACTION" = "uninstall" ]; then
  if [ "$MODE" = "system" ]; then uninstall_system; else uninstall_user; fi
  exit 0
fi

if [ -z "$URL" ]; then
  echo "错误：缺少 --url 参数。" >&2
  print_usage
  exit 1
fi
case "$URL" in
  http://*|https://*) ;;
  *) echo "错误：URL 必须以 http:// 或 https:// 开头。" >&2; exit 1 ;;
esac
case "$INTERVAL" in ''|*[!0-9]*) echo "错误：--interval 必须是不小于 1 的整数（分钟）。" >&2; exit 1 ;; esac
[ "$INTERVAL" -ge 1 ] || { echo "错误：--interval 必须不小于 1。" >&2; exit 1; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "错误：--timeout 必须是不小于 10 的整数（秒）。" >&2; exit 1 ;; esac
[ "$TIMEOUT" -ge 10 ] || { echo "错误：--timeout 必须不小于 10。" >&2; exit 1; }

if ! need_cmd curl && ! need_cmd wget; then
  echo "错误：需要 curl 或 wget，请先安装其一。" >&2
  exit 1
fi

if [ "$MODE" = "system" ]; then install_system; else install_user; fi
