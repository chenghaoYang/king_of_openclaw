# King of OpenClaw — Agent Swarm Setup

An AI orchestration system that manages a fleet of coding agents (Codex, Claude Code, Gemini) to build software autonomously. Based on the [OpenClaw + Codex/ClaudeCode Agent Swarm](https://www.linkedin.com/pulse/openclaw-codexclaudecode-agent-swarm-one-person-dev-team-elvis-chidera) architecture.

## Why This Exists

Context windows are zero-sum. Fill it with code — no room for business context. Fill it with customer history — no room for the codebase.

This two-tier system solves that:
- **Zoe (Orchestrator)**: Holds all business context — customer data, meeting notes, past decisions. Translates context into precise prompts.
- **Coding Agents**: See code. Each agent gets exactly the context it needs for its specific task.

Specialization through context, not through different models.

## Architecture

```
You (Human)
  └─→ Zoe (OpenClaw Orchestrator)
        ├─→ Codex Agent  [worktree + tmux] — backend, bugs, refactors (90% of tasks)
        ├─→ Claude Agent  [worktree + tmux] — frontend, git ops, quick fixes
        └─→ Gemini Agent  [design specs]    — UI design → handed to Claude to build
```

Each agent gets:
- Its own **git worktree** (isolated branch, no conflicts between agents)
- Its own **tmux session** (persistent, supports mid-task redirection)
- A **task entry** in `.clawdbot/active-tasks.json` for monitoring

## Quick Start

### Prerequisites

- `git`, `tmux`, `jq`, `node` (v18+), `gh` (GitHub CLI)
- At least one coding agent CLI: `codex` or `claude`
- (Optional) Telegram bot for notifications

### Setup

```bash
git clone https://github.com/chenghaoYang/king_of_openclaw.git
cd king_of_openclaw
./scripts/setup.sh
```

The setup script checks prerequisites, creates directories, and makes scripts executable.

### Spawn Your First Agent

```bash
./scripts/spawn-agent.sh \
  --task-id my-first-feature \
  --description "Build a hello world API endpoint" \
  --agent codex \
  --model gpt-5.3-codex \
  --effort high \
  --prompt "Create a /api/hello endpoint that returns { message: 'Hello World' }. Include tests."
```

This will:
1. Create a git worktree at `../worktrees/my-first-feature`
2. Install dependencies
3. Register the task in `.clawdbot/active-tasks.json`
4. Start a tmux session running the Codex agent

### Monitor Agents

```bash
# Check all running agents
./scripts/check-agents.sh

# Or use the orchestrator CLI
node scripts/orchestrator.js status
```

### Redirect a Running Agent

Don't kill agents that go in the wrong direction — redirect them:

```bash
# Wrong approach? Redirect:
tmux send-keys -t codex-my-first-feature "Stop. Focus on the API layer first, not the UI." Enter

# Need more context?
tmux send-keys -t codex-my-first-feature "The schema is in src/types/template.ts. Use that." Enter
```

### Review a PR

Every PR gets reviewed by three AI models:

```bash
./scripts/review-pr.sh 42 --models codex,claude,gemini
```

- **Codex**: Edge cases, logic errors, race conditions (thorough, low false positive rate)
- **Gemini Code Assist**: Security issues, scalability (free GitHub App)
- **Claude**: Critical issues only (skip "consider adding" overengineering)

## The Full 8-Step Workflow

### Step 1: Customer Request → Scope with Zoe
Talk through the request with Zoe (the orchestrator). She has access to meeting notes, customer data, and past decisions. Zero explanation needed.

### Step 2: Spawn the Agent
Zoe spawns a coding agent with a detailed prompt containing all the business context.

### Step 3: Monitor (Ralph Loop V2)
A cron job runs every 10 minutes to babysit all agents. It's 100% deterministic and token-efficient:
- Checks if tmux sessions are alive
- Checks for open PRs on tracked branches
- Checks CI status via `gh` CLI
- Auto-respawns failed agents (max 3 retries) with improved prompts
- Only alerts if something needs human attention

### Step 4: Agent Creates PR
The agent commits, pushes, and opens a PR. No notification yet — a PR alone isn't done.

### Step 5: Automated Code Review
Three AI reviewers post comments directly on the PR.

### Step 6: CI Pipeline
Lint, TypeScript, unit tests, E2E, Playwright. If UI changed, screenshots required.

### Step 7: Human Review
Telegram notification: "PR #341 ready for review." By this point CI passed, three reviewers approved, screenshots show the changes. 5-10 minute review.

### Step 8: Merge
PR merges. Daily cron cleans up worktrees and task registry.

## Definition of Done

A task is NOT done until ALL of these pass:
- [ ] PR created
- [ ] Branch synced to main (no merge conflicts)
- [ ] CI passing (lint, types, unit tests, E2E)
- [ ] Codex review passed
- [ ] Claude Code review passed
- [ ] Gemini review passed
- [ ] Screenshots included (if UI changes)

## Configuration

Edit `.clawdbot/config.json` to configure:

- **Agent models and preferences**
- **Reviewer settings** (enable/disable each reviewer)
- **Telegram notifications** (bot token, chat ID)
- **CI requirements** (required vs optional checks)
- **Max concurrent agents** and retry limits

### Telegram Setup

1. Create a bot: Talk to [@BotFather](https://t.me/BotFather) on Telegram
2. Get your chat ID: Send a message to your bot, then visit `https://api.telegram.org/bot<token>/getUpdates`
3. Configure:
```bash
export TELEGRAM_BOT_TOKEN='your-token'
export TELEGRAM_CHAT_ID='your-chat-id'
```
Or set in `.clawdbot/config.json` under `notifications.telegram`.

## Orchestrator CLI

```bash
node scripts/orchestrator.js <command>

# Commands:
  status  [filter]              # Show all tasks (filter: running, done, failed)
  spawn   <id> [type] "<prompt>" # Spawn a new agent
  check                          # Run the agent monitor
  review  <pr-number>            # Run code review on a PR
  cleanup                        # Clean up worktrees and archives
  route   <task-type>            # Show which agent handles a task type
  respawn <id> [reason]          # Respawn failed task with improved context
  learn   <id> <outcome> <notes> # Record learnings from a task
```

## Cron Jobs

```bash
# Install monitoring crons
./scripts/install-crons.sh

# What gets installed:
#   Every 10 min:  check-agents.sh (monitor running agents)
#   Daily at 2 AM: cleanup-worktrees.sh (clean up completed tasks)

# Remove crons
./scripts/remove-crons.sh
```

## Agent Selection Guide

| Task Type | Agent | Why |
|-----------|-------|-----|
| Backend logic | Codex | Deep reasoning across codebase |
| Complex bugs | Codex | Thorough analysis |
| Multi-file refactors | Codex | Handles cross-file dependencies |
| Frontend / UI implementation | Claude Code | Faster, fewer permission issues |
| Git operations | Claude Code | Better at git workflows |
| Quick fixes | Claude Code | Speed over depth |
| UI design specs | Gemini | Best design sensibility |

## The Ralph Loop V2

When an agent fails, Zoe doesn't just respawn with the same prompt. She looks at the failure with full business context:

- **Agent ran out of context?** → "Focus only on these three files."
- **Wrong direction?** → "Stop. The customer wanted X, not Y. Here's what they said."
- **Needs clarification?** → "Here's the customer's email and what their company does."

Over time, Zoe writes better prompts because she remembers what shipped. Reward signals: CI passing, all three code reviews passing, human merge. Any failure triggers the loop.

## Directory Structure

```
.clawdbot/
  ├── config.json          — System configuration
  ├── active-tasks.json    — Task registry
  ├── prompts/             — Prompt templates
  ├── learnings/           — Logged patterns (what worked/failed)
  └── logs/                — Agent output logs

scripts/
  ├── setup.sh             — One-time setup
  ├── spawn-agent.sh       — Create worktree + tmux + launch agent
  ├── run-agent.sh         — Run a coding agent with logging
  ├── update-task.sh       — Update task status
  ├── check-agents.sh      — Monitor all agents (Ralph Loop V2)
  ├── review-pr.sh         — Multi-model code review
  ├── cleanup-worktrees.sh — Clean up completed tasks
  ├── telegram-notify.sh   — Telegram notifications (bash)
  ├── telegram-notify.js   — Telegram notifications (node)
  ├── orchestrator.js      — Zoe CLI interface
  ├── install-crons.sh     — Install cron jobs
  └── remove-crons.sh      — Remove cron jobs
```

## License

MIT
