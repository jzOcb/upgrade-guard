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
METRICS_LOG="$STATE_DIR/watchdog-metrics.jsonl"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"          # consecutive failures before action
RESTART_TIMEOUT="${RESTART_TIMEOUT:-60}"       # seconds to wait after restart
UPGRADE_GUARD="$(dirname "$0")/upgrade-guard.sh"

# Resource thresholds
MEM_WARN_PCT="${MEM_WARN_PCT:-80}"             # warn if system memory > X%
MEM_CRIT_PCT="${MEM_CRIT_PCT:-90}"             # critical if system memory > X%
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"           # warn if disk > X%
DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"           # critical if disk > X%
GW_MEM_WARN_MB="${GW_MEM_WARN_MB:-800}"        # warn if gateway RSS > X MB
GW_MEM_CRIT_MB="${GW_MEM_CRIT_MB:-1200}"       # critical if gateway RSS > X MB
CHROME_MEM_WARN_MB="${CHROME_MEM_WARN_MB:-1500}"  # warn if Chrome total > X MB
CHROME_MEM_CRIT_MB="${CHROME_MEM_CRIT_MB:-2000}"  # restart Chrome if > X MB
METRICS_MAX_LINES="${METRICS_MAX_LINES:-1440}"  # ~24h at 1/min

# Telegram alerts (reads bot token from OpenClaw config)
ALERT_ENABLED="${ALERT_ENABLED:-true}"
ALERT_COOLDOWN="${ALERT_COOLDOWN:-300}"         # min seconds between alerts

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
# Telegram alerts
# ============================================================
_get_bot_token() {
  python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f)['channels']['telegram']['botToken'])
except:
    print('')
" 2>/dev/null
}

_get_chat_id() {
  python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)['channels']['telegram']
        print(c.get('allowedUsers',[''])[0])
except:
    print('')
" 2>/dev/null
}

send_alert() {
  [[ "$ALERT_ENABLED" != "true" ]] && return 0
  local message="$1"
  local level="${2:-WARN}"  # WARN or CRIT

  # Check cooldown
  local last_alert
  last_alert=$(get_state "last_alert_time" "0")
  local now_epoch
  now_epoch=$(date +%s)
  if [[ "$last_alert" != "0" ]] && [[ $((now_epoch - last_alert)) -lt "$ALERT_COOLDOWN" ]]; then
    return 0  # Throttled
  fi

  local token chat_id
  token=$(_get_bot_token)
  chat_id=$(_get_chat_id)
  [[ -z "$token" || -z "$chat_id" ]] && return 0

  local emoji="⚠️"
  [[ "$level" == "CRIT" ]] && emoji="🚨"

  local text="${emoji} *Watchdog ${level}*
${message}
_$(date -u +%H:%M:%S\ UTC)_"

  curl -sf --max-time 10 \
    "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$chat_id" \
    -d text="$text" \
    -d parse_mode="Markdown" \
    >/dev/null 2>&1 || true

  set_state "last_alert_time" "$now_epoch"
  log_event "ALERT_${level}" "$message"
}

# ============================================================
# Resource monitoring
# ============================================================
check_resources() {
  local warnings=()
  local criticals=()

  # --- System memory ---
  local mem_total mem_avail mem_used_pct
  mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "$mem_total" -gt 0 ]]; then
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [[ "$mem_used_pct" -ge "$MEM_CRIT_PCT" ]]; then
      criticals+=("RAM ${mem_used_pct}% (${mem_avail}MB free)")
    elif [[ "$mem_used_pct" -ge "$MEM_WARN_PCT" ]]; then
      warnings+=("RAM ${mem_used_pct}% (${mem_avail}MB free)")
    fi
  fi

  # --- Disk ---
  local disk_pct
  disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
  if [[ -n "$disk_pct" ]]; then
    if [[ "$disk_pct" -ge "$DISK_CRIT_PCT" ]]; then
      criticals+=("Disk ${disk_pct}%")
    elif [[ "$disk_pct" -ge "$DISK_WARN_PCT" ]]; then
      warnings+=("Disk ${disk_pct}%")
    fi
  fi

  # --- Gateway process memory ---
  local gw_rss_mb=0
  local gw_pid
  # Find gateway PID: try multiple patterns
  gw_pid=$(pgrep -f "openclaw-gateway" 2>/dev/null | head -1 || true)
  [[ -z "$gw_pid" ]] && gw_pid=$(pgrep -f "clawdbot-gateway" 2>/dev/null | head -1 || true)
  [[ -z "$gw_pid" ]] && gw_pid=$(ss -tlnp 2>/dev/null | grep ":${GATEWAY_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
  if [[ -n "$gw_pid" ]]; then
    gw_rss_mb=$(ps -o rss= -p "$gw_pid" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)
    if [[ "$gw_rss_mb" -ge "$GW_MEM_CRIT_MB" ]]; then
      criticals+=("Gateway RSS ${gw_rss_mb}MB")
    elif [[ "$gw_rss_mb" -ge "$GW_MEM_WARN_MB" ]]; then
      warnings+=("Gateway RSS ${gw_rss_mb}MB")
    fi
  fi

  # --- Chrome total memory ---
  local chrome_mem_mb=0
  chrome_mem_mb=$(ps aux 2>/dev/null | grep -E "[c]hrome|[c]hromium" | awk '{sum += $6} END {print int(sum/1024)}')
  chrome_mem_mb=${chrome_mem_mb:-0}
  if [[ "$chrome_mem_mb" -gt 0 ]]; then
    if [[ "$chrome_mem_mb" -ge "$CHROME_MEM_CRIT_MB" ]]; then
      criticals+=("Chrome ${chrome_mem_mb}MB — auto-restarting")
      restart_chrome
    elif [[ "$chrome_mem_mb" -ge "$CHROME_MEM_WARN_MB" ]]; then
      warnings+=("Chrome ${chrome_mem_mb}MB")
    fi
  fi

  # --- Record metrics ---
  local ts
  ts=$(date +%s)
  echo "{\"ts\":$ts,\"mem_pct\":${mem_used_pct:-0},\"mem_avail_mb\":${mem_avail:-0},\"disk_pct\":${disk_pct:-0},\"gw_rss_mb\":${gw_rss_mb:-0},\"chrome_mb\":${chrome_mem_mb:-0}}" >> "$METRICS_LOG"

  # Rotate metrics log
  if [[ -f "$METRICS_LOG" ]]; then
    local lines
    lines=$(wc -l < "$METRICS_LOG")
    if [[ "$lines" -gt "$METRICS_MAX_LINES" ]]; then
      tail -n "$METRICS_MAX_LINES" "$METRICS_LOG" > "${METRICS_LOG}.tmp"
      mv "${METRICS_LOG}.tmp" "$METRICS_LOG"
    fi
  fi

  # --- Trend detection: memory creep ---
  if [[ -f "$METRICS_LOG" ]] && [[ $(wc -l < "$METRICS_LOG") -ge 30 ]]; then
    local mem_30_ago mem_now
    mem_30_ago=$(head -1 <(tail -30 "$METRICS_LOG") | python3 -c "import sys,json;print(json.load(sys.stdin)['gw_rss_mb'])" 2>/dev/null || echo 0)
    mem_now=${gw_rss_mb:-0}
    if [[ "$mem_30_ago" -gt 0 ]] && [[ "$mem_now" -gt 0 ]]; then
      local growth=$(( (mem_now - mem_30_ago) * 100 / mem_30_ago ))
      if [[ "$growth" -gt 20 ]]; then
        warnings+=("Gateway memory growing: ${mem_30_ago}MB → ${mem_now}MB (+${growth}% in 30min)")
      fi
    fi
  fi

  # --- Report ---
  # Always show resource summary
  info "Resources: RAM ${mem_used_pct:-?}% | Disk ${disk_pct:-?}% | GW ${gw_rss_mb:-?}MB | Chrome ${chrome_mem_mb:-?}MB"
  
  if [[ ${#criticals[@]} -gt 0 ]]; then
    for c in "${criticals[@]}"; do fail "CRITICAL: $c"; done
    send_alert "$(printf '%s\n' "${criticals[@]}")" "CRIT"
    return 2
  elif [[ ${#warnings[@]} -gt 0 ]]; then
    for w in "${warnings[@]}"; do warn "WARNING: $w"; done
    # Only alert on warnings every 30 min
    local last_warn_alert
    last_warn_alert=$(get_state "last_warn_alert" "0")
    local now_epoch
    now_epoch=$(date +%s)
    if [[ "$last_warn_alert" == "0" ]] || [[ $((now_epoch - last_warn_alert)) -ge 1800 ]]; then
      send_alert "$(printf '%s\n' "${warnings[@]}")" "WARN"
      set_state "last_warn_alert" "$now_epoch"
    fi
    return 1
  fi
  return 0
}

# ============================================================
# Log rotation
# ============================================================
rotate_logs() {
  local logfile="$STATE_DIR/watchdog-cron.log"
  if [[ -f "$logfile" ]]; then
    local size
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    # Rotate at 500KB
    if [[ "$size" -gt 512000 ]]; then
      mv "$logfile" "${logfile}.1"
      info "Log rotated (was ${size} bytes)"
    fi
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

  # Log rotation
  rotate_logs

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

  # Check 4: Resources (memory, disk, gateway process)
  check_resources || true

  # Daily cleanup: Chrome sensitive data (cookies, login data, history)
  clean_chrome_sensitive_data || true

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
# Chrome management
# ============================================================
clean_chrome_sensitive_data() {
  # Clean cookies, login data, history from Chrome user-data
  # Run daily to prevent credential accumulation
  local user_data="$HOME/.openclaw/browser/openclaw/user-data/Default"
  [[ ! -d "$user_data" ]] && return 0
  
  local last_clean
  last_clean=$(get_state "last_chrome_clean" "0")
  local now_epoch
  now_epoch=$(date +%s)
  
  # Only clean once per day (86400 seconds)
  if [[ "$last_clean" != "0" ]] && [[ $((now_epoch - last_clean)) -lt 86400 ]]; then
    return 0
  fi
  
  info "Cleaning Chrome sensitive data (daily)..."
  rm -f "$user_data/Cookies"* 2>/dev/null
  rm -f "$user_data/Login Data"* 2>/dev/null
  rm -f "$user_data/History"* 2>/dev/null
  rm -rf "$user_data/Sessions/" 2>/dev/null
  rm -rf "$user_data/Session Storage/" 2>/dev/null
  rm -rf "$user_data/Local Storage/" 2>/dev/null
  rm -rf "$user_data/IndexedDB/" 2>/dev/null
  
  set_state "last_chrome_clean" "$now_epoch"
  log_event "CHROME_CLEAN" "Daily sensitive data cleanup completed"
  ok "Chrome sensitive data cleaned"
}

restart_chrome() {
  info "Restarting Chrome (memory cleanup)..."
  
  # Kill all Chrome processes
  pkill -9 -f "chrome|chromium" 2>/dev/null || true
  sleep 2
  
  # Chrome will be auto-started by OpenClaw browser tool on next use
  # No need to manually restart — it's lazy-loaded
  
  local after_mem
  after_mem=$(ps aux 2>/dev/null | grep -E "[c]hrome|[c]hromium" | awk '{sum += $6} END {print int(sum/1024)}')
  after_mem=${after_mem:-0}
  
  ok "Chrome restarted (memory: ${after_mem}MB)"
  log_event "CHROME_RESTART" "Chrome restarted for memory cleanup"
  send_alert "Chrome restarted (was using too much memory)" "WARN"
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

  # Show resource trends
  if [[ -f "$METRICS_LOG" ]]; then
    local total_points
    total_points=$(wc -l < "$METRICS_LOG")
    echo ""
    info "Metrics: $total_points data points"
    if [[ "$total_points" -ge 2 ]]; then
      local latest oldest
      latest=$(tail -1 "$METRICS_LOG")
      oldest=$(head -1 "$METRICS_LOG")
      echo "  Oldest: $(echo "$oldest" | python3 -c "import sys,json;from datetime import datetime;d=json.load(sys.stdin);print(datetime.utcfromtimestamp(d['ts']).strftime('%Y-%m-%d %H:%M UTC'))" 2>/dev/null || echo "?")"
      echo "  Latest: $(echo "$latest" | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"RAM {d['mem_pct']}% | Disk {d['disk_pct']}% | GW {d['gw_rss_mb']}MB | Chrome {d.get('chrome_mb',0)}MB\")" 2>/dev/null || echo "?")"
    fi
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
    echo "watchdog.sh — OS-level gateway watchdog with resource monitoring"
    echo ""
    echo "Commands:"
    echo "  check      Run health check (process + HTTP + Telegram + resources)"
    echo "  install    Install systemd timer (checks every 60s)"
    echo "  uninstall  Remove systemd timer"
    echo "  status     Show watchdog state, events, and resource trends"
    echo ""
    echo "Recovery strategy:"
    echo "  Failures 1-2:  Log and wait"
    echo "  Failure 3:     Restart gateway"
    echo "  Failure 6+:    Rollback to last snapshot"
    echo ""
    echo "Resource monitoring:"
    echo "  RAM, disk, gateway RSS, Chrome memory tracked every check"
    echo "  Metrics stored in JSONL (rolling 24h window)"
    echo "  Trend detection: alerts on memory growth >20% in 30min"
    echo "  Chrome auto-restart when memory exceeds threshold"
    echo "  Telegram alerts on WARN and CRIT thresholds"
    echo ""
    echo "Environment:"
    echo "  GATEWAY_PORT      Gateway port (default: 18789)"
    echo "  FAIL_THRESHOLD    Failures before action (default: 3)"
    echo "  RESTART_TIMEOUT   Seconds to wait after restart (default: 60)"
    echo "  MEM_WARN_PCT      Memory warning threshold (default: 80)"
    echo "  DISK_WARN_PCT     Disk warning threshold (default: 80)"
    echo "  GW_MEM_WARN_MB    Gateway RSS warning (default: 800MB)"
    echo "  CHROME_MEM_WARN_MB Chrome warning threshold (default: 1500MB)"
    echo "  CHROME_MEM_CRIT_MB Chrome auto-restart threshold (default: 2000MB)"
    echo "  ALERT_ENABLED     Send Telegram alerts (default: true)"
    ;;
  *)
    fail "Unknown command: $1"
    exit 1
    ;;
esac
