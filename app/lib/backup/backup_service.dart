/// Automatic backups of the main office PC: a consistent database snapshot plus a
/// mirror of the job folders, to an external drive / NAS / network folder.
///
/// Layout in the chosen folder:
///   `Cabinet CRM backup/db/cabinet_crm_YYYY-MM-DD_HHMM.db`  (newest N kept)
///   `Cabinet CRM backup/files/Projects/...`                 (mirror, never pruned)
///   `Cabinet CRM backup/files/Email inbox/...`
///   `Cabinet CRM backup/README.txt`
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/db.dart';
import '../core/files.dart';

class BackupService extends ChangeNotifier {
  BackupService(this.db, this.files);

  final AppDb db;
  final FileStore files;
  Timer? _timer;
  Timer? _soon;
  bool running = false;

  static const folderName = 'Cabinet CRM backup';
  static const mirrored = ['Projects', 'Email inbox'];

  // ------------------------------------------------------------------ settings

  bool get enabled => db.meta('backup_enabled') == '1';
  String? get dir {
    final d = db.meta('backup_dir');
    return (d == null || d.trim().isEmpty) ? null : d;
  }

  int get keep => int.tryParse(db.meta('backup_keep') ?? '') ?? 14;
  DateTime? get last => DateTime.tryParse(db.meta('backup_last') ?? '');
  String? get lastError => db.meta('backup_last_error');
  String? get lastSummary => db.meta('backup_last_summary');

  /// Not set up, or no successful backup in 3 days.
  bool get overdue {
    if (!enabled || dir == null) return true;
    final l = last;
    return l == null || DateTime.now().difference(l) > const Duration(days: 3);
  }

  void configure({required bool enabled, String? dir, int? keep}) {
    db.setMeta('backup_enabled', enabled ? '1' : '0');
    if (dir != null) db.setMeta('backup_dir', dir);
    if (keep != null) db.setMeta('backup_keep', '${keep.clamp(1, 365)}');
    start();
    notifyListeners();
  }

  String? get _root => dir == null ? null : p.join(dir!, folderName);

  // ------------------------------------------------------------------ schedule

  bool get _due {
    if (!enabled || dir == null) return false;
    final l = last;
    return l == null || DateTime.now().difference(l) > const Duration(hours: 24);
  }

  void start() {
    stop();
    if (!enabled) return;
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => _auto());
    if (_due) _soon = Timer(const Duration(minutes: 2), _auto);
  }

  void stop() {
    _timer?.cancel();
    _soon?.cancel();
    _timer = null;
    _soon = null;
  }

  Future<void> _auto() async {
    if (_due && !running) {
      try {
        await runBackup();
      } catch (_) {/* recorded in backup_last_error */}
    }
  }

  // ------------------------------------------------------------------ backup

  Future<String> runBackup() async {
    final root = _root;
    if (root == null) throw StateError('Choose a backup folder first.');
    if (running) return 'A backup is already running.';
    running = true;
    notifyListeners();
    try {
      final dbDir = Directory(p.join(root, 'db'));
      await dbDir.create(recursive: true);
      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${n.year}-${two(n.month)}-${two(n.day)}_${two(n.hour)}${two(n.minute)}';
      var target = p.join(dbDir.path, 'cabinet_crm_$stamp.db');
      if (await File(target).exists()) await File(target).delete(); // same minute: replace
      // Consistent snapshot even while the app (and sync) keep running.
      db.raw.execute("VACUUM INTO '${target.replaceAll("'", "''")}'");

      var copied = 0;
      for (final name in mirrored) {
        copied += await _mirror(Directory(p.join(files.root, name)), Directory(p.join(root, 'files', name)));
      }

      // Rotation: keep the newest N snapshots.
      final snaps = snapshots();
      for (final old in snaps.skip(keep)) {
        try {
          await old.delete();
        } catch (_) {}
      }
      await File(p.join(root, 'README.txt')).writeAsString(_readme);

      final summary = 'Backed up: database + $copied new or changed file${copied == 1 ? '' : 's'}';
      db.setMeta('backup_last', DateTime.now().toIso8601String());
      db.setMeta('backup_last_summary', summary);
      db.raw.execute("DELETE FROM meta WHERE key='backup_last_error'");
      return summary;
    } catch (e) {
      db.setMeta('backup_last_error', '${DateTime.now().toIso8601String().substring(0, 16)}: $e');
      rethrow;
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Copy files that are new or changed (size or modified time). Never deletes.
  static Future<int> _mirror(Directory src, Directory dst) async {
    if (!await src.exists()) return 0;
    var n = 0;
    await for (final e in src.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: src.path);
      final out = File(p.join(dst.path, rel));
      final s = await e.stat();
      if (await out.exists()) {
        final o = await out.stat();
        if (o.size == s.size && !s.modified.isAfter(o.modified)) continue;
      }
      await out.parent.create(recursive: true);
      await e.copy(out.path);
      try {
        await out.setLastModified(s.modified);
      } catch (_) {}
      n++;
    }
    return n;
  }

  /// Database snapshots, newest first.
  List<File> snapshots() {
    final root = _root;
    if (root == null) return [];
    final d = Directory(p.join(root, 'db'));
    if (!d.existsSync()) return [];
    final list = d
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('cabinet_crm_') && f.path.endsWith('.db'))
        .toList()
      ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return list;
  }

  // ------------------------------------------------------------------ restore

  static String _pendingPath(String dataRoot) => p.join(dataRoot, 'data', 'restore_pending.db');

  /// Check the snapshot and stage it; it replaces the database at the next start.
  Future<void> scheduleRestore(String snapshotPath) async {
    if (!await File(snapshotPath).exists()) throw StateError('Backup file not found.');
    try {
      final check = sqlite3.open(snapshotPath, mode: OpenMode.readOnly);
      try {
        final t = check.select("SELECT name FROM sqlite_master WHERE type='table' AND name='projects'");
        if (t.isEmpty) throw StateError('not a Cabinet CRM database');
      } finally {
        check.close();
      }
    } catch (e) {
      throw StateError("That file isn't a Cabinet CRM backup ($e).");
    }
    final pending = File(_pendingPath(files.root));
    await pending.parent.create(recursive: true);
    await File(snapshotPath).copy(pending.path);
  }

  bool get restorePending => File(_pendingPath(files.root)).existsSync();

  /// Call at start-up, before the database is opened. Keeps the current database as a
  /// "before-restore" copy next to it.
  static void applyPendingRestore(String dataRoot) {
    final pending = File(_pendingPath(dataRoot));
    if (!pending.existsSync()) return;
    final dataDir = p.join(dataRoot, 'data');
    final current = File(p.join(dataDir, 'cabinet_crm.db'));
    final ts = DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('.', '').substring(0, 15);
    if (current.existsSync()) {
      current.renameSync(p.join(dataDir, 'cabinet_crm.before-restore-$ts.db'));
    }
    for (final suffix in ['-wal', '-shm']) {
      final f = File('${current.path}$suffix');
      if (f.existsSync()) f.renameSync(p.join(dataDir, 'cabinet_crm.before-restore-$ts.db$suffix'));
    }
    pending.renameSync(current.path);
    // Keep the change counter above anything devices have seen and mark a new "generation"
    // so they re-fetch everything instead of silently drifting.
    try {
      String? meta(Database d, String k) =>
          d.select('SELECT value FROM meta WHERE key=?', [k]).firstOrNull?['value'] as String?;
      final old = sqlite3.open(p.join(dataDir, 'cabinet_crm.before-restore-$ts.db'), mode: OpenMode.readOnly);
      final oldSeq = int.tryParse(meta(old, 'seq') ?? '') ?? 0;
      final oldGen = int.tryParse(meta(old, 'hub_generation') ?? '') ?? 0;
      old.close();
      final now = sqlite3.open(current.path);
      final snapSeq = int.tryParse(meta(now, 'seq') ?? '') ?? 0;
      final snapGen = int.tryParse(meta(now, 'hub_generation') ?? '') ?? 0;
      final maxGen = oldGen > snapGen ? oldGen : snapGen;
      now.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('seq', ?)", ['${(oldSeq > snapSeq ? oldSeq : snapSeq) + 1000}']);
      now.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('hub_generation', ?)", ['${maxGen + 1}']);
      now.close();
    } catch (_) {
      // Best effort: the restore itself has already happened.
    }
  }

  /// Copy job files from the backup mirror back where they are missing. Returns the count.
  Future<int> restoreMissingFiles() async {
    final root = _root;
    if (root == null) return 0;
    var n = 0;
    for (final name in mirrored) {
      final src = Directory(p.join(root, 'files', name));
      if (!await src.exists()) continue;
      await for (final e in src.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final out = File(p.join(files.root, name, p.relative(e.path, from: src.path)));
        if (await out.exists()) continue;
        await out.parent.create(recursive: true);
        await e.copy(out.path);
        n++;
      }
    }
    return n;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  static const _readme = '''Cabinet CRM backup
==================

db\\     Database snapshots (customers, jobs, measurements, quotes, notes...). One per day, newest kept.
files\\  Copy of the job folders (Projects) and the Email inbox attachments.

To restore on the main office PC:
1. Cabinet CRM > Settings > Backups > choose a snapshot > "Restore this".
2. Close and reopen Cabinet CRM. The current database is kept as cabinet_crm.before-restore-....db.
3. If job files are missing, use "Restore missing files from backup".

Moving to a new PC: install Cabinet CRM, choose "Main office PC", point Backups at this folder,
restore the newest snapshot and then "Restore missing files from backup".
''';
}
