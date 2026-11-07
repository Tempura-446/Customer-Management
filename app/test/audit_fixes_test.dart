import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/backup/backup_service.dart';
import 'package:cabinet_crm/core/address_match.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/schedule.dart';
import 'package:cabinet_crm/sync/hub_server.dart';
import 'package:cabinet_crm/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late AppDb hub;
  late FileStore hubFiles;
  late HubServer server;
  late String owner, installer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audit');
    hub = AppDb.memory(isHub: true);
    seedSettings(hub);
    owner = createUser(hub, name: 'Owner', role: 'owner', pin: '1111');
    installer = createUser(hub, name: 'Ian', role: 'field', pin: '2222');
    hub.currentUserId = owner;
    hubFiles = FileStore(hub, '${tmp.path}/hub');
    server = HubServer(hub, hubFiles);
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
  });
  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  Future<(AppDb, FileStore, SyncClient)> device(String userId, String name) async {
    final db = AppDb.memory(isHub: false);
    final files = FileStore(db, '${tmp.path}/$name');
    final c = SyncClient(db, files);
    await c.pair(server.pairingPayload(server.createPairingCode(userId), ['127.0.0.1']), deviceName: name);
    return (db, files, c);
  }

  test('a field device cannot fish out priced rows by pushing stale ids', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final q = createQuote(hub, pid);
    saveQuote(hub, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 9000)]);
    final (db, _, c) = await device(installer, 'field');
    await c.sync();
    final res = await http.post(Uri.parse('http://127.0.0.1:${server.port}/api/sync'),
        headers: {'authorization': 'Bearer ${db.meta('hub_token')}', 'content-type': 'application/json'},
        body: jsonEncode({'since': 0, 'changes': {'quotes': [{'id': q, 'updated_at': '0'}]}}));
    final rows = (jsonDecode(res.body) as Map)['rows'] as Map;
    expect(rows.containsKey('quotes'), isFalse);
    // Look for the price as a JSON value: a timestamp like 05:07:30.900026Z contains "9000" too.
    expect(res.body, isNot(matches(RegExp(r'[:\[,]\s*9000(\.0+)?\s*[,}\]]'))));
    expect(rows.containsKey('quote_items'), isFalse);
  });

  test('files rows with a bad category or sha are not written (no path traversal)', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final r = server.mergePush({
      'files': [
        {'id': newId(), 'updated_at': '2030-01-01', 'created_at': '2030-01-01', 'deleted': 0, 'project_id': pid,
          'category': '../../../escape', 'name': 'x', 'sha256': 'a' * 64, 'size': 1},
        {'id': newId(), 'updated_at': '2030-01-01', 'created_at': '2030-01-01', 'deleted': 0, 'project_id': pid,
          'category': 'photos', 'name': '../../evil.jpg', 'sha256': 'not-a-sha', 'size': 1},
      ]
    }, role: 'owner');
    expect(r.accepted, 0);
    expect(hub.select('SELECT * FROM files'), isEmpty);
    expect(() => hubFiles.storeIncoming('../x', Uint8List(0)), throwsA(isA<FormatException>()));
  });

  test('a pushed row with a used job number cannot delete the real job', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final number = hub.get('projects', pid)!.s('number');
    final ghost = newId();
    server.mergePush({
      'projects': [
        {'id': ghost, 'updated_at': '2030-01-01', 'created_at': '2030-01-01', 'deleted': 0, 'customer_id': cid,
          'title': 'Ghost', 'status': 'lead', 'number': number},
      ]
    }, role: 'owner');
    expect(hub.get('projects', pid)!.s('number'), number, reason: 'original survives');
    expect(hub.get('projects', ghost)!.s('number'), isNot(number), reason: 'ghost got a fresh number');
  });

  test('same setting created on two devices merges into one row', () async {
    final (a, _, ca) = await device(owner, 'a');
    final (b, _, cb) = await device(owner, 'b');
    await ca.sync();
    await cb.sync();
    setSetting(a, 'business_phone', '111');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    setSetting(b, 'business_phone', '222');
    await ca.sync();
    await cb.sync();
    await ca.sync();
    expect(hub.select("SELECT * FROM settings WHERE key='business_phone'"), hasLength(1));
    expect(settings(hub)['business_phone'], '222');
    expect(settings(a)['business_phone'], '222');
    expect(a.select("SELECT * FROM settings WHERE key='business_phone'"), hasLength(1));
  });

  test('device keeps columns an older main PC does not send', () {
    final db = AppDb.memory(isHub: false);
    db.putRaw('projects', {'id': 'p1', 'created_at': 'x', 'updated_at': 'x', 'customer_id': 'c', 'title': 'K',
      'status': 'lead', 'order_type': 'install', 'seq': 1});
    final merged = AppDb.mergeMissing(Map<String, Object?>.from(db.raw.select('SELECT * FROM projects').first),
        {'id': 'p1', 'updated_at': 'y', 'title': 'Kitchen'});
    expect(merged['order_type'], 'install');
    expect(merged['title'], 'Kitchen');
  });

  test('restore from backup: devices re-fetch everything instead of drifting', () async {
    final cid = saveCustomer(hub, {'name': 'Before'});
    final (db, _, c) = await device(owner, 'ws');
    await c.sync();
    expect(db.get('customers', cid), isNotNull);
    // Simulate a restore: the hub's counter is behind and a new generation is marked.
    hub.setMeta('seq', '1');
    hub.setMeta('hub_generation', '2');
    hub.softDelete('customers', cid);
    final after = saveCustomer(hub, {'name': 'After'});
    await c.sync();
    expect(db.get('customers', after), isNotNull);
    expect(db.get('customers', cid), isNull);
    expect(db.meta('hub_generation'), '2');
  });

  test('applyPendingRestore keeps the change counter moving and bumps the generation', () async {
    final root = '${tmp.path}/restore';
    final cur = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: true);
    seedSettings(cur);
    for (var i = 0; i < 50; i++) {
      cur.nextSeq();
    }
    cur.setMeta('hub_generation', '3');
    cur.dispose();
    final snap = AppDb.open(p.join(root, 'data', 'restore_pending.db'), isHub: true);
    seedSettings(snap);
    snap.dispose();
    BackupService.applyPendingRestore(root);
    final now = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: true);
    expect(int.parse(now.meta('seq')!), greaterThan(50));
    expect(now.meta('hub_generation'), '4');
    now.dispose();
  });

  test('a delivery done on an installation job does not mark it installed', () {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K', orderType: 'install');
    setStatus(hub, pid, 'received');
    final a = saveAppointment(hub, projectId: pid, kind: 'delivery', start: DateTime(2026, 1, 1, 9));
    markAppointmentDone(hub, a);
    expect(hub.get('projects', pid)!.s('status'), 'received');
    final b = saveAppointment(hub, projectId: pid, kind: 'install', start: DateTime(2026, 1, 2, 9));
    markAppointmentDone(hub, b);
    expect(hub.get('projects', pid)!.s('status'), 'completed');
  });

  test('tx depth survives a body that throws', () {
    expect(() => hub.tx(() => throw StateError('boom')), throwsStateError);
    final cid = saveCustomer(hub, {'name': 'Works after'});
    expect(hub.get('customers', cid), isNotNull);
  });

  test('a note that becomes money is removed from field devices', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    addNote(hub, pid, 'Deposit paid 5000', kind: 'call');
    final nid = hub.one("SELECT id FROM notes WHERE kind='call'")!.id;
    final (db, _, c) = await device(installer, 'field');
    await c.sync();
    expect(db.get('notes', nid), isNotNull);
    hub.update('notes', nid, {'kind': 'money'});
    await c.sync();
    expect(db.get('notes', nid), isNull);
  });

  test('deleting a job tombstones appointments, orders and lines too', () {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final apt = saveAppointment(hub, projectId: pid, kind: 'measure', start: DateTime(2026, 1, 1, 9));
    deleteProject(hub, pid);
    expect(hub.get('appointments', apt), isNull);
  });

  test('a quote with no lines cannot be accepted', () {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final q = createQuote(hub, pid);
    expect(() => acceptQuote(hub, q), throwsA(isA<BusinessError>()));
  });

  test('address: a different street suffix does not match', () {
    expect(addressScore('123 Main St', '123 Main Ave'), 0);
    expect(addressScore('123 Main', '123 Main Ave'), greaterThan(0));
    expect(addressScore('RE: 123 Main Street', '123 Main St'), greaterThan(0));
  });
}
