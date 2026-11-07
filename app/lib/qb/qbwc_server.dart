/// SOAP service for the QuickBooks Web Connector (QBWC).
///
/// QBWC (installed with QuickBooks 2014) runs on the main office PC next to QuickBooks and
/// polls this service every few minutes: authenticate → sendRequestXML / receiveResponseXML
/// (repeated) → closeConnection. Each request is qbXML that QuickBooks executes against the
/// open company file. QBWC only allows plain http for localhost, so this answers loopback only.
library;

import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:xml/xml.dart';

import '../core/db.dart';
import '../mail/mail_poller.dart';
import 'qb_sync.dart';
import 'qbxml.dart';

const qbwcUser = 'cabinetcrm';
const _ns = 'http://developer.intuit.com/';
const _pwKey = 'cabinet_crm_qbwc_password';

class QbwcService {
  QbwcService(this.db, this.sync, {SecretStore? secrets}) : secrets = secrets ?? DeviceSecretStore();
  final AppDb db;
  final QbSync sync;
  final SecretStore secrets;

  final _tickets = <String, DateTime>{};

  Future<void> setPassword(String password) => secrets.write(_pwKey, password);
  Future<bool> hasPassword() async => ((await secrets.read(_pwKey)) ?? '').isNotEmpty;

  /// The .QWC file you add to the Web Connector ("Add an application").
  String qwcFile({required int port}) => '''<?xml version="1.0"?>
<QBWCXML>
  <AppName>Casework</AppName>
  <AppID></AppID>
  <AppURL>http://localhost:$port/qbwc</AppURL>
  <AppDescription>Casework: sends new customers and jobs to QuickBooks and brings estimates back to the jobs.</AppDescription>
  <AppSupport>http://localhost:$port/qbwc/support</AppSupport>
  <UserName>$qbwcUser</UserName>
  <OwnerID>${sync.ownerId}</OwnerID>
  <FileID>${sync.fileId}</FileID>
  <QBType>QBFS</QBType>
  <Scheduler>
    <RunEveryNMinutes>15</RunEveryNMinutes>
  </Scheduler>
  <IsReadOnly>false</IsReadOnly>
</QBWCXML>
''';

  Handler get handler => (Request req) async {
        // Only the Web Connector on this PC may talk to us.
        final info = req.context['shelf.io.connection_info'];
        if (info is HttpConnectionInfo && !info.remoteAddress.isLoopback) {
          return Response.forbidden('The QuickBooks Web Connector must run on this PC.');
        }
        final path = req.url.path;
        if (req.method == 'GET') {
          if (req.url.queryParameters.containsKey('wsdl') || req.url.query.toLowerCase() == 'wsdl') {
            final u = req.requestedUri;
            return Response.ok(wsdl(Uri(scheme: u.scheme, host: u.host, port: u.port, path: u.path).toString()),
                headers: {'content-type': 'text/xml; charset=utf-8'});
          }
          return Response.ok(_helpPage(path == 'support'), headers: {'content-type': 'text/html; charset=utf-8'});
        }
        if (req.method != 'POST') return Response(405);
        final body = await req.readAsString();
        try {
          return _xml(await handleSoap(body));
        } catch (e) {
          return Response(500, body: _fault('$e'), headers: {'content-type': 'text/xml; charset=utf-8'});
        }
      };

  /// Handle one SOAP call; returns the SOAP response envelope. Public for tests.
  Future<String> handleSoap(String body) async {
    final doc = XmlDocument.parse(body);
    final bodyEl = doc.descendants.whereType<XmlElement>().firstWhere((e) => e.name.local == 'Body');
    final call = bodyEl.childElements.first;
    final method = call.name.local;
    String arg(String name) =>
        call.childElements.where((e) => e.name.local == name).map((e) => e.innerText).firstOrNull ?? '';

    switch (method) {
      case 'serverVersion':
        return _result(method, '1.0');
      case 'clientVersion':
        return _result(method, ''); // any Web Connector version is fine
      case 'authenticate':
        return _array(method, await _authenticate(arg('strUserName'), arg('strPassword')));
      case 'sendRequestXML':
        if (!_tickets.containsKey(arg('ticket'))) return _result(method, '');
        final next = sync.nextRequest();
        if (next == null) sync.end();
        return _result(method, next ?? '');
      case 'receiveResponseXML':
        if (!_tickets.containsKey(arg('ticket'))) return _result(method, '-1');
        if (arg('hresult').trim().isNotEmpty) {
          sync.fail('QuickBooks reported: ${arg('message')} (${arg('hresult')})');
          return _result(method, '-101');
        }
        return _result(method, '${sync.handleResponse(arg('response'))}');
      case 'connectionError':
        sync.fail("QuickBooks couldn't be reached: ${arg('message')} (${arg('hresult')})");
        return _result(method, 'done');
      case 'getLastError':
        return _result(method, sync.error ?? '');
      case 'closeConnection':
        sync.end();
        _tickets.remove(arg('ticket'));
        return _result(method, 'Casework: ${sync.lastResult ?? 'done'}');
      default:
        throw ArgumentError('Unknown Web Connector call $method');
    }
  }

  Future<List<String>> _authenticate(String user, String password) async {
    final saved = await secrets.read(_pwKey);
    if (user != qbwcUser || saved == null || saved.isEmpty || password != saved) return ['', 'nvu'];
    // Forget stale sessions.
    _tickets.removeWhere((_, t) => DateTime.now().difference(t) > const Duration(hours: 2));
    final ticket = newId();
    _tickets[ticket] = DateTime.now();
    if (!sync.enabled) return [ticket, 'none']; // nothing to do this time
    if (sync.running) sync.end();
    sync.begin();
    return [ticket, '']; // "" = use the company file that is open in QuickBooks
  }

  // ------------------------------------------------------------------ SOAP helpers

  static Response _xml(String s) => Response.ok(s, headers: {'content-type': 'text/xml; charset=utf-8'});

  static String _envelope(String inner) => '<?xml version="1.0" encoding="utf-8"?>'
      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">'
      '<soap:Body>$inner</soap:Body></soap:Envelope>';

  static String _result(String method, String value) =>
      _envelope('<${method}Response xmlns="$_ns"><${method}Result>${qbEscape(value)}</${method}Result></${method}Response>');

  static String _array(String method, List<String> values) => _envelope('<${method}Response xmlns="$_ns"><${method}Result>'
      '${values.map((v) => '<string>${qbEscape(v)}</string>').join()}</${method}Result></${method}Response>');

  static String _fault(String message) => _envelope(
      '<soap:Fault><faultcode>soap:Server</faultcode><faultstring>${qbEscape(message)}</faultstring></soap:Fault>');

  String _helpPage(bool support) => '<!doctype html><meta charset="utf-8"><title>Casework · QuickBooks</title>'
      '<body style="font-family:sans-serif;max-width:640px;margin:40px auto">'
      '<h2>Casework ↔ QuickBooks</h2>'
      '<p>This address is used by the QuickBooks Web Connector on this PC. '
      'Set it up in Casework under Settings › QuickBooks.</p>'
      '<p>Last run: ${qbEscape(sync.lastRun ?? 'never')}<br>Result: ${qbEscape(sync.lastResult ?? '-')}</p>'
      '${support ? '<p>Help: in Casework open Settings › QuickBooks for step-by-step instructions.</p>' : ''}'
      '</body>';

  /// WSDL for the Web Connector service (document/literal, SOAP 1.1).
  static String wsdl(String url) {
    const ops = <String, (List<String>, String)>{
      'serverVersion': ([], 'string'),
      'clientVersion': (['strVersion'], 'string'),
      'authenticate': (['strUserName', 'strPassword'], 'ArrayOfString'),
      'sendRequestXML': (['ticket', 'strHCPResponse', 'strCompanyFileName', 'qbXMLCountry', 'qbXMLMajorVers', 'qbXMLMinorVers'], 'string'),
      'receiveResponseXML': (['ticket', 'response', 'hresult', 'message'], 'int'),
      'connectionError': (['ticket', 'hresult', 'message'], 'string'),
      'getLastError': (['ticket'], 'string'),
      'closeConnection': (['ticket'], 'string'),
    };
    final types = StringBuffer();
    final messages = StringBuffer();
    final portOps = StringBuffer();
    final bindingOps = StringBuffer();
    ops.forEach((name, spec) {
      final (params, result) = spec;
      final ints = {'qbXMLMajorVers', 'qbXMLMinorVers'};
      types.write('<s:element name="$name"><s:complexType><s:sequence>');
      for (final p in params) {
        types.write('<s:element minOccurs="0" maxOccurs="1" name="$p" type="s:${ints.contains(p) ? 'int' : 'string'}"/>');
      }
      types.write('</s:sequence></s:complexType></s:element>');
      final rType = result == 'ArrayOfString' ? 'tns:ArrayOfString' : 's:$result';
      types.write('<s:element name="${name}Response"><s:complexType><s:sequence>'
          '<s:element minOccurs="${result == 'int' ? 1 : 0}" maxOccurs="1" name="${name}Result" type="$rType"/>'
          '</s:sequence></s:complexType></s:element>');
      messages.write('<wsdl:message name="${name}SoapIn"><wsdl:part name="parameters" element="tns:$name"/></wsdl:message>'
          '<wsdl:message name="${name}SoapOut"><wsdl:part name="parameters" element="tns:${name}Response"/></wsdl:message>');
      portOps.write('<wsdl:operation name="$name"><wsdl:input message="tns:${name}SoapIn"/>'
          '<wsdl:output message="tns:${name}SoapOut"/></wsdl:operation>');
      bindingOps.write('<wsdl:operation name="$name"><soap:operation soapAction="$_ns$name" style="document"/>'
          '<wsdl:input><soap:body use="literal"/></wsdl:input><wsdl:output><soap:body use="literal"/></wsdl:output>'
          '</wsdl:operation>');
    });
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<wsdl:definitions xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/" xmlns:s="http://www.w3.org/2001/XMLSchema" '
        'xmlns:tns="$_ns" targetNamespace="$_ns" xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/">'
        '<wsdl:types><s:schema elementFormDefault="qualified" targetNamespace="$_ns">'
        '<s:complexType name="ArrayOfString"><s:sequence>'
        '<s:element minOccurs="0" maxOccurs="unbounded" name="string" nillable="true" type="s:string"/>'
        '</s:sequence></s:complexType>$types</s:schema></wsdl:types>'
        '$messages'
        '<wsdl:portType name="QBWebConnectorSvcSoap">$portOps</wsdl:portType>'
        '<wsdl:binding name="QBWebConnectorSvcSoap" type="tns:QBWebConnectorSvcSoap">'
        '<soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>$bindingOps</wsdl:binding>'
        '<wsdl:service name="QBWebConnectorSvc"><wsdl:port name="QBWebConnectorSvcSoap" binding="tns:QBWebConnectorSvcSoap">'
        '<soap:address location="${qbEscape(url)}"/></wsdl:port></wsdl:service>'
        '</wsdl:definitions>';
  }
}
