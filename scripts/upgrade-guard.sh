#!/usr/bin/env bash
# upgrade-guard.sh — Safe OpenClaw upgrade with full pre/post validation
# Born from 7 cascading failures on 2026-02-04.
#
# Usage:
#   upgrade-guard.sh snapshot              # Save current state
#   upgrade-guard.sh check                 # Pre-flight checks
#   upgrade-guard.sh upgrade [--dry-run]   # Full safe upgrade
#   upgrade-guard.sh verify                # Post-upgrade verification
#   upgrade-guard.sh rollback              # Emergency rollback
#   upgrade-guard.sh status                # Show current vs snapshot

set -euo pipefail

# --- Config ---
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/clawdbot}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.clawdbot/clawdbot.json}"
# Also check new path
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="$HOME/.openclaw/openclaw.json"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw/upgrade-guard}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:3456}"

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
fatal() { fail "$*"; exit 1; }

mkdir -p "$STATE_DIR"

# ============================================================
# SNAPSHOT — capture current system state
# ============================================================
cmd_snapshot() {
  info "Taking system snapshot..."
  local snap_dir="$STATE_DIR/snapshot-$(date +%Y%m%d-%H%M%S)"
  local latest="$STATE_DIR/latest"
  mkdir -p "$snap_dir"

  # 1. Version
  local version
  version=$(cd "$OPENCLAW_DIR" && node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")
  echo "$version" > "$snap_dir/version"
  ok "Version: $version"

  # 2. Git state
  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    (cd "$OPENCLAW_DIR" && git rev-parse HEAD) > "$snap_dir/git-commit"
    (cd "$OPENCLAW_DIR" && git log --oneline -1) > "$snap_dir/git-log"
    ok "Git commit: $(cat "$snap_dir/git-commit" | head -c 12)"
  fi

  # 3. Config backup
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$snap_dir/config.json"
    ok "Config backed up"
  else
    warn "Config file not found: $CONFIG_FILE"
  fi

  # 4. Plugin files inventory
  find "$OPENCLAW_DIR" -name "*.plugin.json" -o -name "*.plugin.js" -o -name "*.plugin.mjs" 2>/dev/null \
    | sort > "$snap_dir/plugin-files.txt"
  ok "Plugin files: $(wc -l < "$snap_dir/plugin-files.txt") found"

  # 5. Node modules state
  if [[ -f "$OPENCLAW_DIR/pnpm-lock.yaml" ]]; then
    cp "$OPENCLAW_DIR/pnpm-lock.yaml" "$snap_dir/pnpm-lock.yaml"
    ok "Lock file backed up"
  fi

  # 6. Symlinks
  find "$OPENCLAW_DIR" -type l 2>/dev/null | sort > "$snap_dir/symlinks.txt"
  local symcount
  symcount=$(wc -l < "$snap_dir/symlinks.txt")
  [[ "$symcount" -gt 0 ]] && ok "Symlinks: $symcount found" || info "No symlinks"

  # 7. Running services check
  local gw_status="unknown"
  if curl -sf "${GATEWAY_URL}/healthz" >/dev/null 2>&1 || curl -sf "${GATEWAY_URL}/api/health" >/dev/null 2>&1; then
    gw_status="running"
  elif pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
    gw_status="process-found"
  else
    gw_status="not-running"
  fi
  echo "$gw_status" > "$snap_dir/gateway-status"
  ok "Gateway: $gw_status"

  # 8. Channel connectivity
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
channels = []
for key in ['telegram', 'discord', 'slack', 'whatsapp', 'signal']:
    if key in cfg and cfg[key]:
        channels.append(key)
# Also check under 'channels' key
if 'channels' in cfg:
    for ch in (cfg['channels'] if isinstance(cfg['channels'], list) else [cfg['channels']]):
        if isinstance(ch, dict) and 'type' in ch:
            channels.append(ch['type'])
print('\n'.join(set(channels)))
" > "$snap_dir/channels.txt" 2>/dev/null || true
    ok "Channels configured: $(cat "$snap_dir/channels.txt" | tr '\n' ', ' | sed 's/,$//')"
  fi

  # 9. Model info
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
model = cfg.get('agents', {}).get('primaryModel', cfg.get('primaryModel', 'unknown'))
print(model)
" > "$snap_dir/model.txt" 2>/dev/null || echo "unknown" > "$snap_dir/model.txt"
    ok "Primary model: $(cat "$snap_dir/model.txt")"
  fi

  # Update latest symlink
  rm -f "$latest"
  ln -sf "$snap_dir" "$latest"
  echo ""
  ok "Snapshot saved: $snap_dir"
}

# ============================================================
# CHECK — pre-flight validation
# ============================================================
cmd_check() {
  info "Running pre-upgrade checks..."
  local errors=0
  local warnings=0

  # 1. Snapshot exists?
  if [[ ! -L "$STATE_DIR/latest" ]]; then
    fail "No snapshot found. Run 'upgrade-guard.sh snapshot' first."
    errors=$((errors + 1))
  else
    ok "Snapshot found: $(readlink "$STATE_DIR/latest")"
  fi

  # 2. Config file exists?
  if [[ -f "$CONFIG_FILE" ]]; then
    ok "Config file: $CONFIG_FILE"
  else
    fail "Config file not found: $CONFIG_FILE"
    errors=$((errors + 1))
  fi

  # 3. Git repo clean?
  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    local dirty
    dirty=$(cd "$OPENCLAW_DIR" && git status --porcelain 2>/dev/null | wc -l)
    if [[ "$dirty" -eq 0 ]]; then
      ok "Git repo clean"
    else
      warn "Git repo has $dirty uncommitted changes"
      warnings=$((warnings + 1))
    fi
  fi

  # 4. Disk space
  local avail_kb
  avail_kb=$(df "$OPENCLAW_DIR" --output=avail 2>/dev/null | tail -1 | tr -d ' ')
  if [[ -n "$avail_kb" ]] && [[ "$avail_kb" -gt 500000 ]]; then
    ok "Disk space: $((avail_kb / 1024))MB available"
  else
    warn "Low disk space: $((avail_kb / 1024))MB"
    warnings=$((warnings + 1))
  fi

  # 5. Current version readable?
  local cur_version
  cur_version=$(cd "$OPENCLAW_DIR" && node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "")
  if [[ -n "$cur_version" ]]; then
    ok "Current version: $cur_version"
  else
    fail "Cannot read current version"
    errors=$((errors + 1))
  fi

  # 6. Gateway running?
  if curl -sf "${GATEWAY_URL}/healthz" >/dev/null 2>&1 || curl -sf "${GATEWAY_URL}/api/health" >/dev/null 2>&1; then
    ok "Gateway is responding"
  elif pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
    warn "Gateway process found but not responding on HTTP"
    warnings=$((warnings + 1))
  else
    warn "Gateway not running (will need manual start after upgrade)"
    warnings=$((warnings + 1))
  fi

  # 7. Check for remote updates
  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    (cd "$OPENCLAW_DIR" && git fetch origin 2>/dev/null)
    local behind
    behind=$(cd "$OPENCLAW_DIR" && git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
    if [[ "$behind" -gt 0 ]]; then
      info "Remote is $behind commits ahead"
      # Show what's coming
      echo ""
      info "Incoming changes:"
      (cd "$OPENCLAW_DIR" && git log --oneline HEAD..origin/main 2>/dev/null | head -20)
      echo ""

      # Check for breaking change signals
      local breaking
      breaking=$(cd "$OPENCLAW_DIR" && git log --oneline HEAD..origin/main 2>/dev/null \
        | grep -ic "break\|BREAK\|rename\|migration\|deprecat" || true)
      if [[ "$breaking" -gt 0 ]]; then
        warn "⚡ $breaking commits mention breaking/rename/migration — READ CHANGELOG"
        warnings=$((warnings + 1))
      fi
    else
      info "Already up to date"
    fi
  fi

  # 8. Check npm/pnpm available
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm available: $(pnpm --version 2>/dev/null)"
  elif command -v npm >/dev/null 2>&1; then
    ok "npm available: $(npm --version 2>/dev/null)"
  else
    fail "No package manager found (need pnpm or npm)"
    errors=$((errors + 1))
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$errors" -gt 0 ]]; then
    fail "Pre-flight: $errors errors, $warnings warnings — FIX ERRORS BEFORE UPGRADING"
    return 1
  elif [[ "$warnings" -gt 0 ]]; then
    warn "Pre-flight: 0 errors, $warnings warnings — proceed with caution"
  else
    ok "Pre-flight: all clear ✅"
  fi
}

# ============================================================
# UPGRADE — the actual safe upgrade
# ============================================================
cmd_upgrade() {
  local dry_run=false
  [[ "${1:-}" == "--dry-run" ]] && dry_run=true

  info "Starting safe upgrade..."
  $dry_run && info "(DRY RUN — no changes will be made)"
  echo ""

  # Step 0: Must have snapshot
  if [[ ! -L "$STATE_DIR/latest" ]]; then
    fatal "No snapshot. Run 'upgrade-guard.sh snapshot' first!"
  fi

  # Step 1: Pre-flight
  info "━━━ Step 1/6: Pre-flight checks ━━━"
  if ! cmd_check; then
    fatal "Pre-flight failed. Fix errors first."
  fi
  echo ""

  if $dry_run; then
    ok "DRY RUN complete. Would proceed with upgrade."
    return 0
  fi

  # Step 2: Fresh snapshot
  info "━━━ Step 2/6: Fresh snapshot ━━━"
  cmd_snapshot
  echo ""

  # Step 3: Stop gateway
  info "━━━ Step 3/6: Stopping gateway ━━━"
  if pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
    openclaw gateway stop 2>/dev/null || pkill -f "openclaw gateway" 2>/dev/null || true
    sleep 2
    if pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
      warn "Gateway still running, force killing..."
      pkill -9 -f "openclaw gateway" 2>/dev/null || true
      sleep 1
    fi
    ok "Gateway stopped"
  else
    info "Gateway was not running"
  fi
  echo ""

  # Step 4: git pull
  info "━━━ Step 4/6: git pull ━━━"
  (cd "$OPENCLAW_DIR" && git pull origin main 2>&1) || {
    fail "git pull failed!"
    warn "You can rollback with: upgrade-guard.sh rollback"
    return 1
  }
  local new_version
  new_version=$(cd "$OPENCLAW_DIR" && node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")
  ok "Pulled. New version: $new_version"
  echo ""

  # Step 5: pnpm install + build
  info "━━━ Step 5/6: Install dependencies + build ━━━"
  (cd "$OPENCLAW_DIR" && pnpm install 2>&1) || {
    fail "pnpm install failed!"
    warn "Rolling back git..."
    local old_commit
    old_commit=$(cat "$STATE_DIR/latest/git-commit" 2>/dev/null)
    if [[ -n "$old_commit" ]]; then
      (cd "$OPENCLAW_DIR" && git checkout "$old_commit" 2>&1)
      (cd "$OPENCLAW_DIR" && pnpm install 2>&1)
    fi
    return 1
  }
  ok "Dependencies installed"

  if [[ -f "$OPENCLAW_DIR/package.json" ]] && grep -q '"build"' "$OPENCLAW_DIR/package.json"; then
    (cd "$OPENCLAW_DIR" && pnpm run build 2>&1) || {
      fail "Build failed!"
      warn "Rolling back..."
      cmd_rollback
      return 1
    }
    ok "Build complete"
  fi
  echo ""

  # Step 6: Post-upgrade verification
  info "━━━ Step 6/6: Post-upgrade verification ━━━"
  cmd_verify
}

# ============================================================
# VERIFY — post-upgrade checks
# ============================================================
cmd_verify() {
  info "Running post-upgrade verification..."
  local errors=0
  local warnings=0
  local snap="$STATE_DIR/latest"

  # 1. Version changed?
  local old_version new_version
  old_version=$(cat "$snap/version" 2>/dev/null || echo "unknown")
  new_version=$(cd "$OPENCLAW_DIR" && node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")
  if [[ "$old_version" != "$new_version" ]]; then
    ok "Version: $old_version → $new_version"
  else
    info "Version unchanged: $new_version"
  fi

  # 2. Plugin files — check for renames
  local old_plugins="$snap/plugin-files.txt"
  if [[ -f "$old_plugins" ]]; then
    local new_plugins
    new_plugins=$(mktemp)
    find "$OPENCLAW_DIR" -name "*.plugin.json" -o -name "*.plugin.js" -o -name "*.plugin.mjs" 2>/dev/null \
      | sort > "$new_plugins"

    # Check for removed plugin files
    local removed
    removed=$(comm -23 "$old_plugins" "$new_plugins" 2>/dev/null | wc -l)
    if [[ "$removed" -gt 0 ]]; then
      warn "⚡ $removed plugin files removed/renamed:"
      comm -23 "$old_plugins" "$new_plugins" | while read -r f; do
        echo "    - $f"
        # Check if there's a similarly named replacement
        local basename
        basename=$(basename "$f")
        local altname
        # clawdbot.plugin.json → openclaw.plugin.json or vice versa
        altname=$(echo "$basename" | sed 's/clawdbot/openclaw/g; s/openclaw/clawdbot/g')
        if grep -q "$altname" "$new_plugins" 2>/dev/null; then
          echo "      → possible rename: $altname (may need symlink)"
        fi
      done
      warnings=$((warnings + 1))
    fi

    # Check for new plugin files
    local added
    added=$(comm -13 "$old_plugins" "$new_plugins" 2>/dev/null | wc -l)
    [[ "$added" -gt 0 ]] && info "$added new plugin files added"

    rm -f "$new_plugins"
  fi

  # 3. Config still valid?
  if [[ -f "$CONFIG_FILE" ]]; then
    if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
      ok "Config: valid JSON"
    else
      fail "Config: invalid JSON!"
      errors=$((errors + 1))
    fi

    # Check channels still present
    if [[ -f "$snap/channels.txt" ]]; then
      while read -r ch; do
        if grep -q "$ch" "$CONFIG_FILE" 2>/dev/null; then
          ok "Channel '$ch' still in config"
        else
          fail "Channel '$ch' MISSING from config!"
          errors=$((errors + 1))
        fi
      done < "$snap/channels.txt"
    fi

    # Check model still set
    local old_model new_model
    old_model=$(cat "$snap/model.txt" 2>/dev/null || echo "")
    new_model=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
print(cfg.get('agents', {}).get('primaryModel', cfg.get('primaryModel', '')))
" 2>/dev/null || echo "")
    if [[ -n "$new_model" ]]; then
      ok "Primary model: $new_model"
      [[ "$old_model" != "$new_model" ]] && warn "Model changed: $old_model → $new_model"
    else
      fail "No primary model configured!"
      errors=$((errors + 1))
    fi
  fi

  # 4. Check for broken symlinks
  local broken_links=0
  while IFS= read -r link; do
    if [[ ! -e "$link" ]]; then
      fail "Broken symlink: $link → $(readlink "$link")"
      broken_links=$((broken_links + 1))
    fi
  done < <(find "$OPENCLAW_DIR" -type l 2>/dev/null)
  [[ "$broken_links" -eq 0 ]] && ok "No broken symlinks" || errors=$((errors + broken_links))

  # 5. Check critical node_modules
  local critical_modules=("pi-ai" "@anthropic-ai/sdk" "grammy")
  for mod in "${critical_modules[@]}"; do
    if [[ -d "$OPENCLAW_DIR/node_modules/$mod" ]]; then
      ok "Module: $mod ✓"
    else
      # Not necessarily an error — might not be used
      info "Module not found: $mod (may not be required)"
    fi
  done

  # 6. Try starting gateway and check health
  info "Starting gateway..."
  openclaw gateway start 2>/dev/null &
  local gw_ok=false
  for i in $(seq 1 30); do
    if curl -sf "${GATEWAY_URL}/healthz" >/dev/null 2>&1 || curl -sf "${GATEWAY_URL}/api/health" >/dev/null 2>&1; then
      gw_ok=true
      break
    fi
    sleep 1
  done

  if $gw_ok; then
    ok "Gateway started and responding ✅"
  else
    # Check if process is at least running
    if pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
      warn "Gateway process running but not responding on HTTP"
      warnings=$((warnings + 1))
    else
      fail "Gateway failed to start!"
      errors=$((errors + 1))
    fi
  fi

  # 7. Check recent logs for errors
  local logfile
  for lf in "$HOME/.openclaw/logs/gateway.log" "$HOME/.clawdbot/logs/gateway.log" "/tmp/openclaw-gateway.log"; do
    [[ -f "$lf" ]] && logfile="$lf" && break
  done
  if [[ -n "${logfile:-}" ]]; then
    local recent_errors
    recent_errors=$(tail -50 "$logfile" 2>/dev/null | grep -ic "error\|fatal\|crash\|ENOENT\|MODULE_NOT_FOUND" || true)
    if [[ "$recent_errors" -gt 0 ]]; then
      warn "$recent_errors error lines in recent gateway logs"
      tail -50 "$logfile" | grep -i "error\|fatal\|crash\|ENOENT\|MODULE_NOT_FOUND" | tail -5
      warnings=$((warnings + 1))
    else
      ok "No errors in recent logs"
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$errors" -gt 0 ]]; then
    fail "Verification: $errors errors, $warnings warnings"
    echo ""
    fail "❌ UPGRADE MAY HAVE PROBLEMS"
    echo "  Run 'upgrade-guard.sh rollback' to restore previous version"
    return 1
  elif [[ "$warnings" -gt 0 ]]; then
    warn "Verification: 0 errors, $warnings warnings — check warnings above"
    echo ""
    ok "Upgrade completed with warnings ⚠️"
  else
    ok "Verification: all clear"
    echo ""
    ok "🎉 Upgrade successful!"
  fi
}

# ============================================================
# ROLLBACK — emergency restore
# ============================================================
cmd_rollback() {
  local snap="$STATE_DIR/latest"

  if [[ ! -L "$snap" ]]; then
    fatal "No snapshot to rollback to!"
  fi

  info "Rolling back to snapshot: $(readlink "$snap")"
  echo ""

  # 1. Stop gateway
  info "Stopping gateway..."
  openclaw gateway stop 2>/dev/null || pkill -f "openclaw gateway" 2>/dev/null || true
  sleep 2

  # 2. Restore git state
  local old_commit
  old_commit=$(cat "$snap/git-commit" 2>/dev/null || echo "")
  if [[ -n "$old_commit" ]] && [[ -d "$OPENCLAW_DIR/.git" ]]; then
    info "Restoring git to: $old_commit"
    (cd "$OPENCLAW_DIR" && git checkout "$old_commit" 2>&1) || warn "Git checkout failed"
    ok "Git restored"

    # Reinstall deps for old version
    info "Reinstalling dependencies..."
    (cd "$OPENCLAW_DIR" && pnpm install 2>&1) || warn "pnpm install had issues"

    if grep -q '"build"' "$OPENCLAW_DIR/package.json" 2>/dev/null; then
      (cd "$OPENCLAW_DIR" && pnpm run build 2>&1) || warn "Build had issues"
    fi
    ok "Dependencies restored"
  fi

  # 3. Restore config
  if [[ -f "$snap/config.json" ]]; then
    info "Restoring config..."
    cp "$snap/config.json" "$CONFIG_FILE"
    ok "Config restored"
  fi

  # 4. Restart gateway
  info "Starting gateway..."
  openclaw gateway start 2>/dev/null &
  sleep 5

  if curl -sf "${GATEWAY_URL}/healthz" >/dev/null 2>&1 || pgrep -f "openclaw\|clawdbot" >/dev/null 2>&1; then
    ok "Gateway is back up"
  else
    fail "Gateway didn't start — may need manual intervention"
  fi

  echo ""
  ok "Rollback complete. Version: $(cat "$snap/version" 2>/dev/null || echo 'unknown')"
}

# ============================================================
# STATUS — show current vs snapshot
# ============================================================
cmd_status() {
  local snap="$STATE_DIR/latest"

  echo "━━━ Upgrade Guard Status ━━━"
  echo ""

  # Current
  local cur_version
  cur_version=$(cd "$OPENCLAW_DIR" && node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")
  info "Current version: $cur_version"

  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    info "Current commit: $(cd "$OPENCLAW_DIR" && git rev-parse --short HEAD 2>/dev/null)"
  fi

  # Snapshot
  if [[ -L "$snap" ]]; then
    echo ""
    info "Latest snapshot: $(readlink "$snap")"
    info "  Version: $(cat "$snap/version" 2>/dev/null || echo 'unknown')"
    info "  Commit: $(cat "$snap/git-commit" 2>/dev/null | head -c 12 || echo 'unknown')"
    info "  Channels: $(cat "$snap/channels.txt" 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo 'none')"
    info "  Model: $(cat "$snap/model.txt" 2>/dev/null || echo 'unknown')"
    info "  Gateway was: $(cat "$snap/gateway-status" 2>/dev/null || echo 'unknown')"
  else
    warn "No snapshot taken yet"
  fi

  # Available updates
  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    (cd "$OPENCLAW_DIR" && git fetch origin 2>/dev/null)
    local behind
    behind=$(cd "$OPENCLAW_DIR" && git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
    echo ""
    if [[ "$behind" -gt 0 ]]; then
      warn "$behind commits available upstream"
    else
      ok "Up to date with remote"
    fi
  fi

  # All snapshots
  echo ""
  info "All snapshots:"
  ls -dt "$STATE_DIR"/snapshot-* 2>/dev/null | while read -r d; do
    echo "  $(basename "$d") — v$(cat "$d/version" 2>/dev/null || echo '?')"
  done
  [[ $(ls -d "$STATE_DIR"/snapshot-* 2>/dev/null | wc -l) -eq 0 ]] && echo "  (none)"
}

# ============================================================
# Main
# ============================================================
case "${1:-help}" in
  snapshot)  cmd_snapshot ;;
  check)     cmd_check ;;
  upgrade)   cmd_upgrade "${2:-}" ;;
  verify)    cmd_verify ;;
  rollback)  cmd_rollback ;;
  status)    cmd_status ;;
  help|--help|-h)
    echo "upgrade-guard.sh — Safe OpenClaw upgrades"
    echo ""
    echo "Commands:"
    echo "  snapshot    Save current system state (version, config, plugins, deps)"
    echo "  check       Pre-flight checks (disk, git, config, remote updates)"
    echo "  upgrade     Full safe upgrade: snapshot → check → pull → install → build → verify"
    echo "  verify      Post-upgrade verification (config, channels, plugins, gateway)"
    echo "  rollback    Emergency rollback to last snapshot"
    echo "  status      Show current state vs last snapshot"
    echo ""
    echo "Options:"
    echo "  upgrade --dry-run    Run checks without making changes"
    echo ""
    echo "Environment:"
    echo "  OPENCLAW_DIR    OpenClaw install dir (default: /opt/clawdbot)"
    echo "  CONFIG_FILE     Config path (default: ~/.clawdbot/clawdbot.json)"
    echo "  GATEWAY_URL     Gateway URL (default: http://127.0.0.1:3456)"
    ;;
  *)
    fatal "Unknown command: $1 (try 'help')"
    ;;
esac
