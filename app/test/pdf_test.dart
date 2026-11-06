import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/pdf/documents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quote and invoice PDFs render', () async {
    final db = AppDb.memory(isHub: true);
    seedSettings(db);
    final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '1 Main St', 'phone': '555'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen');
    final did = saveDesign(db, projectId: pid, title: 'L-shape');
    final qid = createQuote(db, pid, designId: did);
    saveQuote(db, qid, designId: did, taxRate: 13, discount: 50, depositPct: 50, notes: 'White shaker', lines: [
      QuoteLine(category: 'Cabinets', description: 'Shaker boxes', qty: 14, unitPrice: 400),
      QuoteLine(category: 'Installation', description: 'Install', qty: 1, unitPrice: 2400),
    ]);
    sendQuote(db, qid);
    acceptQuote(db, qid);
    final dep = createInvoice(db, qid, kind: 'deposit', amount: suggestedInvoiceAmount(db, qid, 'deposit'));
    addPayment(db, dep, amount: 1000);
    final fin = createInvoice(db, qid, kind: 'final', amount: suggestedInvoiceAmount(db, qid, 'final'));

    for (final bytes in [await quotePdf(db, qid), await invoicePdf(db, dep), await invoicePdf(db, fin)]) {
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      expect(bytes.length, greaterThan(1000));
    }
  });
}
