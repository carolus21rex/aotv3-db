#!/usr/bin/env python3
"""
AoTv3 database delta generator.
Compares your working database against the last committed state, generates a
migration file for the difference, pushes it to git, then advances the
reference database to match.

Run this after making database changes you want to version.

Setup (once):
    pip install pymysql
    cp config.example.ini config.ini
    # fill in your database details in config.ini

Usage:
    python aot_delta.py
    # or double-click if compiled with PyInstaller
"""

import os
import sys
import configparser
import subprocess
import datetime
import urllib.request
import zipfile
import tempfile

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("ERROR: pymysql not installed.  Run: pip install pymysql")
    input("\nPress Enter to close...")
    sys.exit(1)


from table_config import load_tracked_tables


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


def connect(cfg, database=None):
    db = cfg['database']
    kwargs = dict(
        host       = db.get('host',     '127.0.0.1'),
        port       = int(db.get('port', 3306)),
        user       = db.get('user',     'peq'),
        password   = db.get('password', 'peqpass'),
        autocommit = True,
        charset    = 'utf8mb4',
        cursorclass = pymysql.cursors.DictCursor,
    )
    if database:
        kwargs['database'] = database
    return pymysql.connect(**kwargs)


# ── SQL helpers ───────────────────────────────────────────────────────────────

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


def execute_sql_file(conn, filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        sql = f.read()
    with conn.cursor() as cur:
        for stmt in split_sql(sql):
            cur.execute(stmt)


def seed_from_archive(live_conn, live_db, seedable_tables):
    import re
    url = "https://github.com/peqarchive/peqdatabase/raw/main/peq-latest.zip"
    print(f"[delta] {live_db} is empty — seeding from PEQ archive (may take a while)...")

    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = os.path.join(tmpdir, "peq-latest.zip")

        def reporthook(count, block, total):
            if total > 0:
                print(f"\r  downloading ... {min(count * block * 100 // total, 100)}%",
                      end='', flush=True)

        urllib.request.urlretrieve(url, zip_path, reporthook=reporthook)
        print()

        print("[delta] Extracting...")
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(tmpdir)

        sql_files = sorted(
            os.path.join(root, f)
            for root, _, files in os.walk(tmpdir)
            for f in files
            if f.endswith('.sql')
        )
        if not sql_files:
            print("[delta] WARNING: no .sql files found in archive — skipping seed")
            return

        # Skip structural/session statements and DELETEs (empty tables, no-op but slow)
        skip_prefixes = (
            'CREATE ', 'DROP ', 'USE ', 'ALTER ', 'SET ',
            'LOCK ', 'UNLOCK ', 'DELETE ', 'TRUNCATE ', 'SOURCE ', '/*',
        )
        # Only import INSERT/REPLACE for tables we can actually delta
        dml_re = re.compile(
            r'(?:INSERT\s+(?:IGNORE\s+)?INTO|REPLACE\s+(?:INTO\s+)?)\s*`?(\w+)`?',
            re.IGNORECASE
        )

        print(f"[delta] Importing tracked tables from {len(sql_files)} SQL file(s)...")
        with live_conn.cursor() as cur:
            for sql_file in sql_files:
                print(f"  {os.path.basename(sql_file)} ...", end='', flush=True)
                with open(sql_file, 'r', encoding='utf-8', errors='replace') as f:
                    sql = f.read()
                imported = errors = 0
                for stmt in split_sql(sql):
                    upper = stmt.strip().upper()
                    if any(upper.startswith(kw) for kw in skip_prefixes):
                        continue
                    m = dml_re.match(stmt.strip())
                    if m and m.group(1) not in seedable_tables:
                        continue
                    try:
                        cur.execute(stmt)
                        imported += 1
                    except Exception as e:
                        errors += 1
                        if errors <= 5:
                            print(f"\n    ERROR: {e} | stmt: {stmt[:120]}")
                print(f" {imported} ok, {errors} errors")

    print("[delta] Seed complete")


# ── Table introspection ───────────────────────────────────────────────────────

def get_primary_keys(conn, db_name, table):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT column_name
            FROM information_schema.key_column_usage
            WHERE table_schema = %s AND table_name = %s
              AND constraint_name = 'PRIMARY'
            ORDER BY ordinal_position
        """, (db_name, table))
        pk_cols = [row['column_name'] for row in cur.fetchall()]
        if pk_cols:
            return pk_cols

        # Fall back to first UNIQUE constraint if no PRIMARY KEY
        cur.execute("""
            SELECT kcu.constraint_name, kcu.column_name
            FROM information_schema.key_column_usage kcu
            JOIN information_schema.table_constraints tc
              ON tc.constraint_schema = kcu.table_schema
             AND tc.table_name = kcu.table_name
             AND tc.constraint_name = kcu.constraint_name
            WHERE kcu.table_schema = %s AND kcu.table_name = %s
              AND tc.constraint_type = 'UNIQUE'
            ORDER BY tc.constraint_name, kcu.ordinal_position
        """, (db_name, table))
        rows = cur.fetchall()
        if rows:
            first = rows[0]['constraint_name']
            return [r['column_name'] for r in rows if r['constraint_name'] == first]

        return []


def get_columns(conn, db_name, table):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
        """, (db_name, table))
        return [row['column_name'] for row in cur.fetchall()]


def get_rows(conn, db_name, table, pk_cols):
    """Returns {pk_tuple: row_dict} for every row in db_name.table."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT * FROM `{db_name}`.`{table}`")
        rows = cur.fetchall()
    return {
        tuple(row[pk] for pk in pk_cols): row
        for row in rows
    }


# ── Delta SQL generation ──────────────────────────────────────────────────────

def fmt_replace(conn, table, columns, row):
    col_list = ", ".join(f"`{c}`" for c in columns)
    val_list = ", ".join(conn.escape(row[c]) for c in columns)
    return f"REPLACE INTO `{table}` ({col_list}) VALUES ({val_list});"


def fmt_delete(conn, table, pk_cols, pk_vals):
    conds = " AND ".join(
        f"`{c}` = {conn.escape(v)}"
        for c, v in zip(pk_cols, pk_vals)
    )
    return f"DELETE FROM `{table}` WHERE {conds};"


def compute_delta(conn, work_db, live_db, table):
    pk_cols = get_primary_keys(conn, work_db, table)
    if not pk_cols:
        print(f"  [delta] WARNING: no primary key on {table}, skipping")
        return []

    columns   = get_columns(conn, work_db, table)
    work_rows = get_rows(conn, work_db, table, pk_cols)
    live_rows = get_rows(conn, live_db, table, pk_cols)

    delta = []

    for pk, row in work_rows.items():
        if live_rows.get(pk) != row:
            delta.append(fmt_replace(conn, table, columns, row))

    for pk in set(live_rows) - set(work_rows):
        delta.append(fmt_delete(conn, table, pk_cols, pk))

    return delta


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    base = get_base_dir()
    cfg  = load_config()

    TRACKED_TABLES = load_tracked_tables(base)
    print(f"[delta] Tracking {len(TRACKED_TABLES)} tables from content_tables.ini")

    work_db        = cfg.get('delta', 'work_db', fallback='peq')
    live_db        = cfg.get('delta', 'live_db', fallback='aot_current')
    migrations_dir = os.path.join(base, 'migrations')

    # ── Step 1: Pull ──────────────────────────────────────────────────────────
    print("[delta] Pulling latest migrations from git...")
    result = subprocess.run(
        ['git', '-C', base, 'pull'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("[delta] ERROR: git pull failed — resolve conflicts before generating a delta.")
        print(result.stderr.strip())
        sys.exit(1)
    last = (result.stdout.strip().splitlines() or [''])[-1]
    print(f"[delta] git: {last}")

    # ── Step 2: Connect ───────────────────────────────────────────────────────
    print(f"[delta] Connecting...")
    try:
        admin = connect(cfg)
        with admin.cursor() as cur:
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{work_db}`")
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{live_db}`")
        work_conn = connect(cfg, work_db)
        live_conn = connect(cfg, live_db)
    except Exception as e:
        print(f"[delta] ERROR: Cannot connect: {e}")
        sys.exit(1)

    print(f"[delta] Connected to {work_db} and {live_db}")

    # ── Step 2.5: Seed work_db if it is empty ────────────────────────────────
    with admin.cursor() as cur:
        cur.execute(
            "SELECT COUNT(*) AS cnt FROM information_schema.tables "
            "WHERE table_schema = %s AND table_name = 'items'",
            (work_db,)
        )
        work_db_empty = cur.fetchone()['cnt'] == 0

    if work_db_empty:
        print(f"[delta] '{work_db}' is empty — seeding from PEQ archive...")
        try:
            import aot_seed_peq
            aot_seed_peq.seed_from_archive(work_conn)
            aot_seed_peq.create_migrations_table(work_conn)
        except Exception as seed_err:
            print(f"[delta] ERROR: seeding failed: {seed_err}")
            sys.exit(1)

    # ── Step 3: Bootstrap live_db tables ──────────────────────────────────────
    print(f"[delta] Checking {live_db} tables...")
    with admin.cursor() as cur:
        for table in TRACKED_TABLES:
            cur.execute(
                f"CREATE TABLE IF NOT EXISTS `{live_db}`.`{table}` "
                f"LIKE `{work_db}`.`{table}`"
            )

    # ── Step 3.5: Seed any empty tracked tables from PEQ archive ─────────────
    tables_to_seed = set()
    with live_conn.cursor() as cur:
        for table in TRACKED_TABLES:
            cur.execute(f"SELECT COUNT(*) AS cnt FROM `{table}`")
            if cur.fetchone()['cnt'] == 0:
                tables_to_seed.add(table)
    if tables_to_seed:
        print(f"[delta] {len(tables_to_seed)} empty table(s) need seeding: {', '.join(sorted(tables_to_seed))}")
        seed_from_archive(live_conn, live_db, tables_to_seed)

    # ── Step 4: Sync live_db with committed migrations ────────────────────────
    print(f"[delta] Syncing {live_db} with committed migrations...")
    with live_conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS db_migrations (
                id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                filename   VARCHAR(255) NOT NULL UNIQUE,
                applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)

    sql_files = sorted(f for f in os.listdir(migrations_dir) if f.endswith('.sql'))
    synced = 0
    for filename in sql_files:
        with live_conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM db_migrations WHERE filename = %s",
                (filename,)
            )
            if cur.fetchone()['cnt'] > 0:
                continue
        print(f"  sync  {filename} ...")
        try:
            execute_sql_file(live_conn, os.path.join(migrations_dir, filename))
            with live_conn.cursor() as cur:
                cur.execute(
                    "INSERT IGNORE INTO db_migrations (filename) VALUES (%s)",
                    (filename,)
                )
            synced += 1
        except Exception as e:
            print(f"[delta] ERROR: Failed to sync {filename} to {live_db}: {e}")
            sys.exit(1)

    if synced:
        print(f"[delta] Synced {synced} migration(s) to {live_db}")
    else:
        print(f"[delta] {live_db} is up to date")

    # ── Step 4b: Sync work_db with committed migrations ───────────────────────
    print(f"[delta] Syncing {work_db} with committed migrations...")
    with work_conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS db_migrations (
                id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                filename   VARCHAR(255) NOT NULL UNIQUE,
                applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)

    synced_work = 0
    for filename in sql_files:
        with work_conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM db_migrations WHERE filename = %s",
                (filename,)
            )
            if cur.fetchone()['cnt'] > 0:
                continue
        print(f"  sync  {filename} -> {work_db} ...")
        try:
            execute_sql_file(work_conn, os.path.join(migrations_dir, filename))
            with work_conn.cursor() as cur:
                cur.execute(
                    "INSERT IGNORE INTO db_migrations (filename) VALUES (%s)",
                    (filename,)
                )
            synced_work += 1
        except Exception as e:
            print(f"[delta] ERROR: Failed to sync {filename} to {work_db}: {e}")
            sys.exit(1)

    if synced_work:
        print(f"[delta] Synced {synced_work} migration(s) to {work_db}")
    else:
        print(f"[delta] {work_db} is up to date")

    # ── Step 5: Compute delta ─────────────────────────────────────────────────
    print(f"[delta] Comparing {work_db} vs {live_db}...")
    all_lines     = []
    changed_tables = []

    for table in TRACKED_TABLES:
        lines = compute_delta(work_conn, work_db, live_db, table)
        if lines:
            sep = '─' * max(1, 60 - len(table))
            all_lines.append(f"\n-- ── {table} {sep}")
            all_lines.extend(lines)
            changed_tables.append(table)

    if not all_lines:
        print(f"[delta] No changes detected — {work_db} matches {live_db}")
        return

    print(f"[delta] Changes detected in: {', '.join(changed_tables)}")

    # ── Step 6: Write migration file ──────────────────────────────────────────
    timestamp  = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    slug       = "_".join(changed_tables[:3])
    filename   = f"{timestamp}_content_delta_{slug}.sql"
    filepath   = os.path.join(migrations_dir, filename)

    header = [
        "-- AoTv3 content delta",
        f"-- Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"-- Changed tables: {', '.join(changed_tables)}",
        "",
    ]
    with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
        f.write("\n".join(header + all_lines) + "\n")
    print(f"[delta] Wrote: {filename}")

    # ── Step 7: Commit and push ───────────────────────────────────────────────
    print("[delta] Committing and pushing...")
    subprocess.run(
        ['git', '-C', base, 'add', f'migrations/{filename}'],
        check=True
    )
    subprocess.run(
        ['git', '-C', base, 'commit', '-m',
         f'Content delta: {", ".join(changed_tables)}'],
        check=True
    )
    push = subprocess.run(
        ['git', '-C', base, 'push'],
        capture_output=True, text=True
    )
    if push.returncode != 0:
        print("[delta] ERROR: git push failed — another commit landed since your pull.")
        print(f'  Run: git -C "{base}" pull --rebase')
        print(f'  Then: git -C "{base}" push')
        sys.exit(1)
    print("[delta] Pushed to git")

    # ── Step 8: Advance live_db ───────────────────────────────────────────────
    print(f"[delta] Advancing {live_db}...")
    execute_sql_file(live_conn, filepath)
    with live_conn.cursor() as cur:
        cur.execute(
            "INSERT IGNORE INTO db_migrations (filename) VALUES (%s)",
            (filename,)
        )

    print(f"\n[delta] Done. Delta committed and {live_db} is up to date.")


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n[delta] Interrupted.")
    except SystemExit:
        raise
    except Exception as e:
        print(f"\n[delta] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
    input("\nPress Enter to close...")
