#!/usr/bin/env bash
# =============================================================================
# update-task.sh — Update a task's status in active-tasks.json
#
# Usage: ./scripts/update-task.sh <task-id> <new-status> [note]
#   task-id:    The task identifier
#   new-status: "running" | "agent_completed" | "agent_failed" | "pr_created" |
#               "ci_passed" | "ci_failed" | "review_passed" | "done" | "cancelled"
#   note:       Optional note (e.g., "exit_code=1", "PR #341")
# =============================================================================

set -euo pipefail

TASK_ID="${1:?Usage: update-task.sh <task-id> <status> [note]}"
NEW_STATUS="${2:?Usage: update-task.sh <task-id> <status> [note]}"
NOTE="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/.clawdbot/active-tasks.json"

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for task management. Install it with: brew install jq"
    exit 1
fi

if [ ! -f "$TASKS_FILE" ]; then
    echo "ERROR: Tasks file not found at $TASKS_FILE"
    exit 1
fi

NOW_MS=$(date +%s)000

# Update the task (using consistent millisecond timestamps)
UPDATED=$(jq --arg id "$TASK_ID" --arg status "$NEW_STATUS" --arg note "$NOTE" --argjson now "$NOW_MS" '
    .tasks = [
        .tasks[] |
        if .id == $id then
            .status = $status |
            .lastUpdated = $now |
            if $note != "" then .note = $note else . end |
            if $status == "done" or $status == "agent_completed" then .completedAt = $now else . end |
            if $status == "agent_failed" then .retryCount = ((.retryCount // 0) + 1) else . end
        else .
        end
    ] |
    .metadata.lastChecked = (now * 1000 | floor) |
    if $status == "done" then .metadata.totalCompleted += 1 else . end |
    if $status == "agent_failed" then .metadata.totalFailed += 1 else . end
' "$TASKS_FILE")

# Atomic write: write to tmp then rename
echo "$UPDATED" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
echo "Task '$TASK_ID' updated to status: $NEW_STATUS"

# Trigger notification for important status changes
case "$NEW_STATUS" in
    done|agent_failed|ci_failed)
        if [ -f "$SCRIPT_DIR/telegram-notify.sh" ]; then
            "$SCRIPT_DIR/telegram-notify.sh" "$TASK_ID" "$NEW_STATUS" "$NOTE" &
        fi
        ;;
esac
