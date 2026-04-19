# Account Planning Database Design v0

## 00_system

## 01_repo

## 02_core

### 02.1 tenant

### 02.2 identity

### 02.3 organization

#### How `core.org_unit_closure` Works

The closure table stores **every ancestor-descendant relationship** in the hierarchy, not just direct parent-child links. This is the key insight.

**The Structure**

Given a hierarchy like this:

```
Bank A (company)
└── Retail Banking (lob)
    └── Marmara Region (region)
        ├── Istanbul Branch (branch)
        │   ├── Team Alpha (team)
        │   └── Team Beta (team)
        └── Bursa Branch (branch)
```

The `org_unit` table stores only the **nodes** (each unit once). The `org_unit_closure` table stores **every reachable path**:

| ancestor_id | descendant_id | depth |
|---|---|---|
| Bank A | Bank A | 0 ← self |
| Bank A | Retail Banking | 1 |
| Bank A | Marmara Region | 2 |
| Bank A | Istanbul Branch | 3 |
| Bank A | Team Alpha | 4 |
| Bank A | Team Beta | 4 |
| Bank A | Bursa Branch | 3 |
| Retail Banking | Retail Banking | 0 ← self |
| Retail Banking | Marmara Region | 1 |
| Retail Banking | Istanbul Branch | 2 |
| Retail Banking | Team Alpha | 3 |
| ... | ... | ... |
| Istanbul Branch | Istanbul Branch | 0 ← self |
| Istanbul Branch | Team Alpha | 1 |
| Istanbul Branch | Team Beta | 1 |
| Team Alpha | Team Alpha | 0 ← self |

Every node has a self-reference at `depth = 0`.

---

#### Query Patterns in This System

##### 1. Get all org units under "Marmara Region" (for dashboards, metric roll-ups)
```sql
SELECT ou.*
FROM core.org_unit ou
JOIN core.org_unit_closure c ON c.descendant_id = ou.id
WHERE c.ancestor_id = '<marmara-region-uuid>'
  AND c.tenant_id = core.current_tenant_id()
  AND c.depth > 0;  -- exclude self
```
**Use case:** Show a regional manager all their branches and teams in one query.

---

##### 2. Get all ancestors of "Team Alpha" (breadcrumb / hierarchy path)
```sql
SELECT ou.*, c.depth
FROM core.org_unit ou
JOIN core.org_unit_closure c ON c.ancestor_id = ou.id
WHERE c.descendant_id = '<team-alpha-uuid>'
  AND c.tenant_id = core.current_tenant_id()
ORDER BY c.depth DESC;  -- Company → LOB → Region → Branch → Team
```
**Use case:** Build breadcrumb navigation, or determine which region/LOB a team belongs to without recursive traversal.

---

##### 3. Get all employees under Marmara Region (for performance metric roll-up)
```sql
SELECT DISTINCT e.*
FROM core.employee e
JOIN core.employee_org_assignment eoa ON eoa.employee_id = e.id
JOIN core.org_unit_closure c ON c.descendant_id = eoa.org_unit_id
WHERE c.ancestor_id = '<marmara-region-uuid>'
  AND c.tenant_id = core.current_tenant_id()
  AND eoa.effective_until IS NULL;
```
**Use case:** Aggregate all reps' performance targets under a regional manager — no matter how deep the hierarchy.

---

##### 4. Aggregate a performance target up to branch level
```sql
SELECT SUM(r.actual_value)
FROM perf.realization r
JOIN perf.target t ON t.id = r.target_id
JOIN core.employee_org_assignment eoa ON eoa.employee_id::text = t.target_entity_id::text
JOIN core.org_unit_closure c ON c.descendant_id = eoa.org_unit_id
WHERE c.ancestor_id = '<istanbul-branch-uuid>'
  AND t.metric_id = '<revenue-metric-uuid>'
  AND r.snapshot_date = CURRENT_DATE;
```
**Use case:** Calculate branch-level actual revenue by summing all employee realizations beneath it.

---

##### 5. Check if unit A is a descendant of unit B (for ABAC policy evaluation)
```sql
SELECT EXISTS (
    SELECT 1 FROM core.org_unit_closure
    WHERE ancestor_id = '<region-uuid>'
      AND descendant_id = '<team-uuid>'
      AND tenant_id = core.current_tenant_id()
);
```
**Use case:** ABAC policy check — "can this regional manager access this team's data?"

---

#### Maintenance: Keeping the Closure Table in Sync

When a new `org_unit` is inserted, the closure rows must be created by the application or a trigger:

```sql
-- When "New Branch" is added under "Marmara Region":
INSERT INTO core.org_unit_closure (ancestor_id, descendant_id, depth, tenant_id)
-- 1. Self-reference
SELECT '<new-branch-uuid>', '<new-branch-uuid>', 0, '<tenant-uuid>'
UNION ALL
-- 2. All ancestors of the parent + this new node
SELECT c.ancestor_id, '<new-branch-uuid>', c.depth + 1, '<tenant-uuid>'
FROM core.org_unit_closure c
WHERE c.descendant_id = '<marmara-region-uuid>';  -- parent's ancestors
```

When a node is **moved** (parent changes), all descendant closure rows must be deleted and reinserted — this is the only expensive write operation, but org restructuring is rare.

---

#### Why Not a Recursive CTE Instead?

You could do `WITH RECURSIVE` in PostgreSQL without the closure table:

```sql
-- Would work, but: slower at runtime, no index benefit
WITH RECURSIVE tree AS (
    SELECT id FROM core.org_unit WHERE id = '<marmara-uuid>'
    UNION ALL
    SELECT o.id FROM core.org_unit o JOIN tree t ON o.parent_id = t.id
)
SELECT * FROM tree;
```

| | Closure Table | Recursive CTE |
|---|---|---|
| **Read speed** | O(1) — single join | O(n) — traverses tree at runtime |
| **Indexable** | ✅ Yes | ❌ No index on recursion |
| **Write complexity** | More complex | None |
| **Best for** | Frequent reads (dashboards, metric rollups) | Rare reads on small hierarchies |

Given that your system does **constant metric aggregations, ABAC checks, and employee lookups across org levels**, the closure table is the right choice here.





## 03_product

### 03.1 product_category

### 03.2 product

#### 03.2.1 product categories

#### 03.2.2 products

Edited 02_core.sql
Edited README_v0.md

##### Lifecycle Structure in `product.product`

The lifecycle is **optional per product**, controlled by two columns working together:

```sql
has_lifecycle           BOOLEAN NOT NULL DEFAULT false,
lifecycle_status        VARCHAR(30)
                        CHECK (lifecycle_status IN ('draft', 'active', 'discontinued', 'sunset')),
lifecycle_effective_date DATE,
```

Plus a constraint that enforces their relationship:
```sql
CONSTRAINT chk_product_lifecycle CHECK (
    (has_lifecycle = false AND lifecycle_status IS NULL) OR
    (has_lifecycle = true  AND lifecycle_status IS NOT NULL)
)
```

---

###### Why Optional?

From your README: *"Some products have lifecycle statuses, not all of them necessarily."*

Some products are simply always available — they don't go through phases. Others (especially in banking or telco) have formal stages tracked for regulatory, product management, or AI recommendation purposes.

| `has_lifecycle` | `lifecycle_status` | Meaning |
|---|---|---|
| `false` | `NULL` | Product exists, no lifecycle tracking needed |
| `true` | `draft` | Being defined, not yet available to customers |
| `true` | `active` | Actively sold and supported |
| `true` | `discontinued` | No new sales, existing customers still served |
| `true` | `sunset` | Fully retired, no active customers expected |

---

###### Industry Examples

**Banking — "Revolving Loan"** → `has_lifecycle = true`
```
draft → active → discontinued → sunset
```
- Central Bank changes regulations → product enters `discontinued`
- AI recommendation engine **stops suggesting** discontinued products
- Existing `customer_product` records remain valid (they're linked to `product_version`)

**Banking — "Processing Fee Rate"** → `has_lifecycle = false`
```
No lifecycle needed — it's a parameter, not a product stage
```

**Telco — "Postpaid 50GB Plan"** → `has_lifecycle = true`
```
draft → active → discontinued (new plan replaces it) → sunset
```

---

###### How `lifecycle_effective_date` Works

This is **when the current status took effect**, not a transition schedule. It gives you a simple "status since" timestamp:

```sql
-- Products that were discontinued in the last 90 days
SELECT *
FROM product.product
WHERE tenant_id = core.current_tenant_id()
  AND has_lifecycle = true
  AND lifecycle_status = 'discontinued'
  AND lifecycle_effective_date >= CURRENT_DATE - INTERVAL '90 days';
```

> [!NOTE]
> This design does **not** store full status transition history in this table. If you later need the full history (e.g., `draft → active on date X, discontinued on date Y`), that would fit naturally in a future `product_lifecycle_event` table. The `product_version` table partially handles this by capturing when specs/terms change.

---

###### How It Interacts with the Rest of the Schema

```
product.product  (has_lifecycle=true, lifecycle_status='discontinued')
    │
    ├── product.product_version        — historical versions still referenced by customer_product
    │
    ├── customer.customer_product      — existing holdings still valid, status stays 'active'
    │
    ├── analytics.model                — AI recommendation model can filter by lifecycle_status
    │
    └── action.action_type             — cross-sell/upsell actions should not trigger for
                                         'discontinued' or 'sunset' products (app-layer rule)
```

###### Query: Active Products Available for AI Recommendations

```sql
SELECT p.*, c.name AS category_name
FROM product.product p
JOIN product.category c ON c.id = p.category_id
WHERE p.tenant_id = core.current_tenant_id()
  AND p.is_active = true
  AND (p.has_lifecycle = false OR p.lifecycle_status = 'active');
```

This is the standard filter the AI recommendation engine would use — it excludes products with no lifecycle flag or lifecycle-tracked products that are past `active`.

---

###### `is_active` vs `lifecycle_status`

These are intentionally separate:

| | `is_active = false` | `lifecycle_status = 'discontinued'` |
|---|---|---|
| **Meaning** | Hard off — product should not be visible anywhere | Soft phase-out — no new sales, still visible for existing customers |
| **Used for** | Temporary suspension, data clean-up | Formal product lifecycle management |
| **AI behavior** | Completely excluded | Can still appear in customer history/context |

## 04_customer

### 04.9 Data Retention

#### What is data_retention_policy?

It's a configuration table — not a data table. It doesn't store customer data itself; it defines rules that tell your automated background jobs:

"For this tenant and this category of data, how long should we keep it, and what should we do when it expires?"

This is essential for KVKK / GDPR compliance (e.g., KVKK requires you don't hold PII longer than necessary).

#### The Table Structure
sql
CREATE TABLE IF NOT EXISTS customer.data_retention_policy (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID,          -- which bank/tenant owns this rule
    data_category           VARCHAR(100),  -- WHAT kind of data
    retention_period_days   INTEGER,       -- HOW LONG to keep it
    action_on_expiry        VARCHAR(30),   -- WHAT to do when it expires
    legal_basis             VARCHAR(100),  -- WHY you're keeping it (KVKK Art.)
    is_active               BOOLEAN,
    created_at / updated_at TIMESTAMPTZ
);
UNIQUE constraint: (tenant_id, data_category) → each tenant can only have one rule per data category.

#### Concrete Row Examples
data_category	retention_period_days	action_on_expiry	legal_basis	Real-world meaning
pii_contact	365	anonymize	KVKK Art. 5/2(c)	Contact details (email, phone) → anonymized after 1 year of inactivity
transaction_history	2555	archive	KVKK Art. 5/2(a)	~7 years, matches Banking Law requirement → moved to cold archive
marketing_consent	730	delete	KVKK Art. 5/1	Explicit consent expires → hard deleted after 2 years
audit_logs	3650	archive	KVKK Art. 12	10-year audit trail for regulators
ai_agent_memory	90	delete	Legitimate interest	Short-lived AI reasoning context → purged quarterly

#### How It Works End-to-End
data_retention_policy        customer.customer            customer.consent
(rule config table)    ────▶  (anonymized_at field)  ────▶ (status = 'expired')
                              (deleted_at field)
         │
         ▼
  Scheduled Background Job (pg_cron / Celery)
         │
         ├─ anonymize → NULL out PII columns, set anonymized_at = now()
         ├─ delete    → SET deleted_at = now() (soft delete) or hard DELETE
         └─ archive   → INSERT INTO archive schema, then DELETE from live
The automated job (cron-based) reads this table and applies the rule to matching rows in customer.customer, customer.consent, etc.

#### Key Design Decisions in Your Schema
1. Per-tenant — Bank A can keep transaction data 7 years, Bank B only 5 years. Each tenant configures their own rules.
2. action_on_expiry is a constrained enum — anonymize, delete, archive. Not free text — enforces only legal/safe operations.
3. legal_basis column — Documents why (e.g., KVKK Art. 5/2(c)) so you can prove compliance in audits.
4. is_active flag — Policies can be disabled without being deleted (e.g., during a legal hold).
5. RLS enforced (17_rls_policies.sql line 127) — Tenants can only see their own retention rules.

**In short**: data_retention_policy is the compliance control knob. It doesn't touch data itself — it's the rulebook that your cleanup jobs follow to enforce KVKK/GDPR automatically.

## 05_performance

### 05.1 Metric Definition

#### What is code and why does it exist?
sql
code  VARCHAR(100) NOT NULL,
UNIQUE (tenant_id, code)

code is a human-readable, stable machine identifier for a metric — as opposed to the UUID id which is opaque.

Think of it as the "business key" — a short slug that your systems, ETL pipelines, and integrations use to refer to a metric by name rather than by UUID.

##### Why is it needed?

UUIDs change across environments (dev → staging → prod). code stays the same.
It's what you map incoming data against during migration/ETL.
It's how the AI agent or reporting layer can reference metrics symbolically (e.g. "NET_REVENUE_MONTHLY").
The UNIQUE(tenant_id, code) constraint guarantees no duplicate metric names per tenant.

**Example codes:**

code	name
NET_REVENUE_MONTHLY	Monthly Net Revenue
ACTIVE_CUSTOMER_COUNT	Active Customer Count
PRODUCT_NPS	Product Net Promoter Score
CROSS_SELL_RATIO	Cross-sell Ratio
CHURN_RATE_QTR	Quarterly Churn Rate

##### Example metric_definition Rows
Here are realistic examples that map directly to company metrics:

sql
-- Revenue metric (from core system, summed monthly)
INSERT INTO perf.metric_definition (tenant_id, code, name, category, unit, data_type, aggregation_method, source)
VALUES (:tid, 'NET_REVENUE_MONTHLY', 'Monthly Net Premium Written', 'revenue', 'TRY', 'decimal', 'sum', 'core_system');
-- Count metric (active policies)
INSERT INTO perf.metric_definition (tenant_id, code, name, category, unit, data_type, aggregation_method, source)
VALUES (:tid, 'ACTIVE_POLICY_COUNT', 'Active Policy Count', 'count', 'count', 'integer', 'sum', 'core_system');
-- Ratio metric (retention %, calculated)
INSERT INTO perf.metric_definition (tenant_id, code, name, category, unit, data_type, aggregation_method, source)
VALUES (:tid, 'RETENTION_RATE', 'Customer Retention Rate', 'ratio', '%', 'percentage', 'avg', 'calculated');
-- Composite: Weighted scorecard score
INSERT INTO perf.metric_definition (tenant_id, code, name, category, unit, data_type, aggregation_method, is_composite, composite_formula, source)
VALUES (:tid, 'BRANCH_SCORE', 'Branch Performance Score', 'score', 'score', 'decimal', 'weighted_avg', true,
  '{"components": [
      {"metric_id": "<revenue-uuid>", "weight": 0.5},
      {"metric_id": "<retention-uuid>", "weight": 0.3},
      {"metric_id": "<nps-uuid>", "weight": 0.2}
  ]}', 'calculated');


##### How Company Metrics Are Migrated Here
The migration is a one-time seeding step, typically part of your ETL/onboarding process:

[Core System / Data Warehouse]
        ↓  (metric catalog export)
[Seed Script / ETL]
        ↓  INSERT INTO perf.metric_definition (code, name, ...)
[perf.metric_definition]
        ↓  (metric_id FK)
[perf.target]  ←── "This branch's NET_REVENUE_MONTHLY target is 5M TRY for Q2"
        ↓  (target_id FK)
[perf.realization] ←── "Actual Q2 achievement: 4.8M TRY"

##### Concretely:

- Export your existing company metric catalog (e.g. from Excel, BI tool, or a legacy DB) — every KPI name, unit, and aggregation type.
- Map each to a code + category + aggregation_method.
- Seed perf.metric_definition once per tenant at onboarding time.
- All future targets and realizations reference these definitions via metric_id FK — keeping historical data consistent even if the metric's name or description changes.

**Key insight:** metric_definition is your catalog/registry of what can be measured. It doesn't store values — perf.target stores the goal, and perf.realization stores the actual. The code field is the stable external key that ties everything together across systems.

## 06_analytics

## 07_action

## 08_content

## 09_audit

## 10_config

## 11_integration

## 12_agent

## 13_notification

## 14_document

## 15_i18n

## 16_reporting

## 17_rls_policies

## 18_indexes

## 99_final_thoughts

