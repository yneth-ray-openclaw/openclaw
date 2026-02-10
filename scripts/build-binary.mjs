#!/usr/bin/env node

/**
 * Compiles OpenClaw into a single executable using Bun's --compile flag.
 *
 * Usage:
 *   node scripts/build-binary.mjs                    # current platform
 *   node scripts/build-binary.mjs --target linux-x64 # cross-compile
 *
 * Supported targets: linux-x64, linux-arm64, darwin-x64, darwin-arm64
 */

import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const ENTRY = "./src/entry.ts";
const OUTFILE = "dist/openclaw";

const TARGET_MAP = {
  "linux-x64": "bun-linux-x64",
  "linux-arm64": "bun-linux-arm64",
  "darwin-x64": "bun-darwin-x64",
  "darwin-arm64": "bun-darwin-arm64",
};

function parseArgs() {
  const args = process.argv.slice(2);
  const targetIdx = args.indexOf("--target");
  if (targetIdx !== -1 && args[targetIdx + 1]) {
    return { target: args[targetIdx + 1] };
  }
  return { target: null };
}

function main() {
  const { target } = parseArgs();

  if (!existsSync(ENTRY)) {
    console.error(`[build-binary] Entry file not found: ${ENTRY}`);
    process.exit(1);
  }

  const outfile = target ? `${OUTFILE}-${target}` : OUTFILE;
  const bunTarget = target ? TARGET_MAP[target] : null;

  if (target && !bunTarget) {
    console.error(
      `[build-binary] Unknown target: ${target}. Supported: ${Object.keys(TARGET_MAP).join(", ")}`,
    );
    process.exit(1);
  }

  const cmd = [
    "bun",
    "build",
    ENTRY,
    "--compile",
    "--minify",
    `--outfile ${outfile}`,
  ];

  if (bunTarget) {
    cmd.push(`--target ${bunTarget}`);
  }

  const cmdStr = cmd.join(" ");
  console.log(`[build-binary] ${cmdStr}`);

  try {
    execSync(cmdStr, { stdio: "inherit", cwd: process.cwd() });
    console.log(`[build-binary] Binary written to ${path.resolve(outfile)}`);
  } catch (err) {
    console.error("[build-binary] Compilation failed");
    process.exit(1);
  }
}

main();
