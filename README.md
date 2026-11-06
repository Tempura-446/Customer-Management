# Cabinet CRM: Measure → 2020 Design → Quote → Invoice

Standalone customer-management software for cabinet and kitchen designers who work in **2020 Design**.

- **Windows app.** One PC is the **main office PC**: it holds the master data and files, organized by job.
  Any other office PCs run the same app as **workstations** connected to it over the office network.
- **iPhone and Android app.** Take it on site: measurements, photos, notes and customer details, fully offline. It syncs with the PC whenever you're back on the shop Wi-Fi.
- **No cloud and no subscription.** Data never leaves your office network.

One Flutter codebase builds all three apps (`app/`).

## How everything is organized

```
Customer                       person / household (contact info, lead source)
└── Job  J-2026-014            "Kitchen", "Master bath": has a pipeline status
    ├── 1. Measurements        per room; on site or from customer; verified yes/no; photos & sketches
    ├── 2. Designs v1, v2…     each 2020 save = new version (.kit + PDF + renders), linked to its measurements
    ├── 3. Quotes Q-2026-009   r1, r2… linked to the design version they price
    ├── 4. Invoices INV-…      only from the accepted quote: deposit → progress → final
    │      └── Payments
    ├── Notes & activity       calls, emails, site visits + automatic history
    └── Files                  Documents\Cabinet CRM\Projects\J-2026-014_Smith\{measurements,designs,quotes,invoices,photos}
```

On the PC, every job has a normal Windows folder, so you can open the `.kit` straight in 2020 from the app
or browse the folder in Explorer.

### Rules built in

| Rule | Why |
|---|---|
| Everything hangs off a **job**, not the customer | Repeat customers get a new job, so history stays clean |
| **From-customer measurements stay "not verified"** and are flagged until checked on site | Fine for designing and pricing, never for ordering |
| **Designs are versioned** (v1, v2…), never overwritten | You can always see what the customer approved |
| **Quotes lock when sent.** Changes create a revision (r2) and supersede r1 | Only one live price at a time |
| **Stale-quote warning** if a newer design exists than the one quoted | Stops invoicing the wrong scope |
| **Accepting a quote** approves its design and supersedes every other open quote and design | One source of truth for ordering |
| **Invoices only from the accepted quote**, and never more than the contract total | No missed or double billing |
| **Status moves forward automatically** (Lead → Measured → Designing → Quoted → Approved → Ordered → Received → Installed / Delivered / Picked up → Paid → Closed, or Lost) | The pipeline board stays accurate |

The **Dashboard › Next actions** list shows what's waiting on you: jobs to measure, designs to start, designs to quote,
quotes to follow up or that have expired, deposits to invoice, measurements to verify, draft invoices and overdue invoices.

## Measurement sources (colour-coded)

Every measurement set records where the numbers came from. The colour shows on the job page, the measurement, and the
design and quote it feeds:

| Source | Colour | Ready to order? |
|---|---|---|
| On-site measure (our team) | green | yes |
| Customer measurement | amber | verify on site first |
| Guessed from customer picture | red | ballpark only: the job shows a strong warning |
| From drawings / plans | blue | verify on site first |
| From contractor / builder | purple | verify on site first |
| From a previous job / old file | teal | verify on site first |
| Other (see notes) | grey | verify on site first |

Anything that isn't our own on-site measure shows **not verified** until someone ticks **Verified on site** (or clicks
**Mark verified on site**). Approved jobs with unverified numbers appear in **Next actions → Verify**.

## Order type: pickup, shipping or installation

Every job has an order type, chosen on the job form or from the badge next to the job number:

| Order type | Colour | Means |
|---|---|---|
| Material pickup only | brown | Customer collects from us. No delivery or installation |
| Order for shipping | blue | We ship to the customer / site. No installation |
| Installation order | green | We deliver and install |

How it's used:

- **Jobs list:** filter by order type (top right). The badge also shows on the job list, the pipeline and the customer page.
- **Quotes and invoices** print it, with the address as "Ship to:" or "Install at:", or "Pickup at our shop" for pickup orders.
- **Checks on the job page:**
  - a pickup or shipping job whose quote includes **Installation**
  - an installation job without an Installation line
  - a shipping job without a **Delivery** line
  - a job with a design or quote but no order type yet
- **Measurement sign-off:** on pickup and shipping jobs we never go to site, so unverified customer measurements ask for
  **customer sign-off in writing** instead of "verify on site". Mark them verified once signed.

## Selections and the job packet

**Selections:** each job page has a Selections card (door style, wood, finish, crown, hardware, countertop, sink,
appliances…). **Add missing checklist items** fills in the usual list; empty lines aren't saved.

**Job packet:** click **Job packet** on the job page (highlighted once the job is approved) to print or share a PDF.
There are three presets, and you can tick sections on or off:

| Preset | For | Contains |
|---|---|---|
| **Customer** | the customer to review and sign | selections, measurements, design drawings, quote with prices, payments, approval/signature page |
| **Production / install** | the shop and installers | contact and order type, "check before ordering" warnings, selections, measurements, drawings, scope of work (**no prices**), site photos, notes |
| **Office file** | your records | everything |

Details:

- **Drawings:** PDF drawings attached to the current design (e.g. exported from 2020) are printed page by page in the packet.
- **Sign-off:** on pickup and shipping jobs, the approval page includes "I confirm the measurements are correct".
- **Saving:** on the main PC, **Save to project folder** files the packet with the job. Packets with prices are filed
  with the quotes, so field staff never receive them.
- **Field staff** can only print the production packet.

### Stronger PDFs with ZPDF (optional)

If **ZPDF** (the PDF-Manager toolkit) is installed on a computer, Cabinet CRM finds it and uses it:

- **Sharper job packets.** The original drawing PDFs (e.g. exported from 2020) and the techs' measurement PDFs are
  merged in as real pages, sharp when zoomed and searchable. The packet gets a bookmark per part and page numbers
  across the whole file. Without ZPDF those PDFs are added as pictures.
- **Open in ZPDF.** A pen button on every PDF attached to a job opens it in ZPDF's reader to annotate, sign or edit.
  If you save it in place, the job shows **Save changes** to keep the new version.

Install it with **Install ZPDF.cmd** from the PDF-Manager repository, then check **Settings → PDF tools (ZPDF)**. Cabinet
CRM looks in `%LOCALAPPDATA%\PDF Manager\app` and for `pdfm` on the PATH, or you can pick the program there. The
standalone ZPDF.exe only opens a window, so use the installer version.

## Scheduling (Calendar)

**Calendar** shows the week, one column per day on the PC and a day-by-day list on phones. You can filter it by person
or by kind: site measure, delivery, customer pickup, installation, service.

- **Booking:** from the Calendar (**New appointment**) or from a job's **Appointments** card. Pick the type, date,
  time, length and the person. A warning appears when that person is already booked at that time.
- **Copy confirmation:** produces a ready-to-send message for the customer, e.g. "this confirms your kitchen
  installation on Tuesday Nov 12 at 8:00 AM at 301 Lake Dr".
- **My day** on the dashboard lists today's and tomorrow's appointments for whoever is signed in, with Call,
  Map and Open job buttons. Installers get the same on their phones.
- **Mark done** on an installation, delivery or pickup moves the job to *Installed / Delivered / Picked up*.
- **Next actions** reminds you to book the site measure for new leads, to book the install, delivery or pickup once
  materials are in, to confirm appointments in the next 2 days, and to mark past appointments done.

## Supplier orders and production

After a job is approved, use **Supplier orders & production** on the job page:

1. **New order:** choose the supplier (Settings → Suppliers holds contacts, account numbers and usual lead time).
   Add lines yourself, **from selections**, or **from the quote / QuickBooks estimate**. Choose deliver to the shop
   or ship to the job site; shipping orders default to the site.
2. **PDF:** a purchase order (PO-2026-001) to email to the supplier. It carries no prices.
3. **Mark ordered:** the expected date is filled in from the supplier's lead time, and the job moves to **Ordered**.
   Record the supplier's confirmation number and date with **Supplier confirmed**.
4. **Everything received** (or enter part quantities). Once every order for the job is in, the job moves to
   **Received**, and Next actions says to book the install, delivery or pickup.
5. **Mark installed / delivered / picked up**, or mark the install appointment done: the job moves to **Installed**.
   It becomes **Paid** once the balance is collected.

Reminders: approved jobs with nothing ordered, draft orders not sent, orders past their expected date, and orders with
no delivery date after 3 days. The dashboard also lists **materials arriving this week**.

## Backups

**Settings → Backups** (main PC). Choose a folder on an external drive, a NAS or a network share. Cabinet CRM then
backs up every day while the app is open:

- **Database:** a safe copy of the database, taken while running. The last 14 are kept, or a number you choose.
- **Job files:** a copy of all job folders (`Projects`, `Email inbox`). New and changed files are added each day;
  nothing is ever deleted from the backup.

**Restore:** choose a database copy. Cabinet CRM swaps it in the next time it starts, and keeps your current data as
`cabinet_crm.before-restore-….db`. **Restore missing files** copies back any job files that have gone missing. The
dashboard warns the owner when backups are not set up or have not run for 3 days.

## QuickBooks Desktop (Enterprise 14)

**Settings → QuickBooks** (main PC, owner). Cabinet CRM connects to QuickBooks through Intuit's **Web Connector**,
which comes with QuickBooks:

- **Customers and jobs → QuickBooks.** New Cabinet CRM customers and jobs are created as *Customer* and
  *Customer:Job* (e.g. `Jane Smith:J-2026-014 Kitchen`), so nobody types them twice.
- **Repeat customers are matched, not duplicated.** Matching is by name in any order ("Smith, Jane" = "Jane Smith"),
  or by phone number. QuickBooks customers Cabinet CRM doesn't know yet are imported, so you find them when they call
  again.
- **Estimates → jobs.** Estimates made in QuickBooks appear on the job with number, total and lines. They feed the job
  packet, supplier-order lines and the order-type checks. A new estimate moves the job to *Quoted*; once it's turned
  into a sales order or invoice, to *Approved*.
- **Quotes & invoices are done in QuickBooks** (switch on that page): jobs then show the QuickBooks estimates card
  instead of Cabinet CRM's quote and invoice cards. Use **Attach QuickBooks PDF** to file the PDFs of your QuickBooks
  quotes and invoices with the job.
- **QuickBooks is never changed beyond adding customers and jobs.**

**Setup:**

- **Where:** run the Web Connector on the **main office PC**. It must also have QuickBooks installed. The Web
  Connector only talks to Cabinet CRM on the same computer.
- **Steps:** on the QuickBooks page, set a password, save the **.qwc** file, add it in the Web Connector, then allow
  access in QuickBooks. The page walks you through each step.
- **Untested against real QuickBooks.** The sync was built and tested against sample QuickBooks responses only, so
  check the first sync's log on the QuickBooks page.

## Staff and roles

| Role | Can do |
|---|---|
| **Owner** | Everything, plus staff, PINs and pairing phones |
| **Office / designer** | Everything except staff management |
| **Field / installer** | Customers, jobs, measurements, designs, photos, notes. **Never receives prices**: quotes, invoices, payments and price history are not sent to their phone at all |

On the PC, each person signs in with a PIN. Each phone is paired to one person.

## Several computers: main office PC + workstations

On first start, Windows asks how the computer will be used:

- **Main office PC.** Choose this on **one** computer. It stores the master copy (`Documents\Cabinet CRM`) and serves
  everyone else. Ideally it's a PC that stays on during work hours. Tick "Start Cabinet CRM when Windows starts" in
  the installer, and set Windows to never sleep while plugged in. It can sit at the sign-in screen; sync still runs.
- **Workstation.** Every other office PC. It keeps a local copy, syncs with the main PC every 15 seconds and a few
  seconds after any change, and keeps working if the network drops.

To connect a workstation:

1. On the main PC: **Devices → Add a phone or computer**, then pick the person who will use it.
2. On the workstation: **Find the main office PC** (or type its address), then type the 8-character code.

You can change a computer's role later under **Settings → This computer**.

**Why not just put the file on a network drive / server share?** The database is a single SQLite file, and SQLite
gets corrupted when several computers open it over a network share (SMB). The app warns you if its data folder is on a
network drive. If you have a server, install Cabinet CRM on it as the **main office PC**: workstations then use the
server, the safe way.

**2020 files on a workstation.** Opening a `.kit` downloads it and opens it in 2020. If you edit and save it, the file
shows **"Edited on this computer – Save changes"** in the app. Click it and the new version goes to the main PC at the
next sync. The same button appears on the main PC when a file there is edited in place. Until you save, other
computers keep the previous version. For a real design change, prefer a new design version (v2, v3…) so the history stays.

A workstation is connected as one staff member, and everyone using it acts as that person.

## Measurement emails (shared Gmail mailbox)

If your techs email measurements and photos (PDF) to a shared mailbox, with the site address in the subject,
the main office PC can file them for you:

1. Main PC: **Settings → Measurement email**. Enter the shared Gmail address and an **app password**
   (myaccount.google.com → Security → 2-Step Verification on → App passwords). Click **Test & save**.
2. Every few minutes the main PC reads new emails. It only looks; nothing in the mailbox is marked, moved or deleted.
3. When the subject matches the address of exactly one job, the email becomes a **measurement record on that job**:
   - the PDFs and photos are attached and stored in the job folder (`…\Projects\J-2026-014_Smith\measurements`)
   - the email text becomes the notes, and the sender is "taken by"
   - the job moves to *Measured*

   Matching tolerates "RE:/Fwd:", "Street" vs "St", unit numbers, and the city on either side.
4. Anything else lands in the **Email inbox** (envelope icon on the Dashboard), on every office computer:
   - **File to job…**: choose the job. Likely matches are offered first.
   - **New customer & job**: creates both from the address in the subject, then files the email.
   - **Ignore**.
   - Filed by mistake? Use **Wrong job? Move**.

Two situations always wait for a person: two different customers with a job at the same address, and a subject
with no street number. Emails without a PDF or photo are skipped, and so are email-signature logos.

Tip for the techs: start the subject with the address, e.g. `123 Main St – kitchen`, one job per email.

The app password is stored in Windows Credential Manager on the main PC, not in the database or backups.

## How phone ↔ PC sync works

1. On the PC: **Devices → Add a phone or computer**, then pick the person. A QR code appears; it works once and expires after 15 minutes.
2. On the phone: open Cabinet CRM, then **Scan QR code on the PC**. You can also type the address and code shown under the QR.
3. From then on the phone works offline and syncs automatically when it can reach the main PC:
   on start, every minute, a few seconds after changes, when the app is reopened, or when you tap **Sync now**.

Details:

- **Phones and workstations find the main PC by themselves** (Bonjour/mDNS) even if its IP address changes.
- **New jobs, quotes and invoices made on a phone or workstation** show "pending" until the next sync. The main PC
  then gives them their J-/Q-/INV- number.
- **Phones upload photos.** They download PDFs and 2020 files only when you tap them.
- **If two devices edit the same record,** the most recent edit wins.
- **Lost a phone, or retiring a PC?** Remove it under **Devices** and its access stops at once.
- **Windows Firewall:** the installer allows the app on **private** networks only. Make sure the office network is set to
  *Private* on the main PC (Settings → Network & internet → your network → Private network).

## Your logo on everything printed

**Settings → Business → Choose logo** (PNG with a transparent background looks best). The logo is stored with the shared
settings, so every PC and phone has it. It prints at the top of every document: quotes, invoices, job packets
(customer, production and office) and purchase orders. It also appears on the sign-in screen and in the app's side
bar. If your logo already spells out the business name, tick **My logo already shows our name**.

## Getting the apps

- **Version releases (recommended).** Bump `version:` in `app/pubspec.yaml` (e.g. `1.1.0+2`) and push a tag `v1.1.0`.
  GitHub then publishes a **Release** with the Windows installer and the Android APK attached, under **Releases** on
  the repository page. Release files don't expire.
- **Test builds.** Every other push builds everything. The installer and APK are kept as downloads for 5 days
  under **Actions → Build → Artifacts**.

| File | What to do |
|---|---|
| `CabinetCRM-Setup-x.y.z.exe` | **Windows installer.** Run it on each PC and click through. It installs to Program Files, adds Start menu and optional desktop shortcuts, can start the app with Windows (tick this on the main office PC), allows sync through the firewall on private networks, and includes the Visual C++ runtime. A newer installer upgrades in place. Uninstall from Settings → Apps; your data in `Documents\Cabinet CRM` is never deleted. Until the installer is code-signed, SmartScreen shows "Windows protected your PC": click **More info → Run anyway**. |
| `CabinetCRM-Android.apk` | Copy it to the phone and install. Allow "install unknown apps" for your file manager. |
| iPhone | CI checks that the iPhone app builds. Installing it needs an Apple Developer account ($99/yr) and TestFlight: see the notes in `.github/workflows/build.yml`. |

## Backups

All data is in **`Documents\Cabinet CRM`** on the PC: `data\cabinet_crm.db` plus the `Projects` folders.
Back up that folder, for example with an external drive or File History. To keep the data elsewhere, set the
`CABINET_CRM_DATA` environment variable to another folder before starting the app.

## Development

```bash
cd app
flutter pub get
flutter test                       # business rules, sync engine, PDFs
flutter run -d windows             # the PC app
flutter run -d <phone>             # the phone app

# Demo data (owner PIN 1234, installer PIN 5555):
CABINET_CRM_DATA=/tmp/crm-demo flutter test tool/seed_demo_test.dart
CABINET_CRM_DATA=/tmp/crm-demo flutter run -d windows
# Run the phone version on a computer, for testing sync:
CABINET_CRM_MODE=phone CABINET_CRM_DATA=/tmp/crm-phone flutter run -d linux
```

Code layout:

| Path | What |
|---|---|
| `lib/core/schema.dart` | Data model; every table carries sync bookkeeping |
| `lib/core/logic.dart` | Workflow rules (status, quotes, invoices, warnings, next actions) |
| `lib/core/files.dart` | File storage: job folders on the PC, on-demand files on phones |
| `lib/sync/` | PC sync service (`hub_server.dart`), phone sync client, network discovery |
| `lib/ui/` | Screens |
| `lib/pdf/` | Quote and invoice PDFs |
