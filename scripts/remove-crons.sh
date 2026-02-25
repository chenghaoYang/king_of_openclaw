#!/usr/bin/env bash
# =============================================================================
# remove-crons.sh — Remove OpenClaw cron jobs
#
# Usage: ./scripts/remove-crons.sh
# =============================================================================

set -euo pipefail

MARKER="# OpenClaw Agent Swarm"

echo "Removing OpenClaw cron jobs..."

EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
CLEANED_CRON=$(echo "$EXISTING_CRON" | grep -v "$MARKER" | grep -v "check-agents.sh" | grep -v "cleanup-worktrees.sh" || true)

if [ -z "$CLEANED_CRON" ]; then
    crontab -r 2>/dev/null || true
else
    echo "$CLEANED_CRON" | crontab -
fi

echo "OpenClaw cron jobs removed."
