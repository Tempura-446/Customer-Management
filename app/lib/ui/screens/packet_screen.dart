import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../pdf/documents.dart';
import '../../services.dart';
import '../widgets/common.dart';

/// Print a summary packet for a job: selections, measurements, drawings, scope/price, photos, sign-off.
class PacketScreen extends StatefulWidget {
  const PacketScreen({super.key, required this.projectId});
  final String projectId;
  @override
  State<PacketScreen> createState() => _PacketScreenState();
}

class _PacketScreenState extends State<PacketScreen> {
  String _preset = 'customer';
  late PacketOptions _o;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _apply(context.svc.prices ? 'customer' : 'production');
  }

  void _apply(String preset) {
    _preset = preset;
    _o = switch (preset) {
      'production' => PacketOptions.production(),
      'office' => PacketOptions.office(),
      _ => PacketOptions.customer(),
    };
    if (!context.svc.prices) _o.prices = false;
  }

  Future<void> _create() async {
    final svc = context.svc;
    setState(() => _busy = true);
    try {
      Future<Uint8List?> load(Rec f) async {
        try {
          var path = svc.files.localPath(f.s('sha256'));
          path ??= await svc.client?.fetchBlob(f.s('sha256'));
          return path == null ? null : await File(path).readAsBytes();
        } catch (_) {
          return null; // not available (e.g. away from the office network): leave it out
        }
      }

      final bytes = await buildJobPacket(svc.db, widget.projectId, _o, load: load, zpdf: svc.zpdf);
      if (!mounted) return;
      final p = projectWithCustomer(svc.db, widget.projectId)!;
      final kind = {'customer': 'Job-summary', 'production': 'Production-packet', 'office': 'Job-file'}[_preset]!;
      await showPdf(
        context,
        bytes: bytes,
        filename: safeFilename('${numberOf(p)}_${p.s('customer')}_${kind}_${today()}.pdf'),
        projectId: widget.projectId,
        // Packets with prices are filed with quotes so installers' phones never receive them.
        category: _o.prices ? 'quotes' : 'other',
      );
    } catch (e) {
      if (mounted) toast(context, "Couldn't build the packet: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final p = projectWithCustomer(svc.db, widget.projectId)!;
    Widget opt(String label, bool value, ValueChanged<bool> set, {String? sub, bool enabled = true}) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: value,
          title: Text(label),
          subtitle: sub == null ? null : Text(sub),
          onChanged: enabled ? (v) => setState(() => set(v ?? false)) : null,
        );
    return Scaffold(
      appBar: AppBar(title: Text('Job packet · ${numberOf(p)} ${p.s('customer')}')),
      body: PageBody(maxWidth: 720, children: [
        SegmentedButton<String>(
          segments: [
            if (svc.prices)
              const ButtonSegment(value: 'customer', icon: Icon(Icons.person_outline), label: Text('Customer')),
            const ButtonSegment(value: 'production', icon: Icon(Icons.handyman_outlined), label: Text('Production / install')),
            if (svc.prices) const ButtonSegment(value: 'office', icon: Icon(Icons.folder_outlined), label: Text('Office file')),
          ],
          selected: {_preset},
          onSelectionChanged: (s) => setState(() => _apply(s.first)),
        ),
        const SizedBox(height: 8),
        Muted(switch (_preset) {
          'production' => 'For the shop and installers: selections, measurements, drawings, scope, photos and notes. No prices.',
          'office' => 'Everything on file for this job, including prices, payments and notes.',
          _ => 'For the customer to review and sign: selections, measurements, drawings and price, with an approval page.',
        }),
        const SizedBox(height: 8),
        opt('Prices', _o.prices, (v) => _o.prices = v,
            enabled: svc.prices, sub: svc.prices ? null : 'Not available for your role'),
        opt('"Check before ordering" warnings', _o.warnings, (v) => _o.warnings = v),
        opt('Selections', _o.selections, (v) => _o.selections = v),
        opt('Measurements', _o.measurements, (v) => _o.measurements = v),
        opt('Design drawings (PDF pages and images of the current design)', _o.drawings, (v) => _o.drawings = v),
        opt(_o.prices ? 'Quote' : 'Scope of work (quote lines without prices)', _o.quote, (v) => _o.quote = v),
        if (_o.prices) opt('Payments & balance', _o.payments, (v) => _o.payments = v),
        opt('Measurement PDFs (e.g. the techs\' measurement sheets)', _o.attachedPdfs, (v) => _o.attachedPdfs = v),
        opt('Site photos (up to ${_o.maxPhotos})', _o.photos, (v) => _o.photos = v),
        opt('Notes (calls, emails, site visits)', _o.notes, (v) => _o.notes = v),
        opt('Customer approval / signature page', _o.signoff, (v) => _o.signoff = v),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            label: Text(_busy ? 'Building…' : 'Create packet'),
          ),
        ),
        const SizedBox(height: 8),
        if (Services.desktop)
          WarnBanner(
              svc.zpdf != null
                  ? 'ZPDF found: drawings and measurement PDFs are merged in as original pages '
                      '(sharp when zoomed, text searchable), with bookmarks and page numbers.'
                  : 'Tip: install ZPDF (PDF-Manager) on this computer and drawings and measurement PDFs are merged in '
                      'as original pages instead of pictures. See Settings › PDF tools.',
              serious: false),
        if (!svc.isHub)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Muted('Drawings and photos not yet on this device are downloaded from the main PC; '
                'away from the office network they are left out.', size: 12),
          ),
      ]),
    );
  }
}
