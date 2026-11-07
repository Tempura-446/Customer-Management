import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/branding.dart';
import '../core/db.dart';
import '../core/checklist.dart';
import '../core/logic.dart';
import '../core/orders.dart';
import '../qb/qb_sync.dart';
import '../services.dart';
import '../ui/widgets/common.dart';
import 'zpdf.dart';

part 'packet.dart';
part 'po_pdf.dart';

// ============================================================================ shared layout

const _grey = PdfColor.fromInt(0xFF666666);
const _light = PdfColor.fromInt(0xFFF3F3F3);

pw.Widget _letterhead(Map<String, String> s, String title, List<(String, String)> meta) {
  final logo = businessLogo(s);
  pw.Widget? logoWidget;
  if (logo != null) {
    try {
      logoWidget = pw.Container(
        margin: const pw.EdgeInsets.only(right: 14),
        constraints: const pw.BoxConstraints(maxWidth: 170, maxHeight: 64),
        child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
      );
    } catch (_) {
      logoWidget = null; // unreadable logo: print without it
    }
  }
  return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 2.5))),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        ?logoWidget,
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            // The logo may already spell out the name (Settings: "My logo already shows our name").
            if (logoWidget == null || s['logo_has_name'] != '1')
              pw.Text(s['business_name'] ?? '', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
            if ((s['business_address'] ?? '').isNotEmpty) pw.Text(s['business_address']!, style: const pw.TextStyle(color: _grey)),
            pw.Text([s['business_phone'], s['business_email']].where((x) => (x ?? '').isNotEmpty).join('   '),
                style: const pw.TextStyle(color: _grey)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, letterSpacing: 3)),
          pw.SizedBox(height: 4),
          for (final (k, v) in meta)
            pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
              pw.Text('$k  ', style: const pw.TextStyle(color: _grey)),
              pw.Text(v),
            ]),
        ]),
      ]),
    );
}

pw.Widget _billTo(Rec p) {
  pw.Widget block(String label, List<String> lines) => pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(label.toUpperCase(), style: const pw.TextStyle(fontSize: 8, color: _grey)),
          pw.Text(lines.first, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          for (final l in lines.skip(1).where((l) => l.trim().isNotEmpty)) pw.Text(l),
        ]),
      );
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 14),
    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      block('Customer', [p.s('customer'), p.s('customer_address'), [p.s('phone'), p.s('email')].join('  ')]),
      pw.SizedBox(width: 30),
      block('Project', [
        p.s('title'),
        ...switch (orderTypeOf(p.ns('order_type'))?.key) {
          'pickup' => ['Order: material pickup only', 'Pickup at our shop'],
          'shipping' => ['Order: shipping', 'Ship to: ${p.s('site_address')}'],
          'install' => ['Order: supply & installation', 'Install at: ${p.s('site_address')}'],
          _ => [p.s('site_address')],
        },
        'Job ${numberOf(p)}',
      ]),
    ]),
  );
}

pw.Widget _totalsTable(List<(String, String, bool)> rows) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.SizedBox(
        width: 260,
        child: pw.Column(children: [
          for (final (k, v, grand) in rows)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              decoration: grand ? const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 1.5))) : null,
              child: pw.Row(children: [
                pw.Expanded(child: pw.Text(k, style: grand ? pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13) : null)),
                pw.Text(v, style: grand ? pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13) : null),
              ]),
            ),
        ]),
      ),
    );

List<pw.Widget> _textBlock(String title, String? body) => (body ?? '').trim().isEmpty
    ? []
    : [
        pw.SizedBox(height: 14),
        pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.Text(body!.trim()),
      ];

pw.Widget _cell(String t, {bool right = false, bool bold = false, PdfColor? color}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: pw.Text(t,
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
          style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : null, color: color)),
    );

pw.TableRow _headRow(List<String> cols, Set<int> right) => pw.TableRow(
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 1.5))),
      children: [for (var i = 0; i < cols.length; i++) _cell(cols[i], right: right.contains(i), bold: true)],
    );

const _rowBorder = pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.5, color: PdfColors.grey300)));

pw.ThemeData _theme() => pw.ThemeData.withFont(base: pw.Font.helvetica(), bold: pw.Font.helveticaBold());

String _m(num v) => fmtMoney(v);

// ============================================================================ quote

Future<Uint8List> quotePdf(AppDb db, String quoteId) async {
  final q = db.get('quotes', quoteId)!;
  final p = projectWithCustomer(db, q.s('project_id'))!;
  final s = settings(db);
  final t = quoteTotals(db, quoteId);
  final d = db.get('designs', q.ns('design_id'));
  final rev = q.i('revision');

  final rows = <pw.TableRow>[_headRow(['Description', 'Qty', 'Unit', 'Amount'], {1, 2, 3})];
  String? cat;
  for (final it in t.items) {
    final c = it.ns('category') ?? 'Other';
    if (c != cat) {
      cat = c;
      rows.add(pw.TableRow(
          decoration: const pw.BoxDecoration(color: _light),
          children: [_cell(c, bold: true), pw.SizedBox(), pw.SizedBox(), pw.SizedBox()]));
    }
    rows.add(pw.TableRow(decoration: _rowBorder, children: [
      _cell(it.s('description')),
      _cell(fmtQty(it.d('qty')), right: true),
      _cell(_m(it.d('unit_price')), right: true),
      _cell(_m(it.d('qty') * it.d('unit_price')), right: true),
    ]));
  }

  final doc = pw.Document(title: 'Quote ${quoteLabel(q)} ${p.s('customer')}', theme: _theme());
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.all(40),
    build: (_) => [
      _letterhead(s, 'QUOTE', [
        ('Quote #', '${numberOf(q)}${rev > 1 ? ' rev $rev' : ''}'),
        ('Date', fmtDate(q.ns('sent_on') ?? q.s('created_at'))),
        ('Valid until', fmtDate(q.ns('valid_until'))),
        if (d != null) ('Design', 'v${d.i('version')}'),
      ]),
      _billTo(p),
      pw.Table(
        columnWidths: const {
          0: pw.FlexColumnWidth(5), 1: pw.FlexColumnWidth(1), 2: pw.FlexColumnWidth(1.6), 3: pw.FlexColumnWidth(1.6),
        },
        children: rows,
      ),
      pw.SizedBox(height: 10),
      _totalsTable([
        ('Subtotal', _m(t.subtotal), false),
        if (t.discount > 0) ('Discount', '-${_m(t.discount)}', false),
        ('Tax (${fmtQty(q.d('tax_rate'))}%)', _m(t.tax), false),
        ('Total', _m(t.total), true),
        ('Deposit due on acceptance (${fmtQty(q.d('deposit_pct'))}%)', _m(t.deposit), false),
      ]),
      ..._textBlock('Notes', q.ns('notes')),
      ..._textBlock('Terms', q.ns('terms')),
      pw.SizedBox(height: 50),
      pw.Row(children: [
        for (final l in ['Customer signature', 'Date']) ...[
          pw.Expanded(
            child: pw.Container(
              padding: const pw.EdgeInsets.only(top: 4),
              decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 1))),
              child: pw.Text(l, style: const pw.TextStyle(fontSize: 9, color: _grey)),
            ),
          ),
          pw.SizedBox(width: 30),
        ],
      ]),
    ],
  ));
  return doc.save();
}

// ============================================================================ invoice

Future<Uint8List> invoicePdf(AppDb db, String invoiceId) async {
  final i = db.get('invoices', invoiceId)!;
  final q = db.one('SELECT * FROM quotes WHERE id=?', [i.s('quote_id')])!;
  final p = projectWithCustomer(db, i.s('project_id'))!;
  final s = settings(db);
  final t = quoteTotals(db, q.id);
  final prior = db.select(
      "SELECT * FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void' AND id<>? AND created_at < ? ORDER BY created_at",
      [q.id, invoiceId, i.s('created_at')]);
  final paid = invoicePaid(db, invoiceId);
  final balance = money(i.d('amount') - paid);
  final kindLabel = switch (i.s('kind')) {
    'deposit' => 'Deposit (${fmtQty(q.d('deposit_pct'))}%)',
    'progress' => 'Progress payment',
    _ => 'Final balance',
  };

  final rows = <pw.TableRow>[
    _headRow(['Description', 'Amount'], {1}),
    pw.TableRow(decoration: _rowBorder, children: [
      _cell('Contract total per quote ${quoteLabel(q)} (incl. tax)'),
      _cell(_m(t.total), right: true),
    ]),
    for (final pi in prior)
      pw.TableRow(decoration: _rowBorder, children: [
        _cell('Previously invoiced: ${numberOf(pi)} (${pi.s('kind')})', color: _grey),
        _cell(_m(pi.d('amount')), right: true, color: _grey),
      ]),
    pw.TableRow(decoration: _rowBorder, children: [
      pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(kindLabel, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          if ((i.ns('notes') ?? '').isNotEmpty) pw.Text(i.s('notes')),
        ]),
      ),
      _cell(_m(i.d('amount')), right: true, bold: true),
    ]),
  ];

  final doc = pw.Document(title: 'Invoice ${numberOf(i)} ${p.s('customer')}', theme: _theme());
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.all(40),
    build: (_) => [
      _letterhead(s, 'INVOICE', [
        ('Invoice #', numberOf(i)),
        ('Date', fmtDate(i.ns('issued_on') ?? i.s('created_at'))),
        ('Due', fmtDate(i.ns('due_on'))),
        ('Quote', quoteLabel(q)),
      ]),
      _billTo(p),
      pw.Table(columnWidths: const {0: pw.FlexColumnWidth(5), 1: pw.FlexColumnWidth(1.6)}, children: rows),
      pw.SizedBox(height: 10),
      _totalsTable([
        ('This invoice', _m(i.d('amount')), false),
        if (paid > 0) ('Payments received', '-${_m(paid)}', false),
        ('Amount due', _m(balance), true),
      ]),
      ..._textBlock('Terms', q.ns('terms')),
    ],
  ));
  return doc.save();
}

// ============================================================================ preview / print / share / save

/// Bottom sheet with Print, Share and (on the PC) Save to project folder.
Future<void> showPdf(
  BuildContext context, {
  required Uint8List bytes,
  required String filename,
  String? projectId,
  String category = 'quotes',
  String? entityType,
  String? entityId,
}) async {
  final svc = context.svc;
  await showModalBottomSheet<void>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(filename), subtitle: const Text('PDF ready')),
        ListTile(
          leading: const Icon(Icons.print_outlined),
          title: const Text('Print / Save as PDF'),
          onTap: () async {
            Navigator.pop(c);
            await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
          },
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Share / email'),
          onTap: () async {
            Navigator.pop(c);
            await Printing.sharePdf(bytes: bytes, filename: filename);
          },
        ),
        if (svc.isHub && projectId != null)
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Save to project folder'),
            subtitle: Text('Projects/…/$category/$filename'),
            onTap: () async {
              Navigator.pop(c);
              await attempt(context, () async {
                svc.files.addBytes(
                    projectId: projectId, bytes: bytes, name: filename, category: category,
                    entityType: entityType, entityId: entityId);
              }, success: 'Saved $filename');
            },
          ),
      ]),
    ),
  );
}

String safeFilename(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').replaceAll(' ', '_');
