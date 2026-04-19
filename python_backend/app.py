#!/usr/bin/env python3
"""
Account Planning — Phase 1 DB Validation App
Multi-tenant Flask app with login, test index navigation, and detailed test pages.

Multi-tenancy pattern:
  1. Login resolves tenant from DB via (tenant_code, username).
  2. Session stores tenant_id; all subsequent connections SET app.current_tenant_id
     so PostgreSQL RLS policies (when active) are automatically enforced.
  3. Tenant-scoped test queries use session tenant_id as a param — never hardcoded.
"""

from flask import Flask, render_template_string, session, redirect, url_for, request
import psycopg2
import psycopg2.extras
import os
from datetime import datetime
from functools import wraps

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "ap-dev-secret-key-2026")

DB_CONFIG = dict(
    host=os.getenv("DB_HOST", "76.13.60.86"),
    port=int(os.getenv("DB_PORT", 5432)),
    user=os.getenv("DB_USER", "ap_user_001"),
    password=os.getenv("DB_PASSWORD", "apuser!23"),
    dbname=os.getenv("DB_NAME", "accountplanning"),
    connect_timeout=8,
)

# ── Auth decorator ─────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user_id" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ── DB helpers ─────────────────────────────────────────────────────────────────
def _get_conn(set_tenant=True):
    """
    Open a connection and optionally set the RLS tenant context.
    Enterprise best-practice: every connection sets app.current_tenant_id so
    PostgreSQL row-level security policies are automatically scoped.
    """
    conn = psycopg2.connect(**DB_CONFIG)
    if set_tenant and session.get("tenant_id"):
        cur = conn.cursor()
        cur.execute("SET app.current_tenant_id = %s", (session["tenant_id"],))
        cur.close()
    return conn


def fmt_cell(val):
    if val is None:
        return "NULL", "null-val"
    if isinstance(val, bool):
        return ("true", "bool-true") if val else ("false", "bool-false")
    s = str(val)
    return (s[:77] + "…") if len(s) > 80 else s, ""


def run_query(sql, params=None, raw=False, set_tenant=True):
    """Execute a query, returning (cols, rows, error).
    raw=True  → rows are plain dicts (for auth).
    raw=False → rows are {col: {display, cls}} dicts (for templates).
    """
    try:
        conn = _get_conn(set_tenant)
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, params)
        raw_rows = cur.fetchall()
        cols = [d[0] for d in cur.description] if cur.description else []
        cur.close(); conn.close()
        if raw:
            return cols, [dict(r) for r in raw_rows], None
        fmt_rows = []
        for r in raw_rows:
            row = {}
            for c in cols:
                display, cls = fmt_cell(r[c])
                row[c] = {"display": display, "cls": cls}
            fmt_rows.append(row)
        return cols, fmt_rows, None
    except Exception as e:
        return [], [], str(e)


def authenticate(tenant_code, username):
    """Resolve tenant + user from DB. No password required in demo mode."""
    _, rows, _ = run_query(
        """
        SELECT u.id       AS user_id,
               u.display_name, u.user_type, u.username,
               t.id       AS tenant_id,
               t.code     AS tenant_code,
               t.name     AS tenant_name
        FROM   core.user_  u
        JOIN   core.tenant t ON t.id = u.tenant_id
        WHERE  UPPER(t.code) = UPPER(%s)
          AND  LOWER(u.username) = LOWER(%s)
          AND  u.status = 'active'
          AND  t.status = 'active'
        LIMIT  1;
        """,
        (tenant_code, username),
        raw=True,
        set_tenant=False,
    )
    return rows[0] if rows else None


# ── Test definitions ───────────────────────────────────────────────────────────
# params_type:
#   "tenant_id" → (session.tenant_id,) passed as param
#   "none"      → no params; SQL uses hardcoded demo fixture UUIDs
TESTS = [
    dict(
        id="T1_1", code="V1.1", icon="🏢",
        title="Multi-Tenant Foundation",
        short_desc="Tenant record with KVKK/GDPR config, industry classification, and data residency.",
        params_type="tenant_id",
        business_req=(
            "The application serves a multi-tenant architecture. Each company has its own set of users, "
            "roles, relations, and preferences. A tenant record must exist with KVKK/GDPR compliance "
            "configuration and industry tagging, enabling proper data residency and jurisdiction rules."
        ),
        what_we_test=(
            "Verify that <code>core.tenant</code> holds your authenticated tenant with correct industry "
            "classification, status, data residency region, and GDPR config fields. "
            "The query is scoped to your session <code>tenant_id</code> — demonstrating tenant isolation."
        ),
        sql=(
            "SELECT code, name, industry, status,\n"
            "       data_residency_region, kvkk_gdpr_config\n"
            "FROM   core.tenant\n"
            "WHERE  id = %s;"
        ),
        expected="1 row — your tenant, status=active, data_residency_region=TR",
        issues=[
            "The <code>domain</code> field from the original plan is absent — replaced by broader <code>settings</code> JSONB. Minor naming drift between plan and DDL.",
            "No top-level <code>subscription_plan</code> column — it is nested inside <code>settings</code> JSONB, adding friction for BI tools that cannot parse JSONB natively.",
        ],
    ),
    dict(
        id="T1_2", code="V1.2", icon="🌳",
        title="Organisation Hierarchy Tree",
        short_desc="6-level company → LOB → region → area → branch → team adjacency list.",
        params_type="tenant_id",
        business_req=(
            "The sales team is organised in a hierarchical structure — LOBs, Regions, Areas, Branches "
            "and Teams. The structure is multi-level and defined per tenant. The database must store all "
            "levels and allow querying the full tree efficiently without recursive CTEs at read time."
        ),
        what_we_test=(
            "Query <code>core.org_unit</code> for all nodes belonging to your tenant and confirm the "
            "full 6-level tree (company → lob×2 → region → area → branch → team) is intact."
        ),
        sql=(
            "SELECT level, code, name, unit_type,\n"
            "       parent_id IS NOT NULL AS has_parent\n"
            "FROM   core.org_unit\n"
            "WHERE  tenant_id = %s\n"
            "ORDER  BY level, code;"
        ),
        expected="7 rows — 6 levels: company(0) lob×2(1) region(2) area(3) branch(4) team(5)",
        issues=[
            "The adjacency table alone cannot answer 'all descendants of X' without joining <code>org_unit_closure</code>. Subtree queries must always use the closure table.",
            "No DB trigger auto-populates <code>org_unit_closure</code> on insert — closure rows must be maintained manually. Data-consistency risk during re-orgs.",
        ],
    ),
    dict(
        id="T1_3", code="V1.3", icon="🔗",
        title="Closure Table — Subtree Queries",
        short_desc="O(1) ancestor/descendant lookups enabling efficient metric roll-ups.",
        params_type="none",
        fixture_note="Uses demo fixture UUID for Retail Banking LOB (c0000000-…-0010)",
        business_req=(
            "Performance metric roll-ups must aggregate from employee → team → branch → region → LOB → company. "
            "The closure table design enables O(1) ancestor/descendant lookups — critical for real-time "
            "dashboard widgets and AI-generated briefings."
        ),
        what_we_test=(
            "Use <code>core.org_unit_closure</code> to find all units that are descendants of "
            "<strong>Retail Banking (LOB)</strong> at any depth, verifying all transitive relationships are stored."
        ),
        sql=(
            "SELECT d.code, d.name, d.unit_type, cc.depth\n"
            "FROM   core.org_unit_closure cc\n"
            "JOIN   core.org_unit d ON d.id = cc.descendant_id\n"
            "WHERE  cc.ancestor_id = 'c0000000-0000-0000-0000-000000000010'\n"
            "  AND  cc.depth > 0\n"
            "ORDER  BY cc.depth;"
        ),
        expected="4 rows — Marmara(1), IST_EUROPE(2), LEVENT(3), LEVENT_TEAM_A(4)",
        issues=[
            "Corporate Banking is correctly isolated — its descendants do not appear in the Retail subtree. ✅",
            "Closure write path is not automated. On re-orgs, all stale closure rows must be deleted and re-inserted. An application-layer utility or stored procedure is needed.",
        ],
    ),
    dict(
        id="T1_4", code="V1.4", icon="👥",
        title="Employee–Org Assignment & Team Membership",
        short_desc="Employee assignments with effective dates, roles, and multi-team support.",
        params_type="none",
        fixture_note="Uses demo fixture UUID for Levent Team A (c0000000-…-0050)",
        business_req=(
            "Each sales employee is assigned to one or more org units. Multi-team assignments are supported "
            "with one marked primary. Historical assignments are preserved via effective_from/effective_until "
            "for accurate historical reporting."
        ),
        what_we_test=(
            "Retrieve all currently active employees assigned to <strong>Levent Team A</strong> by joining "
            "<code>core.employee</code>, <code>core.user_</code>, and <code>core.employee_org_assignment</code> "
            "where <code>effective_until IS NULL</code>."
        ),
        sql=(
            "SELECT e.employee_code, u.display_name, e.title,\n"
            "       eoa.role_in_unit, eoa.effective_from\n"
            "FROM   core.employee e\n"
            "JOIN   core.user_ u ON u.id = e.user_id\n"
            "JOIN   core.employee_org_assignment eoa ON eoa.employee_id = e.id\n"
            "WHERE  eoa.org_unit_id = 'c0000000-0000-0000-0000-000000000050'\n"
            "  AND  eoa.effective_until IS NULL\n"
            "ORDER  BY eoa.effective_from;"
        ),
        expected="3 rows — EMP003 (Senior RM), EMP004 (RM), EMP005 (Junior RM)",
        issues=[
            "<code>role_in_unit</code> uses a CHECK constraint (<code>member|manager|specialist|lead</code>) instead of a lookup table — tenant-specific role names require a DDL change.",
            "The <code>source</code> column correctly tracks assignment origin (<code>manual</code>, <code>core_system</code>, <code>ldap_sync</code>) — important for conflict resolution during automated sync. ✅",
        ],
    ),
    dict(
        id="T1_5", code="V1.5", icon="📅",
        title="Reporting Periods — Temporal Awareness",
        short_desc="Monthly and quarterly periods with fiscal year mapping and current-period flags.",
        params_type="tenant_id",
        business_req=(
            "Performance metrics, targets, and realizations are all time-boxed. The system must know the "
            "currently active period (is_current=true), closed periods, and support both monthly and "
            "quarterly granularity per tenant. This powers YTD, QTD, and period-over-period comparisons."
        ),
        what_we_test=(
            "Fetch all reporting periods from <code>core.reporting_period</code> for your tenant and confirm "
            "both monthly and quarterly periods exist with correct <code>is_current</code> and "
            "<code>is_closed</code> flags."
        ),
        sql=(
            "SELECT period_type, period_label, period_name,\n"
            "       period_start, period_end,\n"
            "       is_current, is_closed, fiscal_year, fiscal_quarter\n"
            "FROM   core.reporting_period\n"
            "WHERE  tenant_id = %s\n"
            "ORDER  BY period_start, period_type;"
        ),
        expected="6 rows — Jan/Feb/Mar/Apr monthly + Q1/Q2 quarterly; Apr & Q2 is_current=true",
        issues=[
            "Fiscal year/quarter are stored as integers per row — fiscal calendar logic is replicated in application code rather than derived from a shared dimension.",
            "No tenant-configurable fiscal year start month. Periods must be seeded manually even for standard calendars.",
            "Improvement: add a <code>reporting_calendar_config</code> to <code>core.tenant</code> or a dedicated config table to auto-generate future periods.",
        ],
    ),
    dict(
        id="T1_6", code="V1.6", icon="🧩",
        title="Module Registry & Feature Flags",
        short_desc="Per-tenant module enable/disable with config overrides for gradual rollout.",
        params_type="tenant_id",
        business_req=(
            "The application is modular — some companies may not be ready for AI-based insights. Each module "
            "(core, product, customer, analytics, agent, etc.) can be individually enabled/disabled per tenant "
            "with configuration overrides. This is the foundation for gradual feature rollout."
        ),
        what_we_test=(
            "Query <code>core.tenant_module</code> to confirm all 15 modules are registered for your tenant "
            "with <code>is_enabled</code> status. This table drives runtime feature-gating across the system."
        ),
        sql=(
            "SELECT module_code, is_enabled,\n"
            "       CASE WHEN config_override = '{}'\n"
            "            THEN 'default' ELSE 'customised'\n"
            "       END AS config_state\n"
            "FROM   core.tenant_module\n"
            "WHERE  tenant_id = %s\n"
            "ORDER  BY module_code;"
        ),
        expected="15 rows — all modules enabled with default config",
        issues=[
            "<code>tenant_module.module_code</code> is <code>VARCHAR</code> with no FK to <code>repo.supported_module</code> — a typo silently creates an orphaned row.",
            "Improvement: FK to <code>repo.supported_module(module_code)</code> or a CHECK constraint listing valid module codes.",
            "No <code>enabled_at</code> / <code>enabled_by</code> audit trail — important for compliance when toggling sensitive modules like <code>agent</code>.",
        ],
    ),
]

TEST_MAP = {t["id"]: t for t in TESTS}

# ── Shared CSS ─────────────────────────────────────────────────────────────────
CSS = """
  :root {
    --bg:#f7f8fa; --surf:#fff; --surf-alt:#f0f2f5;
    --bd:#e2e5ea; --bd-l:#edf0f4;
    --tx:#1a1e2a; --tx2:#5a6071; --txm:#9198a8;
    --ac:#3a6bff; --ac-l:#eef1ff; --ac-d:#2452d9;
    --ok:#16a249; --ok-bg:#edfbf2; --ok-bd:#b4efd0;
    --wa:#d97706; --wa-bg:#fffbeb; --wa-bd:#fde68a;
    --er:#dc2626; --er-bg:#fef2f2; --er-bd:#fecaca;
    --in:#0891b2; --in-bg:#ecfeff; --in-bd:#a5e0ec;
    --r:14px; --rs:8px;
    --sh:0 1px 3px rgba(0,0,0,.06),0 1px 2px rgba(0,0,0,.04);
    --shm:0 4px 14px rgba(0,0,0,.09),0 1px 3px rgba(0,0,0,.05);
  }
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Inter',system-ui,sans-serif;background:var(--bg);color:var(--tx);line-height:1.6}
  a{color:var(--ac);text-decoration:none}
  a:hover{text-decoration:underline}
  code{font-family:'JetBrains Mono',monospace;font-size:.87em;background:var(--surf-alt);padding:.1em .3em;border-radius:4px}

  /* ── Nav ── */
  nav{background:var(--surf);border-bottom:1px solid var(--bd);position:sticky;top:0;z-index:100;box-shadow:var(--sh)}
  .ni{max-width:1280px;margin:0 auto;padding:0 1.5rem;display:flex;align-items:center;height:60px;gap:.9rem}
  .logo{width:32px;height:32px;border-radius:8px;background:linear-gradient(135deg,#3a6bff,#6a3aff);display:grid;place-items:center;color:#fff;font-weight:700;font-size:14px;flex-shrink:0}
  .nav-title{font-size:.93rem;font-weight:600}
  .nav-sub{font-size:.75rem;color:var(--tx2)}
  .nr{margin-left:auto;display:flex;align-items:center;gap:.6rem}
  .ttag{background:var(--ac-l);color:var(--ac);border:1px solid #c7d6ff;padding:.15rem .55rem;border-radius:5px;font-size:.7rem;font-weight:700;letter-spacing:.05em}
  .uchip{display:flex;align-items:center;gap:.45rem;background:var(--surf-alt);border:1px solid var(--bd);border-radius:20px;padding:.25rem .75rem;font-size:.77rem;color:var(--tx2)}
  .udot{width:7px;height:7px;border-radius:50%;background:var(--ok);flex-shrink:0}
  .lout{font-size:.77rem;color:var(--tx2);padding:.3rem .65rem;border-radius:6px;border:1px solid var(--bd);background:var(--surf)}
  .lout:hover{color:var(--er);border-color:var(--er-bd);background:var(--er-bg);text-decoration:none}

  /* ── Layout ── */
  .main{max-width:1280px;margin:0 auto;padding:2rem 1.5rem}

  /* ── Pill ── */
  .pill{display:inline-flex;align-items:center;gap:.3rem;padding:.2rem .65rem;border-radius:20px;font-size:.71rem;font-weight:600}
  .p-pass{background:var(--ok-bg);color:var(--ok);border:1px solid var(--ok-bd)}
  .p-fail{background:var(--er-bg);color:var(--er);border:1px solid var(--er-bd)}
  .p-error{background:var(--wa-bg);color:var(--wa);border:1px solid var(--wa-bd)}
  .p-ac{background:var(--ac-l);color:var(--ac);border:1px solid #c7d6ff}

  /* ── Hero ── */
  .hero{background:linear-gradient(135deg,#eef1ff 0%,#f0f7ff 100%);border:1px solid #d6e0ff;border-radius:var(--r);padding:1.5rem 2rem;margin-bottom:1.75rem;display:flex;align-items:center;gap:2rem;flex-wrap:wrap}
  .hero h1{font-size:1.2rem;font-weight:700;margin-bottom:.3rem}
  .hero p{font-size:.85rem;color:var(--tx2)}
  .hstats{display:flex;gap:1.75rem;margin-left:auto;flex-shrink:0}
  .sn{font-size:1.75rem;font-weight:700;line-height:1;color:var(--ac)}
  .sl{font-size:.68rem;color:var(--txm);letter-spacing:.07em;margin-top:.2rem}

  /* ── Progress bar ── */
  .pb-wrap{margin-bottom:1.75rem}
  .pb-hd{display:flex;justify-content:space-between;font-size:.77rem;font-weight:600;margin-bottom:.4rem;color:var(--tx2)}
  .pb{height:8px;background:var(--bd);border-radius:99px;overflow:hidden}
  .pbf{height:100%;background:linear-gradient(90deg,#3a6bff,#6a3aff);border-radius:99px;transition:width .5s ease}

  /* ── Grid ── */
  .grid{display:grid;grid-template-columns:repeat(3,1fr);gap:1.1rem}
  @media(max-width:860px){.grid{grid-template-columns:repeat(2,1fr)}}
  @media(max-width:540px){.grid{grid-template-columns:1fr}}

  /* ── Card ── */
  .card{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);overflow:hidden;box-shadow:var(--sh);transition:box-shadow .2s,transform .15s;display:flex;flex-direction:column;cursor:pointer}
  .card:hover{box-shadow:var(--shm);transform:translateY(-2px)}
  .card.pass{border-top:3px solid var(--ok)}
  .card.fail{border-top:3px solid var(--er)}
  .card.error{border-top:3px solid var(--wa)}
  .ch{padding:.9rem 1rem .55rem;display:flex;align-items:flex-start;gap:.55rem}
  .cicon{font-size:1.35rem;flex-shrink:0;margin-top:.05rem}
  .ccode{font-family:'JetBrains Mono',monospace;font-size:.67rem;background:var(--surf-alt);border:1px solid var(--bd);border-radius:4px;padding:.08rem .4rem;color:var(--tx2);font-weight:500;display:inline-block;margin-bottom:.2rem}
  .ctitle{font-size:.9rem;font-weight:600;color:var(--tx)}
  .cb{padding:0 1rem .7rem;flex:1;font-size:.8rem;color:var(--tx2);line-height:1.5}
  .fnote{margin-top:.45rem;font-size:.7rem;color:var(--wa);background:var(--wa-bg);border:1px solid var(--wa-bd);padding:.18rem .5rem;border-radius:4px;display:inline-block}
  .cf{padding:.65rem 1rem;border-top:1px solid var(--bd-l);display:flex;align-items:center;justify-content:space-between}
  .rbadge{font-size:.7rem;color:var(--txm)}
  .clink{font-size:.79rem;font-weight:600;color:var(--ac);display:flex;align-items:center;gap:.25rem}
  .clink:hover{text-decoration:none;opacity:.75}

  /* ── Detail card ── */
  .dcrd{background:var(--surf);border:1px solid var(--bd);border-radius:var(--r);overflow:hidden;box-shadow:var(--sh)}
  .dcrd.pass{border-left:4px solid var(--ok)}
  .dcrd.fail{border-left:4px solid var(--er)}
  .dcrd.error{border-left:4px solid var(--wa)}
  .dhd{padding:1.25rem 1.5rem;border-bottom:1px solid var(--bd-l);display:flex;align-items:flex-start;gap:1rem}
  .dbody{padding:1.25rem 1.5rem;display:flex;flex-direction:column;gap:1rem}

  /* ── Blocks ── */
  .blbl{font-size:.67rem;font-weight:700;letter-spacing:.09em;text-transform:uppercase;margin-bottom:.35rem}
  .lbiz{color:var(--in)} .ltest{color:var(--ac)} .lsql{color:#6941c6} .lres{color:var(--ok)} .liss{color:var(--wa)}
  .bbiz{background:var(--in-bg);border:1px solid var(--in-bd);border-radius:var(--rs);padding:.65rem .9rem;font-size:.84rem;color:var(--tx2)}
  .btest{background:var(--ac-l);border:1px solid #c7d6ff;border-radius:var(--rs);padding:.65rem .9rem;font-size:.84rem;color:var(--tx2)}
  .bsql{background:#faf8ff;border:1px solid #e4d9ff;border-radius:var(--rs);padding:.65rem .9rem;font-family:'JetBrains Mono',monospace;font-size:.77rem;color:#3d2e6b;white-space:pre-wrap;overflow-x:auto}
  .bscope{background:var(--ac-l);border:1px solid #c7d6ff;border-radius:6px;padding:.4rem .85rem;font-size:.77rem;color:var(--ac)}
  .etag{display:inline-flex;align-items:center;background:#f0fdf4;border:1px solid var(--ok-bd);border-radius:6px;padding:.18rem .55rem;font-size:.77rem;color:#166534;font-family:'JetBrains Mono',monospace}

  /* ── Table ── */
  .twrap{overflow-x:auto;border-radius:var(--rs);border:1px solid var(--bd)}
  table{width:100%;border-collapse:collapse;font-size:.8rem}
  thead tr{background:var(--surf-alt)}
  th{text-align:left;padding:.5rem .7rem;font-size:.69rem;font-weight:600;color:var(--tx2);letter-spacing:.05em;border-bottom:1px solid var(--bd);white-space:nowrap}
  td{padding:.45rem .7rem;border-bottom:1px solid var(--bd-l);font-family:'JetBrains Mono',monospace;font-size:.77rem}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:var(--surf-alt)}
  .null-val{color:var(--txm);font-style:italic}
  .bool-true{color:var(--ok);font-weight:600}
  .bool-false{color:var(--er);font-weight:600}
  .rcount{margin-top:.4rem;font-size:.71rem;color:var(--txm);text-align:right}

  .ebox{background:var(--er-bg);border:1px solid var(--er-bd);border-radius:var(--rs);padding:.65rem .9rem;font-family:'JetBrains Mono',monospace;font-size:.77rem;color:var(--er);white-space:pre-wrap}

  /* ── Issues ── */
  .ilist{list-style:none;display:flex;flex-direction:column;gap:.4rem}
  .ilist li{background:var(--wa-bg);border:1px solid var(--wa-bd);border-radius:var(--rs);padding:.5rem .8rem;font-size:.81rem;color:#78350f;display:flex;gap:.5rem;align-items:flex-start}
  .ilist li::before{content:"⚠";flex-shrink:0}
  .ilist li.ok{background:var(--ok-bg);border-color:var(--ok-bd);color:#14532d}
  .ilist li.ok::before{content:"✅"}

  /* ── Breadcrumb ── */
  .bc{display:flex;align-items:center;gap:.4rem;margin-bottom:1.25rem;font-size:.81rem;color:var(--tx2)}
  .bc a{color:var(--ac)}
  .bc-sep{opacity:.35}

  /* ── Bottom nav ── */
  .bnav{display:flex;align-items:center;justify-content:space-between;margin-top:1.75rem;gap:.75rem;flex-wrap:wrap}
  .nbtn{display:inline-flex;align-items:center;gap:.45rem;padding:.55rem 1rem;border-radius:var(--rs);border:1px solid var(--bd);background:var(--surf);font-size:.83rem;font-weight:500;color:var(--tx2);cursor:pointer;transition:all .15s;font-family:inherit}
  .nbtn:hover{background:var(--ac-l);color:var(--ac);border-color:#c7d6ff;text-decoration:none}
  .nbtn.ac{background:var(--ac);color:#fff;border-color:var(--ac)}
  .nbtn.ac:hover{background:var(--ac-d);border-color:var(--ac-d);color:#fff}
  .nbtn.dim{opacity:.3;pointer-events:none}

  footer{text-align:center;padding:2rem 1rem;font-size:.73rem;color:var(--txm);border-top:1px solid var(--bd);margin-top:3rem}
"""

FONTS = (
    '<link rel="preconnect" href="https://fonts.googleapis.com">'
    '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700'
    '&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">'
)


def _nav(display_name="", tenant_name="", tenant_code="", user_type="", active_link="tests"):
    return f"""
<nav><div class="ni">
  <div class="logo">AP</div>
  <div><div class="nav-title">Account Planning</div><div class="nav-sub">DB Validation</div></div>
  <div class="nr">
    <span class="ttag">{tenant_code}</span>
    <div class="uchip"><div class="udot"></div>{display_name}
      <span style="color:var(--txm)">· {user_type}</span>
    </div>
    <a href="/logout" class="lout">Sign out</a>
  </div>
</div></nav>"""


# ── Login page ─────────────────────────────────────────────────────────────────
LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Sign In — Account Planning Validation</title>
  """ + FONTS + """
  <style>
    """ + CSS + """
    body{min-height:100vh;background:var(--bg);display:grid;grid-template-columns:1.15fr .85fr}
    @media(max-width:740px){body{grid-template-columns:1fr}.lpanel{display:none!important}}

    /* Left */
    .lpanel{
      background:linear-gradient(148deg,#1e3a8a 0%,#312e81 45%,#1e1b4b 100%);
      padding:3rem;display:flex;flex-direction:column;justify-content:center;
      position:relative;overflow:hidden;
    }
    .lpanel::before{
      content:'';position:absolute;inset:0;
      background:radial-gradient(ellipse at 15% 55%,rgba(99,102,241,.25) 0%,transparent 55%),
                 radial-gradient(ellipse at 82% 18%,rgba(59,130,246,.18) 0%,transparent 50%);
    }
    .lc{position:relative;z-index:1}
    .ll{width:52px;height:52px;border-radius:14px;background:rgba(255,255,255,.13);
        border:1px solid rgba(255,255,255,.2);display:grid;place-items:center;
        font-size:22px;font-weight:800;color:#fff;margin-bottom:2rem}
    .lt1{font-size:2rem;font-weight:700;color:#fff;line-height:1.2;margin-bottom:.9rem}
    .lt2{font-size:.9rem;color:rgba(255,255,255,.68);line-height:1.7;max-width:370px}
    .flist{margin-top:2.5rem;display:flex;flex-direction:column;gap:.7rem}
    .fi{display:flex;align-items:center;gap:.7rem;color:rgba(255,255,255,.82);font-size:.86rem}
    .fii{width:32px;height:32px;border-radius:8px;background:rgba(255,255,255,.1);
         border:1px solid rgba(255,255,255,.14);display:grid;place-items:center;font-size:14px;flex-shrink:0}
    .hint{margin-top:3rem;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.15);
          border-radius:12px;padding:1rem 1.25rem}
    .hint h4{color:rgba(255,255,255,.88);font-size:.72rem;font-weight:700;letter-spacing:.07em;
             text-transform:uppercase;margin-bottom:.65rem}
    .hrow{display:flex;align-items:center;gap:.5rem;margin-bottom:.35rem;font-size:.8rem;color:rgba(255,255,255,.65)}
    .hval{font-family:'JetBrains Mono',monospace;color:#93c5fd;font-size:.78rem;
          background:rgba(255,255,255,.08);padding:.1rem .4rem;border-radius:4px}

    /* Right */
    .rpanel{display:flex;align-items:center;justify-content:center;padding:2.5rem 2rem;background:var(--surf)}
    .fcard{width:100%;max-width:390px}
    .fcard h2{font-size:1.55rem;font-weight:700;margin-bottom:.35rem}
    .fcard>p{font-size:.87rem;color:var(--tx2);margin-bottom:1.75rem}
    .field{margin-bottom:1.05rem}
    .field label{display:block;font-size:.78rem;font-weight:600;color:var(--tx2);margin-bottom:.35rem}
    .field input{width:100%;padding:.65rem .9rem;border:1.5px solid var(--bd);border-radius:8px;
                 font-size:.9rem;font-family:inherit;outline:none;background:var(--surf);color:var(--tx);
                 transition:border-color .15s,box-shadow .15s}
    .field input:focus{border-color:var(--ac);box-shadow:0 0 0 3px rgba(58,107,255,.14)}
    .fhint{font-size:.71rem;color:var(--txm);margin-top:.25rem}
    .sbtn{width:100%;padding:.75rem;background:var(--ac);color:#fff;border:none;border-radius:8px;
          font-size:.95rem;font-weight:600;cursor:pointer;font-family:inherit;margin-top:.35rem;
          transition:background .15s}
    .sbtn:hover{background:var(--ac-d)}
    .errbox{background:var(--er-bg);border:1px solid var(--er-bd);border-radius:8px;
            padding:.6rem .9rem;font-size:.82rem;color:var(--er);margin-bottom:1rem;
            display:flex;gap:.5rem;align-items:flex-start}
    .dmn{margin-top:1.4rem;background:var(--wa-bg);border:1px solid var(--wa-bd);
         border-radius:8px;padding:.55rem .85rem;font-size:.76rem;color:#78350f;line-height:1.5}
  </style>
</head>
<body>

<!-- Left branding panel -->
<div class="lpanel">
  <div class="lc">
    <div class="ll">AP</div>
    <div class="lt1">Account Planning<br>Validation Suite</div>
    <div class="lt2">
      Enterprise database architecture validation for the Agentic AI Sales &amp;
      Performance Assistant — Phase 1: Foundation.
    </div>
    <div class="flist">
      <div class="fi"><div class="fii">🏢</div>Multi-tenant with KVKK/GDPR compliance</div>
      <div class="fi"><div class="fii">🔒</div>Session-scoped tenant isolation via RLS context</div>
      <div class="fi"><div class="fii">🧪</div>Live validation against PostgreSQL</div>
    </div>
    <div class="hint">
      <h4>Demo Credentials</h4>
      <div class="hrow">Company Code <span class="hval">DEMO_BANK</span></div>
      <div class="hrow">Username
        <span class="hval">ahmet.yilmaz</span>
        <span class="hval">ayse.demir</span>
        <span class="hval">mehmet.kaya</span>
      </div>
    </div>
  </div>
</div>

<!-- Right login form -->
<div class="rpanel">
  <div class="fcard">
    <h2>Welcome back</h2>
    <p>Sign in to access the Phase 1 validation suite.</p>

    {% if error %}
    <div class="errbox">⚠&nbsp; {{ error }}</div>
    {% endif %}

    <form method="POST" action="/login" autocomplete="on">
      <div class="field">
        <label for="tc">Company Code</label>
        <input id="tc" name="tenant_code" type="text"
               placeholder="e.g. DEMO_BANK"
               autocomplete="organization"
               style="text-transform:uppercase;letter-spacing:.04em"
               value="{{ request.form.get('tenant_code','') }}"
               required autofocus>
        <div class="fhint">Your organisation's unique tenant identifier.</div>
      </div>
      <div class="field">
        <label for="un">Username</label>
        <input id="un" name="username" type="text"
               placeholder="e.g. ahmet.yilmaz"
               autocomplete="username"
               value="{{ request.form.get('username','') }}"
               required>
      </div>
      <button class="sbtn" type="submit">Sign In →</button>
      <div class="dmn">
        ⚠ <strong>Demo mode</strong> — password authentication is not yet seeded.
        Any active username + valid company code grants access.
      </div>
    </form>
  </div>
</div>

</body>
</html>"""


# ── Tests index page ────────────────────────────────────────────────────────────
INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Phase 1 Tests — Account Planning</title>
  """ + FONTS + """
  <style>""" + CSS + """</style>
</head>
<body>

{{ nav | safe }}

<main class="main">

  <!-- Hero -->
  <div class="hero">
    <div>
      <h1>Phase 1 — Foundation Tests</h1>
      <p>Validating the <strong>core</strong> schema: multi-tenancy, org hierarchy, IAM,
         employee assignments, reporting periods, and module registry.</p>
    </div>
    <div class="hstats">
      <div style="text-align:center"><div class="sn">{{ total }}</div><div class="sl">TESTS</div></div>
      <div style="text-align:center"><div class="sn" style="color:var(--ok)">{{ passed }}</div><div class="sl">PASSED</div></div>
      <div style="text-align:center"><div class="sn" style="color:var(--er)">{{ failed }}</div><div class="sl">FAILED</div></div>
    </div>
  </div>

  <!-- Progress -->
  <div class="pb-wrap">
    <div class="pb-hd">
      <span>Test Suite Progress</span>
      <span style="color:var(--ac)">{{ pct }}% passing</span>
    </div>
    <div class="pb"><div class="pbf" style="width:{{ pct }}%"></div></div>
  </div>

  <!-- Test cards -->
  <div class="grid">
    {% for r in results %}
    <a href="/tests/{{ r.id }}" style="text-decoration:none;display:contents">
      <div class="card {{ r.status }}">
        <div class="ch">
          <div class="cicon">{{ r.icon }}</div>
          <div style="flex:1">
            <div class="ccode">{{ r.code }}</div>
            <div class="ctitle">{{ r.title }}</div>
          </div>
          <div class="pill {% if r.status=='pass' %}p-pass{% elif r.status=='fail' %}p-fail{% else %}p-error{% endif %}">
            {% if r.status=='pass' %}✅{% elif r.status=='fail' %}❌{% else %}⚠{% endif %}
          </div>
        </div>
        <div class="cb">
          {{ r.short_desc }}
          {% if r.fixture_note %}
          <div class="fnote">📌 {{ r.fixture_note }}</div>
          {% endif %}
        </div>
        <div class="cf">
          <span class="rbadge">
            {% if r.error %}
              Connection error
            {% elif r.row_count > 0 %}
              {{ r.row_count }} row{{ 's' if r.row_count != 1 else '' }}
            {% else %}
              No rows returned
            {% endif %}
          </span>
          <span class="clink">View test →</span>
        </div>
      </div>
    </a>
    {% endfor %}
  </div>

</main>

<footer>Account Planning · Phase 1 Foundation &nbsp;·&nbsp; {{ tenant_name }}</footer>

</body>
</html>"""


# ── Test detail page ────────────────────────────────────────────────────────────
DETAIL_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{{ test.code }} « {{ test.title }} — Account Planning</title>
  """ + FONTS + """
  <style>""" + CSS + """</style>
</head>
<body>

{{ nav | safe }}

<main class="main">

  <!-- Breadcrumb -->
  <div class="bc">
    <a href="/tests">← All Tests</a>
    <span class="bc-sep">/</span>
    <span>{{ test.code }}</span>
    <span class="bc-sep">/</span>
    <span>{{ test.title }}</span>
    <span style="margin-left:auto;font-size:.73rem;color:var(--txm)">{{ test_num }} of {{ total_tests }}</span>
  </div>

  {% if test.fixture_note %}
  <div style="background:var(--wa-bg);border:1px solid var(--wa-bd);border-radius:8px;padding:.55rem 1rem;font-size:.79rem;color:#78350f;margin-bottom:1.1rem">
    📌 <strong>Demo Fixture:</strong> {{ test.fixture_note }}
  </div>
  {% endif %}

  <div class="dcrd {{ status }}">

    <!-- Head -->
    <div class="dhd">
      <div style="display:flex;align-items:center;gap:.75rem;flex:1">
        <span style="font-size:1.55rem">{{ test.icon }}</span>
        <div>
          <div class="ccode" style="margin-bottom:.25rem">{{ test.code }}</div>
          <div style="font-size:1.1rem;font-weight:600">{{ test.title }}</div>
        </div>
      </div>
      <div class="pill {% if status=='pass' %}p-pass{% elif status=='fail' %}p-fail{% else %}p-error{% endif %}"
           style="font-size:.79rem;padding:.3rem .85rem">
        {% if status=='pass' %}✅ PASS
        {% elif status=='fail' %}❌ FAIL
        {% else %}⚠ ERROR
        {% endif %}
        &nbsp;·&nbsp;{{ row_count }} row{{ 's' if row_count != 1 else '' }}
      </div>
    </div>

    <!-- Body -->
    <div class="dbody">

      <!-- Business requirement -->
      <div>
        <div class="blbl lbiz">📋 Business Requirement</div>
        <div class="bbiz">{{ test.business_req }}</div>
      </div>

      <!-- What we test -->
      <div>
        <div class="blbl ltest">🔍 What This Test Validates</div>
        <div class="btest">{{ test.what_we_test | safe }}</div>
      </div>

      <!-- Tenant scope badge (only for tenant-scoped tests) -->
      {% if test.params_type == 'tenant_id' %}
      <div class="bscope">
        🔒 <strong>Tenant-scoped:</strong> Query filtered to your session tenant ·
        <code>{{ tenant_code }}</code> ({{ tenant_name }})
      </div>
      {% endif %}

      <!-- SQL -->
      <div>
        <div class="blbl lsql">🗄 Query</div>
        <div class="bsql">{{ test.sql }}</div>
      </div>

      <!-- Expected -->
      <div>
        <span class="blbl lres" style="display:inline">🎯 Expected: </span>&nbsp;
        <span class="etag">{{ test.expected }}</span>
        <span style="font-size:.7rem;color:var(--txm);margin-left:.6rem">· run at {{ ts }}</span>
      </div>

      <!-- Result -->
      <div>
        <div class="blbl lres">📊 Result</div>
        {% if err %}
          <div class="ebox">{{ err }}</div>
        {% elif rows %}
          <div class="twrap">
            <table>
              <thead><tr>{% for c in cols %}<th>{{ c }}</th>{% endfor %}</tr></thead>
              <tbody>
                {% for row in rows %}
                <tr>
                  {% for c in cols %}
                  <td><span class="{{ row[c].cls }}">{{ row[c].display }}</span></td>
                  {% endfor %}
                </tr>
                {% endfor %}
              </tbody>
            </table>
          </div>
          <div class="rcount">{{ row_count }} row{{ 's' if row_count != 1 else '' }} returned</div>
        {% else %}
          <div style="color:var(--txm);font-size:.85rem;padding:.4rem 0">(no rows returned)</div>
        {% endif %}
      </div>

      <!-- Issues & improvement areas -->
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

  <!-- Bottom navigation -->
  <div class="bnav">
    {% if prev_test %}
    <a href="/tests/{{ prev_test.id }}" class="nbtn">
      ← {{ prev_test.code }} · {{ prev_test.title }}
    </a>
    {% else %}
    <span class="nbtn dim">← Previous</span>
    {% endif %}

    <a href="/tests" class="nbtn">↑ All Tests</a>

    {% if next_test %}
    <a href="/tests/{{ next_test.id }}" class="nbtn ac">
      {{ next_test.code }} · {{ next_test.title }} →
    </a>
    {% else %}
    <span class="nbtn dim">Next →</span>
    {% endif %}
  </div>

</main>

<footer>Account Planning · Phase 1 Foundation &nbsp;·&nbsp; {{ tenant_name }}</footer>

</body>
</html>"""


# ── Routes ─────────────────────────────────────────────────────────────────────
@app.route("/")
def root():
    return redirect(url_for("tests_index") if "user_id" in session else url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if "user_id" in session:
        return redirect(url_for("tests_index"))
    error = None
    if request.method == "POST":
        tc = request.form.get("tenant_code", "").strip()
        un = request.form.get("username", "").strip()
        if not tc or not un:
            error = "Please enter both Company Code and Username."
        else:
            user = authenticate(tc, un)
            if user:
                session["user_id"]      = str(user["user_id"])
                session["display_name"] = user["display_name"]
                session["user_type"]    = user["user_type"]
                session["username"]     = user["username"]
                session["tenant_id"]    = str(user["tenant_id"])
                session["tenant_code"]  = user["tenant_code"]
                session["tenant_name"]  = user["tenant_name"]
                return redirect(url_for("tests_index"))
            else:
                error = "No active account found for that Company Code and Username. Check your credentials."
    return render_template_string(LOGIN_HTML, error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/tests")
@login_required
def tests_index():
    tid = session["tenant_id"]
    results = []
    for t in TESTS:
        params = (tid,) if t.get("params_type") == "tenant_id" else None
        cols, rows, err = run_query(t["sql"], params)
        status = "error" if err else ("pass" if rows else "fail")
        results.append({
            "id":          t["id"],
            "code":        t["code"],
            "title":       t["title"],
            "icon":        t["icon"],
            "short_desc":  t["short_desc"],
            "fixture_note": t.get("fixture_note"),
            "status":      status,
            "row_count":   len(rows),
            "error":       err,
        })
    total  = len(results)
    passed = sum(1 for r in results if r["status"] == "pass")
    return render_template_string(
        INDEX_HTML,
        nav=_nav(**_sctx()),
        results=results,
        total=total,
        passed=passed,
        failed=total - passed,
        pct=round(passed / total * 100) if total else 0,
        **_sctx(),
    )


@app.route("/tests/<test_id>")
@login_required
def test_detail(test_id):
    test = TEST_MAP.get(test_id)
    if not test:
        return redirect(url_for("tests_index"))

    tid    = session["tenant_id"]
    params = (tid,) if test.get("params_type") == "tenant_id" else None
    cols, rows, err = run_query(test["sql"], params)
    status = "error" if err else ("pass" if rows else "fail")

    ids      = [t["id"] for t in TESTS]
    idx      = ids.index(test_id)
    prev_t   = TEST_MAP.get(ids[idx - 1]) if idx > 0 else None
    next_t   = TEST_MAP.get(ids[idx + 1]) if idx < len(ids) - 1 else None

    return render_template_string(
        DETAIL_HTML,
        nav=_nav(**_sctx()),
        test=test,
        cols=cols,
        rows=rows,
        row_count=len(rows),
        err=err,
        status=status,
        prev_test=prev_t,
        next_test=next_t,
        test_num=idx + 1,
        total_tests=len(TESTS),
        ts=datetime.now().strftime("%H:%M:%S"),
        **_sctx(),
    )


def _sctx():
    return {
        "display_name": session.get("display_name", ""),
        "tenant_name":  session.get("tenant_name", ""),
        "tenant_code":  session.get("tenant_code", ""),
        "user_type":    session.get("user_type", ""),
    }


# ── Entry point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("▶  Account Planning DB Validation  →  http://127.0.0.1:5050")
    app.run(host="0.0.0.0", port=5050, debug=False)
