import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';

bool _validPin(String p) => RegExp(r'^\d{4,6}$').hasMatch(p);

/// PC first start: business + owner account.
class FirstRunScreen extends StatefulWidget {
  const FirstRunScreen({super.key});
  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends State<FirstRunScreen> {
  final _form = GlobalKey<FormState>();
  final _business = TextEditingController();
  final _owner = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  final _pcName = TextEditingController(text: _defaultPcName());

  static String _defaultPcName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'Office PC';
    }
  }

  @override
  void dispose() {
    for (final c in [_business, _owner, _pin, _pin2, _pcName]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final svc = context.svc;
    final db = svc.db;
    late String uid;
    db.tx(() {
      uid = createUser(db, name: _owner.text.trim(), role: 'owner', pin: _pin.text);
      db.currentUserId = uid;
      setSetting(db, 'business_name', _business.text.trim());
    });
    final pcName = _pcName.text.trim().isEmpty ? 'Office PC' : _pcName.text.trim();
    db.setMeta('hub_name', pcName);
    svc.hub?.hubName = pcName;
    svc.signIn(uid);
  }

  @override
  Widget build(BuildContext context) {
    final pinFmt = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)];
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _form,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Icon(Icons.kitchen, size: 48),
                    const SizedBox(height: 8),
                    Text('Welcome to Cabinet CRM',
                        textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    const Muted('This PC will hold the master copy of your customers, jobs and files. '
                        'Phones sync with it over your shop Wi-Fi.'),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _business,
                      decoration: const InputDecoration(labelText: 'Business name'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _owner,
                      decoration: const InputDecoration(labelText: 'Your name (owner)'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _pin,
                      decoration: const InputDecoration(labelText: 'PIN (4–6 digits)'),
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      inputFormatters: pinFmt,
                      validator: (v) => _validPin(v ?? '') ? null : 'Use 4 to 6 digits',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _pin2,
                      decoration: const InputDecoration(labelText: 'Confirm PIN'),
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      inputFormatters: pinFmt,
                      validator: (v) => v == _pin.text ? null : 'PINs do not match',
                      onFieldSubmitted: (_) => _save(),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _pcName,
                      decoration: const InputDecoration(
                          labelText: 'Name of this PC', helperText: 'Shown on phones, e.g. "Shop PC"'),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(onPressed: _save, child: const Text('Get started')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// PC: pick your name, enter PIN.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  Rec? _selected;
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    final u = _selected;
    if (u == null) return;
    if (checkPin(_pin.text, u.ns('pin_hash'))) {
      context.svc.signIn(u.id);
    } else {
      setState(() {
        _error = 'Wrong PIN';
        _pin.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final users = activeUsers(svc.db);
    final business = settings(svc.db)['business_name'] ?? '';
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.kitchen, size: 48),
              const SizedBox(height: 8),
              Text(business, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              const Center(child: Muted('Who is using the PC?')),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final u in users)
                    _UserTile(
                      user: u,
                      selected: _selected?.id == u.id,
                      onTap: () => setState(() {
                        _selected = u;
                        _error = null;
                        _pin.clear();
                      }),
                    ),
                ],
              ),
              if (_selected != null) ...[
                const SizedBox(height: 24),
                Center(
                  child: SizedBox(
                    width: 240,
                    child: TextField(
                      controller: _pin,
                      autofocus: true,
                      obscureText: true,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, letterSpacing: 8),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      decoration: InputDecoration(labelText: 'PIN for ${_selected!.s('name')}', errorText: _error),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(child: FilledButton(onPressed: _submit, child: const Text('Sign in'))),
              ],
              const SizedBox(height: 24),
              const Center(
                child: Muted('Forgot your PIN? The owner can reset it in Settings › Staff.', size: 12),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.selected, required this.onTap});
  final Rec user;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = user.s('name');
    return SizedBox(
      width: 140,
      child: Card(
        color: selected ? cs.primaryContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              CircleAvatar(radius: 26, child: Text(name.isEmpty ? '?' : name[0].toUpperCase())),
              const SizedBox(height: 8),
              Text(name, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
              Muted(user.s('role'), size: 11),
            ]),
          ),
        ),
      ),
    );
  }
}
