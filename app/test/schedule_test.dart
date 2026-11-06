import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String pid, sam;

  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    setSetting(db, 'business_name', 'Maple & Oak Cabinetry');
    setSetting(db, 'business_phone', '555-0100');
    sam = createUser(db, name: 'Sam Installer', role: 'field', pin: '1111');
    final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '301 Lake Dr'});
    pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'install');
  });

  test('save, log and week query', () {
    final start = DateTime(2030, 3, 12, 8);
    final id = saveAppointment(db, projectId: pid, kind: 'install', start: start, durationMin: 480, assignedTo: sam);
    expect(db.get('appointments', id)!.s('starts_at'), '2030-03-12T08:00');
    expect(db.select("SELECT body FROM notes WHERE body LIKE 'Installation booked%'").single.s('body'), contains('Sam Installer'));
    final week = appointmentsBetween(db, DateTime(2030, 3, 11), DateTime(2030, 3, 18));
    expect(week.single.s('customer'), 'Jane Smith');
    expect(week.single.s('user_name'), 'Sam Installer');
    expect(appointmentsBetween(db, DateTime(2030, 3, 18), DateTime(2030, 3, 25)), isEmpty);
    cancelAppointment(db, id);
    expect(appointmentsBetween(db, DateTime(2030, 3, 11), DateTime(2030, 3, 18)), isEmpty);
    expect(appointmentsBetween(db, DateTime(2030, 3, 11), DateTime(2030, 3, 18), includeCancelled: true), hasLength(1));
  });

  test('conflicts for the same person only', () {
    saveAppointment(db, projectId: pid, kind: 'measure', start: DateTime(2030, 3, 12, 9), assignedTo: sam);
    expect(conflicts(db, assignedTo: sam, start: DateTime(2030, 3, 12, 9, 30), durationMin: 60), hasLength(1));
    expect(conflicts(db, assignedTo: sam, start: DateTime(2030, 3, 12, 10), durationMin: 60), isEmpty);
    expect(conflicts(db, assignedTo: null, start: DateTime(2030, 3, 12, 9), durationMin: 60), isEmpty);
  });

  test('install done marks a received job installed', () {
    setStatus(db, pid, 'received');
    expect(scheduleNextActions(db).any((a) => a.kind == 'book' && a.text.startsWith('Book installation')), isTrue);
    final id = saveAppointment(db, projectId: pid, kind: 'install', start: DateTime.now().add(const Duration(days: 3)));
    expect(scheduleNextActions(db).any((a) => a.kind == 'book'), isFalse);
    markAppointmentDone(db, id);
    expect(db.get('projects', pid)!.s('status'), 'completed');
  });

  test('confirm and mark-done reminders; measure booked', () {
    final soon = DateTime.now().add(const Duration(hours: 20));
    saveAppointment(db, projectId: pid, kind: 'measure', start: soon);
    expect(hasUpcomingMeasure(db, pid), isTrue);
    expect(scheduleNextActions(db).any((a) => a.kind == 'confirm'), isTrue);
    saveAppointment(db, projectId: pid, kind: 'service', start: DateTime.now().subtract(const Duration(hours: 6)));
    expect(scheduleNextActions(db).any((a) => a.kind == 'mark done'), isTrue);
  });

  test('confirmation text', () {
    final id = saveAppointment(db, projectId: pid, kind: 'install', start: DateTime(2030, 3, 12, 8));
    final t = confirmationText(db, id);
    expect(t, startsWith('Hi Jane, this confirms your kitchen installation on Tuesday Mar 12 at 8:00 AM at 301 Lake Dr.'));
    expect(t, contains('Maple & Oak Cabinetry 555-0100'));
  });
}
