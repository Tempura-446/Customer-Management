import 'dart:convert';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/orders.dart';
import 'package:cabinet_crm/pdf/documents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String pid, sup;

  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '1 Main St'});
    pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'install');
    setStatus(db, pid, 'approved');
    saveSelections(db, pid, [
      SelectionLine('Cabinets', 'Door style', 'Shaker, maple'),
      SelectionLine('Hardware', 'Pulls / knobs', '5" bar pull', '28 pcs'),
    ]);
    sup = saveSupplier(db, {'name': 'Northern Cabinets', 'kind': 'Cabinets', 'lead_days': 21, 'phone': '555-9'});
  });

  test('order flow: draft -> ordered (expected from lead time) -> received -> job moves along', () {
    expect(nextActions(db).any((a) => a.kind == 'order' && a.projectId == pid), isTrue);

    final po = createPurchaseOrder(db, pid, supplierId: sup, lines: linesFromSelections(db, pid));
    final r = db.get('purchase_orders', po)!;
    expect(r.s('number'), matches(RegExp(r'^PO-\d{4}-001$')));
    expect(r.s('deliver_to'), 'shop');
    expect(poItems(db, po).map((i) => i.s('description')), ['Door style: Shaker, maple', 'Pulls / knobs: 5" bar pull']);

    markOrdered(db, po, orderedOn: '2026-11-01');
    expect(db.get('purchase_orders', po)!.s('expected_on'), '2026-11-22');
    expect(db.get('projects', pid)!.s('status'), 'ordered');
    expect(() => savePurchaseOrder(db, po, lines: [PoLine('x')]), throwsA(isA<BusinessError>()));

    // Part received: still ordered.
    final items = poItems(db, po);
    receiveItems(db, po, received: {items.first.id: 1});
    expect(db.get('purchase_orders', po)!.s('status'), 'ordered');
    receiveItems(db, po);
    expect(db.get('purchase_orders', po)!.s('status'), 'received');
    expect(db.get('projects', pid)!.s('status'), 'received');

    markCompleted(db, pid);
    expect(db.get('projects', pid)!.s('status'), 'completed');
  });

  test('job is Received only when every non-cancelled order has arrived', () {
    final a = createPurchaseOrder(db, pid, supplierId: sup, lines: [PoLine('Boxes')]);
    final b = createPurchaseOrder(db, pid, supplierId: sup, lines: [PoLine('Quartz top')]);
    markOrdered(db, a);
    markOrdered(db, b);
    receiveItems(db, a);
    expect(db.get('projects', pid)!.s('status'), 'ordered');
    cancelPurchaseOrder(db, b);
    expect(db.get('projects', pid)!.s('status'), 'received');
  });

  test('shipping jobs ship to site; overdue and no-date reminders; arriving soon', () {
    setOrderType(db, pid, 'shipping');
    final po = createPurchaseOrder(db, pid, supplierId: sup, lines: [PoLine('Boxes')]);
    expect(db.get('purchase_orders', po)!.s('deliver_to'), 'site');
    markOrdered(db, po, orderedOn: '2020-01-01', expectedOn: '2020-01-10');
    expect(nextActions(db).any((a) => a.kind == 'overdue' && a.text.contains(poLabel(db.get('purchase_orders', po)!))),
        isTrue);
    savePurchaseOrder(db, po, expectedOn: addDays(3));
    expect(arrivingSoon(db).single.id, po);
  });

  test('cannot order without a supplier or lines; drafts can be deleted', () {
    final po = createPurchaseOrder(db, pid);
    expect(() => markOrdered(db, po), throwsA(isA<BusinessError>()));
    savePurchaseOrder(db, po, supplierId: sup, lines: []);
    expect(() => markOrdered(db, po), throwsA(isA<BusinessError>()));
    deleteDraftOrder(db, po);
    expect(db.get('purchase_orders', po), isNull);
  });

  test('lines from a QuickBooks estimate when there is no Casework quote', () {
    db.insert('qb_estimates', {
      'project_id': pid, 'qb_txn_id': 'T-1', 'ref_number': '1001', 'total': 5000, 'accepted': 1,
      'lines': jsonEncode([
        {'item': 'CAB-SHAKER', 'desc': 'Shaker wall cabinets', 'qty': 6, 'rate': 400, 'amount': 2400},
      ]),
    });
    final lines = linesFromQuote(db, pid);
    expect(lines.single.description, 'Shaker wall cabinets');
    expect(lines.single.qty, 6);
  });

  test('purchase order PDF renders', () async {
    final po = createPurchaseOrder(db, pid, supplierId: sup, lines: linesFromSelections(db, pid));
    final bytes = await purchaseOrderPdf(db, po);
    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
  });
}
