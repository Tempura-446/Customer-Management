import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/address_match.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/mail/imap_fetcher.dart';
import 'package:cabinet_crm/mail/mail_ingest.dart';
import 'package:cabinet_crm/mail/mail_poller.dart';
import 'package:cabinet_crm/sync/hub_server.dart';
import 'package:cabinet_crm/sync/sync_client.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pdf([int n = 1]) => Uint8List.fromList(utf8.encode('%PDF-1.4 measurement $n'));
Uint8List photo(int kb) => Uint8List.fromList(List.filled(kb * 1024, kb));

MailEnvelope mail(String subject, {String id = '', List<MailAttachment>? atts, String text = 'Wall A 144'}) =>
    MailEnvelope(
      messageId: id.isEmpty ? '<$subject@test>' : id,
      subject: subject,
      from: 'Mike Tech <mike@shop.com>',
      date: DateTime(2026, 11, 6, 9, 30),
      text: text,
      attachments: atts ?? [MailAttachment('Measure.pdf', pdf()), MailAttachment('IMG_1.jpg', photo(300), inline: true)],
    );

void main() {
  group('address matching', () {
    test('subjects that should match "123 Main St, Springfield"', () {
      for (final s in [
        '123 Main Street',
        'RE: 123 main st - kitchen measurements',
        'Fwd: Measurements 123 Main St.',
        '123 MAIN STREET SPRINGFIELD',
        'Unit 4 - 123 Main St',
        '123 N Main St',
      ]) {
        expect(addressScore(s, '123 Main St, Springfield'), greaterThan(0), reason: s);
      }
    });

    test('subjects that must not match', () {
      expect(addressScore('124 Main St', '123 Main St'), 0);
      expect(addressScore('123 Maple St', '123 Main St'), 0);
      expect(addressScore('Measurements for Smith', '123 Main St'), 0);
      expect(addressScore('1123 Main St', '123 Main St'), 0);
    });

    test('multi-word street names', () {
      expect(addressScore('45 Maple Ridge Crescent', '45 Maple Ridge Cres'), greaterThan(0));
      expect(addressScore('45 Maple Crescent', '45 Maple Ridge Cres'), 0);
      expect(parseAddress('RE: 2-18 Oak Avenue')!.toString(), '18 oak ave');
    });
  });

  group('ingest', () {
    late Directory tmp;
    late AppDb db;
    late FileStore files;
    late String pid;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mail');
      db = AppDb.memory(isHub: true);
      seedSettings(db);
      files = FileStore(db, tmp.path);
      final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '123 Main St, Springfield'});
      pid = createProject(db, customerId: cid, title: 'Kitchen');
      final c2 = saveCustomer(db, {'name': 'Bob Lee', 'address': '9 Oak Ave'});
      createProject(db, customerId: c2, title: 'Bath');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('matching subject is filed into the job as a measurement with the PDF and photo', () {
      final id = ingestEmail(db, files, mail('RE: 123 Main Street - measurements'))!;
      final item = db.get('mail_inbox', id)!;
      expect(item.s('status'), 'filed');
      expect(item.s('project_id'), pid);
      final m = db.get('measurements', item.s('measurement_id'))!;
      expect(m.s('taken_by'), 'Mike Tech');
      expect(m.s('taken_on'), '2026-11-06');
      expect(m.s('notes'), contains('Wall A 144'));
      expect(db.get('projects', pid)!.s('status'), 'measured');
      final f = files.filesFor('measurement', m.id);
      expect(f.map((r) => r.s('name')), containsAll(['Measure.pdf', 'IMG_1.jpg']));
      // Lives in the job folder on the main PC.
      expect(files.localPath(f.firstWhere((r) => r.s('name') == 'Measure.pdf').s('sha256')),
          contains('${Platform.pathSeparator}Projects${Platform.pathSeparator}'));
    });

    test('same email twice is ignored; emails without PDFs/photos are skipped; logos dropped', () {
      expect(ingestEmail(db, files, mail('123 Main St')), isNotNull);
      expect(ingestEmail(db, files, mail('123 Main St')), isNull);
      expect(ingestEmail(db, files, mail('123 Main St', id: '<x>', atts: [])), isNull);
      final id = ingestEmail(db, files,
          mail('123 Main St', id: '<y>', atts: [MailAttachment('logo.png', photo(5), inline: true), MailAttachment('a.pdf', pdf(2))]))!;
      expect(mailAttachments(db.get('mail_inbox', id)!).map((a) => a['name']), ['a.pdf']);
    });

    test('unknown address waits in the inbox; can create the customer & job from it', () {
      final id = ingestEmail(db, files, mail('77 Birch Lane measure'))!;
      final item = db.get('mail_inbox', id)!;
      expect(item.s('status'), 'unmatched');
      expect(item.s('note'), contains('No job found'));
      expect(unmatchedMailCount(db), 1);
      final newPid = createJobFromMail(db, files, id, customerName: 'New Person');
      expect(projectWithCustomer(db, newPid)!.s('site_address'), '77 Birch Ln');
      expect(db.get('mail_inbox', id)!.s('status'), 'filed');
      expect(unmatchedMailCount(db), 0);
    });

    test('two customers at the same address: ask; then file and move', () {
      final c3 = saveCustomer(db, {'name': 'Tenant', 'address': '123 Main St'});
      final pid3 = createProject(db, customerId: c3, title: 'Closet');
      final id = ingestEmail(db, files, mail('123 Main St'))!;
      expect(db.get('mail_inbox', id)!.s('status'), 'unmatched');
      expect(matchProject(db, '123 Main St').candidates, containsAll([pid, pid3]));
      fileMailItem(db, files, id, pid);
      moveMailItem(db, files, id, pid3);
      final item = db.get('mail_inbox', id)!;
      expect(item.s('project_id'), pid3);
      expect(db.select("SELECT * FROM measurements WHERE project_id=? AND deleted=0", [pid]), isEmpty);
      expect(db.select("SELECT * FROM measurements WHERE project_id=? AND deleted=0", [pid3]), hasLength(1));
    });

    test('closed job loses to an open job for the same customer', () {
      setStatus(db, pid, 'closed');
      final c = db.get('projects', pid)!.s('customer_id');
      final newer = createProject(db, customerId: c, title: 'Bathroom', siteAddress: '123 Main St');
      expect(matchProject(db, '123 Main St').projectId, newer);
    });
  });

  test('reads a real-world MIME email with a PDF attachment', () {
    final raw = [
      'From: "Mike Tech" <mike@shop.com>',
      'To: measurements@shop.com',
      'Subject: 123 Main St - kitchen',
      'Message-ID: <abc123@mail.gmail.com>',
      'Date: Fri, 6 Nov 2026 09:30:00 -0500',
      'MIME-Version: 1.0',
      'Content-Type: multipart/mixed; boundary="XYZ"',
      '',
      '--XYZ',
      'Content-Type: text/plain; charset=utf-8',
      '',
      'Measurements attached. Ceiling 96.',
      '--XYZ',
      'Content-Type: application/pdf; name="Smith measure.pdf"',
      'Content-Disposition: attachment; filename="Smith measure.pdf"',
      'Content-Transfer-Encoding: base64',
      '',
      base64.encode(pdf()),
      '--XYZ--',
      '',
    ].join('\r\n');
    final env = envelopeFrom(MimeMessage.parseFromText(raw));
    expect(env.subject, '123 Main St - kitchen');
    expect(env.messageId, '<abc123@mail.gmail.com>');
    expect(env.from, contains('mike@shop.com'));
    expect(env.text, contains('Ceiling 96'));
    expect(env.attachments.single.name, 'Smith measure.pdf');
    expect(env.attachments.single.bytes, pdf());
  });

  test('poller: checks with saved settings, remembers position, password never in the database', () async {
    final tmp = await Directory.systemTemp.createTemp('poll');
    final db = AppDb.memory(isHub: true);
    final files = FileStore(db, tmp.path);
    final cid = saveCustomer(db, {'name': 'Jane', 'address': '123 Main St'});
    createProject(db, customerId: cid, title: 'Kitchen');
    int? sawAfter;
    final poller = MailPoller(db, files, secrets: MemorySecretStore(),
        fetcher: (c, {afterUid, uidValidity, sinceDays = 14}) async {
      sawAfter = afterUid;
      expect(c.password, 'abcdefghijklmnop');
      return FetchResult([mail('123 Main St'), mail('5 Nowhere Rd')], 41, 7);
    });
    await poller.save(enabled: false, host: 'imap.gmail.com', port: 993, user: 'm@shop.com',
        password: 'abcd efgh ijkl mnop', folder: 'INBOX', pollMinutes: 5, sinceDays: 14);
    final summary = await poller.checkNow();
    expect(summary, '1 filed automatically, 1 waiting in the Email inbox.');
    expect(db.meta('mail_last_uid'), '41');
    await poller.checkNow();
    expect(sawAfter, 41);
    final dump = db.select('SELECT key, value FROM meta').map((r) => r.s('value')).join(' ');
    expect(dump, isNot(contains('abcdefghijklmnop')));
    await tmp.delete(recursive: true);
  });

  test('filing an inbox email on a workstation: syncs, and the main PC copies it into the job folder', () async {
    final tmp = await Directory.systemTemp.createTemp('mailsync');
    final hub = AppDb.memory(isHub: true);
    seedSettings(hub);
    final owner = createUser(hub, name: 'Owner', role: 'owner', pin: '1111');
    hub.currentUserId = owner;
    final hubFiles = FileStore(hub, '${tmp.path}/hub');
    final server = HubServer(hub, hubFiles);
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    final cid = saveCustomer(hub, {'name': 'Jane', 'address': '8 Elm St'});
    final pid = createProject(hub, customerId: cid, title: 'Kitchen');
    final id = ingestEmail(hub, hubFiles, mail('measure for 8 elmm st'))!; // typo: not matched
    expect(hub.get('mail_inbox', id)!.s('status'), 'unmatched');

    final ws = AppDb.memory(isHub: false);
    final wsFiles = FileStore(ws, '${tmp.path}/ws');
    final client = SyncClient(ws, wsFiles);
    await client.pair(server.pairingPayload(server.createPairingCode(owner), ['127.0.0.1']), deviceName: 'ws');
    await client.sync();
    final att = mailAttachments(ws.get('mail_inbox', id)!).first;
    final local = await client.fetchBlob(att['sha256'] as String); // preview before filing
    expect(File(local).existsSync(), isTrue);
    fileMailItem(ws, wsFiles, id, pid);
    await client.sync();

    expect(hub.get('mail_inbox', id)!.s('status'), 'filed');
    final f = hub.select("SELECT * FROM files WHERE project_id=? AND deleted=0", [pid]);
    expect(f, hasLength(2));
    for (final r in f) {
      expect(hubFiles.localPath(r.s('sha256')), contains('Projects'));
    }
    await server.stop();
    await tmp.delete(recursive: true);
  });
}
