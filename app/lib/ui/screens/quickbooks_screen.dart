import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../qb/qb_sync.dart';
import '../../qb/qbwc_server.dart';
import '../../services.dart';
import '../widgets/common.dart';

/// Settings › QuickBooks (main office PC, owner): connect QuickBooks Desktop through the Web Connector.
class QuickBooksScreen extends StatefulWidget {
  const QuickBooksScreen({super.key, required this.qbwc, required this.port});
  final QbwcService qbwc;
  final int port;
  @override
  State<QuickBooksScreen> createState() => _QuickBooksScreenState();
}

class _QuickBooksScreenState extends State<QuickBooksScreen> {
  final _pw = TextEditingController();
  bool _hasPw = false;

  QbSync get _sync => widget.qbwc.sync;

  @override
  void initState() {
    super.initState();
    widget.qbwc.hasPassword().then((v) => mounted ? setState(() => _hasPw = v) : null);
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _savePassword() async {
    if (_pw.text.trim().length < 6) {
      toast(context, 'Use at least 6 characters.', error: true);
      return;
    }
    await attempt(context, () async {
      await widget.qbwc.setPassword(_pw.text.trim());
      _pw.clear();
      _hasPw = true;
      if (mounted) setState(() {});
    }, success: 'Password saved. Enter the same password in the Web Connector.');
  }

  Future<void> _saveQwc() async {
    final bytes = Uint8List.fromList(utf8.encode(widget.qbwc.qwcFile(port: widget.port)));
    await attempt(context, () async {
      final uri = await FilePicker.saveFile(
        fileName: 'Casework.qwc',
        bytes: bytes,
        mimeType: 'application/xml',
        dialogTitle: 'Save the Web Connector file',
      );
      if (uri != null && mounted) toast(context, 'Saved. Now add it in the QuickBooks Web Connector (step 3).');
    });
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    return Scaffold(
      appBar: AppBar(title: const Text('QuickBooks')),
      body: ListenableBuilder(
        listenable: _sync,
        builder: (context, _) => PageBody(maxWidth: 820, children: [
          const Text('Casework works with QuickBooks Desktop (Enterprise 14) through Intuit\'s Web Connector, '
              'which comes with QuickBooks:'),
          const SizedBox(height: 6),
          const Text('• New customers and jobs from Casework are created in QuickBooks as Customer:Job, '
              'so nobody types them twice.\n'
              '• Repeat customers already in QuickBooks are matched by name or phone and linked (not duplicated). '
              'QuickBooks customers Casework doesn\'t have yet are imported, so you find them when they call again.\n'
              '• Estimates you make in QuickBooks show on the Casework job (number, total, lines). The job moves '
              'to Quoted, and to Approved once the estimate becomes an invoice or sales order.\n'
              '• Nothing is deleted or changed in QuickBooks other than adding customers and jobs.'),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _sync.enabled,
            onChanged: (v) => _sync.configure(enabled: v),
            title: const Text('Sync with QuickBooks'),
            subtitle: const Text('When off, the Web Connector connects but nothing is exchanged.'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _sync.importCustomers,
            onChanged: (v) => _sync.configure(importCustomers: v),
            title: const Text('Import QuickBooks customers into Casework'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _sync.createJobs,
            onChanged: (v) => _sync.configure(createJobs: v),
            title: const Text('Create jobs in QuickBooks automatically'),
            subtitle: const Text('As "J-2026-014 Kitchen" under the customer.'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: quotesInQuickBooks(db),
            onChanged: (v) => setState(() => setSetting(db, 'quotes_in_quickbooks', v ? '1' : '0')),
            title: const Text('Quotes & invoices are done in QuickBooks'),
            subtitle: const Text('Jobs show QuickBooks estimates instead of Casework quotes and invoices.'),
          ),
          Section(
            title: 'Set up (once)',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('1. Choose a Web Connector password:'),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _pw,
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: 'Web Connector password',
                        helperText: _hasPw ? 'A password is set. Type a new one to change it.' : null),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _savePassword, child: const Text('Save')),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                const Expanded(child: Text('2. Save the Web Connector file (Casework.qwc):')),
                OutlinedButton.icon(onPressed: _saveQwc, icon: const Icon(Icons.download), label: const Text('Save .qwc file')),
              ]),
              const SizedBox(height: 12),
              const Text(
                  '3. On THIS PC, open QuickBooks as the Admin user, in single-user mode the first time, with your company file.\n'
                  '4. In QuickBooks: File › Update Web Services (or Start menu › QuickBooks Web Connector).\n'
                  '5. In the Web Connector: Add an application › choose Casework.qwc › OK.\n'
                  '6. QuickBooks asks whether to allow Casework: choose "Yes, always; allow access even if QuickBooks is '
                  'not running", log in as Admin (or a user with access to customers and estimates), Continue, Done.\n'
                  '7. Back in the Web Connector: type the password from step 1 in the Password column (Yes to save it), '
                  'tick "Auto-Run" and set "Every_Min" to 15.\n'
                  '8. Click "Update Selected" to run the first sync now. You can switch QuickBooks back to multi-user mode afterwards.\n\n'
                  'The Web Connector must run on this PC (the main office PC) because it only talks to Casework here. '
                  'Casework must be open (it can sit at the sign-in screen).'),
            ]),
          ),
          Section(
            title: 'Status',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_sync.running) const LinearProgressIndicator(),
              KeyValues([
                ('Last sync', fmtDateTime(_sync.lastRun)),
                ('Result', _sync.lastResult ?? 'Not run yet'),
                if (_sync.lastError != null) ('Error', _sync.lastError!),
                ('Web Connector URL', 'http://localhost:${widget.port}/qbwc'),
              ]),
              if (_sync.lastLog.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Details of the last sync'),
                  children: [
                    for (final l in _sync.lastLog.reversed.take(60))
                      Align(alignment: Alignment.centerLeft, child: Muted(l, size: 12)),
                  ],
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Job page: estimates from QuickBooks, the linked QuickBooks job, and attaching QuickBooks PDFs.
class QbEstimatesCard extends StatelessWidget {
  const QbEstimatesCard({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final p = db.get('projects', projectId);
    final estimates = qbEstimatesFor(db, projectId);
    return Section(
      title: 'QuickBooks estimates',
      action: TextButton.icon(
        onPressed: () => _attach(context),
        icon: const Icon(Icons.attach_file, size: 18),
        label: const Text('Attach QuickBooks PDF'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (p?.ns('qb_full_name') != null)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Muted('QuickBooks job: ${p!.s('qb_full_name')}', size: 12))
        else
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Muted('Not linked to a QuickBooks job yet. The next QuickBooks sync creates or links it.', size: 12),
          ),
        if (estimates.isEmpty)
          const Muted('No QuickBooks estimates yet. Make the estimate in QuickBooks for this job; it appears here after the next sync.'),
        for (final e in estimates)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            elevation: 0,
            shape: RoundedRectangleBorder(
                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
            child: ExpansionTile(
              dense: true,
              title: Text('Estimate #${e.s('ref_number')} · ${fmtMoney(e.d('total'))}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([fmtDate(e.ns('txn_date')), if (e.ns('memo') != null) e.s('memo')].join(' · ')),
              trailing: StatusChip(e.b('accepted') ? 'accepted' : (e.b('is_active') ? 'sent' : 'void'),
                  label: e.b('accepted') ? 'accepted' : (e.b('is_active') ? 'open' : 'closed')),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              children: [
                for (final l in qbEstimateLines(e))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(
                          child: Text([l['item'], l['desc']].whereType<String>().where((s) => s.isNotEmpty).join(' · '))),
                      if (l['qty'] != null) SizedBox(width: 50, child: Text(fmtQty(l['qty'] as num), textAlign: TextAlign.right)),
                      SizedBox(width: 100, child: Text(fmtMoney((l['amount'] as num?) ?? 0), textAlign: TextAlign.right)),
                    ]),
                  ),
                const Divider(),
                Row(children: [
                  const Expanded(child: Text('Subtotal')),
                  Text(fmtMoney(e.d('subtotal'))),
                ]),
                Row(children: [
                  const Expanded(child: Text('Tax')),
                  Text(fmtMoney(e.d('tax'))),
                ]),
                Row(children: [
                  const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
                  Text(fmtMoney(e.d('total')), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ],
            ),
          ),
        const SizedBox(height: 4),
        const Muted('PDFs of QuickBooks quotes and invoices you attach here are filed with the job (hidden from field staff).',
            size: 12),
      ]),
    );
  }

  Future<void> _attach(BuildContext context) async {
    final svc = context.svc;
    final picked = await FilePicker.pickFiles(dialogTitle: 'Attach QuickBooks estimate / invoice PDF');
    if (picked.isEmpty || !context.mounted) return;
    final kind = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text('What is it?'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'quotes'), child: const Text('Estimate / quote')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'invoices'), child: const Text('Invoice')),
      ]),
    );
    if (kind == null || !context.mounted) return;
    await attempt(context, () async {
      for (final f in picked) {
        if (f.path == null) continue;
        svc.files.addFile(projectId: projectId, sourcePath: f.path!, name: f.name, category: kind);
      }
    }, success: '${picked.length} file(s) attached');
  }
}
