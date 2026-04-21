#!/usr/bin/env python3
"""
Account Planning — Phase 2 Execution Script
Runs 03_product.sql DDL and seeds product catalog data.
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

GREEN  = "\033[92m"; RED = "\033[91m"; YELLOW = "\033[93m"
CYAN   = "\033[96m"; BOLD = "\033[1m"; RESET = "\033[0m"

def ok(m):   print(f"{GREEN}✅ {m}{RESET}")
def err(m):  print(f"{RED}❌ {m}{RESET}")
def info(m): print(f"{CYAN}ℹ  {m}{RESET}")
def head(m): print(f"\n{BOLD}{CYAN}{'='*60}\n   {m}\n{'='*60}{RESET}\n")

def connect():
    return psycopg2.connect(
        host=HOST, port=PORT, user=USER, password=PASSWORD,
        dbname=MAIN_DB, connect_timeout=10
    )

def exec_sql(conn, sql, label=""):
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
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cur.execute(sql)
        rows = cur.fetchall()
    except Exception as e:
        err(f"Query failed ({title}): {e}")
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


# ── Seed SQL ──────────────────────────────────────────────────────────────────
# Column reference from 03_product.sql:
#   product.category       : id, tenant_id, parent_id, code, name, level, display_order, is_active
#   product.category_closure : ancestor_id, descendant_id, depth, tenant_id
#   product.product        : id, tenant_id, category_id, code, name, description,
#                            specifications, has_lifecycle, lifecycle_status,
#                            lifecycle_effective_date, is_active
#   product.product_version : id, tenant_id, product_id, version_number, version_label,
#                             specifications, terms, change_summary, is_current,
#                             effective_from, effective_until, created_by, approved_by
#   product.product_relationship : id, tenant_id, source_product_id, target_product_id,
#                                  relationship_type, strength, metadata, is_active
#
# CHECK constraints from DDL:
#   product.lifecycle_status  IN ('draft','active','discontinued','sunset')
#   product_relationship.relationship_type IN ('bundle','cross_sell','upsell','prerequisite','complementary','substitute')
#   product_relationship.strength BETWEEN 0.00 AND 1.00

SEED_SQL = """
-- ============================================================
-- PHASE 2 SEED: Product Catalog
-- ============================================================

-- 2.1  Product Categories (3-level tree)
-- Level 0 = root, Level 1 = main category, Level 2 = sub-category
INSERT INTO product.category (id, tenant_id, parent_id, code, name, level, display_order, is_active) VALUES
('f0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',NULL,
    'FINANCIAL','Financial Products',0,1,true),
('f0000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',
    'LOANS','Loans',1,1,true),
('f0000000-0000-0000-0000-000000000011','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',
    'DEPOSITS','Deposits',1,2,true),
('f0000000-0000-0000-0000-000000000012','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',
    'CARDS','Credit Cards',1,3,true),
('f0000000-0000-0000-0000-000000000013','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',
    'INSURANCE','Insurance',1,4,true),
('f0000000-0000-0000-0000-000000000020','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000010',
    'TL_CASH','TL Cash Loans',2,1,true),
('f0000000-0000-0000-0000-000000000021','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000010',
    'MORTGAGE','Mortgage Loans',2,2,true),
('f0000000-0000-0000-0000-000000000022','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000011',
    'TIME_DEPOSIT','Time Deposits',2,1,true),
('f0000000-0000-0000-0000-000000000023','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000011',
    'DEMAND_DEPOSIT','Demand Deposits',2,2,true)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- 2.2  Category Closure (all ancestor-descendant pairs, depth 0 = self)
INSERT INTO product.category_closure (ancestor_id, descendant_id, depth, tenant_id) VALUES
-- Self-refs (depth 0)
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000010',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000011',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000012','f0000000-0000-0000-0000-000000000012',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000013','f0000000-0000-0000-0000-000000000013',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000020','f0000000-0000-0000-0000-000000000020',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000021','f0000000-0000-0000-0000-000000000021',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000022','f0000000-0000-0000-0000-000000000022',0,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000023','f0000000-0000-0000-0000-000000000023',0,'a0000000-0000-0000-0000-000000000001'),
-- FINANCIAL -> level 1 (depth 1)
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000010',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000011',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000013',1,'a0000000-0000-0000-0000-000000000001'),
-- FINANCIAL -> level 2 (depth 2)
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000021',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000022',2,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000023',2,'a0000000-0000-0000-0000-000000000001'),
-- LOANS -> level 2 (depth 1)
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000020',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000010','f0000000-0000-0000-0000-000000000021',1,'a0000000-0000-0000-0000-000000000001'),
-- DEPOSITS -> level 2 (depth 1)
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000022',1,'a0000000-0000-0000-0000-000000000001'),
('f0000000-0000-0000-0000-000000000011','f0000000-0000-0000-0000-000000000023',1,'a0000000-0000-0000-0000-000000000001')
ON CONFLICT (ancestor_id, descendant_id) DO NOTHING;

-- 2.3  Products (8 products, all active)
INSERT INTO product.product (id, tenant_id, category_id, code, name, description, specifications, has_lifecycle, lifecycle_status) VALUES
('10000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',
    'CASH_LOAN_STD','Standard Cash Loan','Standard TL cash loan for individuals',
    '{"max_tenor_months":60,"min_amount":5000,"max_amount":500000}',true,'active'),
('10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000020',
    'CASH_LOAN_PREMIUM','Premium Cash Loan','Lower rates for high-value customers',
    '{"max_tenor_months":84,"min_amount":50000,"max_amount":2000000}',true,'active'),
('10000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000021',
    'MORTGAGE_FIXED','Fixed-Rate Mortgage','15-30 year fixed-rate home loan',
    '{"max_tenor_years":30,"ltv_max_pct":80}',true,'active'),
('10000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000022',
    'TIME_DEP_3M','3-Month Time Deposit','Short-term TL time deposit',
    '{"tenor_months":3,"min_amount":10000}',true,'active'),
('10000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000023',
    'DEMAND_DEP_TL','TL Demand Deposit','Standard TL current account',
    '{"min_balance":0}',true,'active'),
('10000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',
    'CC_GOLD','Gold Credit Card','Gold tier credit card',
    '{"credit_limit_range":[5000,100000],"cashback_pct":0.5}',true,'active'),
('10000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000012',
    'CC_PLATINUM','Platinum Credit Card','Platinum tier with lounge access',
    '{"credit_limit_range":[25000,500000],"cashback_pct":1.5,"lounge_access":true}',true,'active'),
('10000000-0000-0000-0000-000000000008','a0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000013',
    'HOME_INSURANCE','Home Insurance','Property insurance for mortgage holders',
    '{"coverage_types":["fire","earthquake","flood"]}',true,'active')
ON CONFLICT (tenant_id, code) DO NOTHING;

-- 2.4  Product Versions (current versions for 3 key products)
INSERT INTO product.product_version (id, tenant_id, product_id, version_number, version_label,
    specifications, terms, change_summary, is_current, effective_from, created_by) VALUES
('11000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',1,'2025 Launch',
    '{"max_tenor_months":60}','{"interest_rate_pct":2.89,"admin_fee_pct":1.0}',
    'Initial launch terms',true,'2025-01-01','b0000000-0000-0000-0000-000000000001'),
('11000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000006',1,'2025 Gold Launch',
    '{}','{"annual_fee":250,"cashback_pct":0.5}',
    'Gold card launch',true,'2025-01-01','b0000000-0000-0000-0000-000000000001'),
('11000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000007',1,'2025 Platinum Launch',
    '{}','{"annual_fee":0,"cashback_pct":1.5,"lounge_access":true}',
    'Platinum card launch - zero annual fee promo',true,'2025-01-01','b0000000-0000-0000-0000-000000000001'),
('11000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000003',1,'2025 Mortgage Terms',
    '{"ltv_max_pct":80}','{"fixed_rate_pct":3.25,"max_tenor_years":30}',
    'Fixed-rate mortgage initial terms',true,'2025-01-01','b0000000-0000-0000-0000-000000000001')
ON CONFLICT (product_id, version_number) DO NOTHING;

-- 2.5  Product Relationships
-- relationship_type CHECK: bundle|cross_sell|upsell|prerequisite|complementary|substitute
INSERT INTO product.product_relationship (tenant_id, source_product_id, target_product_id, relationship_type, strength, metadata) VALUES
-- Gold Card -> Platinum Card (upsell, 70% signal strength)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000007',
    'upsell',0.70,'{"upsell_threshold_monthly_spend":3000}'),
-- Mortgage -> Home Insurance (complementary, 85% — frequently sold together)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000008',
    'complementary',0.85,'{"trigger":"mortgage_originated"}'),
-- Credit Card -> Demand Deposit (prerequisite — customer needs current account first)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000005',
    'prerequisite',1.00,'{}'),
-- Standard Cash Loan -> Premium Cash Loan (upsell for high-balance customers)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',
    'upsell',0.60,'{"trigger":"loan_balance_above_200k"}'),
-- Standard Cash Loan -> Time Deposit (cross-sell — borrow and save)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004',
    'cross_sell',0.55,'{"rationale":"liquidity_buffer"}'),
-- Platinum Card -> Home Insurance (cross_sell — affluent segment often takes insurance)
('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000008',
    'cross_sell',0.45,'{"segment":"affluent"}')
ON CONFLICT (tenant_id, source_product_id, target_product_id, relationship_type) DO NOTHING;
"""

VALIDATIONS = [
    ("V2.1 — Category tree (9 nodes)",
     """SELECT level, code, name,
               CASE WHEN parent_id IS NULL THEN 'root' ELSE 'child' END as position
        FROM product.category
        WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001'
        ORDER BY level, display_order;"""),

    ("V2.2 — All products under LOANS (via closure table)",
     """SELECT p.code, p.name, c.code as category_code, cc.depth as cat_depth
        FROM product.product p
        JOIN product.category c ON c.id = p.category_id
        JOIN product.category_closure cc ON cc.descendant_id = c.id
        WHERE cc.ancestor_id = 'f0000000-0000-0000-0000-000000000010'
          AND cc.tenant_id = 'a0000000-0000-0000-0000-000000000001'
        ORDER BY p.code;"""),

    ("V2.3 — Current product version for Gold Card",
     """SELECT p.name, pv.version_number, pv.version_label, pv.effective_from, pv.terms
        FROM product.product_version pv
        JOIN product.product p ON p.id = pv.product_id
        WHERE pv.is_current = true AND p.code = 'CC_GOLD';"""),

    ("V2.4 — Recommendations from Gold Card (relationships)",
     """SELECT src.code as from_product, tgt.code as to_product,
               pr.relationship_type, pr.strength
        FROM product.product_relationship pr
        JOIN product.product src ON src.id = pr.source_product_id
        JOIN product.product tgt ON tgt.id = pr.target_product_id
        WHERE src.code = 'CC_GOLD'
        ORDER BY pr.strength DESC;"""),

    ("V2.5 — Product catalog summary by category",
     """SELECT c.name as category, count(p.id) as product_count
        FROM product.category c
        LEFT JOIN product.product p ON p.category_id = c.id
          AND p.tenant_id = 'a0000000-0000-0000-0000-000000000001'
        WHERE c.tenant_id = 'a0000000-0000-0000-0000-000000000001'
          AND c.level > 0
        GROUP BY c.name, c.level, c.display_order
        ORDER BY c.level, c.display_order;"""),
]


def main():
    head("PHASE 2 — Product Catalog  (03_product.sql)")
    conn = connect()

    # Step 1: Run DDL
    head("STEP 1 — DDL: product tables")
    run_file(conn, "sql/03_product.sql")

    # Step 2: Seed
    head("STEP 2 — Seed: categories, products, versions, relationships")
    exec_sql(conn, SEED_SQL, label="phase2_seed")

    # Step 3: Validate
    head("STEP 3 — Validation Queries")
    conn.autocommit = True
    for title, sql in VALIDATIONS:
        qprint(conn, sql, title=title)

    conn.close()

    print(f"\n{BOLD}{GREEN}{'='*60}")
    print("  PHASE 2 COMPLETE — Product Catalog is live!")
    print("  9 categories (3-level tree + closure table)")
    print("  8 products (loans, deposits, cards, insurance)")
    print("  4 product versions")
    print("  6 product relationships (upsell, complementary,")
    print("    cross_sell, prerequisite)")
    print(f"{'='*60}{RESET}\n")


if __name__ == "__main__":
    main()
