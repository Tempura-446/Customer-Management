import 'package:cabinet_crm/core/activity.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/sync/hub_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String alex, sam, pid;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    alex = createUser(db, name: 'Alex', role: 'owner', pin: '1111');
    sam = createUser(db, name: 'Sam', role: 'field', pin: '2222');
    db.currentUserId = alex;
    pid = createProject(db, customerId: saveCustomer(db, {'name': 'Jane'}), title: 'Kitchen');
  });

  // Make the history so far older than the 15-minute merge window.
  void later() => db.raw.execute("UPDATE activity SET updated_at='2026-01-01T00:00:00.000Z'");

  List<String> lines({String? user, bool prices = true}) => [
        for (final r in jobActivity(db, pid, userId: user, prices: prices))
          '${r.s('who')} ${r.s('action')} ${r.s('label')}${r.ns('details') == null ? '' : ': ${r.s('details')}'}',
      ];

  test('who changed what, with old and new values', () {
    later();
    db.update('projects', pid, {'site_address': '12 Oak Ave'});
    expect(lines().first, 'Alex changed the job: site address (blank) → 12 Oak Ave');
    expect(lines().last, startsWith('Alex added the job'));
  });

  test('quick edits to the same thing merge into one line; a field changed twice keeps first and last value', () {
    later();
    db.update('projects', pid, {'title': 'Kitchen 2'});
    db.update('projects', pid, {'title': 'Kitchen + pantry', 'order_type': 'install'});
    final l = lines().where((s) => s.contains('changed the job')).toList();
    expect(l, ['Alex changed the job: title Kitchen → Kitchen + pantry; order type (blank) → Installation']);
  });

  test('a second person is noted on the job, and both are listed', () {
    saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'onsite', lines: [MeasureLine('Wall A', '120', 'in')]);
    later();
    db.currentUserId = sam;
    final m = db.one('SELECT id FROM measurements WHERE project_id=?', [pid])!.id;
    saveMeasurement(db,
        id: m, projectId: pid, room: 'Kitchen', source: 'onsite', notes: 'soffit', lines: [MeasureLine('Wall A', '121', 'in')]);
    expect(lines(user: sam), ['Sam changed measurements "Kitchen": notes; dimensions']);
    final note = db.one("SELECT body FROM notes WHERE project_id=? AND body LIKE '%also worked%'", [pid])!;
    expect(note.s('body'), 'Sam also worked on this job (with Alex)');
    final workers = jobWorkers(db, pid);
    expect(workers.map((w) => w.name), ['Alex', 'Sam']);
    // Only noted once per person.
    db.update('projects', pid, {'site_address': 'x'});
    expect(db.select("SELECT 1 FROM notes WHERE body LIKE '%also worked%'"), hasLength(1));
  });

  test('prices stay with the office; automatic changes and bumps are not listed', () {
    final q = createQuote(db, pid);
    saveQuote(db, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 900)]);
    expect(lines().any((s) => s.contains('quote')), isTrue);
    expect(lines(prices: false).any((s) => s.contains('quote')), isFalse);
    final row = db.one("SELECT * FROM activity WHERE tbl='quotes'")!;
    expect(rowVisible('activity', row.m, 'field'), isFalse);
    final before = lines().length;
    touch(db, pid); // a note bumps the job: not a change
    db.currentUserId = null;
    db.update('projects', pid, {'status': 'quoted'}); // e.g. QuickBooks moved it
    expect(lines().length, before);
  });

  test('deleting a job does not flood the history', () {
    saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'onsite', lines: [MeasureLine('A', '1', 'in')]);
    final before = db.select('SELECT 1 FROM activity').length;
    deleteProject(db, pid);
    expect(db.select('SELECT 1 FROM activity WHERE deleted=0').length, lessThanOrEqualTo(before));
  });

  test('last changed by', () {
    db.currentUserId = sam;
    db.update('projects', pid, {'site_address': 'x'});
    expect(lastChangedBy(db, db.get('projects', pid)!), startsWith('Last changed by Sam, '));
  });
}
