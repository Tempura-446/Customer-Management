import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/device_mode.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/sync/hub_server.dart';
import 'package:cabinet_crm/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

class Phone {
  Phone(Directory dir) {
    db = AppDb.memory(isHub: false);
    files = FileStore(db, dir.path);
    client = SyncClient(db, files);
  }
  late AppDb db;
  late FileStore files;
  late SyncClient client;
}

void main() {
  late Directory tmp;
  late AppDb hub;
  late FileStore hubFiles;
  late HubServer server;
  late String owner, installer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('crm');
    hub = AppDb.memory(isHub: true);
    seedSettings(hub);
    owner = createUser(hub, name: 'Owner', role: 'owner', pin: '1111');
    installer = createUser(hub, name: 'Ian Installer', role: 'field', pin: '2222');
    hub.currentUserId = owner;
    hubFiles = FileStore(hub, '${tmp.path}/hub');
    server = HubServer(hub, hubFiles);
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
  });
  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  Future<Phone> pairedPhone(String userId, String name) async {
    final ph = Phone(Directory('${tmp.path}/$name'));
    await ph.client.pair(server.pairingPayload(server.createPairingCode(userId), ['127.0.0.1']), deviceName: name);
    return ph;
  }

  test('pairing codes are single use', () async {
    final code = server.createPairingCode(owner);
    final a = Phone(Directory('${tmp.path}/a'));
    await a.client.pair(server.pairingPayload(code, ['127.0.0.1']), deviceName: 'a');
    final b = Phone(Directory('${tmp.path}/b'));
    expect(() => b.client.pair(server.pairingPayload(code, ['127.0.0.1']), deviceName: 'b'),
        throwsA(isA<SyncException>()));
  });

  test('phone works offline, then syncs: hub assigns job number, receives photo', () async {
    final ph = await pairedPhone(owner, 'iphone');
    await ph.client.sync();
    expect(ph.db.one('SELECT * FROM users WHERE id=?', [owner])!.ns('pin_hash'), isNull, reason: 'PINs never leave the PC');

    // Offline on site:
    final cid = saveCustomer(ph.db, {'name': 'Site Customer'});
    final pid = createProject(ph.db, customerId: cid, title: 'Kitchen');
    expect(ph.db.get('projects', pid)!.ns('number'), isNull);
    final mid = saveMeasurement(ph.db, projectId: pid, room: 'Kitchen', source: 'onsite',
        lines: [MeasureLine('Wall A', '144', 'in')]);
    ph.files.addBytes(projectId: pid, bytes: Uint8List.fromList([1, 2, 3]), name: 'wall.jpg',
        category: 'photos', entityType: 'measurement', entityId: mid);
    expect(ph.client.pendingChanges(), greaterThan(0));

    final r = await ph.client.sync();
    expect(r.uploaded, 1);
    expect(ph.client.pendingChanges(), 0);
    // Hub has everything, with a real job number, readable file path.
    final hp = projectWithCustomer(hub, pid)!;
    expect(hp.s('number'), startsWith('J-'));
    expect(hp.s('status'), 'measured');
    expect(measurementItems(hub, mid).single.s('value'), '144');
    final sha = hub.one('SELECT sha256 FROM files')!.s('sha256');
    expect(hubFiles.localPath(sha), contains('Projects/${hp.s('number')}_Site-Customer/photos/wall.jpg'));
    // Phone learns the number.
    expect(ph.db.get('projects', pid)!.s('number'), hp.s('number'));
  });

  test('changes made on the PC reach the phone; files download on demand', () async {
    final cid = saveCustomer(hub, {'name': 'Office Customer'});
    final pid = createProject(hub, customerId: cid, title: 'Bath');
    final did = saveDesign(hub, projectId: pid, title: 'v1');
    hubFiles.addBytes(projectId: pid, bytes: Uint8List.fromList([9, 9]), name: 'design.kit',
        category: 'designs', entityType: 'design', entityId: did);
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    expect(ph.db.get('designs', did)!.s('title'), 'v1');
    final f = ph.db.one('SELECT * FROM files')!;
    expect(ph.files.localPath(f.s('sha256')), isNull);
    final path = await ph.client.fetchBlob(f.s('sha256'));
    expect(File(path).readAsBytesSync(), [9, 9]);
  });

  test('conflict: last write wins, loser gets the winning version', () async {
    final cid = saveCustomer(hub, {'name': 'Original'});
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    ph.db.update('customers', cid, {'phone': 'phone-edit'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    hub.update('customers', cid, {'phone': 'pc-edit-later'});
    await ph.client.sync();
    expect(ph.db.get('customers', cid)!.s('phone'), 'pc-edit-later');
    expect(hub.get('customers', cid)!.s('phone'), 'pc-edit-later');
  });

  test('two phones see each other\'s changes through the hub', () async {
    final a = await pairedPhone(owner, 'a');
    final b = await pairedPhone(owner, 'b');
    final cid = saveCustomer(a.db, {'name': 'From A'});
    await a.client.sync();
    await b.client.sync();
    expect(b.db.get('customers', cid)!.s('name'), 'From A');
    deleteCustomer(b.db, cid);
    await b.client.sync();
    await a.client.sync();
    expect(a.db.get('customers', cid), isNull);
  });

  test('field users never receive prices', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final q = createQuote(hub, pid);
    saveQuote(hub, q, taxRate: 0, discount: 0, depositPct: 50,
        lines: [QuoteLine(description: 'Cabinets', unitPrice: 9000)]);
    sendQuote(hub, q);
    final ph = await pairedPhone(installer, 'field');
    await ph.client.sync();
    expect(ph.db.get('projects', pid), isNotNull);
    expect(ph.db.select('SELECT * FROM quotes'), isEmpty);
    expect(ph.db.select('SELECT * FROM quote_items'), isEmpty);
    expect(ph.db.select("SELECT * FROM notes WHERE body LIKE '%9000%' OR body LIKE '%9,000%'"), isEmpty);
    // and can't push them either
    ph.db.insert('quotes', {'project_id': pid, 'status': 'accepted'});
    await ph.client.sync();
    expect(hub.select("SELECT * FROM quotes WHERE status='accepted'"), isEmpty);
  });

  test('revoked device is refused', () async {
    final ph = await pairedPhone(owner, 'lost-phone');
    server.revokeDevice(server.devices().first.id);
    expect(() => ph.client.sync(), throwsA(isA<SyncException>().having((e) => e.unpaired, 'unpaired', true)));
  });

  test('2020 file edited on a workstation is saved back to the main PC', () async {
    final cid = saveCustomer(hub, {'name': 'Kit Customer'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final did = saveDesign(hub, projectId: pid, title: 'v1');
    hubFiles.addBytes(projectId: pid, bytes: Uint8List.fromList([1, 1, 1]), name: 'smith.kit',
        category: 'designs', entityType: 'design', entityId: did);
    final ws = await pairedPhone(owner, 'workstation');
    await ws.client.sync();
    final f = ws.db.one('SELECT * FROM files WHERE deleted=0')!;
    final path = await ws.client.fetchBlob(f.s('sha256'));
    expect(path, endsWith('smith.kit'), reason: 'real file name so 2020 opens it nicely');
    expect(ws.files.locallyModified(f.s('sha256')), isFalse);

    // "Edit in 2020 and save"
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File(path).writeAsBytesSync([2, 2, 2, 2]);
    File(path).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    expect(ws.files.locallyModified(f.s('sha256')), isTrue);
    final newId = ws.files.saveLocalChanges(f.id);
    expect(newId, isNot(f.id));
    final r = await ws.client.sync();
    expect(r.uploaded, 1);

    final live = hub.select("SELECT * FROM files WHERE entity_id=? AND deleted=0", [did]);
    expect(live.single.id, newId);
    expect(File(hubFiles.localPath(live.single.s('sha256'))!).readAsBytesSync(), [2, 2, 2, 2]);
  });

  test('file edited in place on the main PC is not served until saved', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K');
    final fid = hubFiles.addBytes(projectId: pid, bytes: Uint8List.fromList([5]), name: 'a.kit', category: 'designs');
    final sha = hub.get('files', fid)!.s('sha256');
    File(hubFiles.localPath(sha)!).writeAsBytesSync([6, 6]);
    File(hubFiles.localPath(sha)!).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    expect(() => ph.client.fetchBlob(sha), throwsA(isA<SyncException>()));
    expect(hubFiles.locallyModified(sha), isTrue);
    final newId = hubFiles.saveLocalChanges(fid);
    await ph.client.sync();
    final path = await ph.client.fetchBlob(hub.get('files', newId)!.s('sha256'));
    expect(File(path).readAsBytesSync(), [6, 6]);
  });

  test('network drive paths are detected', () {
    expect(looksLikeNetworkPath(r'\\server\share\Cabinet CRM'), isTrue);
    expect(looksLikeNetworkPath('/home/me/Cabinet CRM'), isFalse);
  });

  test('an older app version that does not know order_type cannot wipe it', () async {
    final cid = saveCustomer(hub, {'name': 'C'});
    final pid = createProject(hub, customerId: cid, title: 'K', orderType: 'install');
    final ph = await pairedPhone(owner, 'old');
    await ph.client.sync();
    // Simulate an old phone: edit the title and push a row without the order_type column.
    final row = Map<String, Object?>.from(ph.db.raw.select('SELECT * FROM projects WHERE id=?', [pid]).first)
      ..remove('order_type')
      ..remove('dirty')
      ..['title'] = 'Kitchen (renamed on old phone)'
      ..['updated_at'] = DateTime.now().toUtc().add(const Duration(seconds: 1)).toIso8601String();
    server.mergePush({'projects': [row]}, role: 'owner');
    final p = hub.get('projects', pid)!;
    expect(p.s('title'), 'Kitchen (renamed on old phone)');
    expect(p.s('order_type'), 'install');
  });
}
