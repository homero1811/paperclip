-- Seed company-level goals and initial seed issues for Tsunami Automation.
--
-- Idempotent: every insert is guarded by a `WHERE NOT EXISTS`, so this
-- script is safe to re-run. It never updates an existing row and never
-- deletes anything — any goals or issues already in the database are
-- preserved.
--
-- Usage:
--   psql "$DATABASE_URL" -f scripts/seed-tsunami-goals.sql
--
-- Prerequisite: the six Tsunami agents exist (either from
-- scripts/create-tsunami-agents.sql or from the live UI).

WITH company AS (
  SELECT id FROM companies WHERE name ILIKE '%tsunami%' LIMIT 1
),
a_ceo AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND role = 'ceo' LIMIT 1
),
a_cfo AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND name = 'Tsunami CFO' LIMIT 1
),
a_sales AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND name = 'Tsunami Sales' LIMIT 1
),
a_marketing AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND name = 'Tsunami Marketing' LIMIT 1
),
a_eng AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND name = 'Tsunami Engineering Lead' LIMIT 1
),
a_cs AS (
  SELECT id FROM agents WHERE company_id = (SELECT id FROM company) AND name = 'Tsunami Customer Success' LIMIT 1
),

-- Company-level goals -------------------------------------------------------

g_mrr AS (
  INSERT INTO goals (company_id, title, description, level, status, owner_agent_id)
  SELECT
    company.id,
    'Hit $25k MRR within 90 days',
    'Reach $25,000 monthly recurring revenue across all AI workforce subscriptions within 90 days of seeding this goal.',
    'company',
    'active',
    (SELECT id FROM a_ceo)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM goals
    WHERE company_id = company.id AND title = 'Hit $25k MRR within 90 days'
  )
  RETURNING id
),
g_pilots AS (
  INSERT INTO goals (company_id, title, description, level, status, owner_agent_id)
  SELECT
    company.id,
    'Deliver 3 paying pilot engagements this quarter',
    'Sign and deliver first outcome for 3 paid pilot engagements in the current quarter. Pilots must complete Day-7 checklist with a client-reported positive outcome.',
    'company',
    'active',
    (SELECT id FROM a_ceo)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM goals
    WHERE company_id = company.id AND title = 'Deliver 3 paying pilot engagements this quarter'
  )
  RETURNING id
),
g_reliability AS (
  INSERT INTO goals (company_id, title, description, level, status, owner_agent_id)
  SELECT
    company.id,
    'Maintain >95% weekly heartbeat-success rate',
    'Keep the Tsunami AI workforce operating reliably — weekly heartbeat-success rate across all company agents must stay above 95%. Engineering Lead co-owns with Kai DevOps.',
    'company',
    'active',
    (SELECT id FROM a_eng)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM goals
    WHERE company_id = company.id AND title = 'Maintain >95% weekly heartbeat-success rate'
  )
  RETURNING id
)

-- Seed issues (one per role) -----------------------------------------------

, i_ceo AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Approve Q2 plan and run first Weekly Business Review',
    E'Kick off the quarterly operating cadence:\n\n1. Approve the Q2 plan (revenue target, pilot target, headcount).\n2. Open and pin a Weekly Business Review (WBR) issue where CFO, Sales, Marketing, Eng, CS post their weekly snapshots.\n3. Post the first WBR decision log entry.\n\nCheckout this issue as yourself, execute, then mark `done`.',
    'todo',
    'high',
    (SELECT id FROM a_ceo),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_ceo) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Approve Q2 plan and run first Weekly Business Review'
    )
  RETURNING id
)
, i_cfo AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Set up weekly cash-flow report and invoicing workflow',
    E'Stand up the Tsunami finance cadence:\n\n1. Define the ledger source of truth (confirm with CEO if unclear — Stripe + simple ledger is the default).\n2. Publish the first weekly cash-flow table on the WBR thread (format per `tsunami-ops/roles/cfo.md`).\n3. Set up the invoicing + collections workflow (template, reminder cadence at Day 7 / 14 / 30).\n\nEscalate to CEO if reconciliation does not balance.',
    'todo',
    'high',
    (SELECT id FROM a_cfo),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_cfo) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Set up weekly cash-flow report and invoicing workflow'
    )
  RETURNING id
)
, i_sales AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Build target account list (50 SMBs) and start outbound',
    E'Build Tsunami Automation''s initial pipeline:\n\n1. Build a 50-account target list (ICP: US/CA SMBs, 10–200 employees, $1M–$50M revenue, services / ecommerce / prosumer SaaS).\n2. Open one opportunity issue per account under the "Pipeline" project.\n3. Start outbound per `tsunami-ops/roles/sales-bdr.md` — 3 touches per heartbeat.\n4. Post a pipeline snapshot comment on the WBR every Monday.\n\nEscalate ACV >$50k leads or commit timing <30 days to the CEO.',
    'todo',
    'high',
    (SELECT id FROM a_sales),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_sales) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Build target account list (50 SMBs) and start outbound'
    )
  RETURNING id
)
, i_marketing AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Ship positioning page and two case-study drafts',
    E'Establish the Tsunami Automation public presence:\n\n1. Ship the positioning page — one outcome-led headline, one proof metric, one CTA.\n2. Draft two case studies using the template in `tsunami-ops/roles/marketing.md` (even if pilots are not yet complete, draft the structure).\n3. Start the content calendar — 2 pieces per week.\n\nVerify all numbers with CFO before publishing. Escalate positioning questions to CEO.',
    'todo',
    'high',
    (SELECT id FROM a_marketing),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_marketing) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Ship positioning page and two case-study drafts'
    )
  RETURNING id
)
, i_eng AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Stand up customer onboarding runbook and internal CRM schema',
    E'Build the tooling that lets the Tsunami team scale:\n\n1. Write the customer onboarding runbook (Day 0 → Day 7 per `tsunami-ops/roles/customer-success.md`).\n2. Define the internal CRM schema — opportunity fields, health-score fields, pilot tracking.\n3. Make sure all Tsunami agents have a valid workspace, `dangerouslySkipPermissions: true`, and no stale `instructionsFilePath`. Coordinate with Kai DevOps if any need repair.\n\nAnything infrastructure → @mention Kai DevOps. Anything code-level → own yourself.',
    'todo',
    'high',
    (SELECT id FROM a_eng),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_eng) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Stand up customer onboarding runbook and internal CRM schema'
    )
  RETURNING id
)
, i_cs AS (
  INSERT INTO issues (company_id, title, description, status, priority, assignee_agent_id, created_by_agent_id)
  SELECT
    company.id,
    'Draft onboarding checklist and first-week cadence for pilot customers',
    E'Prepare Customer Success to run pilots cleanly:\n\n1. Materialize the Day 0 → Day 7 checklist from `tsunami-ops/roles/customer-success.md` as a reusable template.\n2. Define the first-response SLA cadence (4h on support tickets).\n3. Set up the health-score rubric (green/yellow/red triggers).\n4. Define the QBR format for retainer clients.\n\nEscalate any yellow/red client signals to CEO early, and pass expansion signals to Sales.',
    'todo',
    'high',
    (SELECT id FROM a_cs),
    (SELECT id FROM a_ceo)
  FROM company
  WHERE (SELECT id FROM a_cs) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM issues
      WHERE company_id = company.id
        AND title = 'Draft onboarding checklist and first-week cadence for pilot customers'
    )
  RETURNING id
)

SELECT
  (SELECT COUNT(*) FROM g_mrr)         AS goal_mrr_inserted,
  (SELECT COUNT(*) FROM g_pilots)      AS goal_pilots_inserted,
  (SELECT COUNT(*) FROM g_reliability) AS goal_reliability_inserted,
  (SELECT COUNT(*) FROM i_ceo)         AS issue_ceo_inserted,
  (SELECT COUNT(*) FROM i_cfo)         AS issue_cfo_inserted,
  (SELECT COUNT(*) FROM i_sales)       AS issue_sales_inserted,
  (SELECT COUNT(*) FROM i_marketing)   AS issue_marketing_inserted,
  (SELECT COUNT(*) FROM i_eng)         AS issue_eng_inserted,
  (SELECT COUNT(*) FROM i_cs)          AS issue_cs_inserted;
