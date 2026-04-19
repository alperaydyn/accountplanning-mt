-- ============================================================================
-- Account Planning — core Schema
-- ============================================================================
-- Tenant management, ABAC-based IAM, SSO/LDAP, delegation/impersonation,
-- closure-table organization hierarchy with historical assignments.
-- ============================================================================

-- ============================================================================
-- 2.1 TENANT MANAGEMENT
-- ============================================================================
-- CONCEPT
--   The platform is multi-tenant: every data row in every schema is scoped to a
--   tenant.  This section defines the root entities that govern that isolation.
--
--   core.tenant       — the top-level entity representing one customer company
--                       (e.g. "Akbank", "Garanti BBVA").  Every tenant-scoped
--                       table has a tenant_id FK pointing here.
--   core.tenant_module — controls which optional features are enabled for each
--                       tenant (feature-flag pattern).  A tenant that has not
--                       activated the "analytics" module should never see
--                       analytics data — enforced by application-layer checks
--                       keyed to this table.
--
-- TENANT STATUS LIFECYCLE
--   onboarding  → active  → suspended  → decommissioned
--   Only 'active' tenants should receive scheduled jobs or AI agent runs.
--
-- COMPLIANCE
--   kvkk_gdpr_config stores tenant-specific compliance settings: data retention
--   periods, DPO contact details, and the legal basis defaults applied when no
--   explicit consent is recorded.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.tenant (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code                    VARCHAR(50) NOT NULL UNIQUE,
    name                    VARCHAR(255) NOT NULL,
    industry                VARCHAR(100),
    status                  VARCHAR(20) NOT NULL DEFAULT 'onboarding'
                            CHECK (status IN ('onboarding', 'active', 'suspended', 'decommissioned')),
    settings                JSONB NOT NULL DEFAULT '{}',
    data_residency_region   VARCHAR(50) NOT NULL DEFAULT 'TR',
    kvkk_gdpr_config        JSONB NOT NULL DEFAULT '{}',
    onboarded_at            TIMESTAMPTZ,
    suspended_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.tenant IS 'Root entity for multi-tenancy. Every tenant-scoped entity references this.';
COMMENT ON COLUMN core.tenant.kvkk_gdpr_config IS 'KVKK/GDPR configuration: retention periods, DPO contact, legal basis defaults';
COMMENT ON COLUMN core.tenant.data_residency_region IS 'Data residency region code (TR, EU, etc.) for compliance routing';

CREATE TABLE IF NOT EXISTS core.tenant_module (
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    module_code     VARCHAR(100) NOT NULL,
    is_enabled      BOOLEAN NOT NULL DEFAULT false,
    config_override JSONB NOT NULL DEFAULT '{}',
    enabled_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, module_code)
);

COMMENT ON TABLE core.tenant_module IS 'Which feature modules are enabled per tenant, with tenant-specific config overrides';

-- ============================================================================
-- 2.2 IDENTITY & ACCESS MANAGEMENT (ABAC)
-- ============================================================================
-- CONCEPT
--   This section implements Attribute-Based Access Control (ABAC) — a model
--   where access decisions are made by evaluating *attributes* of the subject
--   (user), resource, and environment, rather than a simple role list.
--
--   ABAC vs. RBAC
--     Classic RBAC: "User is Manager → can see all branches."
--     ABAC:         "User.region == Resource.region AND User.clearance_level >= 3"
--     ABAC gives us row-level precision: a manager in Marmara Region sees only
--     Marmara data, even though she has the same role as an Istanbul manager.
--
-- TABLES IN THIS SECTION
--   core.user_        — application identities (named with trailing _ to avoid
--                       the PostgreSQL reserved word "user").
--   core.sso_config   — per-tenant IdP configuration for SAML, OIDC, and LDAP.
--                       Enables enterprise SSO without hard-coding credentials.
--   core.abac_policy  — the policy rules evaluated at runtime.  The application
--                       policy-engine iterates over these rows and returns a
--                       permit/deny decision for each access request.
--   core.delegation   — allows User A to temporarily act *as* User B within a
--                       defined scope (e.g. while User B is on leave).
--   core.impersonation_log — immutable audit trail of every session where one
--                       user acted on behalf of another.
--
-- USER ATTRIBUTES (ABAC)
--   The attributes JSONB column stores the ABAC subject attributes directly on
--   the user row for fast policy evaluation without extra joins:
--     {"region": "Marmara", "lob": "retail", "clearance_level": 3}
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.user_ (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    external_id         VARCHAR(255),
    identity_provider   VARCHAR(50) NOT NULL DEFAULT 'local'
                        CHECK (identity_provider IN ('local', 'saml', 'oidc', 'ldap')),
    username            VARCHAR(255) NOT NULL,
    email               VARCHAR(255),
    display_name        VARCHAR(255),
    phone               VARCHAR(50),
    status              VARCHAR(20) NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'inactive', 'locked', 'pending')),
    user_type           VARCHAR(50) NOT NULL DEFAULT 'sales_rep'
                        CHECK (user_type IN ('sales_rep', 'manager', 'admin', 'system', 'analyst', 'app_admin')),
    attributes          JSONB NOT NULL DEFAULT '{}',
    last_login_at       TIMESTAMPTZ,
    password_hash       VARCHAR(255),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    UNIQUE (tenant_id, username)
);

COMMENT ON TABLE core.user_ IS 'Application users. Named user_ to avoid PostgreSQL reserved word conflict.';
COMMENT ON COLUMN core.user_.email IS 'PII — encrypted at rest';
COMMENT ON COLUMN core.user_.phone IS 'PII — encrypted at rest';
COMMENT ON COLUMN core.user_.attributes IS 'ABAC attributes: {"region": "Marmara", "lob": "retail", "clearance_level": 3}';
COMMENT ON COLUMN core.user_.deleted_at IS 'Soft delete timestamp for KVKK/GDPR compliance';

-- SSO/LDAP Configuration per tenant
CREATE TABLE IF NOT EXISTS core.sso_config (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    provider_type   VARCHAR(50) NOT NULL
                    CHECK (provider_type IN ('saml', 'oidc', 'ldap')),
    config          JSONB NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    group_mapping   JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.sso_config IS 'SSO/LDAP identity provider configuration per tenant';
COMMENT ON COLUMN core.sso_config.config IS 'IdP metadata, endpoints, certificate references (encrypted values)';
COMMENT ON COLUMN core.sso_config.group_mapping IS 'Maps IdP groups to internal roles/attributes';

-- ABAC Policy Table
CREATE TABLE IF NOT EXISTS core.abac_policy (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    policy_name             VARCHAR(255) NOT NULL,
    description             TEXT,
    resource_type           VARCHAR(100) NOT NULL,
    conditions              JSONB NOT NULL,
    allowed_actions         VARCHAR(50)[] NOT NULL,
    effect                  VARCHAR(10) NOT NULL DEFAULT 'permit'
                            CHECK (effect IN ('permit', 'deny')),
    priority                INTEGER NOT NULL DEFAULT 0,
    is_active               BOOLEAN NOT NULL DEFAULT true,
    environment_constraints JSONB NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.abac_policy IS 'Attribute-Based Access Control policies evaluated at runtime';
COMMENT ON COLUMN core.abac_policy.conditions IS 'ABAC conditions: {"subject.region": {"$eq": "resource.region"}}';
COMMENT ON COLUMN core.abac_policy.environment_constraints IS 'Optional: time-of-day, IP range, device type constraints';

-- Delegation (act on behalf)
CREATE TABLE IF NOT EXISTS core.delegation (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    delegator_id    UUID NOT NULL REFERENCES core.user_(id),
    delegate_id     UUID NOT NULL REFERENCES core.user_(id),
    scope           JSONB NOT NULL DEFAULT '{}',
    reason          TEXT,
    valid_from      TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until     TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_by      UUID NOT NULL REFERENCES core.user_(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_delegation_different_users CHECK (delegator_id != delegate_id)
);

COMMENT ON TABLE core.delegation IS 'Delegation records allowing one user to act on behalf of another';
COMMENT ON COLUMN core.delegation.scope IS 'What is delegated: resource types, customer sets, org units';

-- Impersonation audit log
CREATE TABLE IF NOT EXISTS core.impersonation_log (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    impersonator_id     UUID NOT NULL REFERENCES core.user_(id),
    impersonated_id     UUID NOT NULL REFERENCES core.user_(id),
    delegation_id       UUID NOT NULL REFERENCES core.delegation(id),
    session_id          UUID NOT NULL,
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at            TIMESTAMPTZ,
    actions_performed   INTEGER NOT NULL DEFAULT 0
);

COMMENT ON TABLE core.impersonation_log IS 'Audit trail for all impersonation/delegation sessions';

-- ============================================================================
-- 2.3 ORGANIZATION HIERARCHY (Closure Table)
-- ============================================================================
-- CONCEPT
--   The organisation is a tree of units (company → LOB → region → area →
--   branch → team).  Two common storage strategies exist:
--
--     Adjacency list  — each row stores only parent_id.  Simple inserts, but
--                       ancestor queries require recursive CTEs (slow on deep
--                       trees).
--     Closure table   — a separate table stores *every ancestor–descendant pair*
--                       at every depth.  Ancestor queries become a single O(1)
--                       index lookup at the cost of extra rows on insert/move.
--
--   We use the closure table pattern because the policy engine and AI agent
--   frequently ask "give me all descendants of branch X" or "is unit Y under
--   region Z?".  These queries must be fast across millions of rows.
--
-- TABLES IN THIS SECTION
--   core.org_unit               — the nodes.  Each row is one org unit.  Temporal
--                                 (effective_from / effective_until) so historical
--                                 org changes are preserved without overwriting.
--   core.org_unit_closure       — the edges.  Every reachable path is stored:
--                                 (A→A depth 0), (A→B depth 1), (A→C depth 2)…
--                                 Populated and maintained by application logic
--                                 whenever org_unit rows are inserted or reparented.
--   core.employee               — a sales employee profile linked to a core.user_
--                                 identity.  Separating employee from user lets HR
--                                 data evolve independently of IAM data.
--   core.employee_org_assignment — temporal many-to-many: an employee can belong
--                                 to multiple org units (is_primary = true for the
--                                 main unit).  Historical rows are kept when an
--                                 employee transfers, enabling point-in-time reports.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.org_unit (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    parent_id       UUID REFERENCES core.org_unit(id),
    code            VARCHAR(100) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    unit_type       VARCHAR(50) NOT NULL
                    CHECK (unit_type IN ('company', 'lob', 'region', 'area', 'branch', 'team', 'department')),
    level           INTEGER NOT NULL DEFAULT 0,
    attributes      JSONB NOT NULL DEFAULT '{}',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    effective_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code, effective_from),
    CONSTRAINT chk_org_unit_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

COMMENT ON TABLE core.org_unit IS 'Organizational units forming a flexible hierarchy. Temporal (effective_from/until) for history.';

-- Closure table for efficient ancestor/descendant queries
CREATE TABLE IF NOT EXISTS core.org_unit_closure (
    ancestor_id     UUID NOT NULL REFERENCES core.org_unit(id),
    descendant_id   UUID NOT NULL REFERENCES core.org_unit(id),
    depth           INTEGER NOT NULL DEFAULT 0,
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    PRIMARY KEY (ancestor_id, descendant_id)
);

COMMENT ON TABLE core.org_unit_closure IS 'Closure table for O(1) org hierarchy queries. Depth 0 = self-reference. The org_unit table stores only the nodes (each unit once). The org_unit_closure table stores every reachable path';

-- Employee (linked to IAM user)
CREATE TABLE IF NOT EXISTS core.employee (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    user_id         UUID NOT NULL REFERENCES core.user_(id),
    employee_code   VARCHAR(100) NOT NULL,
    title           VARCHAR(255),
    attributes      JSONB NOT NULL DEFAULT '{}',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, employee_code)
);

COMMENT ON TABLE core.employee IS 'Sales employees linked to IAM users. Separated for HR/core system integration.';

-- Employee ↔ Org Unit assignment (temporal, multi-team)
CREATE TABLE IF NOT EXISTS core.employee_org_assignment (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    employee_id     UUID NOT NULL REFERENCES core.employee(id),
    org_unit_id     UUID NOT NULL REFERENCES core.org_unit(id),
    role_in_unit    VARCHAR(50) NOT NULL DEFAULT 'member'
                    CHECK (role_in_unit IN ('member', 'manager', 'specialist', 'lead', 'director')),
    is_primary      BOOLEAN NOT NULL DEFAULT true,
    effective_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until DATE,
    source          VARCHAR(50) NOT NULL DEFAULT 'manual'
                    CHECK (source IN ('manual', 'core_system', 'ldap_sync')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_emp_org_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

COMMENT ON TABLE core.employee_org_assignment IS 'Employee-to-org assignments. Supports multi-team (is_primary) and temporal history.';

-- ============================================================================
-- 2.9 REPORTING PERIOD DIMENSION
-- ============================================================================
-- CONCEPT
--   A shared, insert-only time dimension that eliminates ad-hoc date maths
--   across all fact tables (customer_product_metric, customer_transaction, perf
--   targets, etc.).  Instead of every table storing raw dates and every query
--   doing EXTRACT(YEAR ...) / DATETRUNC() arithmetic, fact rows carry a single
--   reporting_period_id FK that resolves to a pre-computed, authoritative row.
--
-- WHY DENORMALIZE period_label AND period_type INTO FACT TABLES?
--   Joining back to this dimension on every analytical query adds I/O and
--   complicates ORM-generated queries.  By copying the two most-queried columns
--   (period_label, period_type) into fact rows analysts can GROUP BY period_label
--   directly.  The FK is still there for data-integrity and for fetching less
--   common columns (fiscal_quarter, is_closed, etc.).
--
-- ROW LIFECYCLE
--   Rows are insert-only — never updated after creation.  Only the is_current
--   flag is toggled by the ETL job when a new period opens, and is_closed is set
--   once figures for that period are finalised and locked.
--
-- SUPPORTED GRAINS
--   daily · weekly · monthly · quarterly · annual · ytd · fiscal_year
--   Each grain produces its own rows; a single calendar month generates at
--   minimum three rows: one 'monthly', one 'ytd', and one 'quarterly' (if it is
--   the last month of the quarter).
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.reporting_period (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id        UUID NOT NULL REFERENCES core.tenant(id),

    -- Human-readable label — also denormalized into fact tables
    period_label     VARCHAR(50)  NOT NULL,           -- e.g. '2025-03', '2025-Q1', '2025-YTD', '2025'
    period_name      VARCHAR(255) NOT NULL,           -- e.g. 'March 2025', 'Q1 2025', 'YTD January–March 2025'

    -- Grain / type — also denormalized into fact tables
    period_type      VARCHAR(20)  NOT NULL
                     CHECK (period_type IN (
                         'daily', 'weekly', 'monthly',
                         'quarterly', 'annual',
                         'ytd', 'fiscal_year'
                     )),

    -- Exact date boundaries
    period_start     DATE         NOT NULL,
    period_end       DATE         NOT NULL,

    -- Calendar dimensions (for group-by without date-math)
    calendar_year    SMALLINT     NOT NULL,
    calendar_month   SMALLINT     CHECK (calendar_month BETWEEN 1 AND 12),   -- NULL for annual/YTD
    calendar_quarter SMALLINT     CHECK (calendar_quarter BETWEEN 1 AND 4),  -- NULL for monthly/daily

    -- Fiscal dimensions (may differ from calendar; tenant-specific)
    fiscal_year      SMALLINT     NOT NULL,
    fiscal_quarter   SMALLINT     CHECK (fiscal_quarter BETWEEN 1 AND 4),

    -- Convenience flags
    is_current       BOOLEAN      NOT NULL DEFAULT false,  -- Only one row per type should be current
    is_closed        BOOLEAN      NOT NULL DEFAULT false,  -- Period has ended and data is finalised

    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_rp_dates      CHECK (period_end >= period_start),
    CONSTRAINT chk_rp_label_type UNIQUE (tenant_id, period_type, period_label)
);

COMMENT ON TABLE  core.reporting_period IS 'Shared time dimension. Fact tables (customer_product_metric, customer_transaction, etc.) hold both a reporting_period_id FK and denormalized period_label + period_type for analyst convenience.';
COMMENT ON COLUMN core.reporting_period.period_label  IS 'Short machine-friendly label, also denormalized into fact rows. e.g. ''2025-03'', ''2025-Q1'', ''2025-YTD'', ''2025''';
COMMENT ON COLUMN core.reporting_period.period_name   IS 'Full human-readable name. e.g. ''March 2025'', ''Q1 2025'', ''YTD January–March 2025''';
COMMENT ON COLUMN core.reporting_period.is_current    IS 'True for the single in-flight period of each type. Maintained by the ETL job.';
COMMENT ON COLUMN core.reporting_period.is_closed     IS 'True once the period has ended and figures are finalised. Closed rows should never be updated.';
