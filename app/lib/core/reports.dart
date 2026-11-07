/// Numbers for the Reports screen (owner / office only): quotes sent and won per month,
/// how long jobs take from measure to quote, and money collected by order type.
///
/// Works with Casework quotes and with QuickBooks estimates (quotes made in QuickBooks),
/// and counts payments recorded here plus payments read from QuickBooks.
library;

import 'db.dart';
import 'logic.dart';

class MonthStats {
  MonthStats(this.month);
  final String month; // yyyy-MM
  int sent = 0, won = 0, lost = 0;
  double sentValue = 0, wonValue = 0, collected = 0;
  final measureToQuoteDays = <int>[];
  final quoteToDecisionDays = <int>[];

  double? get winRate => (won + lost) == 0 ? null : won / (won + lost);
  double? get avgMeasureToQuote => _avg(measureToQuoteDays);
  double? get avgQuoteToDecision => _avg(quoteToDecisionDays);
  static double? _avg(List<int> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

  void add(MonthStats o) {
    sent += o.sent;
    won += o.won;
    lost += o.lost;
    sentValue += o.sentValue;
    wonValue += o.wonValue;
    collected += o.collected;
    measureToQuoteDays.addAll(o.measureToQuoteDays);
    quoteToDecisionDays.addAll(o.quoteToDecisionDays);
  }
}

class OrderTypeStats {
  OrderTypeStats(this.key, this.label);
  final String? key;
  final String label;
  int jobsWon = 0;
  double wonValue = 0, collected = 0;
}

class Report {
  Report(this.months, this.total, this.byOrderType, this.openQuotes, this.openValue);
  final List<MonthStats> months; // oldest first
  final MonthStats total;
  final List<OrderTypeStats> byOrderType;
  final int openQuotes;
  final double openValue;
}

String monthOf(String? isoDate) => (isoDate == null || isoDate.length < 7) ? '' : isoDate.substring(0, 7);

int? _days(String? from, String? to) {
  final a = DateTime.tryParse(from ?? ''), b = DateTime.tryParse(to ?? '');
  if (a == null || b == null) return null;
  final d = DateTime(b.year, b.month, b.day).difference(DateTime(a.year, a.month, a.day)).inDays;
  return d < 0 ? null : d;
}

/// Months from [from] to [to] inclusive, as yyyy-MM.
List<String> monthRange(DateTime from, DateTime to) {
  final out = <String>[];
  var y = from.year, m = from.month;
  while (y < to.year || (y == to.year && m <= to.month)) {
    out.add('$y-${m.toString().padLeft(2, '0')}');
    if (++m > 12) {
      m = 1;
      y++;
    }
  }
  return out;
}

/// The report for the [months] ending with the month of [now] (default: the last 12).
Report buildReport(AppDb db, {DateTime? now, int months = 12}) {
  final end = now ?? DateTime.now();
  final keys = monthRange(DateTime(end.year, end.month - months + 1), end);
  final byMonth = {for (final k in keys) k: MonthStats(k)};
  MonthStats? at(String? date) => byMonth[monthOf(date)];

  final orderLabels = {for (final o in orderTypes) o.key: o.short};
  final byType = <String?, OrderTypeStats>{
    for (final o in orderTypes) o.key: OrderTypeStats(o.key, o.short),
    null: OrderTypeStats(null, 'Not set'),
  };
  OrderTypeStats typeOf(String? k) => byType[orderLabels.containsKey(k) ? k : null]!;

  // First measurement date per job (when we measured or were sent measurements).
  final measured = <String, String>{
    for (final r in db.select('''SELECT project_id, MIN(coalesce(taken_on, substr(created_at,1,10))) d
        FROM measurements WHERE deleted=0 GROUP BY project_id'''))
      r.s('project_id'): r.s('d'),
  };
  final orderType = <String, String?>{
    for (final p in db.select('SELECT id, order_type FROM projects WHERE deleted=0')) p.id: p.ns('order_type'),
  };

  // ---- Casework quotes: one per quote number (revisions are the same quote).
  final quotes = db.select("SELECT * FROM quotes WHERE deleted=0 AND number IS NOT NULL AND sent_on IS NOT NULL "
      'ORDER BY number, revision');
  final byNumber = <String, List<Rec>>{};
  for (final q in quotes) {
    (byNumber[q.s('number')] ??= []).add(q);
  }
  var openQuotes = 0;
  var openValue = 0.0;
  for (final revs in byNumber.values) {
    final first = revs.first, last = revs.last;
    final pid = first.s('project_id');
    final value = quoteTotals(db, last.id).total;
    if (at(first.ns('sent_on')) case final m?) {
      m.sent++;
      m.sentValue += value;
      if (_days(measured[pid], first.ns('sent_on')) case final d?) m.measureToQuoteDays.add(d);
    }
    final accepted = revs.where((r) => r.s('status') == 'accepted').firstOrNull;
    final status = accepted?.s('status') ?? last.s('status');
    final decided = accepted?.ns('decided_on') ?? last.ns('decided_on');
    if (status == 'accepted' || status == 'declined') {
      if (at(decided) case final m?) {
        if (status == 'accepted') {
          final v = quoteTotals(db, accepted!.id).total;
          m.won++;
          m.wonValue += v;
          final t = typeOf(orderType[pid]);
          t.jobsWon++;
          t.wonValue += v;
        } else {
          m.lost++;
        }
        if (_days(first.ns('sent_on'), decided) case final d?) m.quoteToDecisionDays.add(d);
      }
    } else if (status == 'sent') {
      openQuotes++;
      openValue += value;
    }
  }

  // ---- QuickBooks estimates (quotes made in QuickBooks).
  for (final e in db.select('SELECT * FROM qb_estimates WHERE deleted=0')) {
    final pid = e.ns('project_id');
    final total = e.d('total');
    if (at(e.ns('txn_date')) case final m?) {
      m.sent++;
      m.sentValue += total;
      if (pid != null) {
        if (_days(measured[pid], e.ns('txn_date')) case final d?) m.measureToQuoteDays.add(d);
      }
    }
    if (e.b('accepted')) {
      final decided = monthOf(e.ns('time_modified')).isEmpty ? e.ns('txn_date') : e.s('time_modified').substring(0, 10);
      if (at(decided) case final m?) {
        m.won++;
        m.wonValue += total;
        final t = typeOf(pid == null ? null : orderType[pid]);
        t.jobsWon++;
        t.wonValue += total;
        if (_days(e.ns('txn_date'), decided) case final d?) m.quoteToDecisionDays.add(d);
      }
    } else if (e.b('is_active')) {
      openQuotes++;
      openValue += total;
    } else if (at(e.ns('time_modified')) case final m?) {
      m.lost++; // closed in QuickBooks without being accepted
    }
  }

  // ---- Money collected: payments recorded here, plus payments read from QuickBooks.
  for (final p in db.select('''SELECT pay.amount, pay.paid_on, i.project_id FROM payments pay
      JOIN invoices i ON i.id=pay.invoice_id WHERE pay.deleted=0 AND i.deleted=0''')) {
    if (at(p.ns('paid_on')) case final m?) {
      m.collected += p.d('amount');
      typeOf(orderType[p.s('project_id')]).collected += p.d('amount');
    }
  }
  for (final p in db.select('SELECT amount, txn_date, project_id FROM qb_payments WHERE deleted=0')) {
    if (at(p.ns('txn_date')) case final m?) {
      m.collected += p.d('amount');
      typeOf(p.ns('project_id') == null ? null : orderType[p.s('project_id')]).collected += p.d('amount');
    }
  }

  final total = MonthStats('total');
  for (final m in byMonth.values) {
    total.add(m);
  }
  final types = byType.values.where((t) => t.jobsWon > 0 || t.collected > 0).toList()
    ..sort((a, b) => b.wonValue.compareTo(a.wonValue));
  return Report(byMonth.values.toList(), total, types, openQuotes, money(openValue));
}
