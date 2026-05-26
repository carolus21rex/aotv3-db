import configparser
import os
import sys


def load_tracked_tables(base_dir=None):
    if base_dir is None:
        if getattr(sys, 'frozen', False):
            base_dir = os.path.dirname(sys.executable)
        else:
            base_dir = os.path.dirname(os.path.abspath(__file__))

    path = os.path.join(base_dir, 'content_tables.ini')
    if not os.path.exists(path):
        print(f"ERROR: content_tables.ini not found at {path}")
        sys.exit(1)

    cfg = configparser.ConfigParser(allow_no_value=True)
    cfg.read(path, encoding='utf-8')

    tables = []
    for section in cfg.sections():
        tables.extend(cfg.options(section))
    return tables
