# User:
In customer.sql file, can 4.5 customer product metrics and 4.6 transactions handle periodic reporting such as Year-over-Year or Year-to-Date time frames, or monthly trends for reporting? Or do we need to add a reporting term in order to make the reporting easier?

# Agent:
Great analysis target. Here's my assessment:

## Can 4.5 & 4.6 Handle Periodic Reporting Today?
### 4.5 customer_product_metric — Partially Yes
Reporting Need	Current Support	Gap
Monthly trends	✅ Yes — period_start / period_end let you filter/group by month	No period_type column to explicitly tag the grain (monthly vs quarterly)
YTD	✅ Yes — query WHERE period_start >= date_trunc('year', now())	No native shortcut; relies on ad-hoc SQL
YoY	✅ Yes — compare date_part('year', period_start) across rows	No prior-period reference column; requires self-joins or window functions
Snapshot vs. running total	❌ No	No is_snapshot or aggregation_type indicator
The main gap: period_start/period_end are flexible, but there's nothing explicitly declaring the granularity of a row (is it a monthly snapshot or a YTD cumulative?). This forces consumers to infer it from the date range width.

### 4.6 customer_transaction — Weaker
Reporting Need	Current Support	Gap
Monthly trends	✅ Partial — period_type IN ('daily','weekly','monthly') helps	No period_start date; transaction_date alone is ambiguous for aggregated rows
YTD / YoY	⚠️ Requires manual SQL grouping on transaction_date	No period_year, period_month, or fiscal_period columns
Quarterly / Annual	❌ No — period_type only supports daily/weekly/monthly	Missing 'quarterly' and 'annual' in the CHECK constraint
Comparing periods	❌ No	No prior-period amount for precomputed deltas
The main gap: period_type = 'monthly' tells you the grain, but transaction_date for an aggregated row is ambiguous (is it the first day of the month? last day?). Without a period_start + period_end pair (like 4.5 has), reconstructing the exact period in queries is fragile.

### My Recommendation
You have two options — one lightweight, one more robust:

#### Option A — Lightweight: Minimal Additions
Add just a period_type column to 4.5 and a period_start/period_end pair to 4.6, and extend the CHECK constraint in 4.6 to include 'quarterly' and 'annual'. No new table needed.

#### Option B — Robust: Add a reporting_period Dimension Table
Add a shared dimension table (e.g., core.reporting_period) that your metrics and transactions both FK into:

sql
CREATE TABLE core.reporting_period (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    period_label    VARCHAR(50) NOT NULL,    -- e.g. '2025-Q1', '2025-03', '2025'
    period_type     VARCHAR(20) NOT NULL
                    CHECK (period_type IN ('daily','weekly','monthly','quarterly','annual','ytd','fiscal_year')),
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    fiscal_year     INTEGER NOT NULL,
    fiscal_quarter  SMALLINT CHECK (fiscal_quarter BETWEEN 1 AND 4),
    calendar_year   INTEGER NOT NULL,
    calendar_month  SMALLINT CHECK (calendar_month BETWEEN 1 AND 12),
    is_current      BOOLEAN NOT NULL DEFAULT false,
    UNIQUE (tenant_id, period_type, period_start)
);
Then both 4.5 and 4.6 get a reporting_period_id UUID REFERENCES core.reporting_period(id). This gives you:

✅ YoY: join to period_type = 'annual'
✅ YTD: join to period_type = 'ytd'
✅ Monthly trends: join to period_type = 'monthly'
✅ Fiscal vs. calendar year alignment out of the box
✅ No ad-hoc date math in queries

### My suggestion: 
Go with Option B if you anticipate multiple report consumers (BI tools, AI agent, dashboards). The reporting_period dimension is a one-time investment that makes all future reporting simpler and avoids repeated date-arithmetic bugs.

Want me to implement Option B and update both 4.5 and 4.6 accordingly?

# User:
option B sound better, but we should add a human readable name to each period and add it to the fact tables also to increase human readability, other way analists should always need to join the dim table. Another question, this way uniqueness of 4.5 or 4.6 tables will be over customer + product_id/trx_id + reporting_period_id, correct?

# Agent:
Good instincts on both points. Let me confirm the design before implementing.

Answers
On human-readable denormalization ✅ Correct approach
The pattern is called a degenerate dimension — you keep the FK for referential integrity and proper joins, but you also denormalize the most-queried human-readable fields directly into the fact table. For our case, two columns suffice:

Denormalized column	Example value	Why
period_label	'2025-03', '2025-Q1', '2025-YTD'	Readable, sortable, no join needed
period_type	'monthly', 'quarterly', 'ytd'	Analysts can filter by grain without joining
These should be kept in sync with the dim row (either via an app-layer rule or a trigger). Since reporting_period rows are inserted once and never mutated, drift risk is very low.

On uniqueness ✅ Correct
Table	Proposed Unique Constraint
4.5 customer_product_metric	(tenant_id, customer_product_id, metric_code, reporting_period_id) — one value per product-metric per period
4.6 customer_transaction	(tenant_id, customer_id, transaction_type, product_id, reporting_period_id) — one aggregated row per customer × tx_type × product × period
⚠️ One nuance for 4.6: product_id is nullable today (channel-level aggregations with no specific product). The unique constraint needs to account for NULLs — PostgreSQL treats two NULLs as non-equal in unique constraints, so we'd want a partial index or use COALESCE(product_id, uuid_nil()) as the strategy. I'll handle this.

Plan
Files to change:

02_core.sql — Add core.reporting_period dimension table
04_customer.sql — Modify 4.5 and 4.6:
Add reporting_period_id FK
Add denormalized period_label + period_type
Add proper UNIQUE constraints (with null-safe handling for 4.6)
Extend 4.6's period_type CHECK to include quarterly and annual
Shall I proceed?

# User:
yes, proceed please

# Agent:
All changes are in. Here's a summary of everything done:

## What Changed
### 02_core.sql — New: Section 2.9 core.reporting_period
Column	Purpose
period_label	Short machine-friendly label (e.g. '2025-03', '2025-Q1') — also denormalized into fact rows
period_name	Full human-readable name (e.g. 'March 2025', 'Q1 2025', 'YTD January–March 2025')
period_type	Grain: daily, weekly, monthly, quarterly, annual, ytd, fiscal_year
calendar_year/month/quarter	Pre-computed calendar fields — no date-math in queries
fiscal_year/quarter	Tenant-specific fiscal alignment
is_current / is_closed	ETL lifecycle flags
UNIQUE	(tenant_id, period_type, period_label)


## 04_customer.sql — Section 4.5 customer_product_metric
Added reporting_period_id FK
Added denormalized period_label + period_type
Kept period_start/period_end for direct range queries (backward compat)
New UNIQUE constraint: (tenant_id, customer_product_id, metric_code, reporting_period_id)

## 04_customer.sql — Section 4.6 customer_transaction
Added reporting_period_id FK
Added denormalized period_label + period_type
Extended CHECK to include quarterly, annual, ytd, fiscal_year
Uniqueness via two partial indexes (instead of a single UNIQUE constraint) to handle nullable product_id correctly:
uq_ctxn_with_product — when product_id IS NOT NULL
uq_ctxn_no_product — when product_id IS NULL
