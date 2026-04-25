import process from "node:process";
import { readFile, readdir } from "node:fs/promises";
import { join, resolve, extname, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { sql, eq, and } from "drizzle-orm";
import {
  agents,
  companies,
  goals,
  issues,
  projects,
  instanceUserRoles,
  authUsers,
  companyMemberships,
  type Db
} from "@paperclipai/db";
import {
  AGENCY_AGENT_DIVISION_PROJECT_NAMES,
  AGENCY_AGENT_DEFAULT_ADAPTER,
  AGENCY_AGENT_DEFAULT_MODEL,
} from "@paperclipai/shared";
import { logger } from "../middleware/logger.js";
import { DEFAULT_CEO_PROMPT } from "./default-ceo-prompt.js";

const __provisioningDirname = dirname(fileURLToPath(import.meta.url));
const AGENCY_AGENTS_DATA_DIR = resolve(__provisioningDirname, "../seeds/agency-agents");

const LOCAL_BOARD_USER_ID = "local-board";

export async function autoProvision(db: Db) {
  const provisionEnabled = process.env.PAPERCLIP_AUTO_PROVISION === "true";
  const adminEmail = process.env.PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL?.trim();

  // 1. Handle Bootstrap Admin Email
  if (adminEmail) {
    const user = await db
      .select({ id: authUsers.id })
      .from(authUsers)
      .where(eq(authUsers.email, adminEmail))
      .then((rows: any[]) => rows[0] ?? null);

    if (user) {
      const existingRole = await db
        .select({ id: instanceUserRoles.id })
        .from(instanceUserRoles)
        .where(
          and(
            eq(instanceUserRoles.userId, user.id),
            eq(instanceUserRoles.role, "instance_admin")
          )
        )
        .then((rows: any[]) => rows[0] ?? null);

      if (!existingRole) {
        logger.info({ email: adminEmail }, "Auto-provisioning: adding instance_admin role to bootstrap admin");
        await db.insert(instanceUserRoles).values({
          userId: user.id,
          role: "instance_admin",
        });
      }
    }
  }

  if (!provisionEnabled) return;

  // 2. Handle Company & CEO Provisioning
  const companyResults = await db.select({ count: sql<number>`count(*)` }).from(companies);
  if (Number(companyResults[0].count) > 0) {
    logger.debug("Auto-provisioning: skipped (database already has companies)");
    return;
  }

  const companyName = process.env.PAPERCLIP_PROVISION_COMPANY_NAME?.trim() || "My Company";
  const ceoName = process.env.PAPERCLIP_PROVISION_CEO_NAME?.trim() || "CEO";
  const adapterType = process.env.PAPERCLIP_PROVISION_CEO_ADAPTER?.trim() || "claude_local";
  const model = process.env.PAPERCLIP_PROVISION_CEO_MODEL?.trim() || "";
  const cwd = process.env.PAPERCLIP_PROVISION_CEO_CWD?.trim() || "";

  logger.info({ companyName, ceoName }, "Auto-provisioning: creating first company and ceo");

  await db.transaction(async (tx: any) => {
    const [company] = await tx
      .insert(companies)
      .values({
        name: companyName,
        status: "active",
      })
      .returning();

    if (!company) throw new Error("Failed to create company during auto-provisioning");

    const [ceo] = await tx
      .insert(agents)
      .values({
        companyId: company.id,
        name: ceoName,
        role: "ceo",
        status: "idle",
        adapterType,
        adapterConfig: {
          model,
          cwd,
          dangerouslySkipPermissions: adapterType === "claude_local",
          promptTemplate: DEFAULT_CEO_PROMPT,
        },
        runtimeConfig: {
          heartbeat: {
            enabled: true,
            intervalSec: 14400,
            wakeOnDemand: true,
            cooldownSec: 10,
            maxConcurrentRuns: 1,
          },
          sessionHandoffMarkdown: true,
        },
      })
      .returning();

    if (!ceo) throw new Error("Failed to create ceo agent during auto-provisioning");

    // Ensure the local-board (or the bootstrap admin if they exist by ID) has access to this company
    // By default, the initializeBoardClaimChallenge logic handles local-board as owner of all companies
    // but we can be explicit here.
    await tx.insert(companyMemberships).values({
      companyId: company.id,
      principalType: "user",
      principalId: LOCAL_BOARD_USER_ID,
      status: "active",
      membershipRole: "owner",
    });

    if (adminEmail) {
      const user = await tx
        .select({ id: authUsers.id })
        .from(authUsers)
        .where(eq(authUsers.email, adminEmail))
        .then((rows: any[]) => rows[0] ?? null);
      
      if (user) {
        await tx.insert(companyMemberships).values({
          companyId: company.id,
          principalType: "user",
          principalId: user.id,
          status: "active",
          membershipRole: "owner",
        });
      }
    }

    // Add an initial goal if provided
    const mission = process.env.PAPERCLIP_PROVISION_COMPANY_MISSION?.trim();
    if (mission) {
      const [goal] = await tx.insert(goals).values({
        companyId: company.id,
        title: "Company Mission",
        description: mission,
        level: "company",
        status: "active",
        ownerAgentId: ceo.id,
      }).returning();

      if (goal) {
        // Create an initial task for the CEO
        await tx.insert(issues).values({
          companyId: company.id,
          goalId: goal.id,
          title: "Setup first project",
          description: "Initialize the repository and define core team structure.",
          status: "todo",
          priority: "high",
          createdByAgentId: ceo.id,
          assigneeAgentId: ceo.id,
        });
      }
    }
  });

  logger.info("Auto-provisioning complete");

  // Seed agency agents if enabled
  if (process.env.PAPERCLIP_PROVISION_AGENCY_AGENTS === "true") {
    logger.info("Auto-provisioning: seeding agency agents");
    try {
      const company = await db
        .select({ id: companies.id })
        .from(companies)
        .then((rows: { id: string }[]) => rows[0] ?? null);
      if (company) {
        await seedAgencyAgents(db, company.id);
        logger.info("Auto-provisioning: agency agents seeded successfully");
      }
    } catch (err) {
      logger.error({ err }, "Auto-provisioning: agency agent seeding failed (non-fatal)");
    }
  }
}

// ── Simple frontmatter parser (no external deps) ─────────────────────────────

function parseYamlValue(value: string): unknown {
  const trimmed = value.trim();
  if (trimmed === "true") return true;
  if (trimmed === "false") return false;
  const num = Number(trimmed);
  if (!isNaN(num) && trimmed !== "") return num;
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function parseFrontmatter(content: string): { frontmatter: Record<string, unknown>; body: string } {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/.exec(content);
  if (!match) return { frontmatter: {}, body: content.trim() };

  const frontmatter: Record<string, unknown> = {};
  let currentKey = "";
  let listMode = false;
  const listItems: string[] = [];

  for (const line of match[1].split("\n")) {
    const listItemMatch = /^  - (.*)$/.exec(line);
    if (listMode && listItemMatch) { listItems.push(listItemMatch[1].trim()); continue; }
    if (listMode && !listItemMatch) { frontmatter[currentKey] = listItems.splice(0); listMode = false; }

    const kv = /^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$/.exec(line);
    if (!kv) continue;
    currentKey = kv[1];
    if (kv[2].trim() === "") { listMode = true; } else { frontmatter[kv[1]] = parseYamlValue(kv[2]); }
  }
  if (listMode && listItems.length > 0) frontmatter[currentKey] = listItems.slice();

  return { frontmatter, body: match[2].trim() };
}

async function walkMdFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...(await walkMdFiles(full)));
    else if (entry.isFile() && extname(entry.name) === ".md") files.push(full);
  }
  return files;
}

// ── Agency agent seeding ─────────────────────────────────────────────────────

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

async function seedAgencyAgents(db: Db, companyId: string): Promise<void> {
  const adapterType = process.env.DEFAULT_ADAPTER ?? AGENCY_AGENT_DEFAULT_ADAPTER;
  const defaultModel = process.env.DEFAULT_MODEL ?? AGENCY_AGENT_DEFAULT_MODEL;

  let files: string[];
  try {
    files = await walkMdFiles(AGENCY_AGENTS_DATA_DIR);
  } catch {
    logger.warn({ dir: AGENCY_AGENTS_DATA_DIR }, "Agency agents data directory not found — skipping seed");
    return;
  }

  for (const filePath of files) {
    try {
      const content = await readFile(filePath, "utf-8");
      const { frontmatter, body } = parseFrontmatter(content);

      const name = frontmatter.name ? String(frontmatter.name) : null;
      const description = frontmatter.description ? String(frontmatter.description) : null;
      if (!name || !description) { logger.warn({ filePath }, "Agency agent missing name/description — skipping"); continue; }

      const rel = filePath.slice(AGENCY_AGENTS_DATA_DIR.length + 1);
      const parts = rel.split("/");
      const division = parts.length > 1 ? parts[0] : "general";
      const projectName = (AGENCY_AGENT_DIVISION_PROJECT_NAMES as Record<string, string>)[division] ?? division;
      const role = DIVISION_ROLES[division] ?? "general";
      const color = DIVISION_COLORS[division];

      // Find or create project
      const existingProject = await db
        .select({ id: projects.id })
        .from(projects)
        .where(and(eq(projects.companyId, companyId), eq(projects.name, projectName)))
        .then((rows: { id: string }[]) => rows[0] ?? null);

      const projectId = existingProject
        ? existingProject.id
        : await db
            .insert(projects)
            .values({ companyId, name: projectName, status: "planned", color: color ?? null })
            .returning({ id: projects.id })
            .then((rows: { id: string }[]) => rows[0]?.id);

      if (!projectId) { logger.warn({ projectName }, "Failed to find/create project for agency agent"); continue; }

      // Upsert agent
      const existingAgent = await db
        .select({ id: agents.id })
        .from(agents)
        .where(and(eq(agents.companyId, companyId), eq(agents.name, name)))
        .then((rows: { id: string }[]) => rows[0] ?? null);

      const agentPayload = {
        role,
        title: description.slice(0, 255),
        adapterType,
        adapterConfig: {
          model: frontmatter.model ? String(frontmatter.model) : defaultModel,
          promptTemplate: body,
          dangerouslySkipPermissions: adapterType === "claude_local",
        } as Record<string, unknown>,
        metadata: {
          division,
          slug: basename(filePath, ".md"),
          projectId,
          importedFrom: "agency-agents",
        } as Record<string, unknown>,
        updatedAt: new Date(),
      };

      if (existingAgent) {
        await db.update(agents).set(agentPayload).where(eq(agents.id, existingAgent.id));
      } else {
        await db.insert(agents).values({
          companyId,
          name,
          status: "idle",
          budgetMonthlyCents: 0,
          spentMonthlyCents: 0,
          runtimeConfig: {},
          permissions: {},
          ...agentPayload,
        });
      }
    } catch (err) {
      logger.error({ err, filePath }, "Failed to seed agency agent");
    }
  }
}
