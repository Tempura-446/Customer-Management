import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/pdf/documents.dart';
import 'package:flutter_test/flutter_test.dart';

final png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

void main() {
  late Directory tmp;
  late AppDb db;
  late FileStore files;
  late String pid;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('packet');
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    files = FileStore(db, tmp.path);
    final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '1 Main St', 'phone': '555-1'});
    pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'pickup');
    saveSelections(db, pid, [
      SelectionLine('Cabinets', 'Door style', 'Shaker, 3/4" MDF'),
      SelectionLine('Cabinets', 'Finish / colour', 'Painted, Chantilly Lace'),
      SelectionLine('Hardware', 'Pulls / knobs', '5" bar pull, matte black', '28 pcs'),
      SelectionLine('Appliances', 'Range / cooktop', ''), // empty: not kept
    ]);
    final mid = saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'customer',
        lines: [MeasureLine('Wall A length', '144', 'in')]);
    files.addBytes(projectId: pid, bytes: Uint8List.fromList(png), name: 'wall.png', category: 'photos',
        entityType: 'measurement', entityId: mid);
    final did = saveDesign(db, projectId: pid, title: 'L-shape', measurementId: mid);
    files.addBytes(projectId: pid, bytes: Uint8List.fromList(utf8.encode('%PDF fake drawing')), name: 'plan.pdf',
        category: 'designs', entityType: 'design', entityId: did);
    final q = createQuote(db, pid, designId: did);
    saveQuote(db, q, designId: did, taxRate: 13, discount: 0, depositPct: 50,
        lines: [QuoteLine(category: 'Cabinets', description: 'Shaker maple boxes', unitPrice: 11850)]);
    sendQuote(db, q);
    acceptQuote(db, q);
    final inv = createInvoice(db, q, kind: 'deposit', amount: suggestedInvoiceAmount(db, q, 'deposit'));
    addPayment(db, inv, amount: 1000);
    addNote(db, pid, 'Customer picks up Friday', kind: 'call');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<String> build(PacketOptions o, {List<String>? rasterized}) async {
    final bytes = await jobPacketPdf(db, pid, o,
        compress: false,
        load: (f) async => File(files.localPath(f.s('sha256'))!).readAsBytes(),
        rasterize: (pdf) async {
          rasterized?.add(utf8.decode(pdf));
          return [Uint8List.fromList(png)];
        });
    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
    // Text is written one word per [(...)]TJ operator: join the words back together.
    return RegExp(r'\[\((.*?)\)\]TJ')
        .allMatches(latin1.decode(bytes))
        .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'))
        .join(' ');
  }

  test('selections are saved, empty lines dropped', () {
    final sel = selectionsFor(db, pid);
    expect(sel.map((r) => r.s('item')), ['Door style', 'Finish / colour', 'Pulls / knobs']);
  });

  test('customer packet: selections, price, pickup sign-off', () async {
    final raster = <String>[];
    final text = await build(PacketOptions.customer(), rasterized: raster);
    expect(text, contains('Shaker, 3/4" MDF'));
    expect(text, contains('Chantilly Lace'));
    expect(text, contains('\$13,390.50')); // 11850 * 1.13
    expect(text, contains('pickup order: I confirm the measurements are correct'));
    expect(raster, ['%PDF fake drawing'], reason: 'design PDF pages are rendered into the packet');
  });

  test('production packet never shows prices', () async {
    final text = await build(PacketOptions.production());
    expect(text, contains('Shaker maple boxes'));
    expect(text, contains('Wall A length'));
    expect(text, contains('Customer picks up Friday'));
    expect(text, isNot(contains('\$')));
    expect(text, contains('CHECK BEFORE ORDERING'));
  });

  test('office file includes payments', () async {
    final text = await build(PacketOptions.office());
    expect(text, contains('Balance owing'));
  });
}
