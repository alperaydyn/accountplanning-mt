# Account Planning — Iterative DB Generation Plan

## Philosophy

Each phase produces a **self-contained, queryable database state** with seed data. After each phase you can:
1. Connect a dummy frontend (pgAdmin, DBeaver, or a simple web UI) to verify the data.
2. Run the provided **validation queries** to confirm correctness.
3. Approve the phase before moving to the next.

Phases are ordered by **dependency** — each phase only creates tables whose foreign keys are already satisfied by earlier phases.

---

## Prerequisites

- PostgreSQL 16+ instance running and accessible.
- A superuser or database owner role for DDL operations.
- Two databases created: `account_planning` (main) and `account_planning_repo` (repo).

```sql
CREATE DATABASE account_planning;
CREATE DATABASE account_planning_repo;
```

---

## Phase Overview

| Phase | Name | Files | Tables Added | Seed Data | What You Can Verify |
|-------|------|-------|-------------|-----------|---------------------|
| **1** | Foundation | `00`, `01`, `02` | Extensions, 16 schemas, 3 repo tables, 10 core tables | 1 tenant, org hierarchy (7 levels), users, employees, reporting periods | Tenant exists, org tree is navigable, closure table returns correct descendants |
| **2** | Product Catalog | `03` | 4 product tables | Category tree (3 levels), 8 products, versions, relationships | Product picker works, closure queries return correct category subtrees |
| **3** | Customer & Compliance | `04` | 9 customer tables | 10 customers (mixed types), segments, product holdings, assignments, consents, C360 cache | Customer 360 view renders, product holdings visible, consent checks pass |
| **4** | Performance & Targets | `05` | 5 perf tables | 5 metric definitions, targets at 3 levels, realization snapshots, 1 scorecard | Target vs. actual widgets work, scorecard calculation verifiable |
| **5** | Analytics & AI Scores | `06` | 3 analytics tables + partitions | 1 model, 50 scores, 10 explanations | Score lookup by customer works, SHAP explanations render |
| **6** | Action Engine | `07` | 8 action tables + partitions | Status definitions, 4 action types with DAG, 15 action instances, recurrence rule, escalation rules | Action workflow DAG navigable, overdue detection query works |
| **7** | Content & Briefings | `08` | 6 content tables | 2 templates, 3 briefings, read tracking, feedback | Briefing card renders, read/unread tracking visible |
| **8** | Audit & Compliance Logs | `09` | 3 audit tables + partitions | 20 audit log entries, 5 AI reasoning logs, 5 data access logs | Audit trail queryable by resource, AI explainability chain visible |
| **9** | Config & Feature Flags | `10` | 4 config tables | 1 change request with 2 approvals, 3 feature flags, 2 config versions | Feature flag check works, change request approval flow visible |
| **10** | Integration & Events | `11` | 5 integration tables + partitions | 1 data source, 2 sync jobs, 1 webhook, 3 events | Sync job history visible, event replay by aggregate works |
| **11** | Agent & AI Memory | `12` | 6 agent tables | 2 conversations with messages, short/long-term memories, preferences, 2 prompt templates | Conversation transcript renders, memory retrieval by entity works |
| **12** | Notifications | `13` | 4 notification tables | 1 channel, 2 templates, 5 notifications, user preferences | Notification inbox renders, preference filtering works |
| **13** | Documents | `14` | 4 document tables | 3 documents, versions, links to customer/action, access logs | Document list by entity works, access audit visible |
| **14** | Internationalization | `15` | 3 i18n tables | 2 languages, 20 translations, user preference | Translation lookup by locale/namespace works |
| **15** | Reporting Layer | `16` | 4 reporting tables | 2 report definitions, 1 MV registry entry, 2 snapshots, 3 access logs | Report snapshot served, access analytics queryable |
| **16** | Security Hardening | `17`, `18` | RLS policies + indexes | — (policies and indexes only) | RLS isolation test: set tenant A → data from tenant B invisible. Index usage confirmed via `EXPLAIN` |

---

## Phase 1: Foundation (Extensions, Repo, Core)

### Files to Execute
1. **`00_extensions_and_schemas.sql`** → on `account_planning` database
2. **`01_repo.sql`** → on `account_planning_repo` database
3. **`02_core.sql`** → on `account_planning` database

### What Gets Created

| Schema | Tables | Purpose |
|--------|--------|---------|
| *(16 schemas)* | — | Logical namespaces for all modules |
| `repo` | `app_setting`, `module_registry`, `migration_log` | Non-tenant application config |
| `core` | `tenant`, `tenant_module`, `user_`, `sso_config`, `abac_policy`, `delegation`, `impersonation_log`, `org_unit`, `org_unit_closure`, `employee`, `employee_org_assignment`, `reporting_period` | Multi-tenancy, IAM, org hierarchy |

### Seed Data Script

```sql
-- ============================================================
-- PHASE 1 SEED: Foundation
-- ============================================================

-- 1.1 Create the demo tenant
INSERT INTO core.tenant (id, code, name, domain, subscription_plan, kvkk_gdpr_config)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'DEMO_BANK',
    'Demo Bank A.Ş.',
    'demobank.com',
    'enterprise',
    '{"data_protection_officer": "dpo@demobank.com", "jurisdiction": "TR", "encryption_at_rest": true}'
);

-- 1.2 Enable modules for the tenant
INSERT INTO core.tenant_module (tenant_id, module_name, is_enabled, config) VALUES
('a0000000-0000-0000-0000-000000000001', 'core',          true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'product',       true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'customer',      true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'perf',          true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'analytics',     true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'action',        true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'content',       true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'audit',         true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'config',        true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'integration',   true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'agent',         true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'notification',  true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'document',      true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'i18n',          true, '{}'),
('a0000000-0000-0000-0000-000000000001', 'reporting',     true, '{}');

-- 1.3 Create users (system account + 5 employees)
INSERT INTO core.user_ (id, tenant_id, username, email, full_name, identity_provider, external_id, user_type) VALUES
('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'system',       'system@demobank.com',       'System Account',    'local', 'system',      'service_account'),
('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'ahmet.yilmaz', 'ahmet.yilmaz@demobank.com', 'Ahmet Yılmaz',      'local', 'ahmet.yilmaz','internal'),
('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'ayse.demir',   'ayse.demir@demobank.com',   'Ayşe Demir',        'local', 'ayse.demir',  'internal'),
('b0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'mehmet.kaya',  'mehmet.kaya@demobank.com',  'Mehmet Kaya',       'local', 'mehmet.kaya', 'internal'),
('b0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'fatma.ozkan',  'fatma.ozkan@demobank.com',  'Fatma Özkan',       'local', 'fatma.ozkan', 'internal'),
('b0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'ali.celik',    'ali.celik@demobank.com',    'Ali Çelik',         'local', 'ali.celik',   'internal');

-- 1.4 Build org hierarchy (7 levels)
--   Company → LOB → Region → Area → Branch → Team
INSERT INTO core.org_unit (id, tenant_id, parent_id, code, name, unit_type, level) VALUES
-- Level 0: Company
('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', NULL,
    'DEMO_BANK', 'Demo Bank A.Ş.', 'company', 0),
-- Level 1: Lines of Business
('c0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
    'RETAIL', 'Retail Banking', 'lob', 1),
('c0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
    'CORPORATE', 'Corporate Banking', 'lob', 1),
-- Level 2: Region
('c0000000-0000-0000-0000-000000000020', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000010',
    'MARMARA', 'Marmara Region', 'region', 2),
-- Level 3: Area
('c0000000-0000-0000-0000-000000000030', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000020',
    'IST_EUROPE', 'Istanbul European Side', 'area', 3),
-- Level 4: Branch
('c0000000-0000-0000-0000-000000000040', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000030',
    'LEVENT', 'Istanbul Levent Branch', 'branch', 4),
-- Level 5: Team
('c0000000-0000-0000-0000-000000000050', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000040',
    'LEVENT_TEAM_A', 'Levent Team A', 'team', 5);

-- 1.5 Populate closure table (every ancestor-descendant pair including self)
INSERT INTO core.org_unit_closure (ancestor_id, descendant_id, depth, tenant_id) VALUES
-- Self-references (depth 0)
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000010', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000011', 'c0000000-0000-0000-0000-000000000011', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000020', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000030', 'c0000000-0000-0000-0000-000000000030', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000040', 'c0000000-0000-0000-0000-000000000040', 0, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000050', 'c0000000-0000-0000-0000-000000000050', 0, 'a0000000-0000-0000-0000-000000000001'),
-- Company → all descendants
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000010', 1, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000011', 1, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000020', 2, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000030', 3, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000040', 4, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000050', 5, 'a0000000-0000-0000-0000-000000000001'),
-- Retail → descendants
('c0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000020', 1, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000030', 2, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000040', 3, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000050', 4, 'a0000000-0000-0000-0000-000000000001'),
-- Marmara → descendants
('c0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000030', 1, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000040', 2, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000050', 3, 'a0000000-0000-0000-0000-000000000001'),
-- Area → descendants
('c0000000-0000-0000-0000-000000000030', 'c0000000-0000-0000-0000-000000000040', 1, 'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000030', 'c0000000-0000-0000-0000-000000000050', 2, 'a0000000-0000-0000-0000-000000000001'),
-- Branch → Team
('c0000000-0000-0000-0000-000000000040', 'c0000000-0000-0000-0000-000000000050', 1, 'a0000000-0000-0000-0000-000000000001');

-- 1.6 Create employees and assign to org units
INSERT INTO core.employee (id, tenant_id, user_id, employee_code, title, department, is_active) VALUES
('d0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'EMP001', 'Regional Director',     'Retail Banking', true),
('d0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'EMP002', 'Branch Manager',        'Levent Branch',  true),
('d0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000004', 'EMP003', 'Senior RM',             'Levent Team A',  true),
('d0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000005', 'EMP004', 'Relationship Manager',  'Levent Team A',  true),
('d0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000006', 'EMP005', 'Junior RM',             'Levent Team A',  true);

INSERT INTO core.employee_org_assignment (tenant_id, employee_id, org_unit_id, assignment_type, is_primary, effective_from) VALUES
('a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000020', 'manager',  true, '2025-01-01'),
('a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000040', 'manager',  true, '2025-01-01'),
('a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000050', 'member',   true, '2025-01-01'),
('a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000050', 'member',   true, '2025-01-01'),
('a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000050', 'member',   true, '2025-06-01');

-- 1.7 Reporting periods (Q1 2025 + monthly)
INSERT INTO core.reporting_period (id, tenant_id, period_type, period_label, start_date, end_date, is_current) VALUES
('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'monthly',    '2025-01',   '2025-01-01', '2025-01-31', false),
('e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'monthly',    '2025-02',   '2025-02-01', '2025-02-28', false),
('e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'monthly',    '2025-03',   '2025-03-01', '2025-03-31', false),
('e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'quarterly',  '2025-Q1',   '2025-01-01', '2025-03-31', false),
('e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'monthly',    '2025-04',   '2025-04-01', '2025-04-30', true),
('e0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'quarterly',  '2025-Q2',   '2025-04-01', '2025-06-30', true);

-- Repo database seed (run on account_planning_repo)
-- INSERT INTO repo.app_setting (key, value, description) VALUES
--   ('db_version', '"0.1.0"', 'Current database schema version'),
--   ('platform_name', '"Account Planning"', 'Platform display name');
--
-- INSERT INTO repo.module_registry (module_name, display_name, description, is_core) VALUES
--   ('core', 'Core', 'Tenant, IAM, Org Hierarchy', true),
--   ('product', 'Product Catalog', 'Product categories, versions, relationships', true),
--   ('customer', 'Customer Management', 'KVKK/GDPR compliant customer data', true),
--   ('perf', 'Performance', 'Targets, realizations, scorecards', true),
--   ('analytics', 'Analytics', 'ML models, scores, explanations', false),
--   ('action', 'Action Engine', 'DAG-based action workflows', true),
--   ('agent', 'AI Agent', 'Conversations, memory, prompts', false);
```

### Validation Queries

```sql
-- ✅ V1.1: Tenant exists
SELECT id, code, name FROM core.tenant;
-- Expected: 1 row — DEMO_BANK

-- ✅ V1.2: Org hierarchy tree (adjacency)
SELECT level, code, name, unit_type FROM core.org_unit ORDER BY level, code;
-- Expected: 7 rows — company → lob(×2) → region → area → branch → team

-- ✅ V1.3: Closure table — "all units under Retail Banking"
SELECT d.code, d.name, d.unit_type, cc.depth
FROM core.org_unit_closure cc
JOIN core.org_unit d ON d.id = cc.descendant_id
WHERE cc.ancestor_id = 'c0000000-0000-0000-0000-000000000010'  -- RETAIL
  AND cc.depth > 0
ORDER BY cc.depth;
-- Expected: 4 rows — Marmara(1), IST_EUROPE(2), LEVENT(3), LEVENT_TEAM_A(4)

-- ✅ V1.4: Employees assigned to Levent Team A
SELECT e.employee_code, u.full_name, e.title
FROM core.employee e
JOIN core.user_ u ON u.id = e.user_id
JOIN core.employee_org_assignment eoa ON eoa.employee_id = e.id
WHERE eoa.org_unit_id = 'c0000000-0000-0000-0000-000000000050'
  AND eoa.effective_until IS NULL;
-- Expected: 3 rows — Mehmet (Senior RM), Fatma (RM), Ali (Junior RM)

-- ✅ V1.5: Reporting periods
SELECT period_type, period_label, start_date, end_date, is_current
FROM core.reporting_period ORDER BY start_date;
-- Expected: 6 rows
```

> [!TIP]
> **Checkpoint**: If all 5 queries return expected results, Phase 1 is complete. Approve to continue to Phase 2.

---

## Phase 2: Product Catalog

### Files to Execute
- **`03_product.sql`** → on `account_planning` database

### Seed Data Script

```sql
-- ============================================================
-- PHASE 2 SEED: Product Catalog
-- ============================================================

-- 2.1 Product categories (3-level tree)
INSERT INTO product.category (id, tenant_id, parent_id, code, name, level, display_order) VALUES
-- Level 0: Root
('f0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', NULL,
    'FINANCIAL', 'Financial Products', 0, 1),
-- Level 1
('f0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
    'LOANS', 'Loans', 1, 1),
('f0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
    'DEPOSITS', 'Deposits', 1, 2),
('f0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
    'CARDS', 'Credit Cards', 1, 3),
('f0000000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
    'INSURANCE', 'Insurance', 1, 4),
-- Level 2
('f0000000-0000-0000-0000-000000000020', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000010',
    'TL_CASH', 'TL Cash Loans', 2, 1),
('f0000000-0000-0000-0000-000000000021', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000010',
    'MORTGAGE', 'Mortgage Loans', 2, 2),
('f0000000-0000-0000-0000-000000000022', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000011',
    'TIME_DEPOSIT', 'Time Deposits', 2, 1),
('f0000000-0000-0000-0000-000000000023', 'a0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000011',
    'DEMAND_DEPOSIT', 'Demand Deposits', 2, 2);

-- 2.2 Category closure (all ancestor-descendant pairs)
INSERT INTO product.category_closure (ancestor_id, descendant_id, depth, tenant_id) VALUES
-- Self refs
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000010',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000011',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000012','f0000000-0000-0000-0000-000000000012',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000013','f0000000-0000-0000-0000-000000000013',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000020','f0000000-0000-0000-0000-000000000020',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000021','f0000000-0000-0000-0000-000000000021',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000022','f0000000-0000-0000-0000-000000000022',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000023','f0000000-0000-0000-0000-000000000023',0,'a0000000-0000-0000-0000-000000000001'),
-- FINANCIAL → level 1
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000010',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000011',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000013',1,'a0000000-0000-0000-0000-000000000001'),
-- FINANCIAL → level 2
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000021',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000022',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000023',2,'a0000000-0000-0000-0000-000000000001'),
-- LOANS → level 2
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000020',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000021',1,'a0000000-0000-0000-0000-000000000001'),
-- DEPOSITS → level 2
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000022',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000023',1,'a0000000-0000-0000-0000-000000000001');

-- 2.3 Products (8 products)
INSERT INTO product.product (id, tenant_id, category_id, code, name, description, specifications, has_lifecycle, lifecycle_status) VALUES
('10000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',
    'CASH_LOAN_STD', 'Standard Cash Loan', 'Standard TL cash loan for individuals',
    '{"max_tenor_months":60,"min_amount":5000,"max_amount":500000}', true, 'active'),
('10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',
    'CASH_LOAN_PREMIUM', 'Premium Cash Loan', 'Premium TL cash loan — lower rates for high-value customers',
    '{"max_tenor_months":84,"min_amount":50000,"max_amount":2000000}', true, 'active'),
('10000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000021',
    'MORTGAGE_FIXED', 'Fixed-Rate Mortgage', '15–30 year fixed-rate home loan',
    '{"max_tenor_years":30,"ltv_max_pct":80}', true, 'active'),
('10000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000022',
    'TIME_DEP_3M', '3-Month Time Deposit', 'Short-term TL time deposit',
    '{"tenor_months":3,"min_amount":10000}', true, 'active'),
('10000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000023',
    'DEMAND_DEP_TL', 'TL Demand Deposit', 'Standard TL current account',
    '{"min_balance":0}', true, 'active'),
('10000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',
    'CC_GOLD', 'Gold Credit Card', 'Gold tier credit card',
    '{"credit_limit_range":[5000,100000],"cashback_pct":0.5}', true, 'active'),
('10000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',
    'CC_PLATINUM', 'Platinum Credit Card', 'Platinum tier with lounge access',
    '{"credit_limit_range":[25000,500000],"cashback_pct":1.5,"lounge_access":true}', true, 'active'),
('10000000-0000-0000-0000-000000000008','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000013',
    'HOME_INSURANCE', 'Home Insurance', 'Property insurance for mortgage holders',
    '{"coverage_types":["fire","earthquake","flood"]}', true, 'active');

-- 2.4 Product versions (current versions)
INSERT INTO product.product_version (id, tenant_id, product_id, version_number, version_label, specifications, terms, is_current, effective_from, created_by) VALUES
('11000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
    1, '2025 Launch', '{"max_tenor_months":60}', '{"interest_rate_pct":2.89,"admin_fee_pct":1.0}', true, '2025-01-01', 'b0000000-0000-0000-0000-000000000001'),
('11000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006',
    1, '2025 Gold Launch', '{}', '{"annual_fee":250,"cashback_pct":0.5}', true, '2025-01-01', 'b0000000-0000-0000-0000-000000000001'),
('11000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000007',
    1, '2025 Platinum Launch', '{}', '{"annual_fee":0,"cashback_pct":1.5}', true, '2025-01-01', 'b0000000-0000-0000-0000-000000000001');

-- 2.5 Product relationships
INSERT INTO product.product_relationship (tenant_id, source_product_id, target_product_id, relationship_type, strength, metadata) VALUES
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000007',
    'upsell', 0.70, '{"upsell_threshold_monthly_spend":3000}'),
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000008',
    'complementary', 0.85, '{"trigger":"mortgage_originated"}'),
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000005',
    'prerequisite', 1.00, '{}');
```

### Validation Queries

```sql
-- ✅ V2.1: All products under "Loans" category (via closure table)
SELECT p.code, p.name, c.name as category_name
FROM product.product p
JOIN product.category c ON c.id = p.category_id
JOIN product.category_closure cc ON cc.descendant_id = c.id
WHERE cc.ancestor_id = 'f0000000-0000-0000-0000-000000000010'  -- LOANS
  AND cc.tenant_id = 'a0000000-0000-0000-0000-000000000001';
-- Expected: 3 rows — CASH_LOAN_STD, CASH_LOAN_PREMIUM, MORTGAGE_FIXED

-- ✅ V2.2: Current product version for Gold Card
SELECT p.name, pv.version_label, pv.terms
FROM product.product_version pv
JOIN product.product p ON p.id = pv.product_id
WHERE pv.is_current = true AND p.code = 'CC_GOLD';

-- ✅ V2.3: Upsell relationships from Gold Card
SELECT src.code AS from_product, tgt.code AS to_product,
       pr.relationship_type, pr.strength
FROM product.product_relationship pr
JOIN product.product src ON src.id = pr.source_product_id
JOIN product.product tgt ON tgt.id = pr.target_product_id
WHERE src.code = 'CC_GOLD';
-- Expected: 2 rows — upsell→CC_PLATINUM, prerequisite→DEMAND_DEP_TL
```

> [!TIP]
> **Checkpoint**: Product catalog navigable. Category tree, versions, and relationships work. Approve to continue.

---

## Phases 3–16: Summary

> [!IMPORTANT]
> The full seed scripts for Phases 3–16 follow the same pattern. Each phase will be delivered with:
> 1. **DDL execution** — run the SQL file
> 2. **Seed script** — realistic Turkish banking demo data
> 3. **Validation queries** — 3–5 queries to confirm correctness
> 4. **Checkpoint** — user approval before proceeding
>
> Below is the summary of what each remaining phase seeds.

### Phase 3: Customer & Compliance (`04_customer.sql`)
- 10 customers: 5 corporate, 3 SME, 2 individual
- Segments: tier, behavioral, lifecycle assignments
- Product holdings: each customer holds 2–4 products
- RM assignments: primary + secondary
- KVKK consents: data_processing + marketing for all customers
- Data retention policies: 3 categories
- Customer 360 cache: pre-built JSONB profiles

### Phase 4: Performance & Targets (`05_perf.sql`)
- 5 metric definitions: LOAN_VOL_TRY, DEPOSIT_GROWTH, NEW_ACCT_COUNT, CUSTOMER_NPS, CROSS_SELL_RATE
- Targets: company-level, branch-level, employee-level (with floor/target/stretch)
- Realizations: 3 snapshots per target (10th, 20th, 30th of month)
- 1 scorecard: "Branch Manager Scorecard 2025" with 4 weighted components

### Phase 5: Analytics & AI Scores (`06_analytics.sql`)
- 1 model: churn propensity classifier
- 50 scores: one per customer × model cycle
- 10 SHAP explanations: top-3 feature contributions

### Phase 6: Action Engine (`07_action.sql`)
- 5 status definitions: New, In Progress, Done, On Hold, Cancelled
- 4 action types: Discovery Call → Proposal → Negotiation → Contract (DAG)
- Type dependencies: finish-to-start chain
- 15 action instances: 5 per RM, mixed statuses
- 1 recurrence rule: monthly health check
- 3 escalation rules: 48h → team_lead, 96h → manager

### Phase 7: Content & Briefings (`08_content.sql`)
- 2 templates: daily_briefing, product_scorecard
- 3 briefings: branch-level daily, with content_data JSONB
- Read tracking + feedback entries

### Phase 8: Audit & Compliance Logs (`09_audit.sql`)
- 20 audit_log entries: mixed create/update/approve actions
- 5 AI reasoning log entries: full prompt→response chain
- 5 data access log entries: PII access with purpose

### Phase 9: Config & Feature Flags (`10_config.sql`)
- 1 change request: metric formula update, with 2 approvals
- 3 feature flags: ai_suggestion_engine (10% rollout), bulk_target_upload (enabled), advanced_reports (disabled)
- 2 config versions: action_statuses in draft and production

### Phase 10: Integration & Events (`11_integration.sql`)
- 1 data source: CoreBanking ETL (daily batch)
- 2 sync jobs: 1 completed, 1 partial
- 1 outbound webhook: Salesforce action.completed
- 3 events: customer.created, action.completed, target.breached

### Phase 11: Agent & AI Memory (`12_agent.sql`)
- 2 conversations: 1 briefing_agent, 1 action_planner
- 8 messages: system/user/assistant/tool turns
- 3 short-term memories: session context
- 5 long-term memories: customer preferences, risk indicators
- 2 preferences: language (tenant-level), verbosity (user-level)
- 2 prompt templates: briefing_main, action_planner_main

### Phase 12: Notifications (`13_notification.sql`)
- 1 channel: in_app (internal provider)
- 2 templates: action_due_reminder, briefing_ready (Turkish + English)
- 5 notifications: mixed statuses (pending → delivered → read)
- User preferences: quiet hours config

### Phase 13: Documents (`14_document.sql`)
- 3 documents: contract PDF, meeting notes, AI briefing export
- 2 versions: contract v1 + v2
- 4 document links: to customer, action, conversation
- 3 access log entries

### Phase 14: Internationalization (`15_i18n.sql`)
- 2 languages: Turkish (default) + English
- 20 translations: action statuses, metric names, UI labels
- 1 user language preference

### Phase 15: Reporting Layer (`16_reporting.sql`)
- 2 report definitions: customer_kpi_scorecard, rm_action_dashboard
- 1 materialized view registry entry
- 2 report snapshots: cached results with JSONB payloads
- 3 access log entries

### Phase 16: Security Hardening (`17_rls_policies.sql`, `18_indexes.sql`)
- Execute all RLS policies  
- Execute all strategic indexes
- **Validation**: Create a second tenant seed, then prove RLS isolation

---

## Execution Checklist

```markdown
- [ ] Phase  1: Foundation (00 + 01 + 02) — Tenant, Org, Users
- [ ] Phase  2: Product Catalog (03) — Categories, Products, Versions
- [ ] Phase  3: Customer & Compliance (04) — Customer, Segments, Holdings
- [ ] Phase  4: Performance & Targets (05) — Metrics, Targets, Realizations
- [ ] Phase  5: Analytics & AI Scores (06) — Models, Scores, SHAP
- [ ] Phase  6: Action Engine (07) — Status, Types, DAG, Instances
- [ ] Phase  7: Content & Briefings (08) — Templates, Briefings
- [ ] Phase  8: Audit & Compliance (09) — Audit, AI Reasoning, Access Logs
- [ ] Phase  9: Config & Feature Flags (10) — Change Requests, Flags
- [ ] Phase 10: Integration & Events (11) — Data Sources, Sync, Events
- [ ] Phase 11: Agent & AI Memory (12) — Conversations, Memory, Prompts
- [ ] Phase 12: Notifications (13) — Channels, Templates, Delivery
- [ ] Phase 13: Documents (14) — Files, Versions, Links
- [ ] Phase 14: Internationalization (15) — Languages, Translations
- [ ] Phase 15: Reporting Layer (16) — Report Defs, Snapshots
- [ ] Phase 16: Security Hardening (17 + 18) — RLS + Indexes
```

> [!IMPORTANT]
> **How to proceed**: After reviewing this plan, set up your PostgreSQL instance and tell me to begin **Phase 1 execution**. I will generate the combined DDL + seed SQL script and guide you through each validation step.
