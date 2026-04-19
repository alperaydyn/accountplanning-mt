#!/usr/bin/env python3
"""
Account Planning — Phase 1 Execution Script
Creates databases, runs DDL files, and seeds foundation data.
"""

import psycopg2
import psycopg2.extras
import time
import os

HOST     = "76.13.60.86"
PORT     = 5432
USER     = "ap_user_001"
PASSWORD = "apuser!23"
MAIN_DB  = "accountplanning"
REPO_DB  = "accountplanning_repo"

GREEN  = "\033[92m"; RED = "\033[91m"; YELLOW = "\033[93m"
CYAN   = "\033[96m"; BOLD = "\033[1m"; RESET = "\033[0m"

def ok(m):   print(f"{GREEN}✅ {m}{RESET}")
def err(m):  print(f"{RED}❌ {m}{RESET}")
def info(m): print(f"{CYAN}ℹ  {m}{RESET}")
def head(m): print(f"\n{BOLD}{CYAN}{'='*60}\n   {m}\n{'='*60}{RESET}\n")

def connect(dbname):
    return psycopg2.connect(
        host=HOST, port=PORT, user=USER, password=PASSWORD,
        dbname=dbname, connect_timeout=10
    )

def exec_sql(conn, sql, label=""):
    """Execute full SQL string in one shot — psycopg2 handles multi-statement natively."""
    conn.autocommit = False
    cur = conn.cursor()
    t = time.time()
    try:
        cur.execute(sql)
        conn.commit()
        ok(f"{label} — OK ({time.time()-t:.2f}s)")
    except Exception as e:
        conn.rollback()
        err(f"{label} FAILED:\n  {e}")
        raise
    finally:
        cur.close()

def run_file(conn, path, label=None):
    with open(path, encoding='utf-8') as f:
        sql = f.read()
    lbl = label or os.path.basename(path)
    info(f"Running: {lbl}")
    exec_sql(conn, sql, lbl)

def qprint(conn, sql, title=""):
    """Run SELECT and pretty-print results."""
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cur.execute(sql)
        rows = cur.fetchall()
    except Exception as e:
        err(f"Query failed: {e}")
        return
    finally:
        cur.close()

    if title:
        print(f"\n  {BOLD}{title}{RESET}")
    if not rows:
        print(f"  {YELLOW}(no rows){RESET}")
        return
    cols = list(rows[0].keys())
    w = {c: max(len(str(c)), max(len(str(r.get(c) or '')) for r in rows)) for c in cols}
    print("  " + " | ".join(str(c).ljust(w[c]) for c in cols))
    print("  " + "-+-".join("-"*w[c] for c in cols))
    for row in rows:
        print("  " + " | ".join(str(row.get(c) or '').ljust(w[c]) for c in cols))
    print(f"  {GREEN}({len(rows)} row{'s' if len(rows)!=1 else ''}){RESET}")


# ── Seed SQL (safe to execute as one block) ───────────────────────────────────
SEED_SQL = """
-- core.tenant (actual columns: id, code, name, industry, status, settings, data_residency_region, kvkk_gdpr_config)
INSERT INTO core.tenant (id, code, name, industry, status, settings, data_residency_region, kvkk_gdpr_config) VALUES
('a0000000-0000-0000-0000-000000000001','DEMO_BANK','Demo Bank A.S.','banking','active',
 '{"subscription_plan":"enterprise","default_currency":"TRY"}',
 'TR',
 '{"data_protection_officer":"dpo@demobank.com","jurisdiction":"TR","encryption_at_rest":true}')
ON CONFLICT (id) DO NOTHING;

-- core.tenant_module (actual columns: tenant_id, module_code, is_enabled, config_override)
INSERT INTO core.tenant_module (tenant_id, module_code, is_enabled, config_override) VALUES
('a0000000-0000-0000-0000-000000000001','core',true,'{}'),
('a0000000-0000-0000-0000-000000000001','product',true,'{}'),
('a0000000-0000-0000-0000-000000000001','customer',true,'{}'),
('a0000000-0000-0000-0000-000000000001','perf',true,'{}'),
('a0000000-0000-0000-0000-000000000001','analytics',true,'{}'),
('a0000000-0000-0000-0000-000000000001','action',true,'{}'),
('a0000000-0000-0000-0000-000000000001','content',true,'{}'),
('a0000000-0000-0000-0000-000000000001','audit',true,'{}'),
('a0000000-0000-0000-0000-000000000001','config',true,'{}'),
('a0000000-0000-0000-0000-000000000001','integration',true,'{}'),
('a0000000-0000-0000-0000-000000000001','agent',true,'{}'),
('a0000000-0000-0000-0000-000000000001','notification',true,'{}'),
('a0000000-0000-0000-0000-000000000001','document',true,'{}'),
('a0000000-0000-0000-0000-000000000001','i18n',true,'{}'),
('a0000000-0000-0000-0000-000000000001','reporting',true,'{}')
ON CONFLICT (tenant_id, module_code) DO NOTHING;

-- core.user_ (user_type CHECK: sales_rep|manager|admin|system|analyst|app_admin)
INSERT INTO core.user_ (id, tenant_id, username, email, display_name, identity_provider, external_id, user_type, status) VALUES
('b0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','system','system@demobank.com','System Account','local','system','system','active'),
('b0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','ahmet.yilmaz','ahmet.yilmaz@demobank.com','Ahmet Yilmaz','local','ahmet.yilmaz','manager','active'),
('b0000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','ayse.demir','ayse.demir@demobank.com','Ayse Demir','local','ayse.demir','manager','active'),
('b0000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001','mehmet.kaya','mehmet.kaya@demobank.com','Mehmet Kaya','local','mehmet.kaya','sales_rep','active'),
('b0000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001','fatma.ozkan','fatma.ozkan@demobank.com','Fatma Ozkan','local','fatma.ozkan','sales_rep','active'),
('b0000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001','ali.celik','ali.celik@demobank.com','Ali Celik','local','ali.celik','sales_rep','active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO core.org_unit (id, tenant_id, parent_id, code, name, unit_type, level) VALUES
('c0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',NULL,'DEMO_BANK','Demo Bank A.S.','company',0),
('c0000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','RETAIL','Retail Banking','lob',1),
('c0000000-0000-0000-0000-000000000011','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','CORPORATE','Corporate Banking','lob',1),
('c0000000-0000-0000-0000-000000000020','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000010','MARMARA','Marmara Region','region',2),
('c0000000-0000-0000-0000-000000000030','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000020','IST_EUROPE','Istanbul European Side','area',3),
('c0000000-0000-0000-0000-000000000040','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000030','LEVENT','Istanbul Levent Branch','branch',4),
('c0000000-0000-0000-0000-000000000050','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000040','LEVENT_TEAM_A','Levent Team A','team',5)
ON CONFLICT (id) DO NOTHING;

INSERT INTO core.org_unit_closure (ancestor_id, descendant_id, depth, tenant_id) VALUES
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010','c0000000-0000-0000-0000-000000000010',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000011','c0000000-0000-0000-0000-000000000011',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020','c0000000-0000-0000-0000-000000000020',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000030','c0000000-0000-0000-0000-000000000030',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000040','c0000000-0000-0000-0000-000000000040',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000050','c0000000-0000-0000-0000-000000000050',0,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000010',1,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000011',1,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000020',2,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000030',3,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000040',4,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000050',5,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010','c0000000-0000-0000-0000-000000000020',1,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010','c0000000-0000-0000-0000-000000000030',2,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010','c0000000-0000-0000-0000-000000000040',3,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000010','c0000000-0000-0000-0000-000000000050',4,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020','c0000000-0000-0000-0000-000000000030',1,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020','c0000000-0000-0000-0000-000000000040',2,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000020','c0000000-0000-0000-0000-000000000050',3,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000030','c0000000-0000-0000-0000-000000000040',1,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000030','c0000000-0000-0000-0000-000000000050',2,'a0000000-0000-0000-0000-000000000001'),
('c0000000-0000-0000-0000-000000000040','c0000000-0000-0000-0000-000000000050',1,'a0000000-0000-0000-0000-000000000001')
ON CONFLICT (ancestor_id, descendant_id) DO NOTHING;

-- core.employee (actual: no department column; use attributes JSONB instead)
INSERT INTO core.employee (id, tenant_id, user_id, employee_code, title, attributes, is_active) VALUES
('d0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000002','EMP001','Regional Director','{"department":"Retail Banking"}',true),
('d0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000003','EMP002','Branch Manager','{"department":"Levent Branch"}',true),
('d0000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000004','EMP003','Senior RM','{"department":"Levent Team A"}',true),
('d0000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000005','EMP004','Relationship Manager','{"department":"Levent Team A"}',true),
('d0000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000006','EMP005','Junior RM','{"department":"Levent Team A"}',true)
ON CONFLICT (id) DO NOTHING;

-- core.employee_org_assignment (source CHECK: manual|core_system|ldap_sync)
INSERT INTO core.employee_org_assignment (tenant_id, employee_id, org_unit_id, role_in_unit, is_primary, effective_from, source) VALUES
('a0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000020','manager',true,'2025-01-01','manual'),
('a0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-000000000040','manager',true,'2025-01-01','manual'),
('a0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-000000000050','member',true,'2025-01-01','manual'),
('a0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000004','c0000000-0000-0000-0000-000000000050','member',true,'2025-01-01','manual'),
('a0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000005','c0000000-0000-0000-0000-000000000050','member',true,'2025-06-01','manual')
ON CONFLICT DO NOTHING;

-- core.reporting_period (fiscal_year and fiscal_quarter are also NOT NULL)
INSERT INTO core.reporting_period (id, tenant_id, period_type, period_label, period_name, period_start, period_end, calendar_year, calendar_month, calendar_quarter, fiscal_year, fiscal_quarter, is_current, is_closed) VALUES
('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','monthly','2025-01','January 2025','2025-01-01','2025-01-31',2025,1,1,2025,1,false,true),
('e0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','monthly','2025-02','February 2025','2025-02-01','2025-02-28',2025,2,1,2025,1,false,true),
('e0000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','monthly','2025-03','March 2025','2025-03-01','2025-03-31',2025,3,1,2025,1,false,true),
('e0000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001','quarterly','2025-Q1','Q1 2025','2025-01-01','2025-03-31',2025,1,1,2025,1,false,true),
('e0000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001','monthly','2025-04','April 2025','2025-04-01','2025-04-30',2025,4,2,2025,2,true,false),
('e0000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001','quarterly','2025-Q2','Q2 2025','2025-04-01','2025-06-30',2025,4,2,2025,2,true,false)
ON CONFLICT (id) DO NOTHING;
"""

REPO_SEED_SQL = """
-- Repo DB uses public schema (no 'repo.' prefix)
-- Tables: app_setting, supported_module, db_migration
INSERT INTO app_setting (key, value, description) VALUES
('db_version','"0.1.0"','Database schema version'),
('platform_name','"Account Planning"','Platform display name'),
('default_locale','"tr"','Default locale')
ON CONFLICT (key) DO NOTHING;

INSERT INTO db_migration (version, description, applied_at, checksum) VALUES
('0.1.0','Initial schema: extensions, schemas, core, repo','2026-04-19 00:00:00+00','abc123phase1')
ON CONFLICT (version) DO NOTHING;
"""

VALIDATIONS = [
    ("V1.1 — Tenant exists",
     "SELECT id, code, name, industry, status FROM core.tenant;"),
    ("V1.2 — Org hierarchy (7 nodes)",
     "SELECT level, code, name, unit_type FROM core.org_unit ORDER BY level, code;"),
    ("V1.3 — Closure: all units under Retail (depth > 0)",
     """SELECT d.code, d.name, d.unit_type, cc.depth
        FROM core.org_unit_closure cc
        JOIN core.org_unit d ON d.id = cc.descendant_id
        WHERE cc.ancestor_id = 'c0000000-0000-0000-0000-000000000010'
          AND cc.depth > 0
        ORDER BY cc.depth;"""),
    ("V1.4 — Employees in Levent Team A (display_name)",
     """SELECT e.employee_code, u.display_name, e.title
        FROM core.employee e
        JOIN core.user_ u ON u.id = e.user_id
        JOIN core.employee_org_assignment eoa ON eoa.employee_id = e.id
        WHERE eoa.org_unit_id = 'c0000000-0000-0000-0000-000000000050'
          AND eoa.effective_until IS NULL;"""),
    ("V1.5 — Reporting Periods (6 rows)",
     "SELECT period_type, period_label, period_start, period_end, is_current FROM core.reporting_period ORDER BY period_start;"),
    ("V1.6 — Modules enabled for tenant",
     "SELECT module_code, is_enabled FROM core.tenant_module WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001' ORDER BY module_code;"),
]


def main():
    # ── 0: Create databases ──────────────────────────────────────────────────
    head("STEP 0 — Create Databases")
    conn0 = connect("postgres")
    conn0.autocommit = True
    cur = conn0.cursor()
    for dbname in [MAIN_DB, REPO_DB]:
        cur.execute(f"SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
        if cur.fetchone():
            ok(f"'{dbname}' already exists")
        else:
            cur.execute(f'CREATE DATABASE "{dbname}"')
            ok(f"Created database '{dbname}'")
    cur.close()
    conn0.close()

    # ── 1: Extensions & Schemas ──────────────────────────────────────────────
    head("STEP 1 — Extensions & Schemas  (00_extensions_and_schemas.sql)")
    conn_main = connect(MAIN_DB)
    run_file(conn_main, "sql/00_extensions_and_schemas.sql")

    # ── 2: Core tables ───────────────────────────────────────────────────────
    head("STEP 2 — Core Tables  (02_core.sql)")
    run_file(conn_main, "sql/02_core.sql")

    # ── 3: Seed core data ──────────────────────────────────────────────────
    head("STEP 3 — Seed Foundation Data  (tenant, users, org, employees, periods)")
    exec_sql(conn_main, SEED_SQL, label="phase1_seed")

    # ── 4: Repo DB ────────────────────────────────────────────────────────────
    head("STEP 4 — Repo DB  (01_repo.sql → accountplanning_repo)")
    conn_repo = connect(REPO_DB)
    conn_repo.autocommit = False
    cur_repo = conn_repo.cursor()
    cur_repo.execute("CREATE SCHEMA IF NOT EXISTS repo;")
    conn_repo.commit()
    cur_repo.close()
    run_file(conn_repo, "sql/01_repo.sql")
    exec_sql(conn_repo, REPO_SEED_SQL, label="repo_seed")
    conn_repo.close()

    # ── 5: Validate ───────────────────────────────────────────────────────────
    head("STEP 5 — Validation Queries")
    conn_main.autocommit = True
    for title, sql in VALIDATIONS:
        qprint(conn_main, sql, title=title)

    conn_main.close()

    print(f"\n{BOLD}{GREEN}{'='*60}")
    print("  PHASE 1 COMPLETE — Foundation is live!")
    print(f"  Main DB : {MAIN_DB}  (16 schemas + core tables)")
    print(f"  Repo DB : {REPO_DB}  (app settings + module registry)")
    print(f"  Data    : 1 tenant, 7 org units, 6 users,")
    print(f"            5 employees, 15 modules, 6 reporting periods")
    print(f"{'='*60}{RESET}\n")


if __name__ == "__main__":
    main()
