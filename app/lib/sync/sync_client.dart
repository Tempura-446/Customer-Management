import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/db.dart';
import '../core/files.dart';
import '../core/schema.dart';

/// Finds the hub on the local network when its IP address changed.
/// Returns "host:port" candidates. The app plugs in Bonjour/mDNS here.
typedef HubDiscovery = Future<List<String>> Function(String hubId);

class SyncException implements Exception {
  SyncException(this.message, {this.unpaired = false});
  final String message;
  final bool unpaired;
  @override
  String toString() => message;
}

class SyncResult {
  SyncResult(this.pushed, this.pulled, this.uploaded);
  final int pushed, pulled, uploaded;
}

/// Phone side of Wi-Fi sync.
///
/// 1. push every row marked dirty, 2. pull every row the hub changed since
/// our cursor, 3. upload photos/files the hub doesn't have yet.
/// Works offline in between; nothing is lost if the Wi-Fi drops mid-sync
/// (rows stay dirty until the hub confirms).
class SyncClient extends ChangeNotifier {
  SyncClient(this.db, this.files, {this.discovery, http.Client? client}) : _http = client ?? http.Client();
  final AppDb db;
  final FileStore files;
  final HubDiscovery? discovery;
  final http.Client _http;

  bool syncing = false;
  String? lastError;

  bool get paired => db.meta('hub_token') != null;
  String? get hubName => db.meta('hub_name');
  String? get lastSync => db.meta('last_sync');
  String? get userId => db.meta('user_id');

  /// A shared office computer: anyone signs in with their own PIN (set on the main PC).
  bool get shared => db.meta('shared_device') == '1';
  List<String> get _hosts => ((jsonDecode(db.meta('hub_hosts') ?? '[]') as List).cast<String>());

  int pendingChanges() {
    var n = 0;
    for (final t in syncTables.keys) {
      n += db.raw.select('SELECT COUNT(*) c FROM $t WHERE dirty=1').first['c'] as int;
    }
    return n + files.pendingUploads().length;
  }

  // ------------------------------------------------------------------ pairing

  /// [payload] is the JSON from the QR code shown on the PC.
  Future<void> pair(Map<String, dynamic> payload, {required String deviceName}) async {
    if (payload['app'] != 'cabinetcrm') throw SyncException('That QR code is not from the Casework PC app.');
    final port = payload['port'];
    final hosts = ((payload['hosts'] as List?) ?? const []).map((h) => '$h:$port').toList();
    final base = await _reach(hosts, payload['hub'] as String);
    final res = await _post('$base/api/pair', {'code': payload['code'], 'device_name': deviceName}, auth: false);
    db.setMeta('hub_token', res['token'] as String);
    db.setMeta('hub_id', res['hub'] as String);
    db.setMeta('hub_name', res['name'] as String? ?? 'Office PC');
    db.setMeta('hub_hosts', jsonEncode([base.replaceFirst('http://', ''), ...hosts]));
    db.setMeta('cursor', '0');
    if (res['shared'] == true) {
      db.setMeta('shared_device', '1');
    } else {
      db.setMeta('shared_device', '0');
      _storeUser(res['user'] as Map<String, dynamic>);
    }
    notifyListeners();
  }

  void unpair() {
    for (final k in ['hub_token', 'hub_id', 'hub_name', 'hub_hosts', 'cursor', 'user_id', 'last_sync', 'hub_generation',
        'shared_device']) {
      db.raw.execute('DELETE FROM meta WHERE key=?', [k]);
    }
    notifyListeners();
  }

  void _storeUser(Map<String, dynamic> u) {
    db.putRaw('users', {...u, 'dirty': 0});
    db.setMeta('user_id', u['id'] as String);
    db.currentUserId = u['id'] as String;
  }

  // ------------------------------------------------------------------ sync

  Future<SyncResult> sync() => _sync(retryAfterGenerationChange: true);

  /// Store a row from the hub, keeping local columns the hub didn't send and
  /// dropping any stale local row that would clash with it on a unique column.
  void _applyRow(String t, Map<String, Object?> row) {
    final existing = db.raw.select('SELECT * FROM $t WHERE id=?', [row['id']]).firstOrNull;
    // A tombstone for a row we never had (hidden from this role): nothing to do.
    if (existing == null && row['deleted'] == 1 && !row.containsKey('created_at')) return;
    AppDb.mergeMissing(existing == null ? null : Map<String, Object?>.from(existing), row);
    for (final c in db.uniqueClash(t, row) == null ? const <String>[] : AppDb.uniqueColumns[t] ?? const <String>[]) {
      if (row[c] != null) db.raw.execute('DELETE FROM $t WHERE $c=? AND id<>?', [row[c], row['id']]);
    }
    db.putRaw(t, row);
  }

  Future<SyncResult> _sync({required bool retryAfterGenerationChange}) async {
    if (!paired) throw SyncException('Not paired with the office PC yet.', unpaired: true);
    if (syncing) return SyncResult(0, 0, 0);
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final base = await _reach(_hosts, db.meta('hub_id')!);
      // Snapshot what we push so edits made *during* the sync are not overwritten.
      final changes = <String, List<Map<String, Object?>>>{};
      final pushedVersion = <String, String>{};
      var pushed = 0;
      for (final t in syncTables.keys) {
        final rows = db.raw.select('SELECT * FROM $t WHERE dirty=1');
        if (rows.isEmpty) continue;
        changes[t] = rows.map((r) {
          final m = Map<String, Object?>.from(r)..remove('dirty');
          if (t == 'users') m.remove('pin_hash');
          pushedVersion['$t/${m['id']}'] = m['updated_at'] as String;
          // The version this edit started from: lets the main PC keep other people's changes
          // to fields we didn't touch. Older main PCs ignore it.
          final base = db.baseOf(t, m['id'] as String);
          if (base != null) {
            if (t == 'users') base.remove('pin_hash');
            m['_base'] = base;
          }
          return m;
        }).toList();
        pushed += rows.length;
      }
      final res = await _post('$base/api/sync', {
        'since': int.parse(db.meta('cursor') ?? '0'),
        'changes': changes,
        'blobs_pending': files.pendingUploads(),
      });

      var pulled = 0;
      db.raw.execute('BEGIN');
      try {
        // Rows we pushed and the hub accepted come back with their new seq/number.
        // Anything else still dirty that we didn't push must stay dirty.
        final rows = (res['rows'] as Map<String, dynamic>?) ?? {};
        for (final t in syncTables.keys) {
          for (final raw in (rows[t] as List?) ?? const []) {
            final row = Map<String, Object?>.from(raw as Map);
            final local = db.raw.select('SELECT updated_at, dirty FROM $t WHERE id=?', [row['id']]).firstOrNull;
            if (local != null && local['dirty'] == 1) {
              final sent = pushedVersion['$t/${row['id']}'];
              if (sent == null || sent != local['updated_at']) continue; // edited again since: keep ours
            }
            row['dirty'] = 0;
            _applyRow(t, row);
            pulled++;
          }
        }
        // Clear dirty for rows the hub confirmed (older hubs don't list them: then anything
        // pushed and not echoed back counts as accepted).
        final acceptedIds = res['accepted_ids'] as Map<String, dynamic>?;
        final skippedIds = (res['skipped_ids'] as Map<String, dynamic>?) ?? const {};
        for (final MapEntry(key: k, value: ts) in pushedVersion.entries) {
          final [t, id] = k.split('/');
          final confirmed = acceptedIds == null ||
              ((acceptedIds[t] as List?)?.contains(id) ?? false) ||
              ((skippedIds[t] as List?)?.contains(id) ?? false);
          if (confirmed) db.raw.execute('UPDATE $t SET dirty=0 WHERE id=? AND updated_at=? AND dirty=1', [id, ts]);
        }
        db.setMeta('cursor', '${res['cursor']}');
        if (res['user'] != null && res['shared'] != true) _storeUser(res['user'] as Map<String, dynamic>);
        db.pruneBases(syncTables.keys);
        db.raw.execute('COMMIT');
      } catch (_) {
        db.raw.execute('ROLLBACK');
        rethrow;
      }

      var uploaded = 0;
      for (final sha in ((res['need_blobs'] as List?) ?? const []).cast<String>()) {
        final path = files.localPath(sha);
        if (path == null) continue;
        final r = await _http
            .put(Uri.parse('$base/api/blobs/$sha'), headers: _headers(), body: await File(path).readAsBytes())
            .timeout(const Duration(minutes: 5));
        if (r.statusCode == 200) {
          files.markUploaded(sha);
          uploaded++;
        }
      }
      // Hub already had the rest.
      for (final sha in files.pendingUploads()) {
        if (!((res['need_blobs'] as List?) ?? const []).contains(sha)) files.markUploaded(sha);
      }
      // The main PC was restored from a backup: its change counter started over, so
      // everything we hold that isn't ours must be fetched again from scratch.
      final gen = '${res['generation'] ?? '0'}';
      final known = db.meta('hub_generation');
      db.setMeta('hub_generation', gen);
      // Made shared (or back to one person's) on the main PC: what this computer may hold
      // changed, so fetch everything again the same way.
      final nowShared = res['shared'] == true;
      final sharedChanged = res.containsKey('shared') && nowShared != shared;
      if (sharedChanged) {
        db.setMeta('shared_device', nowShared ? '1' : '0');
        if (nowShared) db.raw.execute("DELETE FROM meta WHERE key='user_id'"); // next start: sign-in screen
      }
      if (((known != null && known != gen) || sharedChanged) && retryAfterGenerationChange) {
        db.raw.execute('BEGIN');
        for (final t in syncTables.keys) {
          db.raw.execute('DELETE FROM $t WHERE dirty=0');
        }
        db.pruneBases(syncTables.keys);
        db.setMeta('cursor', '0');
        db.raw.execute('COMMIT');
        syncing = false;
        final again = await _sync(retryAfterGenerationChange: false);
        return SyncResult(pushed + again.pushed, pulled + again.pulled, uploaded + again.uploaded);
      }
      db.setMeta('last_sync', DateTime.now().toIso8601String());
      db.changed();
      return SyncResult(pushed, pulled, uploaded);
    } on SyncException catch (e) {
      lastError = e.message;
      rethrow;
    } on Exception catch (e) {
      lastError = 'Sync failed: $e';
      throw SyncException(lastError!);
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Download a file from the hub (phones keep files on demand).
  Future<String> fetchBlob(String sha) async {
    final have = files.localPath(sha);
    if (have != null) return have;
    final base = await _reach(_hosts, db.meta('hub_id')!);
    final r = await _http.get(Uri.parse('$base/api/blobs/$sha'), headers: _headers()).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) throw SyncException(_err(r));
    files.storeIncoming(sha, r.bodyBytes);
    return files.localPath(sha)!;
  }

  // ------------------------------------------------------------------ transport

  Map<String, String> _headers() =>
      {'authorization': 'Bearer ${db.meta('hub_token')}', 'content-type': 'application/json'};

  Future<Map<String, dynamic>> _post(String url, Object body, {bool auth = true}) async {
    final r = await _http
        .post(Uri.parse(url), headers: auth ? _headers() : {'content-type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(minutes: 2));
    if (r.statusCode == 401) {
      throw SyncException(_err(r), unpaired: true);
    }
    if (r.statusCode != 200) throw SyncException(_err(r));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  String _err(http.Response r) {
    try {
      return (jsonDecode(r.body) as Map)['error'] as String;
    } catch (_) {
      return 'Office PC answered ${r.statusCode}';
    }
  }

  /// Find a reachable hub address: last known IPs first, then network discovery.
  Future<String> _reach(List<String> hosts, String hubId) async {
    Future<String?> tryHost(String h) async {
      try {
        final r = await _http.get(Uri.parse('http://$h/api/hello')).timeout(const Duration(seconds: 3));
        if (r.statusCode == 200 && (jsonDecode(r.body) as Map)['hub'] == hubId) return 'http://$h';
      } catch (_) {}
      return null;
    }

    for (final h in hosts) {
      final ok = await tryHost(h);
      if (ok != null) return ok;
    }
    if (discovery != null) {
      for (final h in await discovery!(hubId)) {
        final ok = await tryHost(h);
        if (ok != null) {
          db.setMeta('hub_hosts', jsonEncode([h, ...hosts.where((x) => x != h)]));
          return ok;
        }
      }
    }
    throw SyncException("Can't reach the office PC. Make sure you're on the shop Wi-Fi and the PC app is open.");
  }
}
