import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/db.dart';
import '../core/files.dart';
import 'imap_fetcher.dart';
import 'mail_ingest.dart';

/// Where the mailbox password is kept: Windows Credential Manager (DPAPI) via
/// flutter_secure_storage, never in the database (which is backed up and synced).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null; // no keyring available: behave as "not saved yet"
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (e) {
      throw Exception("Couldn't save the password in this computer's secure storage: $e");
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }
}

class MemorySecretStore implements SecretStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

typedef Fetcher = Future<FetchResult> Function(MailConfig c, {int? afterUid, int? uidValidity, int sinceDays});

/// Main office PC: checks the measurement mailbox every few minutes and files new emails.
/// Settings live in the local `meta` table of the main PC only.
class MailPoller extends ChangeNotifier {
  MailPoller(this.db, this.files, {SecretStore? secrets, Fetcher? fetcher})
      : secrets = secrets ?? DeviceSecretStore(),
        _fetch = fetcher ?? fetchNewMail;

  final AppDb db;
  final FileStore files;
  final SecretStore secrets;
  final Fetcher _fetch;
  Timer? _timer;
  bool checking = false;

  static const _pwKey = 'cabinet_crm_mail_password';

  bool get enabled => db.meta('mail_enabled') == '1';
  String get host => db.meta('mail_host') ?? 'imap.gmail.com';
  int get port => int.tryParse(db.meta('mail_port') ?? '') ?? 993;
  String get user => db.meta('mail_user') ?? '';
  String get folder => db.meta('mail_folder') ?? 'INBOX';
  int get pollMinutes => int.tryParse(db.meta('mail_poll_minutes') ?? '') ?? 5;
  int get sinceDays => int.tryParse(db.meta('mail_since_days') ?? '') ?? 14;
  String? get lastCheck => db.meta('mail_last_check');
  String? get lastError => db.meta('mail_last_error');
  String? get lastSummary => db.meta('mail_last_summary');

  Future<MailConfig?> config() async {
    final pw = await secrets.read(_pwKey);
    if (user.isEmpty || pw == null || pw.isEmpty) return null;
    return MailConfig(host: host, port: port, user: user, password: pw, folder: folder);
  }

  Future<void> save({
    required bool enabled,
    required String host,
    required int port,
    required String user,
    String? password,
    required String folder,
    required int pollMinutes,
    required int sinceDays,
  }) async {
    final changedBox = host != this.host || user != this.user || folder != this.folder;
    db.setMeta('mail_enabled', enabled ? '1' : '0');
    db.setMeta('mail_host', host.trim());
    db.setMeta('mail_port', '$port');
    db.setMeta('mail_user', user.trim());
    db.setMeta('mail_folder', folder.trim().isEmpty ? 'INBOX' : folder.trim());
    db.setMeta('mail_poll_minutes', '${pollMinutes.clamp(1, 120)}');
    db.setMeta('mail_since_days', '${sinceDays.clamp(1, 365)}');
    if (password != null && password.isNotEmpty) {
      // Gmail shows app passwords in groups of four; other servers may have real spaces.
      await secrets.write(_pwKey, host.trim().toLowerCase() == 'imap.gmail.com' ? password.replaceAll(' ', '') : password);
    }
    if (changedBox) {
      // Different mailbox: start again from "the last N days".
      db.raw.execute("DELETE FROM meta WHERE key IN ('mail_last_uid','mail_uidvalidity')");
    }
    start();
    notifyListeners();
  }

  Future<bool> hasPassword() async => ((await secrets.read(_pwKey)) ?? '').isNotEmpty;

  void start() {
    _timer?.cancel();
    if (!enabled) return;
    _timer = Timer.periodic(Duration(minutes: pollMinutes), (_) => checkNow());
    Future<void>.delayed(const Duration(seconds: 10), checkNow);
  }

  void stop() => _timer?.cancel();

  /// Fetch and file new emails. Returns a short summary.
  Future<String> checkNow() async {
    if (checking) return 'Already checking…';
    final c = await config();
    if (c == null) return 'Mailbox not set up.';
    checking = true;
    notifyListeners();
    try {
      final r = await _fetch(c,
          afterUid: int.tryParse(db.meta('mail_last_uid') ?? ''),
          uidValidity: int.tryParse(db.meta('mail_uidvalidity') ?? ''),
          sinceDays: sinceDays);
      var filed = 0, waiting = 0;
      for (final m in r.messages) {
        final id = ingestEmail(db, files, m);
        if (id == null) continue;
        db.get('mail_inbox', id)!.s('status') == 'filed' ? filed++ : waiting++;
      }
      if (r.lastUid != null) db.setMeta('mail_last_uid', '${r.lastUid}');
      if (r.uidValidity != null) db.setMeta('mail_uidvalidity', '${r.uidValidity}');
      final summary = (filed + waiting) == 0
          ? 'No new measurement emails.'
          : '$filed filed automatically, $waiting waiting in the Email inbox.';
      db.setMeta('mail_last_check', DateTime.now().toIso8601String());
      db.setMeta('mail_last_summary', summary);
      db.raw.execute("DELETE FROM meta WHERE key='mail_last_error'");
      db.changed();
      return summary;
    } catch (e) {
      db.setMeta('mail_last_check', DateTime.now().toIso8601String());
      db.setMeta('mail_last_error', '$e');
      return 'Checking the mailbox failed: $e';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
