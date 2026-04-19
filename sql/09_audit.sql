-- ============================================================================
-- Account Planning — audit Schema
-- ============================================================================
-- Field-level audit logging, AI reasoning chain traceability, and
-- KVKK/GDPR-compliant data access logging. Partitioned with 1-year
-- hot retention and tiered archival.
-- ============================================================================

-- ============================================================================
-- 9.1 AUDIT LOG (Field-Level Diffs)
-- ============================================================================
-- CONCEPT
--   This is the *write-side* compliance log: every mutation (create, update,
--   delete) performed by any user or automated agent on any significant resource
--   is recorded here with the exact before/after diff.  It answers: "Who changed
--   what, when, and to what value?"
--
-- FIELD DIFFS
--   field_diffs stores an array of change objects:
--     [{"field": "status", "old": "pending", "new": "approved"},
--      {"field": "priority", "old": "medium", "new": "high"}]
--   The application layer is responsible for computing the diff before writing
--   here — the DB does not derive it automatically.  This keeps query/write
--   paths simple and lets the application scrub PII from diffs if needed.
--
-- IMPERSONATION AWARENESS
--   When User A is impersonating User B, user_id is set to A (the real actor)
--   and impersonated_user_id is set to B (the identity being acted as).  This
--   ensures accountability even through delegation chains.
--
-- PARTITIONING STRATEGY
--   The table is RANGE-partitioned by occurred_at into monthly child tables
--   (audit_log_y2026m01 … audit_log_y2026m12).  Benefits:
--     • Query pruning  — WHERE occurred_at BETWEEN … touches only relevant months.
--     • Cheap archival — DROP the partition once past the 12-month hot window.
--     • pg_partman    — use this extension to auto-create future partitions.
--   WARNING: new monthly partitions must be created *in advance* (e.g. via a
--   migration or cron job) or INSERTs will fail for the new month.
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.audit_log (
    id                      UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL,
    user_id                 UUID,
    impersonated_user_id    UUID,
    action                  VARCHAR(50) NOT NULL
                            CHECK (action IN ('create', 'update', 'delete', 'approve', 'reject', 'login', 'logout', 'export', 'import', 'escalate', 'delegate')),
    resource_type           VARCHAR(100) NOT NULL,
    resource_id             UUID,
    field_diffs             JSONB,
    metadata                JSONB NOT NULL DEFAULT '{}',
    occurred_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE audit.audit_log IS 'Field-level audit log. Partitioned monthly. 12-month hot retention, then cold archive.';
COMMENT ON COLUMN audit.audit_log.field_diffs IS '[{"field": "status", "old": "pending", "new": "completed"}]';
COMMENT ON COLUMN audit.audit_log.metadata IS 'IP address, user agent, session ID, request ID';
COMMENT ON COLUMN audit.audit_log.impersonated_user_id IS 'Set when action performed via delegation/impersonation';

-- Monthly partitions for audit_log
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m01 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m02 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m03 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m04 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m05 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m06 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m07 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m08 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m09 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m10 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m11 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit.audit_log_y2026m12 PARTITION OF audit.audit_log
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================================
-- 9.2 AI REASONING CHAIN LOG
-- ============================================================================
-- CONCEPT
--   Regulatory and business requirements demand that AI-driven decisions be
--   *explainable and reproducible*.  This table stores the complete reasoning
--   chain for every AI agent invocation: the rendered prompt, the raw model
--   response, the parsed structured output, and the final decision.
--
-- WHY LOG SO MUCH?
--   • KVKK / GDPR Art. 22 (automated decision-making): if an agent recommends
--     an action that affects a customer, the customer can request an explanation.
--     This table provides the answer without rerunning the model.
--   • Debugging: when a rep disputes an AI recommendation, engineers can replay
--     the exact context that was fed to the model.
--   • Cost attribution: tokens_used + model_name allow exact per-decision cost
--     accounting against the AI budget.
--
-- PII CAUTION
--   input_context may reference customer data.  Store customer_id references —
--   NOT raw PII values (name, tax ID, etc.) — in this column.  Resolve PII at
--   query time from the customer schema, so this log survives data anonymization.
--
-- PARTITIONING
--   Same monthly range-partition strategy as audit_log, but with a shorter
--   6-month hot retention window (AI logs are large and age out faster).
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log (
    id                      UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL,
    session_id              UUID,
    agent_type              VARCHAR(50) NOT NULL,
    trigger_type            VARCHAR(50) NOT NULL
                            CHECK (trigger_type IN ('user_request', 'scheduled', 'event', 'escalation', 'system', 'recurring')),
    trigger_entity_type     VARCHAR(100),
    trigger_entity_id       UUID,
    prompt_template_id      UUID,
    input_context           JSONB,
    prompt_rendered         TEXT,
    model_response          TEXT,
    parsed_output           JSONB,
    decision                VARCHAR(100),
    confidence              DECIMAL(5,4),
    tokens_used             JSONB,
    model_name              VARCHAR(100) NOT NULL,
    latency_ms              INTEGER,
    status                  VARCHAR(30) NOT NULL
                            CHECK (status IN ('success', 'error', 'timeout', 'filtered', 'rate_limited')),
    error_message           TEXT,
    occurred_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE audit.ai_reasoning_log IS 'Full AI reasoning chain: prompt, context, response, decision. KVKK/GDPR traceable.';
COMMENT ON COLUMN audit.ai_reasoning_log.tokens_used IS '{"input": 1500, "output": 800, "total": 2300}';
COMMENT ON COLUMN audit.ai_reasoning_log.input_context IS 'Data fed to the model (may contain PII references — log customer_id, not raw PII)';

-- Monthly partitions for ai_reasoning_log (6-month hot retention)
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m01 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m02 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m03 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m04 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m05 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m06 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m07 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m08 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m09 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m10 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m11 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit.ai_reasoning_log_y2026m12 PARTITION OF audit.ai_reasoning_log
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================================
-- 9.3 DATA ACCESS LOG (KVKK/GDPR)
-- ============================================================================
-- CONCEPT
--   This is the *read-side* compliance log.  While audit_log tracks writes,
--   data_access_log tracks *who looked at what, and why*.  This is required
--   under KVKK (Turkish Personal Data Protection Law) and GDPR whenever PII
--   is accessed — especially for export, bulk read, or API access events.
--
-- KEY FIELDS
--   pii_accessed  — boolean flag: did this access touch PII fields?
--                   Lets compliance teams filter quickly to the highest-risk
--                   events without scanning access_type.
--   purpose       — the stated reason for access, required by KVKK Art. 4:
--                   e.g. 'customer_support', 'regulatory_reporting', 'audit'.
--                   Absence of a valid purpose is grounds for KVKK violation.
--   access_type   — granularity of the access event:
--                   read (single record) · export (file download) ·
--                   bulk_read (list/search) · print · api_access
--
-- PARTITIONING
--   Same monthly range-partition strategy as audit_log.  Retention is typically
--   3–5 years for KVKK compliance.  Old partitions should be archived (not
--   dropped) to cold storage.
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit.data_access_log (
    id              UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL,
    user_id         UUID NOT NULL,
    resource_type   VARCHAR(100) NOT NULL,
    resource_id     UUID,
    access_type     VARCHAR(20) NOT NULL
                    CHECK (access_type IN ('read', 'export', 'print', 'api_access', 'bulk_read')),
    pii_accessed    BOOLEAN NOT NULL DEFAULT false,
    purpose         VARCHAR(100),
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE audit.data_access_log IS 'KVKK/GDPR: Tracks all data access events, especially PII access with purpose.';

-- Monthly partitions for data_access_log
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m01 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m02 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m03 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m04 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m05 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m06 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m07 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m08 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m09 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m10 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m11 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit.data_access_log_y2026m12 PARTITION OF audit.data_access_log
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
