-- ============================================================================
-- Account Planning — reporting Schema
-- ============================================================================
-- Report definitions, materialized view registry for in-app reports,
-- cached report snapshots, and report access logging.
--
-- ── WHAT IS THE reporting SCHEMA? ───────────────────────────────────────────
--   The reporting schema is the analytical presentation layer of the Account
--   Planning platform.  It does not store raw business data — instead it
--   organises definitions, execution metadata, cached results, and access logs
--   for every report surface the system exposes, whether that surface is a
--   live in-app dashboard, an exported spreadsheet, or a scorecard block inside
--   the AI agent briefing.
--
--   There are two fundamentally different classes of report in this system:
--
--   1. Core-System Reports  (source = 'core_system')
--      Produced by the bank's existing data warehouse or BI platform (e.g.
--      SAP BW, MicroStrategy, Power BI).  The Account Planning platform does
--      NOT generate these reports itself — it receives them as pre-built PDFs,
--      embedded iFrames, or JSON payloads pushed/pulled via the integration
--      layer (11_integration.sql).  A report_definition row acts as the
--      canonical registry entry so the UI knows how to display, cache, and
--      control access to the externally produced artifact.
--
--   2. In-App Reports  (source = 'in_app')
--      Generated natively by the platform using PostgreSQL materialized views.
--      Examples: customer KPI scorecards assembled from customer.customer_-
--      product_metric, action completion rate dashboards aggregated from
--      action.action_instance, or year-to-date target vs. actual charts built
--      from perf.actual_value.  These reports are defined entirely within the
--      database and rendered by the backend API without any external dependency.
--
--   A third class ('hybrid') combines both: the platform enriches a core-system
--   report with locally computed signals before presenting it to the user.
--
-- ── HOW ARE REPORTS GENERATED? ──────────────────────────────────────────────
--   • Scheduled refresh (refresh_strategy = 'scheduled')
--     A background scheduler (e.g. pg_cron, Celery Beat, or a cron-triggered
--     Lambda) reads report_definition rows whose refresh_cron is due, triggers
--     REFRESH MATERIALIZED VIEW CONCURRENTLY on the relevant view, writes a new
--     report_snapshot row with the serialised result, and updates
--     materialized_view_registry with the new last_refreshed_at timestamp.
--
--   • On-demand refresh (refresh_strategy = 'on_demand')
--     When a user opens a dashboard and the latest snapshot is stale (or
--     absent), the backend API generates the report synchronously, caches the
--     result in report_snapshot, and returns it.  Subsequent requests within
--     the TTL window are served from the snapshot without hitting the database.
--
--   • Event-triggered refresh (refresh_strategy = 'event_triggered')
--     Certain events (e.g. a bulk action-status update, an integration sync
--     completing) publish a message to the event bus.  A consumer detects the
--     event, identifies the affected report_definition rows, and schedules
--     immediate refreshes.
--
--   • Real-time (refresh_strategy = 'real_time')
--     Reserved for lightweight widgets that query a live view (not a
--     materialized view) every time the page loads.  No snapshot is stored.
--
-- ── WHO GENERATES REPORTS? ──────────────────────────────────────────────────
--   • Scheduled job service — cron-driven worker that reads refresh_cron
--     expressions and reruns reports on schedule without any user interaction.
--   • Backend API service — generates or serves cached reports when a user
--     opens a dashboard or explicitly requests a refresh.
--   • AI Agent (12_agent.sql) — queries in-app report snapshots to embed KPI
--     data in pre-meeting briefings without running a live query at generation
--     time.
--   • Export service — produces CSV/Excel/PDF exports from report_snapshot
--     result_data and hands the file to the document schema (14_document.sql)
--     for storage and distribution.
--
-- ── WHO CONSUMES REPORTS? ────────────────────────────────────────────────────
--   • Web & mobile frontend — renders dashboard charts, scorecard widgets,
--     and detail drill-downs sourced from report_snapshot.result_data or live
--     materialized view queries.
--   • Relationship Managers (RMs) — view customer scorecards and action
--     completion rates during daily planning.
--   • Branch / Regional Managers — consume comparison and trend reports to
--     evaluate team performance across the hierarchy.
--   • AI Agent — reads KPI snapshots as structured context when composing
--     customer briefings and target commentary.
--   • Compliance / Audit teams — download export-type report snapshots
--     for regulatory submissions.
--   • Data platform / BI team — monitors materialized_view_registry to
--     detect stale or errored views and trigger reprocessing.
--
-- ── SCHEMA OVERVIEW ──────────────────────────────────────────────────────────
--   16.1  report_definition          — catalogue of every report the platform
--                                     can produce or serve.
--   16.2  materialized_view_registry — operational metadata about each
--                                     PostgreSQL materialized view backing an
--                                     in-app report.
--   16.3  report_snapshot            — cached result payloads for fast retrieval
--                                     without re-executing the underlying query.
--   16.4  report_access_log          — immutable audit trail of who accessed
--                                     which report and when.
-- ============================================================================

-- ============================================================================
-- 16.1 REPORT DEFINITIONS
-- ============================================================================
-- CONCEPT
--   reporting.report_definition is the master catalogue of every report the
--   platform knows about.  A "report" in this context is any structured data
--   surface — a dashboard widget, a scorecard panel, an export template, or a
--   comparison matrix — that a user or system component can request by name.
--
--   Every report has a unique (tenant_id, code) pair so that application code
--   can reference it by a stable machine-readable key (e.g. 'customer_kpi_
--   scorecard') without relying on UUIDs in configuration files.
--
--   The report_type field categorises the visual / functional nature of the
--   report:
--     dashboard   — a multi-widget overview surface (e.g. RM homepage).
--     detail      — a deep-dive report for a single entity (e.g. customer
--                   profile analytics).
--     export      — a data dump for download (CSV / Excel / PDF).
--     scorecard   — a performance card with metric vs. target comparisons.
--     comparison  — side-by-side view of multiple entities or periods.
--     trend       — time-series chart showing movement over multiple periods.
--
--   The source field determines HOW the report data is produced:
--     core_system — data comes from an external system; the platform only
--                   stores the definition and controls access.
--     in_app      — data is generated natively via a materialized view or SQL
--                   template managed within this database.
--     hybrid      — locally enriched core-system report.
--
-- WHEN IS THIS TABLE USED?
--   • At startup / deployment: the migration inserts or upserts every known
--     report definition so the application always has a canonical registry.
--   • When a user navigates to a dashboard: the backend looks up the report by
--     (tenant_id, code), checks access_policy, then either serves a cached
--     snapshot or triggers a fresh generation.
--   • When the scheduler runs: it reads all definitions with refresh_strategy
--     IN ('scheduled', 'event_triggered') to build the work queue.
--   • When the AI agent composes a briefing: it reads relevant scorecard
--     definitions to know which KPI snapshots to embed.
--   • When an admin configures access rules: the access_policy JSONB is updated
--     here and propagated to the frontend permission layer.
--
-- KEY FIELDS
--   code             — stable, machine-readable identifier for the report.
--                      Example: 'customer_kpi_scorecard', 'rm_action_dashboard'.
--                      Referenced by the frontend router and AI agent config.
--   query_config     — for in-app reports: the name of the backing materialized
--                      view, any SQL parameter templates, and the mapping from
--                      URL/API parameters to SQL bind variables.
--                      Example: {"view": "rpt.customer_kpi_mv",
--                                "params": {"customer_id": "$1", "period": "$2"}}
--   parameters_schema — JSON Schema describing the parameters this report
--                       accepts (used by the UI to render filter controls and
--                       by the backend to validate incoming requests before
--                       executing the query).
--   refresh_cron     — a cron expression (e.g. '0 6 * * 1-5') interpreted by
--                      the scheduler service.  NULL for on_demand / real_time.
--   access_policy    — JSONB blob controlling who can view the report.
--                      Example: {"min_level": "branch_manager",
--                                "roles": ["analyst", "rm_senior"]}
--
-- EXAMPLE — a native KPI scorecard report for a single customer:
--   code              = 'customer_kpi_scorecard'
--   name              = 'Customer KPI Scorecard'
--   report_type       = 'scorecard'
--   source            = 'in_app'
--   query_config      = {"view": "rpt.customer_kpi_mv",
--                         "params": {"customer_id": "$1", "period_code": "$2"}}
--   parameters_schema = {"type": "object",
--                         "required": ["customer_id", "period_code"],
--                         "properties": {
--                           "customer_id": {"type": "string", "format": "uuid"},
--                           "period_code": {"type": "string", "example": "2026-Q1"}
--                         }}
--   refresh_strategy  = 'scheduled'
--   refresh_cron      = '0 5 * * *'       -- refresh every day at 05:00
--   access_policy     = {"min_level": "rm"}
--
-- EXAMPLE — a core-system trend report sourced from the BI platform:
--   code              = 'revenue_trend_biplatform'
--   name              = 'Revenue Trend (BI Platform)'
--   report_type       = 'trend'
--   source            = 'core_system'
--   query_config      = {"embed_url_template":
--                          "https://bi.bank.internal/reports/revenue?tenant={{tenant_code}}
--                           &period={{period_code}}"}
--   refresh_strategy  = 'on_demand'
--   access_policy     = {"roles": ["regional_manager", "analyst"]}
--
-- NOTES
--   • query_config is intentionally JSONB (not a typed column) because the
--     structure varies significantly between core_system (embed URL templates)
--     and in_app (view name + parameter bindings) reports.
--   • Keep parameters_schema aligned with the JSON Schema draft-07 spec so the
--     frontend can use a generic form-renderer without report-specific code.
--   • The access_policy is enforced by the backend API, not by database RLS —
--     the policy logic is more complex (hierarchy-level checks, role arrays)
--     than standard RLS can express cleanly.
-- ============================================================================

CREATE TABLE IF NOT EXISTS reporting.report_definition (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    code                VARCHAR(100) NOT NULL,
    name                VARCHAR(255) NOT NULL,
    description         TEXT,
    report_type         VARCHAR(30) NOT NULL
                        CHECK (report_type IN ('dashboard', 'detail', 'export', 'scorecard', 'comparison', 'trend')),
    source              VARCHAR(30) NOT NULL DEFAULT 'in_app'
                        CHECK (source IN ('core_system', 'in_app', 'hybrid')),
    query_config        JSONB,
    parameters_schema   JSONB NOT NULL DEFAULT '{}',
    refresh_strategy    VARCHAR(30) NOT NULL DEFAULT 'on_demand'
                        CHECK (refresh_strategy IN ('on_demand', 'scheduled', 'event_triggered', 'real_time')),
    refresh_cron        VARCHAR(50),
    access_policy       JSONB NOT NULL DEFAULT '{}',
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

COMMENT ON TABLE reporting.report_definition IS 'Report definitions. Most reports from core system; in-app reports use materialized views.';
COMMENT ON COLUMN reporting.report_definition.query_config IS 'For in-app: materialized view name, SQL template, parameters mapping';
COMMENT ON COLUMN reporting.report_definition.access_policy IS 'Who can view: {"min_level": "branch_manager", "roles": ["analyst"]}';

-- ============================================================================
-- 16.2 MATERIALIZED VIEW REGISTRY
-- ============================================================================
-- CONCEPT
--   reporting.materialized_view_registry is the operational control plane for
--   every PostgreSQL materialized view that backs an in-app report.  A
--   materialized view is a pre-computed query result persisted as a physical
--   table inside the database; refreshing it re-executes the underlying query
--   and overwrites the stored rows.
--
--   This registry exists because PostgreSQL's own system catalogs (pg_matviews)
--   do not capture business-level metadata: which tenant owns the view, how
--   often it should be refreshed, which source tables it depends on, and what
--   error (if any) occurred during the last refresh.  By maintaining this
--   registry, the scheduler service and the monitoring dashboard have a single,
--   queryable source of truth about the health of all analytical views.
--
-- HOW IT FITS IN THE REFRESH LIFECYCLE
--   1. At deployment, a row is inserted here for every materialized view that
--      is created in the database.  status = 'active', last_refreshed_at = NULL.
--   2. The scheduler reads rows where status = 'active' and determines (via
--      the linked report_definition.refresh_cron) which views are due.
--   3. It sets status = 'refreshing', then issues
--      REFRESH MATERIALIZED VIEW CONCURRENTLY <view_name>.
--   4. On success: status = 'active', last_refreshed_at = now(),
--      refresh_duration_ms = elapsed time, row_count = new row count.
--   5. On failure: status = 'error', error_message = PG error text.
--      The monitoring alert fires and the on-call engineer investigates.
--   6. If a view has not been refreshed within 2× its expected interval it is
--      automatically flagged status = 'stale' by a health-check job.
--
-- WHEN IS THIS TABLE USED?
--   • Scheduler service — determines which views to refresh and in what order
--     (e.g. base views before dependent views).
--   • Monitoring / alerting — dashboard reads status and last_refreshed_at
--     to surface stale or errored views to the data platform team.
--   • Dependency tracking — source_tables is used to scope refresh triggers:
--     when a data sync job updates customer.customer_product_metric, the
--     event bus can look up all views that list that table in source_tables
--     and trigger their refresh.
--   • Capacity planning — row_count and refresh_duration_ms trends guide
--     decisions about partitioning or view simplification when refresh times
--     grow unacceptably long.
--
-- KEY FIELDS
--   view_name          — exact PostgreSQL object name, schema-qualified.
--                        Example: 'rpt.customer_kpi_mv'.
--   source_tables      — array of fully qualified table names the view reads.
--                        Example: ARRAY['customer.customer_product_metric',
--                                       'perf.target', 'perf.actual_value']
--                        Used for intelligent, event-driven refresh scheduling.
--   refresh_frequency  — coarse bucket used by monitoring to classify a view
--                        as stale.  The precise schedule lives in the linked
--                        report_definition.refresh_cron.
--   refresh_duration_ms — execution time of the last REFRESH command in ms.
--                         A sudden spike signals a data volume growth event or
--                         a missing index on the underlying source tables.
--   status             — current operational state of the view.
--                        'active'     — healthy, data is current.
--                        'refreshing' — refresh is in flight right now.
--                        'stale'      — last refresh is overdue.
--                        'error'      — last refresh failed; error_message set.
--                        'disabled'   — manually paused by an operator.
--
-- EXAMPLE — daily KPI materialized view:
--   view_name         = 'rpt.customer_kpi_mv'
--   source_tables     = ARRAY['customer.customer_product_metric',
--                              'perf.target', 'perf.actual_value',
--                              'customer.customer']
--   refresh_frequency = 'daily'
--   last_refreshed_at = '2026-04-19T05:00:12Z'
--   refresh_duration_ms = 3420        -- 3.4 seconds, healthy
--   row_count         = 84200
--   status            = 'active'
--
-- EXAMPLE — hourly action pipeline view that failed to refresh:
--   view_name         = 'rpt.action_completion_rate_mv'
--   source_tables     = ARRAY['action.action_instance', 'action.action_log']
--   refresh_frequency = 'hourly'
--   last_refreshed_at = '2026-04-19T09:00:08Z'
--   status            = 'error'
--   error_message     = 'ERROR:  deadlock detected on action.action_instance'
--
-- NOTES
--   • REFRESH MATERIALIZED VIEW CONCURRENTLY requires a UNIQUE index on the
--     materialized view.  Ensure every view registered here has at least one
--     unique index defined, or the concurrent refresh will fall back to a
--     blocking lock.
--   • The registry row is per (tenant_id, view_name).  If you use per-tenant
--     schemas instead of a shared schema with tenant_id filtering, each tenant
--     view gets its own registry entry.
--   • Consider partitioning large materialized views by period_code if
--     refresh_duration_ms grows beyond acceptable thresholds.
-- ============================================================================

CREATE TABLE IF NOT EXISTS reporting.materialized_view_registry (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    view_name           VARCHAR(255) NOT NULL,
    source_tables       VARCHAR(255)[] NOT NULL,
    refresh_frequency   VARCHAR(30) NOT NULL DEFAULT 'daily'
                        CHECK (refresh_frequency IN ('hourly', 'daily', 'weekly', 'monthly', 'on_demand')),
    last_refreshed_at   TIMESTAMPTZ,
    refresh_duration_ms INTEGER,
    row_count           BIGINT,
    status              VARCHAR(20) NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'refreshing', 'stale', 'error', 'disabled')),
    error_message       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE reporting.materialized_view_registry IS 'Registry of PostgreSQL materialized views used for in-app reporting.';
COMMENT ON COLUMN reporting.materialized_view_registry.source_tables IS 'Tables this view depends on — used for intelligent refresh scheduling';

-- ============================================================================
-- 16.3 REPORT SNAPSHOTS (Cached Results)
-- ============================================================================
-- CONCEPT
--   reporting.report_snapshot is a cache layer that stores the serialised
--   output of a report execution as a JSONB payload.  Its primary purpose is
--   to decouple report consumption from report generation:
--
--     Without snapshots: every dashboard page load triggers a potentially
--     expensive materialized-view or BI-platform query, making response time
--     dependent on data volume and concurrent load.
--
--     With snapshots: the backend API checks whether a fresh enough snapshot
--     exists for the requested (report_id, parameters) combination.  If it
--     does, the JSON payload is returned immediately without touching the
--     analytical data layer.  Only when the snapshot is absent or expired does
--     the backend run the full generation pipeline.
--
--   Snapshots serve multiple consumer types simultaneously:
--     • The web frontend pre-fetches snapshots at login time and stores them
--       in a client-side cache for instant offline rendering.
--     • The AI agent reads the snapshot result_data directly as structured
--       JSON context when composing a briefing, avoiding a live query at a
--       time-sensitive generation step.
--     • The export service serialises the snapshot into CSV/PDF and passes the
--       file to document.document (14_document.sql) for archival.
--
-- WHEN IS THIS TABLE USED?
--   • By the backend API on every dashboard or scorecard request — first check
--     if a valid (non-expired) snapshot exists, serve it; otherwise generate
--     a fresh one, INSERT a new row, then serve.
--   • By the scheduled job after a successful materialized-view refresh — the
--     new result is immediately serialised into a snapshot row so that the
--     first user request after the refresh is also cache-served.
--   • By the AI agent briefing generator — queries the latest snapshot for the
--     'customer_kpi_scorecard' report for the target customer and embeds the
--     metrics in the briefing without triggering a live query.
--   • By the data retention service — purges expired snapshot rows
--     (expires_at < now()) on a nightly schedule to prevent unbounded growth.
--
-- KEY FIELDS
--   parameters   — the exact parameter values used to generate this snapshot
--                  (e.g. {"customer_id": "uuid-acme", "period_code": "2026-Q1"}).
--                  The combination of (report_id, parameters) acts as the
--                  logical cache key; the backend queries:
--                    SELECT * FROM reporting.report_snapshot
--                    WHERE report_id = $1
--                      AND parameters = $2::jsonb
--                      AND (expires_at IS NULL OR expires_at > now())
--                    ORDER BY generated_at DESC LIMIT 1;
--   result_data  — the full report payload as JSONB.  Structure varies by
--                  report_type but typically contains:
--                    {"rows": [...], "summary": {...}, "generated_at": "..."}
--   expires_at   — when this snapshot becomes stale and should no longer be
--                  served.  NULL means the snapshot never auto-expires (used
--                  for historical archive snapshots).
--   generated_by — what triggered this snapshot:
--                    'scheduled'    — cron job after a materialized view refresh.
--                    'user_request' — a user explicitly clicked "Refresh".
--                    'event'        — an integration or action event triggered it.
--                    'system'       — the AI agent or export service created it
--                                    as a side effect of its own processing.
--
-- EXAMPLE — RM opens Acme Corp scorecard for Q1 2026:
--   report_id    → customer_kpi_scorecard report UUID
--   parameters   = {"customer_id": "uuid-acme", "period_code": "2026-Q1"}
--   result_data  = {"rows": [
--                     {"metric": "Revenue", "actual": 1250000, "target": 1200000,
--                      "achievement_pct": 104.2, "vs_prior_year_pct": 8.1},
--                     {"metric": "NPS",     "actual": 42,      "target": 45,
--                      "achievement_pct": 93.3, "vs_prior_year_pct": 5.0}
--                   ],
--                   "summary": {"overall_achievement": 98.7},
--                   "generated_at": "2026-04-19T05:00:18Z"}
--   row_count    = 2
--   generated_at = '2026-04-19T05:00:18Z'
--   expires_at   = '2026-04-20T05:00:00Z'   -- expires at next scheduled refresh
--   generated_by = 'scheduled'
--
-- EXAMPLE — AI agent generates a briefing snapshot on-demand at 08:45 for a
--           09:00 meeting:
--   generated_by = 'system'
--   expires_at   = '2026-04-19T12:00:00Z'   -- short-lived; meeting context only
--
-- NOTES
--   • result_data can grow large for export-type reports (thousands of rows).
--     Consider storing only aggregate / summary snapshots in this table and
--     offloading raw export payloads to the document schema (14_document.sql).
--   • Index on (report_id, parameters, generated_at DESC) and (expires_at)
--     to efficiently serve cache-lookup queries and nightly expiry purges.
--   • Two snapshots for the same (report_id, parameters) can coexist during a
--     refresh; the backend always reads the one with the highest generated_at
--     that has not yet expired.
-- ============================================================================

CREATE TABLE IF NOT EXISTS reporting.report_snapshot (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    report_id       UUID NOT NULL REFERENCES reporting.report_definition(id),
    parameters      JSONB NOT NULL DEFAULT '{}',
    result_data     JSONB NOT NULL,
    row_count       INTEGER,
    generated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,
    generated_by    VARCHAR(30) NOT NULL DEFAULT 'scheduled'
                    CHECK (generated_by IN ('scheduled', 'user_request', 'event', 'system')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE reporting.report_snapshot IS 'Cached report results for fast retrieval. Expired snapshots are cleaned up.';

-- ============================================================================
-- 16.4 REPORT ACCESS LOG
-- ============================================================================
-- CONCEPT
--   reporting.report_access_log is an append-only audit trail that records
--   every time a user (or system component) retrieves a report result.  It
--   answers the operational question: "Who viewed which report, with what
--   parameters, and did they get a cached result or a fresh query?"
--
--   Unlike document.document_access_log (which tracks file-level interactions
--   such as downloads and prints), this table tracks data-level report views —
--   the moment a JSON payload was served to a user's browser or to an
--   automated consumer.  It captures whether the result came from the cache
--   (cache_hit), required a full re-execution (fresh_query), or was delivered
--   as a file export (export).
--
-- WHY IS THIS TABLE NEEDED?
--   • Usage analytics — identify which reports are most consumed across the
--     user population; determine which reports can be deprecated (zero views
--     in 90 days) or which need faster refresh cadences (accessed 500×/day).
--   • Cache efficiency monitoring — measure the cache_hit rate per report to
--     tune expires_at and refresh_cron settings.  A low hit rate signals that
--     the snapshot expires too quickly or that users access the report with
--     highly varied parameter combinations.
--   • Compliance audit — in regulated environments, demonstrate that
--     sensitive performance data (e.g. individual RM scorecards) was accessed
--     only by authorised roles over a given period.
--   • Per-user behaviour insights — surface to managers which reports their
--     team members engage with most, informing training and coaching.
--
-- WHO WRITES TO THIS TABLE?
--   The backend API writes a row here whenever:
--     • A report JSON payload is returned to the browser (source = 'cache_hit'
--       or 'fresh_query').
--     • An export is triggered and the report data is serialised to CSV/PDF
--       (source = 'export').
--   AI agent internal reads are NOT logged here (they are captured in
--   agent.conversation_turn metadata instead) to avoid polluting access
--   statistics with non-human traffic.
--
-- WHO READS FROM THIS TABLE?
--   • Product / analytics team — dashboards showing report adoption, top
--     reports by view count, and per-user engagement over time.
--   • Data platform / BI team — cache efficiency analysis to optimise
--     refresh schedules and snapshot TTLs.
--   • Compliance officers — audit queries by (report_id, accessed_at range)
--     to confirm access control policies are being enforced.
--   • Automated reporting pipeline — weekly summary of report consumption
--     emailed to tenant administrators.
--
-- KEY FIELDS
--   parameters   — the parameters the user supplied for this specific access.
--                  Stored to distinguish, e.g., an RM viewing *their own*
--                  scorecard vs. a manager drilling into a subordinate's card.
--   source       — indicates how the result was fulfilled:
--                    'cache_hit'   — served from report_snapshot without
--                                    re-executing the underlying query.
--                    'fresh_query' — snapshot was absent/expired; the report
--                                    was re-executed and a new snapshot created.
--                    'export'      — the report was downloaded as a file (CSV,
--                                    PDF, Excel).
--   accessed_at  — server-side timestamp at moment of delivery.
--
-- EXAMPLE — RM views Acme Corp KPI scorecard served from cache:
--   report_id    → customer_kpi_scorecard UUID
--   user_id      → RM jane-uuid
--   parameters   = {"customer_id": "uuid-acme", "period_code": "2026-Q1"}
--   source       = 'cache_hit'
--   accessed_at  = '2026-04-19T08:52:14Z'
--
-- EXAMPLE — regional manager exports an action completion report as Excel:
--   report_id    → rm_action_dashboard UUID
--   user_id      → regional-manager-uuid
--   parameters   = {"region_id": "uuid-region-west", "period_code": "2026-Q1"}
--   source       = 'export'
--   accessed_at  = '2026-04-19T17:30:02Z'
--
-- NOTES
--   • This table is append-only — rows must never be updated or deleted within
--     the tenant's data retention window.
--   • Index on (report_id, accessed_at DESC) for usage analytics and on
--     (user_id, accessed_at DESC) for per-user audit queries.
--   • Consider partitioning by month (RANGE on accessed_at) if the platform
--     serves high report volumes and this table grows beyond tens of millions
--     of rows per year.
--   • source = 'export' events should also be cross-referenced with
--     document.document_access_log if the export was saved as a document.
-- ============================================================================

CREATE TABLE IF NOT EXISTS reporting.report_access_log (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    report_id       UUID NOT NULL REFERENCES reporting.report_definition(id),
    user_id         UUID NOT NULL REFERENCES core.user_(id),
    parameters      JSONB,
    source          VARCHAR(20) NOT NULL DEFAULT 'fresh_query'
                    CHECK (source IN ('cache_hit', 'fresh_query', 'export')),
    accessed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE reporting.report_access_log IS 'Report usage tracking for analytics on report consumption patterns.';
