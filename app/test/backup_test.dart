import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/backup/backup_service.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tmp;
  late String root, backupDir;
  late AppDb db;
  late FileStore files;
  late BackupService b;
  late String pid;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('backup');
    root = p.join(tmp.path, 'data root');
    backupDir = p.join(tmp.path, "Bob's USB"); // quote in path: must be escaped for VACUUM INTO
    db = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: true);
    seedSettings(db);
    files = FileStore(db, root);
    final cid = saveCustomer(db, {'name': 'Jane Smith'});
    pid = createProject(db, customerId: cid, title: 'Kitchen');
    files.addBytes(projectId: pid, bytes: Uint8List.fromList([1, 2, 3]), name: 'plan.pdf', category: 'designs');
    b = BackupService(db, files)..configure(enabled: true, dir: backupDir, keep: 3);
    b.stop();
  });

  tearDown(() async {
    b.dispose();
    try {
      db.dispose();
    } catch (_) {}
    await tmp.delete(recursive: true);
  });

  test('backup: openable snapshot, mirrored files, only new files the second time', () async {
    final s1 = await b.runBackup();
    expect(s1, contains('database + 1 new'));
    expect(b.lastError, isNull);
    expect(b.last, isNotNull);
    expect(b.overdue, isFalse);
    final snap = b.snapshots().single;
    final copy = sqlite3.open(snap.path, mode: OpenMode.readOnly);
    expect(copy.select("SELECT title FROM projects").single['title'], 'Kitchen');
    copy.close();
    final mirrored = Directory(p.join(backupDir, BackupService.folderName, 'files', 'Projects'))
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.basename(f.path));
    expect(mirrored, contains('plan.pdf'));
    expect(File(p.join(backupDir, BackupService.folderName, 'README.txt')).existsSync(), isTrue);

    files.addBytes(projectId: pid, bytes: Uint8List.fromList([9]), name: 'photo.jpg', category: 'photos');
    final s2 = await b.runBackup();
    expect(s2, contains('database + 1 new'), reason: 'plan.pdf unchanged, only photo.jpg copied');
  });

  test('rotation keeps the newest N snapshots', () async {
    final dbDir = Directory(p.join(backupDir, BackupService.folderName, 'db'))..createSync(recursive: true);
    for (final d in ['2026-01-01_0900', '2026-01-02_0900', '2026-01-03_0900', '2026-01-04_0900']) {
      File(p.join(dbDir.path, 'cabinet_crm_$d.db')).writeAsStringSync('old');
    }
    await b.runBackup();
    final names = b.snapshots().map((f) => p.basename(f.path)).toList();
    expect(names, hasLength(3));
    expect(names.last, 'cabinet_crm_2026-01-03_0900.db');
    expect(names, isNot(contains('cabinet_crm_2026-01-01_0900.db')));
  });

  test('restore: validates, swaps at next start, keeps a before-restore copy', () async {
    await b.runBackup();
    final snap = b.snapshots().first.path;
    // Change data after the backup.
    saveCustomer(db, {'name': 'Added after backup'});
    final bogus = File(p.join(tmp.path, 'not-a-db.db'))..writeAsStringSync('hello');
    expect(() => b.scheduleRestore(bogus.path), throwsA(isA<StateError>()));

    await b.scheduleRestore(snap);
    expect(b.restorePending, isTrue);
    db.dispose(); // app closes
    BackupService.applyPendingRestore(root);

    final dataDir = Directory(p.join(root, 'data'));
    expect(dataDir.listSync().map((e) => p.basename(e.path)).any((n) => n.startsWith('cabinet_crm.before-restore-')),
        isTrue);
    db = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: true);
    expect(db.select("SELECT * FROM customers WHERE name='Added after backup'"), isEmpty);
    expect(db.select("SELECT * FROM customers WHERE name='Jane Smith'"), hasLength(1));
    expect(File(p.join(root, 'data', 'restore_pending.db')).existsSync(), isFalse);
  });

  test('restore missing files from the mirror', () async {
    await b.runBackup();
    final f = db.one('SELECT * FROM files')!;
    final path = files.localPath(f.s('sha256'))!;
    File(path).deleteSync();
    expect(await b.restoreMissingFiles(), 1);
    expect(File(path).readAsBytesSync(), [1, 2, 3]);
    expect(await b.restoreMissingFiles(), 0);
  });

  test('not configured counts as overdue', () {
    final other = BackupService(AppDb.memory(isHub: true), files);
    expect(other.overdue, isTrue);
    expect(other.snapshots(), isEmpty);
  });

  test('verify: a good backup passes and is recorded', () async {
    await b.runBackup();
    final r = await b.verifyLatest();
    expect(r, contains('1 job, 1 customer, all job files present'));
    expect(b.lastVerified, isNotNull);
    expect(b.verifyError, isNull);
  });

  test('verify: a damaged copy is caught and reported', () async {
    await b.runBackup();
    final snap = b.snapshots().first;
    final bytes = snap.readAsBytesSync();
    // Overwrite the middle of the file: header intact, pages garbage.
    for (var i = 4096; i < bytes.length && i < 4096 * 3; i++) {
      bytes[i] = 0x5A;
    }
    snap.writeAsBytesSync(bytes);
    await expectLater(b.verifyLatest(), throwsA(isA<StateError>()));
    expect(b.verifyError, isNotNull);
    expect(b.lastVerified, isNull);
  });

  test('verify: a job file missing from the backup folder is caught', () async {
    await b.runBackup();
    final mirrored = Directory(p.join(backupDir, BackupService.folderName, 'files', 'Projects'))
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) => p.basename(f.path) == 'plan.pdf');
    mirrored.deleteSync();
    await expectLater(
        b.verifyLatest(), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('plan.pdf'))));
    // The next backup copies it again and a new check clears the warning.
    await b.runBackup();
    await b.verifyLatest();
    expect(b.verifyError, isNull);
  });
}
