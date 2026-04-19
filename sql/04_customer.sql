-- ============================================================================
-- Account Planning — customer Schema
-- ============================================================================
-- KVKK/GDPR-compliant customer management: demographics, segments,
-- inter-customer relationships, product ownership, assignments,
-- consent tracking, data retention, and Customer 360 cache.
-- ============================================================================

-- ============================================================================
-- 4.1 CUSTOMERS
-- ============================================================================
-- CONCEPT
--   The core customer entity.  Every other table in this schema (and most in
--   other schemas) eventually traces back to a row here via customer_id.
--
-- CUSTOMER TYPES
--   individual  — a private person (retail banking, consumer insurance, etc.)
--   corporate   — a legal entity (company, public institution)
--   sme         — small/medium enterprise; often treated differently from full
--                 corporate for product eligibility and credit rules
--
-- PII HANDLING
--   Fields marked "PII" must be encrypted at-rest using the database-level or
--   application-level encryption configured in core.tenant.kvkk_gdpr_config.
--   Do NOT change these columns to plaintext without a security review.
--
-- SOFT DELETE & ANONYMIZATION
--   deleted_at — set when the customer exercises the KVKK Art. 11 right to
--                erasure.  Hard deletes are avoided to preserve FK integrity.
--   anonymized_at — timestamp when PII columns were overwritten with
--                  pseudonymous tokens.  After this date, audit trails remain
--                  but personal identity is irrecoverable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    external_id         VARCHAR(255) NOT NULL,
    customer_type       VARCHAR(30) NOT NULL
                        CHECK (customer_type IN ('individual', 'corporate', 'sme')),
    name                VARCHAR(255) NOT NULL,        -- PII
    tax_id              VARCHAR(50),                  -- PII
    identity_number     VARCHAR(50),                  -- PII (National ID / Passport)
    contact_email       VARCHAR(255),                 -- PII
    contact_phone       VARCHAR(50),                  -- PII
    address             JSONB DEFAULT '{}',           -- PII (structured address)
    demographics        JSONB DEFAULT '{}',           -- PII (age, gender, etc.)
    risk_profile        JSONB DEFAULT '{}',
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    anonymized_at       TIMESTAMPTZ,
    UNIQUE (tenant_id, external_id)
);

COMMENT ON TABLE customer.customer IS 'Core customer entity. PII fields marked for encryption-at-rest per KVKK/GDPR.';
COMMENT ON COLUMN customer.customer.name IS 'PII — encrypted at rest';
COMMENT ON COLUMN customer.customer.tax_id IS 'PII — encrypted at rest';
COMMENT ON COLUMN customer.customer.identity_number IS 'PII — encrypted at rest (National ID / Passport)';
COMMENT ON COLUMN customer.customer.contact_email IS 'PII — encrypted at rest';
COMMENT ON COLUMN customer.customer.contact_phone IS 'PII — encrypted at rest';
COMMENT ON COLUMN customer.customer.address IS 'PII — encrypted at rest (structured address JSONB)';
COMMENT ON COLUMN customer.customer.demographics IS 'PII — encrypted at rest (age, gender, etc.)';
COMMENT ON COLUMN customer.customer.deleted_at IS 'Soft delete for KVKK/GDPR right to erasure';
COMMENT ON COLUMN customer.customer.anonymized_at IS 'Timestamp when PII was anonymized/pseudonymized';

-- ============================================================================
-- 4.2 CUSTOMER SEGMENTS
-- ============================================================================
-- CONCEPT
--   A customer may belong to multiple segments simultaneously, each describing
--   a different axis of classification.  Segments are temporal: they have an
--   effective_from / effective_until window, so the history of how a customer
--   moved between tiers or risk bands is preserved for analytics.
--
-- SEGMENT TYPES
--   tier         — commercial tier (e.g. Gold, Platinum, SME A)
--   segment      — marketing segment (e.g. Mass Affluent, Premier)
--   sub_segment  — finer subdivision within a segment
--   behavioral   — usage-based grouping (e.g. Digital-first, Branch-heavy)
--   value        — revenue/profitability group (e.g. Top-200 by AUM)
--   risk         — credit/operational risk band
--   lifecycle    — customer lifecycle stage (e.g. Onboarding, Mature, At-Risk)
--
-- SOURCES
--   core_system — pushed from the core banking / CRM system (authoritative)
--   analytics   — derived by the ML pipeline
--   manual      — assigned by a manager or specialist
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_segment (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    customer_id     UUID NOT NULL REFERENCES customer.customer(id),
    segment_type    VARCHAR(50) NOT NULL
                    CHECK (segment_type IN ('tier', 'segment', 'sub_segment', 'behavioral', 'value', 'risk', 'lifecycle')),
    segment_code    VARCHAR(100) NOT NULL,
    segment_name    VARCHAR(255) NOT NULL,
    effective_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until DATE,
    source          VARCHAR(50) NOT NULL DEFAULT 'core_system'
                    CHECK (source IN ('core_system', 'analytics', 'manual')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_segment_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

COMMENT ON TABLE customer.customer_segment IS 'Customer segmentation: tiers, behavioral segments, value segments. Source system provides primary data.';

-- ============================================================================
-- 4.3 CUSTOMER RELATIONSHIPS
-- ============================================================================
-- CONCEPT
--   Customers do not always act independently.  A corporate customer may have
--   several subsidiaries; a retail customer may have a spouse who is also a
--   client; an SME loan may have an individual guarantor.  This table captures
--   those inter-customer links as directed edges: source → target.
--
-- DIRECTIONALITY
--   The edge is directional.  "Acme Corp → Acme Leasing" with type 'parent_company'
--   means Acme Corp is the parent of Acme Leasing.  If you also need the inverse
--   relationship navigable, insert a second row (Acme Leasing → Acme Corp,
--   type='subsidiary').
--
-- WHY NO SELF-LOOPS?
--   The CHECK constraint (source_customer_id != target_customer_id) prevents a
--   customer from being related to itself, which would corrupt graph traversals.
--
-- TYPICAL USE CASES
--   • Group-level exposure calculation (sum AUM across all subsidiaries)
--   • Family bundling for retail products
--   • Guarantor chains for credit decisioning
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_relationship (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    source_customer_id      UUID NOT NULL REFERENCES customer.customer(id),
    target_customer_id      UUID NOT NULL REFERENCES customer.customer(id),
    relationship_type       VARCHAR(50) NOT NULL
                            CHECK (relationship_type IN ('subsidiary', 'parent_company', 'group_member', 'spouse', 'family', 'guarantor', 'business_partner')),
    metadata                JSONB NOT NULL DEFAULT '{}',
    is_active               BOOLEAN NOT NULL DEFAULT true,
    effective_from          DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until         DATE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, source_customer_id, target_customer_id, relationship_type),
    CONSTRAINT chk_cust_rel_diff CHECK (source_customer_id != target_customer_id),
    CONSTRAINT chk_cust_rel_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

COMMENT ON TABLE customer.customer_relationship IS 'Inter-customer relationships: subsidiary/parent, family, guarantor, etc.';

-- ============================================================================
-- 4.4 CUSTOMER PRODUCTS
-- ============================================================================
-- CONCEPT
--   Records which products a customer currently holds or has held.  This is
--   *not* a product catalog (that lives in the product schema) — it is the
--   ownership/subscription fact.
--
-- PRODUCT VERSION PINNING
--   product_version_id captures the exact version of the product at the time
--   of sale.  If the product's terms change later, the customer's row still
--   points to the version they signed up under.  This matters for eligibility
--   checks, rate calculations, and regulatory disclosures.
--
-- STATUS LIFECYCLE
--   pending → active → dormant → suspended → closed
--   'dormant' means the product exists but has seen no activity recently
--   (e.g. a savings account with zero transactions for 12 months).
--
-- ATTRIBUTES
--   Product-specific numerical and categorical fields that differ across
--   product types (loan amount, interest rate, credit limit, maturity date, etc.)
--   are stored in the flexible attributes JSONB column rather than adding
--   columns per product type.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_product (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    customer_id         UUID NOT NULL REFERENCES customer.customer(id),
    product_id          UUID NOT NULL REFERENCES product.product(id),
    product_version_id  UUID REFERENCES product.product_version(id),
    status              VARCHAR(30) NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'closed', 'dormant', 'pending', 'suspended')),
    start_date          DATE,
    end_date            DATE,
    attributes          JSONB NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE customer.customer_product IS 'Products owned/used by customers. Links to specific product version at time of sale.';
COMMENT ON COLUMN customer.customer_product.attributes IS 'Product-specific attributes: amount, rate, limit, duration, etc.';

-- ============================================================================
-- 4.5 CUSTOMER PRODUCT METRICS
-- ============================================================================
-- CONCEPT
--   Aggregated, pre-computed metric values for a customer–product pair over a
--   specific reporting period.  Examples: average monthly balance on a deposit,
--   total loan repayments in Q1, insurance premium collected YTD.
--
--   This is NOT a raw transaction ledger.  Raw transactions come from core
--   banking ETL.  This table holds *already-aggregated* figures pushed by the
--   ETL pipeline — one row per (customer_product, metric_code, period).
--
-- REPORTING PERIOD PATTERN
--   reporting_period_id → core.reporting_period (section 2.9).
--   period_label and period_type are denormalized copies so analysts can GROUP
--   BY period_label without joining back to the dimension on every query.
--   See section 2.9 for the full explanation of the denormalization rationale.
--
-- UNIQUENESS
--   The natural key UNIQUE (tenant, customer_product, metric_code, period) ensures
--   idempotent ETL: re-running the pipeline for the same period safely upserts
--   without creating duplicate metric rows.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_product_metric (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id            UUID NOT NULL REFERENCES core.tenant(id),
    customer_product_id  UUID NOT NULL REFERENCES customer.customer_product(id),
    metric_code          VARCHAR(100) NOT NULL,

    -- Reporting period (FK + denormalized for analyst convenience)
    reporting_period_id  UUID NOT NULL REFERENCES core.reporting_period(id),
    period_label         VARCHAR(50)  NOT NULL,   -- e.g. '2025-03', '2025-Q1'  (copied from dim)
    period_type          VARCHAR(20)  NOT NULL,   -- e.g. 'monthly', 'quarterly' (copied from dim)

    -- Legacy date boundaries kept for backward compatibility and direct range queries
    period_start         DATE NOT NULL,
    period_end           DATE NOT NULL,

    value                DECIMAL(20,4) NOT NULL,
    unit                 VARCHAR(30)   NOT NULL DEFAULT 'TRY',
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT chk_cpm_dates   CHECK (period_end >= period_start),
    -- One metric value per customer-product × metric × period
    CONSTRAINT uq_cpm_natural  UNIQUE (tenant_id, customer_product_id, metric_code, reporting_period_id)
);

COMMENT ON TABLE  customer.customer_product_metric IS 'Aggregated product usage metrics per customer: monthly volume, avg balance, etc. One row per customer_product × metric_code × reporting_period.';
COMMENT ON COLUMN customer.customer_product_metric.reporting_period_id IS 'FK to core.reporting_period dimension.';
COMMENT ON COLUMN customer.customer_product_metric.period_label IS 'Denormalized from core.reporting_period for analyst convenience — no join needed for display.';
COMMENT ON COLUMN customer.customer_product_metric.period_type  IS 'Denormalized grain indicator: monthly, quarterly, annual, ytd, etc.';

-- ============================================================================
-- 4.6 CUSTOMER TRANSACTIONS (Aggregated)
-- ============================================================================
-- CONCEPT
--   Aggregated transaction summaries imported from the core banking / ERP
--   systems.  This is NOT a ledger of individual transactions — individual
--   row-level transactions remain in the source system.  The Account Planning
--   platform works with period summaries (e.g. total credit card spend in
--   March 2026) to feed the AI agent and reporting layer.
--
-- PRODUCT-LEVEL VS. CHANNEL-LEVEL
--   product_id is nullable.  When it is set, the row represents a
--   product-specific aggregation (e.g. 14 transfers via the mobile app,
--   associated with a specific current account product).  When NULL, it is a
--   channel-level aggregation (e.g. total mobile banking usage across all
--   products) — not tied to a specific product.
--   Two partial UNIQUE indexes handle this difference cleanly (a standard UNIQUE
--   constraint allows multiple NULL duplicates in PostgreSQL).
--
-- REPORTING PERIOD PATTERN
--   Same as section 4.5 — FK + denormalized period_label / period_type.
--   transaction_date is kept as a backward-compatibility anchor and for direct
--   date-range queries that do not bother resolving the period FK.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_transaction (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id            UUID NOT NULL REFERENCES core.tenant(id),
    customer_id          UUID NOT NULL REFERENCES customer.customer(id),
    transaction_type     VARCHAR(50)  NOT NULL,
    amount               DECIMAL(20,4),
    currency             VARCHAR(3)   NOT NULL DEFAULT 'TRY',
    channel              VARCHAR(50),
    product_id           UUID REFERENCES product.product(id),   -- nullable: channel-level aggregations
    metadata             JSONB        NOT NULL DEFAULT '{}',

    -- Reporting period (FK + denormalized for analyst convenience)
    reporting_period_id  UUID         NOT NULL REFERENCES core.reporting_period(id),
    period_label         VARCHAR(50)  NOT NULL,   -- e.g. '2025-03', '2025-Q1'  (copied from dim)
    period_type          VARCHAR(20)  NOT NULL    -- e.g. 'monthly', 'quarterly' (copied from dim)
                         CHECK (period_type IN (
                             'daily', 'weekly', 'monthly',
                             'quarterly', 'annual',
                             'ytd', 'fiscal_year'
                         )),

    -- Legacy date kept for direct range queries
    transaction_date     DATE         NOT NULL,   -- first day of the aggregation period

    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Uniqueness: one aggregated row per customer × tx_type × period (× product if product-level).
-- product_id is nullable so a standard UNIQUE constraint would allow duplicate NULLs;
-- two partial indexes cover both cases cleanly.
CREATE UNIQUE INDEX IF NOT EXISTS uq_ctxn_with_product
    ON customer.customer_transaction (tenant_id, customer_id, transaction_type, product_id, reporting_period_id)
    WHERE product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_ctxn_no_product
    ON customer.customer_transaction (tenant_id, customer_id, transaction_type, reporting_period_id)
    WHERE product_id IS NULL;

COMMENT ON TABLE  customer.customer_transaction IS 'Aggregated transaction summaries from core systems (not raw ledger data). One row per customer × transaction_type × (product) × reporting_period.';
COMMENT ON COLUMN customer.customer_transaction.reporting_period_id IS 'FK to core.reporting_period dimension.';
COMMENT ON COLUMN customer.customer_transaction.period_label IS 'Denormalized from core.reporting_period for analyst convenience — no join needed for display.';
COMMENT ON COLUMN customer.customer_transaction.period_type  IS 'Denormalized grain indicator: monthly, quarterly, annual, ytd, etc. Extended from original daily/weekly/monthly.';
COMMENT ON COLUMN customer.customer_transaction.transaction_date IS 'First calendar day of the aggregation period. Use period_start from core.reporting_period for precise boundary.';
COMMENT ON COLUMN customer.customer_transaction.product_id IS 'NULL for channel-level aggregations not tied to a specific product.';

-- ============================================================================
-- 4.7 CUSTOMER ↔ EMPLOYEE ASSIGNMENTS
-- ============================================================================
-- CONCEPT
--   Tracks which sales employee is responsible for which customer, and in what
--   capacity.  Assignments are temporal (effective dates) so the history of
--   ownership changes is preserved — critical for performance attribution and
--   regulatory audits ("who was the RM for this customer at the time of the
--   complaint?").
--
-- ASSIGNMENT TYPES
--   primary    — the main relationship manager or account executive
--   secondary  — a support rep or coverage banker
--   specialist  — a product specialist brought in for a specific deal
--   temporary  — covers while the primary rep is absent
--
-- SOURCES
--   direct          — assigned manually in the platform
--   branch_based    — derived from the customer's home branch matching the rep's branch
--   lob_based       — derived from the product LOB
--   auto_assigned   — assigned by an automated load-balancing rule
--   core_system     — pushed from the core CRM or HR system
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_assignment (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    customer_id     UUID NOT NULL REFERENCES customer.customer(id),
    employee_id     UUID NOT NULL REFERENCES core.employee(id),
    assignment_type VARCHAR(30) NOT NULL DEFAULT 'primary'
                    CHECK (assignment_type IN ('primary', 'secondary', 'specialist', 'temporary')),
    effective_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until DATE,
    source          VARCHAR(50) NOT NULL DEFAULT 'direct'
                    CHECK (source IN ('direct', 'branch_based', 'lob_based', 'auto_assigned', 'core_system')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_cust_assign_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

COMMENT ON TABLE customer.customer_assignment IS 'Customer-to-employee assignments. Temporal for historical tracking.';

-- ============================================================================
-- 4.8 KVKK/GDPR: CONSENT TRACKING
-- ============================================================================
-- CONCEPT
--   KVKK (Turkey) and GDPR (EU) require that any processing of personal data
--   be backed by a documented legal basis and, where applicable, an explicit
--   consent record.  This table is that record.
--
--   Before performing data processing, marketing campaigns, profiling, or
--   cross-border data transfers, the application must verify that a valid
--   (status='granted', not expired) consent row exists for the relevant
--   consent_type.  If it does not, the operation must be blocked.
--
-- CONSENT TYPES
--   data_processing      — general processing under the contract or legal obligation
--   marketing            — sending promotional communications
--   profiling            — using personal data to build customer profiles / scores
--   cross_sell           — using data to offer related products
--   third_party_sharing  — passing data to partners or affiliates
--   automated_decision   — AI/ML-based decisions with legal/significant effect
--   cross_border_transfer — transferring data outside Turkey or the EEA
--
-- LEGAL BASIS
--   Examples: 'KVKK_Art5_b_contract', 'GDPR_Art6_1_a_consent',
--   'KVKK_Art5_c_legal_obligation'.  Must correspond to an applicable legal
--   basis code documented in the tenant's DPA.
--
-- EVIDENCE REF
--   A reference to the stored consent artefact (e.g. a signed form stored in
--   the document schema, or a consent event ID from the CRM).
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.consent (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    customer_id     UUID NOT NULL REFERENCES customer.customer(id),
    consent_type    VARCHAR(100) NOT NULL
                    CHECK (consent_type IN ('data_processing', 'marketing', 'profiling', 'cross_sell', 'third_party_sharing', 'automated_decision', 'cross_border_transfer')),
    status          VARCHAR(20) NOT NULL DEFAULT 'granted'
                    CHECK (status IN ('granted', 'revoked', 'expired')),
    granted_at      TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    legal_basis     VARCHAR(100) NOT NULL,
    purpose         TEXT NOT NULL,
    channel         VARCHAR(50),
    evidence_ref    VARCHAR(255),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE customer.consent IS 'KVKK/GDPR consent records. Tracks data processing permissions with legal basis.';
COMMENT ON COLUMN customer.consent.legal_basis IS 'KVKK Art. 5/GDPR Art. 6 legal basis code';
COMMENT ON COLUMN customer.consent.evidence_ref IS 'Reference to stored consent evidence document';

-- ============================================================================
-- 4.9 DATA RETENTION POLICIES
-- ============================================================================
-- CONCEPT
--   Defines how long each category of customer data should be kept before it
--   is actioned (anonymized, deleted, or archived).  KVKK Art. 7 requires that
--   personal data be retained "only as long as required by the purpose or by
--   law" — this table is the configuration that drives those automated lifecycle
--   jobs.
--
-- DATA CATEGORIES
--   Free-form strings that map to recognisable data domains, e.g.:
--     'pii_contact_data'   — names, emails, phone numbers
--     'transaction_history' — aggregated transaction records
--     'consent_records'    — must be kept for 3 years post-revocation (KVKK)
--     'audit_logs'         — retained 5 years for regulatory inspection
--
-- ACTIONS ON EXPIRY
--   anonymize — replace PII with tokens; row stays for analytics continuity
--   delete    — hard delete (use sparingly; breaks FK chains)
--   archive   — move to cold storage; row becomes inaccessible to the app
--
-- AUTOMATED ENFORCEMENT
--   A nightly job scans customer rows for data older than retention_period_days,
--   matches the data_category, and triggers the configured action.  The result
--   is logged in audit.audit_log with action='delete' or action='export'.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.data_retention_policy (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    data_category           VARCHAR(100) NOT NULL,
    retention_period_days   INTEGER NOT NULL,
    action_on_expiry        VARCHAR(30) NOT NULL DEFAULT 'anonymize'
                            CHECK (action_on_expiry IN ('anonymize', 'delete', 'archive')),
    legal_basis             VARCHAR(100),
    is_active               BOOLEAN NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, data_category)
);

COMMENT ON TABLE customer.data_retention_policy IS 'Per-tenant data retention policies per data category. Automated jobs enforce these.';

-- ============================================================================
-- 4.10 CUSTOMER 360 CACHE
-- ============================================================================
-- CONCEPT
--   A denormalized, pre-aggregated snapshot of everything relevant about a
--   customer, stored as a single JSONB-rich row.  Its sole purpose is to give
--   the AI agent (and the Customer 360 UI card) sub-millisecond read performance
--   without running complex multi-schema joins at query time.
--
-- WHY A CACHE?
--   A full Customer 360 view requires joining customer, segment, product,
--   metrics, actions, analytics, and relationship data — potentially dozens of
--   tables.  Running that at page load or at agent inference time would be too
--   slow.  This cache is refreshed asynchronously and served instantly.
--
-- REFRESH SOURCES
--   scheduled      — nightly ETL rebuilds all rows
--   event_triggered — a significant event (new product, status change) triggers
--                    an immediate refresh for that customer
--   manual         — a manager requests an on-demand refresh
--   real_time      — streaming pipeline keeps the cache near-live
--
-- OPTIMISTIC LOCKING
--   The version column supports optimistic locking: readers note the version;
--   a conditional UPDATE increments it only if the version matches, preventing
--   lost updates when two refresh jobs race.
--
-- STALE DATA WARNING
--   Always check last_refreshed_at before trusting the cache for time-sensitive
--   decisions.  The agent layer should fall back to live queries if the cache
--   is more than N minutes stale (configurable per tenant).
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer.customer_360_cache (
    customer_id         UUID PRIMARY KEY REFERENCES customer.customer(id),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    profile_snapshot    JSONB NOT NULL DEFAULT '{}',
    product_summary     JSONB NOT NULL DEFAULT '{}',
    segment_summary     JSONB NOT NULL DEFAULT '{}',
    relationship_summary JSONB NOT NULL DEFAULT '{}',
    performance_summary JSONB NOT NULL DEFAULT '{}',
    analytics_summary   JSONB NOT NULL DEFAULT '{}',
    action_summary      JSONB NOT NULL DEFAULT '{}',
    risk_summary        JSONB NOT NULL DEFAULT '{}',
    last_refreshed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    refresh_source      VARCHAR(50) NOT NULL DEFAULT 'scheduled'
                        CHECK (refresh_source IN ('scheduled', 'event_triggered', 'manual', 'real_time')),
    version             INTEGER NOT NULL DEFAULT 1
);

COMMENT ON TABLE customer.customer_360_cache IS 'Denormalized customer profile for sub-ms AI agent reads. Refreshed via scheduled jobs or events.';
COMMENT ON COLUMN customer.customer_360_cache.version IS 'Optimistic locking version counter';
