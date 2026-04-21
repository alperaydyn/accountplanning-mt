#!/usr/bin/env python3
"""
Account Planning — Phase 3 Execution Script
Runs 04_customer.sql DDL and seeds customer data.

Tables seeded:
  customer.customer              — 10 customers (5 corporate, 3 sme, 2 individual)
  customer.customer_segment      — tier + lifecycle segments
  customer.customer_relationship — corporate parent/subsidiary links
  customer.customer_product      — product holdings per customer
  customer.customer_product_metric — monthly balances/volumes
  customer.customer_transaction  — aggregated transaction summaries
  customer.customer_assignment   — RM assignments
  customer.consent               — KVKK consent records
  customer.data_retention_policy — 3 retention policies
  customer.customer_360_cache    — pre-built snapshot per customer
"""

import psycopg2
import psycopg2.extras
import time, os

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
        print(f"  {YELLOW}(no rows){RESET}"); return
    cols = list(rows[0].keys())
    w = {c: max(len(str(c)), max(len(str(r.get(c) or '')) for r in rows)) for c in cols}
    print("  " + " | ".join(str(c).ljust(w[c]) for c in cols))
    print("  " + "-+-".join("-"*w[c] for c in cols))
    for row in rows:
        print("  " + " | ".join(str(row.get(c) or '').ljust(w[c]) for c in cols))
    print(f"  {GREEN}({len(rows)} row{'s' if len(rows)!=1 else ''}){RESET}")


# ─────────────────────────────────────────────────────────────────────────────
# All column references taken directly from 04_customer.sql DDL
# CHECK constraints:
#   customer.customer_type         IN ('individual','corporate','sme')
#   customer_segment.segment_type  IN ('tier','segment','sub_segment','behavioral','value','risk','lifecycle')
#   customer_segment.source        IN ('core_system','analytics','manual')
#   customer_relationship.rel_type IN ('subsidiary','parent_company','group_member','spouse','family','guarantor','business_partner')
#   customer_product.status        IN ('active','closed','dormant','pending','suspended')
#   customer_transaction.period_type IN ('daily','weekly','monthly','quarterly','annual','ytd','fiscal_year')
#   customer_assignment.assignment_type IN ('primary','secondary','specialist','temporary')
#   customer_assignment.source     IN ('direct','branch_based','lob_based','auto_assigned','core_system')
#   consent.consent_type           IN ('data_processing','marketing','profiling','cross_sell','third_party_sharing','automated_decision','cross_border_transfer')
#   consent.status                 IN ('granted','revoked','expired')
#   data_retention_policy.action   IN ('anonymize','delete','archive')
#   customer_360_cache.refresh_source IN ('scheduled','event_triggered','manual','real_time')
# ─────────────────────────────────────────────────────────────────────────────

SEED_CUSTOMERS = """
-- ── 3.1 CUSTOMERS ────────────────────────────────────────────────────────────
-- 5 corporate, 3 SME, 2 individual
-- external_id = customer number from hypothetical core banking system
INSERT INTO customer.customer
    (id, tenant_id, external_id, customer_type, name,
     tax_id, contact_email, contact_phone,
     risk_profile, is_active)
VALUES
-- CORPORATE
('20000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',
    'CB-CORP-001','corporate','Arcelik Holding A.S.',
    '9010123456','finance@arcelik.example','02122345678',
    '{"credit_rating":"A+","sector":"manufacturing","employee_count":10000}',true),
('20000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001',
    'CB-CORP-002','corporate','Saray Insaat Ltd.',
    '9010234567','cfo@sarayinsaat.example','02124567890',
    '{"credit_rating":"BBB","sector":"construction","employee_count":250}',true),
('20000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001',
    'CB-CORP-003','corporate','Bosphorus Logistik A.S.',
    '9010345678','treasury@bosphorus.example','02121234567',
    '{"credit_rating":"A","sector":"logistics","employee_count":1200}',true),
('20000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001',
    'CB-CORP-004','corporate','Yildiz Gida Uretim A.S.',
    '9010456789','cfo@yildizgida.example','02129876543',
    '{"credit_rating":"AA-","sector":"food_beverage","employee_count":3500}',true),
('20000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001',
    'CB-CORP-005','corporate','Mavi Teknoloji A.S.',
    '9010567890','finance@maviteknoloji.example','02163456789',
    '{"credit_rating":"A-","sector":"technology","employee_count":450}',true),
-- SME
('20000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001',
    'CB-SME-001','sme','Demir Matbaa ve Ambalaj',
    '9020123456','demir.matbaa@example.com','05321234567',
    '{"credit_rating":"BB","sector":"printing","employee_count":25}',true),
('20000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000001',
    'CB-SME-002','sme','Ozturk Tekstil San.',
    '9020234567','ozturk.tekstil@example.com','05329876543',
    '{"credit_rating":"BB+","sector":"textiles","employee_count":80}',true),
('20000000-0000-0000-0000-000000000008','a0000000-0000-0000-0000-000000000001',
    'CB-SME-003','sme','Karadeniz Balikcilik',
    '9020345678','k.balikcilik@example.com','05323456789',
    '{"credit_rating":"B+","sector":"fishing","employee_count":15}',true),
-- INDIVIDUAL
('20000000-0000-0000-0000-000000000009','a0000000-0000-0000-0000-000000000001',
    'CB-IND-001','individual','Emre Aydin',
    NULL,'emre.aydin@example.com','05551234567',
    '{"risk_band":"medium","income_bracket":"upper_middle"}',true),
('20000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000001',
    'CB-IND-002','individual','Selin Arslan',
    NULL,'selin.arslan@example.com','05559876543',
    '{"risk_band":"low","income_bracket":"affluent"}',true)
ON CONFLICT (tenant_id, external_id) DO NOTHING;
"""

SEED_SEGMENTS = """
-- ── 3.2 CUSTOMER SEGMENTS ─────────────────────────────────────────────────────
-- tier + lifecycle segments for each customer
-- segment_type CHECK: tier|segment|sub_segment|behavioral|value|risk|lifecycle
-- source CHECK: core_system|analytics|manual
INSERT INTO customer.customer_segment
    (tenant_id, customer_id, segment_type, segment_code, segment_name,
     effective_from, source)
VALUES
-- Corporate tiers
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','tier','CORP_PREMIUM','Corporate Premium','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002','tier','CORP_STANDARD','Corporate Standard','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003','tier','CORP_PREMIUM','Corporate Premium','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004','tier','CORP_PREMIUM','Corporate Premium','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000005','tier','CORP_STANDARD','Corporate Standard','2025-01-01','core_system'),
-- SME tiers
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006','tier','SME_A','SME Tier A','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000007','tier','SME_A','SME Tier A','2025-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000008','tier','SME_B','SME Tier B','2025-01-01','core_system'),
-- Individual tiers
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009','tier','AFFLUENT','Affluent','2025-01-01','analytics'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000010','tier','PREMIER','Premier','2025-01-01','analytics'),
-- Lifecycle segments
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','lifecycle','MATURE','Mature Relationship','2023-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000005','lifecycle','GROWING','Growing Relationship','2024-06-01','analytics'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000008','lifecycle','AT_RISK','At-Risk Churn','2025-02-01','analytics'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009','lifecycle','ONBOARDING','Onboarding','2025-03-01','core_system')
ON CONFLICT DO NOTHING;
"""

SEED_RELATIONSHIPS = """
-- ── 3.3 CUSTOMER RELATIONSHIPS ────────────────────────────────────────────────
-- relationship_type CHECK: subsidiary|parent_company|group_member|spouse|family|guarantor|business_partner
INSERT INTO customer.customer_relationship
    (tenant_id, source_customer_id, target_customer_id, relationship_type, metadata, effective_from)
VALUES
-- Saray Insaat is a subsidiary of Arcelik Holding
('a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',
    'parent_company','{"ownership_pct":75}','2022-01-01'),
-- Bosphorus Logistik is a business partner of Arcelik
('a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003',
    'business_partner','{"relationship":"preferred_logistics_partner"}','2023-06-01'),
-- Karadeniz Balikcilik has Emre Aydin as guarantor
('a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000008','20000000-0000-0000-0000-000000000009',
    'guarantor','{"covers":"SME_LOAN_2025"}','2025-01-15')
ON CONFLICT (tenant_id, source_customer_id, target_customer_id, relationship_type) DO NOTHING;
"""

SEED_PRODUCTS = """
-- ── 3.4 CUSTOMER PRODUCTS ─────────────────────────────────────────────────────
-- status CHECK: active|closed|dormant|pending|suspended
INSERT INTO customer.customer_product
    (id, tenant_id, customer_id, product_id, product_version_id, status, start_date, attributes)
VALUES
-- Arcelik Holding: Cash Loan + Time Deposit + Gold Card
('30000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',
    '11000000-0000-0000-0000-000000000001','active','2024-03-01',
    '{"loan_amount":1500000,"tenor_months":48,"interest_rate":2.45}'),
('30000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004',
    NULL,'active','2024-03-01',
    '{"balance":2000000,"rate":35.5}'),
('30000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006',
    '11000000-0000-0000-0000-000000000002','active','2023-06-01',
    '{"credit_limit":100000,"cashback_earned":1250}'),
-- Saray Insaat: Standard Cash Loan + Demand Deposit
('30000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',
    '11000000-0000-0000-0000-000000000001','active','2024-09-01',
    '{"loan_amount":500000,"tenor_months":36,"interest_rate":2.89}'),
('30000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000005',
    NULL,'active','2024-09-01',
    '{"avg_balance":250000}'),
-- Bosphorus Logistik: Mortgage + Home Insurance
('30000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003',
    '11000000-0000-0000-0000-000000000004','active','2022-05-01',
    '{"property_value":8500000,"loan_amount":6000000,"tenor_years":15,"rate":3.25}'),
('30000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000008',
    NULL,'active','2022-05-01',
    '{"coverage_amount":8500000,"annual_premium":18500}'),
-- Yildiz Gida: Premium Cash Loan + Platinum Card + Time Deposit
('30000000-0000-0000-0000-000000000008','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002',
    '11000000-0000-0000-0000-000000000001','active','2023-11-01',
    '{"loan_amount":3000000,"tenor_months":60,"interest_rate":2.35}'),
('30000000-0000-0000-0000-000000000009','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000007',
    '11000000-0000-0000-0000-000000000003','active','2023-11-01',
    '{"credit_limit":500000,"cashback_earned":8750}'),
('30000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004',
    NULL,'active','2024-01-01',
    '{"balance":5000000,"rate":38.0}'),
-- Emre Aydin (individual): Gold Card + Demand Deposit
('30000000-0000-0000-0000-000000000011','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000006',
    '11000000-0000-0000-0000-000000000002','active','2025-03-01',
    '{"credit_limit":25000,"cashback_earned":125}'),
('30000000-0000-0000-0000-000000000012','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000005',
    NULL,'active','2025-03-01',
    '{"avg_balance":50000}'),
-- Selin Arslan (individual): Platinum Card + Mortgage + Home Insurance
('30000000-0000-0000-0000-000000000013','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000007',
    '11000000-0000-0000-0000-000000000003','active','2024-07-01',
    '{"credit_limit":150000,"cashback_earned":3200}'),
('30000000-0000-0000-0000-000000000014','a0000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000003',
    '11000000-0000-0000-0000-000000000004','active','2024-07-01',
    '{"property_value":4200000,"loan_amount":3000000,"tenor_years":20,"rate":3.25}')
ON CONFLICT DO NOTHING;
"""

SEED_METRICS = """
-- ── 3.5 CUSTOMER PRODUCT METRICS ──────────────────────────────────────────────
-- One row per customer_product × metric_code × reporting_period
-- period_label + period_type denormalized from core.reporting_period
INSERT INTO customer.customer_product_metric
    (tenant_id, customer_product_id, metric_code,
     reporting_period_id, period_label, period_type, period_start, period_end, value, unit)
VALUES
-- Arcelik: Premium Cash Loan — monthly utilization balance Mar 2025
('a0000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',
    'LOAN_OUTSTANDING_BAL',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly',
    '2025-03-01','2025-03-31',1425000.00,'TRY'),
-- Arcelik: Time Deposit — average balance Mar 2025
('a0000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002',
    'AVG_DEPOSIT_BAL',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly',
    '2025-03-01','2025-03-31',2000000.00,'TRY'),
-- Arcelik: Gold Card — monthly spend Mar 2025
('a0000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003',
    'CARD_SPEND_MONTHLY',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly',
    '2025-03-01','2025-03-31',85000.00,'TRY'),
-- Yildiz Gida: Platinum Card — monthly spend Mar 2025
('a0000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000009',
    'CARD_SPEND_MONTHLY',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly',
    '2025-03-01','2025-03-31',340000.00,'TRY'),
-- Selin Arslan: Mortgage — outstanding balance Apr 2025
('a0000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000014',
    'LOAN_OUTSTANDING_BAL',
    'e0000000-0000-0000-0000-000000000005','2025-04','monthly',
    '2025-04-01','2025-04-30',2887000.00,'TRY')
ON CONFLICT (tenant_id, customer_product_id, metric_code, reporting_period_id) DO NOTHING;
"""

SEED_TRANSACTIONS = """
-- ── 3.6 CUSTOMER TRANSACTIONS (aggregated) ────────────────────────────────────
-- period_type CHECK: daily|weekly|monthly|quarterly|annual|ytd|fiscal_year
INSERT INTO customer.customer_transaction
    (tenant_id, customer_id, transaction_type, amount, currency, channel,
     product_id, reporting_period_id, period_label, period_type, transaction_date)
VALUES
-- Arcelik: total wire transfers Mar 2025 (product-level)
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'wire_transfer',4200000.00,'TRY','branch',
    '10000000-0000-0000-0000-000000000005',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly','2025-03-01'),
-- Arcelik: POS transactions Mar 2025 (channel-level, product_id = NULL)
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'pos_transaction',85000.00,'TRY','digital',
    NULL,
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly','2025-03-01'),
-- Yildiz Gida: EFT payments Mar 2025
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'eft_payment',6750000.00,'TRY','internet_banking',
    '10000000-0000-0000-0000-000000000005',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly','2025-03-01'),
-- Emre Aydin: mobile payments Mar 2025
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009',
    'pos_transaction',12500.00,'TRY','mobile',
    '10000000-0000-0000-0000-000000000006',
    'e0000000-0000-0000-0000-000000000003','2025-03','monthly','2025-03-01'),
-- Selin Arslan: mortgage repayment Apr 2025
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000010',
    'loan_repayment',27500.00,'TRY','auto_debit',
    '10000000-0000-0000-0000-000000000003',
    'e0000000-0000-0000-0000-000000000005','2025-04','monthly','2025-04-01')
ON CONFLICT DO NOTHING;
"""

SEED_ASSIGNMENTS = """
-- ── 3.7 CUSTOMER-RM ASSIGNMENTS ───────────────────────────────────────────────
-- assignment_type CHECK: primary|secondary|specialist|temporary
-- source CHECK: direct|branch_based|lob_based|auto_assigned|core_system
INSERT INTO customer.customer_assignment
    (tenant_id, customer_id, employee_id, assignment_type, effective_from, source)
VALUES
-- Mehmet Kaya (EMP003 Senior RM) is primary for corporate clients
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000003','primary','2024-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003',
    'd0000000-0000-0000-0000-000000000003','primary','2024-01-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000003','primary','2023-11-01','core_system'),
-- Fatma Ozkan (EMP004 RM) covers SME and corporate-standard
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000004','primary','2024-09-01','core_system'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000005',
    'd0000000-0000-0000-0000-000000000004','primary','2025-01-01','direct'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000004','primary','2025-01-01','branch_based'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000007',
    'd0000000-0000-0000-0000-000000000004','primary','2025-01-01','branch_based'),
-- Ali Celik (EMP005 Junior RM) covers remaining + as secondary
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000008',
    'd0000000-0000-0000-0000-000000000005','primary','2025-01-01','branch_based'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009',
    'd0000000-0000-0000-0000-000000000005','primary','2025-03-01','direct'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000010',
    'd0000000-0000-0000-0000-000000000005','primary','2024-07-01','direct'),
-- Mehmet Kaya as secondary on Yildiz Gida (strategic account, dual coverage)
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000004','secondary','2024-01-01','direct')
ON CONFLICT DO NOTHING;
"""

SEED_CONSENTS = """
-- ── 3.8 KVKK CONSENTS ─────────────────────────────────────────────────────────
-- consent_type CHECK: data_processing|marketing|profiling|cross_sell|third_party_sharing|automated_decision|cross_border_transfer
-- status CHECK: granted|revoked|expired
INSERT INTO customer.consent
    (tenant_id, customer_id, consent_type, status,
     granted_at, legal_basis, purpose, channel)
VALUES
-- All 10 customers: data_processing (mandatory, legal obligation basis)
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'data_processing','granted','2024-03-01 09:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',
    'data_processing','granted','2024-09-01 09:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003',
    'data_processing','granted','2022-05-01 10:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'data_processing','granted','2023-11-01 09:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009',
    'data_processing','granted','2025-03-01 11:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','digital'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000010',
    'data_processing','granted','2024-07-01 14:00:00+03',
    'KVKK_Art5_b_contract','Processing for banking contract fulfilment','digital'),
-- Marketing consents (opt-in; some customers declined)
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'marketing','granted','2024-03-01 09:05:00+03',
    'KVKK_Art5_a_consent','Receiving product and campaign communications','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'marketing','granted','2023-11-01 09:05:00+03',
    'KVKK_Art5_a_consent','Receiving product and campaign communications','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009',
    'marketing','granted','2025-03-01 11:05:00+03',
    'KVKK_Art5_a_consent','Receiving product and campaign communications','digital'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000010',
    'marketing','revoked','2025-01-15 08:00:00+03',
    'KVKK_Art5_a_consent','Receiving product and campaign communications','digital'),
-- Profiling / automated_decision consents for AI
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    'profiling','granted','2024-03-01 09:10:00+03',
    'KVKK_Art5_a_consent','Customer behavioural profiling for product recommendations','branch'),
('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004',
    'automated_decision','granted','2023-11-01 09:10:00+03',
    'KVKK_Art5_a_consent','AI-assisted credit and offer recommendations','branch')
ON CONFLICT DO NOTHING;
"""

SEED_RETENTION = """
-- ── 3.9 DATA RETENTION POLICIES ───────────────────────────────────────────────
-- action_on_expiry CHECK: anonymize|delete|archive
INSERT INTO customer.data_retention_policy
    (tenant_id, data_category, retention_period_days, action_on_expiry, legal_basis, is_active)
VALUES
('a0000000-0000-0000-0000-000000000001',
    'pii_contact_data',3650,'anonymize',
    'KVKK_Art7_purpose_limitation',true),
('a0000000-0000-0000-0000-000000000001',
    'transaction_history',3650,'archive',
    'KVKK_Art7_legal_obligation',true),
('a0000000-0000-0000-0000-000000000001',
    'consent_records',1095,'archive',
    'KVKK_Art7_3yr_post_revocation',true),
('a0000000-0000-0000-0000-000000000001',
    'audit_logs',1825,'archive',
    'KVKK_Art12_security_5yr',true),
('a0000000-0000-0000-0000-000000000001',
    'ai_reasoning_logs',730,'delete',
    'KVKK_Art22_automated_processing',true)
ON CONFLICT (tenant_id, data_category) DO NOTHING;
"""

SEED_C360 = """
-- ── 3.10 CUSTOMER 360 CACHE ───────────────────────────────────────────────────
-- refresh_source CHECK: scheduled|event_triggered|manual|real_time
INSERT INTO customer.customer_360_cache
    (customer_id, tenant_id,
     profile_snapshot, product_summary, segment_summary,
     relationship_summary, performance_summary, analytics_summary,
     action_summary, risk_summary,
     last_refreshed_at, refresh_source, version)
VALUES
-- Arcelik Holding (flagship corporate customer)
('20000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',
    '{"name":"Arcelik Holding A.S.","type":"corporate","tax_id":"9010123456","sector":"manufacturing"}',
    '{"total_products":3,"active_products":3,"product_codes":["CASH_LOAN_PREMIUM","TIME_DEP_3M","CC_GOLD"],"estimated_aum":3585000}',
    '{"primary_tier":"CORP_PREMIUM","lifecycle":"MATURE"}',
    '{"subsidiaries":["CB-CORP-002"],"partners":["CB-CORP-003"]}',
    '{"loan_outstanding":1425000,"deposit_balance":2000000,"card_monthly_spend":85000}',
    '{"churn_score":0.05,"nbo":"PLATINUM_UPGRADE","model_version":"v2.1"}',
    '{"open_actions":2,"overdue_actions":0}',
    '{"credit_rating":"A+","risk_band":"low"}',
    now(),'scheduled',1),
-- Yildiz Gida (high-value corporate)
('20000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000001',
    '{"name":"Yildiz Gida Uretim A.S.","type":"corporate","sector":"food_beverage"}',
    '{"total_products":3,"active_products":3,"product_codes":["CASH_LOAN_PREMIUM","CC_PLATINUM","TIME_DEP_3M"],"estimated_aum":8340000}',
    '{"primary_tier":"CORP_PREMIUM","lifecycle":"MATURE"}',
    '{}',
    '{"loan_outstanding":2950000,"deposit_balance":5000000,"card_monthly_spend":340000}',
    '{"churn_score":0.08,"nbo":"HOME_INSURANCE","model_version":"v2.1"}',
    '{"open_actions":1,"overdue_actions":0}',
    '{"credit_rating":"AA-","risk_band":"low"}',
    now(),'scheduled',1),
-- Emre Aydin (individual, onboarding)
('20000000-0000-0000-0000-000000000009','a0000000-0000-0000-0000-000000000001',
    '{"name":"Emre Aydin","type":"individual","income_bracket":"upper_middle"}',
    '{"total_products":2,"active_products":2,"product_codes":["CC_GOLD","DEMAND_DEP_TL"]}',
    '{"primary_tier":"AFFLUENT","lifecycle":"ONBOARDING"}',
    '{}',
    '{"card_monthly_spend":12500,"deposit_balance":50000}',
    '{"churn_score":0.15,"nbo":"CASH_LOAN_STD","model_version":"v2.1"}',
    '{"open_actions":1,"overdue_actions":0}',
    '{"risk_band":"medium"}',
    now(),'event_triggered',1),
-- Selin Arslan (individual, premier)
('20000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000001',
    '{"name":"Selin Arslan","type":"individual","income_bracket":"affluent"}',
    '{"total_products":2,"active_products":2,"product_codes":["CC_PLATINUM","MORTGAGE_FIXED"]}',
    '{"primary_tier":"PREMIER","lifecycle":"MATURE"}',
    '{}',
    '{"mortgage_outstanding":2887000,"card_monthly_spend":0}',
    '{"churn_score":0.04,"nbo":"HOME_INSURANCE","model_version":"v2.1"}',
    '{"open_actions":0,"overdue_actions":0}',
    '{"risk_band":"low"}',
    now(),'scheduled',1)
ON CONFLICT (customer_id) DO NOTHING;
"""

VALIDATIONS = [
    ("V3.1 — Customer mix (type × count)",
     """SELECT customer_type, count(*) as count
        FROM customer.customer
        WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001'
          AND deleted_at IS NULL
        GROUP BY customer_type ORDER BY customer_type;"""),

    ("V3.2 — Customer→RM assignments (primary only)",
     """SELECT c.name as customer, u.display_name as rm, e.title, ca.assignment_type
        FROM customer.customer_assignment ca
        JOIN customer.customer c    ON c.id  = ca.customer_id
        JOIN core.employee e        ON e.id  = ca.employee_id
        JOIN core.user_ u           ON u.id  = e.user_id
        WHERE ca.tenant_id = 'a0000000-0000-0000-0000-000000000001'
          AND ca.assignment_type = 'primary'
          AND ca.effective_until IS NULL
        ORDER BY u.display_name, c.name;"""),

    ("V3.3 — Product holdings per customer",
     """SELECT c.name as customer, p.code as product, cp.status, cp.start_date
        FROM customer.customer_product cp
        JOIN customer.customer c ON c.id = cp.customer_id
        JOIN product.product p   ON p.id = cp.product_id
        WHERE cp.tenant_id = 'a0000000-0000-0000-0000-000000000001'
        ORDER BY c.name, p.code;"""),

    ("V3.4 — KVKK consent summary",
     """SELECT consent_type,
               sum(CASE WHEN status='granted' THEN 1 ELSE 0 END) as granted,
               sum(CASE WHEN status='revoked' THEN 1 ELSE 0 END) as revoked
        FROM customer.consent
        WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001'
        GROUP BY consent_type ORDER BY consent_type;"""),

    ("V3.5 — Customer 360 cache — NBO per customer",
     """SELECT c.name,
               cache.segment_summary->>'primary_tier' as tier,
               cache.analytics_summary->>'nbo' as next_best_offer,
               (cache.analytics_summary->>'churn_score')::numeric as churn_score,
               cache.refresh_source
        FROM customer.customer_360_cache cache
        JOIN customer.customer c ON c.id = cache.customer_id
        ORDER BY churn_score DESC;"""),

    ("V3.6 — Data retention policies",
     """SELECT data_category, retention_period_days, action_on_expiry
        FROM customer.data_retention_policy
        WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001'
        ORDER BY retention_period_days DESC;"""),
]


def main():
    head("PHASE 3 — Customer & Compliance  (04_customer.sql)")
    conn = connect()

    head("STEP 1 — DDL: customer tables")
    run_file(conn, "sql/04_customer.sql")

    head("STEP 2a — Seed: customers")
    exec_sql(conn, SEED_CUSTOMERS, "customers")

    head("STEP 2b — Seed: segments")
    exec_sql(conn, SEED_SEGMENTS, "segments")

    head("STEP 2c — Seed: relationships")
    exec_sql(conn, SEED_RELATIONSHIPS, "relationships")

    head("STEP 2d — Seed: customer products")
    exec_sql(conn, SEED_PRODUCTS, "customer_products")

    head("STEP 2e — Seed: product metrics")
    exec_sql(conn, SEED_METRICS, "product_metrics")

    head("STEP 2f — Seed: transactions")
    exec_sql(conn, SEED_TRANSACTIONS, "transactions")

    head("STEP 2g — Seed: RM assignments")
    exec_sql(conn, SEED_ASSIGNMENTS, "assignments")

    head("STEP 2h — Seed: consents")
    exec_sql(conn, SEED_CONSENTS, "consents")

    head("STEP 2i — Seed: data retention policies")
    exec_sql(conn, SEED_RETENTION, "retention_policies")

    head("STEP 2j — Seed: Customer 360 cache")
    exec_sql(conn, SEED_C360, "customer_360_cache")

    head("STEP 3 — Validation Queries")
    conn.autocommit = True
    for title, sql in VALIDATIONS:
        qprint(conn, sql, title=title)

    conn.close()
    print(f"\n{BOLD}{GREEN}{'='*60}")
    print("  PHASE 3 COMPLETE — Customer data is live!")
    print("  10 customers  (5 corporate, 3 SME, 2 individual)")
    print("  14 product holdings across 8 products")
    print("  10 RM assignments")
    print("  12 KVKK consent records")
    print("  5 data retention policies")
    print("  4 Customer 360 cache entries with NBO signals")
    print(f"{'='*60}{RESET}\n")


if __name__ == "__main__":
    main()
