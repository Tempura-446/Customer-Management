import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/reports.dart';
import '../../services.dart';
import '../widgets/common.dart';

/// Owner / office: how the business is doing month by month.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _period = '12';

  (DateTime, int) _range() {
    final now = DateTime.now();
    return switch (_period) {
      'this' => (now, now.month),
      'last' => (DateTime(now.year - 1, 12, 31), 12),
      _ => (now, 12),
    };
  }

  static String _pct(double? v) => v == null ? '-' : '${(v * 100).round()}%';
  static String _days(double? v) => v == null ? '-' : '${v.round()} day${v.round() == 1 ? '' : 's'}';
  static String _money0(double v) => NumberFormat.currency(symbol: '\$', decimalDigits: 0).format(v);
  static String _monthName(String ym) => DateFormat('MMM yyyy').format(DateTime.parse('$ym-01'));

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: DbBuilder(
        db: svc.db,
        builder: (context) {
          final (end, months) = _range();
          final r = buildReport(svc.db, now: end, months: months);
          final t = r.total;
          return PageBody(maxWidth: 1100, children: [
            Choices<String>(
              options: [
                ('12', 'Last 12 months', null),
                ('this', '${now.year} so far', null),
                ('last', '${now.year - 1}', null),
              ],
              value: _period,
              onChanged: (v) => setState(() => _period = v),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Tile('Quotes sent', '${t.sent}', _money0(t.sentValue)),
              _Tile('Won', '${t.won}', _money0(t.wonValue)),
              _Tile('Win rate', _pct(t.winRate), '${t.won} won, ${t.lost} lost'),
              _Tile('Measure to quote', _days(t.avgMeasureToQuote), 'average'),
              _Tile('Quote to decision', _days(t.avgQuoteToDecision), 'average'),
              _Tile('Collected', _money0(t.collected), 'payments received'),
              _Tile('Waiting on customers', '${r.openQuotes}', '${_money0(r.openValue)} in open quotes'),
            ]),
            const SizedBox(height: 12),
            Section(
              title: 'By month',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 40,
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 40,
                  columnSpacing: 24,
                  columns: const [
                    DataColumn(label: Text('Month')),
                    DataColumn(label: Text('Sent'), numeric: true),
                    DataColumn(label: Text('Value sent'), numeric: true),
                    DataColumn(label: Text('Won'), numeric: true),
                    DataColumn(label: Text('Value won'), numeric: true),
                    DataColumn(label: Text('Win rate'), numeric: true),
                    DataColumn(label: Text('Measure → quote'), numeric: true),
                    DataColumn(label: Text('Collected'), numeric: true),
                  ],
                  rows: [
                    for (final m in r.months.reversed)
                      DataRow(cells: [
                        DataCell(Text(_monthName(m.month))),
                        DataCell(Text('${m.sent}')),
                        DataCell(Text(_money0(m.sentValue))),
                        DataCell(Text('${m.won}')),
                        DataCell(Text(_money0(m.wonValue))),
                        DataCell(Text(_pct(m.winRate))),
                        DataCell(Text(_days(m.avgMeasureToQuote))),
                        DataCell(Text(_money0(m.collected))),
                      ]),
                  ],
                ),
              ),
            ),
            Section(
              title: 'By order type',
              child: r.byOrderType.isEmpty
                  ? const Muted('No quotes won or payments in this period yet.')
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 40,
                        dataRowMinHeight: 36,
                        dataRowMaxHeight: 40,
                        columns: const [
                          DataColumn(label: Text('Order type')),
                          DataColumn(label: Text('Jobs won'), numeric: true),
                          DataColumn(label: Text('Value won'), numeric: true),
                          DataColumn(label: Text('Collected'), numeric: true),
                        ],
                        rows: [
                          for (final o in r.byOrderType)
                            DataRow(cells: [
                              DataCell(o.key == null ? Text(o.label) : OrderTypeChip(o.key)),
                              DataCell(Text('${o.jobsWon}')),
                              DataCell(Text(_money0(o.wonValue))),
                              DataCell(Text(_money0(o.collected))),
                            ]),
                        ],
                      ),
                    ),
            ),
            const Muted(
                'Quotes count once per quote number (revisions included), in the month first sent; wins and losses in the '
                'month decided. Win rate is won out of decided. QuickBooks estimates count the same way. "Measure to quote" '
                'is from the first measurement on the job to the quote being sent.',
                size: 12),
          ]);
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.sub);
  final String label, value, sub;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: isWide(context) ? 200 : (MediaQuery.sizeOf(context).width - 40) / 2,
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Muted(label, size: 12),
              FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: Theme.of(context).textTheme.headlineSmall)),
              Muted(sub, size: 11),
            ]),
          ),
        ),
      );
}
