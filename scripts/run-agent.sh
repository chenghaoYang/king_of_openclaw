#!/usr/bin/env bash
# =============================================================================
# run-agent.sh — Launch a coding agent (Codex, Claude Code, or Gemini) with full logging
#
# Usage: ./scripts/run-agent.sh <task-id> <agent-type> <model> <effort> "<prompt>"
#   task-id:    Unique identifier for the task (e.g., "custom-templates")
#   agent-type: "codex" | "claude" | "gemini"
#   model:      Model to use (e.g., "gpt-5.3-codex", "claude-opus-4.5")
#   effort:     Reasoning effort: "low" | "medium" | "high"
#   prompt:     The full prompt for the agent (in quotes)
#
# Example:
#   ./scripts/run-agent.sh templates codex gpt-5.3-codex high "Build a template system..."
# =============================================================================

set -euo pipefail

TASK_ID="${1:?Usage: run-agent.sh <task-id> <agent-type> <model> <effort> <prompt>}"
AGENT_TYPE="${2:?Missing agent type (codex|claude|gemini)}"
MODEL="${3:?Missing model name}"
EFFORT="${4:?Missing reasoning effort (low|medium|high)}"
PROMPT="${5:?Missing prompt}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/.clawdbot/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/${TASK_ID}-${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

echo "========================================" | tee "$LOG_FILE"
echo "Agent: $AGENT_TYPE | Model: $MODEL | Effort: $EFFORT" | tee -a "$LOG_FILE"
echo "Task: $TASK_ID" | tee -a "$LOG_FILE"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

run_codex() {
    codex --model "$MODEL" \
        -c "model_reasoning_effort=$EFFORT" \
        --dangerously-bypass-approvals-and-sandbox \
        "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
}

run_claude() {
    # Note: Claude Code CLI does not support a reasoning effort parameter.
    # The $EFFORT variable is only used by Codex.
    claude --model "$MODEL" \
        --dangerously-skip-permissions \
        -p "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
}

run_gemini() {
    # Gemini CLI (gemini-cli) for design specs and code generation
    if command -v gemini &>/dev/null; then
        gemini --model "$MODEL" \
            -p "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
    elif command -v gemini-cli &>/dev/null; then
        gemini-cli --model "$MODEL" \
            -p "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
    else
        # Fallback: use the Gemini REST API via curl
        echo "[Gemini] No gemini CLI found. Attempting API fallback..." | tee -a "$LOG_FILE"

        GEMINI_API_KEY="${GEMINI_API_KEY:-}"
        if [ -z "$GEMINI_API_KEY" ]; then
            echo "[Gemini] ERROR: No gemini CLI and no GEMINI_API_KEY set." | tee -a "$LOG_FILE"
            echo "[Gemini] Install gemini-cli or set GEMINI_API_KEY env var." | tee -a "$LOG_FILE"
            return 1
        fi

        API_MODEL="${MODEL:-gemini-2.5-pro}"
        RESPONSE=$(curl -s -X POST \
            "https://generativelanguage.googleapis.com/v1beta/models/${API_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg prompt "$PROMPT" '{contents: [{parts: [{text: $prompt}]}]}')" 2>&1)

        if echo "$RESPONSE" | jq -e '.candidates[0].content.parts[0].text' &>/dev/null; then
            echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text' | tee -a "$LOG_FILE"
        else
            echo "[Gemini] API call failed:" | tee -a "$LOG_FILE"
            echo "$RESPONSE" | tee -a "$LOG_FILE"
            return 1
        fi
    fi
}

EXIT_CODE=0

case "$AGENT_TYPE" in
    codex)
        run_codex || EXIT_CODE=$?
        ;;
    claude)
        run_claude || EXIT_CODE=$?
        ;;
    gemini)
        run_gemini || EXIT_CODE=$?
        ;;
    *)
        echo "ERROR: Unknown agent type '$AGENT_TYPE'. Use: codex | claude | gemini" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG_FILE"
echo "Exit code: $EXIT_CODE" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"

# Update task status based on exit code
if [ $EXIT_CODE -eq 0 ]; then
    "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "agent_completed"
else
    "$SCRIPT_DIR/update-task.sh" "$TASK_ID" "agent_failed" "exit_code=$EXIT_CODE"
fi

exit $EXIT_CODE
