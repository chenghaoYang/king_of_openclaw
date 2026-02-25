#!/usr/bin/env node
// =============================================================================
// telegram-notify.js — Node.js Telegram notification helper
//
// Provides a programmatic interface for sending Telegram notifications.
// Used by the orchestrator for richer notification formatting.
//
// Usage:
//   node scripts/telegram-notify.js <event> [task-id] [message]
//
// Events:
//   pr_ready       — PR ready for human review
//   agent_failed   — Agent failed
//   ci_failed      — CI checks failed
//   daily_summary  — End-of-day summary
//   morning_scan   — Morning Sentry/error scan results
// =============================================================================

const https = require("https");
const fs = require("fs");
const path = require("path");

const CONFIG_FILE = path.resolve(__dirname, "..", ".clawdbot", "config.json");
const TASKS_FILE = path.resolve(
  __dirname,
  "..",
  ".clawdbot",
  "active-tasks.json"
);

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf-8"));
  } catch {
    return {};
  }
}

function loadTasks() {
  try {
    return JSON.parse(fs.readFileSync(TASKS_FILE, "utf-8"));
  } catch {
    return { tasks: [], metadata: {} };
  }
}

function sendTelegram(botToken, chatId, message) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({
      chat_id: chatId,
      text: message,
      // Plain text (no parse_mode) to avoid Markdown/HTML parse errors from user input
    });

    const options = {
      hostname: "api.telegram.org",
      path: `/bot${botToken}/sendMessage`,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(data),
      },
    };

    const req = https.request(options, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(
            new Error(
              `Telegram API returned HTTP ${res.statusCode}: ${body}`
            )
          );
          return;
        }
        try {
          const result = JSON.parse(body);
          if (result.ok) resolve(result);
          else reject(new Error(`Telegram API error: ${body}`));
        } catch (e) {
          reject(new Error(`Failed to parse Telegram response: ${body}`));
        }
      });
    });

    // 10-second timeout to prevent hanging in cron/background jobs
    req.setTimeout(10000, () => {
      req.destroy(new Error("Telegram request timed out after 10 seconds"));
    });

    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

function buildDailySummary() {
  const data = loadTasks();
  const tasks = data.tasks;

  const running = tasks.filter((t) => t.status === "running").length;
  const done = tasks.filter((t) => t.status === "done").length;
  const failed = tasks.filter(
    (t) => t.status === "agent_failed" || t.status === "ci_failed"
  ).length;

  return `Daily Summary

Running: ${running}
Completed: ${done}
Failed: ${failed}

Total spawned: ${data.metadata.totalSpawned || 0}
Total completed: ${data.metadata.totalCompleted || 0}

-- OpenClaw Agent Swarm`;
}

async function main() {
  const event = process.argv[2] || "info";
  const taskId = process.argv[3] || "";
  const message = process.argv[4] || "";

  const config = loadConfig();
  const telegram = config.notifications?.telegram;

  const botToken = process.env.TELEGRAM_BOT_TOKEN || telegram?.botToken;
  const chatId = process.env.TELEGRAM_CHAT_ID || telegram?.chatId;

  if (!botToken || !chatId) {
    console.log(
      "[telegram] Not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID."
    );
    process.exit(0);
  }

  if (telegram?.enabled === false) {
    console.log("[telegram] Notifications disabled in config.");
    process.exit(0);
  }

  let text;

  switch (event) {
    case "pr_ready":
      text = `PR Ready for Review\n\nTask: ${taskId}\n${message}\n\nAll checks passed. Ready to merge.\n\n-- OpenClaw`;
      break;
    case "agent_failed":
      text = `Agent Failed\n\nTask: ${taskId}\n${message}\n\n-- OpenClaw`;
      break;
    case "ci_failed":
      text = `CI Failed\n\nTask: ${taskId}\n${message}\n\n-- OpenClaw`;
      break;
    case "daily_summary":
      text = buildDailySummary();
      break;
    case "morning_scan":
      text = `Morning Scan\n\n${message}\n\n-- OpenClaw`;
      break;
    default:
      text = `OpenClaw Update\n\nEvent: ${event}\nTask: ${taskId}\n${message}\n\n-- OpenClaw`;
  }

  try {
    await sendTelegram(botToken, chatId, text);
    console.log("[telegram] Message sent.");
  } catch (e) {
    console.error("[telegram] Failed:", e.message);
  }
}

main().catch((e) => {
  console.error("[telegram] Unexpected error:", e.message);
  process.exit(1);
});
