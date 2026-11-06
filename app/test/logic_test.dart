import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    setSetting(db, 'default_tax_rate', '13');
  });

  test('full workflow: measure -> design -> quote -> revise -> accept -> invoice -> paid', () {
    final cid = saveCustomer(db, {'name': 'Jane Smith', 'address': '1 Main St'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'install');
    final p = db.get('projects', pid)!;
    expect(p.s('number'), matches(RegExp(r'^J-\d{4}-001$')));
    expect(p.s('site_address'), '1 Main St');

    final mid = saveMeasurement(db,
        projectId: pid, room: 'Kitchen', source: 'customer', lines: [MeasureLine('Wall A', '120 1/2', 'in')]);
    expect(db.get('projects', pid)!.s('status'), 'measured');
    expect(measurementItems(db, mid).single.s('value'), '120 1/2');

    final d1 = saveDesign(db, projectId: pid, title: 'L-shape', measurementId: mid);
    expect(db.get('projects', pid)!.s('status'), 'designing');
    expect(projectWarnings(db, pid).any((w) => w.message.contains('not verified')), isTrue);

    final q1 = createQuote(db, pid, designId: d1);
    saveQuote(db, q1, designId: d1, taxRate: 13, discount: 100, depositPct: 50, lines: [
      QuoteLine(category: 'Cabinets', description: 'Shaker', qty: 1, unitPrice: 5000),
      QuoteLine(category: 'Installation', description: 'Install', qty: 2, unitPrice: 500),
    ]);
    expect(quoteTotals(db, q1).total, 6667.00);
    sendQuote(db, q1);
    expect(() => saveQuote(db, q1, taxRate: 0, discount: 0, depositPct: 0, lines: []), throwsA(isA<BusinessError>()));
    expect(db.get('projects', pid)!.s('status'), 'quoted');

    final d2 = saveDesign(db, projectId: pid, title: 'with island', measurementId: mid);
    expect(projectWarnings(db, pid).any((w) => w.message.contains('latest design is v2')), isTrue);

    final q2 = reviseQuote(db, q1);
    final rq = db.get('quotes', q2)!;
    expect(rq.i('revision'), 2);
    expect(rq.s('number'), db.get('quotes', q1)!.s('number'));
    expect(rq.s('design_id'), d2);
    expect(db.get('quotes', q1)!.s('status'), 'superseded');
    expect(quoteItems(db, q2).length, 2);

    sendQuote(db, q2);
    acceptQuote(db, q2);
    expect(db.get('designs', d2)!.s('status'), 'approved');
    expect(db.get('designs', d1)!.s('status'), 'superseded');
    expect(db.get('projects', pid)!.s('status'), 'approved');
    expect(nextActions(db).any((a) => a.kind == 'invoice'), isTrue);
    expect(nextActions(db).any((a) => a.kind == 'verify'), isTrue);

    expect(() => createInvoice(db, q1, kind: 'deposit', amount: 10), throwsA(isA<BusinessError>()));
    expect(suggestedInvoiceAmount(db, q2, 'deposit'), 3333.50);
    final i1 = createInvoice(db, q2, kind: 'deposit', amount: 3333.50);
    expect(db.get('invoices', i1)!.s('number'), matches(RegExp(r'^INV-\d{4}-001$')));
    expect(() => createInvoice(db, q2, kind: 'final', amount: 99999), throwsA(isA<BusinessError>()));
    final i2 = createInvoice(db, q2, kind: 'final', amount: suggestedInvoiceAmount(db, q2, 'final'));
    expect(db.get('invoices', i2)!.d('amount'), 3333.50);

    addPayment(db, i1, amount: 3333.50);
    expect(db.get('invoices', i1)!.s('status'), 'paid');
    expect(db.get('projects', pid)!.s('status'), 'approved', reason: 'payments no longer drive production stages');
    verifyMeasurement(db, mid);
    addPayment(db, i2, amount: 3333.50);
    expect(db.get('projects', pid)!.s('status'), 'approved', reason: 'paid in full, but not installed yet');
    markCompleted(db, pid);
    expect(db.get('projects', pid)!.s('status'), 'paid');
    expect(projectWarnings(db, pid), isEmpty);
  });

  test('PIN hashing', () {
    final h = hashPin('4321');
    expect(checkPin('4321', h), isTrue);
    expect(checkPin('1234', h), isFalse);
  });

  test('numbers are sequential per year', () {
    final cid = saveCustomer(db, {'name': 'A'});
    createProject(db, customerId: cid, title: 'x');
    final b = createProject(db, customerId: cid, title: 'y');
    expect(db.get('projects', b)!.s('number'), endsWith('-002'));
  });

  test('deleting a project soft-deletes its children', () {
    final cid = saveCustomer(db, {'name': 'A'});
    final pid = createProject(db, customerId: cid, title: 'x');
    final mid = saveMeasurement(db, projectId: pid, room: 'K', source: 'onsite', lines: []);
    deleteCustomer(db, cid);
    expect(db.get('measurements', mid), isNull);
    expect(customersList(db), isEmpty);
  });

  test('measurement sources: colour-coded, all but on-site need verifying, photo guesses warn hardest', () {
    final cid = saveCustomer(db, {'name': 'A'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen');
    expect(measurementSources.map((s) => s.key).toSet(), hasLength(measurementSources.length));
    final onsite = saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'onsite', lines: []);
    expect(db.get('measurements', onsite)!.b('verified'), isTrue);
    final photo = saveMeasurement(db, projectId: pid, room: 'Pantry', source: 'photo', lines: []);
    final m = db.get('measurements', photo)!;
    expect(m.s('source'), 'photo');
    expect(m.b('verified'), isFalse);
    // A photo guess warns even before there is a design.
    expect(projectWarnings(db, pid).single.message, contains('guessed from photos'));
    saveMeasurement(db, projectId: pid, room: 'Laundry', source: 'plans', lines: []);
    saveDesign(db, projectId: pid, title: 'v1');
    expect(projectWarnings(db, pid).any((w) => w.message.contains('from plans')), isTrue);
    // Approved job with unverified plans/photo numbers -> "verify" next action.
    setStatus(db, pid, 'approved');
    expect(nextActions(db).any((a) => a.kind == 'verify' && a.projectId == pid), isTrue);
    // Unknown source values (e.g. from a newer app version) are kept safe as "needs verifying".
    final odd = saveMeasurement(db, projectId: pid, room: 'X', source: 'nonsense', lines: []);
    expect(db.get('measurements', odd)!.s('source'), 'customer');
    expect(sourceOf('nonsense').needsVerify, isTrue);
  });

  test('order type: pickup / shipping / installation drive the checks', () {
    final cid = saveCustomer(db, {'name': 'A', 'address': '1 Main St'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'pickup');
    expect(db.get('projects', pid)!.s('order_type'), 'pickup');
    saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'customer', lines: []);
    final d = saveDesign(db, projectId: pid);
    final q = createQuote(db, pid, designId: d);
    saveQuote(db, q, designId: d, taxRate: 0, discount: 0, depositPct: 50, lines: [
      QuoteLine(category: 'Cabinets', description: 'Boxes', unitPrice: 1000),
      QuoteLine(category: 'Installation', description: 'Install', unitPrice: 500),
    ]);
    var w = projectWarnings(db, pid).map((w) => w.message).toList();
    expect(w.any((m) => m.contains('includes installation') && m.contains('pickup')), isTrue);
    expect(w.any((m) => m.contains('sign off')), isTrue, reason: 'pickup jobs: customer sign-off, not site verify');

    setOrderType(db, pid, 'install');
    w = projectWarnings(db, pid).map((w) => w.message).toList();
    expect(w.any((m) => m.contains('includes installation')), isFalse);
    expect(w.any((m) => m.contains('not verified on site')), isTrue);

    setOrderType(db, pid, 'shipping');
    expect(projectWarnings(db, pid).any((w) => w.message.contains('no Delivery')), isTrue);
    expect(projectsList(db, orderType: 'shipping').single.id, pid);
    expect(projectsList(db, orderType: 'none'), isEmpty);

    setOrderType(db, pid, null);
    expect(projectWarnings(db, pid).any((w) => w.message.contains('Order type not set')), isTrue);
  });

  test('stages: legacy Invoiced reads as Approved; completed label follows the order type', () {
    final cid = saveCustomer(db, {'name': 'Old'});
    final pid = createProject(db, customerId: cid, title: 'K');
    db.update('projects', pid, {'status': 'invoiced'});
    expect(stageLabel('invoiced'), 'Approved');
    migrateStages(db);
    expect(db.get('projects', pid)!.s('status'), 'approved');
    expect(completedLabel('pickup'), 'Picked up');
    expect(completedLabel('shipping'), 'Delivered');
    expect(completedLabel('install'), 'Installed');
    markCompleted(db, pid);
    expect(db.get('projects', pid)!.s('status'), 'completed');
    expect(activeStages, contains('completed'));
  });
}
