import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/mail/mail_poller.dart';
import 'package:cabinet_crm/qb/qb_sync.dart';
import 'package:cabinet_crm/qb/qbwc_server.dart';
import 'package:cabinet_crm/qb/qbxml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:xml/xml.dart';

String rs(String inner) => '<?xml version="1.0" ?><QBXML><QBXMLMsgsRs>$inner</QBXMLMsgsRs></QBXML>';

String customerRet(String id, String name, {String? parent, String? phone, bool active = true, String? full}) => '''
<CustomerRet><ListID>$id</ListID><TimeModified>2026-10-01T10:00:00-05:00</TimeModified><EditSequence>1</EditSequence>
<Name>${qbEscape(name)}</Name><FullName>${qbEscape(full ?? name)}</FullName><IsActive>$active</IsActive>
${parent != null ? '<ParentRef><ListID>$parent</ListID></ParentRef><Sublevel>1</Sublevel>' : '<Sublevel>0</Sublevel>'}
<BillAddress><Addr1>12 Oak Ave</Addr1><City>Springfield</City><State>IL</State><PostalCode>62704</PostalCode></BillAddress>
${phone != null ? '<Phone>$phone</Phone>' : ''}</CustomerRet>''';

String estimateRet(String txn, String ref, String customerListId, String customerName,
        {bool invoiced = false, String modified = '2026-11-06T09:00:00-05:00'}) =>
    '''
<EstimateRet><TxnID>$txn</TxnID><TimeModified>$modified</TimeModified><CustomerRef><ListID>$customerListId</ListID>
<FullName>${qbEscape(customerName)}</FullName></CustomerRef><TxnDate>2026-11-05</TxnDate><RefNumber>$ref</RefNumber>
<IsActive>true</IsActive><Subtotal>18936.00</Subtotal><SalesTaxTotal>1325.52</SalesTaxTotal><TotalAmount>20261.52</TotalAmount>
<Memo>Kitchen, white shaker</Memo>
${invoiced ? '<LinkedTxn><TxnID>99-1</TxnID><TxnType>Invoice</TxnType><TxnDate>2026-11-06</TxnDate><RefNumber>5001</RefNumber><LinkType>QUANTYPE</LinkType><Amount>20261.52</Amount></LinkedTxn>' : ''}
<EstimateLineRet><TxnLineID>1</TxnLineID><ItemRef><FullName>Cabinets:Shaker</FullName></ItemRef><Desc>Shaker maple, 14 boxes</Desc>
<Quantity>1</Quantity><Rate>11850</Rate><Amount>11850.00</Amount></EstimateLineRet>
<EstimateLineGroupRet><TxnLineID>2</TxnLineID><ItemGroupRef><FullName>Install pkg</FullName></ItemGroupRef><Desc>Install</Desc>
<TotalAmount>7086.00</TotalAmount>
<EstimateLineRet><TxnLineID>3</TxnLineID><ItemRef><FullName>Installation</FullName></ItemRef><Desc>Install &amp; level</Desc>
<Quantity>1</Quantity><Rate>2400</Rate><Amount>2400.00</Amount></EstimateLineRet>
<EstimateLineRet><TxnLineID>4</TxnLineID><ItemRef><FullName>Countertop</FullName></ItemRef><Desc>Quartz</Desc>
<Quantity>52</Quantity><Rate>90.12</Rate><Amount>4686.00</Amount></EstimateLineRet>
</EstimateLineGroupRet></EstimateRet>''';

String invoiceRet(String txn, String ref, String customerListId, String customerName,
        {required double balance, bool paid = false, String? estimate}) =>
    '''
<InvoiceRet><TxnID>$txn</TxnID><TimeModified>2026-11-06T11:00:00-05:00</TimeModified><CustomerRef><ListID>$customerListId</ListID>
<FullName>${qbEscape(customerName)}</FullName></CustomerRef><TxnDate>2026-11-06</TxnDate><RefNumber>$ref</RefNumber>
<DueDate>2026-11-20</DueDate><Subtotal>18936.00</Subtotal><SalesTaxTotal>1325.52</SalesTaxTotal>
<AppliedAmount>-${20261.52 - balance}</AppliedAmount><BalanceRemaining>$balance</BalanceRemaining><IsPaid>$paid</IsPaid>
${estimate != null ? '<LinkedTxn><TxnID>$estimate</TxnID><TxnType>Estimate</TxnType><TxnDate>2026-11-05</TxnDate><RefNumber>1043</RefNumber><LinkType>QUANTYPE</LinkType><Amount>20261.52</Amount></LinkedTxn>' : ''}
</InvoiceRet>''';

String paymentRet(String txn, String customerListId, String customerName, double amount, {String? applyTo}) => '''
<ReceivePaymentRet><TxnID>$txn</TxnID><TimeModified>2026-11-07T09:00:00-05:00</TimeModified><CustomerRef><ListID>$customerListId</ListID>
<FullName>${qbEscape(customerName)}</FullName></CustomerRef><TxnDate>2026-11-07</TxnDate><RefNumber>1201</RefNumber>
<TotalAmount>$amount</TotalAmount><PaymentMethodRef><FullName>Check</FullName></PaymentMethodRef>
${applyTo != null ? '<AppliedToTxnRet><TxnID>$applyTo</TxnID><TxnType>Invoice</TxnType><PaymentAmount>$amount</PaymentAmount></AppliedToTxnRet>' : ''}
</ReceivePaymentRet>''';

String soap(String method, Map<String, String> params) => '<?xml version="1.0" encoding="utf-8"?>'
    '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    '<$method xmlns="http://developer.intuit.com/">'
    '${params.entries.map((e) => '<${e.key}>${qbEscape(e.value)}</${e.key}>').join()}'
    '</$method></soap:Body></soap:Envelope>';

List<String> results(String envelope, String method) => XmlDocument.parse(envelope)
    .findAllElements('${method}Result')
    .first
    .childElements
    .map((e) => e.innerText)
    .toList();

String result(String envelope, String method) => XmlDocument.parse(envelope).findAllElements('${method}Result').first.innerText;

void main() {
  group('qbXML builders', () {
    test('names: no colons, max 41 chars, unique among siblings', () {
      final taken = <String>{'jane smith'};
      expect(qbName('Jane Smith', taken), 'Jane Smith (2)');
      expect(qbName('Jane Smith', taken), 'Jane Smith (3)');
      expect(qbName('A:B', taken), 'A-B');
      final long = qbName('J-2026-014 Kitchen remodel with island and pantry and mudroom', taken);
      expect(long.length, lessThanOrEqualTo(41));
      final long2 = qbName('J-2026-014 Kitchen remodel with island and pantry and mudroom', taken);
      expect(long2, endsWith(' (2)'));
      expect(long2.length, lessThanOrEqualTo(41));
    });

    test('requests escape text and follow qbXML structure', () {
      final x = qbxmlDoc(customerAddRq(
          requestId: 'a1', name: 'O\'Neil & Sons <Kitchen>', phone: '555-123-4567', email: 'tom@x.com',
          address: '301 Lake Dr, Springfield, IL 62704'));
      expect(x, startsWith('<?xml version="1.0" encoding="utf-8"?>\n<?qbxml version="13.0"?>'));
      final doc = XmlDocument.parse(x); // well-formed
      final add = doc.findAllElements('CustomerAdd').single;
      expect(add.getElement('Name')!.innerText, "O'Neil & Sons <Kitchen>");
      expect(add.findAllElements('Addr1').single.innerText, '301 Lake Dr');
      expect(add.findAllElements('Addr2').single.innerText, 'Springfield');
      // Order: Name before BillAddress before Phone before Email.
      final order = add.childElements.map((e) => e.name.local).toList();
      expect(order, ['Name', 'BillAddress', 'Phone', 'Email']);
      final job = XmlDocument.parse(customerAddRq(requestId: 'a2', name: 'J-2026-001 Kitchen', parentListId: '8000-1',
          jobStatus: 'Pending', jobDesc: '12 Oak Ave'));
      expect(job.findAllElements('CustomerAdd').single.childElements.map((e) => e.name.local),
          ['Name', 'ParentRef', 'JobStatus', 'JobDesc']);
      final q = XmlDocument.parse(customerQueryRq(iteratorId: '{abc}'));
      expect(q.rootElement.getAttribute('iterator'), 'Continue');
      expect(q.rootElement.getAttribute('iteratorID'), '{abc}');
      final e = XmlDocument.parse(estimateQueryRq(fromModified: '2026-01-01T00:00:00'));
      expect(e.findAllElements('FromModifiedDate').single.innerText, '2026-01-01T00:00:00');
    });

    test('parses customers and estimates (with line groups and linked invoice)', () {
      final r = parseQbxml(rs('<CustomerQueryRs requestID="cq" statusCode="0" statusSeverity="Info" statusMessage="Status OK" '
          'iteratorRemainingCount="0" iteratorID="{i1}">${customerRet('1-1', 'Smith, Jane', phone: '(555) 111-2222')}'
          '${customerRet('2-1', 'Kitchen', parent: '1-1', full: 'Smith, Jane:Kitchen')}</CustomerQueryRs>'));
      final cs = r.single.rets('CustomerRet').map(QbCustomer.fromXml).toList();
      expect(cs.first.address, '12 Oak Ave, Springfield IL 62704');
      expect(cs.last.isJob, isTrue);
      expect(cs.last.parentListId, '1-1');
      final est = QbEstimate.fromXml(
          XmlDocument.parse(estimateRet('T1', '1043', '2-1', 'Smith, Jane:Kitchen', invoiced: true)).rootElement);
      expect(est.total, 20261.52);
      expect(est.accepted, isTrue);
      expect(est.lines.map((l) => l.item), ['Cabinets:Shaker', 'Installation', 'Countertop']);
      expect(est.lines[1].desc, 'Install & level');
    });

    test('repeat-customer name keys', () {
      expect(QbSync.nameKey('Smith, Jane'), QbSync.nameKey('Jane Smith'));
      expect(QbSync.nameKey("O'Neil, Tom"), QbSync.nameKey("Tom O'Neil"));
      expect(QbSync.nameKey('JANE  SMITH.'), QbSync.nameKey('jane smith'));
      expect(QbSync.phoneKey('+1 (555) 111-2222'), '5551112222');
      expect(QbSync.phoneKey('12'), '');
    });
  });

  test('full Web Connector session: link, import, create, estimates', () async {
    final db = AppDb.memory(isHub: true);
    seedSettings(db);
    final jane = saveCustomer(db, {'name': 'Jane Smith', 'phone': '555 111 2222', 'address': '12 Oak Ave'});
    final janeJob = createProject(db, customerId: jane, title: 'Kitchen');
    final bob = saveCustomer(db, {'name': 'Bob Lee', 'address': '9 Elm St, Springfield'});
    final bobJob = createProject(db, customerId: bob, title: 'Bath vanity');
    saveCustomer(db, {'name': 'No Job Person'}); // no job: not pushed to QuickBooks
    final janeNumber = db.get('projects', janeJob)!.s('number');

    final sync = QbSync(db)..configure(enabled: true);
    final secrets = MemorySecretStore();
    final qbwc = QbwcService(db, sync, secrets: secrets);
    await qbwc.setPassword('s3cret!');

    // Wrong password.
    expect(results(await qbwc.handleSoap(soap('authenticate', {'strUserName': 'cabinetcrm', 'strPassword': 'x'})),
        'authenticate'), ['', 'nvu']);
    final auth = results(
        await qbwc.handleSoap(soap('authenticate', {'strUserName': 'cabinetcrm', 'strPassword': 's3cret!'})), 'authenticate');
    final ticket = auth[0];
    expect(auth[1], '', reason: 'use the open company file');

    Future<String> next() async => result(
        await qbwc.handleSoap(soap('sendRequestXML', {
          'ticket': ticket, 'strHCPResponse': '', 'strCompanyFileName': r'\\server\qb\Company.QBW',
          'qbXMLCountry': 'US', 'qbXMLMajorVers': '13', 'qbXMLMinorVers': '0',
        })),
        'sendRequestXML');
    Future<int> reply(String xml) async =>
        int.parse(result(await qbwc.handleSoap(soap('receiveResponseXML', {'ticket': ticket, 'response': xml, 'hresult': '', 'message': ''})),
            'receiveResponseXML'));

    // 1. Customers (two pages via iterator).
    var req = XmlDocument.parse(await next());
    expect(req.findAllElements('CustomerQueryRq').single.getAttribute('iterator'), 'Start');
    expect(await reply(rs('<CustomerQueryRs requestID="cq" statusCode="0" statusSeverity="Info" statusMessage="Status OK" '
        'iteratorRemainingCount="2" iteratorID="{it-1}">${customerRet('80000001-1', 'Smith, Jane', phone: '555-111-2222')}'
        '</CustomerQueryRs>')), lessThan(100));
    req = XmlDocument.parse(await next());
    expect(req.findAllElements('CustomerQueryRq').single.getAttribute('iteratorID'), '{it-1}');
    await reply(rs('<CustomerQueryRs requestID="cq" statusCode="0" statusSeverity="Info" statusMessage="Status OK" '
        'iteratorRemainingCount="0" iteratorID="{it-1}">${customerRet('80000002-1', 'Repeat Customer Co', phone: '555-999-0000')}'
        '${customerRet('80000003-1', 'Gone Co', active: false)}</CustomerQueryRs>'));
    expect(db.get('customers', jane)!.s('qb_list_id'), '80000001-1', reason: '"Smith, Jane" = "Jane Smith"');
    final imported = db.one("SELECT * FROM customers WHERE name='Repeat Customer Co'");
    expect(imported!.s('source'), 'QuickBooks');
    expect(db.one("SELECT * FROM customers WHERE name='Gone Co'"), isNull, reason: 'inactive QB customers not imported');

    // 2. Create Bob (customer) in QuickBooks.
    req = XmlDocument.parse(await next());
    final adds = req.findAllElements('CustomerAddRq').toList();
    expect(adds.map((a) => a.findAllElements('Name').first.innerText), ['Bob Lee'], reason: 'only customers with a job');
    final bobRid = adds.single.getAttribute('requestID')!;
    await reply(rs('<CustomerAddRs requestID="$bobRid" statusCode="0" statusSeverity="Info" statusMessage="Status OK">'
        '${customerRet('80000010-1', 'Bob Lee')}</CustomerAddRs>'));
    expect(db.get('customers', bob)!.s('qb_list_id'), '80000010-1');

    // 3. Create both jobs under their customers.
    req = XmlDocument.parse(await next());
    final jobAdds = req.findAllElements('CustomerAddRq').toList();
    expect(jobAdds, hasLength(2));
    final byParent = {for (final a in jobAdds) a.findAllElements('ListID').single.innerText: a};
    expect(byParent['80000001-1']!.findAllElements('Name').first.innerText, '$janeNumber Kitchen');
    expect(byParent['80000001-1']!.findAllElements('JobStatus').single.innerText, 'Pending');
    final janeRid = byParent['80000001-1']!.getAttribute('requestID')!;
    final bobJobRid = byParent['80000010-1']!.getAttribute('requestID')!;
    await reply(rs('<CustomerAddRs requestID="$janeRid" statusCode="0" statusSeverity="Info" statusMessage="Status OK">'
        '${customerRet('80000011-1', '$janeNumber Kitchen', parent: '80000001-1', full: 'Smith, Jane:$janeNumber Kitchen')}</CustomerAddRs>'
        '<CustomerAddRs requestID="$bobJobRid" statusCode="3100" statusSeverity="Error" '
        'statusMessage="The name is already in use."/>'));
    expect(db.get('projects', janeJob)!.s('qb_full_name'), 'Smith, Jane:$janeNumber Kitchen');
    // Bob's job name was taken: retried with a suffix.
    req = XmlDocument.parse(await next());
    final retry = req.findAllElements('CustomerAddRq').single;
    expect(retry.findAllElements('Name').first.innerText, endsWith(' (2)'));
    await reply(rs('<CustomerAddRs requestID="${retry.getAttribute('requestID')}" statusCode="0" statusSeverity="Info" statusMessage="OK">'
        '${customerRet('80000012-1', 'x (2)', parent: '80000010-1', full: 'Bob Lee:x (2)')}</CustomerAddRs>'));
    expect(db.get('projects', bobJob)!.s('qb_list_id'), '80000012-1');

    // 4. Estimates.
    req = XmlDocument.parse(await next());
    expect(req.findAllElements('EstimateQueryRq'), hasLength(1));
    final pct = await reply(rs('<EstimateQueryRs requestID="eq" statusCode="0" statusSeverity="Info" statusMessage="OK" '
        'iteratorRemainingCount="0" iteratorID="{e1}">'
        '${estimateRet('E-1', '1043', '80000011-1', 'Smith, Jane:$janeNumber Kitchen', invoiced: true)}'
        '${estimateRet('E-2', '1044', '80000002-1', 'Repeat Customer Co', modified: '2026-11-06T10:00:00-05:00')}'
        '</EstimateQueryRs>'));
    expect(pct, lessThan(100));

    // 5. Invoices: Jane's (made from estimate 1043, linked by the job) and one with only the estimate link.
    req = XmlDocument.parse(await next());
    expect(req.findAllElements('InvoiceQueryRq'), hasLength(1));
    expect(req.findAllElements('IncludeLinkedTxns').single.innerText, 'true');
    expect(await reply(rs('<InvoiceQueryRs requestID="iq" statusCode="0" statusSeverity="Info" statusMessage="OK">'
        '${invoiceRet('99-1', '5001', '80000011-1', 'Smith, Jane:$janeNumber Kitchen', balance: 10261.52, estimate: 'E-1')}'
        '${invoiceRet('99-2', '5002', '80000099-1', 'Unknown:Job', balance: 0, paid: true, estimate: 'E-1')}'
        '</InvoiceQueryRs>')), lessThan(100));

    // 6. Payments: one applied to Jane's invoice.
    req = XmlDocument.parse(await next());
    expect(req.findAllElements('ReceivePaymentQueryRq'), hasLength(1));
    expect(await reply(rs('<ReceivePaymentQueryRs requestID="pq" statusCode="0" statusSeverity="Info" statusMessage="OK">'
        '${paymentRet('P-1', '80000001-1', 'Smith, Jane', 10000, applyTo: '99-1')}'
        '</ReceivePaymentQueryRs>')), 100);
    expect(await next(), '', reason: 'nothing more to do');
    final close = result(await qbwc.handleSoap(soap('closeConnection', {'ticket': ticket})), 'closeConnection');
    expect(close, contains('estimate'));

    final est = qbEstimatesFor(db, janeJob).single;
    expect(est.s('ref_number'), '1043');
    expect(est.d('total'), 20261.52);
    expect(db.get('projects', janeJob)!.s('status'), 'approved', reason: 'estimate became an invoice in QuickBooks');
    expect(currentQbEstimate(db, janeJob)!.s('ref_number'), '1043');
    final repeat = db.one("SELECT * FROM qb_estimates WHERE ref_number='1044'")!;
    expect(repeat.ns('project_id'), isNull);
    expect(repeat.s('customer_id'), imported.id);
    expect(db.meta('qb_last_estimate_sync'), '2026-11-06T10:00:00-05:00');
    expect(sync.lastResult, contains('created in QuickBooks'));
    expect(sync.lastError, isNull);

    // Invoices and payments are on Jane's job; the estimate link finds the job when the customer doesn't.
    expect(qbInvoicesFor(db, janeJob).map((i) => i.s('ref_number')), containsAll(['5001', '5002']));
    expect(qbPaymentsFor(db, janeJob).single.d('amount'), 10000);
    expect(qbPaymentsFor(db, janeJob).single.s('method'), 'Check');
    final b = qbBilling(db, janeJob);
    expect((b.invoiced, b.paid, b.balance), (40523.04, 10000.0, 10261.52));
    expect(db.meta('qb_last_invoice_sync'), '2026-11-06T11:00:00-05:00');
    expect(sync.lastResult, contains('2 invoice(s) and 1 payment(s)'));
    expect(db.get('projects', janeJob)!.s('status'), 'approved', reason: 'not paid in full yet, and not installed');
    expect(db.select("SELECT * FROM notes WHERE project_id=? AND kind='money' AND body LIKE 'Payment received%'", [janeJob]),
        hasLength(1));

    // Installed, and QuickBooks later shows the balance paid: the job becomes Paid.
    markCompleted(db, janeJob);
    expect(db.get('projects', janeJob)!.s('status'), 'completed');
    sync.begin();
    sync.upsertInvoice(QbInvoice.fromXml(XmlDocument.parse(
        invoiceRet('99-1', '5001', '80000011-1', 'Smith, Jane:$janeNumber Kitchen', balance: 0, paid: true)).rootElement));
    refreshQbBilling(db, janeJob);
    sync.end();
    expect(db.get('projects', janeJob)!.s('status'), 'paid');

    // Next run only asks for estimates since then, and finds nothing new to create.
    final again = results(
        await qbwc.handleSoap(soap('authenticate', {'strUserName': 'cabinetcrm', 'strPassword': 's3cret!'})), 'authenticate');
    expect(again[1], '');
  });

  test('disabled sync: Web Connector connects but has nothing to do; QuickBooks errors are reported', () async {
    final db = AppDb.memory(isHub: true);
    final sync = QbSync(db);
    final qbwc = QbwcService(db, sync, secrets: MemorySecretStore());
    await qbwc.setPassword('pw1234');
    var auth = results(await qbwc.handleSoap(soap('authenticate', {'strUserName': 'cabinetcrm', 'strPassword': 'pw1234'})),
        'authenticate');
    expect(auth[1], 'none');
    sync.configure(enabled: true);
    auth = results(await qbwc.handleSoap(soap('authenticate', {'strUserName': 'cabinetcrm', 'strPassword': 'pw1234'})),
        'authenticate');
    await qbwc.handleSoap(soap('sendRequestXML', {'ticket': auth[0]}));
    final r = result(
        await qbwc.handleSoap(soap('receiveResponseXML',
            {'ticket': auth[0], 'response': '', 'hresult': '0x80040408', 'message': 'Could not start QuickBooks.'})),
        'receiveResponseXML');
    expect(int.parse(r), lessThan(0));
    final err = result(await qbwc.handleSoap(soap('getLastError', {'ticket': auth[0]})), 'getLastError');
    expect(err, contains('Could not start QuickBooks'));
    expect(sync.lastError, contains('Could not start QuickBooks'));
  });

  test('HTTP handler: WSDL, help page, QWC file', () async {
    final db = AppDb.memory(isHub: true);
    final qbwc = QbwcService(db, QbSync(db), secrets: MemorySecretStore());
    final wsdl = await qbwc.handler(Request('GET', Uri.parse('http://localhost:47820/qbwc?wsdl')));
    final w = XmlDocument.parse(await wsdl.readAsString());
    expect(w.findAllElements('wsdl:operation').map((e) => e.getAttribute('name')).toSet(),
        containsAll(['authenticate', 'sendRequestXML', 'receiveResponseXML', 'closeConnection']));
    final help = await qbwc.handler(Request('GET', Uri.parse('http://localhost:47820/qbwc')));
    expect(await help.readAsString(), contains('Web Connector'));
    final post = await qbwc.handler(Request('POST', Uri.parse('http://localhost:47820/qbwc'), body: soap('serverVersion', {})));
    expect(result(await post.readAsString(), 'serverVersion'), '1.0');
    final qwc = XmlDocument.parse(qbwc.qwcFile(port: 47820));
    expect(qwc.findAllElements('AppURL').single.innerText, 'http://localhost:47820/qbwc');
    expect(qwc.findAllElements('UserName').single.innerText, 'cabinetcrm');
    expect(qwc.findAllElements('OwnerID').single.innerText, startsWith('{'));
    expect(qbwc.qwcFile(port: 47820), qbwc.qwcFile(port: 47820), reason: 'stable ids');
  });
}
