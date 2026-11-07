import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/approval.dart';
import '../../core/db.dart';
import '../../core/logic.dart';
import '../../mail/smtp_sender.dart';
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

  Future<Uint8List> _build() {
    final svc = context.svc;
    Future<Uint8List?> load(Rec f) async {
      try {
        var path = svc.files.localPath(f.s('sha256'));
        path ??= await svc.client?.fetchBlob(f.s('sha256'));
        return path == null ? null : await File(path).readAsBytes();
      } catch (_) {
        return null; // not available (e.g. away from the office network): leave it out
      }
    }

    return buildJobPacket(svc.db, widget.projectId, _o, load: load, zpdf: svc.zpdf);
  }

  String _filename() {
    final p = projectWithCustomer(context.db, widget.projectId)!;
    final kind = {'customer': 'Job-summary', 'production': 'Production-packet', 'office': 'Job-file'}[_preset]!;
    return safeFilename('${numberOf(p)}_${p.s('customer')}_${kind}_${today()}.pdf');
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final bytes = await _build();
      if (!mounted) return;
      await showPdf(
        context,
        bytes: bytes,
        filename: _filename(),
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

  /// Build the packet and email it to the customer from the shared mailbox (main office PC),
  /// or hand it to the device's share sheet. Either way the job records it as sent for approval.
  Future<void> _sendForApproval() async {
    final svc = context.svc;
    final db = svc.db;
    final p = projectWithCustomer(db, widget.projectId)!;
    final customer = db.get('customers', p.s('customer_id'));
    final direct = svc.mail != null && await svc.mail!.canSend();
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      _o.signoff = true; // the customer needs the page to sign
      final bytes = await _build();
      final name = _filename();
      if (!mounted) return;
      if (direct) {
        final (subject, text) = approvalEmailText(db, widget.projectId);
        final sent = await showDialog<String>(
          context: context,
          builder: (c) => _EmailDialog(
            to: customer?.ns('email') ?? '',
            subject: subject,
            text: text,
            attachment: name,
            send: (to, subject, text) => svc.mail!.send(
                to: to, subject: subject, text: text, attachments: [(name, bytes)], fromName: settings(db)['business_name']),
          ),
        );
        if (sent == null || !mounted) return;
        markSentForApproval(db, widget.projectId, to: sent);
        svc.files.addBytes(projectId: widget.projectId, bytes: bytes, name: name, category: _o.prices ? 'quotes' : 'other');
        toast(context, 'Sent to $sent. A copy is filed with the job.');
      } else {
        await Printing.sharePdf(bytes: bytes, filename: name);
        if (!mounted) return;
        if (await confirm(context, 'Did you send the packet to ${p.s('customer')}? The job will show it as waiting for approval.',
            ok: 'Yes, it was sent')) {
          markSentForApproval(db, widget.projectId, to: customer?.ns('email'), via: 'shared from this device');
          svc.files.addBytes(projectId: widget.projectId, bytes: bytes, name: name, category: _o.prices ? 'quotes' : 'other');
        }
      }
    } catch (e) {
      if (mounted) toast(context, "Couldn't send the packet: $e", error: true);
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
        Choices<String>(
          options: [
            if (svc.prices) ('customer', 'Customer', Icons.person_outline),
            ('production', 'Production / install', Icons.handyman_outlined),
            if (svc.prices) ('office', 'Office file', Icons.folder_outlined),
          ],
          value: _preset,
          onChanged: (v) => setState(() => _apply(v)),
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
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            label: Text(_busy ? 'Building…' : 'Create packet'),
          ),
          if (_preset == 'customer' && svc.prices)
            OutlinedButton.icon(
              onPressed: _busy ? null : _sendForApproval,
              icon: const Icon(Icons.forward_to_inbox_outlined),
              label: const Text('Email to customer for approval'),
            ),
        ]),
        if (p.ns('approval_sent_on') != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Muted(p.ns('approved_on') != null
                ? 'Approved by ${p.s('approved_by')} on ${p.s('approved_on')}.'
                : 'Sent for approval on ${p.s('approval_sent_on')}${p.ns('approval_sent_to') == null ? '' : ' to ${p.s('approval_sent_to')}'}. '
                    'Sending again replaces it: the customer approves the newest version.'),
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

class _EmailDialog extends StatefulWidget {
  const _EmailDialog(
      {required this.to, required this.subject, required this.text, required this.attachment, required this.send});
  final String to, subject, text, attachment;
  final Future<void> Function(List<String> to, String subject, String text) send;
  @override
  State<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends State<_EmailDialog> {
  late final _to = TextEditingController(text: widget.to);
  late final _subject = TextEditingController(text: widget.subject);
  late final _text = TextEditingController(text: widget.text);
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_to, _subject, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    final List<String> to;
    try {
      to = parseRecipients(_to.text);
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.send(to, _subject.text.trim(), _text.text);
      if (mounted) Navigator.pop(context, to.join(', '));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Email for approval'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                  controller: _to,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'To', helperText: 'Several addresses: separate with commas')),
              const SizedBox(height: 8),
              TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Subject')),
              const SizedBox(height: 8),
              TextField(
                  controller: _text,
                  minLines: 6,
                  maxLines: 14,
                  decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true)),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.attach_file, size: 18),
                const SizedBox(width: 4),
                Expanded(child: Muted(widget.attachment, size: 12)),
              ]),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: WarnBanner(_error!)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: _sending ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: _sending ? null : _go,
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: Text(_sending ? 'Sending…' : 'Send'),
          ),
        ],
      );
}
