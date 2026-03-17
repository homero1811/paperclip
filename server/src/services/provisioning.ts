import { process } from "node:process";
import { sql, eq, and } from "drizzle-orm";
import { 
  agents, 
  companies, 
  goals, 
  issues,
  instanceUserRoles, 
  authUsers,
  companyMemberships,
  type Db 
} from "@paperclipai/db";
import { logger } from "../middleware/logger.js";

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
      .then((rows) => rows[0] ?? null);

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
        .then((rows) => rows[0] ?? null);

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

  await db.transaction(async (tx) => {
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
        },
        runtimeConfig: {
          heartbeat: {
            enabled: true,
            intervalSec: 3600,
            wakeOnDemand: true,
            cooldownSec: 10,
            maxConcurrentRuns: 1,
          },
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
        .then((rows) => rows[0] ?? null);
      
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
}
