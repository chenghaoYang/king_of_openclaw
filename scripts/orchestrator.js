#!/usr/bin/env node
// =============================================================================
// orchestrator.js — Zoe: The OpenClaw Agent Orchestrator
//
// This is the brain of the swarm. Zoe:
//   1. Scans for new work (Sentry errors, meeting notes, git log)
//   2. Picks the right agent for each task
//   3. Writes context-rich prompts
//   4. Spawns agents via spawn-agent.sh
//   5. Monitors progress via check-agents.sh
//   6. Handles failures with improved prompts (Ralph Loop V2)
//
// Usage: node scripts/orchestrator.js [command]
//   commands:
//     spawn   — Spawn a new agent interactively
//     status  — Show status of all agents
//     check   — Run the agent monitor
//     review  — Trigger code review on a PR
//     cleanup — Run worktree cleanup
//     list    — List all tasks
//
// For automated orchestration, Zoe should be invoked by the AI orchestrator
// (OpenClaw) which handles the strategic decision-making layer.
// =============================================================================

const { execSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "..");
const TASKS_FILE = path.join(REPO_ROOT, ".clawdbot", "active-tasks.json");
const CONFIG_FILE = path.join(REPO_ROOT, ".clawdbot", "config.json");
const LEARNINGS_DIR = path.join(REPO_ROOT, ".clawdbot", "learnings");

// --- Helpers ---

function loadJSON(filepath) {
  try {
    return JSON.parse(fs.readFileSync(filepath, "utf-8"));
  } catch {
    return null;
  }
}

function saveJSON(filepath, data) {
  fs.writeFileSync(filepath, JSON.stringify(data, null, 2) + "\n");
}

function run(cmd, opts = {}) {
  try {
    return execSync(cmd, {
      cwd: REPO_ROOT,
      encoding: "utf-8",
      stdio: opts.silent ? "pipe" : "inherit",
      ...opts,
    });
  } catch (e) {
    if (opts.silent) return e.stdout || "";
    throw e;
  }
}

function runSilent(cmd) {
  return run(cmd, { silent: true, stdio: "pipe" }).trim();
}

// --- Agent Selection ---

const AGENT_ROUTING = {
  backend: "codex",
  bugs: "codex",
  refactors: "codex",
  "multi-file": "codex",
  complex: "codex",
  api: "codex",
  database: "codex",
  frontend: "claude",
  "git-ops": "claude",
  "quick-fixes": "claude",
  ui: "claude",
  styling: "claude",
  "ui-design": "gemini",
  "html-css-spec": "gemini",
  design: "gemini",
};

function selectAgent(taskType) {
  const config = loadJSON(CONFIG_FILE);
  if (!config) return "codex"; // Default fallback

  // Check routing table
  const normalized = taskType.toLowerCase();
  for (const [key, agent] of Object.entries(AGENT_ROUTING)) {
    if (normalized.includes(key)) return agent;
  }

  return "codex"; // Codex is the workhorse for 90% of tasks
}

function getAgentConfig(agentType) {
  const config = loadJSON(CONFIG_FILE);
  if (!config || !config.agents || !config.agents[agentType]) {
    return { model: "default", command: agentType };
  }
  return config.agents[agentType];
}

// --- Task Management ---

function loadTasks() {
  return loadJSON(TASKS_FILE) || { tasks: [], metadata: {} };
}

function listTasks(filter) {
  const data = loadTasks();
  let tasks = data.tasks;

  if (filter) {
    tasks = tasks.filter((t) => t.status === filter);
  }

  if (tasks.length === 0) {
    console.log("No tasks found.");
    return;
  }

  console.log("\n  OpenClaw Task Registry");
  console.log("  ======================\n");

  for (const task of tasks) {
    const statusIcon =
      {
        running: "🔄",
        agent_completed: "✅",
        pr_created: "📝",
        ci_passed: "✅",
        ci_failed: "❌",
        agent_failed: "💥",
        done: "🎉",
        cancelled: "🚫",
      }[task.status] || "❓";

    console.log(`  ${statusIcon} ${task.id} (${task.status})`);
    console.log(`     ${task.description}`);
    console.log(`     Agent: ${task.agent} | Branch: ${task.branch}`);
    if (task.note) console.log(`     Note: ${task.note}`);
    console.log("");
  }

  console.log(`  Total: ${tasks.length} tasks`);
  console.log(
    `  Stats: ${data.metadata.totalSpawned || 0} spawned, ${data.metadata.totalCompleted || 0} completed, ${data.metadata.totalFailed || 0} failed`
  );
}

// --- Learnings ---

function recordLearning(taskId, outcome, notes) {
  if (!fs.existsSync(LEARNINGS_DIR)) {
    fs.mkdirSync(LEARNINGS_DIR, { recursive: true });
  }

  const learning = {
    taskId,
    outcome,
    notes,
    timestamp: new Date().toISOString(),
  };

  const file = path.join(
    LEARNINGS_DIR,
    `${new Date().toISOString().split("T")[0]}.jsonl`
  );
  fs.appendFileSync(file, JSON.stringify(learning) + "\n");
}

// --- Respawn with Improved Prompt (Ralph Loop V2) ---

function respawnWithContext(taskId, failureReason) {
  const data = loadTasks();
  const task = data.tasks.find((t) => t.id === taskId);
  if (!task) {
    console.error(`Task '${taskId}' not found.`);
    return;
  }

  const config = loadJSON(CONFIG_FILE);
  const maxRetries = config?.orchestrator?.maxRetries || 3;

  if (task.retryCount >= maxRetries) {
    console.log(
      `Task '${taskId}' has reached max retries (${maxRetries}). Needs human attention.`
    );
    recordLearning(taskId, "max_retries_reached", failureReason);
    return;
  }

  console.log(
    `\nRespawning '${taskId}' (attempt ${task.retryCount + 1}/${maxRetries})...`
  );
  console.log(`Failure reason: ${failureReason}`);

  // Load learnings to improve the prompt
  const learnings = loadLearningsForTask(taskId);
  let improvedHints = "";

  if (failureReason.includes("context") || failureReason.includes("timeout")) {
    improvedHints = "IMPORTANT: Focus only on the most critical files. Do not try to read the entire codebase.";
  } else if (
    failureReason.includes("CI") ||
    failureReason.includes("test")
  ) {
    improvedHints = "IMPORTANT: Run tests before creating the PR. Fix any failing tests.";
  } else if (failureReason.includes("wrong direction")) {
    improvedHints = "IMPORTANT: Re-read the requirements carefully. The previous attempt went in the wrong direction.";
  }

  if (learnings.length > 0) {
    improvedHints +=
      "\n\nLearnings from previous attempts:\n" +
      learnings.map((l) => `- ${l.notes}`).join("\n");
  }

  console.log(`Improved hints: ${improvedHints || "(none)"}`);

  recordLearning(taskId, "respawned", `Attempt ${task.retryCount + 1}: ${failureReason}`);
}

function loadLearningsForTask(taskId) {
  if (!fs.existsSync(LEARNINGS_DIR)) return [];

  const files = fs.readdirSync(LEARNINGS_DIR).filter((f) => f.endsWith(".jsonl"));
  const learnings = [];

  for (const file of files) {
    const lines = fs
      .readFileSync(path.join(LEARNINGS_DIR, file), "utf-8")
      .trim()
      .split("\n");
    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        if (entry.taskId === taskId) learnings.push(entry);
      } catch {
        // skip malformed lines
      }
    }
  }

  return learnings;
}

// --- Commands ---

const command = process.argv[2] || "status";

switch (command) {
  case "status":
  case "list":
    listTasks(process.argv[3]); // optional filter: running, done, etc.
    break;

  case "check":
    console.log("Running agent monitor...\n");
    run("./scripts/check-agents.sh --verbose");
    break;

  case "review": {
    const prNumber = process.argv[3];
    if (!prNumber) {
      console.error("Usage: orchestrator.js review <pr-number>");
      process.exit(1);
    }
    run(`./scripts/review-pr.sh ${prNumber}`);
    break;
  }

  case "cleanup":
    console.log("Running worktree cleanup...\n");
    run("./scripts/cleanup-worktrees.sh");
    break;

  case "spawn": {
    const taskId = process.argv[3];
    const agentType = process.argv[4] || "codex";
    const prompt = process.argv[5];

    if (!taskId || !prompt) {
      console.error(
        'Usage: orchestrator.js spawn <task-id> [agent-type] "<prompt>"'
      );
      process.exit(1);
    }

    const agentConfig = getAgentConfig(agentType);
    console.log(`\nSpawning ${agentType} agent for task '${taskId}'...`);
    console.log(`Model: ${agentConfig.model}`);

    run(
      `./scripts/spawn-agent.sh --task-id "${taskId}" --agent "${agentType}" --model "${agentConfig.model}" --prompt "${prompt.replace(/"/g, '\\"')}"`
    );
    break;
  }

  case "route": {
    const taskType = process.argv[3];
    if (!taskType) {
      console.error("Usage: orchestrator.js route <task-type>");
      console.error("  task-type: backend, frontend, bugs, ui-design, etc.");
      process.exit(1);
    }
    const agent = selectAgent(taskType);
    const config = getAgentConfig(agent);
    console.log(`\nTask type: ${taskType}`);
    console.log(`Recommended agent: ${agent}`);
    console.log(`Model: ${config.model}`);
    break;
  }

  case "respawn": {
    const rTaskId = process.argv[3];
    const reason = process.argv[4] || "unknown failure";
    if (!rTaskId) {
      console.error("Usage: orchestrator.js respawn <task-id> [reason]");
      process.exit(1);
    }
    respawnWithContext(rTaskId, reason);
    break;
  }

  case "learn": {
    const lTaskId = process.argv[3];
    const outcome = process.argv[4];
    const notes = process.argv[5];
    if (!lTaskId || !outcome) {
      console.error('Usage: orchestrator.js learn <task-id> <outcome> "<notes>"');
      process.exit(1);
    }
    recordLearning(lTaskId, outcome, notes);
    console.log(`Learning recorded for task '${lTaskId}'.`);
    break;
  }

  default:
    console.log(`
OpenClaw Orchestrator (Zoe)

Usage: node scripts/orchestrator.js <command>

Commands:
  status  [filter]      Show all tasks (optional filter: running, done, etc.)
  list    [filter]      Alias for status
  check                 Run the agent monitor
  spawn   <id> [type] "<prompt>"  Spawn a new agent
  review  <pr-number>   Run code review on a PR
  cleanup               Clean up worktrees and archived tasks
  route   <task-type>   Show which agent would handle a task type
  respawn <id> [reason] Respawn a failed task with improved context
  learn   <id> <outcome> "<notes>"  Record a learning from a task
`);
}
