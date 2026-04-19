-- ============================================================================
-- Account Planning — config Schema
-- ============================================================================
-- Change management with approval workflows, environment separation
-- (draft/staging/production), feature flags per tenant, and
-- versioned configuration snapshots.
-- ============================================================================

-- ============================================================================
-- 10.1 CHANGE REQUESTS
-- ============================================================================
-- CONCEPT
--   Enterprise tenants often require a formal change management gate before any
--   configuration (e.g. a new action type, a revised metric formula) goes live
--   in production.  config.change_request is the central record that captures
--   *what* is changing, *why*, and *where it is in the approval pipeline*.
--
--   A change request stores both the current and proposed state as JSONB blobs
--   so reviewers can diff them directly and, if needed, roll back precisely.
--
-- EXAMPLE LIFECYCLE
--   1. A product manager drafts a new target metric formula.
--      → status = 'draft', environment = 'draft'
--   2. She submits it for peer review.
--      → status = 'pending_approval'
--   3. The IT lead approves and applies it to staging for UAT.
--      → status = 'approved', environment = 'staging'
--   4. After 2 weeks the change is promoted to production.
--      → status = 'applied', environment = 'production'
--   5. A regression is detected 3 days later and the change is reverted.
--      → status = 'rolled_back'
--
-- STATUS FLOW
--   draft → pending_approval → approved → applied → rolled_back
--                           ↘ rejected
--                           ↘ expired   (SLA timeout, never reviewed)
--
-- ENVIRONMENT FLOW
--   draft → staging → production
--   Changes must pass UAT in staging before they can be flagged for production.
--
-- NOTES
--   • current_state may be NULL for 'create' changes (nothing existed before).
--   • change_type = 'bulk_update' covers mass updates, e.g. retiring all
--     action_types for a deprecated product line at once.
--   • Whether this workflow is enforced is controlled by the tenant module
--     named 'change_management' in core.tenant_module.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.change_request (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    entity_type     VARCHAR(100) NOT NULL,
    entity_id       UUID,
    change_type     VARCHAR(20) NOT NULL
                    CHECK (change_type IN ('create', 'update', 'delete', 'bulk_update')),
    current_state   JSONB,
    proposed_state  JSONB NOT NULL,
    justification   TEXT,
    status          VARCHAR(30) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'pending_approval', 'approved', 'rejected', 'applied', 'rolled_back', 'expired')),
    environment     VARCHAR(20) NOT NULL DEFAULT 'draft'
                    CHECK (environment IN ('draft', 'staging', 'production')),
    submitted_by    UUID REFERENCES core.user_(id),
    submitted_at    TIMESTAMPTZ,
    reviewed_by     UUID REFERENCES core.user_(id),
    reviewed_at     TIMESTAMPTZ,
    review_notes    TEXT,
    applied_at      TIMESTAMPTZ,
    applied_by      UUID REFERENCES core.user_(id),
    version         INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE config.change_request IS 'Change management workflow. May not be enforced in every tenant (tenant_module config).';
COMMENT ON COLUMN config.change_request.entity_type IS 'What is being changed: action_type, metric_definition, status_definition, etc.';
COMMENT ON COLUMN config.change_request.environment IS 'Changes can be tested in draft/staging before going to production';

-- ============================================================================
-- 10.2 CHANGE REQUEST APPROVALS (Multi-Approver Support)
-- ============================================================================
-- CONCEPT
--   A single change request may require sign-off from multiple stakeholders
--   before it can progress.  For example, a change to commission calculation
--   rules might need approval from both the Finance Lead and the IT Security
--   team before it reaches production.
--
--   Each approver records their decision as an independent row in this table.
--   The application layer (not the DB) is responsible for evaluating the
--   quorum rule — e.g. "all 3 must approve" or "any 2 of 4 must approve" —
--   and for updating the parent change_request.status accordingly.
--
-- EXAMPLE
--   change_request #CR-0042 (entity_type = 'metric_definition') requires two
--   approvals:
--     Row 1: approver_id = Alice, decision = 'approved',  decided_at = 09:15
--     Row 2: approver_id = Bob,   decision = 'rejected',  comments = 'KPI formula is ambiguous'
--   → application logic marks CR-0042 as 'rejected' because one approver vetoed.
--
-- NOTES
--   • 'needs_revision' lets an approver request corrections without a full
--     reject-and-resubmit cycle.
--   • decided_at is set server-side (DEFAULT now()) so timestamps cannot be
--     back-dated by the client.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.change_request_approval (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    change_request_id   UUID NOT NULL REFERENCES config.change_request(id),
    approver_id         UUID NOT NULL REFERENCES core.user_(id),
    decision            VARCHAR(20) NOT NULL
                        CHECK (decision IN ('approved', 'rejected', 'needs_revision')),
    comments            TEXT,
    decided_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE config.change_request_approval IS 'Individual approver decisions on change requests. Supports multi-approver flows.';

-- ============================================================================
-- 10.3 FEATURE FLAGS
-- ============================================================================
-- CONCEPT
--   Feature flags decouple code deployments from feature releases.  A flag is
--   a named boolean switch that can be flipped at runtime — without a code
--   deploy — to enable or disable a capability for a specific tenant or subset
--   of users.
--
--   This is especially important for an AI-assisted platform where new agent
--   modules (e.g. "auto-suggest next best action") should be validated with a
--   small pilot group before full rollout.
--
-- KEY FIELDS
--   flag_key            — machine-readable name used in code to check the flag.
--                         Example: 'ai_suggestion_engine', 'bulk_target_upload'
--   is_enabled          — master switch; false means the flag is OFF for everyone
--                         in the tenant, regardless of rollout_percentage.
--   rollout_percentage  — when is_enabled = true, only this % of users in the
--                         tenant will actually see the feature (gradual rollout).
--                         Example: 10 → feature is live for ~10 % of active users.
--   conditions          — JSONB rule that further filters eligible users.
--                         Example: {"user_type": ["admin", "manager"], "region": ["TR"]}
--                         → only admins and managers in Turkey see the feature.
--
-- EXAMPLE SCENARIOS
--   Scenario A — Global kill-switch:
--     flag_key = 'ai_suggestion_engine', is_enabled = false
--     → AI suggestions are off for all users in this tenant immediately.
--
--   Scenario B — Pilot 10 % of Istanbul branch managers:
--     flag_key   = 'bulk_target_upload'
--     is_enabled = true, rollout_percentage = 10
--     conditions = {"user_type": ["manager"], "region": ["Istanbul"]}
--
--   Scenario C — Gradual AI adoption ramp:
--     Week 1: rollout_percentage = 5
--     Week 2: rollout_percentage = 25
--     Week 4: rollout_percentage = 100  ← full rollout
--
-- NOTES
--   The UNIQUE (tenant_id, flag_key) constraint ensures each flag has exactly
--   one configuration row per tenant.  The application references flags by
--   flag_key, so renaming a key is a breaking change.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.feature_flag (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    flag_key            VARCHAR(100) NOT NULL,
    is_enabled          BOOLEAN NOT NULL DEFAULT false,
    rollout_percentage  INTEGER DEFAULT 100
                        CHECK (rollout_percentage >= 0 AND rollout_percentage <= 100),
    conditions          JSONB NOT NULL DEFAULT '{}',
    description         TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, flag_key)
);

COMMENT ON TABLE config.feature_flag IS 'Tenant-level feature flags for gradual AI adoption and feature rollout.';
COMMENT ON COLUMN config.feature_flag.rollout_percentage IS '0–100 for gradual rollout to percentage of users';
COMMENT ON COLUMN config.feature_flag.conditions IS 'Targeting: {"user_type": ["admin", "manager"], "region": ["TR"]}';

-- ============================================================================
-- 10.4 CONFIGURATION VERSIONS
-- ============================================================================
-- CONCEPT
--   Some configuration objects — such as action status definitions, product
--   category trees, or KPI metric sets — are complex JSONB documents that
--   change over time and must be promoted through environments before going
--   live.  config.config_version provides an immutable snapshot store for
--   these documents, forming a promotion chain across environments.
--
--   Think of it as "Git for configuration": each commit (version) is
--   immutable; a promotion ("merge to main") is modelled by creating a new
--   row in the target environment that references its source via promoted_from.
--
-- PROMOTION CHAIN EXAMPLE
--   A tenant manages their action_statuses configuration:
--     v1 draft    → created by analyst
--     v2 staging  → promoted from v1 draft (promoted_from = v1.id)
--                   → UAT passes
--     v3 production → promoted from v2 staging (promoted_from = v2.id)
--                     is_active = true  ← only this row is "live"
--
--   If v3 needs a hotfix:
--     v4 draft    → patched copy
--     v4 staging  → promoted, tested
--     v5 production → promoted; is_active flips from v3 → v5
--
-- KEY FIELDS
--   config_type   — logical name of the config document group.
--                   Examples: 'action_statuses', 'metric_definitions',
--                             'product_categories', 'notification_templates'
--   version       — monotonically increasing integer per (tenant, config_type,
--                   environment).  The application increments this on each save.
--   environment   — 'draft' | 'staging' | 'production'.  Each environment has
--                   its own independent version counter.
--   config_data   — the full configuration snapshot as JSONB.
--   is_active     — true for the single "live" version in each environment.
--                   Only one row per (tenant, config_type, environment) should
--                   be active at a time; enforced at the application layer.
--   promoted_from — FK to the version in the previous environment that this
--                   row was cloned from.  NULL for the first draft ever created.
--
-- NOTES
--   • Rows are never UPDATE-d after creation (except toggling is_active).
--   • The UNIQUE constraint on (tenant_id, config_type, version, environment)
--     prevents accidental duplicate version numbers.
--   • To roll back, set is_active = false on the current version and
--     is_active = true on the previous version — no data is deleted.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.config_version (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    config_type     VARCHAR(100) NOT NULL,
    version         INTEGER NOT NULL,
    environment     VARCHAR(20) NOT NULL DEFAULT 'draft'
                    CHECK (environment IN ('draft', 'staging', 'production')),
    config_data     JSONB NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT false,
    promoted_from   UUID REFERENCES config.config_version(id),
    created_by      UUID REFERENCES core.user_(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    activated_at    TIMESTAMPTZ,
    UNIQUE (tenant_id, config_type, version, environment)
);

COMMENT ON TABLE config.config_version IS 'Versioned configuration snapshots with environment promotion chain.';
COMMENT ON COLUMN config.config_version.config_type IS 'Config group: action_statuses, metric_definitions, product_categories, etc.';
COMMENT ON COLUMN config.config_version.promoted_from IS 'Links to the previous environment version in promotion chain';
COMMENT ON COLUMN config.config_version.is_active IS 'Only one active per config_type+environment (enforced at application layer)';
