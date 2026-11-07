/// QuickBooks Desktop sync engine (driven by the QuickBooks Web Connector, see qbwc_server.dart).
///
/// One run:
///   1. read all QuickBooks customers and jobs → link them to Casework customers and jobs
///      (repeat customers are matched by name or phone, never duplicated) and import QuickBooks
///      customers Casework doesn't have yet;
///   2. create Casework customers and jobs that are missing in QuickBooks (as Customer:Job);
///   3. read estimates changed since the last run → show them on the job, move the job to
///      Quoted / Approved.
///
/// Pure Dart: [nextRequest] returns qbXML to send, [handleResponse] consumes QuickBooks' reply.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/logic.dart';
import 'qbxml.dart';

enum _Step { customers, addCustomers, addJobs, estimates, done }

class QbSync extends ChangeNotifier {
  QbSync(this.db);
  final AppDb db;

  // ------------------------------------------------------------------ settings (local meta, main PC only)

  bool get enabled => db.meta('qb_enabled') == '1';
  bool get importCustomers => (db.meta('qb_import_customers') ?? '1') == '1';
  bool get createJobs => (db.meta('qb_create_jobs') ?? '1') == '1';
  String? get lastRun => db.meta('qb_last_run');
  String? get lastResult => db.meta('qb_last_result');
  String? get lastError => db.meta('qb_last_error');
  List<String> get lastLog => ((jsonDecode(db.meta('qb_last_log') ?? '[]') as List).cast<String>());

  void configure({bool? enabled, bool? importCustomers, bool? createJobs}) {
    if (enabled != null) db.setMeta('qb_enabled', enabled ? '1' : '0');
    if (importCustomers != null) db.setMeta('qb_import_customers', importCustomers ? '1' : '0');
    if (createJobs != null) db.setMeta('qb_create_jobs', createJobs ? '1' : '0');
    notifyListeners();
  }

  /// Stable ids for the Web Connector file.
  String get ownerId => db.meta('qb_owner_id') ?? db.setMeta('qb_owner_id', '{${newId().toUpperCase()}}');
  String get fileId => db.meta('qb_file_id') ?? db.setMeta('qb_file_id', '{${newId().toUpperCase()}}');

  // ------------------------------------------------------------------ run state

  bool running = false;
  _Step _step = _Step.done;
  String? _iterator;
  final _qbCustomers = <String, QbCustomer>{}; // ListID -> customer/job
  final _log = <String>[];
  final _pendingAdds = <String, (String kind, String cabinetId, String name, String? parent)>{}; // requestID ->
  final _retry = <(String kind, String cabinetId)>[];
  int _addSeq = 0, _linked = 0, _imported = 0, _created = 0, _estimates = 0;
  String? _maxModified;
  String? error;

  void _note(String s) {
    _log.add(s);
    if (_log.length > 200) _log.removeAt(0);
  }

  /// Start a run (called when the Web Connector authenticates).
  void begin() {
    running = true;
    _step = _Step.customers;
    _iterator = null;
    _qbCustomers.clear();
    _log.clear();
    _pendingAdds.clear();
    _retry.clear();
    _linked = _imported = _created = _estimates = 0;
    _maxModified = null;
    error = null;
    _note('Started ${DateTime.now().toIso8601String()}');
    notifyListeners();
  }

  /// Next qbXML request, or null when the run is finished.
  String? nextRequest() {
    switch (_step) {
      case _Step.customers:
        return qbxmlDoc(customerQueryRq(iteratorId: _iterator));
      case _Step.addCustomers:
      case _Step.addJobs:
        final batch = _buildAdds(_step == _Step.addCustomers ? 'customer' : 'job');
        if (batch == null) {
          _step = _step == _Step.addCustomers ? _Step.addJobs : _Step.estimates;
          _iterator = null;
          return nextRequest();
        }
        return batch;
      case _Step.estimates:
        return qbxmlDoc(estimateQueryRq(fromModified: _estimatesFrom(), iteratorId: _iterator));
      case _Step.done:
        return null;
    }
  }

  /// Consume QuickBooks' reply. Returns progress 0-100 (100 = finished).
  int handleResponse(String xml) {
    try {
      final responses = parseQbxml(xml);
      db.tx(() {
        switch (_step) {
          case _Step.customers:
            _onCustomers(responses);
          case _Step.addCustomers:
          case _Step.addJobs:
            _onAdds(responses);
          case _Step.estimates:
            _onEstimates(responses);
          case _Step.done:
            break;
        }
      });
    } catch (e) {
      fail('Could not read QuickBooks\' reply: $e');
      return -1;
    }
    if (_step == _Step.done) return 100;
    // Peek whether there is anything left to send.
    if (_step == _Step.addCustomers || _step == _Step.addJobs) {
      return 60;
    }
    return switch (_step) { _Step.customers => 20, _Step.estimates => 80, _ => 50 };
  }

  void fail(String message) {
    error = message;
    _note('Error: $message');
    _step = _Step.done;
    _finish(ok: false);
  }

  /// Called when the Web Connector ends the session (also after errors).
  void end() {
    if (running) _finish(ok: error == null);
  }

  void _finish({required bool ok}) {
    if (!running) return;
    running = false;
    final summary = ok
        ? '$_linked linked, $_imported imported from QuickBooks, $_created created in QuickBooks, '
            '$_estimates estimate(s) updated.'
        : 'Stopped: ${error ?? 'unknown error'}';
    db.setMeta('qb_last_run', DateTime.now().toIso8601String());
    db.setMeta('qb_last_result', summary);
    if (ok) {
      db.raw.execute("DELETE FROM meta WHERE key='qb_last_error'");
      if (_maxModified != null) db.setMeta('qb_last_estimate_sync', _maxModified!);
    } else {
      db.setMeta('qb_last_error', error ?? 'unknown error');
    }
    _note(summary);
    db.setMeta('qb_last_log', jsonEncode(_log));
    db.changed();
    notifyListeners();
  }

  // ------------------------------------------------------------------ step 1: customers & jobs

  void _onCustomers(List<QbResponse> responses) {
    final r = responses.where((r) => r.type == 'CustomerQueryRs').firstOrNull;
    if (r == null || !r.ok) {
      throw StateError('CustomerQuery failed: ${r?.statusMessage ?? 'no response'}');
    }
    for (final e in r.rets('CustomerRet')) {
      final c = QbCustomer.fromXml(e);
      if (c.listId.isNotEmpty) _qbCustomers[c.listId] = c;
    }
    if (r.iteratorId != null && r.remaining > 0) {
      _iterator = r.iteratorId;
      return;
    }
    _iterator = null;
    _note('Read ${_qbCustomers.length} QuickBooks customers and jobs.');
    _link();
    _step = _Step.addCustomers;
  }

  static String nameKey(String name) {
    var n = name.toLowerCase();
    if (n.contains(',')) {
      // "Smith, Jane" -> "jane smith"
      final i = n.indexOf(',');
      n = '${n.substring(i + 1)} ${n.substring(0, i)}';
    }
    final words = n.replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ').split(' ').where((w) => w.isNotEmpty).toList()..sort();
    return words.join(' ');
  }

  static String phoneKey(String? phone) {
    final d = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (d.length < 7) return '';
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  void _link() {
    final topLevel = _qbCustomers.values.where((c) => !c.isJob).toList();
    final linkedIds = db
        .select('SELECT qb_list_id FROM customers WHERE qb_list_id IS NOT NULL AND deleted=0')
        .map((r) => r.s('qb_list_id'))
        .toSet();
    // Customers.
    for (final c in db.select('SELECT * FROM customers WHERE deleted=0 AND qb_list_id IS NULL')) {
      final key = nameKey(c.s('name'));
      final ph = phoneKey(c.ns('phone'));
      var matches = topLevel.where((q) => !linkedIds.contains(q.listId) && nameKey(q.name) == key).toList();
      if (matches.length > 1 && ph.isNotEmpty) {
        matches = matches.where((q) => phoneKey(q.phone) == ph).toList();
      }
      if (matches.isEmpty && ph.isNotEmpty) {
        matches = topLevel.where((q) => !linkedIds.contains(q.listId) && phoneKey(q.phone) == ph).toList();
      }
      if (matches.length == 1) {
        db.update('customers', c.id, {'qb_list_id': matches.first.listId});
        linkedIds.add(matches.first.listId);
        _linked++;
        _note('Linked customer ${c.s('name')} ↔ QuickBooks "${matches.first.fullName}".');
      } else if (matches.length > 1) {
        _note('Several QuickBooks customers match ${c.s('name')}: not linked. Link it by hand in QuickBooks names.');
      }
    }
    // Import QuickBooks customers Casework doesn't know (repeat customers).
    if (importCustomers) {
      for (final q in topLevel.where((q) => q.isActive && !linkedIds.contains(q.listId))) {
        db.insert('customers', {
          'name': q.name, 'phone': q.phone, 'email': q.email, 'address': q.address,
          'source': 'QuickBooks', 'qb_list_id': q.listId,
        });
        linkedIds.add(q.listId);
        _imported++;
      }
      if (_imported > 0) _note('Imported $_imported customer(s) from QuickBooks.');
    }
    // Jobs.
    for (final p in db.select('''SELECT p.*, c.qb_list_id AS cust_qb FROM projects p JOIN customers c ON c.id=p.customer_id
                                 WHERE p.deleted=0 AND p.qb_list_id IS NULL AND c.qb_list_id IS NOT NULL''')) {
      final jobs = _qbCustomers.values.where((q) => q.isJob && q.parentListId == p.s('cust_qb')).toList();
      final number = p.ns('number');
      final title = nameKey(p.s('title'));
      final match = jobs.where((j) => number != null && RegExp('^${RegExp.escape(number.toUpperCase())}(\\s|\$)').hasMatch(j.name.toUpperCase())).firstOrNull ??
          jobs.where((j) => nameKey(j.name) == title).firstOrNull;
      if (match != null) {
        db.update('projects', p.id, {'qb_list_id': match.listId, 'qb_full_name': match.fullName});
        _linked++;
        _note('Linked job ${number ?? p.s('title')} ↔ QuickBooks "${match.fullName}".');
      }
    }
  }

  // ------------------------------------------------------------------ step 2: create in QuickBooks

  String? _buildAdds(String kind) {
    _pendingAdds.clear();
    final b = StringBuffer();
    if (kind == 'customer') {
      final taken = _qbCustomers.values.where((q) => !q.isJob).map((q) => q.name.toLowerCase()).toSet();
      final rows = db.select('''SELECT c.* FROM customers c WHERE c.deleted=0 AND c.qb_list_id IS NULL AND EXISTS
                                (SELECT 1 FROM projects p WHERE p.customer_id=c.id AND p.deleted=0)
                                ORDER BY c.created_at''');
      for (final c in rows.where((c) => !_gaveUp(c.id)).take(20)) {
        final name = qbName(c.s('name'), taken);
        final rid = 'a${++_addSeq}';
        _pendingAdds[rid] = ('customer', c.id, name, null);
        b.write(customerAddRq(requestId: rid, name: name, phone: c.ns('phone'), email: c.ns('email'), address: c.ns('address')));
      }
    } else {
      if (!createJobs) return null;
      final rows = db.select('''SELECT p.*, c.qb_list_id AS cust_qb FROM projects p JOIN customers c ON c.id=p.customer_id
                                WHERE p.deleted=0 AND p.qb_list_id IS NULL AND p.number IS NOT NULL
                                AND c.qb_list_id IS NOT NULL AND p.status<>'lost' ORDER BY p.created_at''');
      for (final p in rows.where((p) => !_gaveUp(p.id)).take(20)) {
        final parent = p.s('cust_qb');
        final taken = _qbCustomers.values.where((q) => q.parentListId == parent).map((q) => q.name.toLowerCase()).toSet();
        final name = qbName('${p.s('number')} ${p.s('title')}', taken);
        final rid = 'a${++_addSeq}';
        _pendingAdds[rid] = ('job', p.id, name, parent);
        b.write(customerAddRq(
          requestId: rid, name: name, parentListId: parent, address: p.ns('site_address'),
          jobStatus: _jobStatus(p.s('status')), jobDesc: p.ns('site_address'),
        ));
      }
    }
    return _pendingAdds.isEmpty ? null : qbxmlDoc(b.toString());
  }

  bool _gaveUp(String id) => _retry.any((r) => r.$2 == id && r.$1 == 'gaveup');

  static String _jobStatus(String status) => switch (normalizeStage(status)) {
        'lost' => 'NotAwarded',
        'approved' => 'Awarded',
        'ordered' || 'received' => 'InProgress',
        'completed' || 'paid' || 'closed' => 'Closed',
        _ => 'Pending',
      };

  void _onAdds(List<QbResponse> responses) {
    for (final r in responses.where((r) => r.type == 'CustomerAddRs')) {
      final pending = _pendingAdds[r.requestId];
      if (pending == null) continue;
      final (kind, id, name, _) = pending;
      final ret = r.rets('CustomerRet').firstOrNull;
      if (r.statusCode == 0 && ret != null) {
        final c = QbCustomer.fromXml(ret);
        _qbCustomers[c.listId] = c;
        if (kind == 'customer') {
          db.update('customers', id, {'qb_list_id': c.listId});
        } else {
          db.update('projects', id, {'qb_list_id': c.listId, 'qb_full_name': c.fullName});
        }
        _created++;
        _note('Created in QuickBooks: ${c.fullName}');
      } else if (r.statusCode == 3100) {
        // Name already used (e.g. an inactive or vendor/employee name): try the next suffix, then give up.
        _qbCustomers['taken-${r.requestId}'] = QbCustomer(
            listId: 'taken-${r.requestId}', name: name, fullName: name,
            parentListId: pending.$4, sublevel: pending.$4 == null ? 0 : 1);
        final tries = _retry.where((x) => x.$2 == id).length;
        if (tries >= 3) {
          _retry.add(('gaveup', id));
          _note('Could not add "$name" to QuickBooks: ${r.statusMessage}');
        } else {
          _retry.add((kind, id));
        }
      } else {
        _retry.add(('gaveup', id));
        _note('QuickBooks refused "$name": ${r.statusMessage} (${r.statusCode})');
      }
    }
  }

  // ------------------------------------------------------------------ step 3: estimates

  String _estimatesFrom() =>
      db.meta('qb_last_estimate_sync') ?? qbDateTime(DateTime.now().subtract(const Duration(days: 365)));

  void _onEstimates(List<QbResponse> responses) {
    final r = responses.where((r) => r.type == 'EstimateQueryRs').firstOrNull;
    if (r == null || !r.ok) throw StateError('EstimateQuery failed: ${r?.statusMessage ?? 'no response'}');
    for (final e in r.rets('EstimateRet')) {
      final est = QbEstimate.fromXml(e);
      if (est.txnId.isEmpty) continue;
      upsertEstimate(est);
      final tm = est.timeModified;
      if (tm != null && (_maxModified == null || tm.compareTo(_maxModified!) > 0)) _maxModified = tm;
    }
    if (r.iteratorId != null && r.remaining > 0) {
      _iterator = r.iteratorId;
      return;
    }
    _step = _Step.done;
    _finish(ok: true);
  }

  /// Store one QuickBooks estimate and link it to a job. Public for tests.
  void upsertEstimate(QbEstimate est) {
    String? projectId, customerId;
    final ref = est.customerListId;
    if (ref != null) {
      final p = db.one('SELECT * FROM projects WHERE qb_list_id=? AND deleted=0', [ref]);
      if (p != null) {
        projectId = p.id;
        customerId = p.s('customer_id');
      } else {
        // Estimate on the customer itself (or on a QuickBooks job not linked to a Casework job).
        var custRef = ref;
        final q = _qbCustomers[ref];
        if (q != null && q.isJob && q.parentListId != null) custRef = q.parentListId!;
        final c = db.one('SELECT * FROM customers WHERE qb_list_id=? AND deleted=0', [custRef]);
        if (c != null) {
          customerId = c.id;
          final open = db.select(
              "SELECT id FROM projects WHERE customer_id=? AND deleted=0 AND status NOT IN ('closed','lost','paid')", [c.id]);
          if (open.length == 1) projectId = open.first.id;
        }
      }
    }
    final existing = db.one('SELECT * FROM qb_estimates WHERE qb_txn_id=?', [est.txnId]);
    final values = <String, Object?>{
      'project_id': projectId ?? existing?.ns('project_id'),
      'customer_id': customerId ?? existing?.ns('customer_id'),
      'qb_txn_id': est.txnId,
      'ref_number': est.refNumber,
      'txn_date': est.txnDate,
      'subtotal': est.subtotal,
      'tax': est.tax,
      'total': est.total,
      'is_active': est.isActive ? 1 : 0,
      'accepted': est.accepted ? 1 : 0,
      'memo': est.memo,
      'lines': jsonEncode(est.lines.map((l) => l.toJson()).toList()),
      'qb_customer': est.customerFullName,
      'time_modified': est.timeModified,
      'deleted': 0,
    };
    if (existing == null) {
      db.insert('qb_estimates', values);
    } else {
      db.update('qb_estimates', existing.id, values);
    }
    _estimates++;
    final pid = values['project_id'] as String?;
    if (pid == null) {
      _note('Estimate #${est.refNumber ?? '?'} (${est.customerFullName}) is not linked to a job yet.');
      return;
    }
    final label = 'QuickBooks estimate #${est.refNumber ?? ''}';
    if (existing == null || existing.ns('project_id') != pid) {
      log(db, pid, '$label: ${est.total.toStringAsFixed(2)}', kind: 'money');
      advanceStatus(db, pid, 'quoted', label);
    }
    if (est.accepted && !(existing?.b('accepted') ?? false)) {
      advanceStatus(db, pid, 'approved', '$label accepted in QuickBooks');
    }
  }
}

/// QuickBooks estimates for a job (newest first).
List<Rec> qbEstimatesFor(AppDb db, String projectId) => db.select(
    'SELECT * FROM qb_estimates WHERE project_id=? AND deleted=0 ORDER BY txn_date DESC, time_modified DESC', [projectId]);

/// The estimate to use for the job packet: accepted one, else the newest active one.
Rec? currentQbEstimate(AppDb db, String projectId) {
  final all = qbEstimatesFor(db, projectId);
  return all.where((e) => e.b('accepted')).firstOrNull ?? all.where((e) => e.b('is_active')).firstOrNull ?? all.firstOrNull;
}

List<Map<String, dynamic>> qbEstimateLines(Rec e) =>
    ((jsonDecode(e.ns('lines') ?? '[]') as List).cast<Map<String, dynamic>>());

bool quotesInQuickBooks(AppDb db) => settings(db)['quotes_in_quickbooks'] == '1';
