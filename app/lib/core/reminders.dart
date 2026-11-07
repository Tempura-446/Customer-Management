/// What to remind people about, and when. Pure rules: the notification service
/// (lib/notify/) turns these into phone / Windows notifications.
///
/// - The evening before (5 PM) and an hour before each appointment assigned to the
///   signed-in person: "Tomorrow 9:00 AM: Installation · Tom O'Neil, 301 Lake Dr".
/// - Office computers: a morning summary (7:30 AM) of today's appointments, unassigned
///   appointments, next actions and emails waiting to be filed.
library;

import 'package:intl/intl.dart';

import 'db.dart';
import 'logic.dart';
import 'schedule.dart';

class Reminder {
  Reminder(this.id, this.at, this.title, this.body, {this.projectId});

  /// Stable id: the same appointment and kind of reminder always gets the same id,
  /// so re-scheduling replaces it instead of adding a duplicate.
  final int id;
  final DateTime at;
  final String title, body;
  final String? projectId;
  @override
  String toString() => '$at $title: $body';
}

const eveningHour = 17; // the day before, 5 PM
const leadMinutes = 60; // an hour before
const morningHour = 7, morningMinute = 30;

/// FNV-1a, folded to a positive 31-bit int (notification ids are 32-bit signed).
int stableId(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

String _where(Rec a) => [a.s('customer'), if (a.ns('site_address') != null) a.s('site_address')].join(', ');

/// Appointment reminders for [userId] from [now] over the next [days] days, soonest first.
List<Reminder> appointmentReminders(AppDb db, {required String userId, required DateTime now, int days = 14}) {
  final out = <Reminder>[];
  final time = DateFormat('h:mm a');
  for (final a in appointmentsBetween(db, now, now.add(Duration(days: days)), userId: userId)) {
    if (a.s('status') != 'scheduled') continue;
    final start = parseStart(a.s('starts_at'));
    if (start == null || !start.isAfter(now)) continue;
    final kind = kindOf(a.s('kind')).label;
    final dayBefore = DateTime(start.year, start.month, start.day - 1, eveningHour);
    // Only if the appointment is the next day (an appointment booked at 6 PM for 8 AM
    // tomorrow still gets its one-hour reminder).
    if (dayBefore.isAfter(now)) {
      out.add(Reminder(stableId('${a.id}:eve:${a.s('starts_at')}'), dayBefore, 'Tomorrow ${time.format(start)}: $kind',
          '${_where(a)}${a.b('confirmed') ? '' : ' · not confirmed with the customer yet'}',
          projectId: a.s('project_id')));
    }
    final soon = start.subtract(const Duration(minutes: leadMinutes));
    if (soon.isAfter(now)) {
      out.add(Reminder(stableId('${a.id}:soon:${a.s('starts_at')}'), soon, '${time.format(start)}: $kind', _where(a),
          projectId: a.s('project_id')));
    }
  }
  out.sort((x, y) => x.at.compareTo(y.at));
  return out;
}

/// Next time the morning summary is due (today 7:30 if still ahead, else tomorrow).
DateTime nextMorning(DateTime now) {
  final today = DateTime(now.year, now.month, now.day, morningHour, morningMinute);
  return today.isAfter(now) ? today : DateTime(now.year, now.month, now.day + 1, morningHour, morningMinute);
}

/// The morning summary for an office user, worked out when it is shown. Null when there is nothing to say.
Reminder? morningSummary(AppDb db, {required String userId, required bool prices, required DateTime now}) {
  final start = DateTime(now.year, now.month, now.day);
  final today = appointmentsBetween(db, start, start.add(const Duration(days: 1)))
      .where((a) => a.s('status') == 'scheduled')
      .toList();
  final mine = today.where((a) => a.ns('assigned_to') == userId).length;
  final unassigned = appointmentsBetween(db, start, start.add(const Duration(days: 7)))
      .where((a) => a.s('status') == 'scheduled' && a.ns('assigned_to') == null)
      .length;
  final actions = nextActions(db, prices: prices).length;
  final mail = db.isHub
      ? (db.raw.select("SELECT COUNT(*) c FROM mail_inbox WHERE deleted=0 AND status='unmatched'").first['c'] as int)
      : 0;
  final parts = <String>[
    if (today.isNotEmpty) '${today.length} appointment${today.length == 1 ? '' : 's'} today${mine > 0 ? ' ($mine yours)' : ''}',
    if (unassigned > 0) '$unassigned this week with nobody assigned',
    if (actions > 0) '$actions next action${actions == 1 ? '' : 's'}',
    if (mail > 0) '$mail measurement email${mail == 1 ? '' : 's'} to file',
  ];
  if (parts.isEmpty) return null;
  final d = '${now.year}-${now.month}-${now.day}';
  return Reminder(stableId('morning:$userId:$d'), now, 'Good morning', '${parts.join(' · ')}.');
}
