import 'package:flutter/material.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../mail/imap_fetcher.dart';
import '../../mail/mail_ingest.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'project_screen.dart';

/// Measurement emails: the ones that need a human decision, and recently filed ones.
class MailInboxScreen extends StatefulWidget {
  const MailInboxScreen({super.key});
  @override
  State<MailInboxScreen> createState() => _MailInboxScreenState();
}

class _MailInboxScreenState extends State<MailInboxScreen> {
  bool _showIgnored = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    return Scaffold(
      appBar: AppBar(title: const Text('Email inbox'), actions: [
        if (svc.mail != null)
          ListenableBuilder(
            listenable: svc.mail!,
            builder: (c, _) => TextButton.icon(
              onPressed: svc.mail!.checking
                  ? null
                  : () async {
                      final msg = await svc.mail!.checkNow();
                      if (context.mounted) toast(context, msg);
                    },
              icon: const Icon(Icons.refresh),
              label: Text(svc.mail!.checking ? 'Checking…' : 'Check now'),
            ),
          ),
      ]),
      body: DbBuilder(
        db: db,
        builder: (context) {
          final waiting = db.select(
              "SELECT * FROM mail_inbox WHERE status='unmatched' AND deleted=0 ORDER BY received_at DESC");
          final filed = db.select('''SELECT m.*, p.number AS pnum, p.title AS ptitle, c.name AS customer
              FROM mail_inbox m LEFT JOIN projects p ON p.id=m.project_id LEFT JOIN customers c ON c.id=p.customer_id
              WHERE m.status='filed' AND m.deleted=0 ORDER BY m.received_at DESC LIMIT 50''');
          final ignored = _showIgnored
              ? db.select("SELECT * FROM mail_inbox WHERE status='ignored' AND deleted=0 ORDER BY received_at DESC LIMIT 50")
              : const <Rec>[];
          return PageBody(maxWidth: 1000, children: [
            if (svc.mail == null)
              const WarnBanner('Emails are read by the main office PC and appear here after the next sync.', serious: false),
            if (svc.mail != null && !svc.mail!.enabled)
              const WarnBanner('Reading the measurement mailbox is switched off. Set it up under Settings › Measurement email.'),
            Section(
              title: 'Needs filing (${waiting.length})',
              child: waiting.isEmpty
                  ? const Muted('Nothing waiting. Emails whose subject matches a job address are filed automatically.')
                  : Column(children: [for (final m in waiting) _MailCard(item: m)]),
            ),
            Section(
              title: 'Recently filed',
              child: filed.isEmpty
                  ? const Muted('No measurement emails filed yet.')
                  : Column(children: [for (final m in filed) _MailCard(item: m)]),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showIgnored = !_showIgnored),
                child: Text(_showIgnored ? 'Hide ignored emails' : 'Show ignored emails'),
              ),
            ),
            for (final m in ignored) _MailCard(item: m),
          ]);
        },
      ),
    );
  }
}

class _MailCard extends StatelessWidget {
  const _MailCard({required this.item});
  final Rec item;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    final status = item.s('status');
    final received = DateTime.tryParse(item.s('received_at'))?.toLocal().toIso8601String();
    final atts = mailAttachments(item);
    final candidates = status == 'unmatched' ? matchProject(db, item.s('subject')).candidates : const <String>[];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.mail_outline, size: 18),
            const SizedBox(width: 6),
            Expanded(
                child: Text(item.s('subject').isEmpty ? '(no subject)' : item.s('subject'),
                    style: const TextStyle(fontWeight: FontWeight.w700))),
            StatusChip(status == 'filed' ? 'approved' : (status == 'ignored' ? 'void' : 'pending'),
                label: status == 'unmatched' ? 'needs filing' : status),
          ]),
          const SizedBox(height: 2),
          Muted('${item.s('sender')} · ${fmtDateTime(received)}', size: 12),
          if (item.ns('note') != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(item.s('note'))),
          if (status == 'filed' && item.ns('pnum') != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => push(context, ProjectScreen(projectId: item.s('project_id'))),
              icon: const Icon(Icons.work_outline, size: 16),
              label: Text('${item.s('pnum')} · ${item.s('customer')} · ${item.s('ptitle')}'),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in atts)
              ActionChip(
                avatar: Icon((a['name'] as String).toLowerCase().endsWith('.pdf')
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined, size: 16),
                label: Text(a['name'] as String, overflow: TextOverflow.ellipsis),
                onPressed: () => openStoredFile(context, Rec({'sha256': a['sha256'], 'name': a['name']})),
              ),
          ]),
          if (item.ns('body') != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(item.s('body'), maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          if (status == 'unmatched') ...[
            if (candidates.isNotEmpty) ...[
              const Muted('Possible jobs:', size: 12),
              Wrap(spacing: 6, children: [
                for (final pid in candidates.take(5))
                  if (projectWithCustomer(db, pid) case final p?)
                    ActionChip(
                      label: Text('${numberOf(p)} ${p.s('customer')}'),
                      onPressed: () => _file(context, pid),
                    ),
              ]),
              const SizedBox(height: 6),
            ],
            Wrap(spacing: 8, runSpacing: 6, children: [
              FilledButton.icon(
                  onPressed: () async {
                    final pid = await pickJob(context, suggested: candidates);
                    if (pid != null && context.mounted) _file(context, pid);
                  },
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('File to job…')),
              OutlinedButton.icon(
                  onPressed: () => _newJob(context),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('New customer & job')),
              TextButton(onPressed: () => ignoreMailItem(db, item.id), child: const Text('Ignore')),
            ]),
          ] else if (status == 'filed')
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed: () async {
                    final pid = await pickJob(context);
                    if (pid == null || !context.mounted) return;
                    await attempt(context, () async => moveMailItem(db, svc.files, item.id, pid), success: 'Moved');
                  },
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Wrong job? Move')),
              TextButton(
                  onPressed: () => unfileMailItem(db, item.id),
                  child: const Text('Put back in inbox')),
            ])
          else
            TextButton(
                onPressed: () => db.update('mail_inbox', item.id, {'status': 'unmatched', 'note': 'Restored.'}),
                child: const Text('Restore')),
        ]),
      ),
    );
  }

  Future<void> _file(BuildContext context, String pid) => attempt(context, () async {
        fileMailItem(context.db, context.svc.files, item.id, pid);
      }, success: 'Filed');

  Future<void> _newJob(BuildContext context) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final title = TextEditingController(text: 'Kitchen');
    final address = TextEditingController(text: mailAddress(item));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New customer & job'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Muted('From the email "${item.s('subject')}"'),
            const SizedBox(height: 12),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'Site address')),
            const SizedBox(height: 8),
            TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Customer name *')),
            const SizedBox(height: 8),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 8),
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Job title')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create & file')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await attempt(context, () async {
      final pid = createJobFromMail(context.db, context.svc.files, item.id,
          customerName: name.text.trim(), phone: phone.text.trim(), title: title.text.trim(), address: address.text);
      if (context.mounted) push(context, ProjectScreen(projectId: pid));
    });
  }
}

/// Pick a job, suggestions first. Returns the project id.
Future<String?> pickJob(BuildContext context, {List<String> suggested = const []}) => showDialog<String>(
      context: context,
      builder: (c) => _JobPicker(suggested: suggested),
    );

class _JobPicker extends StatefulWidget {
  const _JobPicker({required this.suggested});
  final List<String> suggested;
  @override
  State<_JobPicker> createState() => _JobPickerState();
}

class _JobPickerState extends State<_JobPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final all = projectsList(db, query: _q);
    all.sort((a, b) {
      final sa = widget.suggested.contains(a.id) ? 0 : 1, sb = widget.suggested.contains(b.id) ? 0 : 1;
      return sa != sb ? sa - sb : b.s('updated_at').compareTo(a.s('updated_at'));
    });
    return AlertDialog(
      title: const Text('File to which job?'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Customer, address or job #'),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final p in all.take(100))
                ListTile(
                  dense: true,
                  leading: widget.suggested.contains(p.id) ? const Icon(Icons.star_outline, size: 18) : null,
                  title: Text('${p.s('customer')} · ${p.s('title')}'),
                  subtitle: Text('${numberOf(p)} · ${p.s('site_address')}'),
                  trailing: StatusChip(p.s('status')),
                  onTap: () => Navigator.pop(context, p.id),
                ),
            ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// Main office PC, owner: connect the shared Gmail mailbox.
class MailSettingsScreen extends StatefulWidget {
  const MailSettingsScreen({super.key});
  @override
  State<MailSettingsScreen> createState() => _MailSettingsScreenState();
}

class _MailSettingsScreenState extends State<MailSettingsScreen> {
  late final _mail = context.svc.mail!;
  late final _user = TextEditingController(text: _mail.user);
  final _password = TextEditingController();
  late final _host = TextEditingController(text: _mail.host);
  late final _port = TextEditingController(text: '${_mail.port}');
  late final _folder = TextEditingController(text: _mail.folder);
  late final _minutes = TextEditingController(text: '${_mail.pollMinutes}');
  late final _days = TextEditingController(text: '${_mail.sinceDays}');
  late bool _enabled = _mail.enabled || _mail.user.isEmpty;
  bool _hasPassword = false;
  bool _busy = false;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _mail.hasPassword().then((v) => mounted ? setState(() => _hasPassword = v) : null);
  }

  @override
  void dispose() {
    for (final c in [_user, _password, _host, _port, _folder, _minutes, _days]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool test = false}) async {
    setState(() => _busy = true);
    await attempt(context, () => _doSave(test: test));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _doSave({bool test = false}) async {
    try {
      if (test) {
        final pw = _password.text.isNotEmpty ? _password.text.replaceAll(' ', '') : (await _mail.config())?.password;
        if (pw == null) {
          if (mounted) toast(context, 'Enter the app password first.', error: true);
          return;
        }
        final err = await testMailConnection(MailConfig(
            host: _host.text.trim(), port: int.tryParse(_port.text) ?? 993, user: _user.text.trim(), password: pw,
            folder: _folder.text.trim().isEmpty ? 'INBOX' : _folder.text.trim()));
        if (mounted) toast(context, err ?? 'Connected. The mailbox can be read.', error: err != null);
        if (err != null) return;
      }
      await _mail.save(
        enabled: _enabled,
        host: _host.text,
        port: int.tryParse(_port.text) ?? 993,
        user: _user.text,
        password: _password.text,
        folder: _folder.text,
        pollMinutes: int.tryParse(_minutes.text) ?? 5,
        sinceDays: int.tryParse(_days.text) ?? 14,
      );
      _password.clear();
      _hasPassword = await _mail.hasPassword();
      if (mounted && !test) toast(context, 'Saved');
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Measurement email')),
        body: PageBody(maxWidth: 760, children: [
          const Text('Cabinet CRM reads the shared measurement mailbox on this PC and files each email '
              'into the job whose site address is in the subject, as a measurement record with the PDFs and photos. '
              'Emails it can\'t match wait in the Email inbox. Nothing in the mailbox is changed or deleted.'),
          const SizedBox(height: 12),
          const WarnBanner(
              'Gmail needs an app password, not the normal password:\n'
              '1. Sign in to the shared Gmail account and open myaccount.google.com → Security.\n'
              '2. Turn on 2-Step Verification if it is off.\n'
              '3. Open "App passwords" (search for it at the top), create one named "Cabinet CRM" and copy the 16 letters here.\n'
              'Google Workspace: the admin may need to allow IMAP and app passwords for the account.',
              serious: false),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('Read the measurement mailbox'),
          ),
          TextField(
              controller: _user,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Shared mailbox address', hintText: 'measurements@yourcompany.com')),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'App password',
              helperText: _hasPassword ? 'A password is saved (in Windows Credential Manager). Leave empty to keep it.' : null,
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _minutes, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Check every (minutes)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _days, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'First time: import the last (days)'))),
          ]),
          TextButton(onPressed: () => setState(() => _advanced = !_advanced), child: Text(_advanced ? 'Hide advanced' : 'Advanced')),
          if (_advanced) ...[
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: _host, decoration: const InputDecoration(labelText: 'IMAP server'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _folder,
                decoration: const InputDecoration(labelText: 'Folder / Gmail label', helperText: 'INBOX, or a label such as Measurements')),
            const SizedBox(height: 12),
          ],
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(onPressed: _busy ? null : () => _save(test: true), child: const Text('Test & save')),
            OutlinedButton(onPressed: _busy ? null : () => _save(), child: const Text('Save')),
            ListenableBuilder(
              listenable: _mail,
              builder: (c, _) => OutlinedButton.icon(
                onPressed: _mail.checking || _busy
                    ? null
                    : () async {
                        final msg = await _mail.checkNow();
                        if (context.mounted) toast(context, msg);
                      },
                icon: const Icon(Icons.refresh),
                label: Text(_mail.checking ? 'Checking…' : 'Check now'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: _mail,
            builder: (c, _) => KeyValues([
              ('Last check', fmtDateTime(_mail.lastCheck)),
              ('Result', _mail.lastError ?? _mail.lastSummary ?? '-'),
            ]),
          ),
          const SizedBox(height: 12),
          const Muted(
              'Tips for the techs: put the site address at the start of the subject (e.g. "123 Main St – kitchen"), '
              'one job per email, PDFs and photos as attachments.',
              size: 12),
        ]),
      );
}
