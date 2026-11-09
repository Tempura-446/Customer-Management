# Casework (cabinet shop CRM): Measure → 2020 Design → Quote → Invoice

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

### Measurement checklists

**Settings → Measurement checklists** (office). Each kind of room has a list of what the tech must measure: Kitchen,
Bathroom, Closet and Laundry to start with, and any you add. A measurement set uses the list whose name is in its room
("Kitchen 2" and "Main kitchen" use Kitchen). Items left blank are listed on the measurement set, warned about on the
job, mentioned when someone marks the measurements verified, and printed in red in the job packet. The lists sync to
every phone.

### Photos by room

Adding photos to a job asks which room they show (the job's measurement rooms are offered, or type another).
Photos added on a measurement set take its room. Each photo shows its room and has a tag button to change it. A
measurement set also shows the job's other photos of that room, and the job packet groups site photos by room.

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

### Customer approval

On the customer packet, **Email to customer for approval** sends the packet from the shared measurement mailbox on
the main PC (Gmail uses the same app password; another mail server can be set under **Measurement email → Advanced**).
You can edit the recipients, subject and message first. On other devices it opens the phone's or PC's share sheet.
Either way the job shows "sent for approval" and keeps a copy of what was sent.

When the signed page comes back, click **Record approval** on the job: who approved and when, and optionally accept
the quote at the same time. Sending a newer packet clears the old approval. A packet that waits longer than the quote
follow-up days shows up in **Next actions**.

### Stronger PDFs with ZPDF (optional)

If **ZPDF** (the PDF-Manager toolkit) is installed on a computer, Casework finds it and uses it:

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

### Reminders

- **Phones:** each person's appointments the evening before (5 PM) and an hour before, even when the app is closed.
  They update after every sync.
- **Computers:** the same while Casework is open, plus a **Good morning** summary at 7:30: today's appointments,
  unassigned ones this week, next actions and emails to file.
- **Off switch:** each device can turn reminders off under **Settings → Reminders on this device**.

## Reports

**Reports** (owner and office): the last 12 months, this year so far, or last year.

- **Quotes:** sent and their value, won and lost, and the win rate.
- **Speed:** average days from the first measurement to the quote, and from quote to decision.
- **Money:** payments collected, and open quotes still waiting on customers.
- **Breakdowns:** a table by month and one by order type.

QuickBooks estimates and payments count the same way as Casework's own.

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

**Settings → Backups** (main PC). Choose a folder on an external drive, a NAS or a network share. Casework then
backs up every day while the app is open:

- **Database:** a safe copy of the database, taken while running. The last 14 are kept, or a number you choose.
- **Job files:** a copy of all job folders (`Projects`, `Email inbox`). New and changed files are added each day;
  nothing is ever deleted from the backup.

**Restore:** choose a database copy. Casework swaps it in the next time it starts, and keeps your current data as
`cabinet_crm.before-restore-….db`. **Restore missing files** copies back any job files that have gone missing. The
dashboard warns the owner when backups are not set up or have not run for 3 days.

**Weekly check:** once a week Casework test-opens the newest database copy the way a restore would, runs SQLite's
integrity check, and checks every job file is in the backup folder. A problem shows on the dashboard. **Check latest
backup** runs it on demand.

## QuickBooks Desktop (Enterprise 14)

**Settings → QuickBooks** (main PC, owner). Casework connects to QuickBooks through Intuit's **Web Connector**,
which comes with QuickBooks:

- **Customers and jobs → QuickBooks.** New Casework customers and jobs are created as *Customer* and
  *Customer:Job* (e.g. `Jane Smith:J-2026-014 Kitchen`), so nobody types them twice.
- **Repeat customers are matched, not duplicated.** Matching is by name in any order ("Smith, Jane" = "Jane Smith"),
  or by phone number. QuickBooks customers Casework doesn't know yet are imported, so you find them when they call
  again.
- **Estimates → jobs.** Estimates made in QuickBooks appear on the job with number, total and lines. They feed the job
  packet, supplier-order lines and the order-type checks. A new estimate moves the job to *Quoted*; once it's turned
  into a sales order or invoice, to *Approved*.
- **Invoices and payments → jobs.** Invoices and customer payments entered in QuickBooks appear on the job: paid or
  open, due date, amount still owed, payments with method. Once every invoice is paid and the work is done, the job
  moves to *Paid*. The dashboard's *Receivable* and the Reports page include them.
- **Quotes & invoices are done in QuickBooks** (switch on that page): jobs then show the QuickBooks estimates card
  instead of Casework's quote and invoice cards. Use **Attach QuickBooks PDF** to file the PDFs of your QuickBooks
  quotes and invoices with the job.
- **QuickBooks is never changed beyond adding customers and jobs.** Estimates, invoices and payments are only read.

**Setup:**

- **Where:** run the Web Connector on the **main office PC**. It must also have QuickBooks installed. The Web
  Connector only talks to Casework on the same computer.
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
  everyone else. Ideally it's a PC that stays on during work hours. Tick "Start Casework when Windows starts" in
  the installer, and set Windows to never sleep while plugged in. It can sit at the sign-in screen; sync still runs.
- **Workstation.** Every other office PC. It keeps a local copy, syncs with the main PC every 15 seconds and a few
  seconds after any change, and keeps working if the network drops.

To connect a workstation:

1. On the main PC: **Devices → Add a phone or computer**, then pick **Shared office computer** (or one person, for
   a computer only they use).
2. On the workstation: **Find the main office PC** (or type its address), then type the 8-character code.

**Shared office computers.** Staff move between workstations freely. A shared computer shows the same sign-in as
the main PC: tap your name, type your PIN, and **Sign out** when you're done. What you see follows your role, so
installers never see prices there. Each change counts as made by whoever was signed in. PINs are kept on shared
computers, so signing in works even while the main PC is off. A computer already connected to one person can be made
shared from **Devices** (the people icon next to it), with no need to connect it again. Phones stay personal.

You can change a computer's role later under **Settings → This computer**.

**Why not just put the file on a network drive / server share?** The database is a single SQLite file, and SQLite
gets corrupted when several computers open it over a network share (SMB). The app warns you if its data folder is on a
network drive. If you have a server, install Casework on it as the **main office PC**: workstations then use the
server, the safe way.

**2020 files on a workstation.** Opening a `.kit` downloads it and opens it in 2020. If you edit and save it, the file
shows **"Edited on this computer – Save changes"** in the app. Click it and the new version goes to the main PC at the
next sync. The same button appears on the main PC when a file there is edited in place. Until you save, other
computers keep the previous version. For a real design change, prefer a new design version (v2, v3…) so the history stays.

**Who worked on what.** Several people can work on the same job; Casework keeps track:

- **History:** every change to a job's records is logged with who made it and what changed, for example
  "Sam changed measurements "Kitchen": ceiling height 96 → 97". It works the same on the main PC, shared computers
  and phones, and syncs everywhere. Quick edits by one person to the same thing within 15 minutes show as one line.
- **On the job page:** a line lists everyone who worked on the job and how many changes each made. Click a name, or
  **History**, to see what they did, day by day.
- **A note when someone joins:** the first time a second person changes something on a job, the notes say
  "Sam also worked on this job (with Alex)".
- **On each record:** measurements, designs, quotes, invoices and supplier orders show "Last changed by Sam, Nov 7,
  9:02 AM".
- **Prices:** history lines about quotes, invoices and payments are hidden from field staff.

**Drag and drop.** On a computer, drag PDFs (or .kit files and renders) from 2020 or Explorer straight onto a job:

- **Designs (2020) card:** asks whether it is a new version or more files for the latest one, and files it there.
- **Quotes card:** attached to the newest quote, or filed with the job's quotes.
- **QuickBooks card:** asks whether it is an estimate or an invoice.
- **Any file list** (a design, a quote, an invoice, a measurement set, All job files) also accepts dropped files.

The card lights up while a file is over it.

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
2. On the phone: open Casework, then **Scan QR code on the PC**. You can also type the address and code shown under the QR.
3. From then on the phone works offline and syncs automatically when it can reach the main PC:
   on start, every minute, a few seconds after changes, when the app is reopened, or when you tap **Sync now**.

Details:

- **Phones and workstations find the main PC by themselves** (Bonjour/mDNS) even if its IP address changes.
- **New jobs, quotes and invoices made on a phone or workstation** show "pending" until the next sync. The main PC
  then gives them their J-/Q-/INV- number.
- **Phones upload photos.** They download PDFs and 2020 files only when you tap them.
- **If two people edit the same record between syncs,** both edits are kept when they changed different fields
  (say one fixed the phone number and the other the email). When both changed the *same* field, the newer edit wins
  and the job shows an **Edit conflict** warning saying who changed what and which value was kept, until someone
  clicks **Mark checked** under Notes.
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
- **Test builds and checks run on your own computer**, not on GitHub, so GitHub Actions minutes are kept for
  releases. Ordinary pushes don't start a GitHub build. To check the code before a release:

  ```powershell
  powershell -ExecutionPolicy Bypass -File app\tool\check.ps1          # analyzer + all tests
  powershell -ExecutionPolicy Bypass -File app\tool\check.ps1 -Build   # also build the Windows app
  ```

  On macOS or Linux: `app/tool/check.sh` (add `--build` to build too). A GitHub test build of everything can still be
  started by hand: **Actions → Build → Run workflow**, with the tag left empty.

| File | What to do |
|---|---|
| `Casework-Setup-x.y.z.exe` | **Windows installer.** Run it on each PC and click through. It installs to Program Files, adds Start menu and optional desktop shortcuts, can start the app with Windows (tick this on the main office PC), allows sync through the firewall on private networks, and includes the Visual C++ runtime. A newer installer upgrades in place. Uninstall from Settings → Apps; your data in `Documents\Cabinet CRM` is never deleted. Until the installer is code-signed, SmartScreen shows "Windows protected your PC": click **More info → Run anyway**. |
| `Casework-Android.apk` | Copy it to the phone and install. Allow "install unknown apps" for your file manager. |
| iPhone | Installed through **TestFlight** once the Apple secrets are added (below). Until then CI only checks that the iPhone app builds. |

### Signing the Android app (do this once)

Every Android update must be signed with the same key, or the phone refuses to install it over the old version.
Until a key is added, each build is signed with a throwaway key, so updating means uninstalling the old app first
(sync first: anything not yet synced on that phone is lost).

1. On any computer with Java, create the key. Keep the file and passwords safe: losing them means every phone must
   uninstall and reinstall once more.

   ```bash
   keytool -genkeypair -v -keystore casework-release.jks -alias casework \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Turn it into text: `base64 -w0 casework-release.jks` (Windows PowerShell:
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("casework-release.jks"))`).
3. On GitHub: **Settings → Secrets and variables → Actions → New repository secret**, add
   `ANDROID_KEYSTORE_BASE64` (the text from step 2), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`casework`)
   and `ANDROID_KEY_PASSWORD` (the same password, unless you chose a different one for the key).
4. The next build is signed with it. Uninstall the old app on each phone once (after syncing), install the new APK,
   and pair again. From then on, updates install over the top.

### iPhone app: TestFlight (do this once)

Needs an Apple Developer account ($99/year). After this, every release puts the iPhone app on TestFlight; staff
install the free TestFlight app and accept the invite once, then get updates automatically.

1. **App record.** In App Store Connect, **Apps → +**, bundle ID `com.cabinetcrm.cabinetCrm`, name Casework.
2. **Certificate.** In Xcode (**Settings → Accounts → Manage Certificates → + → Apple Distribution**) or on
   developer.apple.com. Export it from Keychain Access as a `.p12` with a password.
3. **Profile.** On developer.apple.com, **Profiles → + → App Store Connect**, for that bundle ID and certificate.
   Download the `.mobileprovision`.
4. **API key.** App Store Connect → **Users and Access → Integrations → App Store Connect API**, create a key with
   the App Manager role. Note the key ID and issuer ID, download the `.p8` (only possible once).
5. **Repository secrets** (GitHub **Settings → Secrets and variables → Actions**):

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Team ID from developer.apple.com → Membership |
   | `IOS_DIST_CERT_P12_BASE64` | `base64 -i cert.p12` |
   | `IOS_DIST_CERT_PASSWORD` | the `.p12` password |
   | `IOS_PROVISION_PROFILE_BASE64` | `base64 -i Casework.mobileprovision` |
   | `APP_STORE_CONNECT_KEY_ID` | key ID |
   | `APP_STORE_CONNECT_ISSUER_ID` | issuer ID |
   | `APP_STORE_CONNECT_KEY_P8` | the whole text of the `.p8` file |

6. Publish a release as usual. In App Store Connect → **TestFlight**, add your staff as testers.

Builds on your own Mac keep automatic signing; only the release job switches to these secrets.

## Backups

All data is in **`Documents\Cabinet CRM`** on the PC (the folder keeps its original name so upgrades find it): `data\cabinet_crm.db` plus the `Projects` folders.
Back up that folder, for example with an external drive or File History. To keep the data elsewhere, set the
`CABINET_CRM_DATA` environment variable to another folder before starting the app.

## Development

```bash
cd app
flutter pub get
flutter test                       # business rules, sync engine, PDFs
tool/check.sh                      # analyzer + tests in one go (tool\check.ps1 on Windows)
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
