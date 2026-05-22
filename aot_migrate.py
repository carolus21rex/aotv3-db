#!/usr/bin/env python3
"""
AoTv3 database migration runner.
Pulls the latest migrations from git and applies any that have not been run yet.

Setup (once):
    pip install pymysql
    cp config.example.ini config.ini
    # fill in your database details in config.ini

Usage:
    python aot_migrate.py
    # or double-click if compiled with PyInstaller
"""

import os
import sys
import configparser
import subprocess

try:
    import pymysql
except ImportError:
    print("ERROR: pymysql not installed.  Run: pip install pymysql")
    input("\nPress Enter to close...")
    sys.exit(1)


def get_base_dir():
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def load_config():
    path = os.path.join(get_base_dir(), 'config.ini')
    if not os.path.exists(path):
        print(f"ERROR: config.ini not found at {path}")
        print("Copy config.example.ini to config.ini and fill in your database details.")
        input("\nPress Enter to close...")
        sys.exit(1)
    cfg = configparser.ConfigParser()
    cfg.read(path)
    return cfg


def connect(cfg):
    db = cfg['database']
    return pymysql.connect(
        host     = db.get('host',     '127.0.0.1'),
        port     = int(db.get('port', 3306)),
        user     = db.get('user',     'peq'),
        password = db.get('password', 'peqpass'),
        database = db.get('name',     'peq'),
        autocommit = True,
        charset    = 'utf8mb4',
    )


def split_sql(sql):
    """Split a SQL string into individual statements, respecting string literals."""
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
            if c == string_char:
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


def execute_sql_file(conn, filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        sql = f.read()
    with conn.cursor() as cur:
        for stmt in split_sql(sql):
            cur.execute(stmt)


def main():
    base = get_base_dir()
    cfg  = load_config()

    # ── Pull latest ───────────────────────────────────────────────────────────
    print("[migrate] Pulling latest migrations...")
    result = subprocess.run(
        ['git', '-C', base, 'pull'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[migrate] WARNING: git pull failed (offline?)\n{result.stderr.strip()}")
        print("[migrate] Continuing with local copy...")
    else:
        last = (result.stdout.strip().splitlines() or [''])[-1]
        print(f"[migrate] git: {last}")

    # ── Connect ───────────────────────────────────────────────────────────────
    db_section = cfg['database']
    print(f"[migrate] Connecting to "
          f"{db_section.get('user')}@{db_section.get('host')}:{db_section.get('port')}"
          f"/{db_section.get('name')} ...")
    try:
        conn = connect(cfg)
    except Exception as e:
        print(f"[migrate] ERROR: Cannot connect: {e}")
        sys.exit(1)
    print("[migrate] Connection OK")

    # ── Ensure tracking table ─────────────────────────────────────────────────
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS db_migrations (
                id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                filename   VARCHAR(255) NOT NULL UNIQUE,
                applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)

    # ── Apply pending migrations ──────────────────────────────────────────────
    migrations_dir = os.path.join(base, 'migrations')
    sql_files = sorted(f for f in os.listdir(migrations_dir) if f.endswith('.sql'))

    if not sql_files:
        print(f"[migrate] No .sql files found in {migrations_dir}")
        return

    print(f"[migrate] Found {len(sql_files)} migration file(s)\n")

    applied = skipped = 0
    for filename in sql_files:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM db_migrations WHERE filename = %s",
                (filename,)
            )
            if cur.fetchone()[0] > 0:
                print(f"  skip   {filename}")
                skipped += 1
                continue

        print(f"  apply  {filename} ... ", end='', flush=True)
        try:
            execute_sql_file(conn, os.path.join(migrations_dir, filename))
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT IGNORE INTO db_migrations (filename) VALUES (%s)",
                    (filename,)
                )
            print("OK")
            applied += 1
        except Exception as e:
            print("FAILED")
            print(f"\n[migrate] ERROR in {filename}: {e}")
            print("[migrate] Fix the .sql file and re-run.")
            sys.exit(1)

    print(f"\n[migrate] Done.  Applied: {applied}   Skipped: {skipped}")


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n[migrate] Interrupted.")
    except SystemExit:
        raise
    except Exception as e:
        print(f"\n[migrate] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
    input("\nPress Enter to close...")
