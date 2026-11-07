import 'dart:convert';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/core/reports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    db.currentUserId = createUser(db, name: 'Owner', role: 'owner', pin: '1111');
  });

  String job(String orderType, {String measuredOn = '2026-10-01'}) {
    final pid = createProject(db, customerId: saveCustomer(db, {'name': 'C'}), title: 'Kitchen', orderType: orderType);
    saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'onsite', takenOn: measuredOn, lines: []);
    return pid;
  }

  String quote(String pid, double price, {required String sentOn}) {
    final q = createQuote(db, pid);
    saveQuote(db, q, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: price)]);
    sendQuote(db, q);
    db.update('quotes', q, {'sent_on': sentOn});
    return q;
  }

  test('sent, won, lost, win rate, days and order types', () {
    final a = job('install');
    final qa = quote(a, 10000, sentOn: '2026-10-08'); // 7 days after measuring
    acceptQuote(db, qa);
    db.update('quotes', qa, {'decided_on': '2026-11-02'});

    final b = job('pickup', measuredOn: '2026-10-20');
    final qb = quote(b, 2000, sentOn: '2026-10-23');
    declineQuote(db, qb);
    db.update('quotes', qb, {'decided_on': '2026-10-30'});

    final c = job('shipping', measuredOn: '2026-11-01');
    quote(c, 500, sentOn: '2026-11-05'); // still open

    final inv = createInvoice(db, qa, kind: 'deposit', amount: 5000);
    addPayment(db, inv, amount: 5000, paidOn: '2026-11-03');

    final r = buildReport(db, now: DateTime(2026, 11, 15), months: 12);
    expect(r.months.first.month, '2025-12');
    expect(r.months.last.month, '2026-11');
    final oct = r.months.firstWhere((m) => m.month == '2026-10');
    final nov = r.months.firstWhere((m) => m.month == '2026-11');
    expect((oct.sent, oct.sentValue, oct.lost), (2, 12000.0, 1));
    expect(oct.avgMeasureToQuote, 5.0); // (7 + 3) / 2
    expect((nov.sent, nov.won, nov.wonValue, nov.collected), (1, 1, 10000.0, 5000.0));
    expect(r.total.winRate, 0.5);
    expect((r.openQuotes, r.openValue), (1, 500.0));
    final install = r.byOrderType.firstWhere((t) => t.key == 'install');
    expect((install.jobsWon, install.wonValue, install.collected), (1, 10000.0, 5000.0));
    expect(r.byOrderType.any((t) => t.key == 'pickup'), isFalse, reason: 'nothing won or collected');
  });

  test('a revised quote counts once, in the month first sent, at its latest price', () {
    final a = job('install');
    final q1 = quote(a, 8000, sentOn: '2026-09-10');
    final q2 = reviseQuote(db, q1);
    saveQuote(db, q2, taxRate: 0, discount: 0, depositPct: 50, lines: [QuoteLine(description: 'Boxes', unitPrice: 9000)]);
    sendQuote(db, q2);
    db.update('quotes', q2, {'sent_on': '2026-10-01'});
    final r = buildReport(db, now: DateTime(2026, 11, 15));
    final sep = r.months.firstWhere((m) => m.month == '2026-09');
    expect((sep.sent, sep.sentValue), (1, 9000.0));
    expect(r.total.sent, 1);
  });

  test('QuickBooks estimates count as quotes', () {
    final a = job('install');
    db.insert('qb_estimates', {
      'project_id': a, 'qb_txn_id': 'T1', 'ref_number': '1001', 'txn_date': '2026-10-10', 'total': 7000.0,
      'is_active': 0, 'accepted': 1, 'time_modified': '2026-10-20T10:00:00', 'lines': jsonEncode([]),
    });
    db.insert('qb_estimates', {
      'project_id': a, 'qb_txn_id': 'T2', 'ref_number': '1002', 'txn_date': '2026-11-01', 'total': 300.0,
      'is_active': 1, 'accepted': 0, 'lines': jsonEncode([]),
    });
    final r = buildReport(db, now: DateTime(2026, 11, 15));
    final oct = r.months.firstWhere((m) => m.month == '2026-10');
    expect((oct.sent, oct.won, oct.wonValue), (1, 1, 7000.0));
    expect(oct.avgMeasureToQuote, 9.0);
    expect((r.openQuotes, r.openValue), (1, 300.0));
  });

  test('periods: this year so far and last year', () {
    expect(monthRange(DateTime(2026, 1), DateTime(2026, 3)), ['2026-01', '2026-02', '2026-03']);
    expect(buildReport(db, now: DateTime(2025, 12, 31)).months.map((m) => m.month).first, '2025-01');
    expect(buildReport(db, now: DateTime(2026, 4, 2), months: 4).months.length, 4);
  });
}
