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
        }
      };

  Router get router => Router()
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
      _json({'app': 'cabinetcrm', 'hub': hubId, 'name': hubName, 'v': protocolVersion});

  static String normalizeCode(String c) => c.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  static String displayCode(String c) => c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;

  final _failedPairs = <DateTime>[];

  Future<Response> _pair(Request req) async {
    // Brute-force guard: max 10 wrong codes per 15 minutes.
    final cutoff = DateTime.now().subtract(const Duration(minutes: 15));
    _failedPairs.removeWhere((t) => t.isBefore(cutoff));
    if (_failedPairs.length >= 10) throw _Http(429, 'Too many wrong codes. Wait 15 minutes and create a new code.');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final code = normalizeCode(body['code'] as String? ?? '');
    final row = db.raw.select('SELECT * FROM pairing_codes WHERE code=?', [code]).firstOrNull;
    if (row == null || (row['expires_at'] as String).compareTo(DateTime.now().toUtc().toIso8601String()) < 0) {
      _failedPairs.add(DateTime.now());
      throw _Http(403, 'Pairing code is invalid or expired. Create a new one on the PC.');
    }
    final user = db.get('users', row['user_id'] as String);
    if (user == null || !user.b('active')) throw _Http(403, 'User is not active.');
    db.raw.execute('DELETE FROM pairing_codes WHERE code=?', [code]);
    final token = randomToken();
    final deviceId = newId();
    db.raw.execute('INSERT INTO devices(id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)',
        [deviceId, user.id, body['device_name'] ?? 'Phone', hashToken(token), DateTime.now().toUtc().toIso8601String()]);
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
    final result = mergePush(changes, role: role);
    final out = pullSince(since, role: role);
    // Rejected rows: send back the hub version even if its seq is old.
    for (final MapEntry(key: t, value: ids) in result.rejected.entries) {
      for (final id in ids) {
        final r = db.raw.select('SELECT * FROM $t WHERE id=?', [id]).firstOrNull;
        if (r != null) (out[t] ??= []).add(outgoing(t, Map.from(r)));
      }
    }
    final pending = ((body['blobs_pending'] as List?) ?? const []).cast<String>();
    final need = pending.where((s) => !files.hasBlob(s)).toList();
    db.raw.execute('UPDATE devices SET last_sync=? WHERE id=?', [DateTime.now().toUtc().toIso8601String(), a.device.id]);
    db.changed();
    return _json({
      'cursor': db.currentSeq,
      'rows': out,
      'need_blobs': need,
      'accepted': result.accepted,
      'user': outgoing('users', a.user.m),
    });
  }

  /// Apply rows pushed by a device. Public so tests (and a future cloud relay) can reuse it.
  ({int accepted, Map<String, List<String>> rejected}) mergePush(Map<String, dynamic> changes, {required String role}) {
    var accepted = 0;
    final rejected = <String, List<String>>{};
    final filedFromDevice = <String>[];
    db.tx(() {
      for (final table in syncTables.keys) {
        final rows = (changes[table] as List?) ?? const [];
        if (rows.isEmpty) continue;
        if (!tableAllowed(table, role, write: true)) {
          for (final r in rows) {
            (rejected[table] ??= []).add((r as Map)['id'] as String);
          }
          continue;
        }
        for (final raw in rows) {
          final row = Map<String, Object?>.from(raw as Map);
          final id = row['id'] as String;
          if (!rowVisible(table, row, role)) continue;
          final existing = db.raw.select('SELECT * FROM $table WHERE id=?', [id]).firstOrNull;
          if (existing != null && (existing['updated_at'] as String).compareTo(row['updated_at'] as String) >= 0) {
            (rejected[table] ??= []).add(id);
            continue;
          }
          row.remove('dirty');
          row['seq'] = db.nextSeq();
          row['dirty'] = 0;
          if (table == 'users') row['pin_hash'] = existing?['pin_hash'];
          if (existing != null && existing['number'] != null && DbNumbers.has(table)) {
            row['number'] = existing['number']; // numbers are owned by the hub
          }
          db.assignNumber(table, row);
          db.putRaw(table, row);
          if (table == 'files') filedFromDevice.add(id);
          accepted++;
        }
      }
    });
    // A file filed on another device that is already on this PC (e.g. an inbox email
    // attachment) gets copied into its job folder.
    for (final id in filedFromDevice) {
      files.copyIntoProject(id);
    }
    return (accepted: accepted, rejected: rejected);
  }

  Map<String, List<Map<String, Object?>>> pullSince(int since, {required String role}) {
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in syncTables.keys) {
      if (!tableAllowed(table, role, write: false)) continue;
      final rows = db.raw.select('SELECT * FROM $table WHERE seq > ? ORDER BY seq', [since]);
      for (final r in rows) {
        final m = Map<String, Object?>.from(r);
        if (!rowVisible(table, m, role)) continue;
        (out[table] ??= []).add(outgoing(table, m));
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ files

  Future<Response> _putBlob(Request req, String sha) async {
    _auth(req);
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
    final f = db.one('SELECT * FROM files WHERE sha256=? AND deleted=0 LIMIT 1', [sha]) ??
        // Attachments of measurement emails still waiting in the inbox.
        db.one("SELECT id, subject AS name, 'measurements' AS category FROM mail_inbox WHERE attachments LIKE ? AND deleted=0",
            ['%$sha%']);
    if (f == null || !rowVisible('files', f.m, a.user.s('role'))) throw _Http(404, 'No such file');
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
