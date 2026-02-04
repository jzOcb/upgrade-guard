# Upgrade Guard 🔄

[![OpenClaw Skill](https://img.shields.io/badge/OpenClaw-Skill-blue)](https://clawdhub.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)](./SKILL.md)

## 再也不会因为升级搞挂一个好好的 OpenClaw。

> 源于一次版本升级导致的 7 个连锁故障。

网关崩了，Telegram 断了，插件坏了，模型没了——而制造这些问题的 AI agent 也跟着挂了，远程没法修。

这个 skill 让升级变安全。

## 问题

OpenClaw 升级可能以各种看不见的方式炸掉：

- **插件改名** — `clawdbot.plugin.json` → `openclaw.plugin.json`
- **依赖崩了** — SDK 模块路径变了，exports 变了
- **配置 schema 变了** — 新增必填字段、删除旧字段
- **模型名格式变了** — 点号 vs 连字符
- **频道配置被吞** — 迁移过程中被静默删除

一个 `git pull && pnpm install` 就能同时触发以上所有问题。

## 快速开始

```bash
# 安装
clawdhub install upgrade-guard
# 或者: git clone https://github.com/jzOcb/upgrade-guard

# 升级前：给当前系统拍快照
bash scripts/upgrade-guard.sh snapshot

# 检查有什么更新
bash scripts/upgrade-guard.sh check

# 安全升级（失败自动回滚）
bash scripts/upgrade-guard.sh upgrade

# 出问题了？紧急回滚
bash scripts/upgrade-guard.sh rollback
```

## 命令

| 命令 | 功能 |
|---|---|
| `snapshot` | 保存当前状态（版本、配置、插件、依赖、符号链接） |
| `check` | 升级前检查（磁盘、git、配置、breaking change 检测） |
| `upgrade` | 完整安全升级：快照 → 检查 → pull → install → build → 验证 |
| `upgrade --dry-run` | 只预览不改动 |
| `verify` | 升级后验证（插件、频道、模型、网关、日志） |
| `rollback` | 紧急恢复到上一个快照 |
| `status` | 显示当前状态 vs 快照 |

## 检查项

**升级前：**
- 快照是否存在
- 配置文件是否有效
- Git 仓库是否干净
- 磁盘空间是否充足
- 新提交中是否有 breaking change 信号

**升级后：**
- 插件文件是否被改名/删除（检测 clawdbot↔openclaw 改名）
- 配置是否仍然有效，频道是否还在
- 模型是否还在
- 有没有断掉的符号链接
- 网关能否启动并响应
- 最近日志有没有错误

## 配合 config-guard 使用

| | config-guard | upgrade-guard |
|---|---|---|
| 配置验证 | ✅ | ❌ |
| 插件改名检测 | ❌ | ✅ |
| 依赖崩溃检测 | ❌ | ✅ |
| 版本追踪 | ❌ | ✅ |
| Git 状态管理 | ❌ | ✅ |
| 全系统回滚 | ❌ | ✅ |

最佳搭配：改配置用 config-guard，升级版本用 upgrade-guard。

## 依赖

- `bash` 4+, `python3`, `curl`, `git`, `pnpm` 或 `npm`

## 相关项目

- [config-guard](https://github.com/jzOcb/config-guard) — 配置验证和自动回滚
- [agent-guardrails](https://github.com/jzOcb/agent-guardrails) — AI agent 代码行为的机械化约束

## 许可

MIT
