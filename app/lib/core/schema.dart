/// Database schema.
///
/// Organisation: Customer -> Project (job) -> Measurements -> Designs (2020 files)
///   -> Quotes (+ lines) -> Invoices -> Payments, plus Notes and Files on the project.
///
/// Every SYNCED table has the same bookkeeping columns so the phone and the
/// Windows hub can exchange changes:
///   id          UUID (created on any device, never collides)
///   created_at / updated_at   ISO-8601 UTC timestamps (last write wins)
///   updated_by  user id
///   deleted     soft delete (tombstone) so deletions sync too
///   seq         hub change counter (hub: assigned on every write; phone: last seen)
///   dirty       phone only: 1 = changed here, not yet pushed to the hub
library;

const syncCols = '''
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL DEFAULT 0,
  dirty INTEGER NOT NULL DEFAULT 0''';

/// Synced tables, in dependency order (parents first).
const syncTables = <String, String>{
  'users': '''
    name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'office',   -- owner | office | field
    pin_hash TEXT,                          -- never sent to phones
    active INTEGER NOT NULL DEFAULT 1''',
  'settings': '''
    key TEXT NOT NULL UNIQUE,
    value TEXT''',
  'customers': '''
    name TEXT NOT NULL,
    phone TEXT, email TEXT, address TEXT, source TEXT, notes TEXT,
    qb_list_id TEXT                         -- QuickBooks customer ListID once linked''',
  'projects': '''
    number TEXT UNIQUE,                     -- J-2026-001, assigned by the hub
    customer_id TEXT NOT NULL,
    title TEXT NOT NULL,
    site_address TEXT,
    status TEXT NOT NULL DEFAULT 'lead',
    order_type TEXT,                        -- pickup | shipping | install (null = not decided yet)
    qb_list_id TEXT,                        -- QuickBooks job (Customer:Job) ListID once linked
    qb_full_name TEXT,
    approval_sent_on TEXT, approval_sent_to TEXT, -- job packet sent to the customer to approve
    approved_on TEXT, approved_by TEXT       -- customer approval (signature) recorded''',
  'measurements': '''
    project_id TEXT NOT NULL,
    room TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'onsite',  -- onsite | customer
    taken_by TEXT, taken_on TEXT,
    verified INTEGER NOT NULL DEFAULT 0, verified_on TEXT,
    notes TEXT''',
  'measurement_items': '''
    measurement_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    label TEXT NOT NULL, value TEXT, unit TEXT''',
  // Customer selections for the job: door style, finish, hardware, countertop, appliances…
  'selections': '''
    project_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    category TEXT NOT NULL,
    item TEXT NOT NULL,
    choice TEXT,
    notes TEXT''',
  'designs': '''
    project_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    title TEXT,
    measurement_id TEXT,
    status TEXT NOT NULL DEFAULT 'draft',   -- draft | presented | approved | superseded
    notes TEXT''',
  'quotes': '''
    project_id TEXT NOT NULL,
    number TEXT,                            -- Q-2026-001, shared by all revisions
    revision INTEGER NOT NULL DEFAULT 1,
    design_id TEXT,
    status TEXT NOT NULL DEFAULT 'draft',   -- draft | sent | accepted | declined | superseded
    tax_rate REAL NOT NULL DEFAULT 0,
    discount REAL NOT NULL DEFAULT 0,
    deposit_pct REAL NOT NULL DEFAULT 50,
    valid_until TEXT, notes TEXT, terms TEXT, sent_on TEXT, decided_on TEXT''',
  'quote_items': '''
    quote_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    category TEXT, description TEXT NOT NULL,
    qty REAL NOT NULL DEFAULT 1, unit_price REAL NOT NULL DEFAULT 0''',
  'invoices': '''
    project_id TEXT NOT NULL,
    quote_id TEXT NOT NULL,
    number TEXT UNIQUE,                     -- INV-2026-001
    kind TEXT NOT NULL DEFAULT 'deposit',   -- deposit | progress | final
    amount REAL NOT NULL,
    issued_on TEXT, due_on TEXT,
    status TEXT NOT NULL DEFAULT 'draft',   -- draft | sent | paid | void
    notes TEXT''',
  'payments': '''
    invoice_id TEXT NOT NULL,
    paid_on TEXT NOT NULL, amount REAL NOT NULL, method TEXT, reference TEXT''',
  'notes': '''
    project_id TEXT, customer_id TEXT,
    kind TEXT NOT NULL DEFAULT 'note',      -- note | call | email | site | system
    body TEXT NOT NULL''',
  // Site measures, deliveries, pickups, installs, assigned to staff.
  'appointments': '''
    project_id TEXT NOT NULL,
    kind TEXT NOT NULL,                     -- measure | delivery | pickup | install | service | other
    starts_at TEXT NOT NULL,                -- local time, yyyy-MM-ddTHH:mm
    duration_min INTEGER NOT NULL DEFAULT 60,
    assigned_to TEXT,                       -- user id
    status TEXT NOT NULL DEFAULT 'scheduled', -- scheduled | done | cancelled
    confirmed INTEGER NOT NULL DEFAULT 0,   -- customer confirmed the time
    notes TEXT''',
  'suppliers': '''
    name TEXT NOT NULL,
    kind TEXT,                              -- cabinets | countertops | hardware | other
    contact TEXT, phone TEXT, email TEXT, address TEXT, account_no TEXT,
    lead_days INTEGER,                      -- usual days from order to delivery
    notes TEXT''',
  'purchase_orders': '''
    project_id TEXT NOT NULL,
    supplier_id TEXT,
    number TEXT UNIQUE,                     -- PO-2026-001, assigned by the main PC
    supplier_ref TEXT,                      -- supplier's order / confirmation number
    status TEXT NOT NULL DEFAULT 'draft',   -- draft | ordered | confirmed | received | cancelled
    ordered_on TEXT, expected_on TEXT, received_on TEXT,
    deliver_to TEXT,                        -- shop | site
    notes TEXT''',
  'po_items': '''
    po_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    description TEXT NOT NULL,
    qty REAL NOT NULL DEFAULT 1,
    received_qty REAL NOT NULL DEFAULT 0,
    notes TEXT''',
  // Estimates made in QuickBooks, read by the main PC through the Web Connector.
  'qb_estimates': '''
    project_id TEXT, customer_id TEXT,
    qb_txn_id TEXT NOT NULL UNIQUE,
    ref_number TEXT, txn_date TEXT,
    subtotal REAL, tax REAL, total REAL,
    is_active INTEGER NOT NULL DEFAULT 1,   -- QuickBooks "active" (not closed)
    accepted INTEGER NOT NULL DEFAULT 0,    -- turned into a sales order / invoice in QuickBooks
    memo TEXT,
    lines TEXT,                             -- JSON [{item, desc, qty, rate, amount}]
    qb_customer TEXT,                       -- QuickBooks Customer:Job full name
    time_modified TEXT''',
  // Invoices and customer payments made in QuickBooks, read the same way (main PC).
  'qb_invoices': '''
    project_id TEXT, customer_id TEXT,
    qb_txn_id TEXT NOT NULL UNIQUE,
    ref_number TEXT, txn_date TEXT, due_date TEXT,
    subtotal REAL, tax REAL, total REAL,
    balance REAL,                           -- still owed
    is_paid INTEGER NOT NULL DEFAULT 0,
    memo TEXT,
    estimate_txn_id TEXT,                   -- the QuickBooks estimate it was made from
    qb_customer TEXT,
    time_modified TEXT''',
  'qb_payments': '''
    project_id TEXT, customer_id TEXT,
    qb_txn_id TEXT NOT NULL UNIQUE,
    ref_number TEXT, txn_date TEXT,
    amount REAL, method TEXT,
    applied TEXT,                           -- JSON [{txn_id, amount}] invoices it pays
    qb_customer TEXT,
    time_modified TEXT''',
  // Measurement emails read from the shared mailbox (by the main office PC).
  'mail_inbox': '''
    message_id TEXT NOT NULL UNIQUE,
    subject TEXT, sender TEXT, received_at TEXT,
    body TEXT,
    attachments TEXT,                       -- JSON [{name, sha256, size, mime}]
    status TEXT NOT NULL DEFAULT 'unmatched', -- filed | unmatched | ignored
    project_id TEXT, measurement_id TEXT,
    note TEXT                               -- why it wasn't filed / how it was matched''',
  'files': '''
    project_id TEXT NOT NULL,
    entity_type TEXT, entity_id TEXT,       -- measurement | design | quote | invoice | null
    category TEXT NOT NULL,                 -- measurements | designs | quotes | invoices | photos | other
    name TEXT NOT NULL,
    size INTEGER, sha256 TEXT NOT NULL, mime TEXT,
    room TEXT                               -- photos: which room (Kitchen, Pantry…), for grouping''',
  // Work history: who changed what on a job (see core/activity.dart). updated_by = who.
  'activity': '''
    project_id TEXT, customer_id TEXT,
    tbl TEXT NOT NULL, record_id TEXT NOT NULL,
    action TEXT NOT NULL,                   -- added | changed | deleted | restored
    label TEXT,                             -- e.g. measurements "Kitchen", design v2
    details TEXT,                           -- e.g. ceiling height 96 → 97; notes
    priced INTEGER NOT NULL DEFAULT 0       -- mentions prices: hidden from field staff''',
};

/// Tables a "field" user (installer / measurer) never receives or sends:
/// prices stay on the office side.
const pricedTables = {'quotes', 'quote_items', 'invoices', 'payments', 'qb_estimates', 'qb_invoices', 'qb_payments'};

/// Local-only tables (never synced).
const localSchema = '''
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
-- Where a file's bytes live on THIS device.
CREATE TABLE IF NOT EXISTS blobs (
  sha256 TEXT PRIMARY KEY, path TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 1,
  mtime INTEGER);  -- file time when stored; later = edited on this computer
-- Devices only: the version of a row as last received from the main PC, saved when it is
-- first edited here. Sent with the push so the main PC can merge two people's edits field by field.
CREATE TABLE IF NOT EXISTS bases (tbl TEXT NOT NULL, id TEXT NOT NULL, row TEXT NOT NULL, PRIMARY KEY (tbl, id));
-- Hub only: paired phones / tablets.
-- shared = an office computer anyone signs in to with their own PIN (user_id is who paired it).
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT, token_hash TEXT NOT NULL,
  created_at TEXT NOT NULL, last_sync TEXT, revoked INTEGER NOT NULL DEFAULT 0,
  shared INTEGER NOT NULL DEFAULT 0);
-- Hub only: one-time pairing codes shown as QR.
CREATE TABLE IF NOT EXISTS pairing_codes (
  code TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires_at TEXT NOT NULL,
  shared INTEGER NOT NULL DEFAULT 0);
''';

String createStatements() {
  final b = StringBuffer(localSchema);
  syncTables.forEach((t, cols) {
    b.writeln('CREATE TABLE IF NOT EXISTS $t ($syncCols,\n$cols\n);');
    b.writeln('CREATE INDEX IF NOT EXISTS ix_${t}_seq ON $t(seq);');
    b.writeln('CREATE INDEX IF NOT EXISTS ix_${t}_dirty ON $t(dirty);');
  });
  b.writeln('CREATE INDEX IF NOT EXISTS ix_projects_customer ON projects(customer_id);');
  for (final t in ['measurements', 'designs', 'quotes', 'invoices', 'notes', 'files', 'selections',
      'appointments', 'purchase_orders', 'qb_estimates', 'qb_invoices', 'qb_payments', 'activity']) {
    b.writeln('CREATE INDEX IF NOT EXISTS ix_${t}_project ON $t(project_id);');
  }
  return b.toString();
}
