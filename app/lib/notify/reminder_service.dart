/// Shows the reminders from core/reminders.dart as system notifications.
///
/// Phones: appointment reminders are scheduled ahead with the operating system, so
/// they arrive even when the app is closed. Re-scheduled after every sync or change.
/// Computers (main office PC and workstations): checked every minute while the app
/// is open, plus the morning summary. The app usually runs all day on these.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/reminders.dart';
import '../services.dart';

class ReminderService {
  ReminderService(this.svc);
  final Services svc;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _starting = false;
  Timer? _tick, _debounce;
  List<Reminder> _queue = const [];

  /// Per device: the person using this phone or computer can turn reminders off.
  bool get enabled => svc.db.meta('reminders_off') != '1';

  Future<void> setEnabled(bool on) async {
    svc.db.setMeta('reminders_off', on ? '0' : '1');
    if (on) await _ensureReady(askPermission: true);
    await refresh();
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails('appointments', 'Appointments',
        channelDescription: 'Reminders for site measures, deliveries, pickups and installations',
        importance: Importance.high,
        priority: Priority.high),
    iOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  void start() {
    svc.addListener(_changed);
    svc.db.addListener(_changed);
    if (Services.desktop) _tick = Timer.periodic(const Duration(minutes: 1), (_) => _checkDue());
    _changed();
  }

  void dispose() {
    svc.removeListener(_changed);
    svc.db.removeListener(_changed);
    _tick?.cancel();
    _debounce?.cancel();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), refresh);
  }

  Future<bool> _ensureReady({bool askPermission = false}) async {
    if (_ready) return true;
    if (_starting) return false;
    // Linux (development only): the notification plugin needs a desktop session bus and
    // fails outside our error handling without one.
    if (Platform.isLinux && (Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? '').isEmpty) return false;
    _starting = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Open Casework'),
          windows: WindowsInitializationSettings(
              appName: 'Casework', appUserModelId: 'Casework.Casework', guid: 'b6c1f0a4-3d2e-4f5a-9b8c-7e6d5c4b3a21'),
        ),
      );
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _ready = true;
    } catch (e) {
      // No notification service on this computer (e.g. a Linux box without a desktop):
      // reminders just stay off. Everything else works as before.
      debugPrint('Reminders unavailable: $e');
    } finally {
      _starting = false;
    }
    return _ready;
  }

  /// Work out the reminders again (after a sync, an edit, or signing in / out).
  Future<void> refresh() async {
    final user = svc.user;
    if (user == null || !enabled) {
      _queue = const [];
      if (_ready && !Services.desktop) await _safe(_plugin.cancelAll);
      return;
    }
    if (!await _ensureReady()) return;
    final now = DateTime.now();
    _queue = appointmentReminders(svc.db, userId: user.id, now: now.subtract(const Duration(minutes: 15)));
    if (Services.desktop) {
      _checkDue();
      return;
    }
    // Phones: hand the next ones to the operating system (iOS keeps at most 64).
    await _safe(_plugin.cancelAll);
    for (final r in _queue.where((r) => r.at.isAfter(now)).take(40)) {
      await _safe(() => _plugin.zonedSchedule(
            id: r.id,
            title: r.title,
            body: r.body,
            scheduledDate: tz.TZDateTime.from(r.at, tz.UTC),
            notificationDetails: _details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            payload: r.projectId,
          ));
    }
  }

  // ------------------------------------------------------------------ computers

  Map<String, String> _shown() {
    try {
      return Map<String, String>.from(jsonDecode(svc.db.meta('reminders_shown') ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  void _markShown(Map<String, String> shown, int id, DateTime now) {
    shown['$id'] = now.toIso8601String();
    final cutoff = now.subtract(const Duration(days: 3));
    shown.removeWhere((_, v) => (DateTime.tryParse(v) ?? now).isBefore(cutoff));
    svc.db.setMeta('reminders_shown', jsonEncode(shown));
  }

  Future<void> _checkDue() async {
    final user = svc.user;
    if (!_ready || user == null || !enabled) return;
    final now = DateTime.now();
    final shown = _shown();
    for (final r in _queue) {
      if (r.at.isAfter(now)) break;
      // Missed by more than 15 minutes (PC was off): too late to be useful.
      if (now.difference(r.at) > const Duration(minutes: 15) || shown.containsKey('${r.id}')) continue;
      await _show(r);
      _markShown(shown, r.id, now);
    }
    // Morning summary: from 7:30 until 11, once a day, the first time the app is open.
    final morning = DateTime(now.year, now.month, now.day, morningHour, morningMinute);
    final today = '${now.year}-${now.month}-${now.day}';
    if (now.isAfter(morning) && now.hour < 11 && svc.db.meta('morning_shown:${user.id}') != today) {
      svc.db.setMeta('morning_shown:${user.id}', today);
      final m = morningSummary(svc.db, userId: user.id, prices: svc.prices, now: now);
      if (m != null) await _show(m);
    }
  }

  Future<void> _show(Reminder r) =>
      _safe(() => _plugin.show(id: r.id, title: r.title, body: r.body, notificationDetails: _details, payload: r.projectId));

  Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('Reminder failed: $e');
    }
  }
}
