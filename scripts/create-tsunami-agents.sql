-- Create the six Tsunami Automation business-role agents.
--
-- Idempotent: only inserts roles that do not already exist for the
-- Tsunami company. Does NOT update existing rows — use
-- scripts/patch-tsunami-agents.sh for merge-safe updates so that any
-- ad-hoc tuning made in the live UI survives.
--
-- Usage:
--   psql "$DATABASE_URL" -f scripts/create-tsunami-agents.sql
--
-- Prompts are intentionally short; the detailed playbook lives in the
-- `tsunami-ops` skill (see skills/tsunami-ops/SKILL.md). Keep the
-- prompts here in sync with scripts/agents/tsunami/*.json.

-- Resolve the Tsunami company once.
WITH company AS (
  SELECT id FROM companies WHERE name ILIKE '%tsunami%' LIMIT 1
)

-- CEO
, ins_ceo AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami CEO',
    'ceo',
    'Chief Executive Officer',
    'crown',
    'idle',
    'claude_local',
    jsonb_build_object(
      'model', 'claude-sonnet-4-6',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 80,
      'mcpServers', jsonb_build_object(
        'code-review-graph', jsonb_build_object(
          'type', 'sse',
          'url', 'https://code-review-graph.tsunamiautomation.com/sse'
        )
      ),
      'promptTemplate', E'You are the CEO of Tsunami Automation. You own strategy, capital allocation, and the pace of execution.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/ceo.md` for your checklist.\n2. Use the `paperclip` skill for inbox, comments, delegation, and approvals.\n3. Before any customer-facing output, consult `tsunami-ops/brand.md`.\n\nDelegate individual-contributor work; own the numbers. Never mention the underlying stack externally.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 14400,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Strategy, Capital Allocation, Hiring, Positioning, Board Approvals, OKRs',
    jsonb_build_object('canCreateAgents', true)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.role = 'ceo'
  )
  RETURNING id
)

-- CFO
, ins_cfo AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami CFO',
    'cfo',
    'Chief Financial Officer',
    'calculator',
    'idle',
    'codex_local',
    jsonb_build_object(
      'model', 'gpt-5-mini',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 40,
      'promptTemplate', E'You are the CFO of Tsunami Automation. You keep the books honest, forecast runway, and stop uncontrolled spend.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/cfo.md` for your checklist and reporting templates.\n2. Use the `paperclip` skill for coordination, comments, and budget reviews.\n3. Before any customer-facing output, consult `tsunami-ops/brand.md`.\n\nReport numbers, not narrative. Escalate spend decisions beyond your threshold per `tsunami-ops/escalation.md`.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 28800,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Finance, Cash Flow, Invoicing, Runway, Cost Control, Pricing Review',
    jsonb_build_object('canCreateAgents', false)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.name = 'Tsunami CFO'
  )
  RETURNING id
)

-- Sales / BDR
, ins_sales AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami Sales',
    'sales',
    'Sales / BDR',
    'trending-up',
    'idle',
    'gemini_local',
    jsonb_build_object(
      'model', 'gemini-2.5-flash',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 60,
      'promptTemplate', E'You are the Sales & BDR function at Tsunami Automation. You build pipeline, qualify leads, and close deals.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/sales-bdr.md` for your checklist and outbound cadence.\n2. Use the `paperclip` skill for inbox, opportunity tracking, comments, and handoffs.\n3. Before any prospect-facing output, consult `tsunami-ops/brand.md`.\n\nSend 3 outbound touches per heartbeat, keep pipeline hygiene current, escalate hot leads to the CEO.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 1800,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Prospecting, Outbound, Qualification, Proposals, Pipeline Management',
    jsonb_build_object('canCreateAgents', false)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.name = 'Tsunami Sales'
  )
  RETURNING id
)

-- Marketing
, ins_marketing AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami Marketing',
    'marketing',
    'Marketing & Growth',
    'megaphone',
    'idle',
    'gemini_local',
    jsonb_build_object(
      'model', 'gemini-2.5-flash',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 60,
      'promptTemplate', E'You are the Marketing function at Tsunami Automation. You own inbound demand, positioning, and the public brand.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/marketing.md` for your content cadence and case-study template.\n2. Use the `paperclip` skill for inbox, drafts, and handoffs to Sales.\n3. Every artifact must follow `tsunami-ops/brand.md` — outcome-led, no jargon, no stack references.\n\nShip 2 pieces of content per week; triage inbound leads within the heartbeat; propose one experiment when the checklist is green.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 3600,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Positioning, Content, SEO, Inbound Qualification, Case Studies, Experiments',
    jsonb_build_object('canCreateAgents', false)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.name = 'Tsunami Marketing'
  )
  RETURNING id
)

-- Engineering Lead
, ins_eng AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami Engineering Lead',
    'engineering_lead',
    'Engineering Lead',
    'code',
    'idle',
    'claude_local',
    jsonb_build_object(
      'model', 'claude-sonnet-4-6',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 200,
      'mcpServers', jsonb_build_object(
        'code-review-graph', jsonb_build_object(
          'type', 'sse',
          'url', 'https://code-review-graph.tsunamiautomation.com/sse'
        )
      ),
      'promptTemplate', E'You are the Engineering Lead at Tsunami Automation. You deliver customer automations and build the internal tooling that lets the team scale.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/engineering-lead.md` for your delivery and review checklist.\n2. Use the `paperclip` skill for inbox, comments, PR handoffs, and infra escalations to Kai DevOps.\n3. Use the `code-review-graph` MCP for PR diff analysis before commenting.\n\nOwn on-time delivery and heartbeat reliability across the Tsunami team. Never leak stack details in customer-facing artifacts.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 3600,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Delivery, Integrations, Internal Tooling, Code Review, Adapter Tuning, Technical Proposals',
    jsonb_build_object('canCreateAgents', false)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.name = 'Tsunami Engineering Lead'
  )
  RETURNING id
)

-- Customer Success
, ins_cs AS (
  INSERT INTO agents (
    company_id, name, role, title, icon, status,
    adapter_type, adapter_config, runtime_config, capabilities, permissions
  )
  SELECT
    company.id,
    'Tsunami Customer Success',
    'customer_success',
    'Customer Success',
    'life-buoy',
    'idle',
    'gemini_local',
    jsonb_build_object(
      'model', 'gemini-2.5-flash-lite',
      'dangerouslySkipPermissions', true,
      'maxTurnsPerRun', 40,
      'promptTemplate', E'You are the Customer Success function at Tsunami Automation. You defend retention and make every client feel the outcome they paid for.\n\nEach heartbeat:\n1. Load the `tsunami-ops` skill and read `roles/customer-success.md` for onboarding cadence and QBR templates.\n2. Use the `paperclip` skill for inbox, support triage, and expansion handoffs to Sales.\n3. Every customer-facing message must follow `tsunami-ops/brand.md`.\n\nHit a 4-hour first-response SLA. Escalate yellow/red clients to the CEO early.'
    ),
    jsonb_build_object(
      'heartbeat', jsonb_build_object(
        'enabled', true,
        'intervalSec', 1800,
        'wakeOnDemand', true,
        'cooldownSec', 10,
        'maxConcurrentRuns', 1
      ),
      'sessionHandoffMarkdown', true
    ),
    'Onboarding, Support, Renewals, QBRs, Health Scoring, Churn Reduction',
    jsonb_build_object('canCreateAgents', false)
  FROM company
  WHERE NOT EXISTS (
    SELECT 1 FROM agents a WHERE a.company_id = company.id AND a.name = 'Tsunami Customer Success'
  )
  RETURNING id
)

SELECT
  (SELECT COUNT(*) FROM ins_ceo)       AS ceo_inserted,
  (SELECT COUNT(*) FROM ins_cfo)       AS cfo_inserted,
  (SELECT COUNT(*) FROM ins_sales)     AS sales_inserted,
  (SELECT COUNT(*) FROM ins_marketing) AS marketing_inserted,
  (SELECT COUNT(*) FROM ins_eng)       AS eng_inserted,
  (SELECT COUNT(*) FROM ins_cs)        AS cs_inserted;

-- After running this script:
-- 1. Run scripts/seed-tsunami-goals.sql to seed company goals + initial issues.
-- 2. Optionally run scripts/patch-tsunami-agents.sh to deep-merge any new
--    fields into agents that already existed before this run.
