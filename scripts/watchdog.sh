#!/usr/bin/env bash
# watchdog.sh — OS-level gateway watchdog with auto-recovery
# Runs independently of the AI agent and gateway via systemd timer.
#
# What it does:
#   1. Checks if gateway process is running
#   2. Checks if gateway HTTP responds
#   3. Checks if Telegram bot is connected (optional)
#   4. If unhealthy for FAIL_THRESHOLD consecutive checks:
#      a. Try restart first
#      b. If restart doesn't fix it, rollback to last snapshot
#   5. Sends notification on recovery actions
#
# Usage:
#   watchdog.sh check     # Single health check (for cron/timer)
#   watchdog.sh install   # Install systemd timer
#   watchdog.sh uninstall # Remove systemd timer
#   watchdog.sh status    # Show watchdog state

set -euo pipefail

# --- Config ---
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/clawdbot}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.clawdbot/clawdbot.json}"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="$HOME/.openclaw/openclaw.json"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw/upgrade-guard}"
WATCHDOG_STATE="$STATE_DIR/watchdog-state.json"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"          # consecutive failures before action
RESTART_TIMEOUT="${RESTART_TIMEOUT:-60}"       # seconds to wait after restart
UPGRADE_GUARD="$(dirname "$0")/upgrade-guard.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✖${NC} $*"; }

mkdir -p "$STATE_DIR"

# ============================================================
# State management
# ============================================================
get_state() {
  if [[ -f "$WATCHDOG_STATE" ]]; then
    python3 -c "
import json
with open('$WATCHDOG_STATE') as f:
    s = json.load(f)
print(s.get('${1}', '${2:-}'))
" 2>/dev/null || echo "${2:-}"
  else
    echo "${2:-}"
  fi
}

set_state() {
  local key="$1" value="$2"
  if [[ -f "$WATCHDOG_STATE" ]]; then
    python3 -c "
import json
with open('$WATCHDOG_STATE') as f:
    s = json.load(f)
s['$key'] = '$value'
with open('$WATCHDOG_STATE', 'w') as f:
    json.dump(s, f, indent=2)
" 2>/dev/null
  else
    echo "{\"$key\": \"$value\"}" > "$WATCHDOG_STATE"
  fi
}

# ============================================================
# Health checks
# ============================================================
check_process() {
  pgrep -f "openclaw.*gateway\|clawdbot.*gateway\|node.*dist/index.js.*gateway" >/dev/null 2>&1 \
    || pgrep -x "openclaw-gatewa" >/dev/null 2>&1 \
    || ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT}\\b"
}

check_http() {
  # Try multiple endpoints
  curl -sf --max-time 10 "${GATEWAY_URL}/healthz" >/dev/null 2>&1 \
    || curl -sf --max-time 10 "${GATEWAY_URL}/" >/dev/null 2>&1
}

check_telegram() {
  # Check if Telegram bot is connected by looking at recent logs
  # If no Telegram config, skip this check
  if ! grep -q '"telegram"' "$CONFIG_FILE" 2>/dev/null; then
    return 0  # No Telegram configured, skip
  fi

  # Check journal for recent Telegram errors (last 2 minutes)
  local recent_errors
  recent_errors=$(journalctl -u clawdbot.service --since "2 minutes ago" --no-pager 2>/dev/null \
    | grep -ic "telegram.*error\|telegram.*disconnect\|grammY.*error\|ETELEGRAM" || true)

  # Also check for successful message processing as positive signal
  local recent_activity
  recent_activity=$(journalctl -u clawdbot.service --since "5 minutes ago" --no-pager 2>/dev/null \
    | grep -ic "telegram\|tg\|agent.*res" || true)

  if [[ "$recent_errors" -gt 3 ]]; then
    return 1  # Telegram having issues
  fi
  return 0
}

# ============================================================
# CHECK — main health check
# ============================================================
cmd_check() {
  local healthy=true
  local issues=()
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Check 1: Process
  if check_process; then
    ok "Process: running"
  else
    fail "Process: NOT running"
    healthy=false
    issues+=("process_down")
  fi

  # Check 2: HTTP
  if check_http; then
    ok "HTTP: responding on port $GATEWAY_PORT"
  else
    fail "HTTP: not responding"
    healthy=false
    issues+=("http_down")
  fi

  # Check 3: Telegram
  if check_telegram; then
    ok "Telegram: OK"
  else
    warn "Telegram: errors detected"
    issues+=("telegram_errors")
    # Telegram errors alone don't trigger rollback, just restart
  fi

  # Update state
  if $healthy; then
    set_state "last_healthy" "$timestamp"
    set_state "consecutive_failures" "0"
    set_state "last_check" "$timestamp"
    set_state "status" "healthy"
    ok "Gateway healthy ✅"
    return 0
  fi

  # --- UNHEALTHY ---
  local consecutive
  consecutive=$(get_state "consecutive_failures" "0")
  consecutive=$((consecutive + 1))
  set_state "consecutive_failures" "$consecutive"
  set_state "last_check" "$timestamp"
  set_state "status" "unhealthy"
  set_state "last_issues" "$(IFS=,; echo "${issues[*]}")"

  warn "Unhealthy! Consecutive failures: $consecutive / $FAIL_THRESHOLD"

  if [[ "$consecutive" -ge "$FAIL_THRESHOLD" ]]; then
    fail "⚡ Threshold reached ($consecutive failures). Taking action..."
    echo ""

    # Strategy: restart first, rollback second
    local last_action
    last_action=$(get_state "last_action" "none")
    local last_action_time
    last_action_time=$(get_state "last_action_time" "0")
    local now_epoch
    now_epoch=$(date +%s)

    # Don't rollback too frequently (min 5 minutes between actions)
    local cooldown=300
    if [[ "$last_action_time" != "0" ]]; then
      local elapsed=$((now_epoch - last_action_time))
      if [[ "$elapsed" -lt "$cooldown" ]]; then
        warn "Last action was ${elapsed}s ago (cooldown: ${cooldown}s). Waiting..."
        return 1
      fi
    fi

    if [[ "$last_action" != "restart" ]] || [[ "$consecutive" -lt $((FAIL_THRESHOLD * 2)) ]]; then
      # First: try restart
      action_restart
    else
      # Second: rollback
      action_rollback
    fi
  fi

  return 1
}

# ============================================================
# Recovery actions
# ============================================================
action_restart() {
  info "Action: restarting gateway..."
  set_state "last_action" "restart"
  set_state "last_action_time" "$(date +%s)"

  # Try systemd restart first
  if systemctl restart clawdbot.service 2>/dev/null; then
    info "Systemd restart issued"
  else
    # Fall back to manual restart
    pkill -f "openclaw.*gateway\|node.*dist/index.js.*gateway" 2>/dev/null || true
    sleep 2
    (cd "$OPENCLAW_DIR" && node dist/index.js gateway --port "$GATEWAY_PORT" &) 2>/dev/null
    info "Manual restart issued"
  fi

  # Wait and verify
  info "Waiting ${RESTART_TIMEOUT}s for gateway..."
  local recovered=false
  for i in $(seq 1 "$RESTART_TIMEOUT"); do
    if check_http; then
      recovered=true
      break
    fi
    sleep 1
  done

  if $recovered; then
    ok "Gateway recovered after restart ✅"
    set_state "consecutive_failures" "0"
    set_state "status" "recovered"
    log_event "RESTART_SUCCESS" "Gateway recovered after restart"
  else
    fail "Gateway still down after restart"
    log_event "RESTART_FAILED" "Gateway failed to recover after restart"
  fi
}

action_rollback() {
  local snap="$STATE_DIR/latest"
  if [[ ! -L "$snap" ]]; then
    fail "No snapshot available for rollback!"
    log_event "ROLLBACK_FAILED" "No snapshot available"
    return 1
  fi

  info "Action: rolling back to snapshot..."
  set_state "last_action" "rollback"
  set_state "last_action_time" "$(date +%s)"

  # Use upgrade-guard's rollback
  if [[ -x "$UPGRADE_GUARD" ]]; then
    bash "$UPGRADE_GUARD" rollback 2>&1
  else
    # Manual rollback
    warn "upgrade-guard.sh not found, doing manual rollback..."

    # Stop gateway
    systemctl stop clawdbot.service 2>/dev/null || pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    sleep 2

    # Restore git
    local old_commit
    old_commit=$(cat "$snap/git-commit" 2>/dev/null || echo "")
    if [[ -n "$old_commit" ]]; then
      (cd "$OPENCLAW_DIR" && git checkout "$old_commit" 2>&1) || true
      (cd "$OPENCLAW_DIR" && pnpm install 2>&1) || true
      if grep -q '"build"' "$OPENCLAW_DIR/package.json" 2>/dev/null; then
        (cd "$OPENCLAW_DIR" && pnpm run build 2>&1) || true
      fi
    fi

    # Restore config
    if [[ -f "$snap/config.json" ]]; then
      cp "$snap/config.json" "$CONFIG_FILE"
    fi

    # Restart
    systemctl start clawdbot.service 2>/dev/null || \
      (cd "$OPENCLAW_DIR" && node dist/index.js gateway --port "$GATEWAY_PORT" &) 2>/dev/null
  fi

  # Verify
  sleep 10
  if check_http; then
    ok "Gateway recovered after rollback ✅"
    set_state "consecutive_failures" "0"
    set_state "status" "rolled_back"
    log_event "ROLLBACK_SUCCESS" "Gateway recovered after rollback to $(cat "$snap/version" 2>/dev/null || echo '?')"
  else
    fail "Gateway STILL down after rollback. Manual intervention needed."
    log_event "ROLLBACK_FAILED" "Gateway still down after rollback"
  fi
}

log_event() {
  local event="$1" message="$2"
  local logfile="$STATE_DIR/watchdog.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$event] $message" >> "$logfile"
}

# ============================================================
# INSTALL — set up systemd timer
# ============================================================
cmd_install() {
  local script_path
  script_path=$(realpath "$0")

  # Strategy: try systemd first, fall back to cron
  local installed=false

  # Try system-level systemd (needs root)
  if [[ $EUID -eq 0 ]]; then
    _install_systemd_system "$script_path"
    installed=true
  fi

  # Try user-level systemd (needs dbus)
  if ! $installed && systemctl --user status >/dev/null 2>&1; then
    _install_systemd_user "$script_path"
    installed=true
  fi

  # Fall back to cron
  if ! $installed; then
    _install_cron "$script_path"
    installed=true
  fi
}

_install_systemd_system() {
  local script_path="$1"
  local service_dir="/etc/systemd/system"

  cat > "$service_dir/openclaw-watchdog.service" <<EOF
[Unit]
Description=OpenClaw Gateway Watchdog
After=network.target
[Service]
Type=oneshot
User=clawdbot
Group=clawdbot
Environment="HOME=/home/clawdbot"
Environment="PATH=/home/clawdbot/.npm/bin:/home/clawdbot/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
Environment="GATEWAY_PORT=${GATEWAY_PORT}"
ExecStart=/usr/bin/bash ${script_path} check
StandardOutput=journal
StandardError=journal
EOF

  cat > "$service_dir/openclaw-watchdog.timer" <<EOF
[Unit]
Description=OpenClaw Gateway Watchdog Timer
[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable openclaw-watchdog.timer
  systemctl start openclaw-watchdog.timer
  ok "Watchdog installed (systemd system timer, every 60s)"
  info "View logs: journalctl -u openclaw-watchdog.service"
}

_install_systemd_user() {
  local script_path="$1"
  local service_dir="$HOME/.config/systemd/user"
  mkdir -p "$service_dir"

  cat > "$service_dir/openclaw-watchdog.service" <<EOF
[Unit]
Description=OpenClaw Gateway Watchdog
[Service]
Type=oneshot
Environment="GATEWAY_PORT=${GATEWAY_PORT}"
ExecStart=/usr/bin/bash ${script_path} check
EOF

  cat > "$service_dir/openclaw-watchdog.timer" <<EOF
[Unit]
Description=OpenClaw Gateway Watchdog Timer
[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10
[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable openclaw-watchdog.timer
  systemctl --user start openclaw-watchdog.timer
  loginctl enable-linger "$(whoami)" 2>/dev/null || warn "Run 'sudo loginctl enable-linger $(whoami)' for persistence"
  ok "Watchdog installed (systemd user timer, every 60s)"
  info "View logs: journalctl --user -u openclaw-watchdog.service"
}

_install_cron() {
  local script_path="$1"
  local cron_line="* * * * * GATEWAY_PORT=${GATEWAY_PORT} /usr/bin/bash ${script_path} check >> ${STATE_DIR}/watchdog-cron.log 2>&1"
  local cron_marker="# openclaw-watchdog"

  # Remove existing watchdog cron entry
  crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null || true

  # Add new entry
  (crontab -l 2>/dev/null; echo "${cron_line} ${cron_marker}") | crontab -

  ok "Watchdog installed (cron, every 60s)"
  ok "Cron entry: ${cron_line}"
  info "View logs: tail -f ${STATE_DIR}/watchdog-cron.log"
}

# ============================================================
# UNINSTALL
# ============================================================
cmd_uninstall() {
  # Remove cron entry
  local cron_marker="# openclaw-watchdog"
  crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null && ok "Cron entry removed" || true

  # Try user-level systemd
  systemctl --user stop openclaw-watchdog.timer 2>/dev/null || true
  systemctl --user disable openclaw-watchdog.timer 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/openclaw-watchdog.service"
  rm -f "$HOME/.config/systemd/user/openclaw-watchdog.timer"
  systemctl --user daemon-reload 2>/dev/null || true

  # Try system-level systemd
  if [[ $EUID -eq 0 ]]; then
    systemctl stop openclaw-watchdog.timer 2>/dev/null || true
    systemctl disable openclaw-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/openclaw-watchdog.service
    rm -f /etc/systemd/system/openclaw-watchdog.timer
    systemctl daemon-reload 2>/dev/null || true
  fi

  ok "Watchdog uninstalled"
}

# ============================================================
# STATUS
# ============================================================
cmd_status() {
  echo "━━━ Watchdog Status ━━━"
  echo ""

  if [[ -f "$WATCHDOG_STATE" ]]; then
    info "Status: $(get_state "status" "unknown")"
    info "Last check: $(get_state "last_check" "never")"
    info "Last healthy: $(get_state "last_healthy" "never")"
    info "Consecutive failures: $(get_state "consecutive_failures" "0")"
    info "Last action: $(get_state "last_action" "none")"
  else
    info "No watchdog state yet (run 'watchdog.sh check' first)"
  fi

  echo ""
  # Check timer/cron status
  if systemctl --user is-active openclaw-watchdog.timer >/dev/null 2>&1; then
    ok "Timer: active (systemd user-level)"
  elif systemctl is-active openclaw-watchdog.timer >/dev/null 2>&1; then
    ok "Timer: active (systemd system-level)"
  elif crontab -l 2>/dev/null | grep -q "openclaw-watchdog"; then
    ok "Timer: active (cron)"
  else
    warn "Timer: not installed"
  fi

  # Show recent log
  if [[ -f "$STATE_DIR/watchdog.log" ]]; then
    echo ""
    info "Recent events:"
    tail -10 "$STATE_DIR/watchdog.log"
  fi
}

# ============================================================
# Main
# ============================================================
case "${1:-help}" in
  check)     cmd_check ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  help|--help|-h)
    echo "watchdog.sh — OS-level gateway watchdog"
    echo ""
    echo "Commands:"
    echo "  check      Run health check (process + HTTP + Telegram)"
    echo "  install    Install systemd timer (checks every 60s)"
    echo "  uninstall  Remove systemd timer"
    echo "  status     Show watchdog state and recent events"
    echo ""
    echo "Recovery strategy:"
    echo "  Failures 1-2:  Log and wait"
    echo "  Failure 3:     Restart gateway"
    echo "  Failure 6+:    Rollback to last snapshot"
    echo ""
    echo "Environment:"
    echo "  GATEWAY_PORT      Gateway port (default: 18789)"
    echo "  FAIL_THRESHOLD    Failures before action (default: 3)"
    echo "  RESTART_TIMEOUT   Seconds to wait after restart (default: 60)"
    ;;
  *)
    fail "Unknown command: $1"
    exit 1
    ;;
esac
