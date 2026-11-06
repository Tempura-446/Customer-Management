import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';

const _labels = {
  'business_name': 'Business name',
  'business_address': 'Address',
  'business_phone': 'Phone',
  'business_email': 'Email',
  'default_tax_rate': 'Tax rate %',
  'default_deposit_pct': 'Deposit %',
  'quote_valid_days': 'Quote valid (days)',
  'invoice_due_days': 'Invoice due (days)',
  'quote_followup_days': 'Follow up quotes after (days)',
  'default_terms': 'Default terms on quotes',
};
const _numberKeys = [
  'default_tax_rate', 'default_deposit_pct', 'quote_valid_days', 'invoice_due_days', 'quote_followup_days'
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ctrl = <String, TextEditingController>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  void _load() {
    final s = settings(context.db);
    for (final k in defaultSettings.keys) {
      (_ctrl[k] ??= TextEditingController()).text = s[k] ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final db = context.db;
    final current = settings(db);
    for (final k in _numberKeys) {
      if (double.tryParse(_ctrl[k]!.text.trim()) == null) {
        toast(context, '${_labels[k]} must be a number', error: true);
        return;
      }
    }
    db.tx(() {
      for (final k in defaultSettings.keys) {
        final v = _ctrl[k]!.text.trim();
        if (v != current[k]) setSetting(db, k, v);
      }
    });
    toast(context, 'Settings saved');
  }

  Widget _field(String k, {bool editable = true, int maxLines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _ctrl[k],
          readOnly: !editable,
          maxLines: maxLines,
          keyboardType: _numberKeys.contains(k) ? const TextInputType.numberWithOptions(decimal: true) : null,
          decoration: InputDecoration(labelText: _labels[k] ?? k),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final canEdit = svc.prices; // owner / office
    final wide = isWide(context);
    Widget row(List<String> keys) => wide
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final k in keys) ...[
              Expanded(child: _field(k, editable: canEdit)),
              if (k != keys.last) const SizedBox(width: 12),
            ],
          ])
        : Column(children: [for (final k in keys) _field(k, editable: canEdit)]);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: PageBody(maxWidth: 900, children: [
        Section(
          title: 'Business (printed on quotes & invoices)',
          child: Column(children: [
            _field('business_name', editable: canEdit),
            _field('business_address', editable: canEdit),
            row(['business_phone', 'business_email']),
          ]),
        ),
        if (canEdit)
          Section(
            title: 'Defaults',
            child: Column(children: [
              row(['default_tax_rate', 'default_deposit_pct']),
              row(['quote_valid_days', 'invoice_due_days', 'quote_followup_days']),
              _field('default_terms', maxLines: 4),
            ]),
          ),
        if (canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save settings')),
            ),
          ),
        if (!canEdit) const Padding(padding: EdgeInsets.only(bottom: 12), child: Muted('Only the office can change settings.')),
        if (svc.isHub && svc.isOwner)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Staff'),
              subtitle: const Text('People who use the PC and phones, their roles and PINs'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(context, const UsersScreen()),
            ),
          ),
        if (svc.isHub)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Data folder'),
              subtitle: SelectableText('${svc.files.root}\n'
                  'Back up this folder (database + all project files), e.g. with OneDrive or an external drive.'),
              isThreeLine: true,
              trailing: IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => openFolder(svc.files.root)),
            ),
          ),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Cabinet CRM'),
            subtitle: Text([
              svc.isHub ? 'This PC is the hub (master copy).' : 'This device syncs with ${svc.client?.hubName ?? 'the office PC'}.',
              'Signed in as ${svc.user?.s('name') ?? '-'} (${svc.role}).',
            ].join('\n')),
            isThreeLine: true,
          ),
        ),
      ]),
    );
  }
}

// ============================================================================ staff

class UsersScreen extends StatelessWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    return Scaffold(
      appBar: AppBar(title: const Text('Staff')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add person'),
      ),
      body: DbBuilder(
        db: svc.db,
        builder: (context) {
          final users = svc.db.select('SELECT * FROM users WHERE deleted=0 ORDER BY active DESC, name COLLATE NOCASE');
          return PageBody(maxWidth: 800, children: [
            const Muted('Owner: everything, including staff and devices. Office: everything else. '
                'Field: customers, jobs, measurements, designs and photos, but no prices.'),
            const SizedBox(height: 12),
            for (final u in users)
              ItemTile(
                title: u.s('name') + (u.id == svc.user?.id ? '  (you)' : ''),
                subtitle: [
                  roles[u.s('role')]?.split(' (').first ?? u.s('role'),
                  if (u.ns('pin_hash') == null) 'no PIN set',
                  if (!u.b('active')) 'inactive',
                ].join(' · '),
                dim: !u.b('active'),
                trailing: const Icon(Icons.edit_outlined, size: 20),
                onTap: () => _edit(context, u),
              ),
          ]);
        },
      ),
    );
  }

  static Future<void> _edit(BuildContext context, Rec? user) =>
      showDialog<void>(context: context, builder: (_) => _UserDialog(user: user));
}

class _UserDialog extends StatefulWidget {
  const _UserDialog({this.user});
  final Rec? user;
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final _name = TextEditingController(text: widget.user?.s('name') ?? '');
  final _pin = TextEditingController();
  late String _role = widget.user?.s('role') ?? 'office';
  late bool _active = widget.user?.b('active') ?? true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  int _otherActiveOwners(AppDb db) => (db.scalar(
      "SELECT COUNT(*) FROM users WHERE deleted=0 AND active=1 AND role='owner' AND id<>?",
      [widget.user?.id ?? '']) as int);

  void _save() {
    final svc = context.svc;
    final db = svc.db;
    final u = widget.user;
    final name = _name.text.trim();
    final pin = _pin.text;
    if (name.isEmpty) return setState(() => _error = 'Name is required');
    if (pin.isNotEmpty && !RegExp(r'^\d{4,6}$').hasMatch(pin)) return setState(() => _error = 'PIN must be 4–6 digits');
    if (u == null && pin.isEmpty) return setState(() => _error = 'Set a PIN (needed to sign in on the PC)');
    if (u != null) {
      final isSelf = u.id == svc.user?.id;
      if (isSelf && !_active) return setState(() => _error = "You can't deactivate yourself");
      final wasOwner = u.s('role') == 'owner' && u.b('active');
      final staysOwner = _role == 'owner' && _active;
      if (wasOwner && !staysOwner && _otherActiveOwners(db) == 0) {
        return setState(() => _error = 'There must be at least one active owner');
      }
      db.update('users', u.id, {
        'name': name,
        'role': _role,
        'active': _active ? 1 : 0,
        if (pin.isNotEmpty) 'pin_hash': hashPin(pin),
      });
      if (isSelf) svc.reloadUser();
    } else {
      createUser(db, name: name, role: _role, pin: pin);
    }
    Navigator.pop(context);
    toast(context, 'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.user != null;
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.user!.s('name')}' : 'Add person'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, autofocus: !editing, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: _role,
              onChanged: (v) => setState(() => _role = v ?? _role),
              child: Column(children: [
                for (final MapEntry(key: k, value: desc) in roles.entries)
                  RadioListTile<String>(
                    value: k,
                    title: Text(desc.split(' (').first),
                    subtitle:
                        Text(desc.contains('(') ? desc.substring(desc.indexOf('(') + 1).replaceAll(')', '') : ''),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: InputDecoration(
                labelText: editing ? 'New PIN (leave empty to keep)' : 'PIN (4–6 digits)',
                helperText: 'Used to sign in on the PC. Phones are paired instead.',
              ),
            ),
            if (editing)
              SwitchListTile(
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Active'),
                subtitle: const Text('Inactive staff cannot sign in or sync'),
                contentPadding: EdgeInsets.zero,
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
