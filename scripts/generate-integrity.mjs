#!/usr/bin/env node

/**
 * Generates a SHA-256 integrity manifest for the dist/ directory.
 * Produces dist/.integrity.json containing hashes of all built files.
 *
 * Usage: node scripts/generate-integrity.mjs
 */

import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const DIST_DIR = path.resolve(process.cwd(), "dist");
const OUTPUT_FILE = path.join(DIST_DIR, ".integrity.json");

async function walkDir(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walkDir(fullPath)));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
}

async function hashFile(filePath) {
  const content = await readFile(filePath);
  return createHash("sha256").update(content).digest("hex");
}

async function main() {
  const files = await walkDir(DIST_DIR);
  const hashes = {};

  for (const file of files.sort()) {
    // Use relative path from project root
    const relativePath = path.relative(process.cwd(), file);
    // Skip the integrity file itself
    if (file === OUTPUT_FILE) continue;
    hashes[relativePath] = await hashFile(file);
  }

  const manifest = {
    version: 1,
    generatedAt: new Date().toISOString(),
    algorithm: "sha256",
    files: hashes,
  };

  await writeFile(OUTPUT_FILE, JSON.stringify(manifest, null, 2) + "\n");
  console.log(
    `[integrity] Generated ${OUTPUT_FILE} with ${Object.keys(hashes).length} file hashes`,
  );
}

main().catch((err) => {
  console.error("[integrity] Failed:", err);
  process.exit(1);
});
