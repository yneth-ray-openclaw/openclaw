import { type CommandOptions, runCommandWithTimeout } from "../process/exec.js";

export type ConfigPRParams = {
  configPath: string;
  changes: Record<string, unknown>;
  repo: string;
  branch?: string;
};

export type ConfigPRResult = {
  status: "created" | "error";
  prUrl?: string;
  reason?: string;
};

type CommandRunner = (
  argv: string[],
  options: CommandOptions,
) => Promise<{ stdout: string; stderr: string; code: number | null }>;

const DEFAULT_TIMEOUT_MS = 60_000;

function defaultRunner(
  argv: string[],
  options: CommandOptions,
): Promise<{ stdout: string; stderr: string; code: number | null }> {
  return runCommandWithTimeout(argv, options).then((r) => ({
    stdout: r.stdout,
    stderr: r.stderr,
    code: r.code,
  }));
}

/**
 * Creates a GitHub PR for config changes instead of writing directly.
 * Used when OPENCLAW_CONFIG_MODE=pr (default in Docker containers).
 */
export async function createConfigPR(
  params: ConfigPRParams,
  runCommand: CommandRunner = defaultRunner,
): Promise<ConfigPRResult> {
  const { configPath, changes, repo, branch } = params;
  const timeoutMs = DEFAULT_TIMEOUT_MS;
  const branchName = branch ?? `config-update/${Date.now()}`;

  const githubToken = process.env.GITHUB_TOKEN;
  if (!githubToken) {
    return { status: "error", reason: "GITHUB_TOKEN not set" };
  }

  // Create branch
  const checkoutResult = await runCommand(
    ["git", "checkout", "-b", branchName],
    { cwd: repo, timeoutMs },
  );
  if (checkoutResult.code !== 0) {
    return { status: "error", reason: `branch creation failed: ${checkoutResult.stderr}` };
  }

  // Write config change
  const fs = await import("node:fs/promises");
  try {
    const existing = await fs.readFile(configPath, "utf-8").catch(() => "{}");
    const parsed = JSON.parse(existing) as Record<string, unknown>;
    const merged = { ...parsed, ...changes };
    await fs.writeFile(configPath, JSON.stringify(merged, null, 2) + "\n");
  } catch (err) {
    return { status: "error", reason: `config write failed: ${err}` };
  }

  // Stage and commit
  const addResult = await runCommand(["git", "add", configPath], { cwd: repo, timeoutMs });
  if (addResult.code !== 0) {
    return { status: "error", reason: `git add failed: ${addResult.stderr}` };
  }

  const commitResult = await runCommand(
    ["git", "commit", "-m", `config: update ${configPath}`],
    { cwd: repo, timeoutMs },
  );
  if (commitResult.code !== 0) {
    return { status: "error", reason: `commit failed: ${commitResult.stderr}` };
  }

  // Push
  const pushResult = await runCommand(
    ["git", "push", "-u", "origin", branchName],
    { cwd: repo, timeoutMs },
  );
  if (pushResult.code !== 0) {
    return { status: "error", reason: `push failed: ${pushResult.stderr}` };
  }

  // Create PR via gh CLI
  const prResult = await runCommand(
    [
      "gh",
      "pr",
      "create",
      "--title",
      `config: update ${configPath}`,
      "--body",
      `Automated config update for \`${configPath}\`.\n\nChanges:\n\`\`\`json\n${JSON.stringify(changes, null, 2)}\n\`\`\``,
    ],
    { cwd: repo, timeoutMs },
  );
  if (prResult.code !== 0) {
    return { status: "error", reason: `PR creation failed: ${prResult.stderr}` };
  }

  const prUrl = prResult.stdout.trim();
  return { status: "created", prUrl };
}

/**
 * Returns the current config mode.
 * - "pr": queue changes as GitHub PRs (default in Docker)
 * - "direct": write configs normally (local development)
 */
export function getConfigMode(): "pr" | "direct" {
  return process.env.OPENCLAW_CONFIG_MODE === "direct" ? "direct" : "pr";
}

/**
 * Returns the current update mode.
 * - "pr": create branch + PR for self-updates (default in Docker)
 * - "direct": apply updates directly
 */
export function getUpdateMode(): "pr" | "direct" {
  return process.env.OPENCLAW_UPDATE_MODE === "direct" ? "direct" : "pr";
}
