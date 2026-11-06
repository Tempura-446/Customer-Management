import 'dart:io';
import 'dart:typed_data';

import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/files.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:cabinet_crm/pdf/documents.dart';
import 'package:cabinet_crm/pdf/zpdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

/// Runs only where ZPDF is installed (set CABINET_CRM_PDFM=/path/to/pdfm, or have pdfm on the PATH).
void main() {
  final z = ZPdf.detect();

  Future<Uint8List> onePager(String text) async {
    final d = pw.Document(theme: pw.ThemeData.withFont(base: pw.Font.helvetica()));
    d.addPage(pw.Page(build: (c) => pw.Center(child: pw.Text(text))));
    return d.save();
  }

  test('packet with ZPDF: original drawing + measurement PDFs merged as pages, numbered, bookmarked', () async {
    final tmp = await Directory.systemTemp.createTemp('zpdf');
    final db = AppDb.memory(isHub: true);
    seedSettings(db);
    final files = FileStore(db, tmp.path);
    final cid = saveCustomer(db, {'name': 'Jane', 'address': '1 Main St'});
    final pid = createProject(db, customerId: cid, title: 'Kitchen', orderType: 'install');
    final mid = saveMeasurement(db, projectId: pid, room: 'Kitchen', source: 'onsite', lines: [MeasureLine('Wall A', '144', 'in')]);
    files.addBytes(projectId: pid, bytes: await onePager('TECH MEASURE SHEET'), name: 'Site measure.pdf',
        category: 'measurements', entityType: 'measurement', entityId: mid);
    final did = saveDesign(db, projectId: pid, title: 'L-shape', measurementId: mid);
    files.addBytes(projectId: pid, bytes: await onePager('ELEVATION DRAWING'), name: 'Elevations.pdf',
        category: 'designs', entityType: 'design', entityId: did);

    final bytes = await buildJobPacket(db, pid, PacketOptions.production(), zpdf: z,
        load: (f) async => File(files.localPath(f.s('sha256'))!).readAsBytes(), rasterize: (_) async => []);
    final out = File('${tmp.path}/packet.pdf')..writeAsBytesSync(bytes);

    Future<String> pdfm(List<String> args) async =>
        '${(await Process.run(z!.executable, [...z.prefix, ...args])).stdout}';
    await pdfm(['text', out.path, '-o', '${tmp.path}/packet.txt']);
    final text = File('${tmp.path}/packet.txt').readAsStringSync();
    expect(text, contains('PRODUCTION PACKET'));
    expect(text, contains('ELEVATION DRAWING'), reason: 'drawing kept as a real (text) page');
    expect(text, contains('TECH MEASURE SHEET'));
    expect(text, contains('Page 1 of'));
    final marks = await pdfm(['bookmarks', out.path]);
    expect(marks, contains('Drawing - Elevations'));
    expect(marks, contains('Measurements Kitchen - Site measure'));
    await tmp.delete(recursive: true);
  }, skip: z == null ? 'ZPDF (pdfm) not installed' : false);
}
