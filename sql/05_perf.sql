-- ============================================================================
-- Account Planning — perf Schema
-- ============================================================================
-- Performance metrics, multi-level targets, realizations, and composite
-- scorecards. Metric calculation engine deferred to future.
-- ============================================================================
--
-- BUSINESS OVERVIEW
-- -----------------
-- The `perf` schema is the performance management backbone of the Account
-- Planning system.  It answers one fundamental business question:
--   "How is each bank employee, team, branch, or business line performing
--    against the agreed commercial goals — and are those goals on track?"
--
-- Banks set targets for virtually every activity that drives revenue: how many
-- new loans to originate, how much deposit volume to grow, how many customers
-- to cross-sell, and what overall relationship NPS score to achieve.  These
-- targets cascade from the board level (company-wide) down through lines of
-- business, regions, branches, teams, and ultimately to individual relationship
-- managers.  The `perf` schema models this entire cascade.
--
-- Core concepts:
--   • Metric Definition — the reusable business KPI template (e.g., "Loan
--     Volume", "Customer NPS Score", "Product Penetration Rate").
--   • Target          — a concrete numerical goal for a specific entity (e.g.,
--     "Branch Istanbul-Levent must originate ₺50M in cash loans in Q1 2025").
--   • Realization     — the actual achieved value at a point in time (e.g.,
--     "as of 15 Jan, Istanbul-Levent has originated ₺32M → 64% achievement").
--   • Scorecard       — a weighted composite view that rolls multiple metrics
--     into a single score for an entity level (e.g., a Branch Manager scorecard
--     that is 40% volume, 30% revenue, 20% NPS, 10% activity).
--
-- KEY DESIGN DECISIONS
-- --------------------
--   • Metric definitions are tenant-scoped and reusable — one definition of
--     "Loan Volume" is shared across all targets and scorecards.  This avoids
--     duplicating business logic and makes global metric changes (e.g., changing
--     the aggregation method) a single-row update.
--
--   • Targets are polymorphic by level — the `target_entity_id` column points
--     to different tables depending on `target_level` (company → org_unit,
--     employee → core.user_).  This avoids a proliferation of level-specific
--     target tables while keeping the query pattern uniform.
--
--   • Three-tier target bands (floor / target / stretch) — rather than a
--     binary pass/fail, the system tracks three threshold values so that
--     dashboards and the AI agent can give nuanced performance signals:
--     below floor (underperformance), between floor and target (needs work),
--     between target and stretch (on track), above stretch (exceptional).
--
--   • Realizations are append-only snapshots — rather than updating a single
--     "current achievement" value, each data push from the core system inserts
--     a new row.  This preserves the full historical trajectory and allows
--     trend analysis ("was mid-month realisation tracking better than last
--     quarter?").
--
-- DATA PRODUCERS (who writes to these tables)
-- -------------------------------------------
--   • Target Setting Service  — internal backoffice tool / admin UI used by
--     Sales Ops or Finance teams to cascade and lock in annual / quarterly
--     targets.  Targets are typically uploaded in bulk via Excel import at the
--     start of each period.
--
--   • Core Banking / CRM ETL  — nightly or intraday jobs that pull actual
--     performance figures (loan origination, deposit balances, transaction
--     counts) from core banking, CRM, and ancillary source systems, then
--     insert new rows into perf.realization for every active target.
--
--   • AI / Agent Layer (12)   — the agentic engine writes achievement
--     summaries and trend observations to realization.source='calculated'
--     when it performs mid-period forecasting or gap-fill calculations.
--
--   • Manual Override         — authorized users can post manual realization
--     entries (source='manual') for metrics that have no automated feed
--     (e.g., a qualitative readiness audit score entered by a regional manager).
--
-- DATA CONSUMERS (who reads from these tables)
-- ---------------------------------------------
--   • Account Planning API    — surfaces "how is my customer's RM performing?"
--     and "is this branch hitting targets?" context panels in the planner UI.
--
--   • AI / Agent Layer (12)   — uses realization data and target bands to
--     generate performance alerts, coaching nudges, and next-best-action
--     recommendations in agentic conversations (e.g., "You are at 58% of your
--     loan volume target; here are 3 clients with high propensity — call them
--     this week").
--
--   • Reporting / Analytics (16) — joins perf tables with org hierarchy and
--     customer data to produce monthly performance decks, regional league
--     tables, and scorecard roll-ups for executive dashboards.
--
--   • Notification Service (13) — triggers alerts when an entity's achievement
--     drops below the floor threshold or when a period is about to close with
--     significant gap remaining.
--
--   • Content / Playbook Engine — tailors playbook recommendations based on
--     which metrics an RM is lagging on (e.g., surface loan playbooks when
--     loan volume achievement < 70%).
-- ============================================================================


-- ============================================================================
-- 5.1 METRIC DEFINITIONS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- A metric definition is the blueprint for a measurable business KPI.  Think
-- of it as the "type" of a target — before you can set a target of
-- "₺50M in Cash Loans", you need to define the metric "Loan Volume" once,
-- describing how it is measured, what unit it uses, and how values should be
-- aggregated over time.
--
-- Metric definitions are:
--   • Created once per tenant by the Sales Ops / Finance team during initial
--     setup or whenever a new KPI is introduced.
--   • Referenced by every target, realization, and scorecard component row —
--     so changing the aggregation method here automatically affects all
--     downstream calculations.
--   • Either "atomic" (sourced directly from core banking) or "composite"
--     (calculated from a weighted combination of other metrics).
--
-- METRIC CATEGORIES — what business area does this KPI cover?
-- -----------------------------------------------------------
--   volume     — monetary volume (e.g., Loan Origination Volume in TRY)
--   count      — unit count (e.g., Number of New Accounts Opened)
--   ratio      — a proportion (e.g., NPL Ratio, Fee Income / Total Income)
--   score      — an index (e.g., NPS Score 0–100, Risk Score)
--   activity   — activity-based (e.g., Number of Customer Visits, Calls Made)
--   revenue    — fee or interest income generated
--   experience — customer satisfaction / quality metrics
--
-- COMPOSITE METRICS
-- -----------------
-- A composite metric aggregates other metrics with weights.  Example: a
-- "Relationship Score" might be defined as:
--   {
--     "components": [
--       {"metric_id": "<loan-volume-uuid>",  "weight": 0.40},
--       {"metric_id": "<deposit-vol-uuid>",  "weight": 0.30},
--       {"metric_id": "<nps-score-uuid>",    "weight": 0.20},
--       {"metric_id": "<visits-count-uuid>", "weight": 0.10}
--     ]
--   }
-- The scorecard engine (or future calculation engine) reads this JSONB to
-- derive a single composite score per entity, which is then stored as a
-- realization row.
--
-- EXAMPLE ROWS
-- ------------
--   code='LOAN_VOL_TRY',    name='TL Cash Loan Volume',
--     category='volume',    unit='TRY',   aggregation_method='sum',
--     source='core_system', is_composite=false
--
--   code='NEW_ACCT_COUNT',  name='New Account Openings',
--     category='count',     unit='count', aggregation_method='count',
--     source='core_system', is_composite=false
--
--   code='BRANCH_SCORE',    name='Branch Composite Score',
--     category='score',     unit='score', aggregation_method='weighted_avg',
--     source='calculated',  is_composite=true,
--     composite_formula={"components":[...]}
--
-- PRODUCED BY  : Sales Ops / Finance admin UI (metric catalogue management),
--                Migration / ETL (bulk import of existing KPI catalogue)
-- CONSUMED BY  : Target Setting Service (picker when creating a new target),
--                Realization ETL (maps source-system field → metric_id),
--                Scorecard Engine (weight-calculates composite scores),
--                Reporting (16), AI Agent (12)
-- ============================================================================

CREATE TABLE IF NOT EXISTS perf.metric_definition (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    code                VARCHAR(100) NOT NULL,
    name                VARCHAR(255) NOT NULL,
    description         TEXT,
    category            VARCHAR(50) NOT NULL
                        CHECK (category IN ('volume', 'count', 'ratio', 'score', 'activity', 'revenue', 'experience')),
    unit                VARCHAR(30) NOT NULL DEFAULT 'TRY',
    data_type           VARCHAR(20) NOT NULL DEFAULT 'decimal'
                        CHECK (data_type IN ('decimal', 'integer', 'percentage')),
    aggregation_method  VARCHAR(30) NOT NULL DEFAULT 'sum'
                        CHECK (aggregation_method IN ('sum', 'avg', 'count', 'max', 'min', 'weighted_avg', 'last')),
    is_composite        BOOLEAN NOT NULL DEFAULT false,
    composite_formula   JSONB,
    source              VARCHAR(50) NOT NULL DEFAULT 'core_system'
                        CHECK (source IN ('core_system', 'calculated', 'manual')),
    -- [FUTURE] Metric calculation engine — currently metrics are provided by the core system.
    -- Some cases may require in-app calculation. The field below is reserved for future
    -- calculation logic (formulas, SQL snippets, aggregation rules).
    calculation_config  JSONB,
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code),
    CONSTRAINT chk_composite_formula CHECK (
        (is_composite = false) OR
        (is_composite = true AND composite_formula IS NOT NULL)
    )
);

-- Example rows:
--   (tenant_id='t1', code='LOAN_VOL_TRY', name='TL Cash Loan Volume',
--     category='volume', unit='TRY', aggregation_method='sum',
--     source='core_system', is_composite=false)
--
--   (tenant_id='t1', code='BRANCH_SCORE', name='Branch Composite Score',
--     category='score', unit='score', aggregation_method='weighted_avg',
--     source='calculated', is_composite=true,
--     composite_formula={"components":[{"metric_id":"<loan-uuid>","weight":0.4},...]})

COMMENT ON TABLE perf.metric_definition IS 'Tenant-defined performance metrics. Supports composite metrics with weighted formulas.';
COMMENT ON COLUMN perf.metric_definition.composite_formula IS 'For composite metrics: {"components": [{"metric_id": "...", "weight": 0.4}]}';
COMMENT ON COLUMN perf.metric_definition.calculation_config IS '[FUTURE] Reserved for in-app calculation logic. Currently, metrics are sourced from core systems.';


-- ============================================================================
-- 5.2 TARGETS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- A target is a concrete numerical goal assigned to a specific organizational
-- entity for a defined time window.  Targets cascade from the top of the
-- org hierarchy downwards:
--
--   Company ──► Line of Business ──► Region ──► Area ──► Branch ──► Team ──► Employee
--
-- Example cascade for "TL Cash Loan Volume — Q1 2025":
--   Company  target: ₺10 billion   (set by Finance)
--   LOB      target: ₺4 billion    (Retail Banking's share)
--   Region   target: ₺800 million  (Marmara Region)
--   Branch   target: ₺50 million   (Istanbul-Levent branch)
--   Employee target: ₺8 million    (individual RM's personal quota)
--
-- Each target row is fully self-describing: it knows its metric, the entity it
-- belongs to, the time period it covers, and the three-tier value band.
--
-- THREE-TIER TARGET BAND (floor / target / stretch)
-- --------------------------------------------------
-- Banks use three thresholds instead of a single goal to reflect the reality
-- that performance is a spectrum, not a binary pass/fail:
--
--   floor_value   — The minimum acceptable threshold.  Falling below this
--                   triggers escalation, performance improvement plans, or
--                   automated alerts.  Example: ₺35M for the branch above.
--
--   target_value  — The primary agreed goal.  Achieving this is "on plan".
--                   Incentive schemes typically reset or pay out at this level.
--                   Example: ₺50M.
--
--   stretch_value — The aspirational ceiling.  Exceeding this triggers bonus
--                   accelerators or recognition.  Example: ₺65M.
--
-- Resulting achievement bands for a branch at ₺32M realization:
--   < ₺35M (floor)   → 🔴 Underperforming — escalation triggered
--   ₺35M–₺50M (gap)  → 🟡 Below target    — coaching recommended
--   ₺50M–₺65M (plan) → 🟢 On target       — on track
--   > ₺65M (stretch) → 🏆 Exceptional      — accelerator reward
--
-- POLYMORPHIC ENTITY REFERENCE
-- -----------------------------
-- target_entity_id resolves to different tables depending on target_level:
--   company / lob / region / area / branch / team → core.org_unit(id)
--   employee                                       → core.user_(id)
-- This polymorphism is intentional; the application layer enforces the correct
-- FK at runtime.  A future refactor could add a dedicated junction table if
-- strict DB-level FK enforcement becomes necessary.
--
-- PRODUCED BY  : Target Setting Service (bulk upload / Excel import by Finance
--                and Sales Ops at period start), Account Planning API
--                (ad-hoc target adjustments by authorized managers)
-- CONSUMED BY  : Realization ETL (each realization row references a target),
--                Account Planning API (performance panels in planner UI),
--                AI Agent (12) for gap analysis and coaching logic,
--                Reporting (16) for league tables and achievement dashboards,
--                Notification Service (13) for threshold-breach alerts
-- ============================================================================

CREATE TABLE IF NOT EXISTS perf.target (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    metric_id           UUID NOT NULL REFERENCES perf.metric_definition(id),
    target_level        VARCHAR(30) NOT NULL
                        CHECK (target_level IN ('company', 'lob', 'region', 'area', 'branch', 'team', 'employee')),
    target_entity_id    UUID NOT NULL,
    product_id          UUID REFERENCES product.product(id),
    period_type         VARCHAR(20) NOT NULL DEFAULT 'monthly'
                        CHECK (period_type IN ('monthly', 'quarterly', 'yearly', 'custom')),
    period_start        DATE NOT NULL,
    period_end          DATE NOT NULL,
    target_value        DECIMAL(20,4) NOT NULL,
    stretch_value       DECIMAL(20,4),
    floor_value         DECIMAL(20,4),
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_target_dates CHECK (period_end > period_start),
    CONSTRAINT chk_target_values CHECK (
        floor_value IS NULL OR stretch_value IS NULL OR floor_value <= target_value
    )
);

-- Example rows:
--   (metric_id=<LOAN_VOL_TRY>, target_level='branch',
--     target_entity_id=<istanbul-levent-branch-uuid>,
--     period_type='quarterly', period_start='2025-01-01', period_end='2025-03-31',
--     target_value=50000000.00, floor_value=35000000.00, stretch_value=65000000.00)
--
--   (metric_id=<NEW_ACCT_COUNT>, target_level='employee',
--     target_entity_id=<rm-user-uuid>,
--     period_type='monthly', period_start='2025-01-01', period_end='2025-01-31',
--     target_value=15.00, floor_value=8.00, stretch_value=25.00)

COMMENT ON TABLE perf.target IS 'Multi-level targets: company → employee. Supports calendar and custom periods. Three Tier Target System: Floor, Target, Stretch';
COMMENT ON COLUMN perf.target.target_entity_id IS 'References org_unit (for company/lob/region/branch/team) or employee (for employee level)';
COMMENT ON COLUMN perf.target.stretch_value IS 'Optional stretch/aspirational target above the primary target';
COMMENT ON COLUMN perf.target.floor_value IS 'Optional minimum acceptable threshold';


-- ============================================================================
-- 5.3 REALIZATIONS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- A realization record answers the question: "As of a specific date, how much
-- of the target has actually been achieved?"  The table is the performance
-- fact table — every nightly ETL run from core banking produces a new
-- realization row for each active target.
--
-- This append-only design (rather than updating a single "current" value) is
-- intentional for several reasons:
--   1. Trend analysis — you can plot achievement trajectory across the period
--      (e.g., "by day 10 we were at 30%, by day 20 at 58%"), which the AI
--      agent uses to forecast whether the entity will hit the target by period
--      end.
--   2. Auditability   — every data point has a permanent record.  If a source
--      system is corrected retroactively, the correction appears as a new row
--      (dated the correction date) rather than silently overwriting history.
--   3. Replay         — if the ETL logic changes (e.g., a metric's calculation
--      is corrected), old snapshots remain intact and a restatement batch can
--      be applied alongside them.
--
-- HOW achievement_pct IS CALCULATED
-- -----------------------------------
--   achievement_pct = (actual_value / target.target_value) * 100
--
-- The ETL computes this at insert time as a convenience for fast dashboard
-- queries.  It is intentionally denormalized — the source of truth remains
-- actual_value and the target table's target_value.
--
-- PERFORMANCE DATA SOURCES
-- ------------------------
--   core_system — the primary feed: nightly ETL jobs pull from core banking
--                 (e.g., Temenos T24, Oracle FLEXCUBE), CRM (Salesforce,
--                 Microsoft Dynamics), and treasury systems.
--   calculated  — the in-app engine or AI layer derives the value from other
--                 realizations (e.g., composite metric score, mid-period
--                 projection, gap-fill for missing source data).
--   manual      — authorized users enter values directly for metrics with no
--                 automated feed (e.g., qualitative audit scores, market-share
--                 estimates from external research).
--
-- TYPICAL ETL CADENCE
-- --------------------
--   Daily (EOD)    — standard for volume, count, and revenue metrics.
--   Intraday       — real-time or near-real-time for activity metrics (calls,
--                    visits) where management wants same-day visibility.
--   Monthly / End  — for ratio and score metrics that are only meaningful at
--                    period close (e.g., NPL ratio, NPS score from survey).
--
-- PRODUCED BY  : Core Banking / CRM ETL pipelines (nightly batch),
--                AI Agent (12) (calculated projections and gap-fill),
--                Manual Entry API (for authorized overrides)
-- CONSUMED BY  : Account Planning API (live achievement widgets),
--                AI Agent (12) (gap analysis, coaching recommendations,
--                  "you need ₺18M more in 12 days — here are your top prospects"),
--                Reporting (16) (trajectory charts, league tables,
--                  month-over-month trend reports),
--                Notification Service (13) (floor-breach and end-of-period
--                  deadline alerts)
-- ============================================================================

CREATE TABLE IF NOT EXISTS perf.realization (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    target_id       UUID NOT NULL REFERENCES perf.target(id),
    snapshot_date   DATE NOT NULL,
    actual_value    DECIMAL(20,4) NOT NULL,
    achievement_pct DECIMAL(8,4),
    source          VARCHAR(50) NOT NULL DEFAULT 'core_system'
                    CHECK (source IN ('core_system', 'calculated', 'manual')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Example rows (daily snapshots for an RM's monthly loan target of ₺8M):
--   (target_id=<rm-jan-target>, snapshot_date='2025-01-10',
--     actual_value=2400000.00, achievement_pct=30.00, source='core_system')
--
--   (target_id=<rm-jan-target>, snapshot_date='2025-01-20',
--     actual_value=4640000.00, achievement_pct=58.00, source='core_system')
--
--   (target_id=<rm-jan-target>, snapshot_date='2025-01-31',
--     actual_value=8200000.00, achievement_pct=102.50, source='core_system')

COMMENT ON TABLE perf.realization IS 'Point-in-time realization snapshots against targets. Append-only to preserve trajectory history and support trend analysis.';
COMMENT ON COLUMN perf.realization.achievement_pct IS 'Denormalized convenience field: (actual_value / target.target_value) * 100. Computed by ETL at insert time.';
COMMENT ON COLUMN perf.realization.source IS 'core_system = ETL from core banking/CRM; calculated = AI/app-derived; manual = authorized user override.';


-- ============================================================================
-- 5.4 SCORECARDS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- A scorecard is a curated, weighted composite view of performance that rolls
-- multiple individual metrics into a single overall score for a given
-- organizational level.  Scorecards answer the question:
--   "Taking everything into account, how is this branch / team / employee
--    performing as a whole?"
--
-- Different entity levels have different scorecards because their
-- responsibilities — and therefore the metrics that matter — differ:
--
--   Employee Scorecard  — mostly activity and personal volume/revenue metrics.
--     Example: 40% loan volume, 25% deposit volume, 20% new account count,
--              15% customer visit activity.
--
--   Branch Scorecard    — aggregated portfolio metrics + team performance.
--     Example: 35% total loan volume, 30% total deposit growth,
--              20% customer NPS score, 15% cross-sell penetration rate.
--
--   Regional Scorecard  — strategic metrics plus risk and efficiency.
--     Example: 40% revenue growth, 25% cost-to-income ratio,
--              20% customer satisfaction index, 15% digital adoption rate.
--
-- HOW SCORECARD SCORES ARE CALCULATED
-- -------------------------------------
-- For each component in the scorecard:
--   1. Retrieve the latest realization achievement_pct for the entity and period.
--   2. Apply the weight: weighted_score = achievement_pct × weight.
--   3. Sum all weighted_scores → overall scorecard score.
--
-- Example for an employee scorecard:
--   Loan Volume:     achievement=90%  × weight=0.40 = 36.0 pts
--   Deposit Volume:  achievement=110% × weight=0.25 = 27.5 pts
--   New Accounts:    achievement=75%  × weight=0.20 = 15.0 pts
--   Customer Visits: achievement=120% × weight=0.15 = 18.0 pts
--   ─────────────────────────────────────────────────────────
--   Overall Score:                                  = 96.5 pts (of 100)
--
-- The scorecard overall score is then stored as a realization row against a
-- composite metric (e.g., 'EMPLOYEE_SCORE') so that scorecard history is
-- preserved using the same infrastructure as individual metrics.
--
-- WEIGHT CONSTRAINT
-- -----------------
-- Each component weight must be between 0 and 1 (exclusive), and the sum of
-- all weights for a scorecard must equal 1.0.  This is enforced at the
-- application layer (not DB-level) to keep the constraint practical when
-- weights are being updated incrementally.
--
-- PRODUCED BY  : Sales Ops / Finance admin UI (scorecard design and weight
--                assignment), typically done once per year per entity level
-- CONSUMED BY  : Account Planning API (scorecard widget in planner / manager
--                dashboard), Reporting (16) (scorecard league tables and
--                year-end performance reviews), AI Agent (12) (uses overall
--                scorecard score to prioritize coaching focus areas),
--                HR / Compensation systems (reads final period scorecard
--                score to calculate variable pay entitlements)
-- ============================================================================

CREATE TABLE IF NOT EXISTS perf.scorecard (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    target_level    VARCHAR(30) NOT NULL
                    CHECK (target_level IN ('company', 'lob', 'region', 'area', 'branch', 'team', 'employee')),
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Example rows:
--   (name='Branch Manager Scorecard 2025', target_level='branch', is_active=true)
--   (name='Relationship Manager Scorecard 2025', target_level='employee', is_active=true)
--   (name='Region Director Scorecard 2025', target_level='region', is_active=true)

COMMENT ON TABLE perf.scorecard IS 'Weighted composite scorecards aggregating multiple metrics into a single overall score for a given organizational level.';


-- ----------------------------------------------------------------------------
-- Scorecard Components — the individual metric "slots" within a scorecard,
-- each carrying a weight that determines its contribution to the total score.
--
-- Design note: scorecard_name is denormalized here (duplicating
-- perf.scorecard.name) to make reporting queries self-contained without an
-- extra join.  The application must keep these in sync when a scorecard is
-- renamed.
--
-- Weight rules (app-enforced):
--   • Each weight must be > 0 and ≤ 1.
--   • The sum of all weights for a scorecard should equal exactly 1.0.
--   • A scorecard must have at least one component to be usable.
--
-- Example components for "Branch Manager Scorecard 2025" (weights sum to 1.0):
--   metric=LOAN_VOL_TRY,        weight=0.35, display_order=1
--   metric=DEPOSIT_GROWTH,      weight=0.30, display_order=2
--   metric=CUSTOMER_NPS,        weight=0.20, display_order=3
--   metric=CROSS_SELL_RATE,     weight=0.15, display_order=4
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS perf.scorecard_component (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    scorecard_id    UUID NOT NULL REFERENCES perf.scorecard(id),
    scorecard_name  VARCHAR(255) NOT NULL,
    metric_id       UUID NOT NULL REFERENCES perf.metric_definition(id),
    weight          DECIMAL(5,4) NOT NULL
                    CHECK (weight > 0 AND weight <= 1),
    display_order   INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (scorecard_id, metric_id)
);

-- Example rows (for Branch Manager Scorecard 2025):
--   (scorecard_id=<branch-mgr-scorecard>, metric_id=<LOAN_VOL_TRY>,
--     weight=0.3500, display_order=1)
--   (scorecard_id=<branch-mgr-scorecard>, metric_id=<DEPOSIT_GROWTH>,
--     weight=0.3000, display_order=2)
--   (scorecard_id=<branch-mgr-scorecard>, metric_id=<CUSTOMER_NPS>,
--     weight=0.2000, display_order=3)
--   (scorecard_id=<branch-mgr-scorecard>, metric_id=<CROSS_SELL_RATE>,
--     weight=0.1500, display_order=4)
--   -- weights sum: 0.35 + 0.30 + 0.20 + 0.15 = 1.00 ✓

COMMENT ON TABLE perf.scorecard_component IS 'Individual metric components within a scorecard with weights. Weights should sum to 1.0 per scorecard (app-enforced).';
COMMENT ON COLUMN perf.scorecard_component.weight IS 'Contribution weight of this metric to the overall scorecard score (0 < weight ≤ 1). All weights per scorecard must sum to 1.0.';
COMMENT ON COLUMN perf.scorecard_component.display_order IS 'Controls rendering order in the scorecard UI widget; lower values appear first.';
