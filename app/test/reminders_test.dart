import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/reminders.dart';
import 'package:cabinet_crm/core/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String pid, ian, owner;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    owner = createUser(db, name: 'Owner', role: 'owner', pin: '1111');
    ian = createUser(db, name: 'Ian', role: 'field', pin: '2222');
    db.currentUserId = owner;
    final cid = saveCustomer(db, {'name': "Tom O'Neil", 'address': '301 Lake Dr'});
    pid = createProject(db, customerId: cid, title: 'Kitchen');
  });

  test('evening before and an hour before, only for the assigned person', () {
    final now = DateTime(2026, 11, 9, 10, 0);
    saveAppointment(db, projectId: pid, kind: 'install', start: DateTime(2026, 11, 10, 9, 0), assignedTo: ian);
    saveAppointment(db, projectId: pid, kind: 'measure', start: DateTime(2026, 11, 10, 14, 0), assignedTo: owner);
    final r = appointmentReminders(db, userId: ian, now: now);
    expect(r.map((x) => x.at), [DateTime(2026, 11, 9, 17), DateTime(2026, 11, 10, 8)]);
    expect(r.first.title, 'Tomorrow 9:00 AM: Installation');
    expect(r.first.body, "Tom O'Neil, 301 Lake Dr · not confirmed with the customer yet");
    expect(r.last.title, '9:00 AM: Installation');
    expect(appointmentReminders(db, userId: owner, now: now).length, 2);
  });

  test('past, cancelled and done appointments get nothing; late bookings still get the hour-before one', () {
    final now = DateTime(2026, 11, 9, 18, 0); // after 5 PM
    final a = saveAppointment(db, projectId: pid, kind: 'install', start: DateTime(2026, 11, 10, 9), assignedTo: ian);
    final r = appointmentReminders(db, userId: ian, now: now);
    expect(r.single.at, DateTime(2026, 11, 10, 8));
    saveAppointment(db, projectId: pid, kind: 'delivery', start: DateTime(2026, 11, 9, 8), assignedTo: ian);
    cancelAppointment(db, a);
    expect(appointmentReminders(db, userId: ian, now: now), isEmpty);
  });

  test('ids are stable and change when the appointment moves', () {
    final now = DateTime(2026, 11, 9, 10);
    final a = saveAppointment(db, projectId: pid, kind: 'install', start: DateTime(2026, 11, 12, 9), assignedTo: ian);
    final first = appointmentReminders(db, userId: ian, now: now).map((r) => r.id).toList();
    expect(appointmentReminders(db, userId: ian, now: now).map((r) => r.id), first);
    saveAppointment(db, id: a, projectId: pid, kind: 'install', start: DateTime(2026, 11, 13, 9), assignedTo: ian);
    final moved = appointmentReminders(db, userId: ian, now: now).map((r) => r.id).toList();
    expect(moved.toSet().intersection(first.toSet()), isEmpty);
    expect(first.every((id) => id >= 0 && id <= 0x7fffffff), isTrue);
  });

  test('morning summary: counts today, unassigned and next actions; nothing to say gives null', () {
    final quiet = AppDb.memory(isHub: true);
    seedSettings(quiet);
    final u = createUser(quiet, name: 'O', role: 'owner', pin: '1111');
    expect(morningSummary(quiet, userId: u, prices: true, now: DateTime(2026, 11, 9, 7, 30)), isNull);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    saveAppointment(db, projectId: pid, kind: 'install', start: today.add(const Duration(hours: 13)), assignedTo: owner);
    saveAppointment(db, projectId: pid, kind: 'measure', start: today.add(const Duration(days: 2, hours: 10)));
    final m = morningSummary(db, userId: owner, prices: true, now: today.add(const Duration(hours: 7, minutes: 30)))!;
    expect(m.body, contains('1 appointment today (1 yours)'));
    expect(m.body, contains('1 this week with nobody assigned'));
  });

  test('next morning is today before 7:30, tomorrow after', () {
    expect(nextMorning(DateTime(2026, 11, 9, 6)), DateTime(2026, 11, 9, 7, 30));
    expect(nextMorning(DateTime(2026, 11, 9, 8)), DateTime(2026, 11, 10, 7, 30));
  });
}
