/// Business rules for the measure -> design -> quote -> invoice workflow.
///
/// Every function works the same on the hub (Windows) and on phones; the
/// rows it writes are then exchanged by the sync engine.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'db.dart';
import 'orders.dart';
import '../qb/qb_sync.dart';
import 'schedule.dart';

// ============================================================================ constants

class Stage {
  const Stage(this.key, this.label, this.hint);
  final String key, label, hint;
}

const stages = [
  Stage('lead', 'Lead', 'Need to measure'),
  Stage('measured', 'Measured', 'Ready to design'),
  Stage('designing', 'Designing', 'Design in 2020, then quote'),
  Stage('quoted', 'Quoted', 'Waiting on customer'),
  Stage('approved', 'Approved', 'Deposit, then order materials'),
  Stage('ordered', 'Ordered', 'Waiting on suppliers'),
  Stage('received', 'Received', 'Book install / delivery / pickup'),
  Stage('completed', 'Installed', 'Installed, delivered or picked up'),
  Stage('paid', 'Paid', 'Paid in full'),
  Stage('closed', 'Closed', 'Done'),
  Stage('lost', 'Lost', 'Did not proceed'),
];
final stageKeys = stages.map((s) => s.key).toList();

/// Stages shown on the dashboard pipeline (open work).
final activeStages = stageKeys.sublist(0, stageKeys.indexOf('completed') + 1);

/// Older versions had an "Invoiced" stage between Approved and Paid; it now reads as Approved.
String normalizeStage(String k) => k == 'invoiced' ? 'approved' : k;

String stageLabel(String k) =>
    stages.firstWhere((s) => s.key == normalizeStage(k), orElse: () => Stage(k, k, '')).label;

/// "Installed" reads as "Delivered" / "Picked up" for those order types.
String completedLabel(String? orderType) => switch (orderType) {
      'pickup' => 'Picked up',
      'shipping' => 'Delivered',
      _ => 'Installed',
    };

/// Jobs at or past [stage] (closed/lost excluded).
bool atLeast(String status, String stage) {
  final s = normalizeStage(status);
  if (s == 'closed' || s == 'lost') return false;
  return stageKeys.indexOf(s) >= stageKeys.indexOf(stage);
}

/// Older databases: move jobs from the retired "Invoiced" stage to Approved (main PC only).
void migrateStages(AppDb db) {
  if (!db.isHub) return;
  final rows = db.select("SELECT id FROM projects WHERE status='invoiced'");
  if (rows.isEmpty) return;
  db.tx(() {
    for (final r in rows) {
      db.update('projects', r.id, {'status': 'approved'});
    }
  });
}

const roles = {
  'owner': 'Owner (everything + users & devices)',
  'office': 'Office / designer (everything except users)',
  'field': 'Field / installer (no prices: customers, measurements, designs, photos)',
};
bool canSeePrices(String? role) => role == 'owner' || role == 'office';
bool canManageUsers(String? role) => role == 'owner';

const quoteCategories = [
  'Cabinets', 'Countertops', 'Hardware', 'Accessories', 'Installation', 'Delivery', 'Demo/Removal', 'Other'
];
const fileCategories = ['measurements', 'designs', 'quotes', 'invoices', 'photos', 'other'];
const units = ['in', 'mm', 'cm', 'ft', ''];
const paymentMethods = ['E-transfer', 'Cheque', 'Cash', 'Credit card', 'Financing', 'Other'];

const measurementPresets = <String, List<String>>{
  'Kitchen': [
    'Wall A length', 'Wall B length', 'Wall C length', 'Ceiling height',
    'Soffit / bulkhead height & depth', 'Window 1 (W x H, from left, sill height)',
    'Door / opening (W, from left)', 'Sink / plumbing centre (from left)',
    'Range / cooktop location', 'Fridge opening (W x H)', 'Electrical outlets / switches',
    'Floor level / out-of-square notes',
  ],
  'Bathroom': [
    'Vanity wall length', 'Ceiling height', 'Plumbing centre (from left)', 'Drain height',
    'Supply height', 'Window (W x H, from left)', 'Door swing / clearance', 'Mirror / light location',
  ],
  'Closet': [
    'Back wall length', 'Left return', 'Right return', 'Ceiling height', 'Door opening (W x H)',
    'Baseboard height', 'Outlets / switches',
  ],
  'Laundry': [
    'Wall length', 'Ceiling height', 'Washer / dryer widths', 'Water box / drain location',
    'Dryer vent location', 'Window / door positions',
  ],
};

/// Where a set of measurements came from. Colour-coded everywhere they appear.
/// Anything other than our own on-site measure must be verified on site before ordering.
class MeasureSource {
  const MeasureSource(this.key, this.label, this.short, this.color, this.hint, {this.needsVerify = true, this.risk = 1});
  final String key, label, short, hint;
  final int color; // ARGB
  final bool needsVerify;

  /// 0 = reliable, 1 = check before ordering, 2 = rough estimate.
  final int risk;
}

const measurementSources = <MeasureSource>[
  MeasureSource('onsite', 'On-site measure (our team)', 'On site', 0xFF1F7A45,
      'Measured on site by our tech or designer. Good for ordering.', needsVerify: false, risk: 0),
  MeasureSource('customer', 'Customer measurement', 'Customer', 0xFFB7791F,
      'The customer measured and sent the numbers. Fine to design and quote; verify before ordering.'),
  MeasureSource('photo', 'Guessed from customer picture', 'From photo', 0xFFC53030,
      'Estimated from photos (counting tiles, comparing to a known size). Rough: for a ballpark only.', risk: 2),
  MeasureSource('plans', 'From drawings / plans', 'From plans', 0xFF2357B8,
      "Taken from architect, builder or floor plans. Built walls often differ; verify on site."),
  MeasureSource('contractor', 'From contractor / builder', 'Contractor', 0xFF6B46C1,
      'Supplied by the contractor or builder on the job. Verify before ordering.'),
  MeasureSource('previous', 'From a previous job / old file', 'Previous job', 0xFF2C7A7B,
      'Re-used from earlier work at this address. Things may have changed; verify on site.'),
  MeasureSource('other', 'Other (see notes)', 'Other', 0xFF4A5568,
      'Any other source. Explain it in the notes.'),
];

MeasureSource sourceOf(String? key) =>
    measurementSources.firstWhere((s) => s.key == key, orElse: () => measurementSources[1]);

/// How the order is fulfilled. Set on the job; printed on quotes and invoices.
class OrderType {
  const OrderType(this.key, this.label, this.short, this.color, this.hint, {required this.onSite});
  final String key, label, short, hint;
  final int color; // ARGB

  /// Do we go to the site (so measurements can be verified there)?
  final bool onSite;
}

const orderTypes = <OrderType>[
  OrderType('pickup', 'Material pickup only', 'Pickup', 0xFF8A5A12,
      'The customer collects the material from us. No delivery or installation.', onSite: false),
  OrderType('shipping', 'Order for shipping', 'Shipping', 0xFF2357B8,
      'We ship the material to the customer or site. No installation.', onSite: false),
  OrderType('install', 'Installation order', 'Installation', 0xFF1F7A45,
      'We deliver and install.', onSite: true),
];

/// null when the job's order type hasn't been chosen yet.
OrderType? orderTypeOf(String? key) => orderTypes.where((o) => o.key == key).firstOrNull;

/// Checklist of typical selections for a cabinet job (category -> items).
const selectionChecklist = <String, List<String>>{
  'Cabinets': ['Door style', 'Wood species / material', 'Finish / colour', 'Box construction', 'Drawer boxes',
      'Crown moulding', 'Light rail', 'Toe kick / base'],
  'Hardware': ['Pulls / knobs', 'Hinges', 'Drawer slides'],
  'Countertops': ['Material', 'Colour / pattern', 'Edge profile', 'Backsplash'],
  'Sink & faucet': ['Sink', 'Faucet'],
  'Appliances': ['Range / cooktop', 'Hood', 'Refrigerator', 'Dishwasher', 'Microwave'],
  'Accessories': ['Pull-outs / organisers', 'Lighting'],
};

class SelectionLine {
  SelectionLine(this.category, this.item, [this.choice = '', this.notes = '']);
  String category, item, choice, notes;
}

List<Rec> selectionsFor(AppDb db, String projectId) =>
    db.select('SELECT * FROM selections WHERE project_id=? AND deleted=0 ORDER BY position', [projectId]);

/// Replace the job's selections. Rows without a choice or note are not kept.
void saveSelections(AppDb db, String projectId, List<SelectionLine> lines) => db.tx(() {
      for (final r in selectionsFor(db, projectId)) {
        db.softDelete('selections', r.id);
      }
      var pos = 0;
      for (final l in lines) {
        if (l.item.trim().isEmpty || (l.choice.trim().isEmpty && l.notes.trim().isEmpty)) continue;
        db.insert('selections', {
          'project_id': projectId, 'position': pos++,
          'category': l.category.trim().isEmpty ? 'Other' : l.category.trim(),
          'item': l.item.trim(), 'choice': l.choice.trim(), 'notes': l.notes.trim(),
        });
      }
      log(db, projectId, 'Selections updated ($pos item${pos == 1 ? '' : 's'})');
      touch(db, projectId);
    });

const defaultSettings = {
  'business_name': 'Your Cabinet Co.',
  'business_address': '',
  'business_phone': '',
  'business_email': '',
  'default_tax_rate': '0',
  'default_deposit_pct': '50',
  'quote_valid_days': '30',
  'invoice_due_days': '14',
  'quote_followup_days': '7',
  'default_terms': 'Deposit due on acceptance to place the order. Final measurements are verified on '
      'site before ordering. Balance due on completion of installation.',
};

// ============================================================================ helpers

double money(num x) => (x * 100).roundToDouble() / 100;
String today() => dateOnly(DateTime.now());
String dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String addDays(int n) => dateOnly(DateTime.now().add(Duration(days: n)));

class BusinessError implements Exception {
  BusinessError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ============================================================================ settings

Map<String, String> settings(AppDb db) {
  final s = Map<String, String>.from(defaultSettings);
  for (final r in db.select('SELECT key, value FROM settings WHERE deleted=0')) {
    s[r.s('key')] = r.s('value');
  }
  return s;
}

/// Settings use an id derived from the key, so two devices creating the same
/// setting produce the same row and sync merges them instead of clashing.
String settingId(String key) => 'setting:$key';

void setSetting(AppDb db, String key, String value) {
  final row = db.one('SELECT id FROM settings WHERE key=?', [key]);
  if (row == null) {
    db.insert('settings', {'id': settingId(key), 'key': key, 'value': value});
  } else {
    db.update('settings', row.id, {'value': value, 'deleted': 0});
  }
}

/// Older databases: give settings rows their key-derived ids (main PC only).
void migrateSettingIds(AppDb db) {
  if (!db.isHub) return;
  final rows = db.select('SELECT id, key FROM settings');
  for (final r in rows) {
    final want = settingId(r.s('key'));
    if (r.id == want || db.one('SELECT 1 FROM settings WHERE id=?', [want]) != null) continue;
    db.tx(() {
      db.raw.execute('UPDATE settings SET id=? WHERE id=?', [want, r.id]);
      db.update('settings', want, {}); // new seq so other devices pick it up
    });
  }
}

/// Hub first run: store defaults so they sync to phones.
void seedSettings(AppDb db) => db.tx(() {
      defaultSettings.forEach((k, v) {
        if (db.one('SELECT 1 FROM settings WHERE key=?', [k]) == null) {
          db.insert('settings', {'key': k, 'value': v});
        }
      });
    });

int _int(Map<String, String> s, String k, int dflt) => int.tryParse(s[k] ?? '') ?? dflt;
double _dbl(Map<String, String> s, String k, double dflt) => double.tryParse(s[k] ?? '') ?? dflt;

// ============================================================================ users & PINs

String hashPin(String pin, {String? salt, int iterations = 20000}) {
  salt ??= base64Url.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
  final key = _pbkdf2(utf8.encode(pin), utf8.encode(salt), iterations);
  return 'pbkdf2\$$iterations\$$salt\$${base64Url.encode(key)}';
}

bool checkPin(String pin, String? stored) {
  if (stored == null) return false;
  final p = stored.split('\$');
  if (p.length != 4) return false;
  return _constEq(hashPin(pin, salt: p[2], iterations: int.parse(p[1])), stored);
}

bool _constEq(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

String createUser(AppDb db, {required String name, required String role, String? pin}) =>
    db.insert('users', {'name': name, 'role': role, 'pin_hash': pin == null ? null : hashPin(pin)});

List<Rec> activeUsers(AppDb db) =>
    db.select('SELECT * FROM users WHERE deleted=0 AND active=1 ORDER BY name');

// ============================================================================ log / status

/// kind 'money' = log lines that mention prices (hidden from field users).
void log(AppDb db, String projectId, String body, {String kind = 'system'}) =>
    db.insert('notes', {'project_id': projectId, 'kind': kind, 'body': body});

void touch(AppDb db, String projectId) => db.update('projects', projectId, {});

void setStatus(AppDb db, String projectId, String status, [String? reason]) {
  if (!stageKeys.contains(status)) throw ArgumentError(status);
  db.tx(() {
    db.update('projects', projectId, {'status': status});
    log(db, projectId, 'Status → ${stageLabel(status)}${reason != null ? ' ($reason)' : ''}');
  });
}

/// Move a project forward in the pipeline; never backwards automatically.
void advanceStatus(AppDb db, String projectId, String status, [String? reason]) {
  final p = db.get('projects', projectId);
  if (p == null) return;
  final cur = normalizeStage(p.s('status'));
  if (cur == 'closed' || cur == 'lost') return;
  if (stageKeys.indexOf(status) > stageKeys.indexOf(cur)) setStatus(db, projectId, status, reason);
}

/// Mark the job installed / delivered / picked up (also called when the install appointment is done).
void markCompleted(AppDb db, String projectId, {String? reason}) {
  final p = db.get('projects', projectId);
  if (p == null) return;
  db.tx(() {
    advanceStatus(db, projectId, 'completed', reason ?? completedLabel(p.ns('order_type')).toLowerCase());
    // Already fully paid (Casework invoices)? Then it is done.
    final acc = acceptedQuote(db, projectId);
    if (acc != null && quoteBilling(db, acc.id).total > 0 && quoteBilling(db, acc.id).outstanding <= 0.005) {
      advanceStatus(db, projectId, 'paid', 'balance collected');
    }
  });
}

// ============================================================================ customers / projects

String saveCustomer(AppDb db, Map<String, Object?> v, {String? id}) {
  if ((v['name'] as String? ?? '').trim().isEmpty) throw BusinessError('Name is required.');
  if (id == null) return db.insert('customers', v);
  db.update('customers', id, v);
  return id;
}

String createProject(AppDb db,
        {required String customerId, required String title, String? siteAddress, String? orderType}) =>
    db.tx(() {
      final c = db.get('customers', customerId)!;
      final id = db.insert('projects', {
        'customer_id': customerId,
        'title': title.trim().isEmpty ? 'New project' : title.trim(),
        'site_address': (siteAddress ?? '').trim().isEmpty ? c.ns('address') : siteAddress,
        'status': 'lead',
        'order_type': orderTypeOf(orderType)?.key,
      });
      log(db, id, 'Project created');
      return id;
    });

void setOrderType(AppDb db, String projectId, String? orderType) {
  final p = db.get('projects', projectId)!;
  final ot = orderTypeOf(orderType);
  if (p.ns('order_type') == ot?.key) return;
  db.tx(() {
    db.update('projects', projectId, {'order_type': ot?.key});
    log(db, projectId, 'Order type → ${ot?.label ?? 'not decided'}');
  });
}

/// Display number; phones show "pending" until the hub assigns one.
String numberOf(Rec r) => r.ns('number') ?? '(pending sync)';

Rec? projectWithCustomer(AppDb db, String id) => db.one('''
  SELECT p.*, c.name AS customer, c.phone AS phone, c.email AS email, c.address AS customer_address
  FROM projects p JOIN customers c ON c.id=p.customer_id WHERE p.id=? AND p.deleted=0''', [id]);

List<Rec> projectsList(AppDb db, {String? status, String? customerId, String? query, String? orderType}) {
  final where = ['p.deleted=0', 'c.deleted=0'];
  final args = <Object?>[];
  if (orderType != null) {
    where.add(orderType == 'none' ? 'p.order_type IS NULL' : 'p.order_type=?');
    if (orderType != 'none') args.add(orderType);
  }
  if (status != null) {
    where.add('p.status=?');
    args.add(status);
  }
  if (customerId != null) {
    where.add('p.customer_id=?');
    args.add(customerId);
  }
  if (query != null && query.trim().isNotEmpty) {
    where.add('(p.number LIKE ? OR p.title LIKE ? OR p.site_address LIKE ? OR c.name LIKE ? OR c.phone LIKE ?)');
    args.addAll(List.filled(5, '%${query.trim()}%'));
  }
  return db.select('''SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                      WHERE ${where.join(' AND ')} ORDER BY p.updated_at DESC''', args);
}

List<Rec> customersList(AppDb db, {String? query}) {
  final q = '%${(query ?? '').trim()}%';
  return db.select('''
    SELECT c.*, (SELECT COUNT(*) FROM projects p WHERE p.customer_id=c.id AND p.deleted=0) AS n_projects,
           (SELECT MAX(p.updated_at) FROM projects p WHERE p.customer_id=c.id AND p.deleted=0) AS last_activity
    FROM customers c WHERE c.deleted=0 AND (c.name LIKE ? OR IFNULL(c.phone,'') LIKE ? OR IFNULL(c.email,'') LIKE ?
                                            OR IFNULL(c.address,'') LIKE ?)
    ORDER BY c.name COLLATE NOCASE''', [q, q, q, q]);
}

void deleteProject(AppDb db, String id) => db.tx(() {
      // Children of children first (lines, payments), then everything hanging off the job.
      const children = {
        'measurements': ('measurement_items', 'measurement_id'),
        'quotes': ('quote_items', 'quote_id'),
        'invoices': ('payments', 'invoice_id'),
        'purchase_orders': ('po_items', 'po_id'),
      };
      for (final t in ['measurements', 'designs', 'quotes', 'invoices', 'notes', 'files', 'selections',
          'appointments', 'purchase_orders', 'qb_estimates']) {
        for (final r in db.select('SELECT id FROM $t WHERE project_id=? AND deleted=0', [id])) {
          final child = children[t];
          if (child != null) {
            for (final c in db.select('SELECT id FROM ${child.$1} WHERE ${child.$2}=? AND deleted=0', [r.id])) {
              db.softDelete(child.$1, c.id);
            }
          }
          db.softDelete(t, r.id);
        }
      }
      db.softDelete('projects', id);
    });

void deleteCustomer(AppDb db, String id) => db.tx(() {
      for (final p in db.select('SELECT id FROM projects WHERE customer_id=? AND deleted=0', [id])) {
        deleteProject(db, p.id);
      }
      db.softDelete('customers', id);
    });

void addNote(AppDb db, String projectId, String body, {String kind = 'note'}) {
  if (body.trim().isEmpty) return;
  final p = db.get('projects', projectId)!;
  db.tx(() {
    db.insert('notes', {'project_id': projectId, 'customer_id': p.s('customer_id'), 'kind': kind, 'body': body.trim()});
    touch(db, projectId);
  });
}

// ============================================================================ measurements

class MeasureLine {
  MeasureLine(this.label, this.value, this.unit);
  String label, value, unit;
}

String saveMeasurement(AppDb db,
    {String? id,
    required String projectId,
    required String room,
    required String source,
    String? takenBy,
    String? takenOn,
    bool verified = false,
    String? notes,
    required List<MeasureLine> lines}) {
  return db.tx(() {
    final src = measurementSources.any((s) => s.key == source) ? source : 'customer';
    final isVerified = !sourceOf(src).needsVerify || verified;
    final old = id == null ? null : db.get('measurements', id);
    final v = <String, Object?>{
      'room': room.trim().isEmpty ? 'Room' : room.trim(),
      'source': src,
      'taken_by': takenBy,
      'taken_on': takenOn,
      'verified': isVerified ? 1 : 0,
      'notes': notes,
    };
    if (isVerified && !(old?.b('verified') ?? false)) v['verified_on'] = today();
    String mid;
    if (old == null) {
      mid = db.insert('measurements', {'project_id': projectId, ...v});
      log(db, projectId, 'Measurements added: ${v['room']} (${sourceOf(src).label.toLowerCase()})');
      advanceStatus(db, projectId, 'measured');
    } else {
      mid = old.id;
      db.update('measurements', mid, v);
    }
    // Replace the dimension lines.
    for (final r in db.select('SELECT id FROM measurement_items WHERE measurement_id=? AND deleted=0', [mid])) {
      db.softDelete('measurement_items', r.id);
    }
    var pos = 0;
    for (final l in lines) {
      if (l.label.trim().isEmpty && l.value.trim().isEmpty) continue;
      db.insert('measurement_items', {
        'measurement_id': mid,
        'position': pos++,
        'label': l.label.trim().isEmpty ? '-' : l.label.trim(),
        'value': l.value.trim(),
        'unit': l.unit,
      });
    }
    touch(db, projectId);
    return mid;
  });
}

List<Rec> measurementItems(AppDb db, String mid) =>
    db.select('SELECT * FROM measurement_items WHERE measurement_id=? AND deleted=0 ORDER BY position', [mid]);

void verifyMeasurement(AppDb db, String mid) {
  final m = db.get('measurements', mid)!;
  db.tx(() {
    db.update('measurements', mid, {'verified': 1, 'verified_on': today()});
    log(db, m.s('project_id'), 'Measurements verified on site: ${m.s('room')}');
  });
}

// ============================================================================ designs

String saveDesign(AppDb db,
    {String? id, required String projectId, String? title, String? measurementId, String status = 'draft', String? notes}) {
  return db.tx(() {
    final v = {'title': title, 'measurement_id': measurementId, 'status': status, 'notes': notes};
    if (id != null) {
      db.update('designs', id, v);
      touch(db, projectId);
      return id;
    }
    final ver = (db.scalar('SELECT COALESCE(MAX(version),0)+1 FROM designs WHERE project_id=? AND deleted=0',
        [projectId]) as int);
    final did = db.insert('designs', {'project_id': projectId, 'version': ver, ...v});
    log(db, projectId, 'Design v$ver added');
    advanceStatus(db, projectId, 'designing');
    return did;
  });
}

Rec? latestDesign(AppDb db, String projectId) =>
    db.one('SELECT * FROM designs WHERE project_id=? AND deleted=0 ORDER BY version DESC LIMIT 1', [projectId]);

// ============================================================================ quotes

class QuoteTotals {
  QuoteTotals(this.items, this.subtotal, this.discount, this.tax, this.total, this.deposit, this.byCategory);
  final List<Rec> items;
  final double subtotal, discount, tax, total, deposit;
  final Map<String, double> byCategory;
}

List<Rec> quoteItems(AppDb db, String qid) =>
    db.select('SELECT * FROM quote_items WHERE quote_id=? AND deleted=0 ORDER BY position', [qid]);

QuoteTotals quoteTotals(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  final items = quoteItems(db, qid);
  return computeTotals(items.map((i) => (i.ns('category'), i.d('qty'), i.d('unit_price'))).toList(),
      discount: q.d('discount'), taxRate: q.d('tax_rate'), depositPct: q.d('deposit_pct'), items: items);
}

/// Pure maths so the quote editor can show live totals before saving.
QuoteTotals computeTotals(List<(String?, double, double)> lines,
    {required double discount, required double taxRate, required double depositPct, List<Rec> items = const []}) {
  final sub = money(lines.fold<double>(0, (a, l) => a + l.$2 * l.$3));
  final disc = money(min(discount, sub));
  final taxable = money(sub - disc);
  final tax = money(taxable * taxRate / 100);
  final total = money(taxable + tax);
  final byCat = <String, double>{};
  for (final l in lines) {
    final c = l.$1 ?? 'Other';
    byCat[c] = money((byCat[c] ?? 0) + l.$2 * l.$3);
  }
  return QuoteTotals(items, sub, disc, tax, total, money(total * depositPct / 100), byCat);
}

String createQuote(AppDb db, String projectId, {String? designId}) => db.tx(() {
      final s = settings(db);
      designId ??= latestDesign(db, projectId)?.id;
      final qid = db.insert('quotes', {
        'project_id': projectId,
        'revision': 1,
        'design_id': designId,
        'tax_rate': _dbl(s, 'default_tax_rate', 0),
        'deposit_pct': _dbl(s, 'default_deposit_pct', 50),
        'valid_until': addDays(_int(s, 'quote_valid_days', 30)),
        'terms': s['default_terms'],
      });
      log(db, projectId, 'Quote started');
      return qid;
    });

class QuoteLine {
  QuoteLine({this.category = 'Cabinets', this.description = '', this.qty = 1, this.unitPrice = 0});
  String category, description;
  double qty, unitPrice;
}

void saveQuote(AppDb db, String qid,
    {String? designId, required double taxRate, required double discount, required double depositPct,
    String? validUntil, String? notes, String? terms, required List<QuoteLine> lines}) {
  final q = db.get('quotes', qid)!;
  if (q.s('status') != 'draft') throw BusinessError('This quote is locked. Create a revision to change it.');
  db.tx(() {
    db.update('quotes', qid, {
      'design_id': designId, 'tax_rate': taxRate, 'discount': discount, 'deposit_pct': depositPct,
      'valid_until': validUntil, 'notes': notes, 'terms': terms,
    });
    for (final r in quoteItems(db, qid)) {
      db.softDelete('quote_items', r.id);
    }
    var pos = 0;
    for (final l in lines) {
      if (l.description.trim().isEmpty) continue;
      db.insert('quote_items', {
        'quote_id': qid, 'position': pos++, 'category': l.category, 'description': l.description.trim(),
        'qty': l.qty, 'unit_price': l.unitPrice,
      });
    }
    touch(db, q.s('project_id'));
  });
}

String quoteLabel(Rec q) => '${numberOf(q)} r${q.i('revision')}';

void sendQuote(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  if (q.s('status') != 'draft') throw BusinessError('Only draft quotes can be sent.');
  if (quoteItems(db, qid).isEmpty) throw BusinessError('Add at least one line before sending.');
  db.tx(() {
    db.update('quotes', qid, {'status': 'sent', 'sent_on': today()});
    log(db, q.s('project_id'), 'Quote ${quoteLabel(q)} sent (\$${quoteTotals(db, qid).total.toStringAsFixed(2)})',
        kind: 'money');
    advanceStatus(db, q.s('project_id'), 'quoted');
  });
}

void acceptQuote(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  if (!['draft', 'sent'].contains(q.s('status'))) throw BusinessError('This quote can no longer be accepted.');
  if (quoteItems(db, qid).isEmpty) throw BusinessError('Add at least one line before accepting a quote.');
  final pid = q.s('project_id');
  db.tx(() {
    db.update('quotes', qid, {'status': 'accepted', 'decided_on': today(), 'sent_on': q.ns('sent_on') ?? today()});
    // Only one accepted price per project.
    for (final o in db.select(
        "SELECT id FROM quotes WHERE project_id=? AND id<>? AND deleted=0 AND status IN ('draft','sent','accepted')",
        [pid, qid])) {
      db.update('quotes', o.id, {'status': 'superseded'});
    }
    final did = q.ns('design_id');
    if (did != null) {
      for (final d in db.select("SELECT id FROM designs WHERE project_id=? AND id<>? AND deleted=0 AND status<>'superseded'",
          [pid, did])) {
        db.update('designs', d.id, {'status': 'superseded'});
      }
      db.update('designs', did, {'status': 'approved'});
    }
    log(db, pid, 'Quote ${quoteLabel(q)} accepted');
    advanceStatus(db, pid, 'approved', 'quote ${quoteLabel(q)} accepted');
  });
}

void declineQuote(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  if (q.s('status') != 'sent') throw BusinessError('Only sent quotes can be declined.');
  db.tx(() {
    db.update('quotes', qid, {'status': 'declined', 'decided_on': today()});
    log(db, q.s('project_id'), 'Quote ${quoteLabel(q)} declined');
  });
}

/// Sent quotes are locked. Changing one creates the next revision and
/// supersedes the old one, so only one price is ever "live".
String reviseQuote(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  if (q.ns('number') == null) throw BusinessError('Sync with the main office PC first so this quote gets its number.');
  if (q.s('status') == 'accepted' &&
      db.one("SELECT 1 FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void'", [qid]) != null) {
    throw BusinessError('This quote already has invoices. Void them first, or quote the change separately.');
  }
  final s = settings(db);
  return db.tx(() {
    final rev = (db.scalar('SELECT MAX(revision) FROM quotes WHERE number=? AND deleted=0', [q.s('number')]) as int) + 1;
    final newId = db.insert('quotes', {
      'project_id': q.s('project_id'), 'number': q.s('number'), 'revision': rev,
      'design_id': latestDesign(db, q.s('project_id'))?.id ?? q.ns('design_id'),
      'tax_rate': q.d('tax_rate'), 'discount': q.d('discount'), 'deposit_pct': q.d('deposit_pct'),
      'valid_until': addDays(_int(s, 'quote_valid_days', 30)), 'notes': q.ns('notes'), 'terms': q.ns('terms'),
    });
    for (final i in quoteItems(db, qid)) {
      db.insert('quote_items', {
        'quote_id': newId, 'position': i.i('position'), 'category': i.ns('category'),
        'description': i.s('description'), 'qty': i.d('qty'), 'unit_price': i.d('unit_price'),
      });
    }
    if (q.s('status') != 'superseded') db.update('quotes', qid, {'status': 'superseded'});
    log(db, q.s('project_id'), 'Quote ${q.s('number')} revised → r$rev');
    return newId;
  });
}

void deleteDraftQuote(AppDb db, String qid) {
  final q = db.get('quotes', qid)!;
  if (q.s('status') != 'draft') throw BusinessError('Only drafts can be deleted.');
  db.tx(() {
    for (final i in quoteItems(db, qid)) {
      db.softDelete('quote_items', i.id);
    }
    db.softDelete('quotes', qid);
  });
}

Rec? acceptedQuote(AppDb db, String projectId) => db.one(
    "SELECT * FROM quotes WHERE project_id=? AND status='accepted' AND deleted=0 ORDER BY updated_at DESC LIMIT 1",
    [projectId]);

// ============================================================================ invoices & payments

class Billing {
  Billing(this.total, this.invoiced, this.collected);
  final double total, invoiced, collected;
  double get uninvoiced => money(total - invoiced);
  double get outstanding => money(total - collected);
}

double invoicePaid(AppDb db, String iid) =>
    money((db.scalar('SELECT COALESCE(SUM(amount),0) FROM payments WHERE invoice_id=? AND deleted=0', [iid]) as num));

Billing quoteBilling(AppDb db, String qid) {
  final total = quoteTotals(db, qid).total;
  final invoiced = db.scalar(
      "SELECT COALESCE(SUM(amount),0) FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void'", [qid]) as num;
  final collected = db.scalar('''SELECT COALESCE(SUM(p.amount),0) FROM payments p JOIN invoices i ON i.id=p.invoice_id
                                 WHERE i.quote_id=? AND i.deleted=0 AND p.deleted=0 AND i.status<>'void' ''', [qid]) as num;
  return Billing(total, money(invoiced), money(collected));
}

double suggestedInvoiceAmount(AppDb db, String qid, String kind) {
  final b = quoteBilling(db, qid);
  if (kind == 'deposit') return min(quoteTotals(db, qid).deposit, b.uninvoiced);
  return b.uninvoiced;
}

String createInvoice(AppDb db, String qid, {required String kind, required double amount, String? notes}) {
  final q = db.get('quotes', qid);
  if (q == null || q.s('status') != 'accepted') throw BusinessError('Invoices can only be created from an accepted quote.');
  amount = money(amount);
  final remaining = quoteBilling(db, qid).uninvoiced;
  if (amount <= 0) throw BusinessError('Invoice amount must be more than zero.');
  if (amount > remaining + 0.005) {
    throw BusinessError('Amount exceeds the un-invoiced balance of the quote (\$${remaining.toStringAsFixed(2)}).');
  }
  final s = settings(db);
  return db.tx(() {
    final id = db.insert('invoices', {
      'project_id': q.s('project_id'), 'quote_id': qid, 'kind': kind, 'amount': amount,
      'issued_on': today(), 'due_on': addDays(_int(s, 'invoice_due_days', 14)), 'notes': notes,
    });
    log(db, q.s('project_id'), 'Invoice created ($kind, \$${amount.toStringAsFixed(2)})', kind: 'money');
    return id;
  });
}

void sendInvoice(AppDb db, String iid) {
  final i = db.get('invoices', iid)!;
  if (i.s('status') != 'draft') return;
  db.tx(() {
    db.update('invoices', iid, {'status': 'sent', 'issued_on': today()});
    log(db, i.s('project_id'), 'Invoice ${numberOf(i)} sent');
  });
}

void voidInvoice(AppDb db, String iid) {
  final i = db.get('invoices', iid)!;
  if (invoicePaid(db, iid) > 0) throw BusinessError('Remove payments before voiding.');
  db.tx(() {
    db.update('invoices', iid, {'status': 'void'});
    log(db, i.s('project_id'), 'Invoice ${numberOf(i)} voided');
  });
}

void addPayment(AppDb db, String iid, {required double amount, String? paidOn, String? method, String? reference}) {
  final i = db.get('invoices', iid)!;
  if (i.s('status') == 'void' || amount <= 0) throw BusinessError('Enter a payment amount.');
  db.tx(() {
    if (i.s('status') == 'draft') sendInvoice(db, iid);
    db.insert('payments', {
      'invoice_id': iid, 'paid_on': paidOn ?? today(), 'amount': money(amount), 'method': method, 'reference': reference,
    });
    log(db, i.s('project_id'), 'Payment \$${amount.toStringAsFixed(2)} received on ${numberOf(i)}', kind: 'money');
    refreshInvoiceStatus(db, iid);
  });
}

void deletePayment(AppDb db, String paymentId) {
  final p = db.get('payments', paymentId)!;
  db.tx(() {
    db.softDelete('payments', paymentId);
    refreshInvoiceStatus(db, p.s('invoice_id'));
  });
}

void refreshInvoiceStatus(AppDb db, String iid) {
  final i = db.get('invoices', iid)!;
  if (i.s('status') == 'void') return;
  final paid = invoicePaid(db, iid);
  if (paid >= i.d('amount') - 0.005) {
    if (i.s('status') != 'paid') db.update('invoices', iid, {'status': 'paid'});
  } else if (i.s('status') == 'paid') {
    db.update('invoices', iid, {'status': 'sent'});
  }
  // Paid in full only counts as "Paid" once the work is done.
  final p = db.get('projects', i.s('project_id'));
  if (quoteBilling(db, i.s('quote_id')).outstanding <= 0.005 && p != null && atLeast(p.s('status'), 'completed')) {
    advanceStatus(db, i.s('project_id'), 'paid', 'balance collected');
  }
}

// ============================================================================ warnings & next actions

class Warning {
  Warning(this.serious, this.message);
  final bool serious;
  final String message;
}

List<Warning> projectWarnings(AppDb db, String projectId, {bool prices = true}) {
  final w = <Warning>[];
  final meas = db.select('SELECT * FROM measurements WHERE project_id=? AND deleted=0', [projectId]);
  final designs = db.select('SELECT * FROM designs WHERE project_id=? AND deleted=0 ORDER BY version DESC', [projectId]);
  final quotes = prices
      ? db.select('SELECT * FROM quotes WHERE project_id=? AND deleted=0 ORDER BY updated_at DESC', [projectId])
      : <Rec>[];
  final acc = prices ? acceptedQuote(db, projectId) : null;

  final unverified = meas.where((m) => sourceOf(m.s('source')).needsVerify && !m.b('verified')).toList();
  final guessed = unverified.where((m) => sourceOf(m.s('source')).risk >= 2).toList();
  if (guessed.isNotEmpty) {
    w.add(Warning(true,
        '${guessed.map((m) => m.s('room')).join(', ')}: measurements were guessed from photos. Good for a ballpark only: '
        'measure on site before final design and ordering.'));
  }
  final project = db.get('projects', projectId);
  final ot = orderTypeOf(project?.ns('order_type'));
  final others = unverified.where((m) => sourceOf(m.s('source')).risk < 2).toList();
  if (others.isNotEmpty && (designs.isNotEmpty || acc != null)) {
    final kinds = others.map((m) => sourceOf(m.s('source')).short.toLowerCase()).toSet().join(', ');
    w.add(Warning(
        true,
        ot != null && !ot.onSite
            ? '${others.length} measurement set(s) not checked by us ($kinds). This is a ${ot.short.toLowerCase()} '
                'order: have the customer sign off the measurements in writing before ordering, then mark them verified.'
            : '${others.length} measurement set(s) not verified on site ($kinds). Verify before ordering.'));
  }
  if (project != null && ot == null && (designs.isNotEmpty || quotes.isNotEmpty)) {
    w.add(Warning(false, 'Order type not set: material pickup, shipping or installation?'));
  }
  if (ot != null && prices) {
    final live = quotes.where((q) => ['draft', 'sent', 'accepted'].contains(q.s('status')));
    for (final q in live) {
      final cats = quoteItems(db, q.id).map((i) => i.s('category')).toSet();
      if (ot.key != 'install' && cats.contains('Installation')) {
        w.add(Warning(true, 'Quote ${quoteLabel(q)} includes installation, but this is a ${ot.short.toLowerCase()} order.'));
      }
      if (ot.key == 'install' && !cats.contains('Installation') && cats.isNotEmpty) {
        w.add(Warning(false, 'Installation order, but quote ${quoteLabel(q)} has no Installation line.'));
      }
      if (ot.key == 'shipping' && !cats.contains('Delivery') && cats.isNotEmpty) {
        w.add(Warning(false, 'Shipping order, but quote ${quoteLabel(q)} has no Delivery / shipping line.'));
      }
    }
    final qbe = currentQbEstimate(db, projectId);
    if (qbe != null) {
      final text = qbEstimateLines(qbe).map((l) => '${l['item'] ?? ''} ${l['desc'] ?? ''}').join(' ').toLowerCase();
      final ref = 'QuickBooks estimate #${qbe.s('ref_number')}';
      if (text.trim().isNotEmpty) {
        final hasInstall = text.contains('install');
        final hasDelivery = text.contains('deliver') || text.contains('shipping') || text.contains('freight');
        if (ot.key != 'install' && hasInstall) {
          w.add(Warning(true, '$ref includes installation, but this is a ${ot.short.toLowerCase()} order.'));
        }
        if (ot.key == 'install' && !hasInstall) w.add(Warning(false, 'Installation order, but $ref has no installation line.'));
        if (ot.key == 'shipping' && !hasDelivery) w.add(Warning(false, 'Shipping order, but $ref has no delivery / shipping line.'));
      }
    }
  }
  if (designs.isNotEmpty && meas.isEmpty) w.add(Warning(true, 'Design exists with no measurements on file.'));
  for (final d in designs) {
    if (d.ns('measurement_id') == null && meas.isNotEmpty) {
      w.add(Warning(false, 'Design v${d.i('version')} is not linked to a measurement set.'));
    }
  }
  if (designs.isNotEmpty) {
    final latest = designs.first;
    for (final q in quotes.where((q) => ['draft', 'sent', 'accepted'].contains(q.s('status')))) {
      final did = q.ns('design_id');
      if (did != null && did != latest.id) {
        final dv = designs.where((d) => d.id == did).map((d) => d.i('version')).firstOrNull ?? '?';
        w.add(Warning(true,
            'Quote ${quoteLabel(q)} is priced from design v$dv, but the latest design is v${latest.i('version')}. Revise the quote?'));
      }
      if (did == null && q.s('status') != 'accepted') {
        w.add(Warning(false, 'Quote ${quoteLabel(q)} is not linked to a design.'));
      }
    }
  }
  if (acc != null) {
    final b = quoteBilling(db, acc.id);
    if (b.uninvoiced > 0.005) {
      w.add(Warning(false, '\$${b.uninvoiced.toStringAsFixed(2)} of the accepted quote has not been invoiced yet.'));
    }
  }
  return w;
}

class NextAction {
  NextAction(this.kind, this.text, this.customer, this.ref, this.projectId, {this.quoteId, this.invoiceId});
  final String kind, text, customer, ref, projectId;
  final String? quoteId, invoiceId;
}

List<NextAction> nextActions(AppDb db, {bool prices = true}) {
  final s = settings(db);
  final followup = _int(s, 'quote_followup_days', 7);
  final t = today();
  final out = <NextAction>[];
  const pj = '''SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                WHERE p.deleted=0 AND c.deleted=0''';
  NextAction pa(String kind, Rec p, String text) =>
      NextAction(kind, text, p.s('customer'), '${numberOf(p)} ${p.s('title')}', p.id);

  for (final p in db.select("$pj AND p.status='lead' AND NOT EXISTS "
      '(SELECT 1 FROM measurements m WHERE m.project_id=p.id AND m.deleted=0)')) {
    if (upcomingOf(db, p.id, 'measure') == null) out.add(pa('measure', p, 'Book the site measure'));
  }
  for (final p in db.select("$pj AND p.status='measured' AND NOT EXISTS "
      '(SELECT 1 FROM designs d WHERE d.project_id=p.id AND d.deleted=0)')) {
    out.add(pa('design', p, 'Start 2020 design'));
  }
  for (final p in db.select("$pj AND p.status IN ('approved','invoiced','ordered','received') AND EXISTS "
      "(SELECT 1 FROM measurements m WHERE m.project_id=p.id AND m.deleted=0 AND m.source<>'onsite' AND m.verified=0)")) {
    final ot = orderTypeOf(p.ns('order_type'));
    out.add(pa('verify', p,
        ot != null && !ot.onSite
            ? 'Get customer sign-off on measurements before ordering (${ot.short.toLowerCase()} order)'
            : 'Verify measurements on site before ordering'));
  }
  out.addAll(scheduleNextActions(db));
  if (!prices) return out;
  out.addAll(ordersNextActions(db));

  for (final p in db.select("$pj AND p.status='designing' AND NOT EXISTS "
      "(SELECT 1 FROM quotes q WHERE q.project_id=p.id AND q.deleted=0 AND q.status<>'superseded')")) {
    out.add(pa('quote', p, 'Design done? Build the quote'));
  }
  for (final q in db.select('''SELECT q.*, p.number AS pnum, p.title, c.name AS customer FROM quotes q
        JOIN projects p ON p.id=q.project_id JOIN customers c ON c.id=p.customer_id
        WHERE q.deleted=0 AND p.deleted=0 AND q.status='sent' ''')) {
    final ref = '${q.ns('pnum') ?? ''} ${q.s('title')}';
    if (q.ns('valid_until') != null && q.s('valid_until').compareTo(t) < 0) {
      out.add(NextAction('expired', 'Quote ${quoteLabel(q)} expired ${q.s('valid_until')}', q.s('customer'), ref,
          q.s('project_id'), quoteId: q.id));
    } else if (q.ns('sent_on') != null &&
        dateOnly(DateTime.parse(q.s('sent_on')).add(Duration(days: followup))).compareTo(t) <= 0) {
      out.add(NextAction('follow up', 'Follow up on quote ${quoteLabel(q)} (sent ${q.s('sent_on')})', q.s('customer'),
          ref, q.s('project_id'), quoteId: q.id));
    }
  }
  for (final p in db.select("$pj AND p.status IN ('approved','invoiced','ordered','received')")) {
    final acc = acceptedQuote(db, p.id);
    if (acc != null &&
        quoteBilling(db, acc.id).uninvoiced > 0.005 &&
        db.one("SELECT 1 FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void'", [acc.id]) == null) {
      out.add(NextAction('invoice', 'Quote accepted: send deposit invoice', p.s('customer'),
          '${numberOf(p)} ${p.s('title')}', p.id, quoteId: acc.id));
    }
  }
  for (final i in db.select('''SELECT i.*, p.number AS pnum, p.title, c.name AS customer FROM invoices i
        JOIN projects p ON p.id=i.project_id JOIN customers c ON c.id=p.customer_id
        WHERE i.deleted=0 AND p.deleted=0 AND i.status IN ('draft','sent')''')) {
    final ref = '${i.ns('pnum') ?? ''} ${i.s('title')}';
    if (i.s('status') == 'draft') {
      out.add(NextAction('send', 'Invoice ${numberOf(i)} is still a draft: send it', i.s('customer'), ref,
          i.s('project_id'), invoiceId: i.id));
    } else if (i.ns('due_on') != null && i.s('due_on').compareTo(t) < 0) {
      out.add(NextAction('overdue', 'Invoice ${numberOf(i)} overdue (due ${i.s('due_on')})', i.s('customer'), ref,
          i.s('project_id'), invoiceId: i.id));
    }
  }
  return out;
}

String slug(String text) {
  final s = text.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'x' : (s.length > 40 ? s.substring(0, 40) : s);
}
