import 'dart:typed_data';

import 'package:cabinet_crm/core/branding.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/orders.dart';
import 'package:cabinet_crm/pdf/documents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('logo is resized, shared via settings, and printed on every document', () async {
    final db = AppDb.memory(isHub: true);
    seedSettings(db);
    final cid = saveCustomer(db, {'name': 'Jane', 'address': '1 Main St'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'install');
    final q = createQuote(db, pid);
    saveQuote(db, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 1000)]);
    sendQuote(db, q);
    acceptQuote(db, q);
    final inv = createInvoice(db, q, kind: 'deposit', amount: 500);
    final sup = saveSupplier(db, {'name': 'Supplier'});
    final po = createPurchaseOrder(db, pid, supplierId: sup, lines: [PoLine('Boxes')]);

    Future<List<int>> sizes() async => [
          (await quotePdf(db, q)).length,
          (await invoicePdf(db, inv)).length,
          (await purchaseOrderPdf(db, po)).length,
          (await jobPacketPdf(db, pid, PacketOptions.office(), load: (_) async => null)).length,
        ];

    final without = await sizes();

    // A big, noisy logo (so it can't compress to nothing).
    final big = img.Image(width: 2400, height: 600);
    for (var y = 0; y < big.height; y++) {
      for (var x = 0; x < big.width; x++) {
        big.setPixelRgb(x, y, (x * 7 + y) % 256, (x * y) % 256, (y * 13) % 256);
      }
    }
    setBusinessLogo(db, Uint8List.fromList(img.encodePng(big)));
    final stored = img.decodePng(businessLogo(settings(db))!)!;
    expect(stored.width, 900, reason: 'resized to fit 900 x 360');
    expect(stored.height, 225);

    final withLogo = await sizes();
    for (var i = 0; i < without.length; i++) {
      expect(withLogo[i], greaterThan(without[i] + 10000), reason: 'document $i should contain the logo image');
    }

    expect(() => setBusinessLogo(db, Uint8List.fromList([1, 2, 3])), throwsA(isA<BusinessError>()));
    removeBusinessLogo(db);
    expect(businessLogo(settings(db)), isNull);
  });
}
