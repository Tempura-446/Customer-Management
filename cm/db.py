import sqlite3
from pathlib import Path

from flask import current_app, g

SCHEMA = Path(__file__).with_name("schema.sql")

DEFAULT_SETTINGS = {
    "business_name": "Your Cabinet Co.",
    "business_address": "",
    "business_phone": "",
    "business_email": "",
    "default_tax_rate": "0",
    "default_deposit_pct": "50",
    "quote_valid_days": "30",
    "invoice_due_days": "14",
    "quote_followup_days": "7",
    "default_terms": (
        "Deposit due on acceptance to place the order. "
        "Final measurements are verified on site before ordering. "
        "Balance due on completion of installation."
    ),
}


def get_db():
    if "db" not in g:
        conn = sqlite3.connect(current_app.config["DATABASE"])
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        g.db = conn
    return g.db


def close_db(_exc=None):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def init_db(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA.read_text())
    for k, v in DEFAULT_SETTINGS.items():
        conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", (k, v))
    conn.commit()
    conn.close()


def get_settings():
    rows = get_db().execute("SELECT key, value FROM settings").fetchall()
    s = dict(DEFAULT_SETTINGS)
    s.update({r["key"]: r["value"] for r in rows})
    return s


def one(sql, args=()):
    return get_db().execute(sql, args).fetchone()


def all_(sql, args=()):
    return get_db().execute(sql, args).fetchall()


def run(sql, args=()):
    cur = get_db().execute(sql, args)
    get_db().commit()
    return cur.lastrowid
