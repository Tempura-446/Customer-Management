part of 'documents.dart';

/// Purchase order to send to the supplier (no prices: those come from the supplier / QuickBooks).
Future<Uint8List> purchaseOrderPdf(AppDb db, String poId) async {
  final s = settings(db);
  final po = orderWithSupplier(db, poId)!;
  final p = projectWithCustomer(db, po.s('project_id'))!;
  final items = poItems(db, poId);
  final toSite = po.s('deliver_to') == 'site';
  final doc = pw.Document(title: 'Purchase order ${poLabel(po)}', theme: _theme());

  pw.Widget block(String label, List<String> lines) => pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(label.toUpperCase(), style: const pw.TextStyle(fontSize: 8, color: _grey)),
          if (lines.isNotEmpty) pw.Text(lines.first, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          for (final l in lines.skip(1).where((l) => l.trim().isNotEmpty)) pw.Text(l),
        ]),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.all(36),
    header: (c) => c.pageNumber == 1
        ? _letterhead(s, 'PURCHASE ORDER', [
            ('PO #', poLabel(po)),
            ('Date', po.ns('ordered_on') ?? today()),
            ('Our job', numberOf(p)),
            if (po.ns('expected_on') != null) ('Needed by', po.s('expected_on')),
          ])
        : pw.SizedBox(),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(color: _grey, fontSize: 9))),
    build: (c) => [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 14),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          block('Supplier', [
            po.s('supplier'),
            if (po.ns('supplier_contact') != null) 'Attn: ${po.s('supplier_contact')}',
            po.s('supplier_address'),
            [po.s('supplier_phone'), po.s('supplier_email')].where((x) => x.isNotEmpty).join('   '),
            if (po.ns('supplier_account') != null) 'Account: ${po.s('supplier_account')}',
          ]),
          pw.SizedBox(width: 30),
          block(toSite ? 'Ship to (job site)' : 'Deliver to', toSite
              ? [p.s('customer'), p.s('site_address'), p.s('phone'), 'Ref: ${numberOf(p)} ${p.s('title')}']
              : [s['business_name'] ?? '', s['business_address'] ?? '', s['business_phone'] ?? '', 'Ref: ${numberOf(p)} ${p.s('customer')}']),
        ]),
      ),
      pw.Table(columnWidths: const {
        0: pw.FixedColumnWidth(50),
        1: pw.FlexColumnWidth(4),
        2: pw.FlexColumnWidth(2),
      }, children: [
        _headRow(['Qty', 'Description', 'Notes'], {0}),
        for (final it in items)
          pw.TableRow(decoration: _rowBorder, children: [
            _cell(fmtQty(it.d('qty')), right: true),
            _cell(it.s('description')),
            _cell(it.s('notes')),
          ]),
      ]),
      ..._textBlock('Notes', po.ns('notes')),
      if (po.ns('supplier_ref') != null) ..._textBlock('Your reference', po.s('supplier_ref')),
      pw.SizedBox(height: 20),
      pw.Text('Please confirm this order and the delivery date. Quote PO # ${poLabel(po)} on all paperwork.',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
    ],
  ));
  return doc.save();
}
