-- ============================================================================
-- Account Planning — integration Schema
-- ============================================================================
-- Data source management (ETL/real-time), sync job tracking, webhook
-- configuration for automated actions, and event store for event sourcing.
-- ============================================================================

-- ============================================================================
-- 11.1 DATA SOURCES
-- ============================================================================
-- CONCEPT
--   The Account Planning system is not the system of record for most business
--   data — it consumes data from upstream platforms (core banking, CRM, ERP,
--   billing) via a variety of integration patterns.  integration.data_source
--   is the *registry* of every external feed the system talks to.
--
--   A data source answers three questions:
--     1. WHERE does the data come from?  (connection_config — endpoint, creds)
--     2. HOW does it arrive?             (source_type — batch ETL or real-time)
--     3. HOW is it mapped?               (entity_mapping — source → internal)
--
-- SOURCE TYPES
--   etl_batch        — nightly file transfer from the core banking system.
--   real_time_api    — REST/gRPC push from the CRM as events occur.
--   file_upload      — manual CSV upload by a data analyst.
--   cdc              — Change Data Capture from the billing DB (Debezium).
--   webhook_inbound  — an external partner system pushes events to us.
--
-- EXAMPLE
--   A bank integrates its core-banking system to keep customer balances current:
--     name            = 'CoreBanking - AML Nightly'
--     source_type     = 'etl_batch'
--     sync_frequency  = 'daily'
--     connection_config = {
--       "host": "sftp.bank.internal",
--       "path": "/exports/aml/",
--       "credential_ref": "vault://secrets/corebanking-sftp"
--     }
--     entity_mapping  = {
--       "ACCOUNT_BALANCE": "customer.customer_product_metric",
--       "ACCOUNT_ID":      "customer.account.external_id"
--     }
--
-- NOTES
--   • connection_config and credentials are referenced via a secrets manager
--     (e.g. HashiCorp Vault) — the column stores the *reference*, not the
--     plain-text secret.  The COMMENT marks it ENCRYPTED as a reminder.
--   • is_active = false suspends a source without deleting its history.
--   • last_sync_at is updated by the scheduler on each completed sync job,
--     enabling stale-source alerting (e.g. "no sync in 36 hours").
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.data_source (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    name                VARCHAR(255) NOT NULL,
    source_type         VARCHAR(30) NOT NULL
                        CHECK (source_type IN ('etl_batch', 'real_time_api', 'file_upload', 'cdc', 'webhook_inbound')),
    connection_config   JSONB NOT NULL DEFAULT '{}',
    sync_frequency      VARCHAR(30)
                        CHECK (sync_frequency IS NULL OR sync_frequency IN ('real_time', 'hourly', 'daily', 'weekly', 'monthly', 'on_demand')),
    entity_mapping      JSONB NOT NULL DEFAULT '{}',
    is_active           BOOLEAN NOT NULL DEFAULT true,
    last_sync_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE integration.data_source IS 'External data source configuration: core banking, CRM, billing, etc.';
COMMENT ON COLUMN integration.data_source.connection_config IS 'ENCRYPTED — connection strings, API endpoints, credentials reference';
COMMENT ON COLUMN integration.data_source.entity_mapping IS 'Maps source entities/fields to internal tables/columns';

-- ============================================================================
-- 11.2 SYNC JOBS
-- ============================================================================
-- CONCEPT
--   Each time the system pulls data from a data_source, it records an
--   execution log in integration.sync_job.  This table tells operations and
--   data engineers *exactly* what happened during a sync run — how many
--   records were touched, how many failed, and where to look for errors.
--
-- JOB TYPES
--   full          — wipes target records and re-imports everything.
--                   Used for initial loads or after a major schema change.
--   incremental   — imports only records modified since last_sync_at.
--                   Daily default for most sources.
--   delta         — computes and applies only the diff (insert/update/delete).
--                   Optimized for CDC sources to minimise DB writes.
--   validation    — dry-run: reads source, validates mappings, but writes
--                   nothing.  Used to verify a new data_source before going live.
--
-- EXAMPLE LIFECYCLE
--   1. Scheduler fires nightly 02:00 UTC for data_source 'CoreBanking - AML'.
--      → new row: status = 'pending', job_type = 'incremental'
--   2. Worker picks it up, starts processing.
--      → status = 'running', started_at = now()
--   3. Processes 42,000 customer balance records; 37 fail schema validation.
--      → records_processed = 42000, records_updated = 41963,
--         records_failed = 37, error_log = [{"row": 1042, "error": "..."}]
--   4. Job finishes.
--      → status = 'completed', completed_at = now()
--   5. Alert fires because records_failed > 0, Slack notification sent.
--
-- STATUS FLOW
--   pending → running → completed
--                    ↘ failed   (unrecoverable error)
--                    ↘ partial  (completed but records_failed > threshold)
--                    ↘ cancelled (manually stopped before completion)
--
-- NOTES
--   • records_created, records_updated, records_failed allow granular SLA
--     monitoring (e.g. "fail rate < 0.1 %").
--   • error_log is a JSONB array capped at application layer (e.g. first 500
--     failures) to prevent unbounded row growth.
--   • There is no UPDATE to a completed row — the history is append-only.
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.sync_job (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    data_source_id      UUID NOT NULL REFERENCES integration.data_source(id),
    job_type            VARCHAR(30) NOT NULL
                        CHECK (job_type IN ('full', 'incremental', 'delta', 'validation')),
    status              VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'partial', 'cancelled')),
    records_processed   INTEGER DEFAULT 0,
    records_created     INTEGER DEFAULT 0,
    records_updated     INTEGER DEFAULT 0,
    records_failed      INTEGER DEFAULT 0,
    error_log           JSONB,
    started_at          TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE integration.sync_job IS 'ETL/sync job execution tracking with record-level statistics.';

-- ============================================================================
-- 11.3 WEBHOOKS (Outbound)
-- ============================================================================
-- CONCEPT
--   While sync_job handles inbound data flows, outbound webhooks let the
--   Account Planning system notify *external* systems when significant
--   business events occur inside it.  integration.webhook stores the
--   configuration of each registered endpoint: where to call, what events
--   to send, and how to authenticate.
--
--   Webhooks are the primary mechanism for integrating the AI action engine
--   with downstream tools (Salesforce, HubSpot, Jira, Slack bots) without
--   tight coupling.
--
-- KEY FIELDS
--   event_types     — the list of domain events that trigger this webhook.
--                     Example: {'action.completed', 'action.escalated',
--                               'model.scored', 'target.breached'}
--   retry_policy    — how to handle delivery failures.
--                     Default: up to 3 retries at 1 s / 5 s / 15 s backoff.
--   secret          — HMAC-SHA256 signing key.  The receiving system verifies
--                     the X-Signature header to confirm the payload came from
--                     us and was not tampered with.
--   headers         — any additional auth headers the endpoint requires
--                     (e.g. Bearer token, API key), stored encrypted.
--
-- EXAMPLE
--   A bank wants Salesforce updated whenever a relationship manager completes
--   an action in Account Planning:
--     name        = 'Salesforce — Action Completed'
--     target_url  = 'https://hooks.salesforce.com/services/...'
--     event_types = ARRAY['action.completed', 'action.cancelled']
--     retry_policy = {"max_retries": 5, "backoff_ms": [1000,5000,15000,30000,60000]}
--     secret      = 'vault://secrets/sf-webhook-hmac'
--
-- NOTES
--   • is_active = false silences a webhook without losing its configuration.
--   • Delivery results are stored in integration.webhook_delivery (§11.4).
--   • One webhook can subscribe to many event types; one event type can fan
--     out to many webhooks — the application iterates all active webhooks
--     whose event_types overlap the emitted event.
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.webhook (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    name            VARCHAR(255) NOT NULL,
    target_url      VARCHAR(500) NOT NULL,
    event_types     VARCHAR(100)[] NOT NULL,
    headers         JSONB NOT NULL DEFAULT '{}',
    retry_policy    JSONB NOT NULL DEFAULT '{"max_retries": 3, "backoff_ms": [1000, 5000, 15000]}',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    secret          VARCHAR(255),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE integration.webhook IS 'Outbound webhook configuration for automated action tracking.';
COMMENT ON COLUMN integration.webhook.headers IS 'ENCRYPTED — authentication headers for webhook endpoint';
COMMENT ON COLUMN integration.webhook.secret IS 'ENCRYPTED — HMAC signing secret for payload verification';
COMMENT ON COLUMN integration.webhook.event_types IS 'Array of event types: {action.completed, action.escalated, model.scored}';

-- ============================================================================
-- 11.4 WEBHOOK DELIVERIES
-- ============================================================================
-- CONCEPT
--   Every attempt to deliver a webhook payload is recorded here.  This log
--   serves three purposes:
--     1. Observability — engineering can see exactly what was sent and
--        what the remote endpoint responded at every attempt.
--     2. Retry management — the retry scheduler reads next_retry_at to know
--        when to re-attempt a failed delivery without polling the webhook table.
--     3. Auditability — a customer can request proof that a notification was
--        sent (and what it contained) for compliance purposes.
--
-- EXAMPLE DELIVERY LIFECYCLE (1 failure, 1 retry success)
--   Attempt 1:
--     status         = 'failed'
--     response_status = 503  (Salesforce temporarily unavailable)
--     attempt_count  = 1
--     next_retry_at  = now() + 5 s  (backoff_ms[1] from webhook.retry_policy)
--
--   Attempt 2 (retried after 5 s):
--     status          = 'delivered'
--     response_status = 200
--     attempt_count   = 2
--     delivered_at    = now()
--
-- EXAMPLE DELIVERY LIFECYCLE (all retries exhausted)
--   status = 'failed', attempt_count = 3 (max_retries reached)
--   → alert sent to on-call engineer; manual re-delivery button in Admin UI
--     creates a new row rather than resetting this one.
--
-- KEY FIELDS
--   event_id        — the UUID of the integration.event that triggered this
--                     delivery, enabling full trace from event → webhook → response.
--   request_payload — the exact JSON body that was POSTed to the endpoint,
--                     stored for replay and debugging.
--   response_body   — first N characters of the remote response body
--                     (truncated at application layer to avoid bloat).
--
-- NOTES
--   • Each retry creates a new attempt_count increment on the *same* row
--     rather than a new row, keeping one delivery = one row.
--   • status = 'retrying' indicates the delivery is queued but not yet sent.
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.webhook_delivery (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    webhook_id      UUID NOT NULL REFERENCES integration.webhook(id),
    event_id        UUID,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'delivered', 'failed', 'retrying')),
    request_payload JSONB NOT NULL,
    response_status INTEGER,
    response_body   TEXT,
    attempt_count   INTEGER NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    next_retry_at   TIMESTAMPTZ,
    delivered_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE integration.webhook_delivery IS 'Webhook delivery tracking with retry state.';

-- ============================================================================
-- 11.5 EVENT STORE (Event Sourcing)
-- ============================================================================
-- CONCEPT
--   integration.event is the central nervous system of the Account Planning
--   platform.  Every meaningful state change — a customer score update, an
--   action being completed, a target being breached — is published as an
--   immutable event record here.
--
--   The event store enables four critical capabilities:
--     1. Event-driven integration — other services (webhooks, AI pipelines,
--        notification workers) subscribe to event types without polling tables.
--     2. Audit & replay — the full sequence of events for any entity can be
--        replayed to reconstruct its state at any point in time.
--     3. AI training data — historical event streams are fed to ML models to
--        detect patterns (e.g. "customers with event sequence X churn within
--        90 days").
--     4. Debugging — the causation chain from one event to another can be
--        traced via the metadata.causation_id chain.
--
-- KEY FIELDS
--   event_type      — dot-namespaced domain event identifier.
--                     Convention: <aggregate>.<action>
--                     Examples: 'customer.score_updated',
--                               'action.completed',
--                               'target.breached',
--                               'model.inference_run'
--   aggregate_type  — the entity this event belongs to.
--                     Examples: 'customer', 'action', 'perf_target'
--   aggregate_id    — the UUID of that entity instance.
--                     Together (aggregate_type, aggregate_id) uniquely
--                     identifies the event's owner.
--   sequence_number — monotonically increasing per aggregate, used to
--                     guarantee event ordering during replay.
--                     Example for customer #C-001:
--                       seq=1 customer.created
--                       seq=2 customer.score_updated
--                       seq=3 customer.segment_changed
--   event_data      — the full domain payload at the time of the event.
--                     Example for 'target.breached':
--                       {"target_id": "...", "metric": "AUM",
--                        "threshold": 500000, "actual": 480000,
--                        "breach_pct": -4.0}
--   metadata        — cross-cutting concerns: correlation_id (traces a business
--                     transaction across microservices), causation_id (the event
--                     that caused this one), initiating user, IP address.
--
-- EXAMPLE FLOW
--   1. RM completes action "Annual Review Call" in the UI.
--      → event: action.completed, aggregate_type='action', seq=5
--   2. Notification worker consumes the event → sends in-app notification.
--   3. Webhook worker consumes the event → POSTs to Salesforce.
--   4. AI worker consumes the event → updates customer relationship score.
--      → event: customer.score_updated, aggregate_type='customer', seq=12
--   5. Score crosses a threshold → event: target.breached
--
-- PARTITIONING
--   The table is range-partitioned by occurred_at (monthly).
--   Benefits:
--     • Old partitions can be archived/dropped without touching the hot data.
--     • Queries filtered by date range hit only the relevant partition(s).
--     • Bulk inserts are parallelised across partition workers.
--
-- NOTES
--   • Events are NEVER updated or deleted — they are the source of truth.
--   • sequence_number gaps are acceptable (e.g. after a failed transaction);
--     consumers must tolerate gaps but must respect ordering within a sequence.
--   • Partitions beyond 2026 should be created by a cron job or migration
--     before the month starts to avoid partition-miss errors.
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.event (
    id                  UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL,
    event_type          VARCHAR(100) NOT NULL,
    aggregate_type      VARCHAR(100) NOT NULL,
    aggregate_id        UUID NOT NULL,
    event_data          JSONB NOT NULL,
    metadata            JSONB NOT NULL DEFAULT '{}',
    sequence_number     BIGINT NOT NULL,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE integration.event IS 'Event store for event-driven architecture. Enables replay, debugging, and AI training.';
COMMENT ON COLUMN integration.event.event_type IS 'Domain event: customer.updated, action.created, model.scored, etc.';
COMMENT ON COLUMN integration.event.metadata IS 'Correlation IDs, causation chain, user context';
COMMENT ON COLUMN integration.event.sequence_number IS 'Per-aggregate ordering for event replay';

-- Monthly partitions for event store
-- NOTE: Add new partitions before the start of each month to avoid errors.
CREATE TABLE IF NOT EXISTS integration.event_y2026m01 PARTITION OF integration.event
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m02 PARTITION OF integration.event
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m03 PARTITION OF integration.event
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m04 PARTITION OF integration.event
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m05 PARTITION OF integration.event
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m06 PARTITION OF integration.event
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m07 PARTITION OF integration.event
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m08 PARTITION OF integration.event
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m09 PARTITION OF integration.event
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m10 PARTITION OF integration.event
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m11 PARTITION OF integration.event
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS integration.event_y2026m12 PARTITION OF integration.event
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
