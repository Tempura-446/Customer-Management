import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../pdf/documents.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'project_screen.dart';
import 'quote_screens.dart';

Widget _row(String label, double v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null)),
        Text(fmtMoney(v), style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null),
      ]),
    );

// ============================================================================ new invoice

class InvoiceNewScreen extends StatefulWidget {
  const InvoiceNewScreen({super.key, required this.quoteId, this.kind});
  final String quoteId;
  final String? kind;
  @override
  State<InvoiceNewScreen> createState() => _InvoiceNewScreenState();
}

class _InvoiceNewScreenState extends State<InvoiceNewScreen> {
  late String kind;
  final amount = TextEditingController();
  final notes = TextEditingController();
  bool loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded) return;
    loaded = true;
    final db = context.db;
    final hasInvoices =
        db.one("SELECT 1 FROM invoices WHERE quote_id=? AND deleted=0 AND status<>'void'", [widget.quoteId]) != null;
    kind = widget.kind ?? (hasInvoices ? 'final' : 'deposit');
    _suggest();
  }

  void _suggest() {
    amount.text = suggestedInvoiceAmount(context.db, widget.quoteId, kind).toStringAsFixed(2);
  }

  @override
  void dispose() {
    amount.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final q = db.get('quotes', widget.quoteId)!;
    final p = projectWithCustomer(db, q.s('project_id'))!;
    final b = quoteBilling(db, q.id);
    final t = quoteTotals(db, q.id);
    return Scaffold(
      appBar: AppBar(title: Text('New invoice · ${quoteLabel(q)}')),
      body: PageBody(maxWidth: 720, children: [
        Crumbs('${p.s('customer')} › ${numberOf(p)} ${p.s('title')}'),
        if (q.s('status') != 'accepted') const WarnBanner('Accept the quote before invoicing.'),
        Section(
          title: 'Contract',
          child: Column(children: [
            _row('Contract total', b.total),
            _row('Already invoiced', b.invoiced),
            _row('Left to invoice', b.uninvoiced, bold: true),
          ]),
        ),
        Section(
          title: 'Invoice',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Choices<String>(
              options: [
                ('deposit', 'Deposit (${fmtQty(q.d('deposit_pct'))}%)', null),
                ('progress', 'Progress', null),
                ('final', 'Final / balance', null),
              ],
              value: kind,
              onChanged: (v) => setState(() {
                kind = v;
                _suggest();
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$'),
            ),
            const SizedBox(height: 6),
            Muted(switch (kind) {
              'deposit' => 'Deposit = ${fmtQty(q.d('deposit_pct'))}% of ${fmtMoney(t.total)}. Collect it before ordering cabinets.',
              'final' => 'Final = everything not yet invoiced on this quote.',
              _ => 'Progress payment, e.g. on delivery of cabinets.',
            }, size: 12),
            const SizedBox(height: 12),
            TextField(
              controller: notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes on invoice', hintText: 'Deposit to place cabinet order'),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Create invoice'),
                onPressed: () async {
                  String? id;
                  final ok = await attempt(context, () async {
                    id = createInvoice(db, q.id,
                        kind: kind,
                        amount: double.tryParse(amount.text.trim()) ?? 0,
                        notes: notes.text.trim().isEmpty ? null : notes.text.trim());
                  });
                  if (ok && id != null && context.mounted) {
                    Navigator.of(context)
                        .pushReplacement(MaterialPageRoute(builder: (_) => InvoiceScreen(invoiceId: id!)));
                  }
                },
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ============================================================================ invoice detail

class InvoiceScreen extends StatelessWidget {
  const InvoiceScreen({super.key, required this.invoiceId});
  final String invoiceId;

  @override
  Widget build(BuildContext context) {
    return DbBuilder(
      db: context.db,
      builder: (context) {
        final db = context.db;
        final i = db.get('invoices', invoiceId);
        if (i == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Invoice was deleted.')));
        final q = db.one('SELECT * FROM quotes WHERE id=?', [i.s('quote_id')])!;
        final p = projectWithCustomer(db, i.s('project_id'))!;
        final payments =
            db.select('SELECT * FROM payments WHERE invoice_id=? AND deleted=0 ORDER BY paid_on, created_at', [invoiceId]);
        final paid = invoicePaid(db, invoiceId);
        final balance = money(i.d('amount') - paid);
        final b = quoteBilling(db, q.id);
        final status = i.s('status');

        final actions = Wrap(spacing: 8, runSpacing: 8, children: [
          AsyncButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'PDF',
            onPressed: () async {
              final bytes = await invoicePdf(db, invoiceId);
              if (!context.mounted) return;
              await showPdf(context,
                  bytes: bytes,
                  filename: safeFilename('Invoice_${numberOf(i)}_${p.s('customer')}.pdf'),
                  projectId: p.id,
                  category: 'invoices',
                  entityType: 'invoice',
                  entityId: invoiceId);
            },
          ),
          if (status == 'draft')
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Mark sent'),
              onPressed: () => attempt(context, () async => sendInvoice(db, invoiceId), success: 'Invoice marked sent'),
            ),
          if ((status == 'draft' || status == 'sent') && payments.isEmpty)
            OutlinedButton(
              onPressed: () async {
                if (await confirm(context, 'Void this invoice?', ok: 'Void', danger: true) && context.mounted) {
                  await attempt(context, () async => voidInvoice(db, invoiceId));
                }
              },
              child: const Text('Void'),
            ),
        ]);

        final summary = Section(
          title: 'Invoice',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KeyValues([
              ('Quote', quoteLabel(q)),
              ('Kind', cap(i.s('kind'))),
              ('Amount', fmtMoney(i.d('amount'))),
              ('Paid', fmtMoney(paid)),
              ('Balance', fmtMoney(balance)),
              ('Issued', fmtDate(i.ns('issued_on'))),
              ('Due', fmtDate(i.ns('due_on'))),
            ]),
            if (i.ns('notes') != null) ...[const SizedBox(height: 8), Text(i.s('notes'))],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => push(context, QuoteScreen(quoteId: q.id)),
                child: Text('Open quote ${quoteLabel(q)}'),
              ),
            ),
          ]),
        );

        final job = Section(
          title: 'Whole job',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _row('Contract', b.total),
            _row('Invoiced', b.invoiced),
            _row('Collected', b.collected),
            _row('Outstanding', b.outstanding, bold: true),
            if (b.uninvoiced > 0.005 && q.s('status') == 'accepted') ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: () => push(context, InvoiceNewScreen(quoteId: q.id, kind: 'final')),
                  child: Text('Invoice remaining ${fmtMoney(b.uninvoiced)}'),
                ),
              ),
            ],
          ]),
        );

        final pays = Section(
          title: 'Payments',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (payments.isEmpty) const Muted('No payments yet.'),
            for (final pay in payments)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${fmtMoney(pay.d('amount'))} · ${pay.s('method')}'),
                subtitle: Text([pay.s('paid_on'), if (pay.ns('reference') != null) pay.s('reference')].join(' · ')),
                trailing: IconButton(
                  tooltip: 'Remove payment',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () async {
                    if (await confirm(context, 'Remove this payment?', ok: 'Remove', danger: true) &&
                        context.mounted) {
                      await attempt(context, () async => deletePayment(db, pay.id));
                    }
                  },
                ),
              ),
            if (status != 'void' && balance > 0.005) ...[
              const Divider(),
              _PaymentForm(invoiceId: invoiceId, balance: balance),
            ],
          ]),
        );

        return Scaffold(
          appBar: AppBar(title: Text('Invoice ${numberOf(i)}')),
          body: PageBody(children: [
            InkWell(
              onTap: () => push(context, ProjectScreen(projectId: p.id)),
              child: Crumbs('${p.s('customer')} › ${numberOf(p)} ${p.s('title')}'),
            ),
            Row(children: [
              Flexible(child: Text(numberOf(i), style: Theme.of(context).textTheme.headlineSmall)),
              const SizedBox(width: 10),
              StatusChip(status),
              const Spacer(),
              Text('Due ${fmtMoney(balance)}', style: Theme.of(context).textTheme.titleLarge),
            ]),
            const SizedBox(height: 10),
            actions,
            const SizedBox(height: 10),
            TwoCol(
              left: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [summary, job]),
              right: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                pays,
                FilesPanel(projectId: p.id, entityType: 'invoice', entityId: invoiceId, category: 'invoices'),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _PaymentForm extends StatefulWidget {
  const _PaymentForm({required this.invoiceId, required this.balance});
  final String invoiceId;
  final double balance;
  @override
  State<_PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<_PaymentForm> {
  late final amount = TextEditingController(text: widget.balance.toStringAsFixed(2));
  final reference = TextEditingController();
  String paidOn = today();
  String method = paymentMethods.first;

  @override
  void didUpdateWidget(covariant _PaymentForm old) {
    super.didUpdateWidget(old);
    if (old.balance != widget.balance) amount.text = widget.balance.toStringAsFixed(2);
  }

  @override
  void dispose() {
    amount.dispose();
    reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      DateField(label: 'Date', value: paidOn, onChanged: (v) => setState(() => paidOn = v ?? today())),
      TextField(
        controller: amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$'),
      ),
      DropdownButtonFormField<String>(
        initialValue: method,
        decoration: const InputDecoration(labelText: 'Method'),
        items: [for (final m in paymentMethods) DropdownMenuItem(value: m, child: Text(m))],
        onChanged: (v) => setState(() => method = v ?? method),
      ),
      TextField(
          controller: reference, decoration: const InputDecoration(labelText: 'Reference', hintText: 'Cheque #, txn id')),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Record payment', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 10), child: f),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Record payment'),
          onPressed: () => attempt(context, () async {
            addPayment(context.db, widget.invoiceId,
                amount: double.tryParse(amount.text.trim()) ?? 0,
                paidOn: paidOn,
                method: method,
                reference: reference.text.trim().isEmpty ? null : reference.text.trim());
            reference.clear();
          }, success: 'Payment recorded'),
        ),
      ),
    ]);
  }
}
