import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../services.dart';
import '../../sync/hub_server.dart';
import '../../sync/sync_client.dart';
import '../widgets/common.dart';

// ============================================================================ PC: devices & pairing

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<String> _addresses = const [];

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    try {
      final a = await localAddresses();
      if (mounted) setState(() => _addresses = a);
    } catch (_) {}
  }

  Future<void> _pair() async {
    final svc = context.svc;
    final users = activeUsers(svc.db);
    final user = await showDialog<Rec>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Whose phone is this?'),
        children: [
          for (final u in users)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, u),
              child: ListTile(
                leading: CircleAvatar(child: Text(u.s('name').isEmpty ? '?' : u.s('name')[0].toUpperCase())),
                title: Text(u.s('name')),
                subtitle: Text(roles[u.s('role')]?.split(' (').first ?? u.s('role')),
              ),
            ),
        ],
      ),
    );
    if (user == null || !mounted) return;
    await _loadAddresses();
    if (!mounted) return;
    final code = svc.hub!.createPairingCode(user.id);
    final payload = jsonEncode(svc.hub!.pairingPayload(code, _addresses));
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Pair a phone for ${user.s('name')}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('On the phone: open Cabinet CRM → "Scan QR code on the PC".'),
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(data: payload, size: 260, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 12),
            const Muted('No camera? Enter these on the phone instead:'),
            KeyValues([
              ('PC address', _addresses.isEmpty ? '(not connected to a network)' : _addresses.join(', ')),
              ('Port', '${svc.hub!.port ?? defaultSyncPort}'),
              ('Pairing code', HubServer.displayCode(code)),
            ]),
            const SizedBox(height: 8),
            const Muted('The code works once and expires in 15 minutes.', size: 12),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final hub = svc.hub;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices & Wi-Fi sync')),
      body: DbBuilder(
        db: svc.db,
        builder: (context) {
          final devices = hub?.devices() ?? const <Rec>[];
          return PageBody(maxWidth: 900, children: [
            Section(
              title: 'Sync service',
              action: hub != null && hub.running
                  ? const StatusChip('accepted', label: 'running')
                  : const StatusChip('void', label: 'stopped'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (svc.hubError != null) ...[
                  WarnBanner(svc.hubError!),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                        onPressed: () => svc.startHub(), icon: const Icon(Icons.refresh), label: const Text('Retry')),
                  ),
                  const SizedBox(height: 8),
                ],
                KeyValues([
                  ('PC name', hub?.hubName ?? '-'),
                  ('Address', _addresses.isEmpty ? '(no network)' : _addresses.join(', ')),
                  ('Port', '${hub?.port ?? '-'}'),
                ]),
                const SizedBox(height: 8),
                const Muted(
                    'Phones sync when they are on the same Wi-Fi as this PC and this app is open. '
                    'The installer allows Cabinet CRM through Windows Firewall on private networks. '
                    'If phones can\'t connect, check the PC\'s Wi-Fi is set to "Private" in Windows network settings.',
                    size: 12),
              ]),
            ),
            Section(
              title: 'Paired phones & tablets',
              action: svc.isOwner && hub != null
                  ? FilledButton.icon(
                      onPressed: hub.running ? _pair : null,
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Pair a phone'))
                  : null,
              child: devices.isEmpty
                  ? Muted(svc.isOwner
                      ? 'No phones yet. Click "Pair a phone" and scan the code with the Cabinet CRM phone app.'
                      : 'No phones paired. The owner can pair phones here.')
                  : Column(children: [
                      for (final d in devices)
                        ItemTile(
                          dim: d.b('revoked'),
                          title: d.s('name'),
                          subtitle: [
                            '${d.s('user_name')} (${d.s('role')})',
                            d.ns('last_sync') == null ? 'never synced' : 'last sync ${fmtDateTime(d.s('last_sync'))}',
                            if (d.b('revoked')) 'removed',
                          ].join(' · '),
                          trailing: svc.isOwner && !d.b('revoked')
                              ? IconButton(
                                  tooltip: 'Remove device',
                                  icon: const Icon(Icons.phonelink_erase),
                                  onPressed: () async {
                                    if (await confirm(context,
                                        'Remove "${d.s('name')}"? It will stop syncing immediately (use this if a phone is lost).',
                                        ok: 'Remove', danger: true)) {
                                      hub!.revokeDevice(d.id);
                                    }
                                  },
                                )
                              : null,
                        ),
                    ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ============================================================================ phone: sync status

class PhoneSyncScreen extends StatelessWidget {
  const PhoneSyncScreen({super.key});

  Future<void> _syncNow(BuildContext context) async {
    final svc = context.svc;
    try {
      final r = await svc.client!.sync();
      svc.reloadUser();
      if (context.mounted) {
        toast(context, 'Synced: ${r.pushed} sent, ${r.pulled} received, ${r.uploaded} file(s) uploaded');
      }
    } on SyncException catch (e) {
      if (!context.mounted) return;
      toast(context, e.message, error: true);
      if (e.unpaired) {
        svc.client!.unpair();
        svc.forgetUser();
      }
    }
  }

  Future<void> _unpair(BuildContext context) async {
    final svc = context.svc;
    final pending = svc.client!.pendingChanges();
    final msg = pending > 0
        ? 'This phone has $pending change(s) not yet synced to the PC. They will be lost if you unpair now. Unpair anyway?'
        : 'Unpair this phone from ${svc.client!.hubName ?? 'the office PC'}? You can pair it again any time.';
    if (await confirm(context, msg, ok: 'Unpair', danger: true)) {
      svc.client!.unpair();
      svc.forgetUser();
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final c = svc.client!;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListenableBuilder(
        listenable: Listenable.merge([c, svc.db]),
        builder: (context, _) {
          final pending = c.pendingChanges();
          return PageBody(maxWidth: 600, children: [
            Section(
              title: 'Office PC',
              child: KeyValues([
                ('Synced with', c.hubName ?? '-'),
                ('Signed in as', '${svc.user?.s('name') ?? '-'} (${svc.role})'),
                ('Last sync', c.lastSync == null ? 'never' : fmtDateTime(c.lastSync)),
                ('Not yet synced', pending == 0 ? 'nothing, all up to date' : '$pending change(s)'),
              ]),
            ),
            if (c.lastError != null) WarnBanner(c.lastError!),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: c.syncing ? null : () => _syncNow(context),
                icon: c.syncing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: Text(c.syncing ? 'Syncing…' : 'Sync now', style: const TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 12),
            const Muted(
                'Work offline on site as usual. Everything syncs automatically when you are back on the shop '
                'Wi-Fi with the PC app open (on start, every 5 minutes and when you reopen the app).',
                size: 12),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _unpair(context),
              icon: const Icon(Icons.link_off),
              label: const Text('Unpair this phone'),
            ),
          ]);
        },
      ),
    );
  }
}

// ============================================================================ phone: pairing

class PhonePairScreen extends StatefulWidget {
  const PhonePairScreen({super.key});
  @override
  State<PhonePairScreen> createState() => _PhonePairScreenState();
}

class _PhonePairScreenState extends State<PhonePairScreen> {
  final _deviceName = TextEditingController(text: _defaultName());
  bool _busy = false;
  String? _status;

  static String _defaultName() => Platform.isIOS ? 'iPhone' : (Platform.isAndroid ? 'Android phone' : 'Phone');

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanScreen()));
    if (raw == null || !mounted) return;
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      toast(context, 'That QR code is not from the Cabinet CRM PC app.', error: true);
      return;
    }
    await _pair(payload);
  }

  Future<void> _manual() async {
    final r = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _ManualPairDialog());
    if (r != null && mounted) await _pair(r);
  }

  Future<void> _pair(Map<String, dynamic> payload) async {
    final svc = context.svc;
    final c = svc.client!;
    setState(() {
      _busy = true;
      _status = 'Connecting to the office PC…';
    });
    try {
      final name = _deviceName.text.trim().isEmpty ? _defaultName() : _deviceName.text.trim();
      await c.pair(payload, deviceName: name);
      if (mounted) setState(() => _status = 'Paired. Downloading customers and jobs…');
      try {
        await c.sync();
      } on SyncException catch (e) {
        if (mounted) toast(context, 'Paired, but first sync failed: ${e.message}', error: true);
      }
      svc.signIn(c.userId!);
    } on SyncException catch (e) {
      if (mounted) {
        toast(context, e.message, error: true);
        setState(() => _status = null);
      }
    } catch (e) {
      if (mounted) {
        toast(context, 'Pairing failed: $e', error: true);
        setState(() => _status = null);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.kitchen, size: 56),
                const SizedBox(height: 8),
                Text('Connect to your office PC',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Muted('1. On the PC open Cabinet CRM → Devices → "Pair a phone" and pick your name.\n'
                    '2. Make sure this phone is on the same Wi-Fi as the PC.\n'
                    '3. Scan the QR code shown on the PC.'),
                const SizedBox(height: 20),
                TextField(
                  controller: _deviceName,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Name for this device', helperText: 'e.g. "Mike\'s iPhone"'),
                ),
                const SizedBox(height: 20),
                if (_busy) ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 12),
                  Center(child: Text(_status ?? '')),
                ] else ...[
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                        onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan QR code on the PC')),
                  ),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _manual, child: const Text('Enter address and code instead')),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan the code on the PC')),
        body: MobileScanner(
          onDetect: (capture) {
            if (_done) return;
            for (final b in capture.barcodes) {
              final v = b.rawValue;
              if (v != null && v.contains('cabinetcrm')) {
                _done = true;
                Navigator.of(context).pop(v);
                return;
              }
            }
          },
        ),
      );
}

/// Fallback without camera: ask the PC who it is, then pair with the code.
class _ManualPairDialog extends StatefulWidget {
  const _ManualPairDialog();
  @override
  State<_ManualPairDialog> createState() => _ManualPairDialogState();
}

class _ManualPairDialogState extends State<_ManualPairDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '$defaultSyncPort');
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? defaultSyncPort;
    final code = _code.text.trim();
    if (host.isEmpty || code.isEmpty) return setState(() => _error = 'Enter the PC address and pairing code');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await http.get(Uri.parse('http://$host:$port/api/hello')).timeout(const Duration(seconds: 5));
      final hello = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || hello['app'] != 'cabinetcrm') throw const FormatException();
      if (!mounted) return;
      Navigator.pop(context, <String, dynamic>{
        'app': 'cabinetcrm',
        'v': hello['v'],
        'hub': hello['hub'],
        'name': hello['name'],
        'hosts': [host],
        'port': port,
        'code': code,
      });
    } on TimeoutException {
      setState(() => _error = 'No answer from $host:$port. Same Wi-Fi? PC app open?');
    } catch (_) {
      setState(() => _error = "Couldn't reach Cabinet CRM at $host:$port");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pair manually'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Muted('Shown on the PC under Devices → Pair a phone.'),
          const SizedBox(height: 12),
          TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'PC address', hintText: '192.168.1.20')),
          const SizedBox(height: 8),
          TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
          const SizedBox(height: 8),
          TextField(controller: _code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Pairing code', hintText: 'ABCD-EFGH')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'Checking…' : 'Pair')),
        ],
      );
}
