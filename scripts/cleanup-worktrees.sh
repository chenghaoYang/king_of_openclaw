#!/usr/bin/env bash
# =============================================================================
# cleanup-worktrees.sh — Clean up orphaned worktrees and completed task entries
#
# Runs daily via cron to:
#   1. Remove worktrees for completed/cancelled tasks
#   2. Prune stale git worktree references
#   3. Archive completed tasks from active-tasks.json
#   4. Kill orphaned tmux sessions
#
# Usage: ./scripts/cleanup-worktrees.sh [--dry-run]
# =============================================================================

set -euo pipefail

DRY_RUN="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/.clawdbot/active-tasks.json"
CONFIG_FILE="$REPO_ROOT/.clawdbot/config.json"

log() {
    echo "[cleanup $(date +%H:%M:%S)] $*"
}

action() {
    if [ "$DRY_RUN" = "--dry-run" ]; then
        log "  [DRY RUN] Would: $*"
    else
        log "  $*"
    fi
}

log "========================================="
log "  OpenClaw Worktree Cleanup"
log "========================================="

if [ "$DRY_RUN" = "--dry-run" ]; then
    log "  Running in DRY RUN mode — no changes will be made."
    log ""
fi

# Read worktree base
WORKTREE_BASE="$REPO_ROOT/../worktrees"
if command -v jq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
    CONFIGURED_BASE=$(jq -r '.paths.worktreeBase // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$CONFIGURED_BASE" ]; then
        if [[ "$CONFIGURED_BASE" == /* ]]; then
            WORKTREE_BASE="$CONFIGURED_BASE"
        else
            WORKTREE_BASE="$REPO_ROOT/$CONFIGURED_BASE"
        fi
    fi
fi

CLEANED=0
ARCHIVED=0

# --- Step 1: Clean up completed task worktrees ---
log ""
log "[1/4] Cleaning up completed task worktrees..."

if command -v jq &>/dev/null && [ -f "$TASKS_FILE" ]; then
    DONE_TASKS=$(jq -r '.tasks[] | select(.status == "done" or .status == "cancelled") | .id' "$TASKS_FILE" 2>/dev/null || echo "")

    while IFS= read -r TASK_ID; do
        [ -z "$TASK_ID" ] && continue

        WORKTREE_PATH="$WORKTREE_BASE/$TASK_ID"

        if [ -d "$WORKTREE_PATH" ]; then
            action "Remove worktree: $WORKTREE_PATH"
            if [ "$DRY_RUN" != "--dry-run" ]; then
                cd "$REPO_ROOT"
                git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || \
                    rm -rf "$WORKTREE_PATH" 2>/dev/null || true
            fi
            CLEANED=$((CLEANED + 1))
        fi

        # Kill tmux session if still alive
        TMUX_SESSION=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id) | .tmuxSession' "$TASKS_FILE" 2>/dev/null || true)
        if [ -n "$TMUX_SESSION" ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            action "Kill tmux session: $TMUX_SESSION"
            if [ "$DRY_RUN" != "--dry-run" ]; then
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
            fi
        fi
    done <<< "$DONE_TASKS"
else
    log "  jq not found or no tasks file. Skipping task-based cleanup."
fi

# --- Step 2: Prune stale git worktree references ---
log ""
log "[2/4] Pruning stale git worktree references..."

cd "$REPO_ROOT"
if [ "$DRY_RUN" != "--dry-run" ]; then
    git worktree prune 2>/dev/null || true
    log "  Pruned."
else
    action "git worktree prune"
fi

# --- Step 3: Archive completed tasks ---
log ""
log "[3/4] Archiving completed tasks from active-tasks.json..."

if command -v jq &>/dev/null && [ -f "$TASKS_FILE" ]; then
    DONE_COUNT=$(jq '[.tasks[] | select(.status == "done" or .status == "cancelled")] | length' "$TASKS_FILE" 2>/dev/null || echo "0")

    if [ "$DONE_COUNT" -gt 0 ]; then
        action "Archive $DONE_COUNT completed/cancelled tasks"

        if [ "$DRY_RUN" != "--dry-run" ]; then
            # Save archived tasks (merge with existing archive if run multiple times per day)
            ARCHIVE_FILE="$REPO_ROOT/.clawdbot/logs/archived-tasks-$(date +%Y%m%d).json"
            NEW_ARCHIVED=$(jq '[.tasks[] | select(.status == "done" or .status == "cancelled")]' "$TASKS_FILE")
            if [ -f "$ARCHIVE_FILE" ]; then
                jq -s '.[0] + .[1]' "$ARCHIVE_FILE" <(echo "$NEW_ARCHIVED") > "$ARCHIVE_FILE.tmp" && mv "$ARCHIVE_FILE.tmp" "$ARCHIVE_FILE"
            else
                echo "$NEW_ARCHIVED" > "$ARCHIVE_FILE"
            fi

            # Remove completed tasks from active list (atomic write)
            UPDATED=$(jq '.tasks = [.tasks[] | select(.status != "done" and .status != "cancelled")]' "$TASKS_FILE")
            echo "$UPDATED" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"

            ARCHIVED=$DONE_COUNT
            log "  Archived $ARCHIVED tasks to $ARCHIVE_FILE"
        fi
    else
        log "  No completed tasks to archive."
    fi
fi

# --- Step 4: Kill orphaned tmux sessions ---
log ""
log "[4/4] Checking for orphaned tmux sessions..."

ACTIVE_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || echo "")

while IFS= read -r SESSION; do
    [ -z "$SESSION" ] && continue

    # Check if this looks like an agent session (codex-* or claude-*)
    if echo "$SESSION" | grep -qE '^(codex|claude|gemini)-'; then
        # Check if there's a matching active task
        TASK_EXISTS=false
        if command -v jq &>/dev/null && [ -f "$TASKS_FILE" ]; then
            MATCH=$(jq -r --arg s "$SESSION" '.tasks[] | select(.tmuxSession == $s and (.status == "running" or .status == "agent_completed" or .status == "pr_created")) | .id' "$TASKS_FILE" 2>/dev/null || true)
            if [ -n "$MATCH" ]; then
                TASK_EXISTS=true
            fi
        fi

        if [ "$TASK_EXISTS" = false ]; then
            action "Kill orphaned tmux session: $SESSION"
            if [ "$DRY_RUN" != "--dry-run" ]; then
                tmux kill-session -t "$SESSION" 2>/dev/null || true
            fi
        fi
    fi
done <<< "$ACTIVE_SESSIONS"

# --- Summary ---
log ""
log "========================================="
log "  Cleanup Complete"
log "  Worktrees removed: $CLEANED"
log "  Tasks archived: $ARCHIVED"
log "========================================="
