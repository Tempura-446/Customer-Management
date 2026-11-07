import 'package:flutter/material.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../pdf/documents.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'design_screens.dart';
import 'invoice_screens.dart';
import 'measurement_screens.dart';
import 'project_screen.dart';

// ============================================================================ editor

class _LineCtl {
  _LineCtl(QuoteLine l)
      : category = quoteCategories.contains(l.category) ? l.category : 'Other',
        desc = TextEditingController(text: l.description),
        qty = TextEditingController(text: fmtQty(l.qty)),
        price = TextEditingController(text: l.unitPrice == 0 ? '' : l.unitPrice.toStringAsFixed(2));
  String category;
  final TextEditingController desc, qty, price;
  double get q => double.tryParse(qty.text.trim()) ?? 0;
  double get p => double.tryParse(price.text.trim()) ?? 0;
  QuoteLine toLine() => QuoteLine(category: category, description: desc.text, qty: q, unitPrice: p);
  void dispose() {
    desc.dispose();
    qty.dispose();
    price.dispose();
  }
}

class QuoteEditScreen extends StatefulWidget {
  const QuoteEditScreen({super.key, required this.quoteId});
  final String quoteId;
  @override
  State<QuoteEditScreen> createState() => _QuoteEditScreenState();
}

class _QuoteEditScreenState extends State<QuoteEditScreen> {
  late Rec q;
  late Rec project;
  final lines = <_LineCtl>[];
  final discount = TextEditingController();
  final tax = TextEditingController();
  final deposit = TextEditingController();
  final notes = TextEditingController();
  final terms = TextEditingController();
  String? designId;
  String? validUntil;
  bool loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded) return;
    loaded = true;
    final db = context.db;
    q = db.get('quotes', widget.quoteId)!;
    project = projectWithCustomer(db, q.s('project_id'))!;
    for (final i in quoteItems(db, q.id)) {
      lines.add(_LineCtl(QuoteLine(
          category: i.ns('category') ?? 'Other',
          description: i.s('description'),
          qty: i.d('qty'),
          unitPrice: i.d('unit_price'))));
    }
    if (lines.isEmpty) {
      for (final c in ['Cabinets', 'Countertops', 'Installation']) {
        lines.add(_LineCtl(QuoteLine(category: c)));
      }
    }
    discount.text = fmtQty(q.d('discount'));
    tax.text = fmtQty(q.d('tax_rate'));
    deposit.text = fmtQty(q.d('deposit_pct'));
    notes.text = q.s('notes');
    terms.text = q.s('terms');
    designId = q.ns('design_id');
    validUntil = q.ns('valid_until');
  }

  @override
  void dispose() {
    for (final l in lines) {
      l.dispose();
    }
    for (final c in [discount, tax, deposit, notes, terms]) {
      c.dispose();
    }
    super.dispose();
  }

  double _n(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  QuoteTotals get _totals => computeTotals(
        lines.where((l) => l.desc.text.trim().isNotEmpty).map((l) => (l.category, l.q, l.p)).toList(),
        discount: _n(discount),
        taxRate: _n(tax),
        depositPct: _n(deposit),
      );

  bool _save() {
    final db = context.db;
    try {
      saveQuote(db, q.id,
          designId: designId,
          taxRate: _n(tax),
          discount: _n(discount),
          depositPct: _n(deposit),
          validUntil: validUntil,
          notes: notes.text.trim().isEmpty ? null : notes.text,
          terms: terms.text.trim().isEmpty ? null : terms.text,
          lines: lines.map((l) => l.toLine()).toList());
      return true;
    } on BusinessError catch (e) {
      toast(context, e.message, error: true);
      return false;
    }
  }

  Future<void> _saveAndSend() async {
    if (!await confirm(context, 'Mark as sent? The quote will be locked; later changes need a new revision.',
        ok: 'Mark sent')) {
      return;
    }
    if (!mounted || !_save()) return;
    final ok = await attempt(context, () async => sendQuote(context.db, q.id), success: 'Quote marked sent');
    if (ok && mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => QuoteScreen(quoteId: q.id)));
    }
  }

  void _addLine() => setState(() => lines.add(_LineCtl(QuoteLine(category: lines.isEmpty ? 'Cabinets' : lines.last.category))));

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final current = db.get('quotes', q.id);
    if (current == null || current.s('status') != 'draft') {
      return Scaffold(
        appBar: AppBar(title: Text('Quote ${quoteLabel(q)}')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('This quote has been sent and is locked. Create a revision to change it.'),
            const SizedBox(height: 12),
            if (current != null)
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .pushReplacement(MaterialPageRoute(builder: (_) => QuoteScreen(quoteId: q.id))),
                child: const Text('Open quote'),
              ),
          ]),
        ),
      );
    }
    final designs = db.select('SELECT * FROM designs WHERE project_id=? AND deleted=0 ORDER BY version DESC', [project.id]);
    final t = _totals;
    final wide = isWide(context);
    return Scaffold(
      appBar: AppBar(title: Text('Quote ${quoteLabel(q)} · draft'), actions: [
        TextButton.icon(
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save'),
          onPressed: () {
            if (_save()) toast(context, 'Quote saved');
          },
        ),
        const SizedBox(width: 8),
      ]),
      body: PageBody(children: [
        Crumbs('${project.s('customer')} › ${numberOf(project)} ${project.s('title')}'),
        Section(
          title: 'Quote details',
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(
              width: wide ? 360 : double.infinity,
              child: DropdownButtonFormField<String?>(
                initialValue: designs.any((d) => d.id == designId) ? designId : null,
                decoration: const InputDecoration(labelText: 'Prices design'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('(none)')),
                  for (final d in designs)
                    DropdownMenuItem(value: d.id, child: Text('v${d.i('version')} ${d.s('title')}'.trim())),
                ],
                onChanged: (v) => setState(() => designId = v),
              ),
            ),
            SizedBox(
              width: wide ? 200 : double.infinity,
              child: DateField(label: 'Valid until', value: validUntil, onChanged: (v) => setState(() => validUntil = v)),
            ),
          ]),
        ),
        Section(
          title: 'Lines',
          action: TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Line')),
          child: Column(children: [
            const Muted('Tip: open the 2020 price report next to this and copy the totals into lines.', size: 12),
            const SizedBox(height: 8),
            for (var i = 0; i < lines.length; i++) _lineRow(i, wide),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add line')),
            ),
          ]),
        ),
        Section(
          title: 'Totals',
          child: TwoCol(
            left: Wrap(spacing: 12, runSpacing: 12, children: [
              for (final (label, c) in [('Discount (\$)', discount), ('Tax rate (%)', tax), ('Deposit (%)', deposit)])
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: c,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: label),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
            ]),
            right: Padding(
              padding: EdgeInsets.only(top: wide ? 0 : 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('Subtotal  ${fmtMoney(t.subtotal)}'),
                if (t.discount > 0) Text('Discount  -${fmtMoney(t.discount)}'),
                Text('Tax  ${fmtMoney(t.tax)}'),
                Text('Total  ${fmtMoney(t.total)}', style: Theme.of(context).textTheme.titleLarge),
                Muted('Deposit  ${fmtMoney(t.deposit)}'),
              ]),
            ),
          ),
        ),
        Section(
          title: 'Notes & terms',
          child: Column(children: [
            TextField(
              controller: notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes shown on quote (finishes, door style, inclusions/exclusions)'),
            ),
            const SizedBox(height: 12),
            TextField(controller: terms, maxLines: 3, decoration: const InputDecoration(labelText: 'Terms')),
          ]),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
            onPressed: () {
              if (_save()) toast(context, 'Quote saved');
            },
            child: const Text('Save'),
          ),
          OutlinedButton(
            onPressed: () {
              if (_save()) {
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => QuoteScreen(quoteId: q.id)));
              }
            },
            child: const Text('Save & close'),
          ),
          FilledButton.icon(onPressed: _saveAndSend, icon: const Icon(Icons.send), label: const Text('Save & mark sent')),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _lineRow(int i, bool wide) {
    final l = lines[i];
    final category = DropdownButtonFormField<String>(
      initialValue: l.category,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Category'),
      items: [for (final c in quoteCategories) DropdownMenuItem(value: c, child: Text(c))],
      onChanged: (v) => setState(() => l.category = v ?? 'Other'),
    );
    final desc = TextField(
      controller: l.desc,
      decoration: const InputDecoration(labelText: 'Description'),
      onChanged: (_) => setState(() {}),
    );
    final qty = TextField(
      controller: l.qty,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'Qty'),
      onChanged: (_) => setState(() {}),
    );
    final price = TextField(
      controller: l.price,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'Unit price', prefixText: '\$'),
      onChanged: (_) => setState(() {}),
    );
    final total = SizedBox(
      width: 100,
      child: Text(l.desc.text.trim().isEmpty ? '' : fmtMoney(l.q * l.p),
          textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
    final remove = IconButton(
      tooltip: 'Remove line',
      icon: const Icon(Icons.close, size: 18),
      onPressed: () => setState(() => lines.removeAt(i).dispose()),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(width: 160, child: category),
          const SizedBox(width: 8),
          Expanded(child: desc),
          const SizedBox(width: 8),
          SizedBox(width: 80, child: qty),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: price),
          const SizedBox(width: 8),
          total,
          remove,
        ]),
      );
    }
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          Row(children: [Expanded(child: desc), remove]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(flex: 3, child: category),
            const SizedBox(width: 6),
            Expanded(flex: 2, child: qty),
            const SizedBox(width: 6),
            Expanded(flex: 3, child: price),
          ]),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: total),
        ]),
      ),
    );
  }
}

// ============================================================================ detail

class QuoteScreen extends StatelessWidget {
  const QuoteScreen({super.key, required this.quoteId});
  final String quoteId;

  @override
  Widget build(BuildContext context) {
    return DbBuilder(
      db: context.db,
      builder: (context) {
        final db = context.db;
        final q = db.get('quotes', quoteId);
        if (q == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Quote was deleted.')));
        final p = projectWithCustomer(db, q.s('project_id'))!;
        final t = quoteTotals(db, quoteId);
        final d = db.get('designs', q.ns('design_id'));
        final m = d == null ? null : db.get('measurements', d.ns('measurement_id'));
        final status = q.s('status');
        final revisions = q.ns('number') == null
            ? [q]
            : db.select('SELECT * FROM quotes WHERE number=? AND deleted=0 ORDER BY revision', [q.s('number')]);
        final invoices = db.select(
            'SELECT * FROM invoices WHERE quote_id=? AND deleted=0 ORDER BY created_at', [quoteId]);
        final billing = status == 'accepted' ? quoteBilling(db, quoteId) : null;

        final actions = Wrap(spacing: 8, runSpacing: 8, children: [
          AsyncButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'PDF',
            onPressed: () async {
              final bytes = await quotePdf(db, quoteId);
              if (!context.mounted) return;
              await showPdf(context,
                  bytes: bytes,
                  filename: safeFilename('Quote_${quoteLabel(q)}_${p.s('customer')}.pdf'),
                  projectId: p.id,
                  category: 'quotes',
                  entityType: 'quote',
                  entityId: quoteId);
            },
          ),
          if (status == 'draft') ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit'),
              onPressed: () => push(context, QuoteEditScreen(quoteId: quoteId)),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Mark sent'),
              onPressed: () async {
                if (await confirm(context, 'Mark as sent? It will be locked.', ok: 'Mark sent') && context.mounted) {
                  await attempt(context, () async => sendQuote(db, quoteId), success: 'Quote marked sent');
                }
              },
            ),
          ],
          if (status == 'draft' || status == 'sent')
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Accent.ok, foregroundColor: Colors.white),
              icon: const Icon(Icons.check),
              label: const Text('Accepted'),
              onPressed: () async {
                if (await confirm(context, 'Customer accepted this quote?', ok: 'Accepted') && context.mounted) {
                  await attempt(context, () async => acceptQuote(db, quoteId),
                      success: 'Quote accepted. Next step: create the deposit invoice.');
                }
              },
            ),
          if (status == 'sent')
            OutlinedButton(
              onPressed: () async {
                if (await confirm(context, 'Mark declined?', ok: 'Declined') && context.mounted) {
                  await attempt(context, () async => declineQuote(db, quoteId));
                }
              },
              child: const Text('Declined'),
            ),
          if (['sent', 'declined', 'accepted', 'superseded'].contains(status))
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_all_outlined),
              label: Text('Revise → r${revisions.map((r) => r.i('revision')).fold(0, (a, b) => a > b ? a : b) + 1}'),
              onPressed: () async {
                if (!await confirm(context, 'Create a new revision (copies all lines)?', ok: 'Revise')) return;
                if (!context.mounted) return;
                try {
                  final nid = reviseQuote(db, quoteId);
                  Navigator.of(context)
                      .pushReplacement(MaterialPageRoute(builder: (_) => QuoteEditScreen(quoteId: nid)));
                } on BusinessError catch (e) {
                  toast(context, e.message, error: true);
                }
              },
            ),
          if (status == 'accepted')
            FilledButton.icon(
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Create invoice'),
              onPressed: () => push(context, InvoiceNewScreen(quoteId: quoteId)),
            ),
          if (status == 'draft')
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () async {
                if (await confirm(context, 'Delete this draft quote?', ok: 'Delete', danger: true) &&
                    context.mounted) {
                  final ok = await attempt(context, () async => deleteDraftQuote(db, quoteId));
                  if (ok && context.mounted) Navigator.of(context).pop();
                }
              },
              child: const Text('Delete draft'),
            ),
        ]);

        final linesCard = Section(
          title: 'Lines',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (t.items.isEmpty) const Muted('No lines.'),
            for (final it in t.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(it.s('description')),
                      Muted('${it.s('category')} · ${fmtQty(it.d('qty'))} × ${fmtMoney(it.d('unit_price'))}', size: 12),
                    ]),
                  ),
                  Text(fmtMoney(it.d('qty') * it.d('unit_price'))),
                ]),
              ),
            const Divider(),
            _totalRow('Subtotal', t.subtotal),
            if (t.discount > 0) _totalRow('Discount', -t.discount),
            _totalRow('Tax (${fmtQty(q.d('tax_rate'))}%)', t.tax),
            _totalRow('Total', t.total, big: true, context: context),
            _totalRow('Deposit (${fmtQty(q.d('deposit_pct'))}%)', t.deposit, muted: true),
            if (q.ns('notes') != null) ...[const SizedBox(height: 12), const Muted('Notes'), Text(q.s('notes'))],
            if (q.ns('terms') != null) ...[const SizedBox(height: 12), const Muted('Terms'), Text(q.s('terms'))],
          ]),
        );

        final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Section(
            title: 'Trail',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ItemTile(
                title: d == null ? 'Design: not linked' : 'Design v${d.i('version')} ${d.s('title')}'.trim(),
                subtitle: d?.s('status'),
                onTap: d == null ? null : () => push(context, DesignScreen(designId: d.id)),
              ),
              ItemTile(
                title: m == null ? 'Measurements: -' : 'Measurements: ${m.s('room')}',
                accent: m == null ? null : sourceColor(m.s('source')),
                below: m == null ? null : SourceChip(m.s('source'), verified: m.b('verified')),
                onTap: m == null ? null : () => push(context, MeasurementScreen(measurementId: m.id)),
              ),
              const SizedBox(height: 8),
              KeyValues([
                ('Created', fmtDate(q.s('created_at'))),
                ('Sent', fmtDate(q.ns('sent_on'))),
                ('Valid until', fmtDate(q.ns('valid_until'))),
                ('Decided', fmtDate(q.ns('decided_on'))),
              ]),
            ]),
          ),
          Section(
            title: 'By category',
            child: Column(children: [
              for (final e in t.byCategory.entries) _totalRow(e.key, e.value),
            ]),
          ),
          if (billing != null)
            Section(
              title: 'Billing',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _totalRow('Invoiced', billing.invoiced),
                _totalRow('Collected', billing.collected),
                _totalRow('Not yet invoiced', billing.uninvoiced, big: true, context: context),
                const SizedBox(height: 8),
                for (final i in invoices)
                  ItemTile(
                    title: '${numberOf(i)} · ${i.s('kind')}',
                    subtitle: fmtMoney(i.d('amount')),
                    trailing: StatusChip(i.s('status')),
                    dim: i.s('status') == 'void',
                    onTap: () => push(context, InvoiceScreen(invoiceId: i.id)),
                  ),
              ]),
            ),
          FilesPanel(projectId: p.id, entityType: 'quote', entityId: quoteId, category: 'quotes'),
        ]);

        return Scaffold(
          appBar: AppBar(title: Text('Quote ${quoteLabel(q)}')),
          body: PageBody(children: [
            InkWell(
              onTap: () => push(context, ProjectScreen(projectId: p.id)),
              child: Crumbs('${p.s('customer')} › ${numberOf(p)} ${p.s('title')}'),
            ),
            Row(children: [
              Text(quoteLabel(q), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(width: 10),
              StatusChip(status),
              const Spacer(),
              Text(fmtMoney(t.total), style: Theme.of(context).textTheme.titleLarge),
            ]),
            const SizedBox(height: 10),
            actions,
            const SizedBox(height: 10),
            if (revisions.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  const Muted('Revisions:'),
                  for (final r in revisions)
                    ChoiceChip(
                      label: Text('r${r.i('revision')} (${r.s('status')})'),
                      selected: r.id == quoteId,
                      onSelected: r.id == quoteId
                          ? null
                          : (_) => Navigator.of(context)
                              .pushReplacement(MaterialPageRoute(builder: (_) => QuoteScreen(quoteId: r.id))),
                    ),
                ]),
              ),
            if (status == 'superseded') const WarnBanner('This revision was superseded.', serious: false),
            TwoCol(leftFlex: 2, left: linesCard, right: side),
          ]),
        );
      },
    );
  }
}

Widget _totalRow(String label, double v, {bool big = false, bool muted = false, BuildContext? context}) {
  final style = big && context != null
      ? Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
      : null;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Expanded(child: muted ? Muted(label) : Text(label, style: style)),
      muted ? Muted(fmtMoney(v)) : Text(fmtMoney(v), style: style),
    ]),
  );
}
