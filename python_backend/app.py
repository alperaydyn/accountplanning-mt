#!/usr/bin/env python3
"""
Account Planning — Demo App
Sidebar layout with live data pages + DB validation suite under /test/.
"""
from flask import Flask, render_template_string, session, redirect, url_for, request
import psycopg2, psycopg2.extras, os, json
from datetime import datetime
from functools import wraps

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "ap-dev-secret-key-2026")

DB_CFG = dict(
    host=os.getenv("DB_HOST", "76.13.60.86"),
    port=int(os.getenv("DB_PORT", 5432)),
    user=os.getenv("DB_USER", "ap_user_001"),
    password=os.getenv("DB_PASSWORD", "apuser!23"),
    dbname=os.getenv("DB_NAME", "accountplanning"),
    connect_timeout=8,
)

# ── Auth ───────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def dec(*a, **kw):
        if "user_id" not in session:
            return redirect(url_for("login"))
        return f(*a, **kw)
    return dec

# ── DB ─────────────────────────────────────────────────────────────────────────
def _conn():
    c = psycopg2.connect(**DB_CFG)
    if session.get("tenant_id"):
        cur = c.cursor()
        cur.execute("SET app.current_tenant_id = %s", (session["tenant_id"],))
        cur.close()
    return c

def qry(sql, params=None, raw=False):
    try:
        conn = _conn()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, params)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description] if cur.description else []
        cur.close(); conn.close()
        if raw:
            return cols, [dict(r) for r in rows], None
        return cols, rows, None
    except Exception as e:
        return [], [], str(e)

def qone(sql, params=None):
    _, rows, _ = qry(sql, params, raw=True)
    return rows[0] if rows else {}

def fmt_cell(v):
    if v is None:       return "—", "cell-null"
    if isinstance(v, bool): return ("true","cell-t") if v else ("false","cell-f")
    s = str(v)
    return (s[:77]+"…" if len(s)>80 else s), ""

def fmt_rows(cols, raw_rows):
    return [{c: {"d": fmt_cell(r[c])[0], "cls": fmt_cell(r[c])[1]} for c in cols}
            for r in [dict(r) for r in raw_rows]]

def authenticate(tc, un):
    _, rows, _ = qry("""
        SELECT u.id,u.display_name,u.user_type,u.username,
               t.id AS tenant_id,t.code AS tenant_code,t.name AS tenant_name
        FROM core.user_ u JOIN core.tenant t ON t.id=u.tenant_id
        WHERE UPPER(t.code)=UPPER(%s) AND LOWER(u.username)=LOWER(%s)
          AND u.status='active' AND t.status='active' LIMIT 1""",
        (tc, un), raw=True)
    return rows[0] if rows else None

def sctx():
    return {k: session.get(k,"") for k in
            ("display_name","tenant_name","tenant_code","user_type","user_id")}

def tid(): return session.get("tenant_id","")

# ══════════════════════════════════════════════════════════════════════════════
# TEST DEFINITIONS
# ══════════════════════════════════════════════════════════════════════════════
P1 = [
    dict(id="T1_1",code="V1.1",icon="🏢",phase=1,
        title="Multi-Tenant Foundation",
        short_desc="Tenant record with KVKK/GDPR config, industry classification, and data residency.",
        params_type="tenant_id",
        business_req="The application serves a multi-tenant architecture. Each company has its own set of users, roles, relations and preferences. A tenant record must exist with KVKK/GDPR compliance configuration and industry tagging, enabling proper data residency and jurisdiction rules.",
        what_we_test="Verify that <code>core.tenant</code> holds your authenticated tenant with correct industry classification, status, data residency region, and GDPR config fields. The query is scoped to your session <code>tenant_id</code> — demonstrating tenant isolation.",
        sql="SELECT code,name,industry,status,\n       data_residency_region,kvkk_gdpr_config\nFROM   core.tenant\nWHERE  id=%s;",
        expected="1 row — your tenant, status=active, data_residency_region=TR",
        issues=["The <code>domain</code> field from the original plan is absent — replaced by broader <code>settings</code> JSONB. Minor naming drift between plan and DDL.",
                "No top-level <code>subscription_plan</code> column — nested inside <code>settings</code> JSONB, adding friction for BI tools."]),
    dict(id="T1_2",code="V1.2",icon="🌳",phase=1,
        title="Organisation Hierarchy Tree",
        short_desc="6-level company → LOB → region → area → branch → team adjacency list.",
        params_type="tenant_id",
        business_req="The sales team is organised in a hierarchical structure — LOBs, Regions, Areas, Branches and Teams. The structure is multi-level and defined per tenant. The database must store all levels allowing queries without recursive CTEs at read time.",
        what_we_test="Query <code>core.org_unit</code> for all nodes belonging to your tenant and confirm the full 6-level tree (company→lob×2→region→area→branch→team) is intact.",
        sql="SELECT level,code,name,unit_type,\n       parent_id IS NOT NULL AS has_parent\nFROM   core.org_unit\nWHERE  tenant_id=%s\nORDER  BY level,code;",
        expected="7 rows — 6 levels: company(0) lob×2(1) region(2) area(3) branch(4) team(5)",
        issues=["The adjacency table alone cannot answer 'all descendants of X' without joining <code>org_unit_closure</code>. Subtree queries must always use the closure table.",
                "No DB trigger auto-populates <code>org_unit_closure</code> on insert — closure rows must be maintained manually. Data-consistency risk during re-orgs."]),
    dict(id="T1_3",code="V1.3",icon="🔗",phase=1,
        title="Closure Table — Subtree Queries",
        short_desc="O(1) ancestor/descendant lookups for efficient metric roll-ups across the org tree.",
        params_type="none",fixture_note="Uses demo fixture UUID for Retail Banking LOB (c0000000-…-0010)",
        business_req="Performance metric roll-ups must aggregate from employee → team → branch → region → LOB → company. The closure table design enables O(1) ancestor/descendant lookups — critical for real-time dashboard widgets and AI-generated briefings.",
        what_we_test="Use <code>core.org_unit_closure</code> to find all descendants of <strong>Retail Banking (LOB)</strong> at any depth, verifying transitive relationships are stored.",
        sql="SELECT d.code,d.name,d.unit_type,cc.depth\nFROM   core.org_unit_closure cc\nJOIN   core.org_unit d ON d.id=cc.descendant_id\nWHERE  cc.ancestor_id='c0000000-0000-0000-0000-000000000010'\n  AND  cc.depth>0\nORDER  BY cc.depth;",
        expected="4 rows — Marmara(1),IST_EUROPE(2),LEVENT(3),LEVENT_TEAM_A(4)",
        issues=["Corporate Banking is correctly isolated — its descendants do not appear in the Retail subtree. ✅",
                "Closure write path is not automated. On re-orgs all stale closure rows must be deleted and re-inserted. An application-layer utility or stored procedure is needed."]),
    dict(id="T1_4",code="V1.4",icon="👥",phase=1,
        title="Employee–Org Assignment & Team Membership",
        short_desc="Employee assignments with effective dates, roles, and multi-team support.",
        params_type="none",fixture_note="Uses demo fixture UUID for Levent Team A (c0000000-…-0050)",
        business_req="Each sales employee is assigned to one or more org units. Multi-team assignments are supported with one marked primary. Historical assignments are preserved via effective_from/effective_until for accurate historical reporting.",
        what_we_test="Retrieve all currently active employees assigned to <strong>Levent Team A</strong> by joining <code>core.employee</code>, <code>core.user_</code>, and <code>core.employee_org_assignment</code> where <code>effective_until IS NULL</code>.",
        sql="SELECT e.employee_code,u.display_name,e.title,\n       eoa.role_in_unit,eoa.effective_from\nFROM   core.employee e\nJOIN   core.user_ u ON u.id=e.user_id\nJOIN   core.employee_org_assignment eoa ON eoa.employee_id=e.id\nWHERE  eoa.org_unit_id='c0000000-0000-0000-0000-000000000050'\n  AND  eoa.effective_until IS NULL\nORDER  BY eoa.effective_from;",
        expected="3 rows — EMP003 (Senior RM), EMP004 (RM), EMP005 (Junior RM)",
        issues=["<code>role_in_unit</code> uses a CHECK constraint instead of a lookup table — tenant-specific role names require a DDL change.",
                "The <code>source</code> column correctly tracks assignment origin (<code>manual</code>, <code>core_system</code>, <code>ldap_sync</code>) — important for conflict resolution. ✅"]),
    dict(id="T1_5",code="V1.5",icon="📅",phase=1,
        title="Reporting Periods — Temporal Awareness",
        short_desc="Monthly and quarterly periods with fiscal year mapping and current-period flags.",
        params_type="tenant_id",
        business_req="Performance metrics, targets, and realizations are all time-boxed. The system must know the currently active period (is_current=true), closed periods, and support both monthly and quarterly granularity per tenant. This powers YTD, QTD, and period-over-period comparisons.",
        what_we_test="Fetch all reporting periods from <code>core.reporting_period</code> for your tenant and confirm monthly and quarterly periods with correct <code>is_current</code> and <code>is_closed</code> flags.",
        sql="SELECT period_type,period_label,period_name,\n       period_start,period_end,\n       is_current,is_closed,fiscal_year,fiscal_quarter\nFROM   core.reporting_period\nWHERE  tenant_id=%s\nORDER  BY period_start,period_type;",
        expected="6 rows — Jan/Feb/Mar/Apr monthly + Q1/Q2 quarterly; Apr & Q2 is_current=true",
        issues=["Fiscal year/quarter are integers per row — fiscal calendar logic is replicated in application code rather than derived from a shared calendar dimension.",
                "No tenant-configurable fiscal year start month. Periods must be seeded manually.",
                "Improvement: add a <code>reporting_calendar_config</code> to <code>core.tenant</code> to auto-generate future periods."]),
    dict(id="T1_6",code="V1.6",icon="🧩",phase=1,
        title="Module Registry & Feature Flags",
        short_desc="Per-tenant module enable/disable with config overrides for gradual rollout.",
        params_type="tenant_id",
        business_req="The application is modular — companies may not be ready for AI-based insights. Each module can be individually enabled/disabled per tenant with configuration overrides. This is the foundation for gradual feature rollout.",
        what_we_test="Query <code>core.tenant_module</code> to confirm all 15 modules are registered for your tenant with correct <code>is_enabled</code> status. This table drives runtime feature-gating.",
        sql="SELECT module_code,is_enabled,\n       CASE WHEN config_override='{}'\n            THEN 'default' ELSE 'customised'\n       END AS config_state\nFROM   core.tenant_module\nWHERE  tenant_id=%s\nORDER  BY module_code;",
        expected="15 rows — all modules enabled with default config",
        issues=["<code>tenant_module.module_code</code> is VARCHAR with no FK to <code>repo.supported_module</code> — a typo silently creates an orphaned row.",
                "No <code>enabled_at</code>/<code>enabled_by</code> audit trail — important for compliance when toggling sensitive modules like <code>agent</code>."]),
]

P2 = [
    dict(id="T2_1",code="V2.1",icon="📂",phase=2,
        title="Product Category Tree",
        short_desc="3-level category hierarchy: FINANCIAL → LOANS/DEPOSITS/CARDS/INSURANCE → sub-categories.",
        params_type="tenant_id",
        business_req="The product catalog must be organised in a multi-level category hierarchy enabling browseable navigation, scoped reporting, and category-level insights generated by the AI agent.",
        what_we_test="Verify the 3-level category tree is intact with correct level values and parent-child links. 9 nodes seeded: FINANCIAL (root) → LOANS, DEPOSITS, CARDS, INSURANCE → TL_CASH, MORTGAGE, TIME_DEPOSIT, DEMAND_DEPOSIT.",
        sql="SELECT level,code,name,\n       CASE WHEN parent_id IS NULL THEN 'root' ELSE 'child' END AS position,\n       is_active\nFROM   product.category\nWHERE  tenant_id=%s\nORDER  BY level,display_order;",
        expected="9 rows — level 0 root + level 1×4 + level 2×4, all active",
        issues=["Category closure table (<code>product.category_closure</code>) is not auto-maintained — closure rows must be manually inserted on category creation. Same risk as Phase 1 org closure.",
                "No <code>display_name_i18n</code> column for multi-language labels."]),
    dict(id="T2_2",code="V2.2",icon="🔎",phase=2,
        title="Products Under LOANS (Category Closure)",
        short_desc="All loan products retrieved via category closure — O(1) subtree query.",
        params_type="tenant_id",fixture_note="Uses demo fixture UUID for LOANS category root (f0000000-…-0010)",
        business_req="The AI agent must be able to list all products belonging to a category subtree (e.g. 'which loan products do we offer?'). The category closure table makes O(1) subtree lookups possible without recursive CTEs.",
        what_we_test="Use <code>product.category_closure</code> to retrieve all products whose category is a descendant of the <strong>LOANS</strong> root. Should return Standard Cash Loan, Premium Cash Loan, and Fixed-Rate Mortgage.",
        sql="SELECT p.code,p.name,c.code AS category_code,cc.depth AS cat_depth\nFROM   product.product p\nJOIN   product.category c ON c.id=p.category_id\nJOIN   product.category_closure cc ON cc.descendant_id=c.id\nWHERE  cc.ancestor_id='f0000000-0000-0000-0000-000000000010'\n  AND  cc.tenant_id=%s\nORDER  BY p.code;",
        expected="3 rows — CASH_LOAN_STD, CASH_LOAN_PREMIUM, MORTGAGE_FIXED",
        issues=["All 3 loan products returned correctly via closure join. ✅",
                "Closure table must be updated when a product changes category — no trigger ensures this."]),
    dict(id="T2_3",code="V2.3",icon="📋",phase=2,
        title="Product Versioning — Current Version",
        short_desc="Active terms for Gold Card via is_current=true versioning with full JSONB terms.",
        params_type="none",fixture_note="Queries by product code 'CC_GOLD' (demo seed)",
        business_req="Product terms (interest rates, fees, benefits) change over time. The versioning system must always expose currently active terms via <code>is_current=true</code> while preserving historical versions for audit.",
        what_we_test="Fetch the current version for the Gold Credit Card (<code>CC_GOLD</code>) and confirm <code>is_current=true</code>, correct <code>version_label</code>, and <code>terms</code> JSONB with fee and cashback structure.",
        sql="SELECT p.name,pv.version_number,pv.version_label,\n       pv.effective_from,pv.terms,pv.is_current\nFROM   product.product_version pv\nJOIN   product.product p ON p.id=pv.product_id\nWHERE  pv.is_current=true AND p.code='CC_GOLD';",
        expected="1 row — Gold Card v1 '2025 Gold Launch', is_current=true, terms with annual_fee=250",
        issues=["Version approval workflow not enforced at DB level — <code>approved_by</code> can be NULL and any user can set <code>is_current=true</code>.",
                "No DB constraint prevents two versions having <code>is_current=true</code> simultaneously for the same product."]),
    dict(id="T2_4",code="V2.4",icon="🔀",phase=2,
        title="Product Relationship Graph",
        short_desc="Typed relationships (upsell, cross_sell, prerequisite) with AI-usable strength scores.",
        params_type="none",fixture_note="Queries outbound relationships from product code 'CC_GOLD'",
        business_req="The AI recommendation engine reads <code>product.product_relationship</code> to suggest next-best products. Typed relationships with strength scores (0.0–1.0) enable ranked, explainable recommendation lists in RM briefings.",
        what_we_test="Fetch all outbound product relationships from <code>CC_GOLD</code> and verify relationship types and strength scores. Expected: DEMAND_DEP_TL as prerequisite (1.0) and CC_PLATINUM as upsell (0.70).",
        sql="SELECT src.code AS from_product,tgt.code AS to_product,\n       pr.relationship_type,pr.strength\nFROM   product.product_relationship pr\nJOIN   product.product src ON src.id=pr.source_product_id\nJOIN   product.product tgt ON tgt.id=pr.target_product_id\nWHERE  src.code='CC_GOLD'\nORDER  BY pr.strength DESC;",
        expected="2 rows — CC_GOLD→DEMAND_DEP_TL (prerequisite 1.0), CC_GOLD→CC_PLATINUM (upsell 0.70)",
        issues=["Bidirectional relationships must be inserted as two rows — no automatic symmetric relationship inference.",
                "The <code>metadata</code> JSONB on relationships is untyped — no schema validation prevents malformed payloads."]),
    dict(id="T2_5",code="V2.5",icon="📊",phase=2,
        title="Product Catalog Summary by Category",
        short_desc="Product counts per category to identify catalog coverage and white-space gaps.",
        params_type="tenant_id",
        business_req="Management dashboards need to understand product catalog breadth at a glance — how many products exist per category. Categories with zero products represent white-space opportunities.",
        what_we_test="Aggregate product counts by category (level > 0) to confirm catalog structure. Should show LOANS, DEPOSITS, CARDS, INSURANCE as parent categories with their sub-categories and product counts.",
        sql="SELECT c.name AS category,c.level,count(p.id) AS product_count\nFROM   product.category c\nLEFT   JOIN product.product p ON p.category_id=c.id\nWHERE  c.tenant_id=%s AND c.level>0\nGROUP  BY c.name,c.level,c.display_order\nORDER  BY c.level,c.display_order;",
        expected="8 rows — level 1 categories, level 2 sub-categories with direct products",
        issues=["The <code>level</code> column is stored redundantly — can be derived from closure table depth.",
                "INSURANCE (level 1) has no products directly — products sit in sub-category. Verify this is intentional."]),
]

P3 = [
    dict(id="T3_1",code="V3.1",icon="👤",phase=3,
        title="Customer Mix by Type",
        short_desc="10 customers: 5 corporate, 3 SME, 2 individual — foundation of the 360° view.",
        params_type="tenant_id",
        business_req="The system serves multiple customer types — individual, SME, and corporate — each with different risk profiles, product eligibilities, and relationship management workflows.",
        what_we_test="Verify that the 10 seeded customers are split correctly: 5 corporate, 3 SME, 2 individual. This validates the <code>customer_type</code> CHECK constraint.",
        sql="SELECT customer_type,count(*) AS count\nFROM   customer.customer\nWHERE  tenant_id=%s AND deleted_at IS NULL\nGROUP  BY customer_type\nORDER  BY customer_type;",
        expected="3 rows — corporate:5, individual:2, sme:3",
        issues=["5 corporate, 3 SME, 2 individual correctly seeded. ✅",
                "No tenant-level customer type configuration (e.g. disabling 'individual' for a B2B-only bank)."]),
    dict(id="T3_2",code="V3.2",icon="🤝",phase=3,
        title="Customer–RM Assignments",
        short_desc="Primary RM per customer with source tracking (core_system, direct, branch_based).",
        params_type="tenant_id",
        business_req="Each customer must be assigned to at least one RM (primary). The assignment table tracks who is responsible for each customer at any point in time, enabling workload reporting and coverage analysis.",
        what_we_test="Fetch all current primary assignments (<code>effective_until IS NULL</code>) showing customer name, RM name, title, and assignment source. EMP003 Mehmet Kaya covers 3 corporates; EMP004 covers 4; EMP005 covers 3.",
        sql="SELECT c.name AS customer,u.display_name AS rm,\n       e.title,ca.assignment_type,ca.source\nFROM   customer.customer_assignment ca\nJOIN   customer.customer c ON c.id=ca.customer_id\nJOIN   core.employee e     ON e.id=ca.employee_id\nJOIN   core.user_ u        ON u.id=e.user_id\nWHERE  ca.tenant_id=%s\n  AND  ca.assignment_type='primary'\n  AND  ca.effective_until IS NULL\nORDER  BY u.display_name,c.name;",
        expected="10 rows — 3 RMs covering all 10 customers, source varies by assignment method",
        issues=["Mehmet Kaya also has a secondary assignment on Yildiz Gida — strategic dual-coverage correctly excluded from this query. ✅",
                "No alert fires when a customer has no primary assignment. Coverage check enforcement needed."]),
    dict(id="T3_3",code="V3.3",icon="📦",phase=3,
        title="Customer Product Holdings",
        short_desc="14 active product holdings spanning loans, deposits, credit cards, mortgage, insurance.",
        params_type="tenant_id",
        business_req="The 360° customer view requires knowing what products each customer actively holds. This powers the 'Customer Portfolio' widget and gap-analysis for upsell/cross-sell suggestions.",
        what_we_test="Join <code>customer.customer_product</code> with customer and product tables to list all active product holdings. 14 holdings across 10 customers.",
        sql="SELECT c.name AS customer,p.code AS product,\n       cp.status,cp.start_date\nFROM   customer.customer_product cp\nJOIN   customer.customer c ON c.id=cp.customer_id\nJOIN   product.product p   ON p.id=cp.product_id\nWHERE  cp.tenant_id=%s\nORDER  BY c.name,p.code;",
        expected="14 rows — all status=active, start dates from 2022 to 2025",
        issues=["All 14 holdings have status='active' — correctly seeded. ✅",
                "No FK enforcement on <code>customer_product.product_version_id</code> when NULL."]),
    dict(id="T3_4",code="V3.4",icon="🔐",phase=3,
        title="KVKK Consent Tracking",
        short_desc="Consent records by type and status — data_processing, marketing, profiling, automated_decision.",
        params_type="tenant_id",
        business_req="KVKK requires explicit, recorded consent for each processing purpose. The system must track consent status per customer per type, support revocation, and be queryable for compliance reporting.",
        what_we_test="Aggregate consent records by type and status. Expected: data_processing (6 granted), marketing (3 granted, 1 revoked), profiling (1 granted), automated_decision (1 granted).",
        sql="SELECT consent_type,\n       sum(CASE WHEN status='granted' THEN 1 ELSE 0 END) AS granted,\n       sum(CASE WHEN status='revoked' THEN 1 ELSE 0 END) AS revoked\nFROM   customer.consent\nWHERE  tenant_id=%s\nGROUP  BY consent_type\nORDER  BY consent_type;",
        expected="4 rows — data_processing(6/0), marketing(3/1), profiling(1/0), automated_decision(1/0)",
        issues=["Selin Arslan's marketing consent correctly recorded as 'revoked'. AI engine must check this before sending marketing. ✅",
                "No <code>expires_at</code> column — consents do not auto-expire. KVKK requires periodic re-consent for some types."]),
    dict(id="T3_5",code="V3.5",icon="🤖",phase=3,
        title="Customer 360 Cache & NBO Signals",
        short_desc="Pre-computed snapshots with AI-generated next-best-offer and churn scores per customer.",
        params_type="tenant_id",
        business_req="The AI agent's briefing engine reads pre-computed Customer 360 snapshots to generate contextual insights without running expensive live queries. Each snapshot includes NBO signals, churn scores, and product summaries.",
        what_we_test="Query <code>customer.customer_360_cache</code> joined with <code>customer.customer</code> to retrieve NBO recommendations and churn scores, ordered by churn risk (highest first).",
        sql="SELECT c.name,\n       cache.segment_summary->>'primary_tier'     AS tier,\n       cache.analytics_summary->>'nbo'            AS next_best_offer,\n       (cache.analytics_summary->>'churn_score')::numeric AS churn_score,\n       cache.refresh_source\nFROM   customer.customer_360_cache cache\nJOIN   customer.customer c ON c.id=cache.customer_id\nWHERE  c.tenant_id=%s\nORDER  BY churn_score DESC;",
        expected="4 rows — Emre Aydin highest churn(0.15), Selin Arslan lowest(0.04); NBOs per customer",
        issues=["Emre Aydin (ONBOARDING) has highest churn score (0.15) — NBO of CASH_LOAN_STD correctly targeted for early upsell trigger. ✅",
                "Cache uses <code>version</code> integer — no invalidation trigger exists when a customer product changes."]),
    dict(id="T3_6",code="V3.6",icon="📜",phase=3,
        title="Data Retention Policies",
        short_desc="5 KVKK-compliant retention policies: anonymize, archive, delete by data category.",
        params_type="tenant_id",
        business_req="KVKK mandates that personal data is not kept longer than necessary. Data retention policies define how long each data category is stored and what action (anonymize/delete/archive) is taken on expiry.",
        what_we_test="Fetch all retention policies for your tenant. Should show 5 policies covering PII, transactions, consents, audit logs, and AI reasoning logs.",
        sql="SELECT data_category,retention_period_days,\n       action_on_expiry,legal_basis,is_active\nFROM   customer.data_retention_policy\nWHERE  tenant_id=%s\nORDER  BY retention_period_days DESC;",
        expected="5 rows — audit_logs(1825d), pii/transactions(3650d), consents(1095d), ai_logs(730d)",
        issues=["AI reasoning logs have the shortest retention (730 days) with 'delete' action — correct for KVKK Art22. ✅",
                "Retention policy enforcement is not automated — no pg_cron task calls <code>action_on_expiry</code>.",
                "No per-customer retention policy override — tenant-level only."]),
]

PHASES = {
    1: dict(num=1,icon="🏗",color="#3a6bff",title="Foundation",sub="core schema",
            description="Multi-tenant architecture, org hierarchy with closure table, IAM & ABAC, employee assignments, reporting periods, and module feature-flag registry.",
            schemas=["core"],tests=P1),
    2: dict(num=2,icon="📦",color="#059669",title="Product Catalog",sub="product schema",
            description="Hierarchical product category tree with closure, versioned product terms, typed product-to-product relationship graph powering AI upsell/cross-sell recommendations.",
            schemas=["product"],tests=P2),
    3: dict(num=3,icon="👥",color="#7c3aed",title="Customer & Compliance",sub="customer schema",
            description="Customer universe (corporate/SME/individual), RM assignments, product holdings, KVKK consent tracking, Customer 360 cache with NBO signals, and data retention policies.",
            schemas=["customer"],tests=P3),
}

TEST_MAP = {}
for _pn, _ph in PHASES.items():
    for _t in _ph["tests"]:
        TEST_MAP[_t["id"]] = {"phase_num": _pn, "phase": _ph, "test": _t}

# ══════════════════════════════════════════════════════════════════════════════
# CSS
# ══════════════════════════════════════════════════════════════════════════════
FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">'
         '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700'
         '&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">')

CSS = """
:root{
  --bg:#f4f6fb;--surf:#fff;--sa:#f0f2f6;--bd:#e2e6ed;--bdl:#edf0f5;
  --tx:#18202e;--tx2:#586070;--txm:#9198a8;
  --ac:#3a6bff;--acl:#eef1ff;--acd:#2452d9;
  --ok:#16a34a;--okb:#f0fdf4;--okd:#bbf7d0;
  --wa:#d97706;--wab:#fffbeb;--wad:#fde68a;
  --er:#dc2626;--erb:#fef2f2;--erd:#fecaca;
  --in:#0891b2;--inb:#ecfeff;--ind:#a5e0ec;
  --r:12px;--rs:8px;
  --sh:0 1px 3px rgba(0,0,0,.07),0 1px 2px rgba(0,0,0,.04);
  --shm:0 4px 16px rgba(0,0,0,.1),0 1px 3px rgba(0,0,0,.05);
  --sb:#1c2333;--sb2:#242d42;--sb3:#2e3a52;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden}
body{font-family:'Inter',system-ui,sans-serif;background:var(--bg);color:var(--tx);line-height:1.6}
a{color:var(--ac);text-decoration:none}a:hover{text-decoration:underline}
code{font-family:'JetBrains Mono',monospace;font-size:.85em;background:var(--sa);padding:.1em .3em;border-radius:4px}
button{font-family:inherit}

/* App shell */
.app{display:flex;height:100vh;overflow:hidden}

/* Sidebar */
.sidebar{width:236px;flex-shrink:0;background:var(--sb);display:flex;flex-direction:column;overflow-y:auto;overflow-x:hidden}
.sb-brand{padding:1.1rem 1rem .9rem;border-bottom:1px solid rgba(255,255,255,.06);display:flex;align-items:center;gap:.65rem}
.sb-logo{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,#3a6bff,#7c3aed);display:grid;place-items:center;color:#fff;font-weight:700;font-size:13px;flex-shrink:0}
.sb-appname{font-size:.85rem;font-weight:700;color:#f1f5f9;line-height:1.2}
.sb-tagline{font-size:.65rem;color:#64748b}
.sb-user{padding:.65rem 1rem;border-bottom:1px solid rgba(255,255,255,.06);display:flex;align-items:center;gap:.55rem}
.sb-udot{width:7px;height:7px;border-radius:50%;background:#22c55e;flex-shrink:0}
.sb-uname{font-size:.77rem;color:#cbd5e1;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sb-utag{font-family:'JetBrains Mono',monospace;font-size:.63rem;color:#60a5fa;background:rgba(96,165,250,.12);padding:.08rem .38rem;border-radius:3px;display:inline-block;margin-top:.1rem}
.sb-nav{flex:1;padding:.4rem 0}
.sb-sect{font-size:.62rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#475569;padding:.7rem 1rem .25rem}
.si{display:flex;align-items:center;gap:.6rem;padding:.44rem .85rem .44rem 1rem;font-size:.81rem;color:#94a3b8;border-left:3px solid transparent;transition:all .12s;text-decoration:none!important;white-space:nowrap}
.si:hover{background:rgba(255,255,255,.05);color:#cbd5e1}
.si.act{background:rgba(58,107,255,.14);color:#fff;border-left-color:#3a6bff;font-weight:500}
.si-sub{padding-left:1.6rem;font-size:.77rem}
.si-sub.act{border-left-color:var(--act-color,#3a6bff)}
.si-ico{font-size:.95rem;flex-shrink:0;width:17px;text-align:center}
.sb-footer{padding:.65rem 1rem;border-top:1px solid rgba(255,255,255,.06)}
.sb-out{display:flex;align-items:center;gap:.5rem;font-size:.78rem;color:#64748b;padding:.3rem .4rem;border-radius:6px;cursor:pointer;text-decoration:none!important;transition:all .12s}
.sb-out:hover{color:#f87171;background:rgba(248,113,113,.1)}

/* Content */
.content{flex:1;overflow-y:auto;background:var(--bg)}
.ci{max-width:1080px;margin:0 auto;padding:1.75rem 2rem}

/* Page header */
.ph{margin-bottom:1.5rem}
.ph h1{font-size:1.25rem;font-weight:700;margin-bottom:.2rem}
.ph p{font-size:.85rem;color:var(--tx2)}
.ph-row{display:flex;align-items:flex-end;justify-content:space-between;gap:1rem;flex-wrap:wrap;margin-bottom:1.5rem}
.ph-row h1{font-size:1.25rem;font-weight:700;margin:0}
.ph-row p{font-size:.83rem;color:var(--tx2);margin-top:.15rem}

/* Breadcrumb */
.bc{display:flex;align-items:center;gap:.35rem;margin-bottom:1.25rem;font-size:.79rem;color:var(--tx2);flex-wrap:wrap}
.bc a{color:var(--ac)}.bc-sep{color:var(--bdl)}

/* Stats */
.stats-row{display:grid;grid-template-columns:repeat(4,1fr);gap:.9rem;margin-bottom:1.5rem}
@media(max-width:800px){.stats-row{grid-template-columns:repeat(2,1fr)}}
.stat-card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);padding:1rem 1.2rem;box-shadow:var(--sh)}
.stat-ico{font-size:1.3rem;margin-bottom:.5rem}
.stat-val{font-size:1.6rem;font-weight:700;line-height:1;color:var(--ac)}
.stat-lbl{font-size:.7rem;color:var(--txm);margin-top:.18rem;text-transform:uppercase;letter-spacing:.05em}

/* Data table */
.dtw{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);overflow:hidden;box-shadow:var(--sh)}
.dt-hd{padding:.7rem 1.1rem;border-bottom:1px solid var(--bd);display:flex;align-items:center;justify-content:space-between}
.dt-title{font-size:.88rem;font-weight:600}.dt-cnt{font-size:.73rem;color:var(--txm)}
table{width:100%;border-collapse:collapse}
table.main th{text-align:left;padding:.55rem .9rem;font-size:.69rem;font-weight:600;color:var(--tx2);letter-spacing:.05em;text-transform:uppercase;border-bottom:1px solid var(--bd);background:var(--sa);white-space:nowrap}
table.main td{padding:.5rem .9rem;font-size:.82rem;border-bottom:1px solid var(--bdl)}
table.main tr:last-child td{border-bottom:none}
table.main tbody tr:hover td{background:var(--sa);cursor:pointer}
table.mono td{font-family:'JetBrains Mono',monospace;font-size:.76rem}
.cell-null{color:var(--txm);font-style:italic}.cell-t{color:var(--ok);font-weight:600}.cell-f{color:var(--er);font-weight:600}

/* Chips/badges */
.chip{display:inline-flex;align-items:center;padding:.14rem .52rem;border-radius:20px;font-size:.69rem;font-weight:600}
.ch-corp{background:#eff6ff;color:#1d4ed8;border:1px solid #bfdbfe}
.ch-sme{background:#f0fdf4;color:#15803d;border:1px solid #bbf7d0}
.ch-ind{background:#faf5ff;color:#7e22ce;border:1px solid #e9d5ff}
.ch-active{background:var(--okb);color:var(--ok);border:1px solid var(--okd)}
.ch-warn{background:var(--wab);color:var(--wa);border:1px solid var(--wad)}
.pill{display:inline-flex;align-items:center;gap:.25rem;padding:.18rem .6rem;border-radius:20px;font-size:.7rem;font-weight:600}
.p-pass{background:var(--okb);color:var(--ok);border:1px solid var(--okd)}
.p-fail{background:var(--erb);color:var(--er);border:1px solid var(--erd)}
.p-warn{background:var(--wab);color:var(--wa);border:1px solid var(--wad)}
.p-ac{background:var(--acl);color:var(--ac);border:1px solid #c7d6ff}

/* Cards */
.card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);box-shadow:var(--sh)}
.card-hover{transition:transform .15s,box-shadow .15s}
.card-hover:hover{transform:translateY(-2px);box-shadow:var(--shm)}

/* Grid layouts */
.g2{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
.g3{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem}
.g4{display:grid;grid-template-columns:repeat(4,1fr);gap:1rem}
@media(max-width:860px){.g3{grid-template-columns:1fr 1fr}.g4{grid-template-columns:1fr 1fr}}
@media(max-width:600px){.g2,.g3,.g4{grid-template-columns:1fr}}

/* Dashboard insight cards */
.insight-card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);padding:1rem 1.15rem;box-shadow:var(--sh)}
.ic-label{font-size:.65rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--txm);margin-bottom:.55rem}
.ic-row{display:flex;align-items:center;justify-content:space-between;padding:.3rem 0;border-bottom:1px solid var(--bdl);font-size:.83rem}
.ic-row:last-child{border-bottom:none}
.ic-key{color:var(--tx2)}.ic-val{font-weight:600;color:var(--tx)}

/* Customer 360 */
.c360-header{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);padding:1.15rem 1.35rem;box-shadow:var(--sh);margin-bottom:1rem}
.c360-name{font-size:1.15rem;font-weight:700;margin-bottom:.2rem}
.c360-meta{display:flex;gap:.6rem;flex-wrap:wrap;align-items:center;font-size:.8rem;color:var(--tx2)}
.c360-body{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
@media(max-width:700px){.c360-body{grid-template-columns:1fr}}
.kv{display:flex;gap:.5rem;margin-bottom:.3rem;font-size:.82rem}
.kv-k{color:var(--txm);min-width:110px;flex-shrink:0}.kv-v{color:var(--tx);font-weight:500}

/* NBO */
.nbo-box{background:linear-gradient(135deg,#eef1ff,#f3f0ff);border:1px solid #d6d0ff;border-radius:var(--r);padding:.9rem 1.1rem}
.nbo-label{font-size:.63rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--ac);margin-bottom:.3rem}
.nbo-val{font-size:1.05rem;font-weight:700;color:var(--tx);margin-bottom:.65rem}
.churn-bar{height:5px;background:var(--bd);border-radius:99px;overflow:hidden;margin-top:.25rem}
.churn-fill{height:100%;border-radius:99px}
.churn-low{background:var(--ok)}.churn-med{background:var(--wa)}.churn-hi{background:var(--er)}

/* Products */
.cat-section{margin-bottom:1.5rem}
.cat-hd{font-size:.95rem;font-weight:700;padding:.5rem 0;border-bottom:2px solid var(--bd);margin-bottom:.75rem;display:flex;align-items:center;gap:.5rem}
.prod-cards{display:grid;grid-template-columns:repeat(3,1fr);gap:.75rem}
@media(max-width:800px){.prod-cards{grid-template-columns:1fr 1fr}}
@media(max-width:520px){.prod-cards{grid-template-columns:1fr}}
.prod-card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--rs);padding:.85rem .95rem;box-shadow:var(--sh)}
.prod-code{font-family:'JetBrains Mono',monospace;font-size:.7rem;color:var(--txm);margin-bottom:.2rem}
.prod-name{font-size:.85rem;font-weight:600;margin-bottom:.3rem}
.prod-desc{font-size:.75rem;color:var(--tx2)}

/* Org tree */
.org-tree{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);padding:1.1rem 1.35rem;box-shadow:var(--sh)}
.org-node{display:flex;align-items:center;gap:.6rem;padding:.32rem .5rem;border-radius:6px;font-size:.84rem}
.org-node:hover{background:var(--sa)}
.org-type{font-size:.62rem;font-weight:600;letter-spacing:.04em;text-transform:uppercase;padding:.1rem .38rem;border-radius:3px;background:var(--acl);color:var(--ac)}
.org-code{font-family:'JetBrains Mono',monospace;font-size:.72rem;color:var(--txm)}
.org-name{font-weight:500}

/* Validation cards */
.vcard{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);box-shadow:var(--sh);transition:transform .15s,box-shadow .15s;display:flex;flex-direction:column}
.vcard:hover{transform:translateY(-2px);box-shadow:var(--shm)}
.vcard.pass{border-top:3px solid var(--ok)}.vcard.fail{border-top:3px solid var(--er)}.vcard.error{border-top:3px solid var(--wa)}
.vch{padding:.85rem .95rem .5rem;display:flex;align-items:flex-start;gap:.5rem}
.vcico{font-size:1.3rem;flex-shrink:0;margin-top:.05rem}
.vccode{font-family:'JetBrains Mono',monospace;font-size:.65rem;background:var(--sa);border:1px solid var(--bd);border-radius:4px;padding:.06rem .38rem;color:var(--tx2);display:inline-block;margin-bottom:.18rem}
.vctitle{font-size:.88rem;font-weight:600}
.vcb{padding:0 .95rem .65rem;flex:1;font-size:.79rem;color:var(--tx2);line-height:1.5}
.vcf{padding:.6rem .95rem;border-top:1px solid var(--bdl);display:flex;align-items:center;justify-content:space-between}
.fnote{margin-top:.4rem;font-size:.68rem;color:var(--wa);background:var(--wab);border:1px solid var(--wad);padding:.16rem .45rem;border-radius:4px;display:inline-block}

/* Validation detail */
.dcrd{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);overflow:hidden;box-shadow:var(--sh)}
.dcrd.pass{border-left:4px solid var(--ok)}.dcrd.fail{border-left:4px solid var(--er)}.dcrd.error{border-left:4px solid var(--wa)}
.dhd{padding:1.15rem 1.4rem;border-bottom:1px solid var(--bdl);display:flex;align-items:flex-start;gap:.9rem}
.dbody{padding:1.15rem 1.4rem;display:flex;flex-direction:column;gap:.9rem}
.blbl{font-size:.64rem;font-weight:700;letter-spacing:.09em;text-transform:uppercase;margin-bottom:.3rem}
.lbiz{color:var(--in)}.ltest{color:var(--ac)}.lsql{color:#6941c6}.lres{color:var(--ok)}.liss{color:var(--wa)}
.bbiz{background:var(--inb);border:1px solid var(--ind);border-radius:var(--rs);padding:.6rem .85rem;font-size:.83rem;color:var(--tx2)}
.btest{background:var(--acl);border:1px solid #c7d6ff;border-radius:var(--rs);padding:.6rem .85rem;font-size:.83rem;color:var(--tx2)}
.bsql{background:#faf8ff;border:1px solid #e4d9ff;border-radius:var(--rs);padding:.6rem .85rem;font-family:'JetBrains Mono',monospace;font-size:.76rem;color:#3d2e6b;white-space:pre-wrap;overflow-x:auto}
.bscope{background:var(--acl);border:1px solid #c7d6ff;border-radius:6px;padding:.38rem .8rem;font-size:.76rem;color:var(--ac)}
.etag{display:inline-flex;align-items:center;background:#f0fdf4;border:1px solid var(--okd);border-radius:6px;padding:.16rem .52rem;font-size:.75rem;color:#166534;font-family:'JetBrains Mono',monospace}
.twrap{overflow-x:auto;border-radius:var(--rs);border:1px solid var(--bd)}
.twrap table thead tr{background:var(--sa)}
.twrap table th{text-align:left;padding:.48rem .65rem;font-size:.67rem;font-weight:600;color:var(--tx2);letter-spacing:.05em;border-bottom:1px solid var(--bd);white-space:nowrap}
.twrap table td{padding:.42rem .65rem;border-bottom:1px solid var(--bdl);font-family:'JetBrains Mono',monospace;font-size:.76rem}
.twrap table tr:last-child td{border-bottom:none}
.twrap table tr:hover td{background:var(--sa)}
.rcount{margin-top:.35rem;font-size:.69rem;color:var(--txm);text-align:right}
.ebox{background:var(--erb);border:1px solid var(--erd);border-radius:var(--rs);padding:.6rem .85rem;font-family:'JetBrains Mono',monospace;font-size:.76rem;color:var(--er);white-space:pre-wrap}
.ilist{list-style:none;display:flex;flex-direction:column;gap:.35rem}
.ilist li{background:var(--wab);border:1px solid var(--wad);border-radius:var(--rs);padding:.45rem .75rem;font-size:.8rem;color:#78350f;display:flex;gap:.45rem;align-items:flex-start}
.ilist li::before{content:"⚠";flex-shrink:0}
.ilist li.ok{background:var(--okb);border-color:var(--okd);color:#14532d}.ilist li.ok::before{content:"✅"}

/* Phase tabs */
.ptabs{display:flex;gap:.4rem;margin-bottom:1.4rem;flex-wrap:wrap}
.ptab{padding:.3rem .8rem;border-radius:20px;font-size:.78rem;font-weight:500;border:1px solid var(--bd);background:var(--surf);color:var(--tx2);transition:all .12s}
.ptab:hover{text-decoration:none;background:var(--sa)}
.ptab.p1.act,.ptab.p1:hover{background:#eef1ff;color:#3a6bff;border-color:#c7d6ff}
.ptab.p2.act,.ptab.p2:hover{background:#ecfdf5;color:#059669;border-color:#a7f3d0}
.ptab.p3.act,.ptab.p3:hover{background:#f5f3ff;color:#7c3aed;border-color:#ddd6fe}

/* Hero banner */
.hero{background:linear-gradient(135deg,#eef1ff,#f0f7ff);border:1px solid #d6e0ff;border-radius:var(--r);padding:1.25rem 1.5rem;margin-bottom:1.4rem;display:flex;align-items:center;gap:1.5rem;flex-wrap:wrap}
.hero h2{font-size:1.1rem;font-weight:700;margin-bottom:.2rem}
.hero p{font-size:.83rem;color:var(--tx2)}
.hstats{display:flex;gap:1.5rem;margin-left:auto;flex-shrink:0}
.hsn{font-size:1.55rem;font-weight:700;line-height:1;color:var(--ac)}
.hsl{font-size:.66rem;color:var(--txm);letter-spacing:.06em;margin-top:.18rem}
.pb-wrap{margin-bottom:1.4rem}
.pb-hd{display:flex;justify-content:space-between;font-size:.75rem;font-weight:600;margin-bottom:.35rem;color:var(--tx2)}
.pb{height:6px;background:var(--bd);border-radius:99px;overflow:hidden}
.pbf{height:100%;background:linear-gradient(90deg,#3a6bff,#7c3aed);border-radius:99px;transition:width .4s}

/* Bottom nav */
.bnav{display:flex;align-items:center;justify-content:space-between;margin-top:1.5rem;gap:.6rem;flex-wrap:wrap}
.nbtn{display:inline-flex;align-items:center;gap:.4rem;padding:.5rem .9rem;border-radius:var(--rs);border:1px solid var(--bd);background:var(--surf);font-size:.81rem;font-weight:500;color:var(--tx2);transition:all .12s;font-family:inherit}
.nbtn:hover{background:var(--acl);color:var(--ac);border-color:#c7d6ff;text-decoration:none}
.nbtn.ac{background:var(--ac);color:#fff;border-color:var(--ac)}.nbtn.ac:hover{background:var(--acd);border-color:var(--acd);color:#fff}
.nbtn.dim{opacity:.3;pointer-events:none}

/* Val overview phase cards */
.ov-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem}
@media(max-width:800px){.ov-grid{grid-template-columns:1fr}}
.ov-card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);overflow:hidden;box-shadow:var(--sh);transition:transform .15s,box-shadow .15s;display:flex;flex-direction:column}
.ov-card:hover{transform:translateY(-2px);box-shadow:var(--shm)}
.ov-ch{padding:1rem 1.15rem .55rem;display:flex;align-items:center;gap:.7rem}
.ov-num{width:34px;height:34px;border-radius:9px;display:grid;place-items:center;font-weight:700;font-size:.82rem;color:#fff;flex-shrink:0}
.ov-title{font-size:.93rem;font-weight:700;margin-bottom:.06rem}
.ov-sub{font-size:.68rem;font-weight:500;letter-spacing:.04em}
.ov-body{padding:.1rem 1.15rem .8rem;flex:1;font-size:.8rem;color:var(--tx2);line-height:1.6}
.ov-ft{padding:.65rem 1.15rem;border-top:1px solid var(--bdl);display:flex;align-items:center;justify-content:space-between}
.schema-tag{font-family:'JetBrains Mono',monospace;font-size:.66rem;padding:.08rem .42rem;border-radius:4px;background:var(--sa);border:1px solid var(--bd);color:var(--tx2)}

footer{text-align:center;padding:1.5rem;font-size:.71rem;color:var(--txm)}
"""

# ══════════════════════════════════════════════════════════════════════════════
# SHELL (sidebar + chrome)
# ══════════════════════════════════════════════════════════════════════════════
SHELL = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{{ page_title }} — Account Planning</title>
  """ + FONTS + """
  <style>{{ css | safe }}</style>
</head>
<body><div class="app">

<aside class="sidebar">
  <div class="sb-brand">
    <div class="sb-logo">AP</div>
    <div><div class="sb-appname">Account Planning</div><div class="sb-tagline">Sales Intelligence</div></div>
  </div>
  <div class="sb-user">
    <div class="sb-udot"></div>
    <div>
      <div class="sb-uname">{{ display_name }}</div>
      <span class="sb-utag">{{ tenant_code }}</span>
    </div>
  </div>
  <nav class="sb-nav">
    <a href="/" class="si{% if active=='dashboard' %} act{% endif %}"><span class="si-ico">📊</span> Dashboard</a>

    <div class="sb-sect">CRM</div>
    <a href="/org"       class="si{% if active=='org'       %} act{% endif %}"><span class="si-ico">🌳</span> Organisation</a>
    <a href="/products"  class="si{% if active=='products'  %} act{% endif %}"><span class="si-ico">📦</span> Product Catalog</a>
    <a href="/customers" class="si{% if active=='customers' %} act{% endif %}"><span class="si-ico">👥</span> Customers</a>

    <div class="sb-sect">DB Validation</div>
    <a href="/test" class="si{% if active=='validation' %} act{% endif %}"><span class="si-ico">🧪</span> Overview</a>
    {% for pn, ph in phases.items() %}
    <a href="/test/phase/{{ pn }}"
       class="si si-sub{% if active=='phase_'+(pn|string) %} act{% endif %}"
       style="--act-color:{{ ph.color }}">
      <span class="si-ico">{{ ph.icon }}</span> Phase {{ pn }} — {{ ph.title }}
    </a>
    {% endfor %}
  </nav>
  <div class="sb-footer">
    <a href="/logout" class="sb-out">↩ &nbsp;Sign out</a>
  </div>
</aside>

<main class="content">
  <div class="ci">
"""

SHELL_END = """
  </div>
</main>
</div>
</body></html>"""

def _base():
    return dict(css=CSS, phases=PHASES, **sctx())

def rp(template, active, page_title, **ctx):
    """Render a page inside the sidebar shell."""
    return render_template_string(
        SHELL + template + SHELL_END,
        active=active, page_title=page_title,
        **_base(), **ctx)

# ══════════════════════════════════════════════════════════════════════════════
# PAGE TEMPLATES
# ══════════════════════════════════════════════════════════════════════════════

# ── Login ──────────────────────────────────────────────────────────────────────
LOGIN_HTML = """\
<!DOCTYPE html><html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign In — Account Planning</title>""" + FONTS + """
<style>""" + CSS + """
body{display:grid;grid-template-columns:1.15fr .85fr;height:100vh;overflow:hidden}
@media(max-width:700px){body{grid-template-columns:1fr}.lpanel{display:none!important}}
.lpanel{background:linear-gradient(148deg,#1a2a5e,#2d1b69 55%,#1a1f3a);padding:3rem;display:flex;flex-direction:column;justify-content:center;position:relative;overflow:hidden}
.lpanel::before{content:'';position:absolute;inset:0;background:radial-gradient(ellipse at 15% 60%,rgba(99,102,241,.22),transparent 55%),radial-gradient(ellipse at 80% 20%,rgba(59,130,246,.15),transparent 50%)}
.lc{position:relative;z-index:1}
.ll{width:48px;height:48px;border-radius:13px;background:rgba(255,255,255,.11);border:1px solid rgba(255,255,255,.18);display:grid;place-items:center;font-size:20px;font-weight:800;color:#fff;margin-bottom:1.75rem}
.lt1{font-size:1.85rem;font-weight:700;color:#fff;line-height:1.2;margin-bottom:.8rem}
.lt2{font-size:.87rem;color:rgba(255,255,255,.62);line-height:1.7;max-width:360px}
.flist{margin-top:2rem;display:flex;flex-direction:column;gap:.6rem}
.fi{display:flex;align-items:center;gap:.65rem;color:rgba(255,255,255,.78);font-size:.84rem}
.fii{width:30px;height:30px;border-radius:7px;background:rgba(255,255,255,.09);border:1px solid rgba(255,255,255,.13);display:grid;place-items:center;font-size:13px;flex-shrink:0}
.hint{margin-top:2.5rem;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.13);border-radius:10px;padding:.9rem 1.15rem}
.hint h4{color:rgba(255,255,255,.85);font-size:.69rem;font-weight:700;letter-spacing:.07em;text-transform:uppercase;margin-bottom:.55rem}
.hrow{display:flex;align-items:center;gap:.45rem;margin-bottom:.3rem;font-size:.78rem;color:rgba(255,255,255,.6)}
.hval{font-family:'JetBrains Mono',monospace;color:#93c5fd;font-size:.76rem;background:rgba(255,255,255,.07);padding:.08rem .38rem;border-radius:4px}
.rpanel{display:flex;align-items:center;justify-content:center;padding:2.5rem 2rem;background:#fff}
.fcard{width:100%;max-width:380px}
.fcard h2{font-size:1.5rem;font-weight:700;margin-bottom:.3rem}
.fcard>p{font-size:.85rem;color:var(--tx2);margin-bottom:1.6rem}
.field{margin-bottom:.95rem}
.field label{display:block;font-size:.77rem;font-weight:600;color:var(--tx2);margin-bottom:.3rem}
.field input{width:100%;padding:.62rem .85rem;border:1.5px solid var(--bd);border-radius:8px;font-size:.88rem;font-family:inherit;outline:none;background:#fff;color:var(--tx);transition:border-color .14s,box-shadow .14s}
.field input:focus{border-color:var(--ac);box-shadow:0 0 0 3px rgba(58,107,255,.13)}
.fhint{font-size:.69rem;color:var(--txm);margin-top:.22rem}
.sbtn{width:100%;padding:.72rem;background:var(--ac);color:#fff;border:none;border-radius:8px;font-size:.92rem;font-weight:600;cursor:pointer;font-family:inherit;margin-top:.3rem;transition:background .13s}
.sbtn:hover{background:var(--acd)}
.errbox{background:var(--erb);border:1px solid var(--erd);border-radius:8px;padding:.55rem .85rem;font-size:.8rem;color:var(--er);margin-bottom:.9rem;display:flex;gap:.45rem}
.dmn{margin-top:1.25rem;background:var(--wab);border:1px solid var(--wad);border-radius:8px;padding:.5rem .8rem;font-size:.74rem;color:#78350f;line-height:1.5}
</style></head><body>
<div class="lpanel"><div class="lc">
  <div class="ll">AP</div>
  <div class="lt1">Account Planning<br>Intelligence Suite</div>
  <div class="lt2">Enterprise database architecture for the Agentic AI Sales &amp; Performance Assistant.</div>
  <div class="flist">
    <div class="fi"><div class="fii">📊</div>Live CRM dashboard with real database queries</div>
    <div class="fi"><div class="fii">👥</div>Customer 360° view with NBO signals</div>
    <div class="fi"><div class="fii">🧪</div>17 validation tests across 3 schema phases</div>
  </div>
  <div class="hint">
    <h4>Demo Credentials</h4>
    <div class="hrow">Company Code <span class="hval">DEMO_BANK</span></div>
    <div class="hrow">Username <span class="hval">ahmet.yilmaz</span> <span class="hval">ayse.demir</span> <span class="hval">mehmet.kaya</span></div>
  </div>
</div></div>
<div class="rpanel"><div class="fcard">
  <h2>Welcome back</h2>
  <p>Sign in to access the Account Planning suite.</p>
  {% if error %}<div class="errbox">⚠&nbsp; {{ error }}</div>{% endif %}
  <form method="POST" action="/login" autocomplete="on">
    <div class="field">
      <label for="tc">Company Code</label>
      <input id="tc" name="tenant_code" type="text" placeholder="e.g. DEMO_BANK"
             value="{{ request.form.get('tenant_code','') }}" required autofocus
             style="text-transform:uppercase;letter-spacing:.04em">
      <div class="fhint">Your organisation's unique tenant identifier.</div>
    </div>
    <div class="field">
      <label for="un">Username</label>
      <input id="un" name="username" type="text" placeholder="e.g. ahmet.yilmaz"
             value="{{ request.form.get('username','') }}" required>
    </div>
    <button class="sbtn" type="submit">Sign In →</button>
    <div class="dmn">⚠ <strong>Demo mode</strong> — any active username + valid company code grants access.</div>
  </form>
</div></div>
</body></html>"""

# ── Dashboard ──────────────────────────────────────────────────────────────────
DASHBOARD = """
<div class="ph-row">
  <div><h1>Dashboard</h1><p>Live overview of {{ tenant_name }}. All data queried directly from PostgreSQL.</p></div>
</div>

<div class="stats-row">
  <div class="stat-card"><div class="stat-ico">👥</div><div class="stat-val">{{ stats.customers }}</div><div class="stat-lbl">Customers</div></div>
  <div class="stat-card"><div class="stat-ico">📦</div><div class="stat-val">{{ stats.products }}</div><div class="stat-lbl">Active Products</div></div>
  <div class="stat-card"><div class="stat-ico">👤</div><div class="stat-val">{{ stats.employees }}</div><div class="stat-lbl">Active RMs</div></div>
  <div class="stat-card"><div class="stat-ico">🧩</div><div class="stat-val">{{ stats.modules }}</div><div class="stat-lbl">Enabled Modules</div></div>
</div>

<div class="g3" style="margin-bottom:1rem">
  <div class="insight-card">
    <div class="ic-label">Customer Mix</div>
    {% for row in stats.cust_types %}
    <div class="ic-row">
      <span class="ic-key">
        {% if row.customer_type=='corporate' %}<span class="chip ch-corp">Corporate</span>
        {% elif row.customer_type=='sme' %}<span class="chip ch-sme">SME</span>
        {% else %}<span class="chip ch-ind">Individual</span>{% endif %}
      </span>
      <span class="ic-val">{{ row.count }}</span>
    </div>
    {% endfor %}
  </div>

  <div class="insight-card">
    <div class="ic-label">Current Reporting Period</div>
    {% for row in stats.curr_period %}
    <div class="ic-row"><span class="ic-key">{{ row.period_label }}</span><span class="ic-val">{{ row.period_name }}</span></div>
    <div class="ic-row"><span class="ic-key">Fiscal Year</span><span class="ic-val">{{ row.fiscal_year }}</span></div>
    <div class="ic-row"><span class="ic-key">Quarter</span><span class="ic-val">Q{{ row.fiscal_quarter }}</span></div>
    <div class="ic-row"><span class="ic-key">Status</span><span class="ic-val chip ch-active">Active</span></div>
    {% endfor %}
  </div>

  <div class="insight-card">
    <div class="ic-label">DB Validation Status</div>
    {% for pn, ph in phases.items() %}
    <div class="ic-row">
      <span class="ic-key">{{ ph.icon }} Phase {{ pn }}</span>
      <a href="/test/phase/{{ pn }}" style="font-size:.76rem;color:{{ ph.color }};font-weight:600">Run →</a>
    </div>
    {% endfor %}
    <div style="margin-top:.5rem;font-size:.72rem;color:var(--txm)">17 total tests · 3 phases</div>
  </div>
</div>

<div class="insight-card" style="margin-bottom:1rem">
  <div class="ic-label">⚡ At-Risk Customers — NBO Signals (from Customer 360 Cache)</div>
  {% if stats.nbo %}
  <table class="main" style="margin-top:.4rem">
    <thead><tr><th>Customer</th><th>Type</th><th>Tier</th><th>Churn Score</th><th>Next Best Offer</th><th>Cache Source</th></tr></thead>
    <tbody>
    {% for r in stats.nbo %}
    <tr onclick="window.location='/customers/{{ r.id }}'">
      <td style="font-weight:500">{{ r.name }}</td>
      <td>
        {% if r.customer_type=='corporate' %}<span class="chip ch-corp">Corporate</span>
        {% elif r.customer_type=='sme' %}<span class="chip ch-sme">SME</span>
        {% else %}<span class="chip ch-ind">Individual</span>{% endif %}
      </td>
      <td>{{ r.tier or '—' }}</td>
      <td>
        {% set cs = r.churn_score | float %}
        <span style="font-weight:600;color:{% if cs >= 0.12 %}var(--er){% elif cs >= 0.07 %}var(--wa){% else %}var(--ok){% endif %}">{{ cs }}</span>
      </td>
      <td><code>{{ r.nbo or '—' }}</code></td>
      <td><span class="chip ch-active">{{ r.refresh_source }}</span></td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}<p style="font-size:.82rem;color:var(--txm);margin-top:.4rem">No NBO cache entries found.</p>{% endif %}
</div>
"""

# ── Customers list ─────────────────────────────────────────────────────────────
CUSTOMERS = """
<div class="ph-row">
  <div><h1>Customers</h1><p>{{ rows | length }} active customers — {{ tenant_name }}</p></div>
</div>
{% if err %}<div style="background:var(--erb);border:1px solid var(--erd);border-radius:8px;padding:.6rem .9rem;font-size:.82rem;color:var(--er);margin-bottom:1rem">⚠ {{ err }}</div>{% endif %}
<div class="dtw">
  <div class="dt-hd"><span class="dt-title">Customer Directory</span><span class="dt-cnt">{{ rows | length }} records</span></div>
  <table class="main">
    <thead><tr><th>Name</th><th>Type</th><th>Ext. ID</th><th>Tier</th><th>Primary RM</th><th>Products</th><th>Credit Rating</th></tr></thead>
    <tbody>
    {% for r in rows %}
    <tr onclick="window.location='/customers/{{ r.id }}'">
      <td style="font-weight:500">{{ r.name }}</td>
      <td>{% if r.customer_type=='corporate' %}<span class="chip ch-corp">Corporate</span>
          {% elif r.customer_type=='sme' %}<span class="chip ch-sme">SME</span>
          {% else %}<span class="chip ch-ind">Individual</span>{% endif %}</td>
      <td><code style="font-size:.74rem">{{ r.external_id }}</code></td>
      <td>{{ r.tier or '—' }}</td>
      <td>{{ r.rm_name or '—' }}</td>
      <td><span style="font-weight:600">{{ r.product_count }}</span></td>
      <td>{{ r.credit_rating or '—' }}</td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
</div>
"""

# ── Customer detail ────────────────────────────────────────────────────────────
CUSTOMER_DETAIL = """
<div class="bc">
  <a href="/customers">Customers</a><span class="bc-sep">/</span>
  <span>{{ c.name }}</span>
</div>
<div class="c360-header">
  <div style="display:flex;align-items:center;gap:.75rem;flex-wrap:wrap">
    <div>
      <div class="c360-name">{{ c.name }}</div>
      <div class="c360-meta">
        {% if c.customer_type=='corporate' %}<span class="chip ch-corp">Corporate</span>
        {% elif c.customer_type=='sme' %}<span class="chip ch-sme">SME</span>
        {% else %}<span class="chip ch-ind">Individual</span>{% endif %}
        <span>·</span><code style="font-size:.78rem">{{ c.external_id }}</code>
        {% if c.contact_email %}<span>·</span><span>{{ c.contact_email }}</span>{% endif %}
        {% if c.rm_name %}<span>·</span><span>RM: <strong>{{ c.rm_name }}</strong></span>{% endif %}
      </div>
    </div>
    <div style="margin-left:auto">
      {% if c.tier %}<div class="pill p-ac" style="font-size:.78rem">{{ c.tier }}</div>{% endif %}
    </div>
  </div>
</div>

<div class="c360-body" style="margin-bottom:1rem">
  <div>
    <div class="card" style="padding:1rem 1.15rem;margin-bottom:1rem">
      <div class="ic-label" style="margin-bottom:.55rem">Profile</div>
      <div class="kv"><span class="kv-k">External ID</span><span class="kv-v"><code>{{ c.external_id }}</code></span></div>
      <div class="kv"><span class="kv-k">Type</span><span class="kv-v">{{ c.customer_type }}</span></div>
      {% if c.credit_rating %}<div class="kv"><span class="kv-k">Credit Rating</span><span class="kv-v">{{ c.credit_rating }}</span></div>{% endif %}
      {% if c.sector %}<div class="kv"><span class="kv-k">Sector</span><span class="kv-v">{{ c.sector }}</span></div>{% endif %}
      {% if c.contact_email %}<div class="kv"><span class="kv-k">Email</span><span class="kv-v">{{ c.contact_email }}</span></div>{% endif %}
      {% if c.contact_phone %}<div class="kv"><span class="kv-k">Phone</span><span class="kv-v">{{ c.contact_phone }}</span></div>{% endif %}
    </div>

    {% if products %}
    <div class="dtw">
      <div class="dt-hd"><span class="dt-title">Product Holdings</span><span class="dt-cnt">{{ products | length }}</span></div>
      <table class="main">
        <thead><tr><th>Product</th><th>Status</th><th>Since</th></tr></thead>
        <tbody>
          {% for p in products %}
          <tr><td><code style="font-size:.77rem">{{ p.product_code }}</code> {{ p.product_name }}</td>
            <td><span class="chip ch-active">{{ p.status }}</span></td>
            <td style="font-size:.79rem;color:var(--tx2)">{{ p.start_date }}</td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
    {% endif %}
  </div>

  <div>
    {% if cache %}
    <div class="nbo-box" style="margin-bottom:1rem">
      <div class="nbo-label">🤖 Next Best Offer</div>
      <div class="nbo-val">{{ cache.nbo or 'No recommendation' }}</div>
      <div style="font-size:.75rem;color:var(--tx2);margin-bottom:.4rem">Churn Risk Score</div>
      <div style="font-size:1.1rem;font-weight:700;color:{% set cs=cache.churn_score|float %}{% if cs>=0.12 %}var(--er){% elif cs>=0.07 %}var(--wa){% else %}var(--ok){% endif %}">
        {{ cache.churn_score }}
      </div>
      <div class="churn-bar" style="margin-top:.35rem">
        <div class="churn-fill {% set cs=cache.churn_score|float %}{% if cs>=0.12 %}churn-hi{% elif cs>=0.07 %}churn-med{% else %}churn-low{% endif %}"
             style="width:{{ (cache.churn_score|float * 100)|int }}%"></div>
      </div>
    </div>

    <div class="card" style="padding:1rem 1.15rem">
      <div class="ic-label" style="margin-bottom:.55rem">360° Snapshot</div>
      {% if cache.tier %}<div class="kv"><span class="kv-k">Tier</span><span class="kv-v">{{ cache.tier }}</span></div>{% endif %}
      {% if cache.lifecycle %}<div class="kv"><span class="kv-k">Lifecycle</span><span class="kv-v">{{ cache.lifecycle }}</span></div>{% endif %}
      {% if cache.total_products %}<div class="kv"><span class="kv-k">Total Products</span><span class="kv-v">{{ cache.total_products }}</span></div>{% endif %}
      {% if cache.refresh_source %}<div class="kv"><span class="kv-k">Cache Source</span><span class="kv-v"><span class="chip ch-active">{{ cache.refresh_source }}</span></span></div>{% endif %}
      {% if cache.open_actions %}<div class="kv"><span class="kv-k">Open Actions</span><span class="kv-v">{{ cache.open_actions }}</span></div>{% endif %}
    </div>
    {% else %}
    <div class="card" style="padding:1rem 1.15rem">
      <div class="ic-label" style="margin-bottom:.4rem">360° Snapshot</div>
      <div style="font-size:.82rem;color:var(--txm)">No cache entry for this customer yet. Run the analytics pipeline to generate a snapshot.</div>
    </div>
    {% endif %}
  </div>
</div>
"""

# ── Products ───────────────────────────────────────────────────────────────────
PRODUCTS = """
<div class="ph-row">
  <div><h1>Product Catalog</h1><p>{{ total_products }} active products across {{ total_cats }} categories — {{ tenant_name }}</p></div>
</div>
{% if err %}<div style="background:var(--erb);border:1px solid var(--erd);border-radius:8px;padding:.6rem .9rem;font-size:.82rem;color:var(--er);margin-bottom:1rem">⚠ {{ err }}</div>{% endif %}

{% for cat in categories %}
<div class="cat-section">
  <div class="cat-hd">
    <span>{{ cat.icon }}</span>
    <span>{{ cat.name }}</span>
    <span style="font-size:.72rem;color:var(--txm);font-weight:400">({{ cat.products | length }} product{{ 's' if cat.products|length != 1 else '' }})</span>
  </div>
  {% if cat.products %}
  <div class="prod-cards">
    {% for p in cat.products %}
    <div class="prod-card">
      <div class="prod-code">{{ p.code }}</div>
      <div class="prod-name">{{ p.name }}</div>
      <div class="prod-desc">{{ p.description or '' }}</div>
      <div style="margin-top:.5rem;display:flex;gap:.35rem;flex-wrap:wrap">
        <span class="chip ch-active">{{ p.lifecycle_status }}</span>
      </div>
    </div>
    {% endfor %}
  </div>
  {% else %}
  <div style="font-size:.81rem;color:var(--txm);padding:.3rem 0">No products in this category.</div>
  {% endif %}
  {% if cat.subcategories %}
  {% for sub in cat.subcategories %}
  <div style="margin-top:.9rem;margin-left:1rem">
    <div style="font-size:.82rem;font-weight:600;color:var(--tx2);margin-bottom:.5rem;display:flex;align-items:center;gap:.4rem">
      <span style="color:var(--txm)">↳</span> {{ sub.name }}
      <span style="font-size:.7rem;color:var(--txm);font-weight:400">({{ sub.products|length }})</span>
    </div>
    <div class="prod-cards">
      {% for p in sub.products %}
      <div class="prod-card">
        <div class="prod-code">{{ p.code }}</div>
        <div class="prod-name">{{ p.name }}</div>
        <div class="prod-desc">{{ p.description or '' }}</div>
        <span class="chip ch-active" style="margin-top:.4rem;display:inline-block">{{ p.lifecycle_status }}</span>
      </div>
      {% endfor %}
    </div>
  </div>
  {% endfor %}
  {% endif %}
</div>
{% endfor %}
"""

# ── Org ────────────────────────────────────────────────────────────────────────
ORG = """
<div class="ph-row">
  <div><h1>Organisation</h1><p>Org hierarchy for {{ tenant_name }} — {{ node_count }} units</p></div>
</div>
{% if err %}<div style="background:var(--erb);border:1px solid var(--erd);border-radius:8px;padding:.6rem .9rem;font-size:.82rem;color:var(--er);margin-bottom:1rem">⚠ {{ err }}</div>{% endif %}
<div class="org-tree">
{% for node in nodes %}
<div class="org-node" style="margin-left:{{ node.depth * 1.5 }}rem">
  <span style="font-size:1.05rem">{{ node.icon }}</span>
  <span class="org-name">{{ node.name }}</span>
  <span class="org-code">{{ node.code }}</span>
  <span class="org-type">{{ node.unit_type }}</span>
</div>
{% endfor %}
</div>
"""

# ── Validation overview ────────────────────────────────────────────────────────
VAL_OVERVIEW = """
<div class="ph-row">
  <div><h1>DB Validation</h1><p>Phase-by-phase validation of the Account Planning schema against live PostgreSQL.</p></div>
  <div style="font-size:.8rem;color:var(--txm)">{{ total_tests }} tests · {{ total_phases }} phases</div>
</div>
<div class="ov-grid">
  {% for ph in phase_list %}
  <div class="ov-card" style="border-top:3px solid {{ ph.color }}">
    <div class="ov-ch">
      <div class="ov-num" style="background:{{ ph.color }}">{{ ph.icon }}</div>
      <div>
        <div class="ov-title">Phase {{ ph.num }} — {{ ph.title }}</div>
        <div class="ov-sub" style="color:{{ ph.color }}">{{ ph.sub }}</div>
      </div>
    </div>
    <div class="ov-body">
      {{ ph.description }}
      <div style="display:flex;gap:.35rem;flex-wrap:wrap;margin-top:.5rem">
        {% for s in ph.schemas %}<span class="schema-tag">{{ s }}</span>{% endfor %}
      </div>
    </div>
    <div class="ov-ft">
      <span style="font-size:.7rem;color:var(--txm)">{{ ph.tests | length }} tests</span>
      <a href="/test/phase/{{ ph.num }}" style="font-size:.79rem;font-weight:600;color:{{ ph.color }}">Run Tests →</a>
    </div>
  </div>
  {% endfor %}
</div>
"""

# ── Validation phase ───────────────────────────────────────────────────────────
VAL_PHASE = """
<div class="bc">
  <a href="/test">Validation</a><span class="bc-sep">/</span>
  <span style="color:{{ phase.color }};font-weight:600">Phase {{ phase.num }} — {{ phase.title }}</span>
  <span style="margin-left:auto;font-size:.73rem;color:var(--txm)">{{ passed }}/{{ total }} passing</span>
</div>
<div class="ptabs">
  {% for pn, ph in phases.items() %}
  <a href="/test/phase/{{ pn }}" class="ptab p{{ pn }}{% if pn==phase.num %} act{% endif %}">
    {{ ph.icon }} Phase {{ pn }} — {{ ph.title }}
  </a>
  {% endfor %}
</div>
<div class="hero" style="background:{{ bg_from }};border-color:{{ bd_color }}">
  <div><h2>Phase {{ phase.num }} — {{ phase.title }}</h2><p>{{ phase.description }}</p></div>
  <div class="hstats">
    <div style="text-align:center"><div class="hsn" style="color:{{ phase.color }}">{{ total }}</div><div class="hsl">TESTS</div></div>
    <div style="text-align:center"><div class="hsn" style="color:var(--ok)">{{ passed }}</div><div class="hsl">PASSED</div></div>
    <div style="text-align:center"><div class="hsn" style="color:var(--er)">{{ failed }}</div><div class="hsl">FAILED</div></div>
  </div>
</div>
<div class="pb-wrap">
  <div class="pb-hd"><span>Phase {{ phase.num }} Progress</span><span style="color:{{ phase.color }}">{{ pct }}% passing</span></div>
  <div class="pb"><div class="pbf" style="width:{{ pct }}%;background:{{ phase.color }}"></div></div>
</div>
<div class="g3">
  {% for r in results %}
  <a href="/test/{{ r.id }}" style="display:contents;text-decoration:none">
    <div class="vcard {{ r.status }}">
      <div class="vch">
        <div class="vcico">{{ r.icon }}</div>
        <div style="flex:1">
          <div class="vccode">{{ r.code }}</div>
          <div class="vctitle">{{ r.title }}</div>
        </div>
        <div class="pill {% if r.status=='pass' %}p-pass{% elif r.status=='fail' %}p-fail{% else %}p-warn{% endif %}">
          {% if r.status=='pass' %}✅{% elif r.status=='fail' %}❌{% else %}⚠{% endif %}
        </div>
      </div>
      <div class="vcb">
        {{ r.short_desc }}
        {% if r.fixture_note %}<div class="fnote">📌 {{ r.fixture_note }}</div>{% endif %}
      </div>
      <div class="vcf">
        <span style="font-size:.69rem;color:var(--txm)">{% if r.error %}Error{% elif r.row_count %}{{ r.row_count }} row{{ 's' if r.row_count!=1 else '' }}{% else %}No rows{% endif %}</span>
        <span style="font-size:.78rem;font-weight:600;color:var(--ac)">View →</span>
      </div>
    </div>
  </a>
  {% endfor %}
</div>
"""

# ── Validation detail ──────────────────────────────────────────────────────────
VAL_DETAIL = """
<div class="bc">
  <a href="/test">Validation</a><span class="bc-sep">/</span>
  <a href="/test/phase/{{ phase_num }}" style="color:{{ phase_color }}">Phase {{ phase_num }} — {{ phase_title }}</a>
  <span class="bc-sep">/</span><span>{{ test.code }}</span>
  <span style="margin-left:auto;font-size:.72rem;color:var(--txm)">{{ test_num }} of {{ total_tests }}</span>
</div>
{% if test.fixture_note %}
<div style="background:var(--wab);border:1px solid var(--wad);border-radius:8px;padding:.5rem .9rem;font-size:.77rem;color:#78350f;margin-bottom:1rem">
  📌 <strong>Demo Fixture:</strong> {{ test.fixture_note }}
</div>
{% endif %}
<div class="dcrd {{ status }}">
  <div class="dhd">
    <div style="display:flex;align-items:center;gap:.7rem;flex:1">
      <span style="font-size:1.5rem">{{ test.icon }}</span>
      <div>
        <div class="vccode" style="margin-bottom:.2rem">{{ test.code }}</div>
        <div style="font-size:1.05rem;font-weight:600">{{ test.title }}</div>
      </div>
    </div>
    <div class="pill {% if status=='pass' %}p-pass{% elif status=='fail' %}p-fail{% else %}p-warn{% endif %}" style="font-size:.77rem;padding:.28rem .8rem">
      {% if status=='pass' %}✅ PASS{% elif status=='fail' %}❌ FAIL{% else %}⚠ ERROR{% endif %}
      &nbsp;·&nbsp; {{ row_count }} row{{ 's' if row_count!=1 else '' }}
    </div>
  </div>
  <div class="dbody">
    <div><div class="blbl lbiz">📋 Business Requirement</div><div class="bbiz">{{ test.business_req }}</div></div>
    <div><div class="blbl ltest">🔍 What This Test Validates</div><div class="btest">{{ test.what_we_test | safe }}</div></div>
    {% if test.params_type=='tenant_id' %}
    <div class="bscope">🔒 <strong>Tenant-scoped:</strong> Query filtered to your session tenant · <code>{{ tenant_code }}</code> ({{ tenant_name }})</div>
    {% endif %}
    <div><div class="blbl lsql">🗄 Query</div><div class="bsql">{{ test.sql }}</div></div>
    <div>
      <span class="blbl lres">🎯 Expected:</span>&nbsp;
      <span class="etag">{{ test.expected }}</span>
      <span style="font-size:.69rem;color:var(--txm);margin-left:.55rem">· run at {{ ts }}</span>
    </div>
    <div>
      <div class="blbl lres">📊 Result</div>
      {% if err %}<div class="ebox">{{ err }}</div>
      {% elif rows %}
      <div class="twrap">
        <table><thead><tr>{% for c in cols %}<th>{{ c }}</th>{% endfor %}</tr></thead>
        <tbody>{% for row in rows %}<tr>{% for c in cols %}
          <td><span class="{{ row[c].cls }}">{{ row[c].d }}</span></td>
        {% endfor %}</tr>{% endfor %}</tbody></table>
      </div>
      <div class="rcount">{{ row_count }} row{{ 's' if row_count!=1 else '' }} returned</div>
      {% else %}<div style="color:var(--txm);font-size:.83rem;padding:.35rem 0">(no rows returned)</div>{% endif %}
    </div>
    <div>
      <div class="blbl liss">⚡ Issues & Improvement Areas</div>
      <ul class="ilist">
        {% for issue in test.issues %}
        <li class="{% if '✅' in issue %}ok{% endif %}">{{ issue | safe }}</li>
        {% endfor %}
      </ul>
    </div>
  </div>
</div>
<div class="bnav">
  {% if prev_test %}<a href="/test/{{ prev_test.id }}" class="nbtn">← {{ prev_test.code }} · {{ prev_test.title }}</a>
  {% else %}<span class="nbtn dim">← Previous</span>{% endif %}
  <a href="/test/phase/{{ phase_num }}" class="nbtn" style="color:{{ phase_color }}">↑ Phase {{ phase_num }}: {{ phase_title }}</a>
  {% if next_test %}<a href="/test/{{ next_test.id }}" class="nbtn ac">{{ next_test.code }} · {{ next_test.title }} →</a>
  {% else %}<span class="nbtn dim">Next →</span>{% endif %}
</div>
"""

# ══════════════════════════════════════════════════════════════════════════════
# DATA HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def get_stats():
    t = tid()
    def count(sql): return (qone(sql,(t,)) or {}).get("count", 0)
    customers = count("SELECT count(*)::int FROM customer.customer WHERE tenant_id=%s AND deleted_at IS NULL")
    products  = count("SELECT count(*)::int FROM product.product WHERE tenant_id=%s AND is_active=true")
    employees = count("SELECT count(*)::int FROM core.employee WHERE tenant_id=%s AND status='active'")
    modules   = count("SELECT count(*)::int FROM core.tenant_module WHERE tenant_id=%s AND is_enabled=true")

    _, ct, _  = qry("SELECT customer_type,count(*)::int FROM customer.customer WHERE tenant_id=%s AND deleted_at IS NULL GROUP BY customer_type ORDER BY customer_type", (t,), raw=True)
    _, cp, _  = qry("SELECT period_label,period_name,fiscal_year,fiscal_quarter FROM core.reporting_period WHERE tenant_id=%s AND is_current=true AND period_type='monthly' LIMIT 1", (t,), raw=True)
    _, nbo, _ = qry("""
        SELECT c.id::text,c.name,c.customer_type,
               cache.segment_summary->>'primary_tier' AS tier,
               cache.analytics_summary->>'nbo' AS nbo,
               (cache.analytics_summary->>'churn_score') AS churn_score,
               cache.refresh_source
        FROM customer.customer_360_cache cache
        JOIN customer.customer c ON c.id=cache.customer_id
        WHERE c.tenant_id=%s
        ORDER BY (cache.analytics_summary->>'churn_score')::numeric DESC""", (t,), raw=True)

    return dict(customers=customers,products=products,employees=employees,modules=modules,
                cust_types=ct,curr_period=cp,nbo=nbo)

def get_customers_list():
    t = tid()
    _, rows, err = qry("""
        SELECT c.id::text,c.name,c.customer_type,c.external_id,
               c.risk_profile->>'credit_rating' AS credit_rating,
               cs.segment_code AS tier,
               u.display_name AS rm_name,
               count(DISTINCT cp.id)::int AS product_count
        FROM customer.customer c
        LEFT JOIN customer.customer_segment cs   ON cs.customer_id=c.id AND cs.segment_type='tier' AND cs.effective_until IS NULL
        LEFT JOIN customer.customer_assignment ca ON ca.customer_id=c.id AND ca.assignment_type='primary' AND ca.effective_until IS NULL
        LEFT JOIN core.employee e ON e.id=ca.employee_id
        LEFT JOIN core.user_ u   ON u.id=e.user_id
        LEFT JOIN customer.customer_product cp   ON cp.customer_id=c.id AND cp.status='active'
        WHERE c.tenant_id=%s AND c.deleted_at IS NULL
        GROUP BY c.id,c.name,c.customer_type,c.external_id,c.risk_profile,cs.segment_code,u.display_name
        ORDER BY c.customer_type,c.name""", (t,), raw=True)
    return rows, err

def get_customer_detail(cid):
    t = tid()
    c = qone("""
        SELECT c.id::text,c.name,c.customer_type,c.external_id,
               c.contact_email,c.contact_phone,
               c.risk_profile->>'credit_rating' AS credit_rating,
               c.risk_profile->>'sector'        AS sector,
               cs.segment_code AS tier,
               u.display_name AS rm_name
        FROM customer.customer c
        LEFT JOIN customer.customer_segment cs ON cs.customer_id=c.id AND cs.segment_type='tier' AND cs.effective_until IS NULL
        LEFT JOIN customer.customer_assignment ca ON ca.customer_id=c.id AND ca.assignment_type='primary' AND ca.effective_until IS NULL
        LEFT JOIN core.employee e ON e.id=ca.employee_id
        LEFT JOIN core.user_ u   ON u.id=e.user_id
        WHERE c.id=%s AND c.tenant_id=%s LIMIT 1""", (cid, t))
    if not c:
        return None, [], None

    _, prods, _ = qry("""
        SELECT p.code AS product_code,p.name AS product_name,cp.status,cp.start_date::text
        FROM customer.customer_product cp
        JOIN product.product p ON p.id=cp.product_id
        WHERE cp.customer_id=%s AND cp.tenant_id=%s ORDER BY cp.start_date""", (cid, t), raw=True)

    cache_raw = qone("""
        SELECT segment_summary->>'primary_tier' AS tier,
               segment_summary->>'lifecycle'    AS lifecycle,
               analytics_summary->>'nbo'        AS nbo,
               analytics_summary->>'churn_score' AS churn_score,
               analytics_summary->>'model_version' AS model_version,
               product_summary->>'total_products'  AS total_products,
               action_summary->>'open_actions'     AS open_actions,
               refresh_source
        FROM customer.customer_360_cache WHERE customer_id=%s""", (cid,))

    return c, prods, cache_raw

def get_products():
    t = tid()
    # Fetch all categories + products
    _, cats, err = qry("""
        SELECT c.id::text,c.code,c.name,c.level,c.parent_id::text,
               p.code AS pcode,p.name AS pname,p.description,p.lifecycle_status
        FROM product.category c
        LEFT JOIN product.product p ON p.category_id=c.id AND p.tenant_id=%s AND p.is_active=true
        WHERE c.tenant_id=%s ORDER BY c.level,c.display_order,p.code""", (t,t), raw=True)

    level1_icons = {"LOANS":"💰","DEPOSITS":"🏦","CARDS":"💳","INSURANCE":"🛡","FINANCIAL":"📁"}
    # Build structure: level 1 as parent, level 2 as sub
    l1 = {}  # id → cat dict
    l2 = {}  # id → cat dict
    for r in cats:
        if r["level"] == 1:
            if r["id"] not in l1:
                l1[r["id"]] = {"name":r["name"],"code":r["code"],"icon":level1_icons.get(r["code"],"📂"),"products":[],"subcategories":[]}
        if r["level"] == 2:
            if r["id"] not in l2:
                l2[r["id"]] = {"name":r["name"],"code":r["code"],"parent_id":r["parent_id"],"products":[]}

    for r in cats:
        if r["pcode"] is None:
            continue
        prod = {"code":r["pcode"],"name":r["pname"],"description":r["description"],"lifecycle_status":r["lifecycle_status"]}
        if r["level"] == 1 and r["id"] in l1:
            if not any(p["code"]==prod["code"] for p in l1[r["id"]]["products"]):
                l1[r["id"]]["products"].append(prod)
        elif r["level"] == 2 and r["id"] in l2:
            if not any(p["code"]==prod["code"] for p in l2[r["id"]]["products"]):
                l2[r["id"]]["products"].append(prod)

    # Attach subcategories to their L1 parent
    for sid, sub in l2.items():
        pid = sub["parent_id"]
        if pid in l1:
            if not any(s["code"]==sub["code"] for s in l1[pid]["subcategories"]):
                l1[pid]["subcategories"].append(sub)

    categories = list(l1.values())
    total_products = sum(len(c["products"]) + sum(len(s["products"]) for s in c["subcategories"]) for c in categories)
    return categories, total_products, len(l1)+len(l2), err

def get_org():
    t = tid()
    _, rows, err = qry("SELECT id::text,code,name,unit_type,level,parent_id::text FROM core.org_unit WHERE tenant_id=%s ORDER BY level,code", (t,), raw=True)
    icons = {"company":"🏦","lob":"🏛","region":"🗺","area":"🏙","branch":"🏢","team":"👥"}
    # Build tree, then flatten
    node_map = {r["id"]: {**r, "children": []} for r in rows}
    roots = []
    for r in rows:
        n = node_map[r["id"]]
        n["icon"] = icons.get(r["unit_type"], "📋")
        if r["parent_id"] is None:
            roots.append(n)
        elif r["parent_id"] in node_map:
            node_map[r["parent_id"]]["children"].append(n)

    def flatten(nodes, depth=0):
        res = []
        for n in nodes:
            res.append({**n, "depth": depth})
            res.extend(flatten(n["children"], depth + 1))
        return res

    return flatten(roots), len(rows), err

# ══════════════════════════════════════════════════════════════════════════════
# ROUTES
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/login", methods=["GET","POST"])
def login():
    if "user_id" in session:
        return redirect("/")
    error = None
    if request.method == "POST":
        tc = request.form.get("tenant_code","").strip()
        un = request.form.get("username","").strip()
        if not tc or not un:
            error = "Please enter both Company Code and Username."
        else:
            u = authenticate(tc, un)
            if u:
                session.update({"user_id":str(u["id"]),"display_name":u["display_name"],
                                "user_type":u["user_type"],"username":u["username"],
                                "tenant_id":str(u["tenant_id"]),"tenant_code":u["tenant_code"],
                                "tenant_name":u["tenant_name"]})
                return redirect("/")
            else:
                error = "No active account found for that Company Code and Username."
    return render_template_string(LOGIN_HTML, error=error)

@app.route("/logout")
def logout():
    session.clear()
    return redirect("/login")

@app.route("/")
@login_required
def dashboard():
    stats = get_stats()
    return rp(DASHBOARD, "dashboard", "Dashboard", stats=stats)

@app.route("/customers")
@login_required
def customers():
    rows, err = get_customers_list()
    return rp(CUSTOMERS, "customers", "Customers", rows=rows, err=err)

@app.route("/customers/<cid>")
@login_required
def customer_detail(cid):
    c, products, cache = get_customer_detail(cid)
    if not c:
        return redirect("/customers")
    return rp(CUSTOMER_DETAIL, "customers", f"{c['name']} — Customer 360",
              c=c, products=products, cache=cache)

@app.route("/products")
@login_required
def products():
    categories, total_products, total_cats, err = get_products()
    return rp(PRODUCTS, "products", "Product Catalog",
              categories=categories, total_products=total_products, total_cats=total_cats, err=err)

@app.route("/org")
@login_required
def org():
    nodes, node_count, err = get_org()
    return rp(ORG, "org", "Organisation", nodes=nodes, node_count=node_count, err=err)

# ── Validation (now under /test/) ─────────────────────────────────────────────
@app.route("/test")
@login_required
def val_overview():
    total = sum(len(ph["tests"]) for ph in PHASES.values())
    return rp(VAL_OVERVIEW, "validation", "DB Validation",
              phase_list=list(PHASES.values()), total_tests=total, total_phases=len(PHASES))

@app.route("/test/phase/<int:pnum>")
@login_required
def val_phase(pnum):
    phase = PHASES.get(pnum)
    if not phase:
        return redirect("/test")
    t = tid()
    results = []
    for test in phase["tests"]:
        params = (t,) if test.get("params_type")=="tenant_id" else None
        cols, rows, err = qry(test["sql"], params)
        status = "error" if err else ("pass" if rows else "fail")
        results.append({**test, "status":status, "row_count":len(rows), "error":err})

    total  = len(results)
    passed = sum(1 for r in results if r["status"]=="pass")
    colors = {1:("#eef1ff","#d6e0ff"),2:("#ecfdf5","#a7f3d0"),3:("#f5f3ff","#ddd6fe")}
    bg_from, bd_color = colors.get(pnum, ("#eef1ff","#d6e0ff"))

    return rp(VAL_PHASE, f"phase_{pnum}", f"Phase {pnum} — {phase['title']}",
              phase=phase, results=results, total=total, passed=passed,
              failed=total-passed, pct=round(passed/total*100) if total else 0,
              bg_from=bg_from, bd_color=bd_color)

@app.route("/test/<test_id>")
@login_required
def val_test(test_id):
    entry = TEST_MAP.get(test_id)
    if not entry:
        return redirect("/test")
    test = entry["test"]; pnum = entry["phase_num"]; phase = entry["phase"]
    phase_tests = phase["tests"]
    idx  = [t["id"] for t in phase_tests].index(test_id)
    prev_t = phase_tests[idx-1] if idx > 0 else None
    next_t = phase_tests[idx+1] if idx < len(phase_tests)-1 else None

    t = tid()
    params = (t,) if test.get("params_type")=="tenant_id" else None
    raw_cols, raw_rows, err = qry(test["sql"], params)
    status = "error" if err else ("pass" if raw_rows else "fail")
    rows = []
    if raw_rows:
        for r in [dict(x) for x in raw_rows]:
            d, cls = fmt_cell(list(r.values())[0])
            rows.append({c: {"d": fmt_cell(r[c])[0], "cls": fmt_cell(r[c])[1]} for c in raw_cols})

    return rp(VAL_DETAIL, f"phase_{pnum}", f"{test['code']} — {test['title']}",
              test=test, cols=raw_cols, rows=rows, row_count=len(rows if rows else raw_rows),
              err=err, status=status, prev_test=prev_t, next_test=next_t,
              test_num=idx+1, total_tests=len(phase_tests),
              phase_num=pnum, phase_title=phase["title"], phase_color=phase["color"],
              ts=datetime.now().strftime("%H:%M:%S"))

# Legacy redirects from old URL scheme
@app.route("/tests")
@login_required
def legacy_tests():
    return redirect("/test")

@app.route("/phase/<int:n>")
@login_required
def legacy_phase(n):
    return redirect(f"/test/phase/{n}")

# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    total = sum(len(ph["tests"]) for ph in PHASES.values())
    print(f"▶  Account Planning Demo   →  http://127.0.0.1:5050")
    print(f"   Dashboard · Customers · Products · Org · {total} validation tests")
    app.run(host="0.0.0.0", port=5050, debug=False, reload=True)
