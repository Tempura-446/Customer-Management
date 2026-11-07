import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/activity.dart';
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

  test('shared office computer: everyone signs in with their PIN; changes count with the author\'s role', () async {
    final ws = Phone(Directory('${tmp.path}/ws'));
    await ws.client.pair(server.pairingPayload(server.createPairingCode(owner, shared: true), ['127.0.0.1']),
        deviceName: 'Front desk');
    expect(ws.client.shared, isTrue);
    expect(ws.client.userId, isNull, reason: 'not tied to one person');
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final q = createQuote(hub, pid);
    saveQuote(hub, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 900)]);
    await ws.client.sync();
    // PINs arrive so people can sign in here even with the main PC off; prices too (office computer).
    expect(checkPin('2222', ws.db.get('users', installer)!.ns('pin_hash')), isTrue);
    expect(checkPin('1111', ws.db.get('users', owner)!.ns('pin_hash')), isTrue);
    expect(ws.db.get('quotes', q), isNotNull);

    // The installer signs in and edits the job (fine) and a quote (not allowed for field staff).
    ws.db.currentUserId = installer;
    ws.db.update('projects', pid, {'title': 'Kitchen + pantry'});
    ws.db.update('quotes', q, {'notes': 'installer edit'});
    // Then the owner signs in and edits the quote.
    await ws.client.sync();
    expect(hub.get('projects', pid)!.s('title'), 'Kitchen + pantry');
    expect(hub.get('quotes', q)!.ns('notes'), isNull);
    expect(ws.db.get('quotes', q)!.ns('notes'), isNull, reason: 'refused change replaced by the main PC version');
    ws.db.currentUserId = owner;
    ws.db.update('quotes', q, {'notes': 'owner edit'});
    ws.db.currentUserId = null; // signed out before the next sync: still counts as the owner's change
    await ws.client.sync();
    expect(hub.get('quotes', q)!.s('notes'), 'owner edit');
    // Phones stay personal and never receive PINs.
    final ph = await pairedPhone(installer, 'phone');
    await ph.client.sync();
    expect(ph.db.get('users', owner)!.ns('pin_hash'), isNull);
    expect(ph.client.shared, isFalse);
  });

  test("a person's computer can be made shared on the main PC, and fetches what it was missing", () async {
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final q = createQuote(hub, pid);
    saveQuote(hub, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 900)]);
    final ws = await pairedPhone(installer, 'ws');
    await ws.client.sync();
    expect(ws.db.get('quotes', q), isNull, reason: "the installer's computer gets no prices");
    final device = hub.raw.select('SELECT id FROM devices ORDER BY created_at DESC LIMIT 1').first['id'] as String;
    server.setDeviceShared(device, true);
    await ws.client.sync();
    expect(ws.client.shared, isTrue);
    expect(ws.client.userId, isNull);
    expect(ws.db.get('quotes', q), isNotNull);
    expect(ws.db.get('users', owner)!.ns('pin_hash'), isNotNull);
    server.setDeviceShared(device, false);
    await ws.client.sync();
    expect(ws.client.shared, isFalse);
    expect(ws.client.userId, installer);
    expect(ws.db.get('quotes', q), isNull, reason: 'back to the installer: prices removed again');
  });

  test('work history from a phone reaches the main PC under the right person', () async {
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final ph = await pairedPhone(installer, 'phone');
    await ph.client.sync();
    saveMeasurement(ph.db, projectId: pid, room: 'Pantry', source: 'onsite', lines: [MeasureLine('Depth', '24', 'in')]);
    await ph.client.sync();
    final who = jobWorkers(hub, pid).map((w) => w.name).toList();
    expect(who, containsAll(['Owner', 'Ian Installer']));
    expect(jobActivity(hub, pid, userId: installer).map((r) => r.s('label')),
        containsAll(['measurements "Pantry"', 'the job']), reason: 'the measurements, and the job moving to Measured');
    expect(hub.one("SELECT body FROM notes WHERE project_id=? AND body LIKE '%also worked%'", [pid])!.s('body'),
        'Ian Installer also worked on this job (with Owner)');
  });

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

  test('photos tagged with a room: stored, synced, listed by room', () async {
    final ph = await pairedPhone(installer, 'android');
    await ph.client.sync();
    final cid = saveCustomer(ph.db, {'name': 'Room Customer'});
    final pid = createProject(ph.db, customerId: cid, title: 'Kitchen');
    final mid = saveMeasurement(ph.db, projectId: pid, room: 'Kitchen', source: 'onsite', lines: []);
    saveMeasurement(ph.db, projectId: pid, room: 'Pantry', source: 'onsite', lines: []);
    final f1 = ph.files.addBytes(projectId: pid, bytes: Uint8List.fromList([1]), name: 'sink.jpg', category: 'photos', room: 'kitchen ');
    ph.files.addBytes(projectId: pid, bytes: Uint8List.fromList([2]), name: 'wall.jpg', category: 'measurements',
        entityType: 'measurement', entityId: mid, room: 'Kitchen');
    ph.files.addBytes(projectId: pid, bytes: Uint8List.fromList([3]), name: 'shelf.jpg', category: 'photos', room: 'Pantry');
    ph.files.addBytes(projectId: pid, bytes: Uint8List.fromList([4]), name: 'notes.pdf', category: 'photos', room: 'Kitchen');
    expect(ph.files.roomsForProject(pid), ['Kitchen', 'Pantry']);
    // Kitchen photos not attached to the measurement set itself; PDFs are not photos.
    expect(ph.files.roomPhotos(pid, 'KITCHEN', excludeEntityId: mid).map((f) => f.s('name')), ['sink.jpg']);

    await ph.client.sync();
    expect(hub.get('files', f1)!.s('room'), 'kitchen');
    hubFiles.setRoom(f1, 'Island');
    await ph.client.sync();
    expect(ph.db.get('files', f1)!.s('room'), 'Island');
    expect(ph.files.roomsForProject(pid), ['Kitchen', 'Pantry', 'Island']);
    hubFiles.setRoom(f1, '  ');
    expect(hub.get('files', f1)!.ns('room'), isNull);
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

  test('concurrent edits to different fields are both kept, with no conflict', () async {
    final cid = saveCustomer(hub, {'name': 'Jane', 'phone': '111', 'email': 'old@x.com'});
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    ph.db.update('customers', cid, {'phone': '222'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    hub.update('customers', cid, {'email': 'new@x.com'});
    await ph.client.sync();
    for (final db in [hub, ph.db]) {
      final c = db.get('customers', cid)!;
      expect((c.s('phone'), c.s('email')), ('222', 'new@x.com'));
    }
    expect(hub.select("SELECT body FROM notes WHERE kind='conflict'").map((n) => n.s('body')).toList(), isEmpty);
    expect(ph.db.raw.select('SELECT * FROM bases'), isEmpty, reason: 'base versions are dropped once synced');
  });

  test('same field changed on two phones: newer kept, conflict noted on the job until checked', () async {
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final mid = saveMeasurement(hub, projectId: pid, room: 'Kitchen', source: 'onsite', notes: 'start', lines: []);
    final a = await pairedPhone(owner, 'a');
    final b = await pairedPhone(installer, 'b');
    await a.client.sync();
    await b.client.sync();
    a.db.update('measurements', mid, {'notes': 'from A', 'taken_by': 'Alex'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    b.db.update('measurements', mid, {'notes': 'from B'});
    await a.client.sync();
    await b.client.sync();
    await a.client.sync();
    for (final db in [hub, a.db, b.db]) {
      final m = db.get('measurements', mid)!;
      expect((m.s('notes'), m.s('taken_by')), ('from B', 'Alex'), reason: "B's newer note, A's other change kept");
    }
    final note = hub.one("SELECT * FROM notes WHERE kind='conflict'")!;
    expect(note.s('project_id'), pid);
    expect(note.s('body'), contains('Ian Installer and Owner changed measurements "Kitchen" at the same time'));
    expect(note.s('body'), contains('notes: "from B"'));
    expect(projectWarnings(hub, pid).any((w) => w.message.startsWith('Edit conflict')), isTrue);
    hub.update('notes', note.id, {'kind': 'system'});
    expect(projectWarnings(hub, pid).any((w) => w.message.startsWith('Edit conflict')), isFalse);
  });

  test('edited on a phone while deleted on the PC: stays deleted, noted', () async {
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final mid = saveMeasurement(hub, projectId: pid, room: 'Pantry', source: 'onsite', lines: []);
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    ph.db.update('measurements', mid, {'notes': 'phone edit'});
    hub.softDelete('measurements', mid);
    await ph.client.sync();
    expect(hub.get('measurements', mid), isNull);
    expect(ph.db.get('measurements', mid), isNull);
    expect(hub.one("SELECT body FROM notes WHERE kind='conflict'")!.s('body'), contains('It stays deleted'));
  });

  test("a phone that only touched a job doesn't undo the PC's edit", () async {
    final cid = saveCustomer(hub, {'name': 'Jane'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final ph = await pairedPhone(owner, 'p');
    await ph.client.sync();
    ph.db.update('projects', pid, {}); // e.g. adding a note bumps the job
    await Future<void>.delayed(const Duration(milliseconds: 5));
    hub.update('projects', pid, {'title': 'Kitchen + pantry'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ph.db.update('projects', pid, {}); // the phone's version is now the newest
    await ph.client.sync();
    expect(hub.get('projects', pid)!.s('title'), 'Kitchen + pantry');
    expect(ph.db.get('projects', pid)!.s('title'), 'Kitchen + pantry');
    expect(ph.client.pendingChanges(), 0);
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
