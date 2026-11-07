import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../core/orders.dart';
import '../../mail/mail_ingest.dart';
import '../../services.dart';
import '../widgets/common.dart';
import 'customers_screens.dart';
import 'backup_screen.dart';
import 'calendar_screens.dart';
import 'invoice_screens.dart';
import 'mail_screens.dart';
import 'project_screen.dart';
import 'quote_screens.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    return Scaffold(
      appBar: AppBar(
        title: Text(settings(svc.db)['business_name'] ?? 'Dashboard'),
        actions: [
          if (svc.prices)
            DbBuilder(
              db: svc.db,
              builder: (context) {
                final n = unmatchedMailCount(svc.db);
                return IconButton(
                  tooltip: 'Email inbox',
                  icon: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.mail_outline)),
                  onPressed: () => push(context, const MailInboxScreen()),
                );
              },
            ),
          IconButton(
            tooltip: 'New customer',
            icon: const Icon(Icons.person_add_alt),
            onPressed: () => push(context, const CustomerFormScreen()),
          ),
        ],
      ),
      body: DbBuilder(
        db: svc.db,
        builder: (context) {
          final db = svc.db;
          final prices = svc.prices;
          final projects = projectsList(db).where((p) => activeStages.contains(p.s('status'))).toList();
          final actions = nextActions(db, prices: prices);
          var quotesOut = 0.0, receivable = 0.0;
          if (prices) {
            for (final q in db.select("SELECT id FROM quotes WHERE status='sent' AND deleted=0")) {
              quotesOut += quoteTotals(db, q.id).total;
            }
            for (final i in db.select("SELECT id, amount FROM invoices WHERE status='sent' AND deleted=0")) {
              receivable += i.d('amount') - invoicePaid(db, i.id);
            }
          }
          return PageBody(maxWidth: 1400, children: [
            if (svc.storageWarning != null) WarnBanner(svc.storageWarning!),
            if (svc.isOwner) BackupStatusBanner(backup: svc.backup),
            if (svc.hubError != null) WarnBanner(svc.hubError!),
            if (prices && unmatchedMailCount(db) > 0)
              Card(
                color: tintPair(Accent.warn, context).$1,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(Icons.mark_email_unread_outlined, color: tone(Accent.warn, context)),
                  title: Text('${unmatchedMailCount(db)} measurement email(s) need filing'),
                  subtitle: const Text("The subject didn't match exactly one job address."),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => push(context, const MailInboxScreen()),
                ),
              ),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _Stat('Active jobs', '${projects.length}'),
              if (prices) _Stat('Quotes out', fmtMoney(quotesOut)),
              if (prices) _Stat('Receivable', fmtMoney(receivable)),
              _Stat('Next actions', '${actions.length}'),
            ]),
            const SizedBox(height: 12),
            const MyDayCard(),
            const SizedBox(height: 12),
            Section(
              title: 'Next actions',
              child: actions.isEmpty
                  ? const Muted('Nothing waiting on you.')
                  : Column(children: [for (final a in actions) _ActionRow(a)]),
            ),
            if (arrivingSoon(db).isNotEmpty)
              Section(
                title: 'Materials arriving this week',
                child: Column(children: [
                  for (final o in arrivingSoon(db))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.local_shipping_outlined),
                      title: Text('${o.s('expected_on')} · ${poLabel(o)} from ${o.ns('supplier') ?? 'supplier'}'),
                      subtitle: Text('${o.s('customer')} · ${o.ns('pnum') ?? ''} ${o.s('title')}'),
                      onTap: () => push(context, ProjectScreen(projectId: o.s('project_id'))),
                    ),
                ]),
              ),
            Text('Pipeline', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _Pipeline(projects: projects),
          ]);
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: isWide(context) ? 220 : (MediaQuery.sizeOf(context).width - 36) / 2,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Muted(label, size: 12),
              Text(value, style: Theme.of(context).textTheme.headlineSmall),
            ]),
          ),
        ),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(this.a);
  final NextAction a;

  static const _colors = {
    'overdue': Accent.bad, 'expired': Accent.bad, 'verify': Accent.bad,
    'follow up': Accent.warn, 'invoice': Accent.warn, 'send': Accent.warn,
    'confirm': Accent.warn, 'mark done': Accent.warn, 'book': Accent.info,
    'order': Color(0xFF6B46C1),
  };

  @override
  Widget build(BuildContext context) {
    final c = tone(_colors[a.kind] ?? Theme.of(context).colorScheme.onSurfaceVariant, context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(a.kind.toUpperCase(),
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
        ),
      ),
      title: Text(a.text),
      subtitle: Text('${a.customer} · ${a.ref}'),
      onTap: () {
        if (a.invoiceId != null) {
          push(context, InvoiceScreen(invoiceId: a.invoiceId!));
        } else if (a.quoteId != null && a.kind != 'invoice') {
          push(context, QuoteScreen(quoteId: a.quoteId!));
        } else if (a.kind == 'invoice' && a.quoteId != null) {
          push(context, InvoiceNewScreen(quoteId: a.quoteId!, kind: 'deposit'));
        } else {
          push(context, ProjectScreen(projectId: a.projectId));
        }
      },
    );
  }
}

class _Pipeline extends StatelessWidget {
  const _Pipeline({required this.projects});
  final List projects;

  @override
  Widget build(BuildContext context) {
    final cols = [
      for (final st in stages.where((s) => activeStages.contains(s.key)))
        (st, projects.where((p) => p.s('status') == st.key).toList()),
    ];
    Widget column(Stage st, List items, {double? width}) => Container(
          width: width,
          margin: const EdgeInsets.only(right: 10, bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(st.label, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text('${items.length}'),
            ]),
            Muted(st.hint, size: 11),
            const SizedBox(height: 6),
            for (final p in items)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: () => push(context, ProjectScreen(projectId: p.id)),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(p.s('customer'), style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (p.ns('order_type') != null)
                          Tooltip(
                            message: orderTypeOf(p.ns('order_type'))!.label,
                            child: Icon(orderTypeIcon(p.ns('order_type')), size: 16, color: orderTypeColor(p.ns('order_type'))),
                          ),
                      ]),
                      Muted(p.s('title'), size: 12),
                      Muted(numberOf(p), size: 11),
                    ]),
                  ),
                ),
              ),
          ]),
        );
    if (isWide(context)) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (st, items) in cols) Expanded(child: column(st, items)),
      ]);
    }
    // Phones: one compact list grouped by stage.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (st, items) in cols)
        if (items.isNotEmpty) column(st, items),
    ]);
  }
}
