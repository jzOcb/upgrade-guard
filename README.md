# Upgrade Guard 🔄

[![OpenClaw Skill](https://img.shields.io/badge/OpenClaw-Skill-blue)](https://clawdhub.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)](./SKILL.md)

## Never lose a working OpenClaw to a bad upgrade again.

> Born from 7 cascading failures during a single version jump.

The gateway crashed, Telegram disconnected, plugins broke, models vanished — and the AI agent that caused it was also dead, so nobody could fix it remotely.

This skill makes upgrades safe.

## The Problem

OpenClaw upgrades can break in ways that are invisible until it's too late:

- **Plugin renames** — `clawdbot.plugin.json` → `openclaw.plugin.json`
- **Dependency breaks** — SDK module paths change, exports shift
- **Config schema changes** — new required fields, removed fields
- **Model name changes** — dot vs hyphen format
- **Channel config wipes** — silent removal during migration

A single `git pull && pnpm install` can trigger all of these simultaneously.

## Quick Start

```bash
# Install
clawdhub install upgrade-guard
# or: git clone https://github.com/jzOcb/upgrade-guard

# Before upgrading: snapshot your working system
bash scripts/upgrade-guard.sh snapshot

# Check what's coming
bash scripts/upgrade-guard.sh check

# Safe upgrade (auto-rollback on failure)
bash scripts/upgrade-guard.sh upgrade

# Something broke? Emergency rollback
bash scripts/upgrade-guard.sh rollback
```

## Commands

| Command | What it does |
|---|---|
| `snapshot` | Save current state (version, config, plugins, deps, symlinks) |
| `check` | Pre-flight validation (disk, git, config, breaking changes) |
| `upgrade` | Full safe upgrade: snapshot → check → pull → install → build → verify |
| `upgrade --dry-run` | Preview without changing anything |
| `verify` | Post-upgrade checks (plugins, channels, model, gateway, logs) |
| `rollback` | Emergency restore to last snapshot |
| `status` | Show current state vs snapshots |

## What It Checks

**Pre-upgrade:**
- Snapshot exists
- Config file valid
- Git repo clean
- Disk space sufficient
- Breaking change signals in incoming commits

**Post-upgrade:**
- Plugin files renamed/removed (detects clawdbot↔openclaw renames)
- Config still valid, channels still configured
- Model still set
- No broken symlinks
- Gateway starts and responds
- No errors in recent logs

## Use With config-guard

| | config-guard | upgrade-guard |
|---|---|---|
| Config validation | ✅ | ❌ |
| Plugin renames | ❌ | ✅ |
| Dependency breaks | ❌ | ✅ |
| Version tracking | ❌ | ✅ |
| Git state management | ❌ | ✅ |
| Full system rollback | ❌ | ✅ |

Best used together: config-guard for config edits, upgrade-guard for version upgrades.

## Watchdog — OS-Level Self-Healing

The real "fix it without you" piece. Runs as a systemd timer, independent of the AI agent and gateway.

```bash
# Install (checks every 60 seconds)
bash scripts/watchdog.sh install

# Manual check
bash scripts/watchdog.sh check

# Status
bash scripts/watchdog.sh status
```

**Recovery strategy:**
- Failures 1-2 → log and wait
- Failure 3 → restart gateway
- Failure 6+ → full rollback to last snapshot

**Survives:** gateway crash, AI agent death, server reboots.

## Requirements

- `bash` 4+, `python3`, `curl`, `git`, `pnpm` or `npm`

## Related

- [config-guard](https://github.com/jzOcb/config-guard) — Config validation and auto-rollback
- [agent-guardrails](https://github.com/jzOcb/agent-guardrails) — Code-level enforcement for AI agents

## License

MIT
