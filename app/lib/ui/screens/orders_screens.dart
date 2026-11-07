import 'package:flutter/material.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../core/orders.dart';
import '../../pdf/documents.dart';
import '../../services.dart';
import '../widgets/common.dart';

String _poChipStatus(String s) => switch (s) {
      'draft' => 'draft',
      'ordered' || 'confirmed' => 'sent',
      'received' => 'paid',
      'cancelled' => 'void',
      _ => s,
    };

// ============================================================================ job page card

/// Supplier orders for a job, plus "mark installed / delivered / picked up".
class ProjectOrdersCard extends StatelessWidget {
  const ProjectOrdersCard({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final p = db.get('projects', projectId)!;
    final orders = projectOrders(db, projectId);
    final status = normalizeStage(p.s('status'));
    final canComplete = ['approved', 'ordered', 'received'].contains(status);
    return Section(
      title: 'Supplier orders & production',
      action: Wrap(spacing: 4, children: [
        TextButton.icon(
          onPressed: () {
            final id = createPurchaseOrder(db, projectId);
            push(context, PurchaseOrderScreen(poId: id));
          },
          icon: const Icon(Icons.add_shopping_cart, size: 18),
          label: const Text('New order'),
        ),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (orders.isEmpty)
          Muted(atLeast(status, 'approved')
              ? 'Order the cabinets, doors, countertops… from your suppliers here. Each order gets a PO number and a PDF.'
              : 'Once the job is approved, order materials from your suppliers here.'),
        for (final o in orders)
          ItemTile(
            dim: o.s('status') == 'cancelled',
            title: '${poLabel(o)} · ${o.ns('supplier') ?? 'supplier not chosen'}',
            subtitle: [
              '${o.i('n_items')} line${o.i('n_items') == 1 ? '' : 's'}',
              if (o.ns('ordered_on') != null) 'ordered ${o.s('ordered_on')}',
              if (o.ns('expected_on') != null && o.s('status') != 'received') 'expected ${o.s('expected_on')}',
              if (o.ns('received_on') != null) 'received ${o.s('received_on')}',
              if (o.ns('supplier_ref') != null) 'ref ${o.s('supplier_ref')}',
            ].join(' · '),
            trailing: StatusChip(_poChipStatus(o.s('status')), label: poStatusLabel(o.s('status')).toLowerCase()),
            onTap: () => push(context, PurchaseOrderScreen(poId: o.id)),
          ),
        if (canComplete) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final label = completedLabel(p.ns('order_type'));
                if (await confirm(context, 'Mark this job as ${label.toLowerCase()}?', ok: label)) {
                  if (context.mounted) markCompleted(context.db, projectId);
                }
              },
              icon: const Icon(Icons.task_alt),
              label: Text('Mark ${completedLabel(p.ns('order_type')).toLowerCase()}'),
            ),
          ),
        ],
      ]),
    );
  }
}

// ============================================================================ purchase order

class PurchaseOrderScreen extends StatefulWidget {
  const PurchaseOrderScreen({super.key, required this.poId});
  final String poId;
  @override
  State<PurchaseOrderScreen> createState() => _PurchaseOrderScreenState();
}

class _Line {
  _Line(PoLine l, [this.id])
      : desc = TextEditingController(text: l.description),
        qty = TextEditingController(text: fmtQty(l.qty)),
        notes = TextEditingController(text: l.notes),
        received = TextEditingController(text: fmtQty(l.receivedQty));
  final String? id;
  final TextEditingController desc, qty, notes, received;
  void dispose() {
    for (final c in [desc, qty, notes, received]) {
      c.dispose();
    }
  }
}

class _PurchaseOrderScreenState extends State<PurchaseOrderScreen> {
  final _lines = <_Line>[];
  final _ref = TextEditingController();
  final _notes = TextEditingController();
  String? _supplierId, _expected, _deliverTo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final db = context.db;
    final po = db.get('purchase_orders', widget.poId);
    if (po == null) return;
    _supplierId = po.ns('supplier_id');
    _expected = po.ns('expected_on');
    _deliverTo = po.ns('deliver_to') ?? 'shop';
    _ref.text = po.s('supplier_ref');
    _notes.text = po.s('notes');
    for (final l in _lines) {
      l.dispose();
    }
    _lines
      ..clear()
      ..addAll([
        for (final i in poItems(db, widget.poId))
          _Line(PoLine(i.s('description'), qty: i.d('qty'), notes: i.s('notes'), receivedQty: i.d('received_qty')), i.id),
      ]);
    if (_lines.isEmpty && po.s('status') == 'draft') _lines.add(_Line(PoLine('')));
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _ref.dispose();
    _notes.dispose();
    super.dispose();
  }

  List<PoLine> _collect() => [
        for (final l in _lines)
          PoLine(l.desc.text, qty: double.tryParse(l.qty.text) ?? 1, notes: l.notes.text,
              receivedQty: double.tryParse(l.received.text) ?? 0),
      ];

  Future<bool> _save({bool quiet = false}) => attempt(context, () async {
        final po = context.db.get('purchase_orders', widget.poId)!;
        savePurchaseOrder(context.db, widget.poId,
            supplierId: _supplierId,
            supplierRef: _ref.text.trim(),
            expectedOn: _expected,
            deliverTo: _deliverTo,
            notes: _notes.text.trim(),
            lines: po.s('status') == 'draft' ? _collect() : null);
      }, success: quiet ? null : 'Saved');

  Future<void> _addSupplier() async {
    final id = await showDialog<String>(context: context, builder: (_) => const SupplierDialog());
    if (id != null) setState(() => _supplierId = id);
  }

  void _addLines(List<PoLine> lines) {
    if (lines.isEmpty) {
      toast(context, 'Nothing to add.');
      return;
    }
    setState(() {
      _lines.removeWhere((l) {
        final empty = l.desc.text.trim().isEmpty;
        if (empty) l.dispose();
        return empty;
      });
      _lines.addAll(lines.map(_Line.new));
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    return DbBuilder(
      db: db,
      builder: (context) {
        final po = orderWithSupplier(db, widget.poId);
        if (po == null) return const DeletedScreen('This purchase order');
        final p = projectWithCustomer(db, po.s('project_id'))!;
        final status = po.s('status');
        final draft = status == 'draft';
        final suppliers = suppliersList(db);
        return Scaffold(
          appBar: AppBar(
            title: Text('${poLabel(po)} · ${p.s('customer')}'),
            actions: [
              IconButton(
                tooltip: 'PDF to send to the supplier',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: () async {
                  if (!await _save(quiet: true) || !context.mounted) return;
                  final bytes = await purchaseOrderPdf(db, widget.poId);
                  if (!context.mounted) return;
                  await showPdf(context,
                      bytes: bytes,
                      filename: safeFilename('${poLabel(po)}_${po.s('supplier')}_${numberOf(p)}.pdf'),
                      projectId: p.id,
                      category: 'other');
                },
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'cancel' && await confirm(context, 'Cancel this order?', ok: 'Cancel order', danger: true)) {
                    cancelPurchaseOrder(db, widget.poId);
                  }
                  if (v == 'delete' && context.mounted &&
                      await confirm(context, 'Delete this draft?', ok: 'Delete', danger: true)) {
                    deleteDraftOrder(db, widget.poId);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (c) => [
                  if (draft) dangerItem(c, 'delete', 'Delete draft'),
                  if (!draft && status != 'cancelled') dangerItem(c, 'cancel', 'Cancel order'),
                ],
              ),
            ],
          ),
          body: PageBody(maxWidth: 1000, children: [
            Crumbs('${p.s('customer')} › ${numberOf(p)} · ${p.s('title')}'),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusChip(_poChipStatus(status), label: poStatusLabel(status).toLowerCase()),
              if (po.ns('ordered_on') != null) Muted('Ordered ${po.s('ordered_on')}'),
              if (po.ns('received_on') != null) Muted('Received ${po.s('received_on')}'),
              if (draft)
                FilledButton.icon(
                  onPressed: () async {
                    if (!await _save(quiet: true) || !context.mounted) return;
                    if (!await confirm(context,
                        'Mark this order as sent to the supplier? The lines can no longer be changed afterwards.',
                        ok: 'Mark ordered')) {
                      return;
                    }
                    if (!context.mounted) return;
                    await attempt(context, () async => markOrdered(db, widget.poId), success: 'Marked as ordered');
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Mark ordered'),
                ),
              if (status == 'ordered')
                OutlinedButton.icon(
                  onPressed: () async {
                    if (!await _save(quiet: true) || !context.mounted) return;
                    await attempt(context,
                        () async => markConfirmed(db, widget.poId, supplierRef: _ref.text.trim(), expectedOn: _expected),
                        success: 'Confirmed');
                  },
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Supplier confirmed'),
                ),
              if (status == 'ordered' || status == 'confirmed')
                FilledButton.icon(
                  onPressed: () async {
                    await attempt(context, () async => receiveItems(db, widget.poId), success: 'All received');
                    if (mounted) setState(_load);
                  },
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('Everything received'),
                ),
            ]),
            const SizedBox(height: 12),
            Section(
              title: 'Supplier & delivery',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: suppliers.any((s) => s.id == _supplierId) ? _supplierId : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Supplier'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('(choose)')),
                        for (final s in suppliers)
                          DropdownMenuItem(value: s.id, child: Text('${s.s('name')}${s.ns('kind') != null ? ' · ${s.s('kind')}' : ''}')),
                      ],
                      onChanged: draft ? (v) => setState(() => _supplierId = v) : null,
                    ),
                  ),
                  if (draft) IconButton(tooltip: 'New supplier', icon: const Icon(Icons.add_business_outlined), onPressed: _addSupplier),
                ]),
                const SizedBox(height: 12),
                TwoCol(
                  left: DateField(label: 'Expected / needed by', value: _expected, onChanged: (v) => setState(() => _expected = v)),
                  right: Padding(
                    padding: EdgeInsets.only(top: isWide(context) ? 0 : 12),
                    child: TextField(controller: _ref, decoration: const InputDecoration(labelText: "Supplier's order / confirmation #")),
                  ),
                ),
                const SizedBox(height: 12),
                Choices<String>(
                  options: const [
                    ('shop', 'Deliver to our shop', Icons.store_outlined),
                    ('site', 'Ship to the job site', Icons.home_outlined),
                  ],
                  value: _deliverTo ?? 'shop',
                  onChanged: (v) => setState(() => _deliverTo = v),
                ),
                const SizedBox(height: 12),
                TextField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes for the supplier')),
              ]),
            ),
            Section(
              title: 'Lines',
              action: draft
                  ? Wrap(spacing: 4, children: [
                      TextButton(onPressed: () => _addLines(linesFromSelections(db, p.id)), child: const Text('From selections')),
                      TextButton(onPressed: () => _addLines(linesFromQuote(db, p.id)), child: const Text('From quote / estimate')),
                    ])
                  : null,
              child: Column(children: [
                for (final (i, l) in _lines.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 70,
                        child: TextField(
                            controller: l.qty,
                            enabled: draft,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Qty')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                          flex: 3,
                          child: TextField(
                              controller: l.desc, enabled: draft, decoration: const InputDecoration(labelText: 'Description'))),
                      const SizedBox(width: 8),
                      if (isWide(context))
                        Expanded(
                            flex: 2,
                            child: TextField(controller: l.notes, enabled: draft, decoration: const InputDecoration(labelText: 'Notes'))),
                      if (!draft && status != 'cancelled') ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: l.received,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Received'),
                            onSubmitted: (_) => _saveReceived(),
                          ),
                        ),
                      ],
                      if (draft)
                        IconButton(
                            tooltip: 'Remove line',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() => _lines.removeAt(i).dispose())),
                    ]),
                    if (!isWide(context) && (draft || l.notes.text.isNotEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: TextField(
                            controller: l.notes,
                            enabled: draft,
                            decoration: const InputDecoration(labelText: 'Notes', isDense: true)),
                      ),
                    ]),
                  ),
                if (draft)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: () => setState(() => _lines.add(_Line(PoLine('')))),
                        icon: const Icon(Icons.add),
                        label: const Text('Add line')),
                  ),
                if (!draft && (status == 'ordered' || status == 'confirmed'))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: _saveReceived, icon: const Icon(Icons.save_outlined), label: const Text('Save received quantities')),
                  ),
              ]),
            ),
            Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: () => _save(), child: const Text('Save'))),
          ]),
        );
      },
    );
  }

  Future<void> _saveReceived() async {
    final ok = await attempt(context, () async {
      receiveItems(context.db, widget.poId, received: {
        for (final l in _lines)
          if (l.id != null) l.id!: double.tryParse(l.received.text) ?? 0,
      });
    }, success: 'Saved');
    if (ok && mounted) setState(_load);
  }
}

// ============================================================================ suppliers

class SuppliersScreen extends StatelessWidget {
  const SuppliersScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    return Scaffold(
      appBar: AppBar(title: const Text('Suppliers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<String>(context: context, builder: (_) => const SupplierDialog()),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('New supplier'),
      ),
      body: DbBuilder(
        db: db,
        builder: (context) {
          final list = suppliersList(db);
          if (list.isEmpty) return const Center(child: Muted('No suppliers yet. Add your cabinet, door and countertop suppliers.'));
          return ListView(padding: const EdgeInsets.only(bottom: 80), children: [
            for (final s in list)
              ListTile(
                leading: const Icon(Icons.local_shipping_outlined),
                title: Text(s.s('name')),
                subtitle: Text([
                  s.s('kind'),
                  s.s('contact'),
                  s.s('phone'),
                  s.s('email'),
                  if (s.i('lead_days') > 0) '${s.i('lead_days')} days lead time',
                ].where((x) => x.isNotEmpty).join(' · ')),
                onTap: () => showDialog<String>(context: context, builder: (_) => SupplierDialog(supplier: s)),
              ),
          ]);
        },
      ),
    );
  }
}

/// Add / edit a supplier. Returns the supplier id.
class SupplierDialog extends StatefulWidget {
  const SupplierDialog({super.key, this.supplier});
  final Rec? supplier;
  @override
  State<SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<SupplierDialog> {
  late final _f = {
    for (final k in ['name', 'contact', 'phone', 'email', 'address', 'account_no', 'notes'])
      k: TextEditingController(text: widget.supplier?.s(k) ?? ''),
  };
  late final _lead = TextEditingController(
      text: (widget.supplier?.i('lead_days') ?? 0) > 0 ? '${widget.supplier!.i('lead_days')}' : '');
  late String? _kind = widget.supplier?.ns('kind');

  @override
  void dispose() {
    for (final c in [..._f.values, _lead]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget f(String k, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(controller: _f[k], decoration: InputDecoration(labelText: label)));
    return AlertDialog(
      title: Text(widget.supplier == null ? 'New supplier' : 'Edit supplier'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            f('name', 'Name *'),
            DropdownButtonFormField<String?>(
              initialValue: supplierKinds.contains(_kind) ? _kind : null,
              decoration: const InputDecoration(labelText: 'Supplies'),
              items: [
                const DropdownMenuItem(value: null, child: Text('-')),
                for (final k in supplierKinds) DropdownMenuItem(value: k, child: Text(k)),
              ],
              onChanged: (v) => setState(() => _kind = v),
            ),
            const SizedBox(height: 8),
            f('contact', 'Contact person'),
            f('phone', 'Phone'),
            f('email', 'Email'),
            f('address', 'Address'),
            f('account_no', 'Our account #'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                  controller: _lead,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Usual lead time (days)', helperText: 'Fills in the expected date when you order')),
            ),
            f('notes', 'Notes'),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            String? id;
            final ok = await attempt(context, () async {
              id = saveSupplier(context.db, {
                for (final e in _f.entries) e.key: e.value.text.trim(),
                'kind': _kind,
                'lead_days': int.tryParse(_lead.text.trim()),
              }, id: widget.supplier?.id);
            });
            if (ok && context.mounted) Navigator.pop(context, id);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
