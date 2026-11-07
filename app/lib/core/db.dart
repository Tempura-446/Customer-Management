import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

/// A database row with convenient typed getters.
class Rec {
  Rec(this.m);
  final Map<String, Object?> m;
  Object? operator [](String k) => m[k];
  String get id => m['id'] as String;
  String s(String k) => m[k]?.toString() ?? '';
  String? ns(String k) {
    final v = m[k];
    if (v == null) return null;
    final t = v.toString();
    return t.isEmpty ? null : t;
  }
  double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
  int i(String k) => (m[k] as num?)?.toInt() ?? 0;
  bool b(String k) => i(k) != 0;
  bool has(String k) => m.containsKey(k);
  @override
  String toString() => m.toString();
}

/// Thin wrapper around SQLite that adds sync bookkeeping to every write.
///
/// The Windows app is the HUB: every write gets a new `seq` number and
/// sequential document numbers (J-/Q-/INV-) are assigned here.
/// Phones are CLIENTS: writes are marked `dirty` until pushed to the hub.
class AppDb extends ChangeNotifier {
  AppDb._(this.raw, {required this.isHub}) {
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute(createStatements());
    _migrate();
    deviceId = meta('device_id') ?? (setMeta('device_id', newId()));
  }

  /// Small additive migrations for databases created by older versions.
  void _migrate() {
    // Columns added after the first release: (table, column, type).
    const added = [
      ('blobs', 'mtime', 'INTEGER'),
      ('projects', 'order_type', 'TEXT'),
      ('projects', 'qb_list_id', 'TEXT'),
      ('projects', 'qb_full_name', 'TEXT'),
      ('customers', 'qb_list_id', 'TEXT'),
      ('files', 'room', 'TEXT'),
      ('projects', 'approval_sent_on', 'TEXT'),
      ('projects', 'approval_sent_to', 'TEXT'),
      ('projects', 'approved_on', 'TEXT'),
      ('projects', 'approved_by', 'TEXT'),
    ];
    for (final (table, column, type) in added) {
      final cols = raw.select('PRAGMA table_info($table)').map((r) => r['name']).toSet();
      if (!cols.contains(column)) raw.execute('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }

  factory AppDb.open(String path, {required bool isHub}) {
    Directory(File(path).parent.path).createSync(recursive: true);
    return AppDb._(sqlite3.open(path), isHub: isHub);
  }

  factory AppDb.memory({required bool isHub}) =>
      AppDb._(sqlite3.openInMemory(), isHub: isHub);

  final Database raw;
  final bool isHub;
  late final String deviceId;

  /// Who is making changes (stamped into updated_by).
  String? currentUserId;

  int _txDepth = 0;
  bool _changed = false;
  String _lastTs = '';

  // ------------------------------------------------------------------ reads

  List<Rec> select(String sql, [List<Object?> args = const []]) =>
      raw.select(sql, args).map((r) => Rec(Map<String, Object?>.from(r))).toList();

  Rec? one(String sql, [List<Object?> args = const []]) {
    final r = select(sql, args);
    return r.isEmpty ? null : r.first;
  }

  Rec? get(String table, String? id) => id == null
      ? null
      : one('SELECT * FROM $table WHERE id=? AND deleted=0', [id]);

  Object? scalar(String sql, [List<Object?> args = const []]) {
    final r = raw.select(sql, args);
    return r.isEmpty ? null : r.first.values.first;
  }

  // ------------------------------------------------------------------ meta (local only)

  String? meta(String key) =>
      raw.select('SELECT value FROM meta WHERE key=?', [key]).firstOrNull?['value'] as String?;

  String setMeta(String key, String value) {
    raw.execute('INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)', [key, value]);
    return value;
  }

  // ------------------------------------------------------------------ writes

  /// Strictly increasing UTC timestamp for this device.
  String now() {
    var ts = DateTime.now().toUtc().toIso8601String();
    if (ts.compareTo(_lastTs) <= 0) {
      ts = DateTime.parse(_lastTs).add(const Duration(microseconds: 1)).toIso8601String();
    }
    _lastTs = ts;
    return ts;
  }

  int nextSeq() {
    final n = int.parse(meta('seq') ?? '0') + 1;
    setMeta('seq', '$n');
    return n;
  }

  int get currentSeq => int.parse(meta('seq') ?? '0');

  Map<String, Object?> _stamp(Map<String, Object?> v) {
    v['updated_at'] = now();
    v['updated_by'] = currentUserId ?? v['updated_by'];
    if (isHub) {
      v['seq'] = nextSeq();
      v['dirty'] = 0;
    } else {
      v['dirty'] = 1;
    }
    return v;
  }

  String insert(String table, Map<String, Object?> values) {
    final v = Map<String, Object?>.from(values);
    v['id'] ??= newId();
    _stamp(v);
    v['created_at'] = v['updated_at'];
    if (isHub) assignNumber(table, v);
    _write('INSERT INTO $table (${v.keys.join(',')}) VALUES (${List.filled(v.length, '?').join(',')})',
        v.values.toList());
    return v['id'] as String;
  }

  void update(String table, String id, Map<String, Object?> values) {
    final v = _stamp(Map<String, Object?>.from(values));
    _write('UPDATE $table SET ${v.keys.map((k) => '$k=?').join(',')} WHERE id=?',
        [...v.values, id]);
  }

  void softDelete(String table, String id) => update(table, id, {'deleted': 1});

  /// Run several writes as one unit; listeners are notified once at the end.
  T tx<T>(T Function() body) {
    if (_txDepth == 0) raw.execute('BEGIN');
    _txDepth++;
    var ok = false;
    try {
      final r = body();
      ok = true;
      return r;
    } finally {
      _txDepth--;
      if (_txDepth == 0) {
        if (ok) {
          try {
            raw.execute('COMMIT');
          } catch (_) {
            _rollback();
            rethrow;
          }
          _flush();
        } else {
          _rollback();
        }
      }
    }
  }

  void _rollback() {
    try {
      raw.execute('ROLLBACK');
    } catch (_) {}
    _changed = false;
  }

  /// Columns that must be unique besides the id (sync has to respect them).
  static const uniqueColumns = {
    'projects': ['number'],
    'invoices': ['number'],
    'purchase_orders': ['number'],
    'settings': ['key'],
    'qb_estimates': ['qb_txn_id'],
    'mail_inbox': ['message_id'],
  };

  /// An existing row (other id) that would clash with [row] on a unique column, or null.
  Map<String, Object?>? uniqueClash(String table, Map<String, Object?> row) {
    for (final col in uniqueColumns[table] ?? const <String>[]) {
      final v = row[col];
      if (v == null || '$v'.isEmpty) continue;
      final r = raw.select('SELECT * FROM $table WHERE $col=? AND id<>?', [v, row['id']]).firstOrNull;
      if (r != null) return Map<String, Object?>.from(r);
    }
    return null;
  }

  void _write(String sql, List<Object?> args) {
    raw.execute(sql, args);
    _changed = true;
    if (_txDepth == 0) _flush();
  }

  void _flush() {
    if (_changed) {
      _changed = false;
      notifyListeners();
    }
  }

  /// Tell listeners data changed (e.g. after applying a sync).
  void changed() => notifyListeners();

  // ------------------------------------------------------------------ numbering (hub only)

  static const numberPrefix = {'projects': 'J', 'quotes': 'Q', 'invoices': 'INV', 'purchase_orders': 'PO'};

  /// Give new jobs / quotes / invoices their next sequential number.
  /// Phones create them with number = NULL; the hub fills it in on sync.
  void assignNumber(String table, Map<String, Object?> v) {
    final prefix = numberPrefix[table];
    if (prefix == null || (v['number'] != null && '${v['number']}'.isNotEmpty)) return;
    v['number'] = nextNumber(prefix, table);
  }

  String nextNumber(String prefix, String table) {
    final stem = '$prefix-${DateTime.now().year}-';
    var maxN = 0;
    for (final r in raw.select('SELECT number FROM $table WHERE number LIKE ?', ['$stem%'])) {
      final n = int.tryParse((r['number'] as String).substring(stem.length));
      if (n != null && n > maxN) maxN = n;
    }
    return '$stem${(maxN + 1).toString().padLeft(3, '0')}';
  }

  /// Columns of a table (for sync).
  List<String> columns(String table) =>
      raw.select('PRAGMA table_info($table)').map((r) => r['name'] as String).toList();

  /// Write a row exactly as received (sync). Does not stamp or notify.
  void putRaw(String table, Map<String, Object?> row) {
    final cols = columns(table).where(row.containsKey).toList();
    final sets = cols.where((c) => c != 'id').map((c) => '$c=excluded.$c').join(',');
    raw.execute(
        'INSERT INTO $table (${cols.join(',')}) VALUES (${List.filled(cols.length, '?').join(',')}) '
        'ON CONFLICT(id) DO ${sets.isEmpty ? 'NOTHING' : 'UPDATE SET $sets'}',
        cols.map((c) => row[c]).toList());
    _changed = true;
  }

  /// Fill in columns missing from [row] (sent by an older app version) from [existing].
  static Map<String, Object?> mergeMissing(Map<String, Object?>? existing, Map<String, Object?> row) {
    if (existing == null) return row;
    for (final MapEntry(:key, :value) in existing.entries) {
      if (!row.containsKey(key)) row[key] = value;
    }
    return row;
  }

  @override
  void dispose() {
    raw.close();
    super.dispose();
  }
}
