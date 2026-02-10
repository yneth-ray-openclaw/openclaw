import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

export type IntegrityResult = {
  valid: boolean;
  mismatches: string[];
  missing: string[];
  totalFiles: number;
};

type IntegrityManifest = {
  version: number;
  algorithm: string;
  files: Record<string, string>;
};

async function hashFile(filePath: string): Promise<string> {
  const content = await fs.readFile(filePath);
  return createHash("sha256").update(content).digest("hex");
}

/**
 * Verifies file integrity against the generated .integrity.json manifest.
 * Returns a result indicating which files are valid, mismatched, or missing.
 */
export async function verifyIntegrity(root: string): Promise<IntegrityResult> {
  const manifestPath = path.join(root, "dist", ".integrity.json");

  let manifest: IntegrityManifest;
  try {
    const raw = await fs.readFile(manifestPath, "utf-8");
    manifest = JSON.parse(raw) as IntegrityManifest;
  } catch {
    return { valid: false, mismatches: [], missing: [manifestPath], totalFiles: 0 };
  }

  const mismatches: string[] = [];
  const missing: string[] = [];
  const entries = Object.entries(manifest.files);

  for (const [relativePath, expectedHash] of entries) {
    const fullPath = path.join(root, relativePath);
    try {
      const actualHash = await hashFile(fullPath);
      if (actualHash !== expectedHash) {
        mismatches.push(relativePath);
      }
    } catch {
      missing.push(relativePath);
    }
  }

  return {
    valid: mismatches.length === 0 && missing.length === 0,
    mismatches,
    missing,
    totalFiles: entries.length,
  };
}
