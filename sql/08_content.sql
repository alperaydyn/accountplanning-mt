-- ============================================================================
-- Account Planning — content Schema
-- ============================================================================
-- AI-generated briefings with structured data templates, product/action
-- insights, versioning, read tracking, and thumbs-up/down feedback.
-- ============================================================================

-- ============================================================================
-- 8.1 CONTENT TEMPLATES
-- ============================================================================
-- CONCEPT
--   A template is the blueprint that tells the platform *what shape* a piece of
--   AI-generated content should have and *how the front-end should render it*.
--   It separates the "schema contract" (template_schema) from the runtime data
--   (briefing.content_data / product_insight.content_data) so that the model
--   output can be validated and displayed without hard-coding layout logic in
--   the application.
--
-- CONTENT TYPES
--   briefing        — daily/weekly summaries pushed to managers and reps
--   product_insight — product-level performance card for a single rep
--   action_insight  — highlights on open/completed actions for a rep
--   notification    — short push-notification or in-app alert body
--   report          — longer structured reports (monthly, quarterly)
--   summary         — concise single-metric or single-entity summaries
--
-- KEY FIELDS
--   template_schema  — a JSON Schema document that the AI output must conform to.
--                      The front-end reads this at render time to pick the right
--                      component (chart, KPI tile, table, etc.).
--   rendering_hints  — front-end metadata: which component library to use, color
--                      palette, layout direction, chart type, etc.  Decouples
--                      visual decisions from data contract changes.
--   version          — templates are versioned; the UNIQUE (tenant_id, code, version)
--                      constraint lets old briefings reference the exact template
--                      version they were generated from.
--
-- EXAMPLE ROW
--   code='DAILY_BRIEFING_V2', content_type='briefing',
--   template_schema='{"type":"object","properties":{"highlights":{"type":"array"},
--     "kpis":{"type":"object"}}}',
--   rendering_hints='{"layout":"card_grid","chart_type":"bar"}'
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.template (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    code            VARCHAR(100) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    content_type    VARCHAR(30) NOT NULL
                    CHECK (content_type IN ('briefing', 'product_insight', 'action_insight', 'notification', 'report', 'summary')),
    template_schema JSONB NOT NULL,
    rendering_hints JSONB NOT NULL DEFAULT '{}',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    version         INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code, version)
);

COMMENT ON TABLE content.template IS 'Content templates define the structured data shape for briefings, insights, etc.';
COMMENT ON COLUMN content.template.template_schema IS 'JSON Schema defining the structure of content_data in briefings/insights';
COMMENT ON COLUMN content.template.rendering_hints IS 'Front-end rendering instructions: layout, component types, chart configs';

-- ============================================================================
-- 8.2 BRIEFINGS
-- ============================================================================
-- CONCEPT
--   A briefing is a single AI-generated document — the actual content delivery
--   artefact that end-users read.  It is always generated from a template
--   (section 8.1) and targets a specific audience scope (e.g., all reps in a
--   branch, a single region, or the entire company).
--
-- AUDIENCE SCOPE
--   The (audience_scope, audience_entity_id) pair determines *who sees this
--   briefing*:  a scope of 'branch' + an entity ID pointing to "Istanbul Branch"
--   limits visibility to employees of that branch.  The application layer
--   enforces this by joining employee org assignments at query time.
--
-- VERSIONING & SERIES
--   Briefings are never updated in place.  When a new version is generated
--   (e.g. after a data refresh) a new row is inserted with the same series_id
--   and an incremented version.  The is_current flag marks the latest version.
--   Keeping all versions supports audit, A/B quality review, and rollback.
--
-- GENERATION TRIGGERS
--   scheduled       — regular ETL / nightly run
--   event           — a significant data change (e.g. churn-risk spike)
--   manual          — triggered by a manager
--   model_refresh   — a new ML model version was deployed
--   data_change     — upstream source data was updated out of cycle
--
-- AI CONTEXT
--   ai_context captures the input conditions: which model version ran, what
--   data windows were included, and confidence scores.  This is the "explain
--   my briefing" trail — useful when a rep disputes a recommendation.
--
-- EXAMPLE ROW
--   audience_scope='branch', frequency='daily', generation_trigger='scheduled',
--   generated_by='ai_agent', content_data={"highlights":[...], "kpis":{...}},
--   valid_from='2026-04-19 00:00', valid_until='2026-04-20 00:00'
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.briefing (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    template_id         UUID NOT NULL REFERENCES content.template(id),
    title               VARCHAR(500) NOT NULL,
    content_data        JSONB NOT NULL,
    audience_scope      VARCHAR(30) NOT NULL
                        CHECK (audience_scope IN ('company', 'lob', 'region', 'branch', 'product_line', 'team', 'individual')),
    audience_entity_id  UUID,
    frequency           VARCHAR(20) NOT NULL DEFAULT 'daily'
                        CHECK (frequency IN ('daily', 'weekly', 'monthly', 'quarterly', 'ad_hoc')),
    version             INTEGER NOT NULL DEFAULT 1,
    series_id           UUID,
    is_current          BOOLEAN NOT NULL DEFAULT true,
    generation_trigger  VARCHAR(30) NOT NULL DEFAULT 'scheduled'
                        CHECK (generation_trigger IN ('scheduled', 'event', 'manual', 'model_refresh', 'data_change')),
    generated_by        VARCHAR(50) NOT NULL DEFAULT 'ai_agent'
                        CHECK (generated_by IN ('ai_agent', 'system', 'user')),
    ai_context          JSONB,
    valid_from          TIMESTAMPTZ,
    valid_until         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE content.briefing IS 'AI-generated briefings. All versions retained. Audience scope determines visibility.';
COMMENT ON COLUMN content.briefing.content_data IS 'Structured content matching the template_schema — consumed by front-end templates';
COMMENT ON COLUMN content.briefing.series_id IS 'Groups versions of the same briefing series together';
COMMENT ON COLUMN content.briefing.ai_context IS 'What data/models were used to generate this briefing';

-- ============================================================================
-- 8.3 BRIEFING READ TRACKING
-- ============================================================================
-- CONCEPT
--   This table answers: "Did the right people read today's briefing, and did
--   they engage with it?"  It gives managers and the AI agent a signal for
--   adoption measurement and nudge targeting.
--
-- WHY TRACK READ TIME?
--   time_spent_seconds is a proxy for engagement quality.  A rep who opens
--   the briefing for 2 seconds has not "read" it in the same sense as one who
--   spent 3 minutes on it.  The agent can prioritise a follow-up nudge for
--   the former.
--
-- DEVICE
--   Knowing whether the briefing was read on web, mobile, tablet, or via API
--   helps the design team optimise layout and content length per channel.
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.briefing_read_tracking (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    briefing_id     UUID NOT NULL REFERENCES content.briefing(id),
    user_id         UUID NOT NULL REFERENCES core.user_(id),
    read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    time_spent_seconds INTEGER,
    device          VARCHAR(30)
                    CHECK (device IS NULL OR device IN ('web', 'mobile', 'tablet', 'api'))
);

COMMENT ON TABLE content.briefing_read_tracking IS 'Tracks who read which briefing, when, and for how long.';

-- ============================================================================
-- 8.4 BRIEFING FEEDBACK
-- ============================================================================
-- CONCEPT
--   A lightweight thumbs-up / thumbs-down signal that lets the AI model
--   improvement loop close.  Only one feedback row is allowed per
--   (briefing, user) pair (UNIQUE constraint) to prevent ballot stuffing.
--
-- RATING ENCODING
--   1 = thumbs down  (the briefing was unhelpful, inaccurate, or irrelevant)
--   5 = thumbs up    (the briefing was useful and actionable)
--   The binary encoding mirrors common feedback widgets and simplifies
--   aggregation — no neutral/ambiguous middle values.
--
-- FEEDBACK TEXT
--   Optional free text lets reps explain *why* something was unhelpful.  This
--   text is surfaced to the content/AI team for qualitative model improvement.
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.briefing_feedback (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    briefing_id     UUID NOT NULL REFERENCES content.briefing(id),
    user_id         UUID NOT NULL REFERENCES core.user_(id),
    rating          SMALLINT NOT NULL
                    CHECK (rating IN (1, 5)),
    feedback_text   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (briefing_id, user_id)
);

COMMENT ON TABLE content.briefing_feedback IS 'Thumbs-up (5) / thumbs-down (1) feedback per user per briefing.';

-- ============================================================================
-- 8.5 PRODUCT INSIGHTS
-- ============================================================================
-- CONCEPT
--   A product insight is a rep-facing AI card that summarises how a specific
--   product is performing for a specific employee's portfolio.  Unlike a
--   briefing (audience_scope can be broad), a product insight is always
--   personal: one rep, one product.
--
-- WHY SEPARATE FROM BRIEFING?
--   Briefings are push-broadcast documents; product insights are pull-on-demand
--   cards rendered inline within the product detail screen.  They have a
--   different template_schema shape, different refresh cadence, and different
--   access control — only the assigned rep and their manager see a given row.
--
-- VERSIONING
--   Same series_id + version pattern as briefings.  is_current = true marks
--   the latest version for a (product, employee) pair.
--
-- EXAMPLE ROW
--   product=MORTGAGE, employee=jane.doe, content_data={"avg_balance":320000,
--   "active_count":14, "churn_risk_count":3, "recommendation":"Schedule QBR"},
--   generated_by='ai_agent'
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.product_insight (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    template_id     UUID NOT NULL REFERENCES content.template(id),
    product_id      UUID NOT NULL REFERENCES product.product(id),
    employee_id     UUID NOT NULL REFERENCES core.employee(id),
    content_data    JSONB NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    series_id       UUID,
    is_current      BOOLEAN NOT NULL DEFAULT true,
    generated_by    VARCHAR(50) NOT NULL DEFAULT 'ai_agent',
    ai_context      JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE content.product_insight IS 'AI-generated product performance insights for individual sales reps.';

-- ============================================================================
-- 8.6 ACTION INSIGHTS
-- ============================================================================
-- CONCEPT
--   An action insight summarises the *actions* dimension of a rep's work:
--   how many actions are open, overdue, or recently completed; which customer
--   types are generating the most backlog; and what the AI recommends doing
--   next to improve closure rates.
--
-- RELATIONSHIP TO ACTION SCHEMA
--   This table does NOT duplicate action rows.  content_data is a pre-aggregated
--   JSONB snapshot (computed by the AI pipeline from action.action) that the UI
--   can render directly — without running live aggregation queries at page-load
--   time.  Think of it as a materialized summary for the AI-generated action
--   coaching card.
--
-- EXAMPLE CONTENT DATA
--   {"open_actions": 12, "overdue": 3, "completed_this_week": 7,
--    "top_priority_customer": "Acme Corp",
--    "recommendation": "Follow up on 3 overdue renewal actions by Friday."}
-- ============================================================================

CREATE TABLE IF NOT EXISTS content.action_insight (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    template_id     UUID NOT NULL REFERENCES content.template(id),
    employee_id     UUID NOT NULL REFERENCES core.employee(id),
    content_data    JSONB NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    series_id       UUID,
    is_current      BOOLEAN NOT NULL DEFAULT true,
    generated_by    VARCHAR(50) NOT NULL DEFAULT 'ai_agent',
    ai_context      JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE content.action_insight IS 'AI-generated action performance insights for sales reps.';
