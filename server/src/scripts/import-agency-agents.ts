/**
 * Standalone script: import agency-agent markdown files into Paperclip
 * via Drizzle ORM (bypasses HTTP — runs server-side against the DB directly).
 *
 * Usage:
 *   npx tsx server/src/scripts/import-agency-agents.ts --company-id <uuid>
 *   DATABASE_URL=postgres://... npx tsx server/src/scripts/import-agency-agents.ts --company-id <uuid>
 */
import process from "node:process";
import { readFile, readdir } from "node:fs/promises";
import { join, resolve, extname, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { eq, and } from "drizzle-orm";
import dotenv from "dotenv";
import { createDb, agents, projects } from "@paperclipai/db";
import type { Db } from "@paperclipai/db";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const AGENTS_DATA_DIR = resolve(__dirname, "../seeds/agency-agents");

// ── Division → Project mapping ──────────────────────────────────────────────

const DIVISION_PROJECT_NAMES: Record<string, string> = {
  engineering: "Engineering",
  testing: "Quality & Testing",
  "project-management": "Project Management",
  product: "Product",
  support: "Operations & Support",
  marketing: "Marketing & Growth",
};

const DIVISION_ROLES: Record<string, string> = {
  engineering: "engineer",
  testing: "qa",
  "project-management": "pm",
  product: "pm",
  support: "general",
  marketing: "general",
};

const DIVISION_COLORS: Record<string, string> = {
  engineering: "#6366f1",
  testing: "#22c55e",
  "project-management": "#3b82f6",
  product: "#8b5cf6",
  support: "#14b8a6",
  marketing: "#ec4899",
};

const DEFAULT_ADAPTER = process.env.DEFAULT_ADAPTER ?? "claude_local";
const DEFAULT_MODEL = process.env.DEFAULT_MODEL ?? "claude-opus-4-5";
const DEFAULT_TEMPERATURE = parseFloat(process.env.DEFAULT_TEMPERATURE ?? "0.7");

// ── Simple YAML frontmatter parser ──────────────────────────────────────────

interface AgentFrontmatter {
  name: string;
  description: string;
  model?: string;
  temperature?: number;
  tags?: string[];
  enabled?: boolean;
}

interface ParsedAgent {
  filePath: string;
  division: string;
  slug: string;
  frontmatter: AgentFrontmatter;
  body: string;
}

function parseYamlValue(value: string): unknown {
  const trimmed = value.trim();
  if (trimmed === "true") return true;
  if (trimmed === "false") return false;
  const num = Number(trimmed);
  if (!isNaN(num) && trimmed !== "") return num;
  // Simple list detection: "- item1\n- item2"
  if (trimmed.startsWith("[")) {
    try {
      return JSON.parse(trimmed.replace(/'/g, '"'));
    } catch {
      return trimmed;
    }
  }
  // Strip quotes
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function parseFrontmatter(content: string): { frontmatter: Record<string, unknown>; body: string } {
  const fmRegex = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/;
  const match = fmRegex.exec(content);
  if (!match) {
    return { frontmatter: {}, body: content.trim() };
  }

  const yamlBlock = match[1];
  const body = match[2].trim();
  const frontmatter: Record<string, unknown> = {};

  let currentKey = "";
  let listMode = false;
  const listItems: string[] = [];

  for (const line of yamlBlock.split("\n")) {
    const listItemMatch = /^  - (.*)$/.exec(line);
    if (listMode && listItemMatch) {
      listItems.push(listItemMatch[1].trim());
      continue;
    }
    if (listMode && !listItemMatch) {
      frontmatter[currentKey] = listItems.slice();
      listItems.length = 0;
      listMode = false;
    }

    const kvMatch = /^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$/.exec(line);
    if (!kvMatch) continue;

    const [, key, rawValue] = kvMatch;
    currentKey = key;

    if (rawValue.trim() === "") {
      listMode = true;
    } else {
      frontmatter[key] = parseYamlValue(rawValue);
    }
  }

  if (listMode && listItems.length > 0) {
    frontmatter[currentKey] = listItems.slice();
  }

  return { frontmatter, body };
}

async function walkDir(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walkDir(full)));
    } else if (entry.isFile() && extname(entry.name) === ".md") {
      files.push(full);
    }
  }
  return files;
}

async function loadAllAgents(): Promise<ParsedAgent[]> {
  const files = await walkDir(AGENTS_DATA_DIR);
  const parsed: ParsedAgent[] = [];

  for (const filePath of files) {
    const content = await readFile(filePath, "utf-8");
    const { frontmatter, body } = parseFrontmatter(content);

    if (!frontmatter.name || !frontmatter.description) {
      console.warn(`  ⚠️  Skipping ${filePath}: missing name or description`);
      continue;
    }

    // Division = parent directory name relative to AGENTS_DATA_DIR
    const rel = filePath.slice(AGENTS_DATA_DIR.length + 1);
    const parts = rel.split("/");
    const division = parts.length > 1 ? parts[0] : "general";
    const slug = basename(filePath, ".md");

    parsed.push({
      filePath,
      division,
      slug,
      frontmatter: {
        name: String(frontmatter.name),
        description: String(frontmatter.description),
        model: frontmatter.model ? String(frontmatter.model) : undefined,
        temperature: typeof frontmatter.temperature === "number" ? frontmatter.temperature : undefined,
        tags: Array.isArray(frontmatter.tags)
          ? (frontmatter.tags as string[])
          : undefined,
        enabled: frontmatter.enabled !== false,
      },
      body,
    });
  }

  return parsed;
}

// ── DB helpers ──────────────────────────────────────────────────────────────

async function findOrCreateProject(
  db: Db,
  companyId: string,
  name: string,
  color?: string
): Promise<string> {
  const existing = await db
    .select({ id: projects.id })
    .from(projects)
    .where(and(eq(projects.companyId, companyId), eq(projects.name, name)))
    .then((rows: { id: string }[]) => rows[0] ?? null);

  if (existing) return existing.id;

  const [created] = await db
    .insert(projects)
    .values({
      companyId,
      name,
      status: "planned",
      color: color ?? null,
    })
    .returning({ id: projects.id });

  if (!created) throw new Error(`Failed to create project "${name}"`);
  return created.id;
}

async function upsertAgent(
  db: Db,
  companyId: string,
  agentData: {
    name: string;
    role: string;
    title: string;
    capabilities?: string;
    adapterType: string;
    adapterConfig: Record<string, unknown>;
    metadata: Record<string, unknown>;
  }
): Promise<{ id: string; action: "created" | "updated" }> {
  const existing = await db
    .select({ id: agents.id })
    .from(agents)
    .where(and(eq(agents.companyId, companyId), eq(agents.name, agentData.name)))
    .then((rows: { id: string }[]) => rows[0] ?? null);

  if (existing) {
    await db
      .update(agents)
      .set({
        role: agentData.role,
        title: agentData.title,
        capabilities: agentData.capabilities ?? null,
        adapterType: agentData.adapterType,
        adapterConfig: agentData.adapterConfig,
        metadata: agentData.metadata,
        updatedAt: new Date(),
      })
      .where(eq(agents.id, existing.id));

    return { id: existing.id, action: "updated" };
  }

  const [created] = await db
    .insert(agents)
    .values({
      companyId,
      name: agentData.name,
      role: agentData.role,
      title: agentData.title,
      capabilities: agentData.capabilities ?? null,
      status: "idle",
      adapterType: agentData.adapterType,
      adapterConfig: agentData.adapterConfig,
      runtimeConfig: {},
      permissions: {},
      metadata: agentData.metadata,
      budgetMonthlyCents: 0,
      spentMonthlyCents: 0,
    })
    .returning({ id: agents.id });

  if (!created) throw new Error(`Failed to create agent "${agentData.name}"`);
  return { id: created.id, action: "created" };
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  // Parse --company-id from argv
  const companyIdArg = process.argv.find((_, i, arr) => arr[i - 1] === "--company-id");
  const companyId = companyIdArg ?? process.env.PAPERCLIP_COMPANY_ID ?? "";

  if (!companyId) {
    console.error("Usage: npx tsx server/src/scripts/import-agency-agents.ts --company-id <uuid>");
    console.error("  or set PAPERCLIP_COMPANY_ID env var");
    process.exit(1);
  }

  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    console.error("DATABASE_URL environment variable is required");
    process.exit(1);
  }

  console.log("\n🚀 Agency-Agents → Paperclip DB importer");
  console.log(`   Company: ${companyId}`);
  console.log(`   Source: ${AGENTS_DATA_DIR}\n`);

  const db = createDb(databaseUrl);
  const allAgents = await loadAllAgents();

  console.log(`✅ Parsed ${allAgents.length} agents across ${new Set(allAgents.map(a => a.division)).size} divisions\n`);

  let created = 0;
  let updated = 0;
  let errors = 0;

  // Group by division
  const byDivision = new Map<string, ParsedAgent[]>();
  for (const agent of allAgents) {
    const group = byDivision.get(agent.division) ?? [];
    group.push(agent);
    byDivision.set(agent.division, group);
  }

  for (const [division, divAgents] of [...byDivision.entries()].sort()) {
    const projectName = DIVISION_PROJECT_NAMES[division] ?? division;
    const color = DIVISION_COLORS[division];
    const role = DIVISION_ROLES[division] ?? "general";

    let projectId: string;
    try {
      projectId = await findOrCreateProject(db, companyId, projectName, color);
      console.log(`📁 "${projectName}" (project: ${projectId})`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`   ❌ Failed to set up project "${projectName}": ${msg}`);
      errors += divAgents.length;
      continue;
    }

    for (const agent of divAgents) {
      if (agent.frontmatter.enabled === false) {
        console.log(`   ⏭️  ${agent.frontmatter.name} (disabled — skipping)`);
        continue;
      }

      try {
        const { id, action } = await upsertAgent(db, companyId, {
          name: agent.frontmatter.name,
          role,
          title: agent.frontmatter.description.slice(0, 255),
          capabilities: agent.frontmatter.tags?.join(", "),
          adapterType: DEFAULT_ADAPTER,
          adapterConfig: {
            model: agent.frontmatter.model ?? DEFAULT_MODEL,
            promptTemplate: agent.body,
            dangerouslySkipPermissions: DEFAULT_ADAPTER === "claude_local",
          },
          metadata: {
            division,
            slug: agent.slug,
            projectId,
            temperature: agent.frontmatter.temperature ?? DEFAULT_TEMPERATURE,
            importedFrom: "agency-agents",
          },
        });

        const icon = action === "created" ? "🆕" : "🔄";
        console.log(`   ${icon} ${agent.frontmatter.name} → ${action} (id: ${id})`);
        if (action === "created") created++;
        else updated++;
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`   ❌ ${agent.frontmatter.name} → error: ${msg}`);
        errors++;
      }
    }
  }

  console.log(`\n${"─".repeat(50)}`);
  console.log(`✅ Done! Created: ${created}, Updated: ${updated}, Errors: ${errors}`);
  console.log(`   Total agents processed: ${allAgents.length}\n`);

  process.exit(errors > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
