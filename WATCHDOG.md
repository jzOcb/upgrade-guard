# Watchdog — OS-Level Self-Healing

The watchdog runs independently via systemd timer. It survives gateway crashes, AI agent death, and server reboots.

## Commands

```bash
# Install (checks every 60 seconds)
bash scripts/watchdog.sh install

# Check health manually
bash scripts/watchdog.sh check

# View status and recent events
bash scripts/watchdog.sh status

# Remove
bash scripts/watchdog.sh uninstall
```

## Recovery Strategy

| Consecutive failures | Action |
|---|---|
| 1-2 | Log and wait |
| 3 | Restart gateway |
| 6+ | Rollback to last snapshot |

## Health Checks

1. **Process** — is the gateway process running?
2. **HTTP** — does the gateway respond on its port?
3. **Telegram** — any connection errors in recent logs?

## Why It Works When Everything Else Fails

- Runs as **systemd timer** — survives gateway crash, AI death, reboots
- Checks every **60 seconds** — detects problems fast
- **5-minute cooldown** between actions — no restart loops
- Uses upgrade-guard's **rollback** — full version restore if restart doesn't help
- **Logs everything** to `watchdog.log` for post-mortem
