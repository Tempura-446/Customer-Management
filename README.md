# Customer Management: Measure → Design → Quote → Invoice

A small, local web app for cabinet / kitchen designers who work in **2020 Design**.
It keeps every customer's notes, measurements, design files, quotes, invoices and payments
in one place and **linked together**, so you always know which measurements a design used
and which design a price was based on.

Runs on your own computer: one SQLite database file plus an uploads folder. No subscription, no cloud.

## Quick start

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt      # Windows: .venv\Scripts\pip install -r requirements.txt
.venv/bin/python run.py                        # open http://localhost:5000
```

To try it with sample data:

```bash
.venv/bin/python seed_demo.py demo-data
CM_DATA_DIR=demo-data .venv/bin/python run.py
```

First thing: go to **Settings** and enter your business name, tax rate, deposit %, and terms.

Your data lives in `./data/` (`customers.db` + `uploads/`). **Back up that folder**, for example by syncing it
to OneDrive, Dropbox or Google Drive. Set `CM_DATA_DIR=/path/to/folder` to keep it somewhere else.

## How it's organized (the logic)

```
Customer                      one person / household (contact info, lead source)
└── Project  J-2026-014       one job: "Kitchen", "Master bath"; has a status
    ├── 1. Measurements       per room; source = on-site or from customer; verified yes/no
    ├── 2. Designs  v1, v2…   each 2020 save is a new version (.kit + PDF + renders), linked to measurements
    ├── 3. Quotes  Q-2026-009 r1, r2…   linked to the design version they price
    ├── 4. Invoices INV-…     created only from the accepted quote: deposit → progress → final
    │      └── Payments
    ├── Notes / activity log  calls, emails, site visits + automatic history
    └── Files                 uploads/J-2026-014_Customer/{measurements,designs,quotes,invoices,photos}
```

### Rules built in

| Rule | Why |
|---|---|
| **Customer is not the job.** Everything hangs off a Project. | Repeat customers get a new project, so the history stays clean. |
| **Measurements have a source.** "From customer" stays *unverified* and is flagged until you mark it verified on site. | Customer numbers are fine for a design and a price, never for an order. |
| **Designs are versioned.** Never overwrite; add v2. Each version points to the measurements it used. | You can always see what the customer saw and approved. |
| **Quotes lock when sent.** Changes create a *revision* (r2) and the old one becomes *superseded*. | Only one live price at a time, with a full history. |
| **Stale-quote warning.** If you add design v3 after quoting v2, the project tells you the quote is out of date. | Stops you invoicing the wrong scope. |
| **Accepting a quote** approves its design and supersedes every other open quote and design. | One source of truth for production. |
| **Invoices come only from the accepted quote** and can't add up to more than the contract total. Deposit defaults to your deposit %; "final" = whatever is left. | No missed or double billing. |
| **Status moves forward automatically:** Lead → Measured → Designing → Quoted → Approved → Invoiced → Paid → Closed (or Lost). You can override it. | The pipeline board stays accurate without extra clicks. |

### Dashboard: Next actions
The dashboard lists what's waiting on you: jobs to measure, measured jobs with no design, designs with no quote,
quotes to follow up (after *N* days, set in Settings), expired quotes, accepted quotes with no deposit invoice,
unverified customer measurements on approved jobs, draft invoices, and overdue invoices.

## Recommended day-to-day routine

1. **Lead comes in** → *New customer* → *New project*. You get a job number, e.g. `J-2026-014`.
2. **Measure.** Add measurements; use the *Kitchen / Bathroom / Closet* checklist so you never forget the ceiling height or plumbing centre.
   Attach site photos and sketches. If the customer sent the numbers, choose *From customer*.
3. **Design in 2020.** Save the file as `J-2026-014_Smith_v1.kit` and upload it, with the PDF and renders, as *Design v1*.
   Every revision the customer asks for becomes v2, v3…
4. **Quote.** Click *Quote this design*. Copy the totals from the 2020 price report into lines
   (Cabinets / Countertops / Hardware / Installation…). Print to PDF, send it, then click *Mark sent*.
5. **Customer says yes** → *Accepted* → *Create invoice* (deposit). Verify any customer measurements on site **before ordering**.
6. **Record payments** as they come in. Use a progress invoice on delivery if you need one, then the final invoice for the balance.
7. Close the project when it's installed and paid.

Tip: keep the 2020 job folder on your PC named the same as the project (`J-2026-014_Smith`), so the files are easy to find both inside and outside the app.

## Development

```bash
.venv/bin/python -m pytest -q
```

Code layout: `cm/schema.sql` (data model), `cm/logic.py` (business rules), `cm/app.py` (routes), `cm/templates/` (pages).
