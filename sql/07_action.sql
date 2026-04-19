-- ============================================================================
-- Account Planning — action Schema
-- ============================================================================
-- PURPOSE
--   This schema implements a full-lifecycle action engine for the Account
--   Planning platform.  An "action" is anything a sales rep (or the AI agent)
--   should *do* with respect to a customer — a call, a proposal, a quarterly
--   review, an automated renewal alert, etc.
--
-- CONCEPTUAL LAYERS  (read top-to-bottom — each layer depends on the one above)
--
--   1. STATUS DEFINITIONS   — vocabulary: what states an action can be in
--   2. ACTION TYPES         — blueprints: what kinds of actions exist
--   3. TYPE DEPENDENCIES    — DAG templates: which type must come before which
--   4. ACTIONS              — instances: individual action records for real work
--   5. ACTION DEPENDENCIES  — instance-level DAG edges that mirror the templates
--   6. RECURRENCE           — schedules: auto-generate repeating instances
--   7. ESCALATION RULES     — guardrails: what happens when SLAs are breached
--   8. EXECUTION LOG        — audit trail: every automated execution attempt
--
-- MULTI-TENANCY
--   Every table carries tenant_id.  Rows from different tenants are logically
--   isolated; combine this with Row-Level Security policies in your application
--   layer for full data separation.
--
-- DAG OVERVIEW
--   The platform uses a Directed Acyclic Graph (DAG) model at two levels:
--     • Template level  (action_type_dependency):  defines *in general* that,
--       e.g., "Discovery Call" must be finished before "Proposal Sent".
--     • Instance level  (action_dependency):        records the *actual* edge
--       between two concrete action rows inside a running workflow.
--   Cycle detection is enforced at the application layer, not by the DB.
-- ============================================================================

-- ============================================================================
-- 7.1  STATUS DEFINITIONS  (Tenant-Configurable)
-- ============================================================================
-- CONCEPT
--   Before you can track action instances you need a shared vocabulary for
--   "what state is this action in?"  Different companies use different terms
--   (e.g. "Pending / In-Flight / Done" vs. "Open / Active / Closed"), so
--   statuses are *not* hard-coded.  Each tenant defines its own status set here.
--
-- CATEGORIES  (the only fixed vocabulary — drives workflow engine behaviour)
--   • initial    — the action just existed/was created but work hasn't started
--                  e.g. "New", "Queued"
--   • active     — work is in progress
--                  e.g. "In Progress", "Waiting for Customer"
--   • terminal   — successfully completed, no more transitions expected
--                  e.g. "Done", "Closed Won"
--   • cancelled  — abandoned before completion
--                  e.g. "Cancelled", "Withdrawn"
--   • on_hold    — paused; may resume later
--                  e.g. "On Hold", "Requires Approval"
--
-- HOW IT IS USED
--   action.action.status_id → this table.
--   The workflow engine checks the category column to decide whether an action
--   is eligible to trigger downstream successors in the DAG.  Only a terminal
--   status marks a predecessor as "done".
--
-- EXAMPLE ROWS (tenant A)
--   code='NEW',         name='New',         category='initial'
--   code='IN_PROGRESS', name='In Progress',  category='active'
--   code='DONE',        name='Done',         category='terminal'
--   code='ON_HOLD',     name='On Hold',      category='on_hold'
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.status_definition (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    code            VARCHAR(50) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    category        VARCHAR(30) NOT NULL
                    CHECK (category IN ('initial', 'active', 'terminal', 'cancelled', 'on_hold')),
    display_order   INTEGER NOT NULL DEFAULT 0,
    color           VARCHAR(7),           -- hex color for UI badges, e.g. '#3B82F6'
    is_default      BOOLEAN NOT NULL DEFAULT false,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

COMMENT ON TABLE action.status_definition IS 'Tenant-defined action statuses. Companies can add/modify/remove statuses.';
COMMENT ON COLUMN action.status_definition.category IS 'Logical grouping for workflow engine: initial → active → terminal/cancelled';

-- ============================================================================
-- 7.2  ACTION TYPES  (Templates / Blueprints)
-- ============================================================================
-- CONCEPT
--   An action type is the *blueprint* for a class of work — think of it as a
--   reusable task template.  Every concrete action (section 7.4) is stamped
--   from one of these blueprints and inherits its defaults.
--
--   This separation of "type" from "instance" lets you:
--     • Change the default SLA for "Quarterly Business Review" once and have it
--       automatically apply to all future QBR actions.
--     • Define which fields reps *must* fill in when completing an action
--       (required_fields).
--     • Wire up automation: some types are executed by the AI agent instead of
--       a human (is_automated = true).
--
-- CATEGORIES
--   sales          — revenue-driving activities (proposals, demos, negotiations)
--   service        — post-sale support and account health activities
--   follow_up      — reminders and check-ins
--   administrative — internal paperwork, approvals
--   automated      — fully machine-driven (renewal alerts, data enrichment)
--   communication  — outbound messages (emails, calls, SMS campaigns)
--   onboarding     — new customer ramp-up tasks
--
-- KEY JSONB FIELDS
--   automation_config — only populated for automated types.  Specifies:
--     • trigger conditions ("on score drop below 0.4")
--     • execution steps (which API to call, in which order)
--     • retry policy (max attempts, back-off strategy)
--   required_fields   — JSON array of field names reps must fill before the
--     action can transition to a terminal status.
--     e.g. ["outcome", "next_step_date", "revenue_impact"]
--   tracking_config   — declares *what* metrics to capture on completion.
--     The data is stored as action.action.outcome (JSONB).
--
-- APPROVAL WORKFLOW
--   New or edited action types can require a manager sign-off:
--   created_by → approved_by / approved_at pattern.
--
-- EXAMPLE ROWS
--   code='QBR',                name='Quarterly Business Review',
--     category='sales',        default_sla_hours=72,  is_automated=false
--   code='RENEWAL_ALERT',      name='Renewal Alert Email',
--     category='automated',    is_automated=true,
--     automation_config='{"trigger":{"days_before_renewal":60}, "step":"send_email"}'
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_type (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    code                VARCHAR(100) NOT NULL,
    name                VARCHAR(255) NOT NULL,
    description         TEXT,
    category            VARCHAR(50) NOT NULL
                        CHECK (category IN ('sales', 'service', 'follow_up', 'administrative', 'automated', 'communication', 'onboarding')),
    is_automated        BOOLEAN NOT NULL DEFAULT false,
    automation_config   JSONB,            -- see note above; NULL for manual types
    default_sla_hours   INTEGER,          -- NULL = no SLA enforced by default
    default_priority    VARCHAR(20) NOT NULL DEFAULT 'medium'
                        CHECK (default_priority IN ('low', 'medium', 'high', 'critical')),
    required_fields     JSONB NOT NULL DEFAULT '[]',
    tracking_config     JSONB NOT NULL DEFAULT '{}',
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_by          UUID REFERENCES core.user_(id),
    approved_by         UUID REFERENCES core.user_(id),
    approved_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

COMMENT ON TABLE action.action_type IS 'Action type templates. Defines what actions look like, their SLA, automation, and tracking.';
COMMENT ON COLUMN action.action_type.automation_config IS 'For automated types: triggers, execution steps, API configs, retry policies';
COMMENT ON COLUMN action.action_type.tracking_config IS 'What to track upon completion: {"fields": ["outcome", "revenue_impact", "next_step"]}';

-- ============================================================================
-- 7.3  ACTION TYPE DEPENDENCIES  (DAG Template Edges)
-- ============================================================================
-- CONCEPT
--   This table encodes the *template-level* rules about which action types
--   must come before (or after) which others.  Think of it as the "factory
--   settings" for a workflow: whenever a workflow containing these types is
--   instantiated, these edges are copied into action_dependency (7.5) as
--   concrete instance edges.
--
--   The graph formed by these rows must be a DAG (no cycles).  The application
--   layer is responsible for rejecting INSERTs that would create a cycle.
--
-- DEPENDENCY TYPES  (classic project-management semantics)
--   finish_to_start  (default) — successor cannot START until predecessor is DONE
--                                 most common: "Discovery Call" → "Proposal"
--   start_to_start            — successor cannot START until predecessor STARTS
--                                 e.g. "Internal Kickoff" → "External Kickoff"
--   finish_to_finish          — successor cannot FINISH until predecessor FINISHES
--                                 e.g. "Legal Review" → "Contract Sign-Off"
--
-- DELAY
--   delay_hours lets you encode a mandatory waiting period between steps.
--   e.g. delay_hours=24 on "Send Follow-Up Email" after "Demo" means the
--   email cannot be scheduled until 24 hours after the demo is marked done.
--
-- CONDITIONS (JSONB)
--   Optional guard clauses that further restrict when the dependency is active.
--   e.g. {"only_if_outcome": "positive"} — only chain to the next step if the
--   predecessor was completed with a positive outcome.
--
-- EXAMPLE ROWS (tenant A)
--   predecessor=DISCOVERY_CALL → successor=PROPOSAL,  type=finish_to_start, delay=0
--   predecessor=PROPOSAL       → successor=NEGOTIATION, type=finish_to_start, delay=48
--   predecessor=NEGOTIATION    → successor=CONTRACT,    type=finish_to_start, mandatory=true
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_type_dependency (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    predecessor_type_id     UUID NOT NULL REFERENCES action.action_type(id),
    successor_type_id       UUID NOT NULL REFERENCES action.action_type(id),
    dependency_type         VARCHAR(30) NOT NULL DEFAULT 'finish_to_start'
                            CHECK (dependency_type IN ('finish_to_start', 'start_to_start', 'finish_to_finish')),
    is_mandatory            BOOLEAN NOT NULL DEFAULT true,
    delay_hours             INTEGER NOT NULL DEFAULT 0,
    conditions              JSONB NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, predecessor_type_id, successor_type_id),
    CONSTRAINT chk_no_self_dep CHECK (predecessor_type_id != successor_type_id)
);

COMMENT ON TABLE action.action_type_dependency IS 'DAG edges between action types. Cycle detection enforced at application layer.';
COMMENT ON COLUMN action.action_type_dependency.delay_hours IS 'Minimum delay between predecessor completion and successor start';

-- ============================================================================
-- 7.4  ACTIONS  (Instances — the heart of the schema)
-- ============================================================================
-- CONCEPT
--   An action is a single unit of work assigned to an employee, tied to a
--   customer (and optionally a product), with a clear deadline, priority, and
--   lifecycle status.  Every action is an *instance* of an action_type.
--
-- ORIGINS  (the "source" field)
--   Actions can be created in four ways:
--     manual          — rep creates it by hand in the UI
--     ai_recommended  — the AI agent scored the customer and suggested this
--                       action (source_model_id + source_score_id trace back
--                       to the analytics schema)
--     rule_based      — a deterministic business rule fired (e.g. "product
--                       renewal < 60 days away → create renewal action")
--     automated       — an automated action_type executed itself
--     recurring       — generated by action_recurrence (7.6)
--
-- WORKFLOW GROUPING
--   parent_action_id — allows tree-shaped sub-tasks (a proposal action can
--     have child actions for each internal approval step).
--   workflow_id      — a free UUID that groups *all* sibling actions in one
--     multi-step workflow execution.  Use it to pull the full workflow picture:
--     SELECT * FROM action.action WHERE workflow_id = '<uuid>';
--
-- SLA & ESCALATION
--   due_date        — business-meaningful deadline visible to the rep
--   sla_deadline    — technical SLA deadline used by the escalation engine; may
--                     differ from due_date (e.g. SLA = due_date − 4 hours)
--   escalation_level — incremented by the escalation engine (7.7) each time the
--                     action is escalated; starts at 0
--
-- AI CONTEXT
--   context (JSONB) stores the reasoning snapshot that caused this action to
--   be created.  For AI-recommended actions this includes model scores, customer
--   health signals, and the natural-language justification.  This is the
--   "why did the agent suggest this?" audit trail.
--
-- OUTCOME
--   outcome (JSONB) is populated by reps upon completion, guided by
--   action_type.tracking_config.  Examples:
--     {"result": "meeting_scheduled", "revenue_impact": 50000, "next_step": "2026-06-01"}
--
-- TRIGGER TRACEABILITY
--   These four columns record the exact code path that created this action row.
--   They are the primary tool for detecting *unintended* action creation —
--   e.g. a rule that fires twice, an agent loop that spawns duplicate actions,
--   or a webhook that is called unexpectedly.
--
--   trigger_module     — the logical service/module that owns the creation call
--                        e.g. 'churn_risk_engine', 'renewal_rule_engine',
--                             'agent_planner', 'recurrence_scheduler'
--   trigger_function   — the specific function / step inside that module
--                        e.g. 'evaluate_churn_cohort', 'plan_next_actions',
--                             'generate_renewal_tasks'
--   trigger_event_type — the event or condition that caused the trigger to fire
--                        e.g. 'score_threshold_breach', 'rule_match',
--                             'agent_decision', 'schedule_tick', 'api_webhook'
--   trigger_call_stack — ordered JSON array of the full call chain for deep
--                        debugging; populated only when verbose tracing is on
--                        e.g. ["agent_orchestrator", "plan_step", "create_action"]
--
--   MONITORING QUERY — find unexpected bulk action creation:
--     SELECT trigger_module, trigger_function, trigger_event_type,
--            COUNT(*) AS cnt, DATE_TRUNC('hour', created_at) AS hour
--     FROM action.action
--     GROUP BY 1,2,3,4
--     HAVING COUNT(*) > 50
--     ORDER BY cnt DESC;
--
-- EXAMPLE ROW
--   type=DISCOVERY_CALL, customer=Acme Corp, assigned_to=jane.doe@co,
--   status=IN_PROGRESS, priority=high, due_date='2026-05-01',
--   source=ai_recommended, context={"churn_risk_score": 0.82, "reason": "No contact in 60 days"},
--   trigger_module='churn_risk_engine', trigger_function='evaluate_churn_cohort',
--   trigger_event_type='score_threshold_breach'
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    action_type_id      UUID NOT NULL REFERENCES action.action_type(id),
    parent_action_id    UUID REFERENCES action.action(id),  -- NULL = top-level action
    workflow_id         UUID,                               -- groups actions in one workflow run
    customer_id         UUID REFERENCES customer.customer(id),
    product_id          UUID REFERENCES product.product(id),
    assigned_to         UUID NOT NULL REFERENCES core.employee(id),
    status_id           UUID NOT NULL REFERENCES action.status_definition(id),
    priority            VARCHAR(20) NOT NULL DEFAULT 'medium'
                        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    title               VARCHAR(500) NOT NULL,
    description         TEXT,
    context             JSONB NOT NULL DEFAULT '{}',        -- AI reasoning snapshot
    due_date            TIMESTAMPTZ,
    sla_deadline        TIMESTAMPTZ,
    escalation_level    INTEGER NOT NULL DEFAULT 0,
    started_at          TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,
    cancellation_reason TEXT,
    outcome             JSONB,                              -- rep-filled completion data
    source              VARCHAR(50) NOT NULL DEFAULT 'manual'
                        CHECK (source IN ('ai_recommended', 'manual', 'rule_based', 'automated', 'recurring')),
    source_model_id     UUID REFERENCES analytics.model(id),
    source_score_id     UUID,                              -- FK to analytics score row (loosely typed)
    -- Trigger traceability: records the code path that created this action
    trigger_module      VARCHAR(100),                     -- logical service/module e.g. 'churn_risk_engine'
    trigger_function    VARCHAR(200),                     -- specific function e.g. 'evaluate_churn_cohort'
    trigger_event_type  VARCHAR(100),                     -- event kind e.g. 'score_threshold_breach'
    trigger_call_stack  JSONB,                            -- full ordered call chain; NULL unless verbose tracing on
    created_by          UUID REFERENCES core.user_(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE action.action IS 'Action instances. Can be part of multi-step workflows (parent_action_id, workflow_id).';
COMMENT ON COLUMN action.action.context IS 'AI context: model scores, customer insights, reasoning that triggered this action';
COMMENT ON COLUMN action.action.outcome IS 'Result data collected based on action_type.tracking_config';
COMMENT ON COLUMN action.action.workflow_id IS 'Groups actions belonging to the same workflow instance';
COMMENT ON COLUMN action.action.trigger_module IS 'Logical service/module that initiated this action creation (for traceability)';
COMMENT ON COLUMN action.action.trigger_function IS 'Specific function/step inside trigger_module that called the creation';
COMMENT ON COLUMN action.action.trigger_event_type IS 'Event or condition that caused the trigger to fire (e.g. score_threshold_breach)';
COMMENT ON COLUMN action.action.trigger_call_stack IS 'Ordered array of the full call chain; populated only when verbose tracing is enabled';

-- ============================================================================
-- 7.5  ACTION DEPENDENCIES  (Instance-Level DAG Edges)
-- ============================================================================
-- CONCEPT
--   While action_type_dependency (7.3) captures the *general* rule ("a Proposal
--   always follows a Discovery Call"), this table captures the *specific* edge
--   between two *real* action instances inside a live workflow run.
--
--   RELATIONSHIP TO 7.3
--   Think of 7.3 as the "class diagram" and 7.5 as the "object diagram":
--     • 7.3 says:  type DISCOVERY_CALL  → type PROPOSAL  (rule)
--     • 7.5 says:  action #abc123       → action #def456 (fact for Acme Corp run)
--
--   When a workflow is instantiated, the application:
--     1. Creates one action row (7.4) per step.
--     2. Copies each matching action_type_dependency edge into this table,
--        substituting the concrete action IDs.
--
--   WHY A SEPARATE TABLE?
--   Storing edges in a dedicated table makes it easy to:
--     • Query "which actions are blocking this one?" (blocked = is_satisfied=false)
--     • Mark a dependency as satisfied (is_satisfied=true, satisfied_at=now())
--       when the predecessor transitions to a terminal status — without touching
--       the action row itself.
--     • Support ad-hoc dependencies added at runtime (not derived from a type template).
--
-- LIFECYCLE
--   is_satisfied starts as false.  The workflow engine flips it to true —
--   and sets satisfied_at — when the predecessor action reaches a terminal status
--   (and any delay_hours have elapsed).  Once all incoming edges for an action
--   are satisfied, the action is eligible to start.
--
-- EXAMPLE ROWS (workflow run #wf-001, Acme Corp)
--   predecessor=#abc123 (Discovery Call - DONE) → successor=#def456 (Proposal - NEW)
--     is_satisfied=true,  satisfied_at='2026-04-19 10:00'
--   predecessor=#def456 (Proposal - IN_PROGRESS) → successor=#ghi789 (Contract - NEW)
--     is_satisfied=false, satisfied_at=NULL   ← Proposal not done yet
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_dependency (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    predecessor_action_id   UUID NOT NULL REFERENCES action.action(id),
    successor_action_id     UUID NOT NULL REFERENCES action.action(id),
    dependency_type         VARCHAR(30) NOT NULL DEFAULT 'finish_to_start',
    is_satisfied            BOOLEAN NOT NULL DEFAULT false,
    satisfied_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (predecessor_action_id, successor_action_id),
    CONSTRAINT chk_action_dep_diff CHECK (predecessor_action_id != successor_action_id)
);

COMMENT ON TABLE action.action_dependency IS 'Instance-level dependencies between actions within a workflow.';

-- ============================================================================
-- 7.6  ACTION RECURRENCE  (Scheduled Auto-Generation)
-- ============================================================================
-- CONCEPT
--   Some actions should happen on a *regular schedule* — a monthly health check
--   call with every strategic account, a quarterly business review, an annual
--   contract renewal preparation, etc.  Rather than requiring reps to manually
--   create these every time, the recurrence engine reads this table and
--   auto-generates action instances at the right time.
--
-- HOW IT WORKS
--   1. A recurrence record is created once, linking an action_type, a customer,
--      and an assignee.
--   2. A background job (cron or queue worker) periodically reads rows where
--      next_occurrence ≤ NOW() and is_active = true.
--   3. For each such row it:
--        a. Creates a new action row (7.4) using template_data as defaults,
--           with source='recurring'.
--        b. Updates last_generated_at = NOW().
--        c. Calculates and writes the next next_occurrence based on
--           recurrence_rule.
--   4. If end_date is reached the record is deactivated (is_active = false).
--
-- RECURRENCE RULE FORMAT
--   Inspired by iCalendar RRULE, stored as JSONB for flexibility:
--     {"frequency": "monthly", "interval": 1, "day_of_month": 1}
--       → fires on the 1st of every month
--     {"frequency": "weekly",  "interval": 2, "day_of_week": "monday"}
--       → fires every other Monday
--     {"frequency": "quarterly"}
--       → fires every 3 months from last_generated_at
--
-- TEMPLATE DATA
--   template_data is a JSONB object that pre-fills the generated action:
--     {"title": "Monthly Health Check — {{customer_name}}",
--      "priority": "medium",
--      "description": "Standard monthly check-in. Review usage and open issues.",
--      "context": {"source": "recurrence"}}
--
-- EXAMPLE ROW
--   action_type=HEALTH_CHECK, customer=Acme Corp, assigned_to=jane.doe,
--   recurrence_rule={"frequency":"monthly","interval":1,"day_of_month":15},
--   next_occurrence='2026-05-15', end_date='2027-01-01'
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_recurrence (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    action_type_id      UUID NOT NULL REFERENCES action.action_type(id),
    customer_id         UUID REFERENCES customer.customer(id),
    assigned_to         UUID NOT NULL REFERENCES core.employee(id),
    recurrence_rule     JSONB NOT NULL,
    next_occurrence     TIMESTAMPTZ,
    last_generated_at   TIMESTAMPTZ,
    end_date            TIMESTAMPTZ,
    is_active           BOOLEAN NOT NULL DEFAULT true,
    template_data       JSONB NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE action.action_recurrence IS 'Recurring action schedules. Generates action instances based on recurrence_rule.';
COMMENT ON COLUMN action.action_recurrence.recurrence_rule IS 'iCal RRULE-like: {"frequency": "monthly", "interval": 1, "day_of_month": 1}';
COMMENT ON COLUMN action.action_recurrence.template_data IS 'Template for auto-generated actions: title, description, priority, context';

-- ============================================================================
-- 7.7  ACTION ESCALATION RULES
-- ============================================================================
-- CONCEPT
--   When an action misses its SLA or sits untouched for too long the platform
--   should *automatically* escalate it — not wait for someone to notice.  This
--   table defines the escalation ladder: who gets notified at what point, and
--   under what conditions.
--
-- HOW ESCALATION WORKS
--   escalation_level is the "rung" on the ladder (0 = no escalation yet).
--   Rules are evaluated in ascending order of escalation_level.
--
--   Example ladder for action_type = "High-Value Renewal":
--     Level 1: trigger after 48 overdue hours  → notify team_lead
--     Level 2: trigger after 96 overdue hours  → notify manager
--     Level 3: trigger if SLA missed           → notify manager_plus_1 (skip level)
--
--   The escalation engine:
--     1. Periodically scans open actions for breached trigger_conditions.
--     2. Finds the *next* unsatisfied rule for that action's type.
--     3. Increments action.escalation_level and fires the notification.
--
-- TRIGGER CONDITIONS (JSONB)
--   {"overdue_hours": 48}
--     → fire when (NOW() - due_date) > 48 hours AND status is not terminal
--   {"missed_sla": true}
--     → fire when sla_deadline has passed
--   {"overdue_pct": 0.5}
--     → fire when 50% of the SLA window has elapsed without progress
--
-- ESCALATE TO
--   manager         — the direct manager of the assigned employee
--   manager_plus_1  — the manager's manager (skip-level)
--   team_lead       — the team lead for the org unit
--   specific_user   — a named user (escalate_to_user_id)
--   specific_role   — everyone with a given RBAC role in the tenant
--
-- NOTIFICATION CONFIG (JSONB)
--   Controls *how* the escalation is communicated:
--     {"channels": ["email", "in_app"], "message_template_id": "esc_level1"}
--
-- EXAMPLE ROWS (action_type = HIGH_VALUE_RENEWAL)
--   level=1, trigger={"overdue_hours":48},  escalate_to='team_lead'
--   level=2, trigger={"overdue_hours":96},  escalate_to='manager'
--   level=3, trigger={"missed_sla":true},   escalate_to='manager_plus_1'
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_escalation_rule (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    action_type_id      UUID REFERENCES action.action_type(id),  -- NULL = applies to all types
    escalation_level    INTEGER NOT NULL,
    trigger_condition   JSONB NOT NULL,
    escalate_to         VARCHAR(50) NOT NULL
                        CHECK (escalate_to IN ('manager', 'manager_plus_1', 'specific_user', 'specific_role', 'team_lead')),
    escalate_to_user_id UUID REFERENCES core.user_(id),          -- only when escalate_to='specific_user'
    notification_config JSONB NOT NULL DEFAULT '{}',
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, action_type_id, escalation_level)
);

COMMENT ON TABLE action.action_escalation_rule IS 'Escalation rules: auto-escalate overdue/SLA-breached actions to managers.';
COMMENT ON COLUMN action.action_escalation_rule.trigger_condition IS '{"overdue_hours": 48} or {"missed_sla": true, "overdue_pct": 0.5}';

-- ============================================================================
-- 7.8  ACTION EXECUTION LOG  (Automated / Agent Audit Trail)
-- ============================================================================
-- CONCEPT
--   When an action is executed by the platform (rather than a human) every
--   attempt is recorded here.  This covers:
--     • automated action types (API calls, email sends, data enrichment jobs)
--     • AI agent executions (LLM-driven steps in a workflow)
--     • webhook callbacks
--     • manual retries triggered by an operator
--
--   This table answers the questions: "Did the automation run?",
--   "What did it send?", "What did the external system respond?",
--   "How many times did it retry and why did it fail?"
--
-- WHY PARTITION BY MONTH?
--   Execution logs are high-volume (every automated action can produce multiple
--   rows — one per attempt).  Range partitioning by created_at lets the DB
--   engine skip irrelevant months during queries and allows old partitions to be
--   archived or dropped cheaply without touching the live table.
--
--   NOTE: The application must create new monthly partitions *in advance* (e.g.
--   via a cron job or migration) before data arrives for that month.
--
-- KEY COLUMNS
--   execution_type   — who/what initiated this execution attempt
--   status           — outcome of this specific attempt (not the action's status)
--   api_endpoint     — the URL called; useful for debugging integration issues
--   request_payload  — exactly what was sent to the external system (GDPR note:
--                      scrub PII before storing if the endpoint receives it)
--   response_payload — raw response from the external system
--   http_status      — HTTP response code; 0 or NULL if network-level failure
--   correlation_id   — ID returned by (or sent to) the external system for
--                      cross-system tracing (e.g. email provider message ID)
--   retry_count      — how many times this particular execution has been retried
--   duration_ms      — wall-clock latency of the API call; use for performance SLOs
--
-- TRIGGER TRACEABILITY (execution side)
--   Mirrors the trigger fields on action.action but scoped to a *single
--   execution attempt*, not the original action creation.  Useful for:
--     • spotting which internal step (e.g. agent sub-task scheduler) is issuing
--       unexpected API calls
--     • correlating a burst of executions back to a specific code path
--
--   triggered_by_module   — service that initiated this attempt
--                           e.g. 'workflow_engine', 'agent_executor', 'retry_worker'
--   triggered_by_function — function that made the call
--                           e.g. 'run_step', 'retry_failed_automations'
--   trigger_call_stack    — full ordered call chain (verbose mode only)
--
-- API CALL COST TRACKING
--   For LLM / AI-API calls the platform should track token counts and dollar
--   costs per execution attempt.  This enables:
--     • per-action cost attribution  ("this churn analysis cost $0.03")
--     • per-tenant / per-module cost roll-ups for budgeting
--     • alerting when a single execution exceeds a cost threshold
--
--   model_used     — the model identifier charged for this call
--                   e.g. 'gpt-4o', 'gemini-1.5-pro', 'claude-3-5-sonnet'
--   tokens_input   — prompt / context tokens sent (billed at input rate)
--   tokens_output  — completion tokens received (billed at output rate)
--   cost_usd       — total cost in USD for this attempt, stored with 6 decimal
--                   places (sub-cent precision).  Calculated by the application
--                   using the provider price sheet at call time.
--   cost_metadata  — extra provider-specific cost breakdown:
--                   {"cached_tokens": 800, "reasoning_tokens": 200,
--                    "provider": "openai", "price_snapshot_id": "2026-Q2"}
--
--   COST ROLL-UP QUERY:
--     SELECT trigger_module, model_used,
--            SUM(tokens_input)  AS total_in,
--            SUM(tokens_output) AS total_out,
--            SUM(cost_usd)      AS total_cost_usd
--     FROM action.action_execution_log
--     WHERE created_at >= NOW() - INTERVAL '30 days'
--     GROUP BY 1, 2
--     ORDER BY total_cost_usd DESC;
--
-- READING THE LOG FOR A FAILING AUTOMATION
--   SELECT * FROM action.action_execution_log
--   WHERE action_id = '<uuid>'
--   ORDER BY started_at;
--   → See each attempt: first 'initiated', then retries with error_message,
--     finally 'success' or permanently 'failed'.
--
-- PARTITION TABLE (read-only reference — managed by migrations / cron)
--   action_execution_log_y2026m01  → January 2026
--   action_execution_log_y2026m02  → February 2026
--   ... and so on through December 2026
-- ============================================================================

CREATE TABLE IF NOT EXISTS action.action_execution_log (
    id                    UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id             UUID NOT NULL,
    action_id             UUID NOT NULL,
    execution_type        VARCHAR(30) NOT NULL
                          CHECK (execution_type IN ('automated', 'manual', 'retry', 'webhook', 'agent')),
    status                VARCHAR(30) NOT NULL
                          CHECK (status IN ('initiated', 'in_progress', 'success', 'failed', 'timeout', 'cancelled')),
    api_endpoint          VARCHAR(500),
    request_payload       JSONB,
    response_payload      JSONB,
    http_status           INTEGER,
    correlation_id        UUID,                   -- external system trace ID
    retry_count           INTEGER NOT NULL DEFAULT 0,
    max_retries           INTEGER,
    error_message         TEXT,
    error_code            VARCHAR(100),
    -- Trigger traceability (execution-side)
    triggered_by_module   VARCHAR(100),           -- service that initiated this attempt
    triggered_by_function VARCHAR(200),           -- function that made the call
    trigger_call_stack    JSONB,                  -- full ordered call chain (verbose mode)
    -- API call cost tracking
    model_used            VARCHAR(100),           -- e.g. 'gpt-4o', 'gemini-1.5-pro'
    tokens_input          INTEGER,               -- prompt/context tokens sent
    tokens_output         INTEGER,               -- completion tokens received
    cost_usd              NUMERIC(14,6),          -- total USD cost for this attempt
    cost_metadata         JSONB,                  -- provider-specific breakdown (cached tokens, etc.)
    started_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at          TIMESTAMPTZ,
    duration_ms           INTEGER,               -- wall-clock latency of the call
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE action.action_execution_log IS 'Execution audit trail for automated/agent actions. Partitioned monthly.';
COMMENT ON COLUMN action.action_execution_log.correlation_id IS 'External system correlation ID for cross-system tracing';
COMMENT ON COLUMN action.action_execution_log.triggered_by_module IS 'Service/module that initiated this execution attempt (traceability)';
COMMENT ON COLUMN action.action_execution_log.triggered_by_function IS 'Specific function that triggered this execution attempt';
COMMENT ON COLUMN action.action_execution_log.trigger_call_stack IS 'Ordered call chain array; populated only when verbose tracing is enabled';
COMMENT ON COLUMN action.action_execution_log.model_used IS 'AI/LLM model identifier charged for this call (e.g. gpt-4o)';
COMMENT ON COLUMN action.action_execution_log.tokens_input IS 'Prompt/context tokens sent to the model (billed at input rate)';
COMMENT ON COLUMN action.action_execution_log.tokens_output IS 'Completion tokens returned by the model (billed at output rate)';
COMMENT ON COLUMN action.action_execution_log.cost_usd IS 'Total USD cost for this attempt (6 decimal places for sub-cent precision)';
COMMENT ON COLUMN action.action_execution_log.cost_metadata IS 'Provider-specific cost breakdown: cached tokens, reasoning tokens, price snapshot';

-- Create initial monthly partitions
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m01 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m02 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m03 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m04 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m05 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m06 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m07 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m08 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m09 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m10 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m11 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS action.action_execution_log_y2026m12 PARTITION OF action.action_execution_log
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
