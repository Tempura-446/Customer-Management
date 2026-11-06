import 'package:flutter/material.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'customers_screens.dart';
import 'design_screens.dart';
import 'invoice_screens.dart';
import 'measurement_screens.dart';
import 'projects_screens.dart';
import 'quote_screens.dart';

/// The job "hub": everything for one project in workflow order.
class ProjectScreen extends StatelessWidget {
  const ProjectScreen({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    return DbBuilder(
      db: db,
      builder: (context) {
        final p = projectWithCustomer(db, projectId);
        if (p == null) return const Scaffold(body: Center(child: Text('This job was deleted.')));
        final prices = svc.prices;
        return Scaffold(
          appBar: AppBar(
            title: Text('${p.s('customer')} · ${p.s('title')}'),
            actions: [
              IconButton(
                  tooltip: 'Edit job',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => push(context, ProjectFormScreen(projectId: projectId))),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'customer') push(context, CustomerDetailScreen(customerId: p.s('customer_id')));
                  if (v == 'folder') openFolder(svc.files.projectFolder(projectId));
                  if (v == 'delete' &&
                      await confirm(context, 'Delete this job and all its measurements, designs, quotes and invoices?',
                          ok: 'Delete', danger: true)) {
                    deleteProject(db, projectId);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'customer', child: Text('Open customer')),
                  if (svc.isHub) const PopupMenuItem(value: 'folder', child: Text('Open job folder')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete job')),
                ],
              ),
            ],
          ),
          body: PageBody(maxWidth: 1400, children: [
            _Header(p: p),
            _Stepper(status: p.s('status'), projectId: projectId),
            for (final w in projectWarnings(db, projectId, prices: prices)) WarnBanner(w.message, serious: w.serious),
            const SizedBox(height: 4),
            LayoutBuilder(builder: (context, c) {
              final cards = [
                _MeasurementsCard(projectId: projectId),
                _DesignsCard(projectId: projectId),
                if (prices) _QuotesCard(projectId: projectId),
                if (prices) _InvoicesCard(projectId: projectId),
              ];
              final perRow = c.maxWidth >= 1100 ? cards.length : (c.maxWidth >= 640 ? 2 : 1);
              if (perRow == 1) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: cards);
              final rows = <Widget>[];
              for (var i = 0; i < cards.length; i += perRow) {
                rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (var j = i; j < i + perRow; j++) ...[
                    if (j > i) const SizedBox(width: 12),
                    Expanded(child: j < cards.length ? cards[j] : const SizedBox()),
                  ],
                ]));
              }
              return Column(children: rows);
            }),
            TwoCol(
              left: _NotesCard(projectId: projectId),
              right: FilesPanel(projectId: projectId, category: 'photos', title: 'All job files', allowCategoryChoice: true),
            ),
          ]),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.p});
  final Rec p;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(numberOf(p), style: Theme.of(context).textTheme.titleMedium),
          PopupMenuButton<String>(
            tooltip: 'Change order type',
            onSelected: (v) => setOrderType(context.db, p.id, v == 'none' ? null : v),
            itemBuilder: (_) => [
              for (final o in orderTypes)
                PopupMenuItem(
                  value: o.key,
                  child: ListTile(
                    dense: true,
                    leading: Icon(orderTypeIcon(o.key), color: Color(o.color)),
                    title: Text(o.label),
                    subtitle: Text(o.hint),
                  ),
                ),
              const PopupMenuItem(value: 'none', child: ListTile(dense: true, leading: Icon(Icons.help_outline), title: Text('Not decided yet'))),
            ],
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              OrderTypeChip(p.ns('order_type'), long: true),
              const Icon(Icons.arrow_drop_down, size: 18),
            ]),
          ),
          if (p.ns('phone') != null) Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.phone_outlined, size: 16), const SizedBox(width: 4), SelectableText(p.s('phone'))]),
          if (p.ns('email') != null) Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.email_outlined, size: 16), const SizedBox(width: 4), SelectableText(p.s('email'))]),
          if (p.ns('site_address') != null) Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.place_outlined, size: 16), const SizedBox(width: 4), SelectableText(p.s('site_address'))]),
        ]),
      );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.status, required this.projectId});
  final String status, projectId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = stages.where((s) => s.key != 'lost').toList();
    final cur = stageKeys.indexOf(status);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (i, s) in shown.indexed)
            Container(
              margin: const EdgeInsets.only(right: 2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: s.key == status
                    ? cs.primary
                    : (status != 'lost' && i < cur ? cs.primaryContainer : cs.surfaceContainerHighest),
                borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(i == 0 ? 8 : 0), right: Radius.circular(i == shown.length - 1 ? 8 : 0)),
              ),
              child: Text(s.label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: s.key == status ? FontWeight.w700 : FontWeight.normal,
                      color: s.key == status ? cs.onPrimary : cs.onSurfaceVariant)),
            ),
        ]),
      ),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Muted('Status moves forward automatically. Override: ', size: 12),
        DropdownButton<String>(
          value: status,
          isDense: true,
          underline: const SizedBox(),
          items: [for (final s in stages) DropdownMenuItem(value: s.key, child: Text(s.label, style: const TextStyle(fontSize: 13)))],
          onChanged: (v) {
            if (v != null && v != status) setStatus(context.db, projectId, v, 'manual');
          },
        ),
      ]),
      const SizedBox(height: 6),
    ]);
  }
}

class _MeasurementsCard extends StatelessWidget {
  const _MeasurementsCard({required this.projectId});
  final String projectId;
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final list = db.select('''SELECT m.*, (SELECT COUNT(*) FROM measurement_items i WHERE i.measurement_id=m.id AND i.deleted=0) n,
                                (SELECT COUNT(*) FROM files f WHERE f.entity_type='measurement' AND f.entity_id=m.id AND f.deleted=0) nf
                              FROM measurements m WHERE m.project_id=? AND m.deleted=0 ORDER BY m.created_at DESC''',
        [projectId]);
    return Section(
      number: 1,
      title: 'Measurements',
      action: TextButton.icon(
          onPressed: () => push(context, MeasurementFormScreen(projectId: projectId)),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add')),
      child: Column(children: [
        if (list.isEmpty) const Muted('Start here: record measurements from the site visit or from the customer.'),
        for (final m in list)
          ItemTile(
            title: m.s('room'),
            accent: sourceColor(m.s('source')),
            below: SourceChip(m.s('source'), verified: m.b('verified')),
            subtitle: '${m.ns('taken_on') ?? fmtDate(m.s('created_at'))} · '
                '${[if (m.i('n') > 0) '${m.i('n')} dims', if (m.i('nf') > 0) '${m.i('nf')} file${m.i('nf') == 1 ? '' : 's'}'].join(', ').ifEmpty('no dims')}',
            onTap: () => push(context, MeasurementScreen(measurementId: m.id)),
          ),
      ]),
    );
  }
}

class _DesignsCard extends StatelessWidget {
  const _DesignsCard({required this.projectId});
  final String projectId;
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final list = db.select('''SELECT d.*, m.room AS m_room,
                                (SELECT COUNT(*) FROM files f WHERE f.entity_type='design' AND f.entity_id=d.id AND f.deleted=0) nf
                              FROM designs d LEFT JOIN measurements m ON m.id=d.measurement_id
                              WHERE d.project_id=? AND d.deleted=0 ORDER BY d.version DESC''', [projectId]);
    return Section(
      number: 2,
      title: 'Designs (2020)',
      action: TextButton.icon(
          onPressed: () => push(context, DesignFormScreen(projectId: projectId)),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New version')),
      child: Column(children: [
        if (list.isEmpty) const Muted('Save each 2020 change as a new version (v1, v2…) with its .kit file, PDF and renders.'),
        for (final d in list)
          ItemTile(
            dim: d.s('status') == 'superseded',
            title: 'v${d.i('version')}${d.ns('title') != null ? ' · ${d.s('title')}' : ''}',
            subtitle: [
              fmtDate(d.s('created_at')),
              if (d.ns('m_room') != null) 'from “${d.s('m_room')}”',
              '${d.i('nf')} file${d.i('nf') == 1 ? '' : 's'}',
            ].join(' · '),
            trailing: StatusChip(d.s('status')),
            onTap: () => push(context, DesignScreen(designId: d.id)),
          ),
      ]),
    );
  }
}

class _QuotesCard extends StatelessWidget {
  const _QuotesCard({required this.projectId});
  final String projectId;
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final list = db.select('''SELECT q.*, d.version AS d_version FROM quotes q LEFT JOIN designs d ON d.id=q.design_id
                              WHERE q.project_id=? AND q.deleted=0 ORDER BY q.created_at DESC''', [projectId]);
    return Section(
      number: 3,
      title: 'Quotes',
      action: TextButton.icon(
          onPressed: () {
            final qid = createQuote(db, projectId);
            push(context, QuoteEditScreen(quoteId: qid));
          },
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New quote')),
      child: Column(children: [
        if (list.isEmpty) const Muted('Build the quote from the design. It records which design version it prices.'),
        for (final q in list)
          ItemTile(
            dim: q.s('status') == 'superseded',
            title: quoteLabel(q),
            subtitle: [
              fmtMoney(quoteTotals(db, q.id).total),
              if (q.ns('d_version') != null) 'design v${q.s('d_version')}',
              if (q.ns('sent_on') != null) 'sent ${q.s('sent_on')}',
            ].join(' · '),
            trailing: StatusChip(q.s('status')),
            onTap: () => push(context, QuoteScreen(quoteId: q.id)),
          ),
      ]),
    );
  }
}

class _InvoicesCard extends StatelessWidget {
  const _InvoicesCard({required this.projectId});
  final String projectId;
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final acc = acceptedQuote(db, projectId);
    final b = acc == null ? null : quoteBilling(db, acc.id);
    final list = db.select('SELECT * FROM invoices WHERE project_id=? AND deleted=0 ORDER BY created_at', [projectId]);
    Widget fig(String l, double v) => Expanded(
          child: Container(
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Muted(l, size: 11),
              FittedBox(child: Text(fmtMoney(v), style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ),
        );
    return Section(
      number: 4,
      title: 'Invoices',
      action: acc == null
          ? null
          : TextButton.icon(
              onPressed: () => push(context, InvoiceNewScreen(quoteId: acc.id)),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Invoice')),
      child: Column(children: [
        if (b != null) ...[
          Row(children: [fig('Contract', b.total), fig('Invoiced', b.invoiced)]),
          Row(children: [fig('Collected', b.collected), fig('Outstanding', b.outstanding)]),
          const SizedBox(height: 6),
        ],
        if (list.isEmpty)
          Muted(acc == null
              ? 'Invoices unlock once a quote is accepted.'
              : 'Create the deposit invoice from the accepted quote.'),
        for (final i in list)
          ItemTile(
            dim: i.s('status') == 'void',
            title: numberOf(i),
            subtitle: '${i.s('kind')} · ${fmtMoney(i.d('amount'))} · paid ${fmtMoney(invoicePaid(db, i.id))}'
                '${i.ns('due_on') != null ? ' · due ${i.s('due_on')}' : ''}',
            trailing: StatusChip(i.s('status')),
            onTap: () => push(context, InvoiceScreen(invoiceId: i.id)),
          ),
      ]),
    );
  }
}

class _NotesCard extends StatefulWidget {
  const _NotesCard({required this.projectId});
  final String projectId;
  @override
  State<_NotesCard> createState() => _NotesCardState();
}

class _NotesCardState extends State<_NotesCard> {
  final _ctl = TextEditingController();
  String _kind = 'note';
  bool _showSystem = true;

  static const _kinds = {'note': 'Note', 'call': 'Call', 'email': 'Email', 'site': 'Site visit'};
  static const _icons = {
    'note': Icons.sticky_note_2_outlined, 'call': Icons.phone_outlined, 'email': Icons.email_outlined,
    'site': Icons.home_repair_service_outlined, 'system': Icons.history, 'money': Icons.attach_money,
  };

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    final notes = db.select('''SELECT n.*, u.name AS who FROM notes n LEFT JOIN users u ON u.id=n.updated_by
        WHERE n.project_id=? AND n.deleted=0 ${svc.prices ? '' : "AND n.kind<>'money'"}
        ${_showSystem ? '' : "AND n.kind NOT IN ('system','money')"} ORDER BY n.created_at DESC LIMIT 200''',
        [widget.projectId]);
    return Section(
      title: 'Notes & activity',
      action: FilterChip(
        label: const Text('History', style: TextStyle(fontSize: 12)),
        selected: _showSystem,
        onSelected: (v) => setState(() => _showSystem = v),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButton<String>(
            value: _kind,
            items: [for (final e in _kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _kind = v ?? 'note'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctl,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Wants white shaker doors, soft-close…'),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: () {
              addNote(db, widget.projectId, _ctl.text, kind: _kind);
              _ctl.clear();
            },
          ),
        ]),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView(shrinkWrap: true, children: [
            for (final n in notes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_icons[n.s('kind')] ?? Icons.notes, size: 18),
                title: Text(n.s('body'),
                    style: (n.s('kind') == 'system' || n.s('kind') == 'money')
                        ? TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)
                        : null),
                subtitle: Text('${fmtDateTime(n.s('created_at'))}${n.ns('who') != null ? ' · ${n.s('who')}' : ''}',
                    style: const TextStyle(fontSize: 11)),
              ),
          ]),
        ),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
