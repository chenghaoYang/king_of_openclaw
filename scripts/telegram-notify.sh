#!/usr/bin/env bash
# =============================================================================
# telegram-notify.sh — Send notifications via Telegram Bot API
#
# Usage: ./scripts/telegram-notify.sh <task-id> <event> [message]
#   task-id: The task identifier or "monitor" for system messages
#   event:   "pr_ready" | "agent_failed" | "ci_failed" | "needs_attention" | "all_done"
#   message: Optional additional context
#
# Configuration: Set in .clawdbot/config.json or via environment variables:
#   TELEGRAM_BOT_TOKEN — Your Telegram bot token
#   TELEGRAM_CHAT_ID   — Your Telegram chat ID
#
# To create a bot: Talk to @BotFather on Telegram
# To get chat ID: Send a message to your bot, then visit:
#   https://api.telegram.org/bot<token>/getUpdates
# =============================================================================

set -euo pipefail

TASK_ID="${1:-system}"
EVENT="${2:-info}"
MESSAGE="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.clawdbot/config.json"

# Load Telegram credentials from config or environment
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ -z "$BOT_TOKEN" ] && [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
    BOT_TOKEN=$(jq -r '.notifications.telegram.botToken // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CHAT_ID=$(jq -r '.notifications.telegram.chatId // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# Check if Telegram is configured
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "[telegram-notify] Not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID."
    echo "[telegram-notify] Or configure in .clawdbot/config.json under notifications.telegram"
    exit 0  # Don't fail — notifications are optional
fi

# Check if notifications are enabled
if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
    ENABLED=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
    if [ "$ENABLED" != "true" ]; then
        echo "[telegram-notify] Notifications disabled in config. Set enabled: true to activate."
        exit 0
    fi
fi

# Build the message based on event type (using real newlines, not \n literals)
case "$EVENT" in
    pr_ready)
        TITLE="PR Ready for Review"
        BODY="Task: ${TASK_ID}
${MESSAGE}

All checks passed. Ready to merge."
        ;;
    agent_failed)
        TITLE="Agent Failed"
        BODY="Task: ${TASK_ID}
${MESSAGE}"
        ;;
    ci_failed)
        TITLE="CI Failed"
        BODY="Task: ${TASK_ID}
${MESSAGE}"
        ;;
    needs_attention)
        TITLE="Needs Human Attention"
        BODY="$MESSAGE"
        ;;
    all_done)
        TITLE="All Tasks Complete"
        BODY="$MESSAGE"
        ;;
    *)
        TITLE="OpenClaw Update"
        BODY="Task: ${TASK_ID}
Event: ${EVENT}
${MESSAGE}"
        ;;
esac

# Format the Telegram message (plain text, no Markdown to avoid parse errors)
TELEGRAM_MSG="${TITLE}

${BODY}

-- OpenClaw Agent Swarm"

# Send via Telegram Bot API using --data-urlencode to handle special characters
RESPONSE=$(curl -s -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${TELEGRAM_MSG}" \
    2>/dev/null || echo '{"ok": false}')

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "[telegram-notify] Message sent successfully."
else
    echo "[telegram-notify] Failed to send message."
    echo "[telegram-notify] Response: $RESPONSE"
fi
