"""Business rules for the measure -> design -> quote -> invoice workflow.

Kept separate from the routes so the rules are easy to read and test.
"""
import re
from datetime import date, datetime, timedelta

from .db import all_, get_db, get_settings, one, run

# Project pipeline, in order. Status only moves FORWARD automatically.
STAGES = [
    ("lead", "Lead", "Need to measure"),
    ("measured", "Measured", "Ready to design"),
    ("designing", "Designing", "Design in 2020, then quote"),
    ("quoted", "Quoted", "Waiting on customer"),
    ("approved", "Approved", "Collect deposit / invoice"),
    ("invoiced", "Invoiced", "Order, install, collect"),
    ("paid", "Paid", "Paid in full"),
    ("closed", "Closed", "Done & archived"),
    ("lost", "Lost", "Did not proceed"),
]
STAGE_KEYS = [s[0] for s in STAGES]
STAGE_LABELS = {s[0]: s[1] for s in STAGES}
ACTIVE_STAGES = STAGE_KEYS[:6]

QUOTE_CATEGORIES = ["Cabinets", "Countertops", "Hardware", "Accessories",
                    "Installation", "Delivery", "Demo/Removal", "Other"]

MEASUREMENT_PRESETS = {
    "Kitchen": ["Wall A length", "Wall B length", "Wall C length", "Ceiling height",
                "Soffit / bulkhead height & depth", "Window 1 (W x H, from left, sill height)",
                "Door / opening (W, from left)", "Sink / plumbing centre (from left)",
                "Range / cooktop location", "Fridge opening (W x H)",
                "Electrical outlets / switches", "Floor level / out-of-square notes"],
    "Bathroom": ["Vanity wall length", "Ceiling height", "Plumbing centre (from left)",
                 "Drain height", "Supply height", "Window (W x H, from left)",
                 "Door swing / clearance", "Mirror / light location"],
    "Closet": ["Back wall length", "Left return", "Right return", "Ceiling height",
               "Door opening (W x H)", "Baseboard height", "Outlets / switches"],
}


def today():
    return date.today().isoformat()


def money(x):
    return round(float(x or 0) + 1e-9, 2)


# --------------------------------------------------------------------------- numbering

def next_number(prefix, table, column="number"):
    """Next sequential number like J-2026-007 (resets each year)."""
    year = date.today().year
    stem = f"{prefix}-{year}-"
    rows = all_(f"SELECT {column} AS n FROM {table} WHERE {column} LIKE ?", (stem + "%",))
    seq = 0
    for r in rows:
        m = re.match(re.escape(stem) + r"(\d+)$", r["n"])
        if m:
            seq = max(seq, int(m.group(1)))
    return f"{stem}{seq + 1:03d}"


# --------------------------------------------------------------------------- status

def advance_status(project_id, new_status, reason=None):
    """Move a project forward in the pipeline; never backward automatically."""
    p = one("SELECT status FROM projects WHERE id=?", (project_id,))
    if p is None:
        return
    cur = p["status"]
    if cur in ("closed", "lost"):
        return
    if STAGE_KEYS.index(new_status) > STAGE_KEYS.index(cur):
        set_status(project_id, new_status, reason)


def set_status(project_id, status, reason=None):
    assert status in STAGE_KEYS
    run("UPDATE projects SET status=?, updated_at=datetime('now') WHERE id=?", (status, project_id))
    log(project_id, f"Status → {STAGE_LABELS[status]}" + (f" ({reason})" if reason else ""))


def touch(project_id):
    run("UPDATE projects SET updated_at=datetime('now') WHERE id=?", (project_id,))


def log(project_id, body, kind="system"):
    run("INSERT INTO notes(project_id, kind, body) VALUES (?,?,?)", (project_id, kind, body))


# --------------------------------------------------------------------------- quotes

def quote_totals(quote_id):
    q = one("SELECT * FROM quotes WHERE id=?", (quote_id,))
    items = all_("SELECT * FROM quote_items WHERE quote_id=? ORDER BY position, id", (quote_id,))
    subtotal = money(sum(i["qty"] * i["unit_price"] for i in items))
    discount = money(min(q["discount"] or 0, subtotal))
    taxable = money(subtotal - discount)
    tax = money(taxable * (q["tax_rate"] or 0) / 100)
    total = money(taxable + tax)
    by_cat = {}
    for i in items:
        by_cat[i["category"] or "Other"] = money(by_cat.get(i["category"] or "Other", 0)
                                                 + i["qty"] * i["unit_price"])
    return {"items": items, "subtotal": subtotal, "discount": discount, "taxable": taxable,
            "tax": tax, "total": total, "deposit": money(total * (q["deposit_pct"] or 0) / 100),
            "by_category": by_cat}


def create_quote(project_id, design_id=None):
    s = get_settings()
    valid = (date.today() + timedelta(days=int(s["quote_valid_days"] or 30))).isoformat()
    number = next_number("Q", "quotes")
    return run(
        """INSERT INTO quotes(project_id, number, revision, design_id, tax_rate, deposit_pct,
                              valid_until, terms) VALUES (?,?,?,?,?,?,?,?)""",
        (project_id, number, 1, design_id, float(s["default_tax_rate"] or 0),
         float(s["default_deposit_pct"] or 50), valid, s["default_terms"]))


def revise_quote(quote_id):
    """Sent/declined quotes are locked. To change one, make a new revision and
    supersede the old one so there is only ever one 'live' price."""
    q = one("SELECT * FROM quotes WHERE id=?", (quote_id,))
    s = get_settings()
    rev = one("SELECT MAX(revision) AS r FROM quotes WHERE number=?", (q["number"],))["r"] + 1
    latest_design = one("SELECT id FROM designs WHERE project_id=? ORDER BY version DESC LIMIT 1",
                        (q["project_id"],))
    valid = (date.today() + timedelta(days=int(s["quote_valid_days"] or 30))).isoformat()
    new_id = run(
        """INSERT INTO quotes(project_id, number, revision, design_id, tax_rate, discount,
                              deposit_pct, valid_until, notes, terms)
           VALUES (?,?,?,?,?,?,?,?,?,?)""",
        (q["project_id"], q["number"], rev,
         latest_design["id"] if latest_design else q["design_id"],
         q["tax_rate"], q["discount"], q["deposit_pct"], valid, q["notes"], q["terms"]))
    db = get_db()
    db.execute("""INSERT INTO quote_items(quote_id, position, category, description, qty, unit_price)
                  SELECT ?, position, category, description, qty, unit_price
                  FROM quote_items WHERE quote_id=?""", (new_id, quote_id))
    if q["status"] in ("draft", "sent", "declined"):
        db.execute("UPDATE quotes SET status='superseded' WHERE id=?", (quote_id,))
    db.commit()
    log(q["project_id"], f"Quote {q['number']} revised → rev {rev}")
    return new_id


def accept_quote(quote_id):
    q = one("SELECT * FROM quotes WHERE id=?", (quote_id,))
    db = get_db()
    db.execute("UPDATE quotes SET status='accepted', decided_on=? WHERE id=?", (today(), quote_id))
    # Only one accepted price per project: everything else still open is superseded.
    db.execute("""UPDATE quotes SET status='superseded'
                  WHERE project_id=? AND id<>? AND status IN ('draft','sent')""",
               (q["project_id"], quote_id))
    if q["design_id"]:
        db.execute("UPDATE designs SET status='superseded' WHERE project_id=? AND id<>? "
                   "AND status<>'superseded'", (q["project_id"], q["design_id"]))
        db.execute("UPDATE designs SET status='approved' WHERE id=?", (q["design_id"],))
    db.commit()
    advance_status(q["project_id"], "approved", f"quote {q['number']} rev {q['revision']} accepted")


def accepted_quote(project_id):
    return one("SELECT * FROM quotes WHERE project_id=? AND status='accepted' "
               "ORDER BY id DESC LIMIT 1", (project_id,))


# --------------------------------------------------------------------------- invoices

def invoice_paid(invoice_id):
    return money(one("SELECT COALESCE(SUM(amount),0) AS s FROM payments WHERE invoice_id=?",
                     (invoice_id,))["s"])


def quote_billing(quote_id):
    """How much of an accepted quote has been invoiced / collected."""
    total = quote_totals(quote_id)["total"]
    invoiced = money(one("SELECT COALESCE(SUM(amount),0) AS s FROM invoices "
                         "WHERE quote_id=? AND status<>'void'", (quote_id,))["s"])
    collected = money(one("""SELECT COALESCE(SUM(p.amount),0) AS s FROM payments p
                             JOIN invoices i ON i.id=p.invoice_id
                             WHERE i.quote_id=? AND i.status<>'void'""", (quote_id,))["s"])
    return {"total": total, "invoiced": invoiced, "uninvoiced": money(total - invoiced),
            "collected": collected, "outstanding": money(total - collected)}


def suggested_invoice_amount(quote_id, kind):
    t = quote_totals(quote_id)
    b = quote_billing(quote_id)
    if kind == "deposit":
        return min(t["deposit"], b["uninvoiced"])
    return b["uninvoiced"]


def create_invoice(quote_id, kind, amount, notes=None):
    q = one("SELECT * FROM quotes WHERE id=?", (quote_id,))
    if q is None or q["status"] != "accepted":
        raise ValueError("Invoices can only be created from an accepted quote.")
    amount = money(amount)
    remaining = quote_billing(quote_id)["uninvoiced"]
    if amount <= 0:
        raise ValueError("Invoice amount must be more than zero.")
    if amount > remaining + 0.005:
        raise ValueError(f"Amount exceeds the un-invoiced balance of the quote (${remaining:,.2f}).")
    s = get_settings()
    due = (date.today() + timedelta(days=int(s["invoice_due_days"] or 14))).isoformat()
    inv_id = run("""INSERT INTO invoices(project_id, quote_id, number, kind, amount, issued_on, due_on, notes)
                    VALUES (?,?,?,?,?,?,?,?)""",
                 (q["project_id"], quote_id, next_number("INV", "invoices"), kind, amount,
                  today(), due, notes))
    return inv_id


def refresh_invoice_status(invoice_id):
    inv = one("SELECT * FROM invoices WHERE id=?", (invoice_id,))
    if inv["status"] == "void":
        return
    paid = invoice_paid(invoice_id)
    if paid >= inv["amount"] - 0.005:
        run("UPDATE invoices SET status='paid' WHERE id=?", (invoice_id,))
    elif inv["status"] == "paid":
        run("UPDATE invoices SET status='sent' WHERE id=?", (invoice_id,))
    # Project is paid when the accepted quote is fully collected.
    b = quote_billing(inv["quote_id"])
    if b["outstanding"] <= 0.005:
        advance_status(inv["project_id"], "paid", "balance collected")


# --------------------------------------------------------------------------- warnings / next actions

def project_warnings(project_id):
    """Things that are inconsistent or risky inside one project."""
    w = []
    meas = all_("SELECT * FROM measurements WHERE project_id=?", (project_id,))
    designs = all_("SELECT * FROM designs WHERE project_id=? ORDER BY version DESC", (project_id,))
    quotes = all_("SELECT * FROM quotes WHERE project_id=? ORDER BY id DESC", (project_id,))
    acc = accepted_quote(project_id)

    unverified = [m for m in meas if m["source"] == "customer" and not m["verified"]]
    if unverified and (acc or designs):
        w.append(("warn", f"{len(unverified)} customer-supplied measurement set(s) not verified on site. "
                          "Verify before ordering."))
    if designs and not meas:
        w.append(("warn", "Design exists with no measurements on file."))
    for d in designs:
        if not d["measurement_id"] and meas:
            w.append(("info", f"Design v{d['version']} is not linked to a measurement set."))
    if designs:
        latest = designs[0]
        live = [q for q in quotes if q["status"] in ("draft", "sent", "accepted")]
        for q in live:
            if q["design_id"] and q["design_id"] != latest["id"]:
                dv = next((d["version"] for d in designs if d["id"] == q["design_id"]), "?")
                w.append(("warn", f"Quote {q['number']} rev {q['revision']} is priced from design v{dv}, "
                                  f"but the latest design is v{latest['version']}. Revise the quote?"))
    for q in quotes:
        if q["status"] in ("draft", "sent") and not q["design_id"] and designs:
            w.append(("info", f"Quote {q['number']} rev {q['revision']} is not linked to a design."))
    if acc:
        b = quote_billing(acc["id"])
        if b["uninvoiced"] > 0.005:
            w.append(("info", f"${b['uninvoiced']:,.2f} of the accepted quote has not been invoiced yet."))
    return w


def next_actions():
    """Dashboard to-do list across all projects."""
    s = get_settings()
    followup = int(s["quote_followup_days"] or 7)
    t = today()
    acts = []

    def add(kind, row, text, target):
        acts.append({"kind": kind, "text": text, "customer": row["customer"],
                     "ref": f"{row['pnum'] if 'pnum' in row.keys() else row['number']} {row['title']}",
                     "target": target})

    for p in all_("""SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                     WHERE p.status='lead' AND NOT EXISTS
                       (SELECT 1 FROM measurements m WHERE m.project_id=p.id)"""):
        add("measure", p, "Book / take measurements", ("project", p["id"]))

    for p in all_("""SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                     WHERE p.status IN ('measured') AND NOT EXISTS
                       (SELECT 1 FROM designs d WHERE d.project_id=p.id)"""):
        add("design", p, "Start 2020 design", ("project", p["id"]))

    for p in all_("""SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                     WHERE p.status='designing' AND NOT EXISTS
                       (SELECT 1 FROM quotes q WHERE q.project_id=p.id AND q.status<>'superseded')"""):
        add("quote", p, "Design done? Build the quote", ("project", p["id"]))

    for q in all_("""SELECT q.*, p.number AS pnum, p.title, p.id AS pid, c.name AS customer
                     FROM quotes q JOIN projects p ON p.id=q.project_id JOIN customers c ON c.id=p.customer_id
                     WHERE q.status='sent'"""):
        if q["valid_until"] and q["valid_until"] < t:
            add("expired", q, f"Quote {q['number']} r{q['revision']} expired {q['valid_until']}", ("quote", q["id"]))
        elif q["sent_on"] and (date.fromisoformat(q["sent_on"]) + timedelta(days=followup)).isoformat() <= t:
            add("followup", q, f"Follow up on quote {q['number']} r{q['revision']} (sent {q['sent_on']})", ("quote", q["id"]))

    for p in all_("""SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                     WHERE p.status IN ('approved','invoiced')"""):
        acc = accepted_quote(p["id"])
        if acc and quote_billing(acc["id"])["uninvoiced"] > 0.005 and not one(
                "SELECT 1 FROM invoices WHERE quote_id=? AND status<>'void'", (acc["id"],)):
            add("invoice", p, "Quote accepted: send deposit invoice", ("project", p["id"]))
        if one("""SELECT 1 FROM measurements WHERE project_id=? AND source='customer' AND verified=0""",
               (p["id"],)):
            add("verify", p, "Verify customer measurements on site before ordering", ("project", p["id"]))

    for i in all_("""SELECT i.*, p.number AS pnum, p.title, p.id AS pid, c.name AS customer
                     FROM invoices i JOIN projects p ON p.id=i.project_id JOIN customers c ON c.id=p.customer_id
                     WHERE i.status='sent' AND i.due_on < ?""", (t,)):
        add("overdue", i, f"Invoice {i['number']} overdue (due {i['due_on']})", ("invoice", i["id"]))
    for i in all_("""SELECT i.*, p.number AS pnum, p.title, p.id AS pid, c.name AS customer
                     FROM invoices i JOIN projects p ON p.id=i.project_id JOIN customers c ON c.id=p.customer_id
                     WHERE i.status='draft'"""):
        add("send", i, f"Invoice {i['number']} is still a draft: send it", ("invoice", i["id"]))
    return acts


def slug(text):
    return re.sub(r"[^A-Za-z0-9]+", "-", text or "").strip("-")[:40] or "x"


def parse_date(v):
    if not v:
        return None
    try:
        return datetime.strptime(v, "%Y-%m-%d").date().isoformat()
    except ValueError:
        return None
