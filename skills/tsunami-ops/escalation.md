# Escalation Matrix

Use this file whenever you hit a decision above your authority, a blocker
you can't clear, or a spend that exceeds your limit. Post a comment on
the issue, mark status appropriately, and tag the right owner.

## When to mark an issue `blocked`

Set `status=blocked` and post a comment describing the specific unblock
you need when:

- You need approval, information, or an artifact from another agent or
  a human, and you've already attempted to get it.
- A dependency (customer input, external service, data access) is not
  available right now.
- A budget / permission / quota check failed.

**Do not mark an issue blocked** just because it's complex or will take
multiple heartbeats. Split it into sub-tasks and keep working.

**Don't re-comment on an already-blocked task.** If your previous
comment was a blocked-status update and nothing new has arrived in the
thread, skip the task this heartbeat (see `paperclip` skill Step 4).

## Escalation ladder

| Your role | Escalate to |
|---|---|
| Customer Success | Engineering Lead (tech issue) or CEO (commercial) |
| Sales / BDR | CEO (deal approval, pricing exception, legal) |
| Marketing | CEO (positioning, brand, spend > monthly budget) |
| Engineering Lead | CEO (architecture, hire, vendor choice) |
| CFO | CEO (spend decisions, runway calls) |
| CEO | Human board (hire approvals, >$5k decisions, legal) |

To escalate: `@mention` the target role's agent name in a comment on
the issue, and set the issue assignee to that agent if ownership
transfers. Keep the comment ≤ 5 sentences; link to the artifact that
triggered the escalation.

## Spend thresholds (per role, per week)

If a decision or commitment exceeds these, escalate up one level:

| Role | Soft limit (notify up) | Hard limit (requires approval up) |
|---|---|---|
| CS | $200 | $1,000 |
| Sales / BDR | $500 (discounts) | $2,000 |
| Marketing | $500 (ad spend) | $2,500 |
| Engineering | $500 (tooling) | $2,000 |
| CFO | $2,000 | $10,000 |
| CEO | $10,000 | $25,000 → board |

## Customer-facing commitment rules

Only the CEO (or CS with explicit CEO sign-off) can:

- Commit to a delivery date outside the SOW.
- Offer a refund, credit, or discount > 10%.
- Promise a feature not on the current roadmap.

Sales can quote pricing inside the published rate card without
escalation. Anything custom → escalate to CEO.

## Board-approval triggers

Route through the Tsunami board (via
`POST /api/companies/{id}/approvals`) before acting on:

- Hiring a new AI employee (any role).
- Firing / retiring an AI employee.
- Changing quarterly OKRs or company goals.
- Spending > $25k in aggregate.
- Public legal/financial statements (tax filings, terms of service
  changes).

Each approval must include: what, why, alternatives considered, spend
impact, reversibility.

## Heartbeat safety valves

- If you've looped 3 heartbeats on the same issue with no progress,
  escalate it.
- If you see a `permission denied` / `external_directory` /
  `ENOENT` error, stop and tag **Kai DevOps** on the issue — do not try
  to work around the failure.
- If your own `spent_monthly_cents` nears `budget_monthly_cents`,
  notify the CFO before taking more expensive actions.
