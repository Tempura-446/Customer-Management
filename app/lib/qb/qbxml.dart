/// qbXML (QuickBooks Desktop SDK, version 13.0 = QuickBooks 2014 US) request builders and
/// response parsers. Pure Dart so it can be tested without QuickBooks.
///
/// Element order matters in qbXML: the builders follow the order of the SDK's OSR.
library;

import 'package:xml/xml.dart';

const qbxmlVersion = '13.0';

/// QuickBooks limits (US 2014).
const qbNameMax = 41;
const qbAddrMax = 41;
const qbPhoneMax = 21;
const qbJobDescMax = 99;

String qbEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _cut(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : t.substring(0, max).trimRight();
}

/// A valid, unique QuickBooks list name: no colons (they separate Customer:Job), at most
/// 41 characters, and not already in [taken] (case-insensitive). Adds " (2)", " (3)"… if needed.
/// The chosen name is added to [taken].
String qbName(String name, Set<String> taken) {
  var base = name.replaceAll(':', '-').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (base.isEmpty) base = 'Customer';
  var candidate = _cut(base, qbNameMax);
  var n = 1;
  while (taken.contains(candidate.toLowerCase())) {
    n++;
    final suffix = ' ($n)';
    candidate = '${_cut(base, qbNameMax - suffix.length)}$suffix';
  }
  taken.add(candidate.toLowerCase());
  return candidate;
}

/// Wrap one or more requests in a QBXML document.
String qbxmlDoc(String requests) => '<?xml version="1.0" encoding="utf-8"?>\n'
    '<?qbxml version="$qbxmlVersion"?>\n'
    '<QBXML><QBXMLMsgsRq onError="continueOnError">$requests</QBXMLMsgsRq></QBXML>';

String _iterAttrs(String? iteratorId) =>
    iteratorId == null ? 'iterator="Start"' : 'iterator="Continue" iteratorID="${qbEscape(iteratorId)}"';

const _customerFields = [
  'ListID', 'TimeModified', 'EditSequence', 'Name', 'FullName', 'IsActive', 'ParentRef', 'Sublevel',
  'BillAddress', 'Phone', 'Email',
];

/// All customers and jobs (active and inactive), 200 at a time.
String customerQueryRq({String? iteratorId, String requestId = 'cq', int maxReturned = 200}) {
  final b = StringBuffer('<CustomerQueryRq requestID="${qbEscape(requestId)}" ${_iterAttrs(iteratorId)}>')
    ..write('<MaxReturned>$maxReturned</MaxReturned>')
    ..write('<ActiveStatus>All</ActiveStatus>');
  for (final f in _customerFields) {
    b.write('<IncludeRetElement>$f</IncludeRetElement>');
  }
  b.write('</CustomerQueryRq>');
  return b.toString();
}

/// Split a one-line address ("12 Oak Ave, Springfield, IL 62704") into QuickBooks address lines.
String billAddressXml(String? address) {
  final a = (address ?? '').trim();
  if (a.isEmpty) return '';
  final parts = a.split(RegExp(r'\s*[,\n]\s*')).where((p) => p.isNotEmpty).toList();
  final lines = <String>[];
  for (final p in parts) {
    if (lines.length == 4) {
      lines[3] = _cut('${lines[3]}, $p', qbAddrMax);
    } else {
      lines.add(_cut(p, qbAddrMax));
    }
  }
  final b = StringBuffer('<BillAddress>');
  for (final (i, l) in lines.indexed) {
    b.write('<Addr${i + 1}>${qbEscape(l)}</Addr${i + 1}>');
  }
  b.write('</BillAddress>');
  return b.toString();
}

/// Add a top-level customer, or (with [parentListId]) a job under a customer.
String customerAddRq({
  required String requestId,
  required String name,
  String? parentListId,
  String? phone,
  String? email,
  String? address,
  String? jobStatus, // Awarded | Closed | InProgress | None | NotAwarded | Pending
  String? jobDesc,
}) {
  final b = StringBuffer('<CustomerAddRq requestID="${qbEscape(requestId)}"><CustomerAdd>')
    ..write('<Name>${qbEscape(_cut(name.replaceAll(':', '-'), qbNameMax))}</Name>');
  if (parentListId != null) b.write('<ParentRef><ListID>${qbEscape(parentListId)}</ListID></ParentRef>');
  b.write(billAddressXml(address));
  if ((phone ?? '').trim().isNotEmpty) b.write('<Phone>${qbEscape(_cut(phone!, qbPhoneMax))}</Phone>');
  if ((email ?? '').trim().isNotEmpty) b.write('<Email>${qbEscape(email!.trim())}</Email>');
  if (jobStatus != null) b.write('<JobStatus>$jobStatus</JobStatus>');
  if ((jobDesc ?? '').trim().isNotEmpty) b.write('<JobDesc>${qbEscape(_cut(jobDesc!, qbJobDescMax))}</JobDesc>');
  b.write('</CustomerAdd></CustomerAddRq>');
  return b.toString();
}

/// QuickBooks date-time ("2026-11-06T09:12:33"), local time, no offset.
String qbDateTime(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// Estimates changed since [fromModified] (a QuickBooks date-time string), with lines and links.
String estimateQueryRq({required String fromModified, String? iteratorId, String requestId = 'eq', int maxReturned = 100}) =>
    '<EstimateQueryRq requestID="${qbEscape(requestId)}" ${_iterAttrs(iteratorId)}>'
    '<MaxReturned>$maxReturned</MaxReturned>'
    '<ModifiedDateRangeFilter><FromModifiedDate>${qbEscape(fromModified)}</FromModifiedDate></ModifiedDateRangeFilter>'
    '<IncludeLineItems>true</IncludeLineItems>'
    '<IncludeLinkedTxns>true</IncludeLinkedTxns>'
    '</EstimateQueryRq>';

String invoiceQueryRq({required String fromModified, String? iteratorId, String requestId = 'iq', int maxReturned = 100}) =>
    '<InvoiceQueryRq requestID="${qbEscape(requestId)}" ${_iterAttrs(iteratorId)}>'
    '<MaxReturned>$maxReturned</MaxReturned>'
    '<ModifiedDateRangeFilter><FromModifiedDate>${qbEscape(fromModified)}</FromModifiedDate></ModifiedDateRangeFilter>'
    '<IncludeLinkedTxns>true</IncludeLinkedTxns>'
    '</InvoiceQueryRq>';

String receivePaymentQueryRq(
        {required String fromModified, String? iteratorId, String requestId = 'pq', int maxReturned = 100}) =>
    '<ReceivePaymentQueryRq requestID="${qbEscape(requestId)}" ${_iterAttrs(iteratorId)}>'
    '<MaxReturned>$maxReturned</MaxReturned>'
    '<ModifiedDateRangeFilter><FromModifiedDate>${qbEscape(fromModified)}</FromModifiedDate></ModifiedDateRangeFilter>'
    '<IncludeLineItems>true</IncludeLineItems>'
    '</ReceivePaymentQueryRq>';

// ============================================================================ parsing

class QbResponse {
  QbResponse(this.element);
  final XmlElement element;

  String get type => element.name.local; // e.g. CustomerQueryRs
  String get requestId => element.getAttribute('requestID') ?? '';
  int get statusCode => int.tryParse(element.getAttribute('statusCode') ?? '') ?? -1;
  String get statusSeverity => element.getAttribute('statusSeverity') ?? '';
  String get statusMessage => element.getAttribute('statusMessage') ?? '';
  String? get iteratorId => element.getAttribute('iteratorID');
  int get remaining => int.tryParse(element.getAttribute('iteratorRemainingCount') ?? '') ?? 0;

  /// 0 = OK, 1 = query found nothing (fine), 500/530 = some objects not found (fine for queries).
  bool get ok => statusCode == 0 || statusCode == 1 || statusCode == 500 || statusCode == 530;

  Iterable<XmlElement> rets(String name) => element.findElements(name);
}

/// The responses inside a QBXML reply.
List<QbResponse> parseQbxml(String xml) {
  final doc = XmlDocument.parse(xml);
  final rs = doc.findAllElements('QBXMLMsgsRs').firstOrNull;
  if (rs == null) return const [];
  return rs.childElements.map(QbResponse.new).toList();
}

String? _text(XmlElement e, String name) {
  final c = e.getElement(name);
  final t = c?.innerText.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String? _ref(XmlElement e, String ref, String field) {
  final r = e.getElement(ref);
  return r == null ? null : _text(r, field);
}

double _num(String? s) => double.tryParse((s ?? '').replaceAll(',', '')) ?? 0;

class QbCustomer {
  QbCustomer({
    required this.listId,
    required this.name,
    required this.fullName,
    this.parentListId,
    this.sublevel = 0,
    this.phone,
    this.email,
    this.address,
    this.isActive = true,
    this.timeModified,
  });
  final String listId, name, fullName;
  final String? parentListId, phone, email, address, timeModified;
  final int sublevel;
  final bool isActive;
  bool get isJob => sublevel > 0 || parentListId != null;

  factory QbCustomer.fromXml(XmlElement e) {
    final addr = e.getElement('BillAddress');
    String? address;
    if (addr != null) {
      final lines = [
        for (final f in ['Addr1', 'Addr2', 'Addr3', 'Addr4', 'Addr5']) ?_text(addr, f),
        [_text(addr, 'City'), _text(addr, 'State'), _text(addr, 'PostalCode')].whereType<String>().join(' '),
      ].where((l) => l.trim().isNotEmpty).toList();
      address = lines.isEmpty ? null : lines.join(', ');
    }
    return QbCustomer(
      listId: _text(e, 'ListID') ?? '',
      name: _text(e, 'Name') ?? '',
      fullName: _text(e, 'FullName') ?? _text(e, 'Name') ?? '',
      parentListId: _ref(e, 'ParentRef', 'ListID'),
      sublevel: int.tryParse(_text(e, 'Sublevel') ?? '') ?? 0,
      phone: _text(e, 'Phone'),
      email: _text(e, 'Email'),
      address: address,
      isActive: (_text(e, 'IsActive') ?? 'true') == 'true',
      timeModified: _text(e, 'TimeModified'),
    );
  }
}

class QbEstimateLine {
  QbEstimateLine({this.item, this.desc, this.qty, this.rate, this.amount = 0});
  final String? item, desc;
  final double? qty, rate;
  final double amount;
  Map<String, Object?> toJson() => {'item': item, 'desc': desc, 'qty': qty, 'rate': rate, 'amount': amount};
}

class QbEstimate {
  QbEstimate({
    required this.txnId,
    this.refNumber,
    this.txnDate,
    this.customerListId,
    this.customerFullName,
    this.subtotal = 0,
    this.tax = 0,
    this.total = 0,
    this.isActive = true,
    this.accepted = false,
    this.memo,
    this.lines = const [],
    this.timeModified,
  });
  final String txnId;
  final String? refNumber, txnDate, customerListId, customerFullName, memo, timeModified;
  final double subtotal, tax, total;
  final bool isActive, accepted;
  final List<QbEstimateLine> lines;

  factory QbEstimate.fromXml(XmlElement e) {
    QbEstimateLine line(XmlElement l, {String itemRef = 'ItemRef', String amount = 'Amount'}) => QbEstimateLine(
          item: _ref(l, itemRef, 'FullName'),
          desc: _text(l, 'Desc'),
          qty: double.tryParse(_text(l, 'Quantity') ?? ''),
          rate: double.tryParse(_text(l, 'Rate') ?? ''),
          amount: _num(_text(l, amount)),
        );
    final lines = <QbEstimateLine>[];
    for (final c in e.childElements) {
      if (c.name.local == 'EstimateLineRet') {
        lines.add(line(c));
      } else if (c.name.local == 'EstimateLineGroupRet') {
        final subs = c.findElements('EstimateLineRet').toList();
        if (subs.isEmpty) {
          lines.add(line(c, itemRef: 'ItemGroupRef', amount: 'TotalAmount'));
        } else {
          lines.addAll(subs.map(line));
        }
      }
    }
    final linkedTypes = e.findElements('LinkedTxn').map((l) => _text(l, 'TxnType')).whereType<String>().toSet();
    return QbEstimate(
      txnId: _text(e, 'TxnID') ?? '',
      refNumber: _text(e, 'RefNumber'),
      txnDate: _text(e, 'TxnDate'),
      customerListId: _ref(e, 'CustomerRef', 'ListID'),
      customerFullName: _ref(e, 'CustomerRef', 'FullName'),
      subtotal: _num(_text(e, 'Subtotal')),
      tax: _num(_text(e, 'SalesTaxTotal')),
      total: _num(_text(e, 'TotalAmount')),
      isActive: (_text(e, 'IsActive') ?? 'true') == 'true',
      accepted: linkedTypes.contains('Invoice') || linkedTypes.contains('SalesOrder'),
      memo: _text(e, 'Memo'),
      lines: lines,
      timeModified: _text(e, 'TimeModified'),
    );
  }
}

class QbInvoice {
  QbInvoice({
    required this.txnId,
    this.refNumber,
    this.txnDate,
    this.dueDate,
    this.customerListId,
    this.customerFullName,
    this.subtotal = 0,
    this.tax = 0,
    this.balance = 0,
    this.isPaid = false,
    this.memo,
    this.estimateTxnIds = const [],
    this.timeModified,
  });
  final String txnId;
  final String? refNumber, txnDate, dueDate, customerListId, customerFullName, memo, timeModified;
  final double subtotal, tax, balance;
  final bool isPaid;
  final List<String> estimateTxnIds;
  double get total => subtotal + tax;

  factory QbInvoice.fromXml(XmlElement e) => QbInvoice(
        txnId: _text(e, 'TxnID') ?? '',
        refNumber: _text(e, 'RefNumber'),
        txnDate: _text(e, 'TxnDate'),
        dueDate: _text(e, 'DueDate'),
        customerListId: _ref(e, 'CustomerRef', 'ListID'),
        customerFullName: _ref(e, 'CustomerRef', 'FullName'),
        subtotal: _num(_text(e, 'Subtotal')),
        tax: _num(_text(e, 'SalesTaxTotal')),
        balance: _num(_text(e, 'BalanceRemaining')),
        isPaid: _text(e, 'IsPaid') == 'true',
        memo: _text(e, 'Memo'),
        estimateTxnIds: [
          for (final l in e.findElements('LinkedTxn'))
            if (_text(l, 'TxnType') == 'Estimate' && _text(l, 'TxnID') != null) _text(l, 'TxnID')!,
        ],
        timeModified: _text(e, 'TimeModified'),
      );
}

class QbPayment {
  QbPayment({
    required this.txnId,
    this.refNumber,
    this.txnDate,
    this.customerListId,
    this.customerFullName,
    this.amount = 0,
    this.method,
    this.applied = const [],
    this.timeModified,
  });
  final String txnId;
  final String? refNumber, txnDate, customerListId, customerFullName, method, timeModified;
  final double amount;

  /// Invoices this payment pays: (invoice TxnID, amount applied).
  final List<(String, double)> applied;

  factory QbPayment.fromXml(XmlElement e) => QbPayment(
        txnId: _text(e, 'TxnID') ?? '',
        refNumber: _text(e, 'RefNumber'),
        txnDate: _text(e, 'TxnDate'),
        customerListId: _ref(e, 'CustomerRef', 'ListID'),
        customerFullName: _ref(e, 'CustomerRef', 'FullName'),
        amount: _num(_text(e, 'TotalAmount')),
        method: _ref(e, 'PaymentMethodRef', 'FullName'),
        applied: [
          for (final a in e.findElements('AppliedToTxnRet'))
            if (_text(a, 'TxnID') != null) (_text(a, 'TxnID')!, _num(_text(a, 'PaymentAmount'))),
        ],
        timeModified: _text(e, 'TimeModified'),
      );
}
