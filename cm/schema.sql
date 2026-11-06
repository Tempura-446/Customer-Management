-- Customer Management schema
-- Everything hangs off a PROJECT (a job). A customer can have many projects
-- (kitchen now, bathroom next year). Within a project the paper trail is:
--   measurement -> design (2020 file) -> quote -> invoice -> payment
-- and each step links back to the one before it, so you can always answer
-- "which measurements was this price based on?"

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS customers (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    phone      TEXT,
    email      TEXT,
    address    TEXT,
    source     TEXT,              -- referral, website, showroom, contractor...
    notes      TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS projects (
    id           INTEGER PRIMARY KEY,
    number       TEXT NOT NULL UNIQUE,      -- J-2026-001
    customer_id  INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    title        TEXT NOT NULL,             -- "Kitchen remodel"
    site_address TEXT,
    status       TEXT NOT NULL DEFAULT 'lead',
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS measurements (
    id          INTEGER PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    room        TEXT NOT NULL,
    source      TEXT NOT NULL DEFAULT 'onsite',   -- onsite | customer
    taken_by    TEXT,
    taken_on    TEXT,
    verified    INTEGER NOT NULL DEFAULT 0,       -- customer numbers must be verified onsite before ordering
    verified_on TEXT,
    notes       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS measurement_items (
    id             INTEGER PRIMARY KEY,
    measurement_id INTEGER NOT NULL REFERENCES measurements(id) ON DELETE CASCADE,
    position       INTEGER NOT NULL DEFAULT 0,
    label          TEXT NOT NULL,
    value          TEXT,
    unit           TEXT
);

CREATE TABLE IF NOT EXISTS designs (
    id             INTEGER PRIMARY KEY,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    version        INTEGER NOT NULL,
    title          TEXT,
    measurement_id INTEGER REFERENCES measurements(id) ON DELETE SET NULL,
    status         TEXT NOT NULL DEFAULT 'draft',   -- draft | presented | approved | superseded
    notes          TEXT,
    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (project_id, version)
);

CREATE TABLE IF NOT EXISTS quotes (
    id          INTEGER PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    number      TEXT NOT NULL,                     -- Q-2026-001
    revision    INTEGER NOT NULL DEFAULT 1,
    design_id   INTEGER REFERENCES designs(id) ON DELETE SET NULL,
    status      TEXT NOT NULL DEFAULT 'draft',     -- draft | sent | accepted | declined | superseded
    tax_rate    REAL NOT NULL DEFAULT 0,           -- percent
    discount    REAL NOT NULL DEFAULT 0,           -- flat amount, before tax
    deposit_pct REAL NOT NULL DEFAULT 50,
    valid_until TEXT,
    notes       TEXT,
    terms       TEXT,
    sent_on     TEXT,
    decided_on  TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (number, revision)
);

CREATE TABLE IF NOT EXISTS quote_items (
    id          INTEGER PRIMARY KEY,
    quote_id    INTEGER NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL DEFAULT 0,
    category    TEXT,
    description TEXT NOT NULL,
    qty         REAL NOT NULL DEFAULT 1,
    unit_price  REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS invoices (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    quote_id   INTEGER NOT NULL REFERENCES quotes(id),
    number     TEXT NOT NULL UNIQUE,               -- INV-2026-001
    kind       TEXT NOT NULL DEFAULT 'deposit',    -- deposit | progress | final
    amount     REAL NOT NULL,
    issued_on  TEXT,
    due_on     TEXT,
    status     TEXT NOT NULL DEFAULT 'draft',      -- draft | sent | paid | void
    notes      TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS payments (
    id         INTEGER PRIMARY KEY,
    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    paid_on    TEXT NOT NULL,
    amount     REAL NOT NULL,
    method     TEXT,
    reference  TEXT
);

CREATE TABLE IF NOT EXISTS notes (
    id          INTEGER PRIMARY KEY,
    project_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL DEFAULT 'note',     -- note | call | email | site | system
    body        TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Files: 2020 design files (.kit), PDFs, renders, site photos, signed quotes...
-- Stored on disk under uploads/<project number>_<customer>/<category>/
CREATE TABLE IF NOT EXISTS files (
    id            INTEGER PRIMARY KEY,
    project_id    INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    entity_type   TEXT,          -- measurement | design | quote | invoice | NULL (general)
    entity_id     INTEGER,
    category      TEXT NOT NULL, -- measurements | designs | quotes | invoices | photos | other
    original_name TEXT NOT NULL,
    stored_path   TEXT NOT NULL,
    size          INTEGER,
    uploaded_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS ix_projects_customer ON projects(customer_id);
CREATE INDEX IF NOT EXISTS ix_meas_project ON measurements(project_id);
CREATE INDEX IF NOT EXISTS ix_designs_project ON designs(project_id);
CREATE INDEX IF NOT EXISTS ix_quotes_project ON quotes(project_id);
CREATE INDEX IF NOT EXISTS ix_invoices_project ON invoices(project_id);
CREATE INDEX IF NOT EXISTS ix_notes_project ON notes(project_id);
CREATE INDEX IF NOT EXISTS ix_files_entity ON files(entity_type, entity_id);
