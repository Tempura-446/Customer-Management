// Fills a data folder with demo jobs so you can click around:
//   CABINET_CRM_DATA=/some/folder flutter test tool/seed_demo_test.dart
//   CABINET_CRM_DATA=/some/folder flutter run -d windows
// Owner PIN is 1234.
import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/mail/mail_ingest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('seed demo data', () {
    final root = Platform.environment['CABINET_CRM_DATA'];
    if (root == null) {
      markTestSkipped('Set CABINET_CRM_DATA');
      return;
    }
    final db = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: true);
    final files = FileStore(db, root);
    seedSettings(db);
    setSetting(db, 'business_name', 'Maple & Oak Cabinetry');
    setSetting(db, 'default_tax_rate', '13');
    final owner = createUser(db, name: 'Alex (owner)', role: 'owner', pin: '1234');
    createUser(db, name: 'Sam (installer)', role: 'field', pin: '5555');
    db.currentUserId = owner;

    String job(String name, String phone, String addr, String title) {
      final c = saveCustomer(db, {'name': name, 'phone': phone, 'address': addr, 'source': 'Referral'});
      return createProject(db, customerId: c, title: title);
    }

    String measure(String pid, {String source = 'onsite'}) => saveMeasurement(db,
        projectId: pid, room: {'photo': 'Pantry', 'plans': 'Mudroom'}[source] ?? 'Kitchen', source: source, takenBy: 'Alex', takenOn: today(),
        notes: 'Wall A out of square by 1/4". Soffit over sink.',
        lines: [
          MeasureLine('Wall A length', '144', 'in'),
          MeasureLine('Wall B length', '118 1/4', 'in'),
          MeasureLine('Ceiling height', '96', 'in'),
          MeasureLine('Window 1 (W x H, from left, sill height)', '36 x 42, 30, 42', 'in'),
        ]);

    String design(String pid, String mid, String title) {
      final d = saveDesign(db, projectId: pid, title: title, measurementId: mid, status: 'presented');
      files.addBytes(projectId: pid, bytes: Uint8List.fromList(List.filled(2048, 7)), name: 'design_v1.kit',
          category: 'designs', entityType: 'design', entityId: d);
      return d;
    }

    String quote(String pid, String did) {
      final q = createQuote(db, pid, designId: did);
      saveQuote(db, q, designId: did, taxRate: 13, discount: 0, depositPct: 50, validUntil: addDays(30),
          notes: 'Includes crown moulding and light rail.', terms: settings(db)['default_terms'], lines: [
        QuoteLine(category: 'Cabinets', description: 'Shaker maple, white paint: 14 boxes', unitPrice: 11850),
        QuoteLine(category: 'Countertops', description: 'Quartz, 52 sq ft, eased edge', qty: 52, unitPrice: 85),
        QuoteLine(category: 'Hardware', description: 'Soft-close pulls', qty: 28, unitPrice: 9.5),
        QuoteLine(category: 'Installation', description: 'Install & levelling', unitPrice: 2400),
      ]);
      sendQuote(db, q);
      return q;
    }

    job('Lisa Chen', '555-201-3344', '12 Oak Ave', 'Laundry room');
    var pid = job('Mark Rivera', '555-339-1100', '88 Pine Rd', 'Kitchen remodel');
    measure(pid, source: 'customer');
    pid = job('Smith Family', '555-410-2020', '4 Elm St', 'Kitchen');
    design(pid, measure(pid), 'L-shape w/ island');
    measure(pid, source: 'photo');
    measure(pid, source: 'plans');
    pid = job('Priya Patel', '555-777-8080', '19 Birch Ln', 'Kitchen + pantry');
    quote(pid, design(pid, measure(pid), 'U-shape'));
    pid = job("Tom O'Neil", '555-123-4567', '301 Lake Dr', 'Kitchen');
    final q = quote(pid, design(pid, measure(pid, source: 'customer'), 'Galley'));
    acceptQuote(db, q);
    final inv = createInvoice(db, q, kind: 'deposit', amount: suggestedInvoiceAmount(db, q, 'deposit'));
    addPayment(db, inv, amount: 5000, method: 'Cheque', reference: '#1042');
    addNote(db, pid, 'Customer wants delivery after the 15th.', kind: 'call');

    // Two measurement emails from the shared mailbox: one matches a job, one doesn't.
    MailEnvelope email(String subject, String id) => MailEnvelope(
          messageId: id, subject: subject, from: 'Sam Installer <sam@mapleoak.example>', date: DateTime.now(),
          text: 'Measured today. Ceiling 96 1/2. Plumbing centre 34 from left wall.',
          attachments: [
            MailAttachment('Site measure.pdf', Uint8List.fromList('%PDF-1.4 demo $id'.codeUnits)),
            MailAttachment('IMG_2041.jpg', Uint8List.fromList(List.filled(60 * 1024, id.length)), inline: true),
          ]);
    ingestEmail(db, files, email('RE: 12 Oak Avenue - laundry measurements', '<demo1>'));
    ingestEmail(db, files, email('Measurements 230 Cedar Crescent', '<demo2>'));
    db.dispose();
  });
}
