#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time setup for the OpenClaw Agent Swarm
#
# This script:
#   1. Checks prerequisites (git, tmux, jq, gh, node)
#   2. Creates required directories
#   3. Makes all scripts executable
#   4. Initializes config files (if not present)
#   5. Optionally installs cron jobs
#
# Usage: ./scripts/setup.sh [--with-crons]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_CRONS="${1:-}"

echo "================================================"
echo "  OpenClaw Agent Swarm — Setup"
echo "================================================"
echo ""

ERRORS=0

# --- Check prerequisites ---
echo "[1/5] Checking prerequisites..."

check_cmd() {
    local cmd="$1"
    local purpose="$2"
    local install_hint="$3"

    if command -v "$cmd" &>/dev/null; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        echo "  ✓ $cmd — $version"
    else
        echo "  ✗ $cmd — NOT FOUND ($purpose)"
        echo "    Install: $install_hint"
        ERRORS=$((ERRORS + 1))
    fi
}

check_cmd "git"   "Version control"           "https://git-scm.com/"
check_cmd "tmux"  "Agent session management"   "brew install tmux / apt install tmux"
check_cmd "jq"    "JSON processing"            "brew install jq / apt install jq"
check_cmd "gh"    "GitHub CLI"                 "brew install gh / https://cli.github.com/"
check_cmd "node"  "Orchestrator runtime"       "https://nodejs.org/"
check_cmd "curl"  "Telegram notifications"     "Usually pre-installed"

# Check for at least one coding agent
HAS_AGENT=false
for agent in codex claude gemini; do
    if command -v "$agent" &>/dev/null; then
        echo "  ✓ $agent agent — available"
        HAS_AGENT=true
    fi
done

if [ "$HAS_AGENT" = false ]; then
    echo "  ⚠ No coding agents found (codex, claude, gemini)"
    echo "    Install at least one: Codex CLI or Claude Code CLI"
fi

# Check gh auth
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null 2>&1; then
        echo "  ✓ gh auth — authenticated"
    else
        echo "  ⚠ gh auth — not authenticated. Run: gh auth login"
    fi
fi

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo "  ⚠ $ERRORS required tools missing. Install them and re-run setup."
    echo ""
fi

# --- Create directories ---
echo ""
echo "[2/5] Creating directories..."

DIRS=(
    "$REPO_ROOT/.clawdbot"
    "$REPO_ROOT/.clawdbot/logs"
    "$REPO_ROOT/.clawdbot/prompts"
    "$REPO_ROOT/.clawdbot/learnings"
)

for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "  Created: $dir"
    else
        echo "  Exists:  $dir"
    fi
done

# --- Make scripts executable ---
echo ""
echo "[3/5] Making scripts executable..."

for script in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.js; do
    if [ -f "$script" ]; then
        chmod +x "$script"
        echo "  chmod +x $(basename "$script")"
    fi
done

# --- Initialize config files ---
echo ""
echo "[4/5] Checking configuration files..."

if [ -f "$REPO_ROOT/.clawdbot/config.json" ]; then
    echo "  Config file exists: .clawdbot/config.json"
else
    echo "  Creating default config..."
    echo "  ⚠ Edit .clawdbot/config.json to configure Telegram and agent preferences"
fi

if [ -f "$REPO_ROOT/.clawdbot/active-tasks.json" ]; then
    echo "  Task registry exists: .clawdbot/active-tasks.json"
else
    echo '{"tasks":[],"metadata":{"lastChecked":null,"totalSpawned":0,"totalCompleted":0,"totalFailed":0}}' > "$REPO_ROOT/.clawdbot/active-tasks.json"
    echo "  Created task registry: .clawdbot/active-tasks.json"
fi

# --- Cron jobs ---
echo ""
echo "[5/5] Cron jobs..."

if [ "$INSTALL_CRONS" = "--with-crons" ]; then
    "$SCRIPT_DIR/install-crons.sh"
else
    echo "  Skipped. Run './scripts/install-crons.sh' to install cron jobs."
    echo "  Or re-run setup with: ./scripts/setup.sh --with-crons"
fi

# --- Summary ---
echo ""
echo "================================================"
echo "  Setup Complete!"
echo "================================================"
echo ""
echo "  Quick Start:"
echo "    1. Edit .clawdbot/config.json with your preferences"
echo "    2. Set Telegram credentials (optional):"
echo "       export TELEGRAM_BOT_TOKEN='your-token'"
echo "       export TELEGRAM_CHAT_ID='your-chat-id'"
echo "    3. Spawn your first agent:"
echo "       ./scripts/spawn-agent.sh \\"
echo "         --task-id my-first-task \\"
echo "         --agent codex \\"
echo "         --model gpt-5.3-codex \\"
echo "         --effort high \\"
echo "         --prompt 'Build a hello world feature'"
echo "    4. Monitor agents:"
echo "       ./scripts/check-agents.sh"
echo "    5. Or use the orchestrator:"
echo "       node scripts/orchestrator.js status"
echo ""
echo "  For the full workflow, read the README.md"
echo "================================================"
