#!/usr/bin/env bash
# =============================================================================
# remove-crons.sh — Remove OpenClaw cron jobs
#
# Usage: ./scripts/remove-crons.sh
# =============================================================================

set -euo pipefail

# Must match the marker used in install-crons.sh
MARKER="# OPENCLAW_AGENT_SWARM"

echo "Removing OpenClaw cron jobs..."

EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")

# Only remove lines matching our specific marker
CLEANED_CRON=$(echo "$EXISTING_CRON" | grep -v "$MARKER" || true)

# Also remove the actual cron command lines that follow our markers
# (they reference our repo scripts and are on the lines after the marker)
CLEANED_CRON=$(echo "$CLEANED_CRON" | grep -v "scripts/check-agents.sh.*monitor.log" | grep -v "scripts/cleanup-worktrees.sh.*cleanup.log" || true)

if [ -z "$(echo "$CLEANED_CRON" | tr -d '[:space:]')" ]; then
    crontab -r 2>/dev/null || true
else
    echo "$CLEANED_CRON" | crontab -
fi

echo "OpenClaw cron jobs removed."
