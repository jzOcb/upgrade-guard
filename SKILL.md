---
name: upgrade-guard
description: "Safe OpenClaw upgrade management with snapshot, pre-flight checks, controlled upgrade steps, post-verification, and emergency rollback via upgrade-guard.sh. Use when upgrading OpenClaw, updating OpenClaw to a new version, rolling back a failed OpenClaw update, checking OpenClaw upgrade safety, or performing OpenClaw version migration."
metadata:
  openclaw:
    emoji: "🔄"
---

# Upgrade Guard

Manages safe OpenClaw version upgrades through a 5-phase workflow: snapshot current state, run pre-flight checks, execute controlled upgrade with auto-rollback, verify the result, and rollback if needed.

## Known Upgrade Risks

OpenClaw upgrades can cause cascading failures — plugin renames (`clawdbot.plugin.json` to `openclaw.plugin.json`), dependency breaks, config schema changes, model name format changes, and silent channel config wipes. A single `git pull && pnpm install` can trigger all of these simultaneously.

## Workflow

### 1. Snapshot — Capture Working State

```bash
bash scripts/upgrade-guard.sh snapshot
```

Saves: version + git commit, full config backup, plugin file inventory, symlink map, lock file, channel list + model info, gateway health status.

### 2. Pre-flight — Check Before Touching Anything

```bash
bash scripts/upgrade-guard.sh check
```

Validates: snapshot exists, config valid, git repo clean, disk space OK, package manager available. Previews remote changes and scans commit messages for breaking changes.

### 3. Upgrade — Controlled 6-Step Process

```bash
# Full upgrade with auto-rollback on failure
bash scripts/upgrade-guard.sh upgrade

# Preview without changing anything
bash scripts/upgrade-guard.sh upgrade --dry-run
```

Steps: pre-flight checks (abort if fail) → fresh snapshot → stop gateway → `git pull` (rollback on fail) → `pnpm install` + `pnpm run build` (rollback on fail) → post-upgrade verification.

### 4. Verify — Post-Upgrade Checks

```bash
bash scripts/upgrade-guard.sh verify
```

Checks: version changed, plugin files renamed/removed (detects clawdbot/openclaw renames), config still valid JSON, all channels configured, model set, no broken symlinks, gateway starts and responds, no errors in recent logs.

### 5. Rollback — Emergency Restore

```bash
bash scripts/upgrade-guard.sh rollback
```

Stops gateway → restores git to previous commit → reinstalls old dependencies → restores config → restarts gateway.

### Status

```bash
bash scripts/upgrade-guard.sh status
```

## Agent Instructions

**MANDATORY before any OpenClaw upgrade:**

1. `bash scripts/upgrade-guard.sh snapshot` — save current state
2. `bash scripts/upgrade-guard.sh check` — verify pre-conditions
3. `bash scripts/upgrade-guard.sh upgrade` — controlled upgrade with auto-rollback
4. `bash scripts/upgrade-guard.sh verify` — confirm everything works
5. If anything fails → `bash scripts/upgrade-guard.sh rollback`

**NEVER run `git pull && pnpm install` directly — always use upgrade-guard.**

## Watchdog — OS-Level Self-Healing

The watchdog runs as a systemd timer to detect and recover from gateway failures independently. See [WATCHDOG.md](WATCHDOG.md) for full details and commands.

## Complementary Tools

| Concern | Tool |
|---|---|
| Config validation and auto-rollback | [config-guard](https://github.com/jzOcb/config-guard) |
| Code-level enforcement for AI agents | [agent-guardrails](https://github.com/jzOcb/agent-guardrails) |

Use config-guard for config changes, upgrade-guard for version upgrades.

## Install

```bash
clawdhub install upgrade-guard
```

## Requirements

- `bash` 4+, `python3`, `curl`, `git`, `pnpm` or `npm`
