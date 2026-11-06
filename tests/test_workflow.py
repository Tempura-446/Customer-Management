import io
import re

import pytest

from cm.app import create_app


@pytest.fixture
def client(tmp_path):
    app = create_app(tmp_path)
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def ok(resp, code=200):
    assert resp.status_code == code, resp.get_data(as_text=True)[:2000]
    return resp


def last_id(location):
    return int(re.search(r"/(\d+)(?:/edit)?$", location).group(1))


def test_full_workflow(client, tmp_path):
    # customer + project
    r = client.post("/customers/new", data={"name": "Jane Smith", "phone": "555-1234",
                                            "address": "1 Main St", "create_project": "1"})
    assert "/projects/new?customer_id=" in r.location
    r = client.post("/projects/new", data={"customer_id": "1", "title": "Kitchen", "site_address": ""})
    pid = last_id(r.location)
    page = ok(client.get(f"/projects/{pid}")).get_data(as_text=True)
    assert "J-20" in page and "1 Main St" in page

    # measurements from customer: unverified
    r = client.post(f"/projects/{pid}/measurements/new", data={
        "room": "Kitchen", "source": "customer", "taken_on": "2026-01-02",
        "label": ["Wall A", "Ceiling", ""], "value": ["120 1/2", "96", ""], "unit": ["in", "in", "in"],
        "files": (io.BytesIO(b"sketch"), "sketch.jpg")}, content_type="multipart/form-data")
    mid = last_id(r.location)
    m = ok(client.get(f"/measurements/{mid}")).get_data(as_text=True)
    assert "120 1/2" in m and "not verified" in m and "sketch.jpg" in m

    # design with a 2020 file
    r = client.post(f"/projects/{pid}/designs/new", data={
        "title": "L-shape", "measurement_id": str(mid), "status": "presented",
        "files": (io.BytesIO(b"KIT"), "smith.kit")}, content_type="multipart/form-data")
    did = last_id(r.location)
    assert list(tmp_path.glob("uploads/J-*_Jane-Smith/designs/smith.kit"))

    proj = ok(client.get(f"/projects/{pid}")).get_data(as_text=True)
    assert "Designing" in proj and "not verified on site" in proj

    # quote from design
    r = client.post(f"/projects/{pid}/quotes/new", data={"design_id": did})
    qid = last_id(r.location)
    r = client.post(f"/quotes/{qid}/edit", data={
        "design_id": did, "tax_rate": "13", "discount": "100", "deposit_pct": "50", "valid_until": "2099-01-01",
        "category": ["Cabinets", "Installation"], "description": ["Shaker cabinets", "Install"],
        "qty": ["1", "2"], "unit_price": ["5000", "500"], "notes": "", "terms": "", "action": "send"})
    q = ok(client.get(f"/quotes/{qid}")).get_data(as_text=True)
    # (6000 - 100) * 1.13 = 6667.00
    assert "$6,667.00" in q and "sent" in q
    # locked after sending
    r = client.get(f"/quotes/{qid}/edit")
    assert r.status_code == 302

    # new design version makes the quote out of date -> revise
    client.post(f"/projects/{pid}/designs/new", data={"title": "with island", "measurement_id": str(mid)})
    assert "latest design is v2" in client.get(f"/projects/{pid}").get_data(as_text=True)
    r = client.post(f"/quotes/{qid}/revise")
    qid2 = last_id(r.location)
    assert "rev 2" in ok(client.get(f"/quotes/{qid2}/edit")).get_data(as_text=True)
    assert "superseded" in client.get(f"/quotes/{qid}").get_data(as_text=True)
    client.post(f"/quotes/{qid2}/send")
    client.post(f"/quotes/{qid2}/accept")
    proj = client.get(f"/projects/{pid}").get_data(as_text=True)
    assert "latest design is" not in proj

    # cannot invoice the superseded quote
    r = client.get(f"/quotes/{qid}/invoices/new")
    assert r.status_code == 302

    # deposit invoice: suggested 50%
    form = ok(client.get(f"/quotes/{qid2}/invoices/new")).get_data(as_text=True)
    assert 'value="3333.50"' in form
    r = client.post(f"/quotes/{qid2}/invoices/new", data={"kind": "deposit", "amount": "3333.50"})
    iid = last_id(r.location)
    # over-invoicing is blocked
    r = client.post(f"/quotes/{qid2}/invoices/new", data={"kind": "final", "amount": "99999"})
    assert "/invoices/new" in r.location
    r = client.post(f"/quotes/{qid2}/invoices/new", data={"kind": "final", "amount": "3333.50"})
    iid2 = last_id(r.location)

    client.post(f"/invoices/{iid}/payments", data={"amount": "3333.50", "paid_on": "2026-02-01", "method": "Cheque"})
    assert "paid" in client.get(f"/invoices/{iid}").get_data(as_text=True)
    assert "Invoiced" in client.get(f"/projects/{pid}").get_data(as_text=True)

    client.post(f"/measurements/{mid}/verify")
    client.post(f"/invoices/{iid2}/payments", data={"amount": "3333.50", "paid_on": "2026-03-01"})
    proj = client.get(f"/projects/{pid}").get_data(as_text=True)
    assert 'value="paid" selected' in proj
    assert "not verified on site" not in proj

    # print pages render
    assert "QUOTE" in ok(client.get(f"/quotes/{qid2}/print")).get_data(as_text=True)
    assert "INVOICE" in ok(client.get(f"/invoices/{iid2}/print")).get_data(as_text=True)


def test_dashboard_and_search(client):
    client.post("/customers/new", data={"name": "Bob Lee", "phone": "555-9"})
    client.post("/projects/new", data={"customer_id": "1", "title": "Bath vanity"})
    d = ok(client.get("/")).get_data(as_text=True)
    assert "Book / take measurements" in d and "Bob Lee" in d
    s = ok(client.get("/search?q=555-9")).get_data(as_text=True)
    assert "Bob Lee" in s
    for url in ["/customers", "/projects", "/settings", "/workflow", "/customers/1", "/projects/1/measurements/new",
                "/projects/1/designs/new"]:
        ok(client.get(url))


def test_numbering_sequential(client):
    client.post("/customers/new", data={"name": "A"})
    a = client.post("/projects/new", data={"customer_id": "1", "title": "x"})
    b = client.post("/projects/new", data={"customer_id": "1", "title": "y"})
    pa = client.get(a.location).get_data(as_text=True)
    pb = client.get(b.location).get_data(as_text=True)
    na = re.search(r"J-\d{4}-(\d{3})", pa).group(1)
    nb = re.search(r"J-\d{4}-(\d{3})", pb).group(1)
    assert (na, nb) == ("001", "002")
