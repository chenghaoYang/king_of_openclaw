#!/usr/bin/env bash
# =============================================================================
# install-crons.sh — Install cron jobs for the OpenClaw agent swarm
#
# Cron jobs:
#   1. Every 10 minutes: check-agents.sh (monitor running agents)
#   2. Daily at 2 AM: cleanup-worktrees.sh (clean up completed tasks)
#
# Usage: ./scripts/install-crons.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Installing OpenClaw cron jobs..."

# Marker to identify our cron entries
MARKER="# OpenClaw Agent Swarm"

# Build cron entries
CRON_ENTRIES="
$MARKER — Agent Monitor (every 10 min)
*/10 * * * * cd $REPO_ROOT && ./scripts/check-agents.sh >> .clawdbot/logs/monitor.log 2>&1
$MARKER — Daily Cleanup (2 AM)
0 2 * * * cd $REPO_ROOT && ./scripts/cleanup-worktrees.sh >> .clawdbot/logs/cleanup.log 2>&1
"

# Remove existing OpenClaw entries and add new ones
EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
CLEANED_CRON=$(echo "$EXISTING_CRON" | grep -v "$MARKER" | grep -v "check-agents.sh" | grep -v "cleanup-worktrees.sh" || true)

echo "$CLEANED_CRON
$CRON_ENTRIES" | crontab -

echo "Cron jobs installed successfully!"
echo ""
echo "Installed cron jobs:"
echo "  - Agent monitor: every 10 minutes"
echo "  - Worktree cleanup: daily at 2:00 AM"
echo ""
echo "View with:   crontab -l"
echo "Remove with: ./scripts/remove-crons.sh"
