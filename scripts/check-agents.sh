#!/usr/bin/env bash
# =============================================================================
# check-agents.sh — Monitor all running agents (The Ralph Loop V2)
#
# This script is 100% deterministic and extremely token-efficient.
# It runs every 10 minutes via cron to babysit all agents.
#
# It does NOT poll agents directly (that would be expensive). Instead it:
#   - Checks if tmux sessions are alive
#   - Checks for open PRs on tracked branches
#   - Checks CI status via gh cli
#   - Auto-respawns failed agents (max 3 retries)
#   - Only alerts if something needs human attention
#
# Usage: ./scripts/check-agents.sh [--verbose]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$REPO_ROOT/.clawdbot/active-tasks.json"
CONFIG_FILE="$REPO_ROOT/.clawdbot/config.json"
VERBOSE="${1:-}"

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

verbose() {
    if [ "$VERBOSE" = "--verbose" ]; then
        log "$*"
    fi
}

# --- Preflight checks ---
if ! command -v jq &>/dev/null; then
    log "ERROR: jq is required. Install with: brew install jq / apt install jq"
    exit 1
fi

if [ ! -f "$TASKS_FILE" ]; then
    log "No active-tasks.json found. Nothing to check."
    exit 0
fi

MAX_RETRIES=3
if [ -f "$CONFIG_FILE" ]; then
    MAX_RETRIES=$(jq -r '.orchestrator.maxRetries // 3' "$CONFIG_FILE")
fi

# --- Load tasks ---
RUNNING_TASKS=$(jq -r '.tasks[] | select(.status == "running" or .status == "agent_completed" or .status == "pr_created") | .id' "$TASKS_FILE")

if [ -z "$RUNNING_TASKS" ]; then
    verbose "No active tasks to monitor."
    exit 0
fi

NEEDS_ATTENTION=()
SUMMARY=()

log "========================================="
log "  OpenClaw Agent Monitor"
log "========================================="

while IFS= read -r TASK_ID; do
    [ -z "$TASK_ID" ] && continue

    TASK=$(jq --arg id "$TASK_ID" '.tasks[] | select(.id == $id)' "$TASKS_FILE")
    TMUX_SESSION=$(echo "$TASK" | jq -r '.tmuxSession')
    BRANCH=$(echo "$TASK" | jq -r '.branch')
    STATUS=$(echo "$TASK" | jq -r '.status')
    RETRY_COUNT=$(echo "$TASK" | jq -r '.retryCount // 0')
    RETRY_COUNT="${RETRY_COUNT:-0}"
    DESCRIPTION=$(echo "$TASK" | jq -r '.description')

    log ""
    log "--- Task: $TASK_ID ($STATUS) ---"
    log "    $DESCRIPTION"

    # --- Check 1: Is the tmux session alive? ---
    TMUX_ALIVE=false
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_ALIVE=true
        verbose "    tmux session '$TMUX_SESSION' is alive"
    else
        verbose "    tmux session '$TMUX_SESSION' is dead"
    fi

    # --- Check 2: Does a PR exist for this branch? ---
    PR_NUMBER=""
    PR_STATE=""
    if command -v gh &>/dev/null; then
        PR_INFO=$(gh pr list --head "$BRANCH" --json number,state --limit 1 2>/dev/null || echo "[]")
        PR_NUMBER=$(echo "$PR_INFO" | jq -r '.[0].number // empty' 2>/dev/null || true)
        PR_STATE=$(echo "$PR_INFO" | jq -r '.[0].state // empty' 2>/dev/null || true)
    fi

    if [ -n "$PR_NUMBER" ]; then
        log "    PR #$PR_NUMBER ($PR_STATE)"

        # --- Check 3: CI status ---
        CI_STATUS="unknown"
        if command -v gh &>/dev/null; then
            CI_STATUS=$(gh pr checks "$PR_NUMBER" --json state --jq '.[].state' 2>/dev/null | sort -u | tr '\n' ',' || echo "unknown")
            CI_STATUS="${CI_STATUS%,}" # trim trailing comma
        fi

        log "    CI: $CI_STATUS"

        # --- Check 4: Review status ---
        REVIEW_STATUS="pending"
        if command -v gh &>/dev/null; then
            REVIEWS=$(gh pr view "$PR_NUMBER" --json reviews --jq '.reviews[].state' 2>/dev/null | sort -u | tr '\n' ',' || echo "")
            REVIEWS="${REVIEWS%,}"
            if [ -n "$REVIEWS" ]; then
                REVIEW_STATUS="$REVIEWS"
            fi
        fi

        log "    Reviews: $REVIEW_STATUS"

        # --- Decision logic ---
        if echo "$CI_STATUS" | grep -qi "SUCCESS\|PASS"; then
            if echo "$CI_STATUS" | grep -qi "FAILURE\|FAIL"; then
                # Mixed results
                log "    ACTION: CI has failures. Needs investigation."
                NEEDS_ATTENTION+=("$TASK_ID: CI partially failing on PR #$PR_NUMBER")
            else
                # All CI passed
                "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "ci_passed" "PR #$PR_NUMBER" 2>/dev/null || true

                # Check if all reviews are in
                if echo "$REVIEW_STATUS" | grep -qi "APPROVED"; then
                    log "    READY: All checks passed! PR #$PR_NUMBER ready for human review."
                    "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "done" "PR #$PR_NUMBER — all checks passed" 2>/dev/null || true
                    SUMMARY+=("READY: $TASK_ID — PR #$PR_NUMBER ready for merge")
                else
                    log "    WAITING: CI passed, awaiting reviews."
                    SUMMARY+=("WAITING: $TASK_ID — PR #$PR_NUMBER CI passed, reviews pending")
                fi
            fi
        elif echo "$CI_STATUS" | grep -qi "FAILURE\|FAIL"; then
            log "    FAILED: CI failed on PR #$PR_NUMBER"
            "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "ci_failed" "PR #$PR_NUMBER" 2>/dev/null || true

            # Auto-respawn if under retry limit
            if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
                log "    RESPAWN: Retry $((RETRY_COUNT + 1))/$MAX_RETRIES"
                NEEDS_ATTENTION+=("$TASK_ID: CI failed, auto-respawning (retry $((RETRY_COUNT + 1)))")
                # The orchestrator (Zoe) handles the actual respawn with improved prompts
            else
                log "    BLOCKED: Max retries ($MAX_RETRIES) reached. Needs human attention."
                NEEDS_ATTENTION+=("$TASK_ID: CI failed after $MAX_RETRIES retries. Needs human help.")
            fi
        else
            verbose "    CI still running or status unknown."
            SUMMARY+=("RUNNING: $TASK_ID — PR #$PR_NUMBER, CI in progress")
        fi

    elif [ "$TMUX_ALIVE" = false ] && [ "$STATUS" = "running" ]; then
        # No PR and tmux is dead — agent crashed or finished without creating PR
        log "    ISSUE: Agent finished but no PR found."

        if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
            log "    RESPAWN: Will retry ($((RETRY_COUNT + 1))/$MAX_RETRIES)"
            "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "agent_failed" "No PR created, tmux dead" 2>/dev/null || true
            NEEDS_ATTENTION+=("$TASK_ID: Agent died without creating PR. Retry $((RETRY_COUNT + 1)).")
        else
            log "    BLOCKED: Max retries reached. Needs human attention."
            "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "agent_failed" "Max retries exceeded" 2>/dev/null || true
            NEEDS_ATTENTION+=("$TASK_ID: Agent failed after $MAX_RETRIES attempts. Needs human help.")
        fi

    elif [ "$TMUX_ALIVE" = true ]; then
        verbose "    Agent still working (tmux alive, no PR yet)."
        SUMMARY+=("RUNNING: $TASK_ID — agent working, no PR yet")
    fi

done <<< "$RUNNING_TASKS"

# --- Summary ---
log ""
log "========================================="
log "  Summary"
log "========================================="

if [ ${#SUMMARY[@]} -gt 0 ]; then
    for s in "${SUMMARY[@]}"; do
        log "  $s"
    done
fi

if [ ${#NEEDS_ATTENTION[@]} -gt 0 ]; then
    log ""
    log "  *** NEEDS HUMAN ATTENTION ***"
    for a in "${NEEDS_ATTENTION[@]}"; do
        log "  ! $a"
    done

    # Send Telegram notification
    if [ -f "$SCRIPT_DIR/telegram-notify.sh" ]; then
        ATTENTION_MSG=$(printf '%s\n' "${NEEDS_ATTENTION[@]}")
        "$SCRIPT_DIR/telegram-notify.sh" "monitor" "needs_attention" "$ATTENTION_MSG" &
    fi
else
    log ""
    log "  All agents running normally."
fi

log ""
log "========================================="

# Update last checked timestamp
if [ -f "$TASKS_FILE" ]; then
    jq '.metadata.lastChecked = (now * 1000 | floor)' "$TASKS_FILE" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
fi
