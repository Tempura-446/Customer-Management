part of 'documents.dart';

/// What goes into a job packet.
class PacketOptions {
  PacketOptions({
    this.title = 'JOB PACKET',
    this.prices = true,
    this.warnings = true,
    this.selections = true,
    this.measurements = true,
    this.photos = true,
    this.drawings = true,
    this.quote = true,
    this.payments = true,
    this.notes = true,
    this.signoff = true,
    this.maxPhotos = 12,
  });

  String title;
  bool prices, warnings, selections, measurements, photos, drawings, quote, payments, notes, signoff;
  int maxPhotos;

  /// For the customer to review and sign: selections, drawings, price.
  factory PacketOptions.customer() => PacketOptions(
      title: 'JOB SUMMARY', warnings: false, photos: false, notes: false, payments: true);

  /// For the shop / installers: everything needed to build and install, no prices.
  factory PacketOptions.production() => PacketOptions(
      title: 'PRODUCTION PACKET', prices: false, payments: false, signoff: false);

  /// Everything, for the office file.
  factory PacketOptions.office() => PacketOptions(title: 'JOB FILE', signoff: false);
}

/// Loads a stored file's bytes (on phones/workstations it may need downloading first).
typedef FileLoader = Future<Uint8List?> Function(Rec file);

/// Turns a PDF (e.g. a 2020 drawing export) into page images. Injected so tests can skip it.
typedef PdfRasterizer = Future<List<Uint8List>> Function(Uint8List pdf);

Future<List<Uint8List>> _rasterize(Uint8List pdf) async {
  final out = <Uint8List>[];
  await for (final page in Printing.raster(pdf, dpi: 110)) {
    out.add(await page.toPng());
    if (out.length >= 12) break; // keep the packet a sensible size
  }
  return out;
}

bool _pdfImageOk(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png');
}

/// Build the job packet PDF.
Future<Uint8List> jobPacketPdf(AppDb db, String projectId, PacketOptions o,
    {required FileLoader load, PdfRasterizer? rasterize, bool compress = true}) async {
  rasterize ??= _rasterize;
  final s = settings(db);
  final p = projectWithCustomer(db, projectId)!;
  final ot = orderTypeOf(p.ns('order_type'));
  final doc = pw.Document(title: '${o.title} ${numberOf(p)} ${p.s('customer')}', theme: _theme(), compress: compress);
  final body = <pw.Widget>[];

  pw.Widget h(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 16, bottom: 6),
        child: pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          color: _light,
          child: pw.Text(t.toUpperCase(), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
        ),
      );
  pw.Widget kv(List<(String, String)> rows) => pw.Table(columnWidths: const {
        0: pw.FixedColumnWidth(120),
        1: pw.FlexColumnWidth(),
      }, children: [
        for (final (k, v) in rows.where((r) => r.$2.trim().isNotEmpty))
          pw.TableRow(children: [_cell(k, color: _grey), _cell(v)]),
      ]);

  // ---------------------------------------------------------------- summary
  final designs = db.select('SELECT * FROM designs WHERE project_id=? AND deleted=0 ORDER BY version DESC', [projectId]);
  final design = designs.where((d) => d.s('status') == 'approved').firstOrNull ?? designs.firstOrNull;
  final quote = acceptedQuote(db, projectId) ??
      db.one("SELECT * FROM quotes WHERE project_id=? AND deleted=0 AND status IN ('sent','draft') "
          'ORDER BY updated_at DESC LIMIT 1', [projectId]);
  final totals = quote == null ? null : quoteTotals(db, quote.id);
  body.add(_billTo(p));
  body.add(kv([
    ('Order type', ot?.label ?? 'Not decided'),
    ('Status', stageLabel(p.s('status'))),
    ('Design', design == null ? '' : 'v${design.i('version')} ${design.s('title')} (${design.s('status')})'),
    ('Quote', quote == null ? '' : '${quoteLabel(quote)} (${quote.s('status')})${o.prices && totals != null ? ' · ${_m(totals.total)}' : ''}'),
    ('Contact', [p.s('phone'), p.s('email')].where((x) => x.isNotEmpty).join('   ')),
  ]));

  if (o.warnings) {
    final w = projectWarnings(db, projectId, prices: o.prices);
    if (w.isNotEmpty) {
      body.add(pw.Container(
        margin: const pw.EdgeInsets.only(top: 12),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.orange700), color: PdfColors.orange50),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('CHECK BEFORE ORDERING', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.orange900)),
          for (final x in w) pw.Bullet(text: x.message),
        ]),
      ));
    }
  }

  // ---------------------------------------------------------------- selections
  if (o.selections) {
    final sel = selectionsFor(db, projectId);
    body.add(h('Selections'));
    if (sel.isEmpty) {
      body.add(pw.Text('No selections recorded yet.', style: const pw.TextStyle(color: _grey)));
    } else {
      final cats = <String, List<Rec>>{};
      for (final r in sel) {
        (cats[r.s('category')] ??= []).add(r);
      }
      body.add(pw.Table(columnWidths: const {
        0: pw.FixedColumnWidth(150),
        1: pw.FlexColumnWidth(2),
        2: pw.FlexColumnWidth(1.4),
      }, children: [
        _headRow(['Item', 'Selection', 'Notes'], {}),
        for (final MapEntry(key: cat, value: rows) in cats.entries) ...[
          pw.TableRow(decoration: const pw.BoxDecoration(color: _light), children: [
            _cell(cat, bold: true), _cell(''), _cell(''),
          ]),
          for (final r in rows)
            pw.TableRow(decoration: _rowBorder, children: [
              _cell(r.s('item'), color: _grey),
              _cell(r.s('choice'), bold: true),
              _cell(r.s('notes')),
            ]),
        ],
      ]));
    }
  }

  // ---------------------------------------------------------------- measurements
  final meas = db.select('SELECT * FROM measurements WHERE project_id=? AND deleted=0 ORDER BY created_at', [projectId]);
  if (o.measurements && meas.isNotEmpty) {
    body.add(h('Measurements'));
    for (final m in meas) {
      final src = sourceOf(m.s('source'));
      final verified = !src.needsVerify || m.b('verified');
      final items = measurementItems(db, m.id);
      // Keep each measurement set on one page (short sets) so headings don't get separated.
      final keep = items.length <= 30;
      final block = pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.only(left: 8),
        decoration: pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: PdfColor.fromInt(src.color), width: 4))),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Row(children: [
            pw.Text(m.s('room'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
            pw.SizedBox(width: 8),
            pw.Text(src.label, style: pw.TextStyle(color: PdfColor.fromInt(src.color), fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(width: 8),
            pw.Text(verified ? (src.needsVerify ? 'verified ${m.s('verified_on')}' : '') : 'NOT VERIFIED',
                style: pw.TextStyle(color: verified ? PdfColors.green800 : PdfColors.red800, fontWeight: pw.FontWeight.bold)),
          ]),
          pw.Text([if (m.ns('taken_by') != null) 'by ${m.s('taken_by')}', m.ns('taken_on') ?? fmtDate(m.s('created_at'))].join(' · '),
              style: const pw.TextStyle(color: _grey, fontSize: 9)),
          if (items.isNotEmpty)
            pw.Table(columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)}, children: [
              for (final it in items)
                pw.TableRow(decoration: _rowBorder, children: [
                  _cell(it.s('label')),
                  _cell(it.ns('value') == null ? '-' : '${it.s('value')} ${it.s('unit')}', bold: true),
                ]),
            ]),
          if (m.ns('notes') != null) pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text(m.s('notes'))),
        ]),
      );
      body.add(keep ? pw.Inseparable(child: block) : block);
    }
  }

  // ---------------------------------------------------------------- design
  if (design != null) {
    body.add(h('Design v${design.i('version')}${design.ns('title') != null ? ' · ${design.s('title')}' : ''}'));
    body.add(kv([
      ('Status', design.s('status')),
      ('Date', fmtDate(design.s('created_at'))),
      ('Files', db.select("SELECT name FROM files WHERE entity_type='design' AND entity_id=? AND deleted=0", [design.id])
          .map((f) => f.s('name')).join(', ')),
    ]));
    if (design.ns('notes') != null) body.add(pw.Text(design.s('notes')));
  }

  // ---------------------------------------------------------------- quote / scope
  if (o.quote && quote != null && totals != null) {
    body.add(h(o.prices ? 'Quote ${quoteLabel(quote)}' : 'Scope of work (${quoteLabel(quote)})'));
    final cats = <String, List<Rec>>{};
    for (final it in totals.items) {
      (cats[it.ns('category') ?? 'Other'] ??= []).add(it);
    }
    body.add(pw.Table(
      columnWidths: o.prices
          ? const {0: pw.FlexColumnWidth(4), 1: pw.FixedColumnWidth(40), 2: pw.FixedColumnWidth(70), 3: pw.FixedColumnWidth(80)}
          : const {0: pw.FlexColumnWidth(4), 1: pw.FixedColumnWidth(50)},
      children: [
        _headRow(o.prices ? ['Description', 'Qty', 'Unit', 'Amount'] : ['Description', 'Qty'], o.prices ? {1, 2, 3} : {1}),
        for (final MapEntry(key: cat, value: rows) in cats.entries) ...[
          pw.TableRow(decoration: const pw.BoxDecoration(color: _light), children: [
            _cell(cat, bold: true), _cell(''), if (o.prices) ...[_cell(''), _cell('')],
          ]),
          for (final it in rows)
            pw.TableRow(decoration: _rowBorder, children: [
              _cell(it.s('description')),
              _cell(fmtQty(it.d('qty')), right: true),
              if (o.prices) ...[
                _cell(_m(it.d('unit_price')), right: true),
                _cell(_m(it.d('qty') * it.d('unit_price')), right: true),
              ],
            ]),
        ],
      ],
    ));
    if (o.prices) {
      body.add(_totalsTable([
        ('Subtotal', _m(totals.subtotal), false),
        if (totals.discount > 0) ('Discount', '-${_m(totals.discount)}', false),
        ('Tax (${fmtQty(quote.d('tax_rate'))}%)', _m(totals.tax), false),
        ('Total', _m(totals.total), true),
      ]));
    }
    body.addAll(_textBlock('Notes', quote.ns('notes')));
  }

  // ---------------------------------------------------------------- payments
  if (o.prices && o.payments && quote != null && quote.s('status') == 'accepted') {
    final b = quoteBilling(db, quote.id);
    final inv = db.select("SELECT * FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void' ORDER BY created_at", [quote.id]);
    body.add(h('Payments'));
    body.add(pw.Table(children: [
      _headRow(['Invoice', 'Type', 'Amount', 'Paid'], {2, 3}),
      for (final i in inv)
        pw.TableRow(decoration: _rowBorder, children: [
          _cell(numberOf(i)), _cell(i.s('kind')), _cell(_m(i.d('amount')), right: true),
          _cell(_m(invoicePaid(db, i.id)), right: true),
        ]),
    ]));
    body.add(_totalsTable([
      ('Contract', _m(b.total), false),
      ('Collected', _m(b.collected), false),
      ('Balance owing', _m(b.outstanding), true),
    ]));
  }

  // ---------------------------------------------------------------- notes
  if (o.notes) {
    final notes = db.select("SELECT n.*, u.name AS who FROM notes n LEFT JOIN users u ON u.id=n.updated_by "
        "WHERE n.project_id=? AND n.deleted=0 AND n.kind NOT IN ('system','money') ORDER BY n.created_at DESC LIMIT 40",
        [projectId]);
    if (notes.isNotEmpty) {
      body.add(h('Notes'));
      for (final n in notes) {
        body.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(
                width: 110,
                child: pw.Text('${fmtDate(n.s('created_at'))} ${n.s('kind')}', style: const pw.TextStyle(color: _grey, fontSize: 9))),
            pw.Expanded(child: pw.Text(n.s('body'))),
          ]),
        ));
      }
    }
  }

  // ---------------------------------------------------------------- sign-off
  if (o.signoff) {
    final remote = ot != null && !ot.onSite;
    body.add(h('Customer approval'));
    body.add(pw.Text('I have reviewed the selections${o.measurements ? ', measurements' : ''}${design != null ? ', drawings' : ''}'
        '${o.quote && quote != null ? ' and scope' : ''} in this packet and approve them for ordering.'));
    if (remote) {
      body.add(pw.Padding(
        padding: const pw.EdgeInsets.only(top: 6),
        child: pw.Text('This is a ${ot.short.toLowerCase()} order: I confirm the measurements are correct. Measurements I supplied '
            'are my responsibility.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      ));
    }
    body.add(pw.SizedBox(height: 40));
    body.add(pw.Row(children: [
      for (final l in ['Customer signature', 'Printed name', 'Date'])
        pw.Expanded(
          child: pw.Container(
            margin: const pw.EdgeInsets.only(right: 20),
            padding: const pw.EdgeInsets.only(top: 4),
            decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide())),
            child: pw.Text(l, style: const pw.TextStyle(fontSize: 8, color: _grey)),
          ),
        ),
    ]));
  }

  final meta = [('Job', numberOf(p)), ('Date', today()), if (ot != null) ('Order', ot.short)];
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.all(36),
    header: (c) => c.pageNumber == 1
        ? _letterhead(s, o.title, meta)
        : pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 10),
            child: pw.Text('${o.title} · ${numberOf(p)} ${p.s('customer')}', style: const pw.TextStyle(color: _grey, fontSize: 9))),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(color: _grey, fontSize: 9))),
    build: (c) => body,
  ));

  // ---------------------------------------------------------------- drawings (design PDFs and images)
  if (o.drawings && design != null) {
    for (final f in db.select("SELECT * FROM files WHERE entity_type='design' AND entity_id=? AND deleted=0 ORDER BY created_at",
        [design.id])) {
      final name = f.s('name');
      final isPdf = name.toLowerCase().endsWith('.pdf');
      if (!isPdf && !_pdfImageOk(name)) continue;
      final bytes = await load(f);
      if (bytes == null) continue;
      List<Uint8List> pages;
      try {
        pages = isPdf ? await rasterize(bytes) : [bytes];
      } catch (_) {
        continue; // couldn't render this file; it is still listed under Design
      }
      for (final (i, img) in pages.indexed) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.letter.landscape,
          margin: const pw.EdgeInsets.all(24),
          build: (c) => pw.Column(children: [
            pw.Text('Design v${design.i('version')} · $name${pages.length > 1 ? ' · page ${i + 1}' : ''}',
                style: const pw.TextStyle(color: _grey, fontSize: 9)),
            pw.SizedBox(height: 6),
            pw.Expanded(child: pw.Center(child: pw.Image(pw.MemoryImage(img), fit: pw.BoxFit.contain))),
          ]),
        ));
      }
    }
  }

  // ---------------------------------------------------------------- photos
  if (o.photos) {
    final photos = db.select("SELECT * FROM files WHERE project_id=? AND deleted=0 AND category IN ('photos','measurements') "
        'ORDER BY created_at', [projectId]).where((f) => _pdfImageOk(f.s('name'))).take(o.maxPhotos).toList();
    final imgs = <(String, Uint8List)>[];
    for (final f in photos) {
      final b = await load(f);
      if (b != null) imgs.add((f.s('name'), b));
    }
    for (var i = 0; i < imgs.length; i += 4) {
      final chunk = imgs.sublist(i, i + 4 > imgs.length ? imgs.length : i + 4);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(30),
        build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('SITE PHOTOS · ${numberOf(p)} ${p.s('customer')}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Expanded(
            child: pw.GridView(crossAxisCount: 2, childAspectRatio: 0.85, crossAxisSpacing: 10, mainAxisSpacing: 10, children: [
              for (final (name, b) in chunk)
                pw.Column(children: [
                  pw.Expanded(child: pw.Image(pw.MemoryImage(b), fit: pw.BoxFit.contain)),
                  pw.Text(name, style: const pw.TextStyle(fontSize: 8, color: _grey)),
                ]),
            ]),
          ),
        ]),
      ));
    }
  }

  return doc.save();
}
