import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'logic.dart';

/// Stores attachment bytes on this device.
///
/// HUB (Windows): human-readable folders you can open in Explorer / 2020:
///   `<root>/Projects/J-2026-001_Smith/designs/smith_v2.kit`
/// PHONE: content-addressed blobs (`<root>/blobs/<sha256>.<ext>`), downloaded on demand.
class FileStore {
  FileStore(this.db, this.root);
  final AppDb db;
  final String root;

  static String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

  String? localPath(String sha) {
    final r = db.raw.select('SELECT path FROM blobs WHERE sha256=?', [sha]);
    if (r.isEmpty) return null;
    final path = r.first['path'] as String;
    return File(path).existsSync() ? path : null;
  }

  bool hasBlob(String sha) => localPath(sha) != null;

  String projectFolder(String projectId) {
    final pr = projectWithCustomer(db, projectId);
    final num = pr?.ns('number') ?? projectId.substring(0, 8);
    return p.join(root, 'Projects', '${num}_${slug(pr?.s('customer') ?? '')}');
  }

  String _targetPath(String projectId, String category, String name, String sha) {
    if (!db.isHub) {
      final ext = p.extension(name);
      return p.join(root, 'blobs', '$sha$ext');
    }
    final dir = p.join(projectFolder(projectId), category);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var target = p.join(dir, safe);
    var n = 1;
    while (File(target).existsSync()) {
      n++;
      target = p.join(dir, '${p.basenameWithoutExtension(safe)}_$n${p.extension(safe)}');
    }
    return target;
  }

  void _writeBlob(String sha, Uint8List bytes, String target, {required bool uploaded}) {
    File(target).parent.createSync(recursive: true);
    File(target).writeAsBytesSync(bytes, flush: true);
    db.raw.execute('INSERT OR REPLACE INTO blobs(sha256, path, uploaded) VALUES (?,?,?)',
        [sha, target, uploaded ? 1 : 0]);
  }

  /// Attach a file from disk / camera to a project (optionally to a measurement, design, quote, invoice).
  String addFile({
    required String projectId,
    required String sourcePath,
    String? name,
    required String category,
    String? entityType,
    String? entityId,
  }) {
    final bytes = File(sourcePath).readAsBytesSync();
    return addBytes(
        projectId: projectId, bytes: bytes, name: name ?? p.basename(sourcePath), category: category,
        entityType: entityType, entityId: entityId);
  }

  String addBytes({
    required String projectId,
    required Uint8List bytes,
    required String name,
    required String category,
    String? entityType,
    String? entityId,
  }) {
    final sha = sha256Of(bytes);
    // PC: every job folder gets its own copy so the folders stay complete.
    if (db.isHub || !hasBlob(sha)) {
      _writeBlob(sha, bytes, _targetPath(projectId, category, name, sha), uploaded: db.isHub);
    }
    return db.tx(() {
      final id = db.insert('files', {
        'project_id': projectId, 'entity_type': entityType, 'entity_id': entityId, 'category': category,
        'name': name, 'size': bytes.length, 'sha256': sha, 'mime': _mime(name),
      });
      log(db, projectId, 'File added to $category: $name');
      return id;
    });
  }

  /// Bytes received over sync (hub: upload from phone; phone: download from hub).
  void storeIncoming(String sha, Uint8List bytes) {
    if (sha256Of(bytes) != sha) throw const FormatException('File checksum mismatch');
    if (hasBlob(sha)) return;
    final f = db.one('SELECT * FROM files WHERE sha256=? ORDER BY deleted, created_at LIMIT 1', [sha]);
    final target = f == null
        ? p.join(root, db.isHub ? 'Unfiled' : 'blobs', sha)
        : _targetPath(f.s('project_id'), f.s('category'), f.s('name'), sha);
    _writeBlob(sha, bytes, target, uploaded: true);
  }

  /// Phone: blobs created here that the hub doesn't have yet.
  List<String> pendingUploads() => db.raw
      .select('SELECT sha256 FROM blobs WHERE uploaded=0')
      .map((r) => r['sha256'] as String)
      .toList();

  void markUploaded(String sha) => db.raw.execute('UPDATE blobs SET uploaded=1 WHERE sha256=?', [sha]);

  void deleteFile(String fileId) => db.softDelete('files', fileId);

  List<Rec> filesFor(String entityType, String entityId) => db.select(
      'SELECT * FROM files WHERE entity_type=? AND entity_id=? AND deleted=0 ORDER BY created_at', [entityType, entityId]);

  List<Rec> projectFiles(String projectId, {bool prices = true}) => db.select(
      'SELECT * FROM files WHERE project_id=? AND deleted=0 '
      "${prices ? '' : "AND category NOT IN ('quotes','invoices') "}"
      'ORDER BY category, created_at',
      [projectId]);

  static String _mime(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.heic':
        return 'image/heic';
      case '.pdf':
        return 'application/pdf';
      case '.kit':
        return 'application/x-2020-kitchen';
      default:
        return 'application/octet-stream';
    }
  }

  static bool isImage(String name) =>
      ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic'].contains(p.extension(name).toLowerCase());
}
