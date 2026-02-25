# OpenClaw Agent Swarm — Project Context

## What is this?

This is an AI agent orchestration system (code-named "OpenClaw") that manages a fleet of coding agents (Codex, Claude Code, Gemini) to build software autonomously. The orchestrator (Zoe) spawns agents, writes their prompts, picks the right model for each task, monitors progress, and notifies the human when PRs are ready.

## Architecture

```
Human (you)
  └─→ Zoe (AI Orchestrator / OpenClaw)
        ├─→ Codex Agent (worktree + tmux) — backend, bugs, refactors
        ├─→ Claude Code Agent (worktree + tmux) — frontend, git ops
        └─→ Gemini Agent (design specs) — UI design → handed to Claude
```

Two-tier system: Zoe holds business context. Agents hold code context. Context windows are zero-sum — this separation is the key insight.

## Directory Structure

```
.clawdbot/
  ├── config.json          — System configuration (agents, reviewers, notifications)
  ├── active-tasks.json    — Task registry (running, completed, failed tasks)
  ├── prompts/             — Prompt templates for agents and reviewers
  │   ├── system-prompt-zoe.md
  │   ├── agent-codex.md
  │   ├── agent-claude.md
  │   ├── review-codex.md
  │   └── review-claude.md
  ├── learnings/           — Logged patterns from successful/failed tasks
  └── logs/                — Agent output logs and archives

scripts/
  ├── setup.sh             — One-time setup
  ├── spawn-agent.sh       — Create worktree + tmux + launch agent
  ├── run-agent.sh         — Run a coding agent with logging
  ├── update-task.sh       — Update task status in registry
  ├── check-agents.sh      — Monitor all agents (Ralph Loop V2)
  ├── review-pr.sh         — Multi-model code review
  ├── cleanup-worktrees.sh — Clean up completed task worktrees
  ├── telegram-notify.sh   — Bash Telegram notifications
  ├── telegram-notify.js   — Node.js Telegram notifications
  ├── orchestrator.js      — Zoe CLI interface
  ├── install-crons.sh     — Install monitoring cron jobs
  └── remove-crons.sh      — Remove cron jobs
```

## Key Concepts

- **Worktrees**: Each agent gets an isolated git worktree (branch). This prevents agents from conflicting with each other.
- **tmux sessions**: Agents run in tmux for persistent sessions and mid-task redirection.
- **Task registry**: `.clawdbot/active-tasks.json` tracks all active, completed, and failed tasks.
- **Ralph Loop V2**: When an agent fails, Zoe doesn't just respawn with the same prompt — she analyzes the failure and writes a better prompt.
- **Definition of Done**: A task isn't done until: PR created, CI passes, 3 AI reviews pass, screenshots included (if UI).
- **Learnings**: Successful patterns are logged so prompts improve over time.

## Agent Selection Guide

- **Codex**: Backend logic, complex bugs, multi-file refactors, deep reasoning. 90% of tasks.
- **Claude Code**: Frontend work, git operations, quick fixes. Faster.
- **Gemini**: UI design specs. Generate HTML/CSS, then hand to Claude to implement.

## Commands

```bash
# Setup
./scripts/setup.sh

# Spawn an agent
./scripts/spawn-agent.sh --task-id <id> --agent codex --prompt "<prompt>"

# Monitor agents
./scripts/check-agents.sh

# Review a PR
./scripts/review-pr.sh <pr-number>

# Orchestrator CLI
node scripts/orchestrator.js status
node scripts/orchestrator.js spawn <id> codex "<prompt>"
node scripts/orchestrator.js check
node scripts/orchestrator.js review <pr>
node scripts/orchestrator.js cleanup
```
