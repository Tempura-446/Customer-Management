# Cabinet CRM: Measure → 2020 Design → Quote → Invoice

Standalone customer-management software for cabinet and kitchen designers who work in **2020 Design**.

- **Windows app (the office PC).** This is the main program. It holds all data and files, organized by job, and runs Wi-Fi sync for the phones.
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
| **Status moves forward automatically** (Lead → Measured → Designing → Quoted → Approved → Invoiced → Paid → Closed / Lost) | The pipeline board stays accurate |

The **Dashboard › Next actions** list shows what's waiting on you: jobs to measure, designs to start, designs to quote,
quotes to follow up or that have expired, deposits to invoice, measurements to verify, draft invoices and overdue invoices.

## Staff and roles

| Role | Can do |
|---|---|
| **Owner** | Everything, plus staff, PINs and pairing phones |
| **Office / designer** | Everything except staff management |
| **Field / installer** | Customers, jobs, measurements, designs, photos, notes. **Never receives prices**: quotes, invoices, payments and price history are not sent to their phone at all |

On the PC, each person signs in with a PIN. Each phone is paired to one person.

## How phone ↔ PC sync works

1. On the PC: **Devices → Pair a phone**, then pick the person. A QR code appears; it works once and expires after 15 minutes.
2. On the phone: open Cabinet CRM, then **Scan QR code on the PC**. You can also type the address and code shown under the QR.
3. From then on the phone works offline and syncs automatically when it can reach the PC:
   on start, every 5 minutes, when the app is reopened, or when you tap **Sync now**.

Details:

- **Phones find the PC by itself** (Bonjour/mDNS) even if its IP address changes.
- **New jobs, quotes and invoices made on a phone** show "pending" until the next sync. The PC then gives them their J-/Q-/INV- number.
- **Phones upload photos.** They download PDFs and 2020 files only when you tap them.
- **If two devices edit the same record,** the most recent edit wins.
- **Lost a phone?** Remove it under **Devices** and its access stops at once.
- **Windows Firewall** asks the first time you start the app. Tick **Private networks** and click Allow.

## Getting the apps

Every push to GitHub builds all three apps (see **Actions → Build → Artifacts**):

| Artifact | What to do |
|---|---|
| `CabinetCRM-Windows` | Unzip anywhere, e.g. `C:\Program Files\Cabinet CRM`, and run `cabinet_crm.exe`. Windows SmartScreen may warn until the app is code-signed. |
| `CabinetCRM-Android` | Copy `app-release.apk` to the phone and install. Allow "install unknown apps" for your file manager. |
| `CabinetCRM-iOS-unsigned` | Proves the iPhone app builds. Installing it on iPhones needs an Apple Developer account ($99/yr) and TestFlight: see the notes in `.github/workflows/build.yml`. |

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
