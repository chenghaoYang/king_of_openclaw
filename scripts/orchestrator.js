#!/usr/bin/env node
// =============================================================================
// orchestrator.js — Zoe: The OpenClaw Agent Orchestrator
//
// Usage: node scripts/orchestrator.js [command]
//   commands:
//     spawn   — Spawn a new agent
//     status  — Show status of all agents
//     check   — Run the agent monitor
//     review  — Trigger code review on a PR
//     cleanup — Run worktree cleanup
//     list    — List all tasks
//     route   — Show which agent would handle a task type
//     respawn — Respawn a failed task with improved context
//     learn   — Record a learning from a task
// =============================================================================

const { execSync, execFileSync } = require("child_process");
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
  } catch (e) {
    if (e.code !== "ENOENT") {
      console.error(`Warning: Failed to parse ${filepath}: ${e.message}`);
    }
    return null;
  }
}

function saveJSON(filepath, data) {
  // Atomic write: write to tmp file then rename to prevent corruption
  const tmp = filepath + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
  fs.renameSync(tmp, filepath);
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

// Safe execution: uses execFileSync to avoid shell injection
function runFile(command, args, opts = {}) {
  try {
    return execFileSync(command, args, {
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

// --- Agent Selection ---

// Ordered from most specific to least specific to prevent substring false matches.
// e.g. "ui-design" must match gemini before "ui" matches claude.
const AGENT_ROUTING = [
  ["ui-design", "gemini"],
  ["html-css-spec", "gemini"],
  ["design", "gemini"],
  ["multi-file", "codex"],
  ["quick-fixes", "claude"],
  ["git-ops", "claude"],
  ["backend", "codex"],
  ["bugs", "codex"],
  ["refactors", "codex"],
  ["complex", "codex"],
  ["api", "codex"],
  ["database", "codex"],
  ["frontend", "claude"],
  ["ui", "claude"],
  ["styling", "claude"],
];

function selectAgent(taskType) {
  const normalized = taskType.toLowerCase();

  // Exact match first
  for (const [key, agent] of AGENT_ROUTING) {
    if (normalized === key) return agent;
  }

  // Substring match (already ordered most specific → least specific)
  for (const [key, agent] of AGENT_ROUTING) {
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
        running: "[~]",
        agent_completed: "[+]",
        pr_created: "[PR]",
        ci_passed: "[CI+]",
        ci_failed: "[CI!]",
        agent_failed: "[!!]",
        done: "[OK]",
        cancelled: "[--]",
      }[task.status] || "[?]";

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

function loadLearningsForTask(taskId) {
  if (!fs.existsSync(LEARNINGS_DIR)) return [];

  const files = fs.readdirSync(LEARNINGS_DIR).filter((f) => f.endsWith(".jsonl"));
  const learnings = [];

  for (const file of files) {
    const content = fs.readFileSync(path.join(LEARNINGS_DIR, file), "utf-8").trim();
    if (!content) continue;
    for (const line of content.split("\n")) {
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
  const retryCount = task.retryCount || 0;

  if (retryCount >= maxRetries) {
    console.log(
      `Task '${taskId}' has reached max retries (${maxRetries}). Needs human attention.`
    );
    recordLearning(taskId, "max_retries_reached", failureReason);
    return;
  }

  console.log(
    `\nRespawning '${taskId}' (attempt ${retryCount + 1}/${maxRetries})...`
  );
  console.log(`Failure reason: ${failureReason}`);

  // Load learnings to improve the prompt
  const learnings = loadLearningsForTask(taskId);
  let improvedHints = "";

  if (failureReason.includes("context") || failureReason.includes("timeout")) {
    improvedHints = "IMPORTANT: Focus only on the most critical files. Do not try to read the entire codebase.";
  } else if (failureReason.includes("CI") || failureReason.includes("test")) {
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
  recordLearning(taskId, "respawned", `Attempt ${retryCount + 1}: ${failureReason}`);

  // Build the new prompt from original + improved hints
  const originalPrompt = task.prompt || "";
  if (!originalPrompt) {
    console.error(
      `No original prompt stored for task '${taskId}'. Cannot auto-respawn.`
    );
    console.error(
      `Re-spawn manually: node scripts/orchestrator.js spawn ${taskId} ${task.agent} "<prompt>"`
    );
    return;
  }

  const newPrompt = `${originalPrompt}\n\n--- RETRY CONTEXT (attempt ${retryCount + 1}) ---\nPrevious failure: ${failureReason}\n${improvedHints}`;

  // Update task status back to running
  const taskIndex = data.tasks.findIndex((t) => t.id === taskId);
  if (taskIndex >= 0) {
    data.tasks[taskIndex].retryCount = retryCount + 1;
    data.tasks[taskIndex].status = "running";
    data.tasks[taskIndex].lastUpdated = Date.now();
    data.tasks[taskIndex].prompt = newPrompt;
    saveJSON(TASKS_FILE, data);
  }

  // Actually respawn the agent (using execFileSync to avoid shell injection)
  const agentConfig = getAgentConfig(task.agent);
  try {
    runFile("./scripts/spawn-agent.sh", [
      "--task-id", taskId,
      "--agent", task.agent,
      "--model", agentConfig.model || task.model || "default",
      "--effort", "high",
      "--prompt", newPrompt,
      "--branch", task.branch,
    ]);
    console.log(`Agent respawned for task '${taskId}'.`);
  } catch (e) {
    console.error(`Failed to respawn agent: ${e.message}`);
  }
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
    // Validate PR number is strictly numeric to prevent command injection
    if (!/^\d+$/.test(prNumber)) {
      console.error("Error: PR number must be a positive integer.");
      process.exit(1);
    }
    runFile("./scripts/review-pr.sh", [prNumber]);
    break;
  }

  case "cleanup":
    console.log("Running worktree cleanup...\n");
    run("./scripts/cleanup-worktrees.sh");
    break;

  case "spawn": {
    // Support both: spawn <id> <type> "<prompt>" and spawn <id> "<prompt>"
    let taskId, agentType, prompt;

    if (process.argv.length === 5) {
      // orchestrator.js spawn <id> "<prompt>" (2-arg form, default agent)
      taskId = process.argv[3];
      agentType = "codex";
      prompt = process.argv[4];
    } else {
      // orchestrator.js spawn <id> <type> "<prompt>" (3-arg form)
      taskId = process.argv[3];
      agentType = process.argv[4] || "codex";
      prompt = process.argv[5];
    }

    if (!taskId || !prompt) {
      console.error(
        'Usage: orchestrator.js spawn <task-id> [agent-type] "<prompt>"'
      );
      process.exit(1);
    }

    // Enforce max concurrent agents
    const spawnConfig = loadJSON(CONFIG_FILE);
    const maxConcurrent = spawnConfig?.orchestrator?.maxConcurrentAgents || 5;
    const spawnData = loadTasks();
    const running = spawnData.tasks.filter((t) => t.status === "running").length;
    if (running >= maxConcurrent) {
      console.error(
        `Cannot spawn: ${running} agents already running (max: ${maxConcurrent}).`
      );
      console.error(
        "Wait for agents to finish or increase maxConcurrentAgents in config."
      );
      process.exit(1);
    }

    const agentConfig = getAgentConfig(agentType);
    console.log(`\nSpawning ${agentType} agent for task '${taskId}'...`);
    console.log(`Model: ${agentConfig.model}`);

    // Use execFileSync to avoid shell injection
    runFile("./scripts/spawn-agent.sh", [
      "--task-id", taskId,
      "--agent", agentType,
      "--model", agentConfig.model || "default",
      "--effort", agentConfig.reasoningEffort || "high",
      "--prompt", prompt,
    ]);
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
    const routeConfig = getAgentConfig(agent);
    console.log(`\nTask type: ${taskType}`);
    console.log(`Recommended agent: ${agent}`);
    console.log(`Model: ${routeConfig.model}`);
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
      console.error(
        'Usage: orchestrator.js learn <task-id> <outcome> "<notes>"'
      );
      process.exit(1);
    }
    recordLearning(lTaskId, outcome, notes);
    console.log(`Learning recorded for task '${lTaskId}'.`);
    break;
  }

  case "-h":
  case "--help":
  case "help":
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
