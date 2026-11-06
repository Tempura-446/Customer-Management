"""Fill a data folder with demo customers so you can click around:
    python seed_demo.py demo-data && CM_DATA_DIR=demo-data python run.py
"""
import io
import sys

from cm.app import create_app

app = create_app(sys.argv[1] if len(sys.argv) > 1 else "demo-data")
c = app.test_client()


def new_customer(name, phone, address, title):
    r = c.post("/customers/new", data={"name": name, "phone": phone, "address": address, "source": "Referral"})
    cid = int(r.location.split("/")[-1])
    r = c.post("/projects/new", data={"customer_id": cid, "title": title})
    return int(r.location.split("/")[-1])


def measure(pid, source="onsite"):
    r = c.post(f"/projects/{pid}/measurements/new", data={
        "room": "Kitchen", "source": source, "taken_by": "Me",
        "label": ["Wall A length", "Wall B length", "Ceiling height", "Window 1"],
        "value": ["144", "118 1/4", "96", "36 x 42, 30 from left, sill 42"], "unit": ["in", "in", "in", "in"],
        "notes": "Wall A out of square by 1/4\". Soffit over sink."})
    return int(r.location.split("/")[-1])


def design(pid, mid, title):
    r = c.post(f"/projects/{pid}/designs/new", data={
        "title": title, "measurement_id": mid, "status": "presented",
        "files": (io.BytesIO(b"demo"), "design.kit")}, content_type="multipart/form-data")
    return int(r.location.split("/")[-1])


def quote(pid, did, send=True):
    r = c.post(f"/projects/{pid}/quotes/new", data={"design_id": did})
    qid = int(r.location.split("/")[-2])
    c.post(f"/quotes/{qid}/edit", data={
        "design_id": did, "tax_rate": "13", "discount": "0", "deposit_pct": "50", "valid_until": "2099-12-31",
        "category": ["Cabinets", "Countertops", "Hardware", "Installation"],
        "description": ["Shaker maple, white paint: 14 boxes", "Quartz, 52 sq ft, eased edge", "Soft-close pulls", "Install & levelling"],
        "qty": ["1", "52", "28", "1"], "unit_price": ["11850", "85", "9.5", "2400"],
        "notes": "Includes crown moulding and light rail.", "terms": "", "action": "send" if send else "done"})
    return qid


new_customer("Lisa Chen", "555-201-3344", "12 Oak Ave", "Laundry room")
p = new_customer("Mark Rivera", "555-339-1100", "88 Pine Rd", "Kitchen remodel"); measure(p, "customer")
p = new_customer("Smith Family", "555-410-2020", "4 Elm St", "Kitchen"); m = measure(p); design(p, m, "L-shape w/ island")
p = new_customer("Priya Patel", "555-777-8080", "19 Birch Ln", "Kitchen + pantry"); m = measure(p)
d = design(p, m, "U-shape"); quote(p, d)
p = new_customer("Tom O'Neil", "555-123-4567", "301 Lake Dr", "Kitchen"); m = measure(p, "customer")
d = design(p, m, "Galley"); q = quote(p, d); c.post(f"/quotes/{q}/accept")
r = c.post(f"/quotes/{q}/invoices/new", data={"kind": "deposit", "amount": "9271.15"})
print("Demo data created.")
