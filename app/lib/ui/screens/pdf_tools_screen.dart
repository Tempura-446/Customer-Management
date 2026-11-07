import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services.dart';
import '../widgets/common.dart';

/// Settings › PDF tools: connect ZPDF (PDF-Manager) for sharper job packets and annotating/signing PDFs.
class PdfToolsScreen extends StatefulWidget {
  const PdfToolsScreen({super.key});
  @override
  State<PdfToolsScreen> createState() => _PdfToolsScreenState();
}

class _PdfToolsScreenState extends State<PdfToolsScreen> {
  String? _version;
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final z = context.svc.zpdf;
    setState(() {
      _checking = true;
      _error = null;
      _version = null;
    });
    if (z != null) {
      try {
        _version = await z.version();
      } catch (e) {
        _error = '$e';
      }
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _choose() async {
    final svc = context.svc;
    final picked = await FilePicker.pickFiles(dialogTitle: 'Choose pdfm.exe or ZPDF\'s python.exe');
    if (picked.isEmpty || picked.first.path == null) return;
    svc.db.setMeta('zpdf_path', picked.first.path!);
    svc.detectZpdf();
    await _check();
  }

  void _reset() {
    final svc = context.svc;
    svc.db.raw.execute("DELETE FROM meta WHERE key='zpdf_path'");
    svc.detectZpdf();
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final svc = ServicesScope.of(context);
    final z = svc.zpdf;
    return Scaffold(
      appBar: AppBar(title: const Text('PDF tools')),
      body: PageBody(maxWidth: 760, children: [
        const Text('Casework can use ZPDF (your PDF-Manager toolkit) when it is installed on this computer:'),
        const SizedBox(height: 6),
        const Text('• Job packets: the original drawing and measurement PDFs are merged in as real pages, sharp when zoomed '
            'and searchable, with a bookmark for each part and page numbers across the whole packet.\n'
            '• "Open in ZPDF" on any PDF attached to a job, to annotate, sign or edit it.'),
        const SizedBox(height: 16),
        Section(
          title: 'Status',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_checking)
              const LinearProgressIndicator()
            else if (z == null)
              const WarnBanner('ZPDF was not found on this computer. Packets still work, with drawings added as pictures.',
                  serious: false)
            else if (_error != null)
              WarnBanner('ZPDF was found but did not start: $_error')
            else
              WarnBanner('Connected: ${_version ?? 'ZPDF'}', serious: false),
            if (z != null) KeyValues([('Program', z.display)]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: _checking ? null : () {
                svc.detectZpdf();
                _check();
              }, icon: const Icon(Icons.refresh), label: const Text('Look again')),
              OutlinedButton.icon(onPressed: _choose, icon: const Icon(Icons.folder_open), label: const Text('Choose program…')),
              if (svc.db.meta('zpdf_path') != null)
                TextButton(onPressed: _reset, child: const Text('Use automatic detection')),
            ]),
          ]),
        ),
        const Section(
          title: 'Installing ZPDF on Windows',
          child: Text('1. Open the PDF-Manager repository on GitHub → Code → Download ZIP, and unzip it.\n'
              '2. Double-click "Install ZPDF.cmd" (More info → Run anyway if Windows asks).\n'
              '3. Come back here and click "Look again".\n\n'
              'Casework looks in %LOCALAPPDATA%\\PDF Manager\\app (where the installer puts it) and for "pdfm" '
              'on the PATH. The standalone ZPDF app (ZPDF.exe) only opens a window, so use the installer version.'),
        ),
      ]),
    );
  }
}
