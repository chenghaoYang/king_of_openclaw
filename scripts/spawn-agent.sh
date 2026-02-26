#!/usr/bin/env bash
# =============================================================================
# spawn-agent.sh — Create a worktree, start a tmux session, and launch an agent
#
# This is the main entry point for spawning a new coding agent. It:
#   1. Creates an isolated git worktree for the task
#   2. Installs dependencies in the worktree
#   3. Starts a tmux session for the agent
#   4. Registers the task in .clawdbot/active-tasks.json
#   5. Launches the agent inside the tmux session
#
# Usage:
#   ./scripts/spawn-agent.sh \
#     --task-id <id> \
#     --description "<description>" \
#     --agent <codex|claude|gemini> \
#     --model <model-name> \
#     --effort <low|medium|high> \
#     --prompt "<prompt>" \
#     [--branch <branch-name>] \
#     [--base <base-branch>] \
#     [--no-install] \
#     [--use-template]            # Fill agent prompt template with --prompt as task description
#     [--context "<context>"]     # Business context (fills {{BUSINESS_CONTEXT}})
#     [--files "<files>"]         # Files to focus on (fills {{RELEVANT_FILES}})
#     [--constraints "<text>"]    # Constraints (fills {{CONSTRAINTS}})
#
# Example:
#   ./scripts/spawn-agent.sh \
#     --task-id custom-templates \
#     --description "Custom email templates for agency customer" \
#     --agent codex \
#     --model gpt-5.3-codex \
#     --effort high \
#     --prompt "Build a template system that lets users save and edit configurations..."
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.clawdbot/config.json"
TASKS_FILE="$REPO_ROOT/.clawdbot/active-tasks.json"

# Default values
TASK_ID=""
DESCRIPTION=""
AGENT_TYPE=""
MODEL=""
EFFORT="high"
PROMPT=""
BRANCH=""
BASE_BRANCH="origin/main"
SKIP_INSTALL=false
USE_TEMPLATE=false
CONTEXT=""
FILES=""
CONSTRAINTS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --task-id)     TASK_ID="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --agent)       AGENT_TYPE="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --effort)      EFFORT="$2"; shift 2 ;;
        --prompt)      PROMPT="$2"; shift 2 ;;
        --branch)      BRANCH="$2"; shift 2 ;;
        --base)        BASE_BRANCH="$2"; shift 2 ;;
        --no-install)  SKIP_INSTALL=true; shift ;;
        --use-template) USE_TEMPLATE=true; shift ;;
        --context)     CONTEXT="$2"; shift 2 ;;
        --files)       FILES="$2"; shift 2 ;;
        --constraints) CONSTRAINTS="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required args
if [ -z "$TASK_ID" ] || [ -z "$AGENT_TYPE" ] || [ -z "$PROMPT" ]; then
    echo "ERROR: --task-id, --agent, and --prompt are required."
    echo "Usage: spawn-agent.sh --task-id <id> --agent <type> --prompt '<prompt>'"
    exit 1
fi

# Defaults
BRANCH="${BRANCH:-feat/$TASK_ID}"
DESCRIPTION="${DESCRIPTION:-Task $TASK_ID}"

# --- Template substitution ---
# If --use-template is set, load the agent-specific prompt template and fill in placeholders.
# Otherwise, use the raw --prompt value as-is.
if [ "$USE_TEMPLATE" = true ]; then
    TEMPLATE_FILE="$REPO_ROOT/.clawdbot/prompts/agent-${AGENT_TYPE}.md"
    if [ -f "$TEMPLATE_FILE" ]; then
        echo "[template] Loading prompt template from $TEMPLATE_FILE"
        TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE")

        # Substitute placeholders using simple string replacement
        TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{TASK_DESCRIPTION\}\}/$PROMPT}"
        TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{BUSINESS_CONTEXT\}\}/${CONTEXT:-No additional context provided.}}"
        TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{RELEVANT_FILES\}\}/${FILES:-Agent should discover relevant files.}}"
        TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{CONSTRAINTS\}\}/${CONSTRAINTS:-No special constraints.}}"

        PROMPT="$TEMPLATE_CONTENT"
        echo "[template] Template applied successfully."
    else
        echo "[template] WARNING: Template not found at $TEMPLATE_FILE — using raw prompt."
    fi
fi
TMUX_SESSION="${AGENT_TYPE}-${TASK_ID}"

# Read worktree base from config, fallback to ../worktrees
WORKTREE_BASE="$REPO_ROOT/../worktrees"
if command -v jq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
    CONFIGURED_BASE=$(jq -r '.paths.worktreeBase // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$CONFIGURED_BASE" ]; then
        # Resolve relative paths from repo root
        if [[ "$CONFIGURED_BASE" == /* ]]; then
            WORKTREE_BASE="$CONFIGURED_BASE"
        else
            WORKTREE_BASE="$REPO_ROOT/$CONFIGURED_BASE"
        fi
    fi
fi

WORKTREE_PATH="$WORKTREE_BASE/$TASK_ID"

echo "================================================"
echo "  OpenClaw Agent Spawner"
echo "================================================"
echo "Task ID:    $TASK_ID"
echo "Agent:      $AGENT_TYPE"
echo "Model:      ${MODEL:-default}"
echo "Effort:     $EFFORT"
echo "Branch:     $BRANCH"
echo "Base:       $BASE_BRANCH"
echo "Worktree:   $WORKTREE_PATH"
echo "tmux:       $TMUX_SESSION"
echo "================================================"

# --- Step 1: Create git worktree ---
echo ""
echo "[1/5] Creating git worktree..."

if [ -d "$WORKTREE_PATH" ]; then
    echo "  Worktree already exists at $WORKTREE_PATH. Reusing."
else
    mkdir -p "$(dirname "$WORKTREE_PATH")"
    cd "$REPO_ROOT"
    git fetch origin 2>/dev/null || true
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH" 2>/dev/null || \
        git worktree add "$WORKTREE_PATH" "$BRANCH" 2>/dev/null || \
        { echo "ERROR: Failed to create worktree."; exit 1; }
    echo "  Worktree created at $WORKTREE_PATH"
fi

# --- Step 2: Install dependencies ---
echo ""
echo "[2/5] Installing dependencies..."

if [ "$SKIP_INSTALL" = true ]; then
    echo "  Skipped (--no-install flag)"
else
    cd "$WORKTREE_PATH"
    if [ -f "package-lock.json" ]; then
        npm install --silent 2>/dev/null || echo "  npm install completed (with warnings)"
    elif [ -f "pnpm-lock.yaml" ]; then
        pnpm install --silent 2>/dev/null || echo "  pnpm install completed (with warnings)"
    elif [ -f "yarn.lock" ]; then
        yarn install --silent 2>/dev/null || echo "  yarn install completed (with warnings)"
    elif [ -f "package.json" ]; then
        npm install --silent 2>/dev/null || echo "  npm install completed (with warnings)"
    else
        echo "  No package manager lockfile found. Skipping install."
    fi
fi

# --- Step 3: Register the task ---
echo ""
echo "[3/5] Registering task in active-tasks.json..."

NOW_MS=$(date +%s)000

if command -v jq &>/dev/null; then
    # Build JSON safely with jq --arg to prevent injection from special characters
    TASK_JSON=$(jq -n \
        --arg id "$TASK_ID" \
        --arg tmux "$TMUX_SESSION" \
        --arg agent "$AGENT_TYPE" \
        --arg model "${MODEL:-default}" \
        --arg desc "$DESCRIPTION" \
        --arg repo "$(basename "$REPO_ROOT")" \
        --arg worktree "$TASK_ID" \
        --arg branch "$BRANCH" \
        --arg prompt "$PROMPT" \
        --argjson started "$NOW_MS" \
        '{
            id: $id,
            tmuxSession: $tmux,
            agent: $agent,
            model: $model,
            description: $desc,
            repo: $repo,
            worktree: $worktree,
            branch: $branch,
            prompt: $prompt,
            startedAt: $started,
            status: "running",
            retryCount: 0,
            notifyOnComplete: true
        }')

    # Atomic write: write to tmp then rename to prevent corruption
    UPDATED=$(jq --argjson task "$TASK_JSON" '
        .tasks += [$task] |
        .metadata.totalSpawned += 1 |
        .metadata.lastChecked = (now * 1000 | floor)
    ' "$TASKS_FILE")
    echo "$UPDATED" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
else
    echo "  WARNING: jq not found. Task not registered in JSON. Install jq for full functionality."
fi

echo "  Task registered: $TASK_ID"

# --- Step 4: Start tmux session ---
echo ""
echo "[4/5] Starting tmux session: $TMUX_SESSION"

# Kill existing session if it exists
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Build the agent command with proper escaping via printf %q
AGENT_CMD=$(printf '%q %q %q %q %q %q' \
    "$SCRIPT_DIR/run-agent.sh" "$TASK_ID" "$AGENT_TYPE" "${MODEL:-default}" "$EFFORT" "$PROMPT")

# Create tmux session and run the agent
tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_PATH" "bash -c $AGENT_CMD"

echo "  tmux session started. Attach with: tmux attach -t $TMUX_SESSION"

# --- Step 5: Confirm ---
echo ""
echo "[5/5] Agent spawned successfully!"
echo ""
echo "================================================"
echo "  Agent is running in tmux session: $TMUX_SESSION"
echo ""
echo "  Useful commands:"
echo "    tmux attach -t $TMUX_SESSION       # Watch the agent"
echo "    tmux send-keys -t $TMUX_SESSION 'Redirect message' Enter  # Redirect"
echo "    tmux kill-session -t $TMUX_SESSION  # Kill the agent"
echo ""
echo "    ./scripts/check-agents.sh           # Check all agents"
echo "================================================"
