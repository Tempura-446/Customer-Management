/// Supplier orders (purchase orders) and production tracking after a job is approved.
///
/// Approved → (PO marked ordered) Ordered → (everything received) Received →
/// (installed / delivered / picked up) Installed. See markCompleted in logic.dart.
library;

import 'dart:convert';

import 'db.dart';
import 'logic.dart';

class PoStatus {
  const PoStatus(this.key, this.label);
  final String key, label;
}

const poStatuses = [
  PoStatus('draft', 'Draft'),
  PoStatus('ordered', 'Ordered'),
  PoStatus('confirmed', 'Confirmed'),
  PoStatus('received', 'Received'),
  PoStatus('cancelled', 'Cancelled'),
];
String poStatusLabel(String k) => poStatuses.firstWhere((s) => s.key == k, orElse: () => PoStatus(k, k)).label;

const supplierKinds = ['Cabinets', 'Doors', 'Countertops', 'Hardware', 'Appliances', 'Other'];

// ============================================================================ suppliers

List<Rec> suppliersList(AppDb db) => db.select('SELECT * FROM suppliers WHERE deleted=0 ORDER BY name COLLATE NOCASE');

String saveSupplier(AppDb db, Map<String, Object?> v, {String? id}) {
  if ((v['name'] as String? ?? '').trim().isEmpty) throw BusinessError('Supplier name is required.');
  if (id == null) return db.insert('suppliers', v);
  db.update('suppliers', id, v);
  return id;
}

// ============================================================================ purchase orders

class PoLine {
  PoLine(this.description, {this.qty = 1, this.notes = '', this.receivedQty = 0});
  String description, notes;
  double qty, receivedQty;
}

List<Rec> projectOrders(AppDb db, String projectId) => db.select('''
  SELECT po.*, s.name AS supplier, s.lead_days AS lead_days,
    (SELECT COUNT(*) FROM po_items i WHERE i.po_id=po.id AND i.deleted=0) AS n_items
  FROM purchase_orders po LEFT JOIN suppliers s ON s.id=po.supplier_id
  WHERE po.project_id=? AND po.deleted=0 ORDER BY po.created_at''', [projectId]);

Rec? orderWithSupplier(AppDb db, String poId) => db.one('''
  SELECT po.*, s.name AS supplier, s.contact AS supplier_contact, s.phone AS supplier_phone, s.email AS supplier_email,
         s.address AS supplier_address, s.account_no AS supplier_account, s.lead_days AS lead_days
  FROM purchase_orders po LEFT JOIN suppliers s ON s.id=po.supplier_id WHERE po.id=? AND po.deleted=0''', [poId]);

List<Rec> poItems(AppDb db, String poId) =>
    db.select('SELECT * FROM po_items WHERE po_id=? AND deleted=0 ORDER BY position', [poId]);

String poLabel(Rec po) => po.ns('number') ?? 'PO (pending sync)';

/// New draft order for a job. Material for shipping orders goes to the site by default; otherwise to the shop.
String createPurchaseOrder(AppDb db, String projectId, {String? supplierId, List<PoLine> lines = const []}) {
  final p = db.get('projects', projectId)!;
  return db.tx(() {
    final id = db.insert('purchase_orders', {
      'project_id': projectId,
      'supplier_id': supplierId,
      'status': 'draft',
      'deliver_to': p.ns('order_type') == 'shipping' ? 'site' : 'shop',
    });
    _replaceItems(db, id, lines);
    log(db, projectId, 'Supplier order started');
    return id;
  });
}

void _replaceItems(AppDb db, String poId, List<PoLine> lines) {
  for (final r in poItems(db, poId)) {
    db.softDelete('po_items', r.id);
  }
  var pos = 0;
  for (final l in lines) {
    if (l.description.trim().isEmpty) continue;
    db.insert('po_items', {
      'po_id': poId, 'position': pos++, 'description': l.description.trim(), 'qty': l.qty,
      'received_qty': l.receivedQty, 'notes': l.notes.trim(),
    });
  }
}

/// Save the order. Lines can only change while it's a draft; dates, reference and notes any time.
void savePurchaseOrder(AppDb db, String poId,
    {String? supplierId,
    String? supplierRef,
    String? expectedOn,
    String? deliverTo,
    String? notes,
    List<PoLine>? lines}) {
  final po = db.get('purchase_orders', poId)!;
  db.tx(() {
    db.update('purchase_orders', poId, {
      if (po.s('status') == 'draft') 'supplier_id': supplierId,
      'supplier_ref': supplierRef, 'expected_on': expectedOn, 'deliver_to': deliverTo, 'notes': notes,
    });
    if (lines != null) {
      if (po.s('status') != 'draft') throw BusinessError('Lines can only be changed while the order is a draft.');
      _replaceItems(db, poId, lines);
    }
    touch(db, po.s('project_id'));
  });
}

void markOrdered(AppDb db, String poId, {String? orderedOn, String? expectedOn}) {
  final po = orderWithSupplier(db, poId)!;
  if (po.s('status') != 'draft') throw BusinessError('This order was already sent.');
  if (po.ns('supplier_id') == null) throw BusinessError('Choose the supplier first.');
  if (poItems(db, poId).isEmpty) throw BusinessError('Add at least one line.');
  final on = orderedOn ?? today();
  final lead = po.i('lead_days');
  final expected = expectedOn ?? po.ns('expected_on') ??
      (lead > 0 ? dateOnly(DateTime.parse(on).add(Duration(days: lead))) : null);
  db.tx(() {
    db.update('purchase_orders', poId, {'status': 'ordered', 'ordered_on': on, 'expected_on': expected});
    log(db, po.s('project_id'),
        'Ordered ${poLabel(po)} from ${po.s('supplier')}${expected != null ? ' (expected $expected)' : ''}');
    advanceStatus(db, po.s('project_id'), 'ordered');
  });
}

void markConfirmed(AppDb db, String poId, {String? supplierRef, String? expectedOn}) {
  final po = orderWithSupplier(db, poId)!;
  if (!['ordered', 'confirmed'].contains(po.s('status'))) throw BusinessError('Mark the order as ordered first.');
  db.tx(() {
    db.update('purchase_orders', poId, {
      'status': 'confirmed',
      'supplier_ref': ?supplierRef,
      'expected_on': ?expectedOn,
    });
    log(db, po.s('project_id'),
        '${poLabel(po)} confirmed by ${po.s('supplier')}${(expectedOn ?? po.ns('expected_on')) != null ? ', delivery ${expectedOn ?? po.s('expected_on')}' : ''}');
  });
}

/// Record what arrived. [received] maps item id -> quantity received so far (null = all lines fully).
void receiveItems(AppDb db, String poId, {Map<String, double>? received, String? receivedOn}) {
  final po = orderWithSupplier(db, poId)!;
  if (!['ordered', 'confirmed', 'received'].contains(po.s('status'))) {
    throw BusinessError('Only ordered items can be received.');
  }
  final items = poItems(db, poId);
  db.tx(() {
    for (final it in items) {
      final q = received == null ? it.d('qty') : (received[it.id] ?? it.d('received_qty'));
      if (q != it.d('received_qty')) db.update('po_items', it.id, {'received_qty': q.clamp(0, it.d('qty') * 10)});
    }
    final all = poItems(db, poId).every((i) => i.d('received_qty') >= i.d('qty') - 1e-9);
    if (all && po.s('status') != 'received') {
      db.update('purchase_orders', poId, {'status': 'received', 'received_on': receivedOn ?? today()});
      log(db, po.s('project_id'), '${poLabel(po)} from ${po.s('supplier')} received');
    } else if (!all) {
      log(db, po.s('project_id'), '${poLabel(po)}: part received');
    }
    _checkAllReceived(db, po.s('project_id'));
  });
}

void cancelPurchaseOrder(AppDb db, String poId) {
  final po = orderWithSupplier(db, poId)!;
  db.tx(() {
    db.update('purchase_orders', poId, {'status': 'cancelled'});
    log(db, po.s('project_id'), '${poLabel(po)} cancelled');
    _checkAllReceived(db, po.s('project_id'));
  });
}

void deleteDraftOrder(AppDb db, String poId) {
  final po = db.get('purchase_orders', poId)!;
  if (po.s('status') != 'draft') throw BusinessError('Only drafts can be deleted; cancel the order instead.');
  db.tx(() {
    for (final i in poItems(db, poId)) {
      db.softDelete('po_items', i.id);
    }
    db.softDelete('purchase_orders', poId);
  });
}

/// When every (non-cancelled) supplier order of a job has arrived, the job moves to Received.
void _checkAllReceived(AppDb db, String projectId) {
  final live = projectOrders(db, projectId).where((o) => o.s('status') != 'cancelled').toList();
  if (live.isEmpty || live.any((o) => o.s('status') == 'draft')) return;
  if (live.every((o) => o.s('status') == 'received')) {
    advanceStatus(db, projectId, 'received', 'all materials in');
  }
}

/// Suggested order lines from the job's selections (one line per selection).
List<PoLine> linesFromSelections(AppDb db, String projectId, {String? category}) => [
      for (final s in selectionsFor(db, projectId))
        if (category == null || s.s('category') == category)
          PoLine('${s.s('item')}: ${s.s('choice')}', notes: s.s('notes')),
    ];

/// Suggested order lines from the accepted Cabinet CRM quote, or the latest QuickBooks estimate.
List<PoLine> linesFromQuote(AppDb db, String projectId) {
  final acc = acceptedQuote(db, projectId);
  if (acc != null) {
    return [for (final i in quoteItems(db, acc.id)) PoLine(i.s('description'), qty: i.d('qty'), notes: i.s('category'))];
  }
  final est = db.one('SELECT * FROM qb_estimates WHERE project_id=? AND deleted=0 ORDER BY accepted DESC, txn_date DESC LIMIT 1',
      [projectId]);
  if (est == null) return const [];
  final lines = (jsonDecode(est.ns('lines') ?? '[]') as List).cast<Map<String, dynamic>>();
  return [
    for (final l in lines)
      if (('${l['desc'] ?? l['item'] ?? ''}').trim().isNotEmpty)
        PoLine('${l['desc'] ?? l['item']}', qty: (l['qty'] as num?)?.toDouble() ?? 1, notes: '${l['item'] ?? ''}'),
  ];
}

// ============================================================================ next actions

List<NextAction> ordersNextActions(AppDb db) {
  final t = today();
  final out = <NextAction>[];
  const pj = '''SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
                WHERE p.deleted=0 AND c.deleted=0''';
  for (final p in db.select("$pj AND p.status IN ('approved','invoiced') AND NOT EXISTS "
      "(SELECT 1 FROM purchase_orders o WHERE o.project_id=p.id AND o.deleted=0 AND o.status<>'cancelled')")) {
    out.add(NextAction('order', 'Approved: order the materials', p.s('customer'), '${numberOf(p)} ${p.s('title')}', p.id));
  }
  for (final o in db.select('''SELECT o.*, s.name AS supplier, p.number AS pnum, p.title, p.id AS pid, c.name AS customer
      FROM purchase_orders o JOIN projects p ON p.id=o.project_id JOIN customers c ON c.id=p.customer_id
      LEFT JOIN suppliers s ON s.id=o.supplier_id
      WHERE o.deleted=0 AND p.deleted=0 AND o.status IN ('draft','ordered','confirmed')''')) {
    final ref = '${o.ns('pnum') ?? ''} ${o.s('title')}';
    final who = o.ns('supplier') ?? 'the supplier';
    if (o.s('status') == 'draft') {
      out.add(NextAction('order', '${poLabel(o)} is a draft: send it to $who', o.s('customer'), ref, o.s('pid')));
    } else if (o.ns('expected_on') != null && o.s('expected_on').compareTo(t) < 0) {
      out.add(NextAction('overdue', '${poLabel(o)} from $who was due ${o.s('expected_on')}', o.s('customer'), ref, o.s('pid')));
    } else if (o.s('status') == 'ordered' && o.ns('expected_on') == null && o.ns('ordered_on') != null &&
        dateOnly(DateTime.parse(o.s('ordered_on')).add(const Duration(days: 3))).compareTo(t) <= 0) {
      out.add(NextAction('follow up', 'Get a delivery date for ${poLabel(o)} from $who', o.s('customer'), ref, o.s('pid')));
    }
  }
  return out;
}

/// Orders arriving in the next [days] days (dashboard "Arriving soon").
List<Rec> arrivingSoon(AppDb db, {int days = 7}) => db.select('''
  SELECT o.*, s.name AS supplier, p.number AS pnum, p.title, c.name AS customer
  FROM purchase_orders o JOIN projects p ON p.id=o.project_id JOIN customers c ON c.id=p.customer_id
  LEFT JOIN suppliers s ON s.id=o.supplier_id
  WHERE o.deleted=0 AND p.deleted=0 AND o.status IN ('ordered','confirmed') AND o.expected_on IS NOT NULL
    AND o.expected_on >= ? AND o.expected_on <= ?
  ORDER BY o.expected_on''', [today(), addDays(days)]);
