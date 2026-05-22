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

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("ERROR: pymysql not installed.  Run: pip install pymysql")
    input("\nPress Enter to close...")
    sys.exit(1)


# ── Tables tracked for content deltas ────────────────────────────────────────
# Add or remove tables here as your content expands.
TRACKED_TABLES = [
    "aa_ability",
    "aa_rank",
    "aa_rank_effects",
    "aa_rank_prereqs",
    "alternate_currency",
    "base_data",
    "items",
    "lootdrop",
    "lootdrop_entries",
    "loottable",
    "loottable_entries",
    "npc_spells",
    "npc_spells_entries",
    "npc_types",
    "spawn2",
    "spawnentry",
    "spawngroup",
    "spells_new",
    "tradeskill_recipe",
    "tradeskill_recipe_entries",
]


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
        return [row['column_name'] for row in cur.fetchall()]


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
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{live_db}`")
        work_conn = connect(cfg, work_db)
        live_conn = connect(cfg, live_db)
    except Exception as e:
        print(f"[delta] ERROR: Cannot connect: {e}")
        sys.exit(1)
    print(f"[delta] Connected to {work_db} and {live_db}")

    # ── Step 3: Bootstrap live_db tables ──────────────────────────────────────
    print(f"[delta] Checking {live_db} tables...")
    with admin.cursor() as cur:
        for table in TRACKED_TABLES:
            cur.execute(
                f"CREATE TABLE IF NOT EXISTS `{live_db}`.`{table}` "
                f"LIKE `{work_db}`.`{table}`"
            )

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
