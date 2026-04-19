# Account Planning — Database Architecture Walkthrough

## What Was Built

A complete PostgreSQL database architecture for an **enterprise-grade Agentic AI Sales & Performance Assistant**, delivered as 19 ordered SQL migration files.

### By the Numbers

| Metric | Value |
|--------|-------|
| SQL files | 19 |
| Total lines of DDL | 3,054 |
| Schemas | 16 (+ 1 separate repo DB) |
| Tables | ~100 |
| RLS-protected tables | 60+ |
| Partitioned tables | 6 |
| Indexes | 60+ |

---

## File Structure

```
v0/sql/
├── 00_extensions_and_schemas.sql   — Extensions (uuid-ossp, pgcrypto, btree_gist) + 16 schemas
├── 01_repo.sql                     — Separate repo DB: app settings, module registry
├── 02_core.sql                     — Tenancy, ABAC IAM, SSO/LDAP, delegation, org hierarchy
├── 03_product.sql                  — Category hierarchy, versioned products, cross-sell
├── 04_customer.sql                 — KVKK/GDPR-compliant customers, segments, 360 cache
├── 05_perf.sql                     — Metrics, multi-level targets, scorecards
├── 06_analytics.sql                — Model registry, partitioned scores, SHAP explanations
├── 07_action.sql                   — DAG workflows, SLA/escalation, recurrence, execution logs
├── 08_content.sql                  — Briefings, structured templates, read tracking, feedback
├── 09_audit.sql                    — Field-level diffs, AI reasoning chains, data access logs
├── 10_config.sql                   — Change management, feature flags, env separation
├── 11_integration.sql              — ETL/API sources, webhooks, event store
├── 12_agent.sql                    — Conversations, short/long-term memory, prompt templates
├── 13_notification.sql             — Multi-channel notifications with external provider support
├── 14_document.sql                 — File metadata, versions, entity linking, access audit
├── 15_i18n.sql                     — Multi-language with human review workflow
├── 16_reporting.sql                — Report definitions, materialized view registry, snapshots
├── 17_rls_policies.sql             — RLS policies for all 60+ tenant-scoped tables
└── 18_indexes.sql                  — 60+ strategic indexes for hot query paths
```

---

## Key Design Decisions

### 1. Multi-Tenancy: Row-Level Security
Every tenant-scoped table has `tenant_id UUID NOT NULL` and an RLS policy using `core.current_tenant_id()`. The application sets `SET app.current_tenant_id = '<uuid>'` on every database connection. The `core.tenant` table itself is exempt (needed for lookups before context is set).

### 2. Organization Hierarchy: Closure Table
Chosen for O(1) ancestor/descendant queries — critical for metric aggregation roll-ups across LOB → Region → Branch. The `core.org_unit_closure` table stores all transitive relationships. Trade-off: writes require maintaining the closure, but reads (the dominant operation) are fast.

### 3. ABAC over RBAC
The `core.abac_policy` table stores attribute-based conditions (subject region = resource region, clearance level ≥ N) rather than static role→permission mappings. This enables fine-grained, context-aware access control.

### 4. KVKK/GDPR by Architecture
- PII columns are marked via comments for application-layer encryption
- `customer.consent` tracks granular consent with legal basis
- `customer.data_retention_policy` defines per-category retention rules
- `deleted_at` + `anonymized_at` on customers support right to erasure
- `audit.data_access_log` records all PII access with purpose

### 5. Partitioned High-Volume Tables
Six tables are monthly range-partitioned for the expected scale (100 tenants × 2M scores/cycle):
- `analytics.model_score` (scored_at)
- `action.action_execution_log` (created_at)
- `audit.audit_log` (occurred_at) — 12-month hot retention
- `audit.ai_reasoning_log` (occurred_at) — 6-month hot retention  
- `audit.data_access_log` (occurred_at) — 12-month hot retention
- `integration.event` (occurred_at) — 18-month hot retention

### 6. DAG-Based Workflows
Action dependencies are modeled at two levels:
- **Template level**: `action.action_type_dependency` defines reusable DAG edges
- **Instance level**: `action.action_dependency` tracks runtime satisfaction
Cycle detection is enforced at the application layer (not SQL-expressible).

### 7. AI Agent Architecture
- **Short-term memory** (`agent.memory_short_term`): ephemeral, with `expires_at` for auto-cleanup
- **Long-term memory** (`agent.memory_long_term`): persistent facts with confidence scores and relevance decay
- **Preferences** (`agent.preference`): hierarchical (tenant → LOB → user), more specific overrides general
- **Prompt templates** (`agent.prompt_template`): tenant-isolated, versioned, with approval workflow

### 8. Future-Proofing
Several fields are reserved for future capabilities with `[FUTURE]` comments:
- `analytics.model.performance_metrics` / `ab_test_config` — for automatic A/B testing
- `perf.metric_definition.calculation_config` — for in-app metric calculation engine

---

## Execution Order

The files are numbered for dependency-correct execution:

```bash
# Against the MAIN database:
psql -f sql/00_extensions_and_schemas.sql
psql -f sql/02_core.sql
psql -f sql/03_product.sql
psql -f sql/04_customer.sql
psql -f sql/05_perf.sql
psql -f sql/06_analytics.sql
psql -f sql/07_action.sql
psql -f sql/08_content.sql
psql -f sql/09_audit.sql
psql -f sql/10_config.sql
psql -f sql/11_integration.sql
psql -f sql/12_agent.sql
psql -f sql/13_notification.sql
psql -f sql/14_document.sql
psql -f sql/15_i18n.sql
psql -f sql/16_reporting.sql
psql -f sql/17_rls_policies.sql
psql -f sql/18_indexes.sql

# Against the REPO database (separate):
psql -d repo_db -f sql/01_repo.sql
```

---

## Pending Verification

- **Schema validation**: Requires running DDL against a PostgreSQL 16+ instance to verify syntax and FK resolution
- **RLS testing**: Insert test data with different tenant contexts to verify isolation
- **Partition management**: Verify partition creation and query routing

---

## Suggested Next Steps

1. **Spin up PostgreSQL 16** and run the DDL in order to validate
2. **Seed reference data**: default statuses, default feature flags, sample tenant
3. **Develop ORM models** (SQLAlchemy/Alembic) for the Python backend
4. **Implement partition management job** for auto-creating future partitions
5. **Build audit trigger functions** for automatic field-level diff capture
6. **Design Customer 360 refresh pipeline** (scheduled + event-triggered)
