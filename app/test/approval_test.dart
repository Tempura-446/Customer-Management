import 'dart:typed_data';

import 'package:cabinet_crm/core/approval.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/mail/mail_poller.dart';
import 'package:cabinet_crm/mail/smtp_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String pid;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    db.currentUserId = createUser(db, name: 'Owner', role: 'owner', pin: '1111');
    setSetting(db, 'business_name', 'Maple & Oak');
    pid = createProject(db, customerId: saveCustomer(db, {'name': 'Jane Smith', 'email': 'jane@example.com'}), title: 'Kitchen');
  });

  test('sent, then approved; sending again needs a new approval', () {
    markSentForApproval(db, pid, to: 'jane@example.com');
    var p = db.get('projects', pid)!;
    expect(p.s('approval_sent_on'), today());
    expect(p.ns('approved_on'), isNull);
    expect(() => recordApproval(db, pid, by: '  '), throwsA(isA<BusinessError>()));
    recordApproval(db, pid, by: 'Jane Smith', on: '2026-11-08');
    p = db.get('projects', pid)!;
    expect((p.s('approved_by'), p.s('approved_on')), ('Jane Smith', '2026-11-08'));
    markSentForApproval(db, pid, to: 'jane@example.com');
    expect(db.get('projects', pid)!.ns('approved_on'), isNull);
    clearApproval(db, pid);
    expect(db.select("SELECT body FROM notes WHERE project_id=? AND body LIKE '%approval%'", [pid]).length, greaterThanOrEqualTo(3));
  });

  test('recording approval can accept the sent quote', () {
    final q = createQuote(db, pid);
    saveQuote(db, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 100)]);
    sendQuote(db, q);
    recordApproval(db, pid, by: 'Jane', acceptQuoteId: q);
    expect(db.get('quotes', q)!.s('status'), 'accepted');
  });

  test('waiting approvals become a follow-up next action after the follow-up days', () {
    markSentForApproval(db, pid, to: 'jane@example.com');
    expect(approvalsWaiting(db), isEmpty);
    db.update('projects', pid, {'approval_sent_on': dateOnly(DateTime.now().subtract(const Duration(days: 9)))});
    expect(approvalsWaiting(db).single.id, pid);
    expect(nextActions(db).any((a) => a.projectId == pid && a.text.contains('no approval yet')), isTrue);
    expect(nextActions(db, prices: false).any((a) => a.text.contains('no approval yet')), isFalse);
    recordApproval(db, pid, by: 'Jane');
    expect(approvalsWaiting(db), isEmpty);
  });

  test('email text, recipients and SMTP host', () {
    final (subject, body) = approvalEmailText(db, pid);
    expect(subject, contains('kitchen project'));
    expect(body, startsWith('Hi Jane,'));
    expect(body, contains('Maple & Oak'));
    expect(parseRecipients('a@x.com; b@y.org ,c@z.co'), ['a@x.com', 'b@y.org', 'c@z.co']);
    expect(() => parseRecipients(''), throwsArgumentError);
    expect(() => parseRecipients('jane at example'), throwsArgumentError);
    expect(smtpHostFor('imap.gmail.com'), 'smtp.gmail.com');
    expect(smtpHostFor('mail.shop.com'), 'mail.shop.com');
  });

  test('message has the PDF attached and goes to every recipient', () {
    final m = buildMessage(OutgoingMail(
        fromName: 'Maple & Oak',
        fromEmail: 'shop@example.com',
        to: ['jane@example.com', 'bob@example.com'],
        subject: 'Approve',
        text: 'Hello',
        attachments: [('J-2026-001_Job-summary.pdf', Uint8List.fromList([37, 80, 68, 70]))]));
    expect(m.recipientAddresses, ['jane@example.com', 'bob@example.com']);
    expect(m.decodeSubject(), 'Approve');
    final atts = m.findContentInfo();
    expect(atts.single.fileName, 'J-2026-001_Job-summary.pdf');
    expect(atts.single.contentType?.mediaType.text, 'application/pdf');
  });

  test('the mailbox sends with the saved app password and the derived SMTP server', () async {
    final sent = <(String, int, String, OutgoingMail)>[];
    final secrets = MemorySecretStore();
    final mail = MailPoller(db, FileStore(db, '/tmp/unused'), secrets: secrets,
        sender: (m, {required host, required port, required user, required password}) async {
      expect(password, 'abcdabcdabcdabcd');
      sent.add((host, port, user, m));
    });
    expect(await mail.canSend(), isFalse);
    await expectLater(mail.send(to: ['x@y.com'], subject: 's', text: 't'), throwsException);
    await mail.save(
        enabled: false, host: 'imap.gmail.com', port: 993, user: 'shop@example.com', password: 'abcd abcd abcd abcd',
        folder: 'INBOX', pollMinutes: 5, sinceDays: 14);
    mail.stop();
    expect(await mail.canSend(), isTrue, reason: 'sending works even when reading the mailbox is off');
    await mail.send(to: ['jane@example.com'], subject: 'Approve', text: 'Hi', fromName: 'Maple & Oak');
    expect((sent.single.$1, sent.single.$2, sent.single.$3), ('smtp.gmail.com', 465, 'shop@example.com'));
    mail.saveSmtp(host: 'smtp.office365.com', port: 587);
    expect((mail.smtpHost, mail.smtpPort), ('smtp.office365.com', 587));
    mail.saveSmtp(host: 'smtp.gmail.com', port: 465);
    expect(db.meta('mail_smtp_host'), isNull, reason: 'the default is not stored, so it follows the IMAP server');
  });
}
