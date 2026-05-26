#!/usr/bin/env python3
"""
One-shot script to seed a fresh MariaDB for the AoTv3 devcontainer.

What it does:
  1. Connects to MariaDB on localhost:3307 (devcontainer port-forward) as peq
     - If the peq user/database doesn't exist yet it prints the one sudo mysql
       command to run inside the container, then exits.
  2. Downloads the PEQ archive and imports all tables into `peq`
  3. Creates the db_migrations tracking table

Run from Windows (with devcontainer running):
    python aot_seed_peq.py

Requires:
    pip install pymysql
"""

import os
import sys
import tempfile
import urllib.request
import zipfile

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("ERROR: pymysql not installed.  Run: pip3 install pymysql")
    sys.exit(1)

# ── Config ────────────────────────────────────────────────────────────────────
# Port 3307 = devcontainer MariaDB forwarded to Windows host
DB_HOST     = os.environ.get("SEED_HOST", "127.0.0.1")
DB_PORT     = int(os.environ.get("SEED_PORT", "3307"))
DB_NAME     = os.environ.get("SEED_DB",   "peq")
DB_USER     = os.environ.get("SEED_USER", "peq")
DB_PASS     = os.environ.get("SEED_PASS", "peqpass")
PEQ_ZIP_URL = "https://github.com/peqarchive/peqdatabase/raw/main/peq-latest.zip"



# ── SQL parser (handles backslash escapes + doubled-quote escapes) ─────────────

def split_sql(sql):
    statements = []
    current = []
    in_string = False
    string_char = None
    i = 0
    while i < len(sql):
        c = sql[i]
        if not in_string and sql[i:i+2] == '--':
            while i < len(sql) and sql[i] != '\n':
                i += 1
            continue
        if in_string:
            current.append(c)
            if c == '\\':
                i += 1
                if i < len(sql):
                    current.append(sql[i])
            elif c == string_char:
                if i + 1 < len(sql) and sql[i + 1] == string_char:
                    current.append(sql[i + 1])
                    i += 2
                    continue
                in_string = False
        elif c in ("'", '"'):
            in_string = True
            string_char = c
            current.append(c)
        elif c == ';':
            stmt = ''.join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
        else:
            current.append(c)
        i += 1
    stmt = ''.join(current).strip()
    if stmt:
        statements.append(stmt)
    return [s for s in statements if s]


# ── Step 1: Verify peq user/database exists (must be done manually in container) ─

BOOTSTRAP_SQL = (
    "CREATE DATABASE IF NOT EXISTS `peq` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n"
    "CREATE USER IF NOT EXISTS 'peq'@'%' IDENTIFIED BY 'peqpass';\n"
    "GRANT ALL PRIVILEGES ON `peq`.* TO 'peq'@'%';\n"
    "FLUSH PRIVILEGES;"
)


def check_connection():
    """Try to connect; if it fails, print the manual bootstrap instructions and exit."""
    try:
        c = connect()
        c.close()
    except Exception as e:
        print(f"[seed] Cannot connect to MariaDB as peq: {e}")
        print()
        print("  The peq database/user doesn't exist yet.")
        print("  In the devcontainer terminal, run:")
        print()
        print("    sudo mysql <<'EOF'")
        for line in BOOTSTRAP_SQL.strip().splitlines():
            print(f"    {line}")
        print("    EOF")
        print()
        print("  Then re-run this script.")
        sys.exit(1)


# ── Step 2: Connect as peq ────────────────────────────────────────────────────

def connect():
    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        autocommit=True,
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor,
    )


# ── Step 3: Seed from PEQ archive ─────────────────────────────────────────────

def seed_from_archive(conn):
    skip_prefixes = (
        'DROP ', 'USE ', 'ALTER ', 'SET ',
        'LOCK ', 'UNLOCK ', 'DELETE ', 'TRUNCATE ', 'SOURCE ', '/*',
    )

    print(f"[seed] Downloading PEQ archive (may take a while)...")
    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = os.path.join(tmpdir, "peq-latest.zip")

        def reporthook(count, block, total):
            if total > 0:
                pct = min(count * block * 100 // total, 100)
                print(f"\r  downloading ... {pct}%", end='', flush=True)

        urllib.request.urlretrieve(PEQ_ZIP_URL, zip_path, reporthook=reporthook)
        print()

        print("[seed] Extracting...")
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(tmpdir)

        sql_files = sorted(
            os.path.join(root, f)
            for root, _, files in os.walk(tmpdir)
            for f in files
            if f.endswith('.sql')
        )
        if not sql_files:
            print("[seed] WARNING: no .sql files found in archive")
            return

        print(f"[seed] Importing all tables from {len(sql_files)} SQL file(s)...")
        with conn.cursor() as cur:
            for sql_file in sql_files:
                print(f"  {os.path.basename(sql_file)} ...", end='', flush=True)
                with open(sql_file, 'r', encoding='utf-8', errors='replace') as f:
                    sql = f.read()
                imported = errors = 0
                for stmt in split_sql(sql):
                    stripped = stmt.strip()
                    upper = stripped.upper()

                    # Skip destructive / session-level statements
                    if any(upper.startswith(kw) for kw in skip_prefixes):
                        continue

                    try:
                        cur.execute(stmt)
                        imported += 1
                    except Exception as e:
                        errors += 1
                        if errors <= 5:
                            print(f"\n    ERROR: {e} | stmt: {stmt[:120]}")
                print(f" {imported} ok, {errors} errors")

    print("[seed] Archive import complete.")


# ── Step 4: Create db_migrations table ────────────────────────────────────────

def create_migrations_table(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS db_migrations (
                id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                filename   VARCHAR(255) NOT NULL UNIQUE,
                applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
    print("[seed] db_migrations table ready.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    check_connection()

    print("[seed] Connecting as peq...")
    conn = connect()
    print("[seed] Connected.")

    # Check if the DB is already populated by probing the items table
    already_seeded = False
    with conn.cursor() as cur:
        try:
            cur.execute("SELECT COUNT(*) AS cnt FROM `items`")
            already_seeded = cur.fetchone()['cnt'] > 0
        except Exception:
            pass  # table doesn't exist yet

    if already_seeded:
        print("[seed] Database already has data — nothing to seed.")
    else:
        seed_from_archive(conn)

    create_migrations_table(conn)
    print("\n[seed] Done. Run aot_migrate.py next to apply AoT-specific migrations.")


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n[seed] Interrupted.")
    except Exception as e:
        import traceback
        print(f"\n[seed] Unexpected error: {e}")
        traceback.print_exc()
