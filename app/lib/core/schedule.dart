/// Scheduling: site measures, deliveries, pickups, installs, service calls.
library;

import 'package:intl/intl.dart';

import 'db.dart';
import 'logic.dart';

class AppointmentKind {
  const AppointmentKind(this.key, this.label, this.color, {this.completes = false});
  final String key, label;
  final int color; // ARGB

  /// Marking this kind done marks the job installed / delivered / picked up.
  final bool completes;
}

const appointmentKinds = <AppointmentKind>[
  AppointmentKind('measure', 'Site measure', 0xFF8A5A12),
  AppointmentKind('delivery', 'Delivery', 0xFF2357B8, completes: true),
  AppointmentKind('pickup', 'Customer pickup', 0xFF6B46C1, completes: true),
  AppointmentKind('install', 'Installation', 0xFF1F7A45, completes: true),
  AppointmentKind('service', 'Service / warranty', 0xFFB02A2A),
  AppointmentKind('other', 'Other', 0xFF4A5568),
];

AppointmentKind kindOf(String? key) =>
    appointmentKinds.firstWhere((k) => k.key == key, orElse: () => appointmentKinds.last);

/// The completing appointment kind for a job's order type.
String completingKind(String? orderType) => switch (orderType) {
      'pickup' => 'pickup',
      'shipping' => 'delivery',
      _ => 'install',
    };

String fmtStart(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}';
String _two(int n) => n.toString().padLeft(2, '0');

DateTime? parseStart(String? s) => s == null ? null : DateTime.tryParse(s);

String _when(DateTime d) => DateFormat('EEE d MMM HH:mm').format(d);

String saveAppointment(AppDb db,
    {String? id,
    required String projectId,
    required String kind,
    required DateTime start,
    int durationMin = 60,
    String? assignedTo,
    String? notes,
    bool confirmed = false}) {
  final k = kindOf(kind);
  final v = <String, Object?>{
    'project_id': projectId,
    'kind': k.key,
    'starts_at': fmtStart(start),
    'duration_min': durationMin < 5 ? 5 : durationMin,
    'assigned_to': assignedTo,
    'notes': notes,
    'confirmed': confirmed ? 1 : 0,
  };
  return db.tx(() {
    final who = assignedTo == null ? null : db.get('users', assignedTo)?.ns('name');
    if (id == null) {
      final nid = db.insert('appointments', {...v, 'status': 'scheduled'});
      log(db, projectId, '${k.label} booked ${_when(start)}${who != null ? ' – $who' : ''}');
      return nid;
    }
    final old = db.get('appointments', id);
    db.update('appointments', id, v);
    if (old != null && old.s('starts_at') != v['starts_at']) {
      log(db, projectId, '${k.label} moved to ${_when(start)}${who != null ? ' – $who' : ''}');
    }
    return id;
  });
}

void cancelAppointment(AppDb db, String id) {
  final a = db.get('appointments', id);
  if (a == null) return;
  db.tx(() {
    db.update('appointments', id, {'status': 'cancelled'});
    final d = parseStart(a.s('starts_at'));
    log(db, a.s('project_id'), '${kindOf(a.s('kind')).label} cancelled${d != null ? ' (${_when(d)})' : ''}');
  });
}

void markAppointmentDone(AppDb db, String id) {
  final a = db.get('appointments', id);
  if (a == null) return;
  final k = kindOf(a.s('kind'));
  db.tx(() {
    db.update('appointments', id, {'status': 'done'});
    log(db, a.s('project_id'), '${k.label} done');
    if (k.completes) markCompleted(db, a.s('project_id'), reason: '${k.label.toLowerCase()} done');
  });
}

const _apptSelect = '''
  SELECT a.*, p.number AS pnum, p.title AS ptitle, p.site_address AS site_address, p.order_type AS order_type,
         p.status AS pstatus, c.name AS customer, c.phone AS phone, u.name AS user_name
  FROM appointments a
  JOIN projects p ON p.id=a.project_id
  JOIN customers c ON c.id=p.customer_id
  LEFT JOIN users u ON u.id=a.assigned_to
  WHERE a.deleted=0 AND p.deleted=0''';

List<Rec> appointmentsBetween(AppDb db, DateTime from, DateTime to,
    {String? userId, String? kind, bool includeCancelled = false}) {
  final where = <String>['a.starts_at >= ?', 'a.starts_at < ?'];
  final args = <Object?>[fmtStart(from), fmtStart(to)];
  if (userId != null) {
    where.add('a.assigned_to=?');
    args.add(userId);
  }
  if (kind != null) {
    where.add('a.kind=?');
    args.add(kind);
  }
  if (!includeCancelled) where.add("a.status<>'cancelled'");
  return db.select('$_apptSelect AND ${where.join(' AND ')} ORDER BY a.starts_at', args);
}

List<Rec> projectAppointments(AppDb db, String projectId) =>
    db.select("$_apptSelect AND a.project_id=? ORDER BY a.starts_at DESC", [projectId]);

/// Today and tomorrow for one person.
List<Rec> todayFor(AppDb db, String userId) {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  return appointmentsBetween(db, start, start.add(const Duration(days: 2)), userId: userId)
      .where((a) => a.s('status') == 'scheduled')
      .toList();
}

/// Scheduled appointments of the same person that overlap.
List<Rec> conflicts(AppDb db, {required String? assignedTo, required DateTime start, required int durationMin, String? excludeId}) {
  if (assignedTo == null) return const [];
  final end = start.add(Duration(minutes: durationMin));
  final dayStart = DateTime(start.year, start.month, start.day).subtract(const Duration(days: 1));
  return appointmentsBetween(db, dayStart, end, userId: assignedTo).where((a) {
    if (a.id == excludeId || a.s('status') != 'scheduled') return false;
    final s = parseStart(a.s('starts_at'));
    if (s == null) return false;
    final e = s.add(Duration(minutes: a.i('duration_min')));
    return s.isBefore(end) && e.isAfter(start);
  }).toList();
}

bool hasUpcomingMeasure(AppDb db, String projectId) => upcomingOf(db, projectId, 'measure') != null;

/// Next scheduled appointment of [kind] for a job (from today on).
Rec? upcomingOf(AppDb db, String projectId, String kind) {
  final now = DateTime.now();
  return db.one(
      "SELECT * FROM appointments WHERE project_id=? AND kind=? AND status='scheduled' AND deleted=0 AND starts_at >= ? "
      'ORDER BY starts_at LIMIT 1',
      [projectId, kind, fmtStart(DateTime(now.year, now.month, now.day))]);
}

String describeAppointment(Rec a) {
  final d = parseStart(a.s('starts_at'));
  return '${kindOf(a.s('kind')).label}${d != null ? ' ${_when(d)}' : ''}${a.ns('user_name') != null ? ' – ${a.s('user_name')}' : ''}';
}

List<NextAction> scheduleNextActions(AppDb db) {
  final out = <NextAction>[];
  final now = DateTime.now();
  const pj = '''SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                WHERE p.deleted=0 AND c.deleted=0''';
  for (final p in db.select("$pj AND p.status='received'")) {
    final kind = completingKind(p.ns('order_type'));
    if (upcomingOf(db, p.id, kind) != null) continue;
    final label = switch (kind) { 'pickup' => 'Book pickup', 'delivery' => 'Book delivery', _ => 'Book installation' };
    out.add(NextAction('book', '$label (materials received)', p.s('customer'), '${numberOf(p)} ${p.s('title')}', p.id));
  }
  for (final a in appointmentsBetween(db, now.subtract(const Duration(days: 30)), now.add(const Duration(days: 2)))) {
    if (a.s('status') != 'scheduled') continue;
    final s = parseStart(a.s('starts_at'));
    if (s == null) continue;
    final ref = '${a.ns('pnum') ?? ''} ${a.s('ptitle')}';
    final end = s.add(Duration(minutes: a.i('duration_min')));
    if (end.add(const Duration(hours: 2)).isBefore(now)) {
      out.add(NextAction('mark done', '${describeAppointment(a)}: done? Mark it done or move it', a.s('customer'), ref,
          a.s('project_id')));
    } else if (s.isAfter(now) && !a.b('confirmed')) {
      out.add(NextAction('confirm', 'Confirm ${describeAppointment(a)} with the customer', a.s('customer'), ref,
          a.s('project_id')));
    }
  }
  return out;
}

/// Friendly message to paste into a text or email.
String confirmationText(AppDb db, String appointmentId) {
  final a = db.one('$_apptSelect AND a.id=?', [appointmentId]);
  if (a == null) return '';
  final s = settings(db);
  final d = parseStart(a.s('starts_at'));
  final first = a.s('customer').split(' ').first;
  final kind = kindOf(a.s('kind'));
  final what = switch (kind.key) {
    'measure' => 'site measure',
    'install' => '${a.s('ptitle').toLowerCase()} installation',
    'delivery' => '${a.s('ptitle').toLowerCase()} delivery',
    'pickup' => 'pickup of your ${a.s('ptitle').toLowerCase()} order',
    'service' => 'service visit',
    _ => 'appointment',
  };
  final when = d == null ? '' : ' on ${DateFormat('EEEE MMM d').format(d)} at ${DateFormat('h:mm a').format(d)}';
  final where = kind.key == 'pickup'
      ? ' at our shop${(s['business_address'] ?? '').isNotEmpty ? ' (${s['business_address']})' : ''}'
      : (a.ns('site_address') != null ? ' at ${a.s('site_address')}' : '');
  final sign = [s['business_name'], s['business_phone']].where((x) => (x ?? '').isNotEmpty).join(' ');
  return 'Hi $first, this confirms your $what$when$where. Please let us know if anything changes. — $sign';
}
