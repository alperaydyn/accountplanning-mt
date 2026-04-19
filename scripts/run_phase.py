#!/usr/bin/env python3
"""
Account Planning — Phase Runner
Connects to PostgreSQL via environment variables and executes SQL files / inline SQL.
Usage: python3 run_phase.py <sql_file_or_inline_sql>
"""

import psycopg2
import psycopg2.extras
import sys
import os
import time

# ── Connection config ─────────────────────────────────────────────────────────
CONFIG = {
    "host":     os.environ.get("DB_HOST", "76.13.60.86"),
    "port":     int(os.environ.get("DB_PORT", 5432)),
    "user":     os.environ.get("DB_USER", "ap_user_001"),
    "password": os.environ.get("DB_PASSWORD", "apuser!23"),
    "dbname":   os.environ.get("DB_NAME", "accountplanning"),
}

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def ok(msg):    print(f"{GREEN}✅ {msg}{RESET}")
def err(msg):   print(f"{RED}❌ {msg}{RESET}")
def info(msg):  print(f"{CYAN}ℹ  {msg}{RESET}")
def warn(msg):  print(f"{YELLOW}⚠  {msg}{RESET}")
def head(msg):  print(f"\n{BOLD}{CYAN}{'='*60}\n{msg}\n{'='*60}{RESET}\n")

def connect():
    try:
        conn = psycopg2.connect(**CONFIG)
        conn.autocommit = False
        ok(f"Connected to {CONFIG['dbname']} @ {CONFIG['host']}:{CONFIG['port']}")
        return conn
    except Exception as e:
        err(f"Connection failed: {e}")
        sys.exit(1)

def run_sql(conn, sql: str, label: str = ""):
    """Execute a multi-statement SQL block inside a single transaction."""
    cursor = conn.cursor()
    label_str = f" [{label}]" if label else ""
    info(f"Executing{label_str}...")
    start = time.time()
    try:
        # Split on statement boundaries and skip empties
        statements = [s.strip() for s in sql.split(';') if s.strip() and not s.strip().startswith('--')]
        count = 0
        for stmt in statements:
            cursor.execute(stmt)
            count += 1
        conn.commit()
        elapsed = time.time() - start
        ok(f"Completed {count} statements in {elapsed:.2f}s{label_str}")
    except Exception as e:
        conn.rollback()
        err(f"Failed{label_str}: {e}")
        print(f"  Failed SQL (first 300 chars): {sql[:300]}")
        raise
    finally:
        cursor.close()

def run_file(conn, path: str):
    """Execute a SQL file."""
    if not os.path.exists(path):
        err(f"File not found: {path}")
        sys.exit(1)
    with open(path, 'r') as f:
        sql = f.read()
    info(f"Running file: {os.path.basename(path)}")
    run_sql(conn, sql, label=os.path.basename(path))

def query(conn, sql: str, label: str = ""):
    """Run a SELECT and print results as a table."""
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cursor.execute(sql)
        rows = cursor.fetchall()
        if label:
            print(f"\n{BOLD}{label}{RESET}")
        if not rows:
            warn("  (no rows returned)")
            return rows
        # Print header
        cols = list(rows[0].keys())
        col_w = {c: max(len(c), max(len(str(r[c])) for r in rows)) for c in cols}
        header = "  " + "  |  ".join(c.ljust(col_w[c]) for c in cols)
        sep    = "  " + "--+--".join("-" * col_w[c] for c in cols)
        print(header)
        print(sep)
        for row in rows:
            print("  " + "  |  ".join(str(row[c]).ljust(col_w[c]) for c in cols))
        print(f"  ({len(rows)} row{'s' if len(rows) != 1 else ''})")
        return rows
    except Exception as e:
        err(f"Query failed: {e}")
        return []
    finally:
        cursor.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 run_phase.py <sql_file.sql>")
        sys.exit(1)
    conn = connect()
    for arg in sys.argv[1:]:
        run_file(conn, arg)
    conn.close()
