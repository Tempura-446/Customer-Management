import os
from pathlib import Path

from flask import (Flask, abort, flash, redirect, render_template, request,
                   send_from_directory, url_for)
from werkzeug.utils import secure_filename

from . import logic as L
from .db import all_, close_db, get_db, get_settings, init_db, one, run

FILE_CATEGORIES = ["measurements", "designs", "quotes", "invoices", "photos", "other"]
ENTITY_CATEGORY = {"measurement": "measurements", "design": "designs",
                   "quote": "quotes", "invoice": "invoices"}


def create_app(data_dir=None):
    app = Flask(__name__)
    data_dir = Path(data_dir or os.environ.get("CM_DATA_DIR") or Path.cwd() / "data")
    app.config.update(
        SECRET_KEY=os.environ.get("CM_SECRET_KEY", "change-me-local-only"),
        DATABASE=str(data_dir / "customers.db"),
        UPLOAD_DIR=str(data_dir / "uploads"),
        MAX_CONTENT_LENGTH=200 * 1024 * 1024,
    )
    init_db(app.config["DATABASE"])
    Path(app.config["UPLOAD_DIR"]).mkdir(parents=True, exist_ok=True)
    app.teardown_appcontext(close_db)

    @app.context_processor
    def inject():
        return {"STAGES": L.STAGES, "STAGE_LABELS": L.STAGE_LABELS, "settings": get_settings()}

    @app.template_filter("money")
    def money_filter(v):
        return f"${float(v or 0):,.2f}"

    @app.template_filter("qty")
    def qty_filter(v):
        v = float(v or 0)
        return f"{v:g}"

    # ------------------------------------------------------------------ helpers

    def project_or_404(pid):
        p = one("""SELECT p.*, c.name AS customer, c.phone, c.email, c.address AS customer_address
                   FROM projects p JOIN customers c ON c.id=p.customer_id WHERE p.id=?""", (pid,))
        if p is None:
            abort(404)
        return p

    def row_or_404(table, rid):
        r = one(f"SELECT * FROM {table} WHERE id=?", (rid,))
        if r is None:
            abort(404)
        return r

    def save_uploads(project, entity_type=None, entity_id=None, category=None, field="files"):
        cat = category or ENTITY_CATEGORY.get(entity_type, "other")
        folder = Path(app.config["UPLOAD_DIR"]) / f"{project['number']}_{L.slug(project['customer'])}" / cat
        saved = 0
        for f in request.files.getlist(field):
            if not f or not f.filename:
                continue
            folder.mkdir(parents=True, exist_ok=True)
            name = secure_filename(f.filename) or "file"
            target = folder / name
            stem, suffix, n = target.stem, target.suffix, 1
            while target.exists():
                n += 1
                target = folder / f"{stem}_{n}{suffix}"
            f.save(target)
            run("""INSERT INTO files(project_id, entity_type, entity_id, category, original_name,
                                     stored_path, size) VALUES (?,?,?,?,?,?,?)""",
                (project["id"], entity_type, entity_id, cat, f.filename,
                 str(target.relative_to(app.config["UPLOAD_DIR"])), target.stat().st_size))
            saved += 1
        if saved:
            L.log(project["id"], f"{saved} file(s) added to {cat}")
        return saved

    def files_for(entity_type, entity_id):
        return all_("SELECT * FROM files WHERE entity_type=? AND entity_id=? ORDER BY id",
                    (entity_type, entity_id))

    # ------------------------------------------------------------------ dashboard / search

    @app.route("/")
    def dashboard():
        projects = all_("""SELECT p.*, c.name AS customer FROM projects p
                           JOIN customers c ON c.id=p.customer_id
                           WHERE p.status IN ({}) ORDER BY p.updated_at DESC"""
                        .format(",".join("?" * len(L.ACTIVE_STAGES))), L.ACTIVE_STAGES)
        board = {k: [] for k in L.ACTIVE_STAGES}
        for p in projects:
            board[p["status"]].append(p)
        open_quotes = sum(L.quote_totals(q["id"])["total"]
                          for q in all_("SELECT id FROM quotes WHERE status='sent'"))
        receivable = 0.0
        for i in all_("SELECT id, amount FROM invoices WHERE status='sent'"):
            receivable += i["amount"] - L.invoice_paid(i["id"])
        return render_template("dashboard.html", board=board, actions=L.next_actions(),
                               open_quotes=open_quotes, receivable=receivable)

    @app.route("/search")
    def search():
        q = (request.args.get("q") or "").strip()
        like = f"%{q}%"
        customers = all_("""SELECT * FROM customers WHERE name LIKE ? OR phone LIKE ? OR email LIKE ?
                            OR address LIKE ? ORDER BY name""", (like,) * 4) if q else []
        projects = all_("""SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                           WHERE p.number LIKE ? OR p.title LIKE ? OR p.site_address LIKE ? OR c.name LIKE ?
                           ORDER BY p.updated_at DESC""", (like,) * 4) if q else []
        docs = all_("""SELECT 'quote' AS t, q.id, q.number || ' r' || q.revision AS label, q.project_id
                       FROM quotes q WHERE q.number LIKE ?
                       UNION ALL
                       SELECT 'invoice', i.id, i.number, i.project_id FROM invoices i WHERE i.number LIKE ?""",
                    (like, like)) if q else []
        return render_template("search.html", q=q, customers=customers, projects=projects, docs=docs)

    # ------------------------------------------------------------------ customers

    @app.route("/customers")
    def customers():
        rows = all_("""SELECT c.*, COUNT(p.id) AS n_projects, MAX(p.updated_at) AS last_activity
                       FROM customers c LEFT JOIN projects p ON p.customer_id=c.id
                       GROUP BY c.id ORDER BY c.name""")
        return render_template("customers.html", customers=rows)

    @app.route("/customers/new", methods=["GET", "POST"])
    @app.route("/customers/<int:cid>/edit", methods=["GET", "POST"])
    def customer_form(cid=None):
        c = row_or_404("customers", cid) if cid else None
        if request.method == "POST":
            f = request.form
            vals = (f["name"].strip(), f.get("phone"), f.get("email"), f.get("address"),
                    f.get("source"), f.get("notes"))
            if not vals[0]:
                flash("Name is required.", "error")
                return render_template("customer_form.html", c=f)
            if c:
                run("""UPDATE customers SET name=?, phone=?, email=?, address=?, source=?, notes=?
                       WHERE id=?""", vals + (cid,))
            else:
                cid = run("""INSERT INTO customers(name, phone, email, address, source, notes)
                             VALUES (?,?,?,?,?,?)""", vals)
                if f.get("create_project"):
                    return redirect(url_for("project_form", customer_id=cid))
            return redirect(url_for("customer_detail", cid=cid))
        return render_template("customer_form.html", c=c)

    @app.route("/customers/<int:cid>")
    def customer_detail(cid):
        c = row_or_404("customers", cid)
        projects = all_("SELECT * FROM projects WHERE customer_id=? ORDER BY created_at DESC", (cid,))
        notes = all_("SELECT * FROM notes WHERE customer_id=? ORDER BY created_at DESC", (cid,))
        return render_template("customer_detail.html", c=c, projects=projects, notes=notes)

    @app.post("/customers/<int:cid>/delete")
    def customer_delete(cid):
        run("DELETE FROM customers WHERE id=?", (cid,))
        flash("Customer deleted.")
        return redirect(url_for("customers"))

    # ------------------------------------------------------------------ projects

    @app.route("/projects")
    def projects():
        status = request.args.get("status")
        sql = """SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id"""
        rows = all_(sql + " WHERE p.status=? ORDER BY p.updated_at DESC", (status,)) if status \
            else all_(sql + " ORDER BY p.updated_at DESC")
        return render_template("projects.html", projects=rows, status=status)

    @app.route("/projects/new", methods=["GET", "POST"])
    @app.route("/projects/<int:pid>/edit", methods=["GET", "POST"])
    def project_form(pid=None):
        p = project_or_404(pid) if pid else None
        if request.method == "POST":
            f = request.form
            if p:
                run("UPDATE projects SET title=?, site_address=?, updated_at=datetime('now') WHERE id=?",
                    (f["title"], f.get("site_address"), pid))
            else:
                cust = row_or_404("customers", int(f["customer_id"]))
                pid = run("""INSERT INTO projects(number, customer_id, title, site_address)
                             VALUES (?,?,?,?)""",
                          (L.next_number("J", "projects"), cust["id"], f["title"] or "New project",
                           f.get("site_address") or cust["address"]))
                L.log(pid, "Project created")
            return redirect(url_for("project_detail", pid=pid))
        cid = request.args.get("customer_id", type=int)
        customer = row_or_404("customers", cid) if cid else None
        return render_template("project_form.html", p=p, customer=customer,
                               customers=all_("SELECT id, name FROM customers ORDER BY name"))

    @app.route("/projects/<int:pid>")
    def project_detail(pid):
        p = project_or_404(pid)
        meas = all_("""SELECT m.*, (SELECT COUNT(*) FROM measurement_items WHERE measurement_id=m.id) AS n_items
                       FROM measurements m WHERE project_id=? ORDER BY m.created_at DESC""", (pid,))
        designs = all_("""SELECT d.*, m.room AS m_room FROM designs d
                          LEFT JOIN measurements m ON m.id=d.measurement_id
                          WHERE d.project_id=? ORDER BY d.version DESC""", (pid,))
        quotes = [dict(q) | {"total": L.quote_totals(q["id"])["total"]}
                  for q in all_("""SELECT q.*, d.version AS d_version FROM quotes q
                                   LEFT JOIN designs d ON d.id=q.design_id
                                   WHERE q.project_id=? ORDER BY q.number, q.revision DESC""", (pid,))]
        invoices = [dict(i) | {"paid": L.invoice_paid(i["id"])}
                    for i in all_("SELECT * FROM invoices WHERE project_id=? ORDER BY id", (pid,))]
        acc = L.accepted_quote(pid)
        billing = L.quote_billing(acc["id"]) if acc else None
        notes = all_("SELECT * FROM notes WHERE project_id=? ORDER BY created_at DESC, id DESC", (pid,))
        files = all_("SELECT * FROM files WHERE project_id=? ORDER BY category, id", (pid,))
        return render_template("project_detail.html", p=p, meas=meas, designs=designs, quotes=quotes,
                               invoices=invoices, accepted=acc, billing=billing, notes=notes,
                               files=files, warnings=L.project_warnings(pid),
                               file_categories=FILE_CATEGORIES)

    @app.post("/projects/<int:pid>/status")
    def project_status(pid):
        project_or_404(pid)
        st = request.form["status"]
        if st in L.STAGE_KEYS:
            L.set_status(pid, st, "manual")
        return redirect(url_for("project_detail", pid=pid))

    @app.post("/projects/<int:pid>/notes")
    def project_note(pid):
        p = project_or_404(pid)
        body = (request.form.get("body") or "").strip()
        if body:
            run("INSERT INTO notes(project_id, customer_id, kind, body) VALUES (?,?,?,?)",
                (pid, p["customer_id"], request.form.get("kind", "note"), body))
            L.touch(pid)
        return redirect(url_for("project_detail", pid=pid) + "#notes")

    @app.post("/projects/<int:pid>/files")
    def project_files(pid):
        p = project_or_404(pid)
        cat = request.form.get("category")
        save_uploads(p, category=cat if cat in FILE_CATEGORIES else "other")
        return redirect(url_for("project_detail", pid=pid) + "#files")

    @app.post("/projects/<int:pid>/delete")
    def project_delete(pid):
        p = project_or_404(pid)
        run("DELETE FROM projects WHERE id=?", (pid,))
        flash(f"Project {p['number']} deleted (files on disk were kept).")
        return redirect(url_for("customer_detail", cid=p["customer_id"]))

    # ------------------------------------------------------------------ files

    @app.route("/files/<int:fid>")
    def file_download(fid):
        f = row_or_404("files", fid)
        return send_from_directory(app.config["UPLOAD_DIR"], f["stored_path"],
                                   download_name=f["original_name"],
                                   as_attachment=request.args.get("dl") == "1")

    @app.post("/files/<int:fid>/delete")
    def file_delete(fid):
        f = row_or_404("files", fid)
        run("DELETE FROM files WHERE id=?", (fid,))
        try:
            (Path(app.config["UPLOAD_DIR"]) / f["stored_path"]).unlink()
        except OSError:
            pass
        return redirect(request.form.get("next") or url_for("project_detail", pid=f["project_id"]))

    # ------------------------------------------------------------------ measurements

    def save_measurement_items(mid):
        db = get_db()
        db.execute("DELETE FROM measurement_items WHERE measurement_id=?", (mid,))
        labels = request.form.getlist("label")
        values = request.form.getlist("value")
        units = request.form.getlist("unit")
        pos = 0
        for lab, val, unit in zip(labels, values, units):
            if lab.strip() or val.strip():
                db.execute("""INSERT INTO measurement_items(measurement_id, position, label, value, unit)
                              VALUES (?,?,?,?,?)""", (mid, pos, lab.strip() or "-", val.strip(), unit))
                pos += 1
        db.commit()

    @app.route("/projects/<int:pid>/measurements/new", methods=["GET", "POST"])
    @app.route("/measurements/<int:mid>/edit", methods=["GET", "POST"])
    def measurement_form(pid=None, mid=None):
        m = row_or_404("measurements", mid) if mid else None
        p = project_or_404(m["project_id"] if m else pid)
        if request.method == "POST":
            f = request.form
            source = f.get("source") if f.get("source") in ("onsite", "customer") else "onsite"
            verified = 1 if source == "onsite" or f.get("verified") else 0
            vals = (f.get("room") or "Room", source, f.get("taken_by"), L.parse_date(f.get("taken_on")),
                    verified, f.get("notes"))
            if m:
                run("""UPDATE measurements SET room=?, source=?, taken_by=?, taken_on=?, verified=?, notes=?
                       WHERE id=?""", vals + (mid,))
            else:
                mid = run("""INSERT INTO measurements(project_id, room, source, taken_by, taken_on,
                                                      verified, notes) VALUES (?,?,?,?,?,?,?)""",
                          (p["id"],) + vals)
                L.log(p["id"], f"Measurements added: {vals[0]} ({'on site' if source == 'onsite' else 'from customer'})")
                L.advance_status(p["id"], "measured")
            if verified and not (m and m["verified"]):
                run("UPDATE measurements SET verified_on=? WHERE id=?", (L.today(), mid))
            save_measurement_items(mid)
            save_uploads(p, "measurement", mid)
            L.touch(p["id"])
            return redirect(url_for("measurement_detail", mid=mid))
        items = all_("SELECT * FROM measurement_items WHERE measurement_id=? ORDER BY position",
                     (mid,)) if m else []
        return render_template("measurement_form.html", m=m, p=p, items=items,
                               presets=L.MEASUREMENT_PRESETS, today=L.today())

    @app.route("/measurements/<int:mid>")
    def measurement_detail(mid):
        m = row_or_404("measurements", mid)
        p = project_or_404(m["project_id"])
        items = all_("SELECT * FROM measurement_items WHERE measurement_id=? ORDER BY position", (mid,))
        designs = all_("SELECT * FROM designs WHERE measurement_id=? ORDER BY version", (mid,))
        return render_template("measurement_detail.html", m=m, p=p, items=items, designs=designs,
                               files=files_for("measurement", mid))

    @app.post("/measurements/<int:mid>/verify")
    def measurement_verify(mid):
        m = row_or_404("measurements", mid)
        run("UPDATE measurements SET verified=1, verified_on=? WHERE id=?", (L.today(), mid))
        L.log(m["project_id"], f"Measurements verified on site: {m['room']}")
        return redirect(url_for("measurement_detail", mid=mid))

    @app.post("/measurements/<int:mid>/delete")
    def measurement_delete(mid):
        m = row_or_404("measurements", mid)
        run("DELETE FROM measurements WHERE id=?", (mid,))
        return redirect(url_for("project_detail", pid=m["project_id"]))

    # ------------------------------------------------------------------ designs

    @app.route("/projects/<int:pid>/designs/new", methods=["GET", "POST"])
    @app.route("/designs/<int:did>/edit", methods=["GET", "POST"])
    def design_form(pid=None, did=None):
        d = row_or_404("designs", did) if did else None
        p = project_or_404(d["project_id"] if d else pid)
        meas = all_("SELECT * FROM measurements WHERE project_id=? ORDER BY created_at DESC", (p["id"],))
        if request.method == "POST":
            f = request.form
            mid = f.get("measurement_id", type=int)
            if mid and not any(x["id"] == mid for x in meas):
                mid = None
            status = f.get("status") if f.get("status") in ("draft", "presented", "approved", "superseded") \
                else "draft"
            if d:
                run("UPDATE designs SET title=?, measurement_id=?, status=?, notes=? WHERE id=?",
                    (f.get("title"), mid, status, f.get("notes"), did))
            else:
                ver = one("SELECT COALESCE(MAX(version),0)+1 AS v FROM designs WHERE project_id=?",
                          (p["id"],))["v"]
                did = run("""INSERT INTO designs(project_id, version, title, measurement_id, status, notes)
                             VALUES (?,?,?,?,?,?)""", (p["id"], ver, f.get("title"), mid, status, f.get("notes")))
                L.log(p["id"], f"Design v{ver} added")
                L.advance_status(p["id"], "designing")
            save_uploads(p, "design", did)
            L.touch(p["id"])
            return redirect(url_for("design_detail", did=did))
        return render_template("design_form.html", d=d, p=p, meas=meas)

    @app.route("/designs/<int:did>")
    def design_detail(did):
        d = row_or_404("designs", did)
        p = project_or_404(d["project_id"])
        m = one("SELECT * FROM measurements WHERE id=?", (d["measurement_id"],)) if d["measurement_id"] else None
        quotes = all_("SELECT * FROM quotes WHERE design_id=? ORDER BY number, revision", (did,))
        return render_template("design_detail.html", d=d, p=p, m=m, quotes=quotes,
                               files=files_for("design", did))

    @app.post("/designs/<int:did>/delete")
    def design_delete(did):
        d = row_or_404("designs", did)
        run("DELETE FROM designs WHERE id=?", (did,))
        return redirect(url_for("project_detail", pid=d["project_id"]))

    # ------------------------------------------------------------------ quotes

    @app.post("/projects/<int:pid>/quotes/new")
    def quote_new(pid):
        p = project_or_404(pid)
        did = request.form.get("design_id", type=int)
        if not did:
            latest = one("SELECT id FROM designs WHERE project_id=? ORDER BY version DESC LIMIT 1", (pid,))
            did = latest["id"] if latest else None
        qid = L.create_quote(pid, did)
        q = one("SELECT number FROM quotes WHERE id=?", (qid,))
        L.log(pid, f"Quote {q['number']} started")
        return redirect(url_for("quote_edit", qid=qid))

    @app.route("/quotes/<int:qid>")
    def quote_detail(qid):
        q = row_or_404("quotes", qid)
        p = project_or_404(q["project_id"])
        d = one("SELECT * FROM designs WHERE id=?", (q["design_id"],)) if q["design_id"] else None
        m = one("SELECT * FROM measurements WHERE id=?", (d["measurement_id"],)) if d and d["measurement_id"] else None
        revisions = all_("SELECT id, revision, status FROM quotes WHERE number=? ORDER BY revision", (q["number"],))
        invoices = all_("SELECT * FROM invoices WHERE quote_id=? ORDER BY id", (qid,))
        billing = L.quote_billing(qid) if q["status"] == "accepted" else None
        return render_template("quote_detail.html", q=q, p=p, d=d, m=m, t=L.quote_totals(qid),
                               revisions=revisions, invoices=invoices, billing=billing,
                               files=files_for("quote", qid))

    @app.route("/quotes/<int:qid>/edit", methods=["GET", "POST"])
    def quote_edit(qid):
        q = row_or_404("quotes", qid)
        p = project_or_404(q["project_id"])
        if q["status"] != "draft":
            flash("This quote has been sent and is locked. Create a revision to change it.", "error")
            return redirect(url_for("quote_detail", qid=qid))
        designs = all_("SELECT * FROM designs WHERE project_id=? ORDER BY version DESC", (p["id"],))
        if request.method == "POST":
            f = request.form
            did = f.get("design_id", type=int)
            if did and not any(x["id"] == did for x in designs):
                did = None
            run("""UPDATE quotes SET design_id=?, tax_rate=?, discount=?, deposit_pct=?, valid_until=?,
                                     notes=?, terms=? WHERE id=?""",
                (did, f.get("tax_rate", type=float) or 0, f.get("discount", type=float) or 0,
                 f.get("deposit_pct", type=float) or 0, L.parse_date(f.get("valid_until")),
                 f.get("notes"), f.get("terms"), qid))
            db = get_db()
            db.execute("DELETE FROM quote_items WHERE quote_id=?", (qid,))
            pos = 0
            for cat, desc, qty, price in zip(f.getlist("category"), f.getlist("description"),
                                             f.getlist("qty"), f.getlist("unit_price")):
                if not desc.strip():
                    continue
                try:
                    qty_v, price_v = float(qty or 1), float(price or 0)
                except ValueError:
                    qty_v, price_v = 1.0, 0.0
                db.execute("""INSERT INTO quote_items(quote_id, position, category, description, qty, unit_price)
                              VALUES (?,?,?,?,?,?)""", (qid, pos, cat, desc.strip(), qty_v, price_v))
                pos += 1
            db.commit()
            save_uploads(p, "quote", qid)
            L.touch(p["id"])
            if f.get("action") == "send":
                return quote_send(qid)
            flash("Quote saved.")
            return redirect(url_for("quote_edit", qid=qid) if f.get("action") == "stay"
                            else url_for("quote_detail", qid=qid))
        items = all_("SELECT * FROM quote_items WHERE quote_id=? ORDER BY position, id", (qid,))
        return render_template("quote_form.html", q=q, p=p, items=items, designs=designs,
                               categories=L.QUOTE_CATEGORIES, t=L.quote_totals(qid))

    @app.post("/quotes/<int:qid>/send")
    def quote_send(qid):
        q = row_or_404("quotes", qid)
        if q["status"] != "draft":
            abort(400)
        if not one("SELECT 1 FROM quote_items WHERE quote_id=?", (qid,)):
            flash("Add at least one line item before sending.", "error")
            return redirect(url_for("quote_edit", qid=qid))
        run("UPDATE quotes SET status='sent', sent_on=? WHERE id=?", (L.today(), qid))
        L.log(q["project_id"], f"Quote {q['number']} rev {q['revision']} sent "
                               f"({L.quote_totals(qid)['total']:,.2f})")
        L.advance_status(q["project_id"], "quoted")
        return redirect(url_for("quote_detail", qid=qid))

    @app.post("/quotes/<int:qid>/accept")
    def quote_accept(qid):
        q = row_or_404("quotes", qid)
        if q["status"] not in ("sent", "draft"):
            abort(400)
        if q["status"] == "draft":
            run("UPDATE quotes SET sent_on=COALESCE(sent_on, ?) WHERE id=?", (L.today(), qid))
        L.accept_quote(qid)
        flash("Quote accepted. Next step: create the deposit invoice.")
        return redirect(url_for("quote_detail", qid=qid))

    @app.post("/quotes/<int:qid>/decline")
    def quote_decline(qid):
        q = row_or_404("quotes", qid)
        if q["status"] != "sent":
            abort(400)
        run("UPDATE quotes SET status='declined', decided_on=? WHERE id=?", (L.today(), qid))
        L.log(q["project_id"], f"Quote {q['number']} rev {q['revision']} declined")
        return redirect(url_for("quote_detail", qid=qid))

    @app.post("/quotes/<int:qid>/revise")
    def quote_revise(qid):
        q = row_or_404("quotes", qid)
        if q["status"] == "accepted" and one("SELECT 1 FROM invoices WHERE quote_id=? AND status<>'void'", (qid,)):
            flash("This quote already has invoices. Void them first, or handle the change as a separate quote.",
                  "error")
            return redirect(url_for("quote_detail", qid=qid))
        if q["status"] == "accepted":
            run("UPDATE quotes SET status='superseded' WHERE id=?", (qid,))
        new_id = L.revise_quote(qid)
        return redirect(url_for("quote_edit", qid=new_id))

    @app.post("/quotes/<int:qid>/delete")
    def quote_delete(qid):
        q = row_or_404("quotes", qid)
        if q["status"] != "draft":
            abort(400)
        run("DELETE FROM quotes WHERE id=?", (qid,))
        return redirect(url_for("project_detail", pid=q["project_id"]))

    @app.route("/quotes/<int:qid>/print")
    def quote_print(qid):
        q = row_or_404("quotes", qid)
        p = project_or_404(q["project_id"])
        d = one("SELECT * FROM designs WHERE id=?", (q["design_id"],)) if q["design_id"] else None
        return render_template("quote_print.html", q=q, p=p, d=d, t=L.quote_totals(qid))

    # ------------------------------------------------------------------ invoices

    @app.route("/quotes/<int:qid>/invoices/new", methods=["GET", "POST"])
    def invoice_new(qid):
        q = row_or_404("quotes", qid)
        p = project_or_404(q["project_id"])
        if q["status"] != "accepted":
            flash("Accept the quote before invoicing.", "error")
            return redirect(url_for("quote_detail", qid=qid))
        billing = L.quote_billing(qid)
        kind = request.values.get("kind") or (
            "deposit" if not one("SELECT 1 FROM invoices WHERE quote_id=? AND status<>'void'", (qid,))
            else "final")
        if request.method == "POST":
            try:
                iid = L.create_invoice(qid, kind, request.form.get("amount", type=float) or 0,
                                       request.form.get("notes"))
            except ValueError as e:
                flash(str(e), "error")
                return redirect(url_for("invoice_new", qid=qid, kind=kind))
            inv = one("SELECT number FROM invoices WHERE id=?", (iid,))
            L.log(p["id"], f"Invoice {inv['number']} ({kind}) created")
            return redirect(url_for("invoice_detail", iid=iid))
        return render_template("invoice_form.html", q=q, p=p, billing=billing, kind=kind,
                               t=L.quote_totals(qid), suggested=L.suggested_invoice_amount(qid, kind))

    @app.route("/invoices/<int:iid>")
    def invoice_detail(iid):
        i = row_or_404("invoices", iid)
        p = project_or_404(i["project_id"])
        q = row_or_404("quotes", i["quote_id"])
        payments = all_("SELECT * FROM payments WHERE invoice_id=? ORDER BY paid_on, id", (iid,))
        paid = L.invoice_paid(iid)
        return render_template("invoice_detail.html", i=i, p=p, q=q, payments=payments, paid=paid,
                               balance=L.money(i["amount"] - paid), billing=L.quote_billing(q["id"]),
                               files=files_for("invoice", iid), today=L.today())

    @app.post("/invoices/<int:iid>/send")
    def invoice_send(iid):
        i = row_or_404("invoices", iid)
        if i["status"] == "draft":
            run("UPDATE invoices SET status='sent', issued_on=? WHERE id=?", (L.today(), iid))
            L.log(i["project_id"], f"Invoice {i['number']} sent")
            L.advance_status(i["project_id"], "invoiced")
        return redirect(url_for("invoice_detail", iid=iid))

    @app.post("/invoices/<int:iid>/void")
    def invoice_void(iid):
        i = row_or_404("invoices", iid)
        if L.invoice_paid(iid) > 0:
            flash("Remove payments before voiding.", "error")
        else:
            run("UPDATE invoices SET status='void' WHERE id=?", (iid,))
            L.log(i["project_id"], f"Invoice {i['number']} voided")
        return redirect(url_for("invoice_detail", iid=iid))

    @app.post("/invoices/<int:iid>/payments")
    def invoice_payment(iid):
        i = row_or_404("invoices", iid)
        amt = request.form.get("amount", type=float) or 0
        if i["status"] == "void" or amt <= 0:
            flash("Enter a payment amount.", "error")
            return redirect(url_for("invoice_detail", iid=iid))
        if i["status"] == "draft":
            invoice_send(iid)
        run("INSERT INTO payments(invoice_id, paid_on, amount, method, reference) VALUES (?,?,?,?,?)",
            (iid, L.parse_date(request.form.get("paid_on")) or L.today(), L.money(amt),
             request.form.get("method"), request.form.get("reference")))
        L.log(i["project_id"], f"Payment {amt:,.2f} received on {i['number']}")
        L.advance_status(i["project_id"], "invoiced")
        L.refresh_invoice_status(iid)
        return redirect(url_for("invoice_detail", iid=iid))

    @app.post("/payments/<int:pay_id>/delete")
    def payment_delete(pay_id):
        pay = row_or_404("payments", pay_id)
        run("DELETE FROM payments WHERE id=?", (pay_id,))
        L.refresh_invoice_status(pay["invoice_id"])
        return redirect(url_for("invoice_detail", iid=pay["invoice_id"]))

    @app.route("/invoices/<int:iid>/print")
    def invoice_print(iid):
        i = row_or_404("invoices", iid)
        p = project_or_404(i["project_id"])
        q = row_or_404("quotes", i["quote_id"])
        prior = all_("""SELECT * FROM invoices WHERE quote_id=? AND id<? AND status<>'void' ORDER BY id""",
                     (q["id"], iid))
        paid = L.invoice_paid(iid)
        return render_template("invoice_print.html", i=i, p=p, q=q, t=L.quote_totals(q["id"]),
                               prior=prior, paid=paid, balance=L.money(i["amount"] - paid))

    # ------------------------------------------------------------------ settings

    @app.route("/settings", methods=["GET", "POST"])
    def settings_page():
        if request.method == "POST":
            db = get_db()
            for k in get_settings():
                if k in request.form:
                    db.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?,?)",
                               (k, request.form[k]))
            db.commit()
            flash("Settings saved.")
            return redirect(url_for("settings_page"))
        return render_template("settings.html")

    @app.route("/workflow")
    def workflow():
        return render_template("workflow.html")

    return app
