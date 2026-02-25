#!/usr/bin/env bash
# =============================================================================
# review-pr.sh — Run automated code review on a PR with multiple AI models
#
# Every PR gets reviewed by three AI models. They catch different things:
#   - Codex:  Edge cases, logic errors, race conditions (thorough, low false positive)
#   - Gemini: Security issues, scalability problems (free via GitHub App)
#   - Claude: Critical issues only (skip "consider adding" suggestions)
#
# Usage: ./scripts/review-pr.sh <pr-number> [--models codex,claude,gemini]
# =============================================================================

set -euo pipefail

PR_NUMBER="${1:?Usage: review-pr.sh <pr-number> [--models codex,claude,gemini]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/.clawdbot/prompts"
CONFIG_FILE="$REPO_ROOT/.clawdbot/config.json"

# Parse optional --models flag
MODELS="codex,claude"
while [[ $# -gt 0 ]]; do
    case $1 in
        --models) MODELS="${2:?--models requires a value}"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Read reviewer models from config (with fallbacks)
CODEX_MODEL="gpt-5.3-codex"
CLAUDE_MODEL="claude-opus-4.5"
if command -v jq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
    CODEX_MODEL=$(jq -r '.reviewers.codex.model // "gpt-5.3-codex"' "$CONFIG_FILE" 2>/dev/null || echo "gpt-5.3-codex")
    CLAUDE_MODEL=$(jq -r '.reviewers.claude.model // "claude-opus-4.5"' "$CONFIG_FILE" 2>/dev/null || echo "claude-opus-4.5")
fi

echo "================================================"
echo "  OpenClaw Code Review — PR #$PR_NUMBER"
echo "================================================"
echo "  Models: $MODELS"
echo ""

# Fetch the PR diff
echo "[1/4] Fetching PR diff..."
PR_DIFF=$(gh pr diff "$PR_NUMBER" 2>/dev/null || echo "")

if [ -z "$PR_DIFF" ]; then
    echo "ERROR: Could not fetch diff for PR #$PR_NUMBER"
    echo "Make sure you're in the right repo and gh is authenticated."
    exit 1
fi

# Get PR metadata
PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq '.title' 2>/dev/null || echo "Unknown")
PR_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null || echo "")
PR_FILES=$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null || echo "")

echo "  Title: $PR_TITLE"
echo "  Files changed: $(echo "$PR_FILES" | wc -l | tr -d ' ')"
echo ""

# Check if UI files changed (for screenshot requirement)
UI_CHANGED=false
if echo "$PR_FILES" | grep -qiE '\.(tsx|jsx|css|scss|html|vue|svelte)$'; then
    UI_CHANGED=true
    echo "  UI files changed — screenshot check enabled"

    # Check if PR body contains image references
    if ! echo "$PR_BODY" | grep -qiE '!\[.*\]\(.*\)|<img |screenshot|\.png|\.jpg|\.gif'; then
        echo "  WARNING: UI changed but no screenshot found in PR description!"
        gh pr comment "$PR_NUMBER" --body "**[OpenClaw Monitor]** UI files were changed but no screenshot was included in the PR description. Please add screenshots showing the UI changes." 2>/dev/null || true
    fi
fi

# --- Codex Review ---
if echo "$MODELS" | grep -q "codex"; then
    echo ""
    echo "[2/4] Running Codex review..."

    CODEX_PROMPT=$(cat "$PROMPTS_DIR/review-codex.md" 2>/dev/null || echo "Review this PR diff for bugs, edge cases, and security issues.")

    REVIEW_INPUT="$CODEX_PROMPT

## PR: $PR_TITLE

## Changed Files:
$PR_FILES

## Diff:
$PR_DIFF"

    # Write review input to temp file to avoid ARG_MAX limits on large diffs
    REVIEW_TMPFILE=$(mktemp)
    echo "$REVIEW_INPUT" > "$REVIEW_TMPFILE"

    CODEX_REVIEW=$(codex --model "$CODEX_MODEL" \
        -c "model_reasoning_effort=high" \
        --dangerously-bypass-approvals-and-sandbox \
        "$(cat "$REVIEW_TMPFILE")" 2>/dev/null || echo "[Codex review failed to run]")

    rm -f "$REVIEW_TMPFILE"

    echo "  Codex review complete. Posting to PR..."
    gh pr comment "$PR_NUMBER" --body "## Codex Code Review

$CODEX_REVIEW" 2>/dev/null || echo "  Failed to post Codex review comment."
fi

# --- Claude Review ---
if echo "$MODELS" | grep -q "claude"; then
    echo ""
    echo "[3/4] Running Claude review..."

    CLAUDE_PROMPT=$(cat "$PROMPTS_DIR/review-claude.md" 2>/dev/null || echo "Review this PR diff. Only flag critical issues.")

    REVIEW_INPUT="$CLAUDE_PROMPT

## PR: $PR_TITLE

## Changed Files:
$PR_FILES

## Diff:
$PR_DIFF"

    # Write review input to temp file to avoid ARG_MAX limits on large diffs
    REVIEW_TMPFILE=$(mktemp)
    echo "$REVIEW_INPUT" > "$REVIEW_TMPFILE"

    CLAUDE_REVIEW=$(claude --model "$CLAUDE_MODEL" \
        --dangerously-skip-permissions \
        -p "$(cat "$REVIEW_TMPFILE")" 2>/dev/null || echo "[Claude review failed to run]")

    rm -f "$REVIEW_TMPFILE"

    echo "  Claude review complete. Posting to PR..."
    gh pr comment "$PR_NUMBER" --body "## Claude Code Review

$CLAUDE_REVIEW" 2>/dev/null || echo "  Failed to post Claude review comment."
fi

# --- Gemini Review ---
if echo "$MODELS" | grep -q "gemini"; then
    echo ""
    echo "[3.5/4] Gemini review..."
    echo "  Gemini Code Assist reviews automatically via GitHub App."
    echo "  If not installed, add it at: https://github.com/apps/gemini-code-assist"
    echo "  Skipping manual Gemini review invocation."
fi

# --- Summary ---
echo ""
echo "[4/4] Review complete!"
echo ""
echo "================================================"
echo "  Reviews posted to PR #$PR_NUMBER"
echo "  View at: $(gh pr view "$PR_NUMBER" --json url --jq '.url' 2>/dev/null || echo 'https://github.com')"
echo "================================================"
