/// Work history: who changed what on a job.
///
/// Every insert / change / delete made through [AppDb] on a job's records writes a row in
/// the synced `activity` table: who (updated_by), what record, and which fields changed from
/// what to what. Several edits by the same person to the same record within 15 minutes are
/// merged into one line. Changes made with nobody signed in (QuickBooks, email filing,
/// sync) are not recorded here; they already leave notes on the job.
///
/// When someone works on a job other people have worked on, the first change also adds a
/// note: "Sam also worked on this job".
library;

import 'db.dart';
import 'logic.dart';
import 'schedule.dart';

/// Tables whose changes are recorded. Line tables are recorded against their parent record.
const _parents = {
  'measurement_items': ('measurements', 'measurement_id', 'dimensions'),
  'quote_items': ('quotes', 'quote_id', 'quote lines'),
  'po_items': ('purchase_orders', 'po_id', 'order lines'),
  'payments': ('invoices', 'invoice_id', 'payments'),
};
const _tracked = {
  'customers', 'projects', 'measurements', 'measurement_items', 'selections', 'designs', 'quotes', 'quote_items',
  'invoices', 'payments', 'appointments', 'purchase_orders', 'po_items', 'files',
};
const _priced = {'quotes', 'quote_items', 'invoices', 'payments'};
const _skipCols = {
  'id', 'created_at', 'updated_at', 'updated_by', 'seq', 'dirty', 'deleted', 'number', 'project_id', 'customer_id',
  'qb_list_id', 'qb_full_name', 'sha256', 'size', 'mime', 'position', 'revision',
  'measurement_id', 'quote_id', 'po_id', 'invoice_id',
};
const _colNames = {
  'unit_price': 'price', 'qty': 'quantity', 'starts_at': 'time', 'duration_min': 'length (min)', 'assigned_to': 'assigned to',
  'order_type': 'order type', 'site_address': 'site address', 'taken_by': 'measured by', 'taken_on': 'measured on',
  'design_id': 'design', 'supplier_id': 'supplier', 'supplier_ref': "supplier's order #", 'deposit_pct': 'deposit %',
  'tax_rate': 'tax rate', 'valid_until': 'valid until', 'due_on': 'due', 'issued_on': 'issued', 'paid_on': 'paid on',
  'expected_on': 'expected', 'deliver_to': 'deliver to', 'received_qty': 'received', 'approval_sent_on': 'sent for approval',
  'approved_by': 'approved by', 'approved_on': 'approved on',
};

/// While > 0, writes are not recorded (e.g. deleting a whole job records one line, not hundreds).
int quietActivity = 0;

T withoutActivity<T>(T Function() body) {
  quietActivity++;
  try {
    return body();
  } finally {
    quietActivity--;
  }
}

String _short(Object? v) {
  final s = '${v ?? ''}'.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return '(blank)';
  return s.length > 40 ? '${s.substring(0, 39)}…' : s;
}

String _value(AppDb db, String col, Object? v) {
  if (v == null || '$v'.isEmpty) return '(blank)';
  switch (col) {
    case 'status':
      return stageKeys.contains('$v') ? stageLabel('$v') : '$v';
    case 'order_type':
      return orderTypeOf('$v')?.short ?? '$v';
    case 'source':
      return sourceOf('$v').short;
    case 'assigned_to':
      return db.get('users', '$v')?.s('name') ?? 'someone';
    case 'supplier_id':
      return db.get('suppliers', '$v')?.s('name') ?? 'a supplier';
    case 'design_id':
      final d = db.get('designs', '$v');
      return d == null ? 'a design' : 'v${d.i('version')}';
    case 'verified':
      return v == 1 ? 'yes' : 'no';
    case 'starts_at':
      final d = parseStart('$v');
      return d == null ? '$v' : '${d.month}/${d.day} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }
  return _short(v);
}

/// A readable name for a record, e.g. 'measurements "Kitchen"', 'design v2', 'quote Q-2026-004 r1'.
String activityLabel(AppDb db, String table, Map<String, Object?> r) {
  String s(String k) => '${r[k] ?? ''}'.trim();
  switch (table) {
    case 'customers':
      return 'customer details';
    case 'projects':
      return 'the job';
    case 'measurements':
      return 'measurements "${s('room')}"';
    case 'designs':
      return 'design v${s('version')}';
    case 'quotes':
      return 'quote ${s('number').isEmpty ? '(new)' : s('number')} r${s('revision')}';
    case 'invoices':
      return 'invoice ${s('number').isEmpty ? '(new)' : s('number')}';
    case 'appointments':
      return '${kindOf(s('kind')).label.toLowerCase()} appointment';
    case 'purchase_orders':
      return 'order ${s('number').isEmpty ? '(new)' : s('number')}';
    case 'files':
      return 'file "${s('name')}"';
    case 'selections':
      return 'selections';
  }
  return table;
}

String? _projectOf(AppDb db, String table, Map<String, Object?> r) {
  if (table == 'projects') return r['id'] as String?;
  if (r['project_id'] is String) return r['project_id'] as String;
  return null;
}

/// Called by AppDb after a write. [old] is the row before (null for an insert).
void recordActivity(AppDb db, String table, String id, Map<String, Object?>? old, Map<String, Object?> now) {
  if (quietActivity > 0 || !_tracked.contains(table)) return;
  final user = db.currentUserId;
  if (user == null) return; // automatic change (QuickBooks, email, sync)
  final merged = {...?old, ...now};
  var tbl = table, recordId = id;
  Map<String, Object?> rec = merged;
  String? lineWhat;
  final parent = _parents[table];
  if (parent != null) {
    final pid = merged[parent.$2] as String?;
    final p = pid == null ? null : db.raw.select('SELECT * FROM ${parent.$1} WHERE id=?', [pid]).firstOrNull;
    if (p == null) return;
    tbl = parent.$1;
    recordId = pid!;
    rec = Map<String, Object?>.from(p);
    lineWhat = parent.$3;
  } else if (table == 'selections') {
    recordId = '${merged['project_id']}';
  }
  final projectId = _projectOf(db, tbl, rec);
  final customerId = tbl == 'customers' ? id : null;
  if (projectId == null && customerId == null) return;

  // What happened.
  String action;
  final details = <String>[];
  final wasDeleted = old != null && old['deleted'] == 1;
  final isDeleted = merged['deleted'] == 1;
  if (lineWhat != null || table == 'selections') {
    action = 'changed';
    details.add(lineWhat ?? 'selections');
  } else if (old == null) {
    action = 'added';
  } else if (isDeleted && !wasDeleted) {
    action = 'deleted';
  } else if (!isDeleted && wasDeleted) {
    action = 'restored';
  } else {
    action = 'changed';
    for (final c in now.keys) {
      if (_skipCols.contains(c)) continue;
      if ('${old[c] ?? ''}' == '${now[c] ?? ''}') continue;
      final name = _colNames[c] ?? c.replaceAll('_', ' ');
      final long = c == 'notes' || c == 'terms' || c == 'body' || '${now[c] ?? ''}'.length > 60;
      details.add(long ? name : '$name ${_value(db, c, old[c])} → ${_value(db, c, now[c])}');
    }
    if (details.isEmpty) return; // only bumped (e.g. "touched" when a note was added)
  }

  final label = activityLabel(db, tbl, rec);
  final priced = _priced.contains(tbl) || _priced.contains(table);
  final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 15)).toIso8601String();

  // Same person, same record, a few minutes ago: merge into that line. Devices only merge into
  // lines they haven't synced yet, so two devices never edit the same history line.
  final recent = db.one(
      'SELECT * FROM activity WHERE tbl=? AND record_id=? AND updated_by=? AND deleted=0 AND updated_at>=? '
      '${db.isHub ? '' : 'AND dirty=1 '}ORDER BY updated_at DESC LIMIT 1',
      [tbl, recordId, user, cutoff]);
  if (recent != null && recent.s('action') == 'added' && action == 'changed') {
    return; // just created: the "added" line already covers it
  }
  if (recent != null && (action == 'changed' || recent.s('action') == action)) {
    final parts = <String>[...recent.s('details').split('; ').where((s) => s.isNotEmpty)];
    for (final d in details) {
      final key = d.split(' ').first;
      // A field changed twice: keep the first "from" and the latest "to".
      final i = parts.indexWhere((p) => p.split(' ').first == key && p.contains(' → ') && d.contains(' → '));
      if (i >= 0) {
        parts[i] = '${parts[i].substring(0, parts[i].indexOf(' → '))} → ${d.substring(d.indexOf(' → ') + 3)}';
      } else if (!parts.contains(d)) {
        parts.add(d);
      }
    }
    var text = parts.join('; ');
    if (text.length > 400) text = '${text.substring(0, 399)}…';
    db.update('activity', recent.id, {
      'details': text,
      'label': label,
      if (recent.s('action') != 'added' && action == 'deleted') 'action': 'deleted',
    });
    return;
  }

  final firstTimeHere = projectId != null &&
      db.one('SELECT 1 FROM activity WHERE project_id=? AND updated_by=? AND deleted=0', [projectId, user]) == null;
  db.insert('activity', {
    'project_id': projectId,
    'customer_id': customerId ?? db.get('projects', projectId)?.ns('customer_id'),
    'tbl': tbl,
    'record_id': recordId,
    'action': action,
    'label': label,
    'details': details.join('; '),
    'priced': priced ? 1 : 0,
  });
  if (firstTimeHere) {
    final others = db.select(
        'SELECT DISTINCT u.name FROM activity a JOIN users u ON u.id=a.updated_by '
        'WHERE a.project_id=? AND a.updated_by<>? AND a.deleted=0',
        [projectId, user]).map((r) => r.s('name')).toList();
    if (others.isNotEmpty) {
      final me = db.get('users', user)?.s('name') ?? 'Someone';
      log(db, projectId, '$me also worked on this job (with ${others.join(', ')})');
    }
  }
}

class Worker {
  Worker(this.userId, this.name, this.changes, this.first, this.last);
  final String userId, name;
  final int changes;
  final String first, last;
}

/// Everyone who changed something on the job, most active first.
List<Worker> jobWorkers(AppDb db, String projectId, {bool prices = true}) => [
      for (final r in db.select('''
          SELECT a.updated_by uid, coalesce(u.name, 'Someone') name, COUNT(*) n, MIN(a.created_at) first, MAX(a.updated_at) last
          FROM activity a LEFT JOIN users u ON u.id=a.updated_by
          WHERE a.project_id=? AND a.deleted=0 ${prices ? '' : 'AND a.priced=0'}
          GROUP BY a.updated_by ORDER BY n DESC''', [projectId]))
        Worker(r.s('uid'), r.s('name'), r.i('n'), r.s('first'), r.s('last')),
    ];

/// The job's history, newest first, optionally for one person.
List<Rec> jobActivity(AppDb db, String projectId, {String? userId, bool prices = true, int limit = 500}) => db.select('''
    SELECT a.*, coalesce(u.name, 'Someone') who FROM activity a LEFT JOIN users u ON u.id=a.updated_by
    WHERE a.project_id=? AND a.deleted=0 ${prices ? '' : 'AND a.priced=0'} ${userId == null ? '' : 'AND a.updated_by=?'}
    ORDER BY a.updated_at DESC LIMIT $limit''', [projectId, ?userId]);

/// "Last changed by Sam, Nov 7 9:02" for a record, or null.
String? lastChangedBy(AppDb db, Rec r) {
  final u = r.ns('updated_by') == null ? null : db.get('users', r.s('updated_by'));
  if (u == null) return null;
  return 'Last changed by ${u.s('name')}, ${fmtWhen(r.s('updated_at'))}';
}

String fmtWhen(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${months[d.month - 1]} ${d.day}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}
