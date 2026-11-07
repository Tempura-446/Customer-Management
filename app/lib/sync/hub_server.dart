import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

import '../core/db.dart';
import '../core/files.dart';
import '../core/logic.dart';
import '../core/schema.dart';
import '../qb/qbwc_server.dart';

const defaultSyncPort = 47820;
const serviceType = '_cabinetcrm._tcp';
const protocolVersion = 1;

String randomToken([int bytes = 32]) =>
    base64Url.encode(List<int>.generate(bytes, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

String hashToken(String t) => sha256.convert(utf8.encode(t)).toString();

/// What a user's devices may see and change.
bool tableAllowed(String table, String role, {required bool write}) {
  if (!syncTables.containsKey(table)) return false;
  if (role == 'field' && pricedTables.contains(table)) return false;
  if (write && table == 'users' && role != 'owner') return false;
  if (write && table == 'settings' && role == 'field') return false;
  return true;
}

/// Row-level filter on top of the table filter (field users: no price info).
bool rowVisible(String table, Map<String, Object?> row, String role) {
  if (role != 'field') return true;
  if (table == 'notes' && row['kind'] == 'money') return false;
  if (table == 'files' && (row['category'] == 'quotes' || row['category'] == 'invoices')) return false;
  return true;
}

Map<String, Object?> outgoing(String table, Map<String, Object?> row) {
  final r = Map<String, Object?>.from(row)..remove('dirty');
  if (table == 'users') r.remove('pin_hash');
  return r;
}

/// The sync service running inside the Windows app.
///
/// Phones on the same Wi-Fi push their changes and pull everything new.
/// Conflict rule: last write wins per record (by updated_at); the losing
/// side receives the winning version.
class HubServer {
  HubServer(this.db, this.files, {this.hubName = 'Office PC'});
  final AppDb db;
  final FileStore files;
  String hubName;
  HttpServer? _server;
  int? port;

  String get hubId => db.meta('hub_id') ?? db.setMeta('hub_id', newId());
  bool get running => _server != null;

  Future<void> start({int port = defaultSyncPort, InternetAddress? address}) async {
    if (_server != null) return;
    final handler = const Pipeline().addMiddleware(_errors()).addHandler(router.call);
    _server = await io.serve(handler, address ?? InternetAddress.anyIPv4, port);
    this.port = _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Middleware _errors() => (inner) => (req) async {
        try {
          return await inner(req);
        } on _Http catch (e) {
          return _json({'error': e.message}, status: e.status);
        } on BusinessError catch (e) {
          return _json({'error': e.message}, status: 400);
        } on FormatException catch (e) {
          return _json({'error': 'Bad request: ${e.message}'}, status: 400);
        } on TypeError {
          return _json({'error': 'Bad request'}, status: 400);
        }
      };

  String get generation => db.meta('hub_generation') ?? '0';

  /// QuickBooks Web Connector endpoint (set on the main PC).
  QbwcService? qbwc;

  Router get router => Router()
    ..all('/qbwc', (Request r) => qbwc?.handler(r) ?? Response.notFound('QuickBooks not set up'))
    ..all('/qbwc/<rest|.*>', (Request r, String rest) => qbwc?.handler(r) ?? Response.notFound('QuickBooks not set up'))
    ..get('/api/hello', _hello)
    ..post('/api/pair', _pair)
    ..post('/api/sync', _sync)
    ..put('/api/blobs/<sha>', _putBlob)
    ..get('/api/blobs/<sha>', _getBlob);

  // ------------------------------------------------------------------ pairing

  /// Owner creates a one-time code for a user (shown as a QR code). Valid 15 minutes.
  /// Codes use letters/digits that can't be confused (no 0/O, 1/I/L) and are shown as ABCD-EFGH.
  String createPairingCode(String userId) {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final code = List.generate(8, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
    db.raw.execute('DELETE FROM pairing_codes WHERE expires_at < ?', [DateTime.now().toUtc().toIso8601String()]);
    db.raw.execute('INSERT INTO pairing_codes(code, user_id, expires_at) VALUES (?,?,?)',
        [code, userId, DateTime.now().toUtc().add(const Duration(minutes: 15)).toIso8601String()]);
    return code;
  }

  /// Payload for the QR code: everything a phone needs to find and join this hub.
  Map<String, Object?> pairingPayload(String code, List<String> hosts) =>
      {'app': 'cabinetcrm', 'v': protocolVersion, 'hub': hubId, 'name': hubName, 'hosts': hosts, 'port': port, 'code': code};

  List<Rec> devices() => db.select('''SELECT d.*, u.name AS user_name, u.role AS role FROM devices d
                                      LEFT JOIN users u ON u.id=d.user_id ORDER BY d.created_at DESC''');

  void revokeDevice(String id) {
    db.raw.execute('UPDATE devices SET revoked=1 WHERE id=?', [id]);
    db.changed();
  }

  Response _hello(Request req) =>
      _json({'app': 'cabinetcrm', 'hub': hubId, 'name': hubName, 'v': protocolVersion, 'generation': generation});

  static String _remote(Request req) =>
      (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? '?';

  static String normalizeCode(String c) => c.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  static String displayCode(String c) => c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;

  final _failedPairs = <String, List<DateTime>>{};

  Future<Response> _pair(Request req) async {
    // Brute-force guard: max 10 wrong codes per 15 minutes from one address.
    final who = _remote(req);
    final cutoff = DateTime.now().subtract(const Duration(minutes: 15));
    final failed = (_failedPairs[who] ??= [])..removeWhere((t) => t.isBefore(cutoff));
    if (failed.length >= 10) throw _Http(429, 'Too many wrong codes. Wait 15 minutes and create a new code.');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final code = normalizeCode('${body['code'] ?? ''}');
    final row = db.raw.select('SELECT * FROM pairing_codes WHERE code=?', [code]).firstOrNull;
    if (row == null || (row['expires_at'] as String).compareTo(DateTime.now().toUtc().toIso8601String()) < 0) {
      failed.add(DateTime.now());
      throw _Http(403, 'Pairing code is invalid or expired. Create a new one on the PC.');
    }
    final user = db.get('users', row['user_id'] as String);
    if (user == null || !user.b('active')) throw _Http(403, 'User is not active.');
    db.raw.execute('DELETE FROM pairing_codes WHERE code=?', [code]);
    final token = randomToken();
    final deviceId = newId();
    db.raw.execute('INSERT INTO devices(id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)',
        [deviceId, user.id, '${body['device_name'] ?? 'Phone'}', hashToken(token), DateTime.now().toUtc().toIso8601String()]);
    db.changed();
    return _json({
      'token': token, 'device_id': deviceId, 'hub': hubId, 'name': hubName,
      'user': outgoing('users', user.m),
    });
  }

  ({Rec device, Rec user}) _auth(Request req) {
    final h = req.headers['authorization'] ?? '';
    if (!h.startsWith('Bearer ')) throw _Http(401, 'Not paired');
    final dev = db.raw
        .select('SELECT * FROM devices WHERE token_hash=? AND revoked=0', [hashToken(h.substring(7))]).firstOrNull;
    if (dev == null) throw _Http(401, 'This device was removed. Pair it again from the PC.');
    final user = db.get('users', dev['user_id'] as String);
    if (user == null || !user.b('active')) throw _Http(401, 'User is not active.');
    return (device: Rec(Map.from(dev)), user: user);
  }

  // ------------------------------------------------------------------ sync

  Future<Response> _sync(Request req) async {
    final a = _auth(req);
    final role = a.user.s('role');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final since = (body['since'] as num?)?.toInt() ?? 0;
    final changes = (body['changes'] as Map<String, dynamic>?) ?? {};
    final result = mergePush(changes, role: role, byUser: a.user.id);
    final out = pullSince(since, role: role);
    // Rejected rows: send back the hub version even if its seq is old (only what this role may see).
    for (final MapEntry(key: t, value: ids) in result.rejected.entries) {
      if (!tableAllowed(t, role, write: false)) continue;
      for (final id in ids) {
        final r = db.raw.select('SELECT * FROM $t WHERE id=?', [id]).firstOrNull;
        if (r == null) continue;
        final m = Map<String, Object?>.from(r);
        if (!rowVisible(t, m, role)) continue;
        (out[t] ??= []).add(outgoing(t, m));
      }
    }
    final pending = ((body['blobs_pending'] as List?) ?? const []).cast<String>();
    final need = pending.where((s) => !files.hasBlob(s)).toList();
    db.raw.execute('UPDATE devices SET last_sync=? WHERE id=?', [DateTime.now().toUtc().toIso8601String(), a.device.id]);
    db.changed();
    return _json({
      'cursor': db.currentSeq,
      'generation': generation,
      'rows': out,
      'need_blobs': need,
      'accepted': result.accepted,
      'accepted_ids': result.acceptedIds,
      'skipped_ids': result.skippedIds,
      'user': outgoing('users', a.user.m),
    });
  }

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Rows a device may push: well-formed, and files rows that can't escape the data folder.
  String? _reject(String table, Map<String, Object?> row) {
    if (row['id'] is! String || (row['id'] as String).isEmpty) return 'no id';
    if (row['updated_at'] is! String) return 'no updated_at';
    if (table == 'files' && (row['deleted'] ?? 0) == 0) {
      if (!fileCategories.contains(row['category'])) return 'bad category';
      if (row['sha256'] is! String || !_hex64.hasMatch(row['sha256'] as String)) return 'bad sha256';
      if (row['name'] is! String || (row['name'] as String).trim().isEmpty) return 'no name';
      if (db.get('projects', row['project_id'] as String?) == null) return 'unknown job';
    }
    return null;
  }

  /// Apply rows pushed by a device. Public so tests (and a future cloud relay) can reuse it.
  ({int accepted, Map<String, List<String>> rejected, Map<String, List<String>> acceptedIds,
      Map<String, List<String>> skippedIds}) mergePush(Map<String, dynamic> changes, {required String role, String? byUser}) {
    var accepted = 0;
    final rejected = <String, List<String>>{};
    final acceptedIds = <String, List<String>>{};
    final skippedIds = <String, List<String>>{};
    final filedFromDevice = <String>[];
    db.tx(() {
      for (final table in syncTables.keys) {
        final rows = (changes[table] as List?) ?? const [];
        if (rows.isEmpty) continue;
        if (!tableAllowed(table, role, write: true)) {
          for (final r in rows) {
            if (r is Map && r['id'] is String) (rejected[table] ??= []).add(r['id'] as String);
          }
          continue;
        }
        for (final raw in rows) {
          if (raw is! Map) continue;
          var row = Map<String, Object?>.from(raw);
          final base = row.remove('_base');
          final why = _reject(table, row);
          if (why != null) {
            if (row['id'] is String) (skippedIds[table] ??= []).add(row['id'] as String);
            continue;
          }
          final id = row['id'] as String;
          if (!rowVisible(table, row, role)) {
            (skippedIds[table] ??= []).add(id);
            continue;
          }
          final existing = db.raw.select('SELECT * FROM $table WHERE id=?', [id]).firstOrNull;
          // Someone else changed this row after the device last synced it: merge field by field
          // instead of letting one whole version win.
          if (existing != null && base is Map && table != 'settings' && base['updated_at'] != existing['updated_at']) {
            final merged = _mergeEdits(table, Map<String, Object?>.from(base), Map<String, Object?>.from(existing), row,
                byUser: byUser ?? row['updated_by'] as String?);
            if (merged == null) {
              (rejected[table] ??= []).add(id); // nothing of the device's left to apply: send it the current version
              continue;
            }
            row = merged;
          } else if (existing != null &&
              (existing['updated_at'] as String).compareTo(row['updated_at'] as String) >= 0) {
            (rejected[table] ??= []).add(id);
            continue;
          }
          // A device running an older version may not know newer columns: keep their current values.
          AppDb.mergeMissing(existing == null ? null : Map<String, Object?>.from(existing), row);
          row.remove('dirty');
          row['dirty'] = 0;
          if (table == 'users') row['pin_hash'] = existing?['pin_hash'];
          if (existing != null && existing['number'] != null && DbNumbers.has(table)) {
            row['number'] = existing['number']; // numbers are owned by the hub
          }
          // Would this new row clash with a different existing row on a unique column?
          final clash = existing == null ? db.uniqueClash(table, row) : null;
          if (clash != null) {
            if (DbNumbers.has(table) && table != 'quotes') {
              row['number'] = null; // a stale number (e.g. after a restore): give it a fresh one
            } else if (table == 'settings') {
              // Same setting created on two devices: merge into the hub's row.
              if ((clash['updated_at'] as String).compareTo(row['updated_at'] as String) >= 0) {
                (rejected[table] ??= []).add(id);
                continue;
              }
              row['id'] = clash['id'];
            } else {
              (rejected[table] ??= []).add(id);
              continue;
            }
          }
          row['seq'] = db.nextSeq();
          db.assignNumber(table, row);
          db.putRaw(table, row);
          if (table == 'files') filedFromDevice.add(id);
          (acceptedIds[table] ??= []).add(id);
          accepted++;
        }
      }
    });
    // A file filed on another device that is already on this PC (e.g. an inbox email
    // attachment) gets copied into its job folder. Never fail the sync over a copy.
    for (final id in filedFromDevice) {
      try {
        files.copyIntoProject(id);
      } catch (_) {}
    }
    return (accepted: accepted, rejected: rejected, acceptedIds: acceptedIds, skippedIds: skippedIds);
  }

  static const _bookkeeping = {'id', 'created_at', 'updated_at', 'updated_by', 'seq', 'dirty', 'number'};

  /// Three-way merge of a device's edit ([mine], started from [base]) with the current
  /// version ([theirs]). Fields only one side changed keep that change; a field both changed
  /// differently goes to the newer edit and is recorded as a conflict on the job.
  /// Returns the merged row, or null when the device changed nothing that is still different.
  Map<String, Object?>? _mergeEdits(String table, Map<String, Object?> base, Map<String, Object?> theirs,
      Map<String, Object?> mine, {String? byUser}) {
    bool same(Object? a, Object? b) => '${a ?? ''}' == '${b ?? ''}';
    final cols = theirs.keys.where((c) => !_bookkeeping.contains(c)).toList();
    final mineChanged = [for (final c in cols) if (mine.containsKey(c) && !same(mine[c], base[c])) c];
    final theirsChanged = {for (final c in cols) if (!same(theirs[c], base[c])) c};
    final mineNewer = (mine['updated_at'] as String).compareTo(theirs['updated_at'] as String) > 0;
    final clashes = [for (final c in mineChanged) if (theirsChanged.contains(c) && !same(mine[c], theirs[c])) c];
    final merged = Map<String, Object?>.from(theirs);
    var changed = false;
    for (final c in mineChanged) {
      if (clashes.contains(c) && !mineNewer) continue;
      if (!same(merged[c], mine[c])) {
        merged[c] = mine[c];
        changed = true;
      }
    }
    final deletedMeanwhile = theirs['deleted'] == 1 && base['deleted'] != 1 && mine['deleted'] != 1 && mineChanged.isNotEmpty;
    if (clashes.isNotEmpty || deletedMeanwhile) {
      _recordConflict(table, theirs, mine,
          clashes: clashes, mineWon: mineNewer, deletedMeanwhile: deletedMeanwhile, byUser: byUser);
    }
    if (!changed) return null;
    // Newer than both versions, so every device takes the merged one.
    var ts = db.now();
    for (final t in [theirs['updated_at'], mine['updated_at']]) {
      if (t is String && t.compareTo(ts) >= 0) {
        ts = DateTime.parse(t).add(const Duration(microseconds: 1)).toUtc().toIso8601String();
      }
    }
    merged['updated_at'] = ts;
    merged['updated_by'] = mine['updated_by'] ?? byUser;
    return merged;
  }

  static const _what = {
    'customers': 'the customer', 'projects': 'the job', 'measurements': 'measurements', 'measurement_items': 'a dimension',
    'selections': 'a selection', 'designs': 'a design', 'quotes': 'a quote', 'quote_items': 'a quote line',
    'invoices': 'an invoice', 'payments': 'a payment', 'notes': 'a note', 'appointments': 'an appointment',
    'suppliers': 'a supplier', 'purchase_orders': 'a purchase order', 'po_items': 'an order line', 'files': 'a file',
  };

  String? _projectOf(String table, Map<String, Object?> row) {
    if (table == 'projects') return row['id'] as String?;
    if (row['project_id'] is String) return row['project_id'] as String;
    String? via(String parent, String fk) =>
        db.raw.select('SELECT project_id FROM $parent WHERE id=?', [row[fk]]).firstOrNull?['project_id'] as String?;
    return switch (table) {
      'measurement_items' => via('measurements', 'measurement_id'),
      'quote_items' => via('quotes', 'quote_id'),
      'po_items' => via('purchase_orders', 'po_id'),
      'payments' => via('invoices', 'invoice_id'),
      _ => null,
    };
  }

  void _recordConflict(String table, Map<String, Object?> theirs, Map<String, Object?> mine,
      {required List<String> clashes, required bool mineWon, required bool deletedMeanwhile, String? byUser}) {
    String who(Object? uid) => (uid is String ? db.get('users', uid)?.ns('name') : null) ?? 'someone';
    final me = who(byUser ?? mine['updated_by']), them = who(theirs['updated_by']);
    final label = [
      _what[table] ?? table,
      for (final k in const ['room', 'title', 'name', 'label', 'item', 'description', 'number'])
        if ((theirs[k] ?? '').toString().trim().isNotEmpty) '"${theirs[k]}"',
    ].take(2).join(' ');
    final priced = pricedTables.contains(table);
    String field(String c) => c.replaceAll('_', ' ');
    final String body;
    if (deletedMeanwhile) {
      body = 'Edit conflict: $them deleted $label while $me was changing it. It stays deleted: '
          "restore it by hand if $me's changes are needed.";
    } else {
      final winner = mineWon ? mine : theirs;
      final details = clashes.map((c) => priced ? field(c) : '${field(c)}: "${winner[c] ?? ''}"').join(', ');
      body = 'Edit conflict: $me and $them changed $label at the same time. '
          "Kept ${mineWon ? me : them}'s ${clashes.length == 1 ? 'value' : 'values'} ($details). "
          "${mineWon ? them : me}'s other changes were kept.";
    }
    final pid = _projectOf(table, theirs);
    db.insert('notes', {
      'project_id': pid,
      'customer_id': pid == null && table == 'customers' ? theirs['id'] : null,
      'kind': 'conflict',
      'body': body,
    });
  }

  Map<String, List<Map<String, Object?>>> pullSince(int since, {required String role}) {
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in syncTables.keys) {
      if (!tableAllowed(table, role, write: false)) continue;
      final rows = db.raw.select('SELECT * FROM $table WHERE seq > ? ORDER BY seq', [since]);
      for (final r in rows) {
        final m = Map<String, Object?>.from(r);
        if (!rowVisible(table, m, role)) {
          // e.g. a note later marked 'money': the device must drop the version it has.
          (out[table] ??= []).add({'id': m['id'], 'deleted': 1, 'updated_at': m['updated_at'], 'seq': m['seq']});
          continue;
        }
        (out[table] ??= []).add(outgoing(table, m));
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ files

  Future<Response> _putBlob(Request req, String sha) async {
    _auth(req);
    if (!_hex64.hasMatch(sha)) throw _Http(400, 'Bad file id');
    final bytes = await _readBytes(req);
    try {
      files.storeIncoming(sha, bytes);
    } on FormatException catch (e) {
      throw _Http(400, e.message);
    }
    return _json({'ok': true});
  }

  Future<Response> _getBlob(Request req, String sha) async {
    final a = _auth(req);
    if (!_hex64.hasMatch(sha)) throw _Http(404, 'No such file');
    final role = a.user.s('role');
    final rows = db.select('SELECT * FROM files WHERE sha256=? AND deleted=0', [sha]);
    // Hidden anywhere (e.g. filed under quotes) means hidden for field staff.
    if (rows.any((r) => !rowVisible('files', r.m, role))) throw _Http(404, 'No such file');
    final f = rows.firstOrNull ??
        // Attachments of measurement emails still waiting in the inbox.
        db.one("SELECT id, subject AS name, 'measurements' AS category FROM mail_inbox WHERE attachments LIKE ? AND deleted=0",
            ['%"$sha"%']);
    if (f == null) throw _Http(404, 'No such file');
    final path = files.localPath(sha);
    if (path == null) throw _Http(404, 'File not on the PC yet');
    if (!files.matchesChecksum(sha)) {
      throw _Http(409, '${f.s('name')} was edited on the main office PC. Open the job there and click '
          '"Save changes" on the file first.');
    }
    return Response.ok(File(path).openRead(), headers: {'content-type': 'application/octet-stream'});
  }

  static Future<Uint8List> _readBytes(Request req) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  static Response _json(Object body, {int status = 200}) =>
      Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json'});
}

class DbNumbers {
  static bool has(String table) => AppDb.numberPrefix.containsKey(table);
}

class _Http implements Exception {
  _Http(this.status, this.message);
  final int status;
  final String message;
}

/// IPv4 addresses of this PC on the local network (for the pairing QR code).
Future<List<String>> localAddresses() async {
  final out = <String>[];
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in ni.addresses) {
      if (!a.isLoopback && !a.isLinkLocal) out.add(a.address);
    }
  }
  return out;
}
