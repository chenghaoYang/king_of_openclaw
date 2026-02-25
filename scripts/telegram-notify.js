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
const TASKS_FILE = path.resolve(__dirname, "..", ".clawdbot", "active-tasks.json");

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
      parse_mode: "Markdown",
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
        try {
          const result = JSON.parse(body);
          if (result.ok) resolve(result);
          else reject(new Error(`Telegram API error: ${body}`));
        } catch (e) {
          reject(e);
        }
      });
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
  const failed = tasks.filter((t) => t.status === "agent_failed" || t.status === "ci_failed").length;
  const prReady = tasks.filter((t) => t.status === "done" && t.note?.includes("all checks passed")).length;

  return `📊 *Daily Summary*

🔄 Running: ${running}
✅ Completed: ${done}
❌ Failed: ${failed}
📝 PRs ready to merge: ${prReady}

Total spawned: ${data.metadata.totalSpawned || 0}
Total completed: ${data.metadata.totalCompleted || 0}

_— OpenClaw Agent Swarm_`;
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
    console.log("[telegram] Not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.");
    process.exit(0);
  }

  if (telegram?.enabled === false) {
    console.log("[telegram] Notifications disabled in config.");
    process.exit(0);
  }

  let text;

  switch (event) {
    case "pr_ready":
      text = `✅ *PR Ready for Review*\n\nTask: ${taskId}\n${message}\n\nAll checks passed. Ready to merge.\n\n_— OpenClaw_`;
      break;
    case "agent_failed":
      text = `❌ *Agent Failed*\n\nTask: ${taskId}\n${message}\n\n_— OpenClaw_`;
      break;
    case "ci_failed":
      text = `🔴 *CI Failed*\n\nTask: ${taskId}\n${message}\n\n_— OpenClaw_`;
      break;
    case "daily_summary":
      text = buildDailySummary();
      break;
    case "morning_scan":
      text = `🔍 *Morning Scan*\n\n${message}\n\n_— OpenClaw_`;
      break;
    default:
      text = `ℹ️ *OpenClaw Update*\n\nEvent: ${event}\nTask: ${taskId}\n${message}\n\n_— OpenClaw_`;
  }

  try {
    await sendTelegram(botToken, chatId, text);
    console.log("[telegram] Message sent.");
  } catch (e) {
    console.error("[telegram] Failed:", e.message);
  }
}

main();
