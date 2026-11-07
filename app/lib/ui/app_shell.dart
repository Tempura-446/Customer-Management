import 'dart:async';

import 'package:flutter/material.dart';

import '../core/logic.dart';
import '../services.dart';
import '../sync/sync_client.dart';
import 'screens/calendar_screens.dart';
import 'screens/customers_screens.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screens.dart';
import 'screens/mail_screens.dart';
import 'screens/projects_screens.dart';
import 'screens/settings_screens.dart';
import 'screens/sync_screens.dart';
import 'widgets/common.dart';

/// Decides what to show first:
///  PC:    first-run setup -> PIN login -> app
///  Phone: pair with the PC (scan QR) -> app
class AppGate extends StatelessWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = ServicesScope.of(context);
    if (svc.isHub) {
      final hasUsers = svc.db.one('SELECT 1 FROM users WHERE deleted=0') != null;
      if (!hasUsers) return const FirstRunScreen();
      if (svc.user == null) return const LoginScreen();
      return AppShell(key: ValueKey('${svc.user!.id}/${svc.role}'));
    }
    if (!svc.client!.paired || svc.user == null) return const PhonePairScreen();
    return AppShell(key: ValueKey('${svc.user!.id}/${svc.role}'));
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _tab = 0;
  Timer? _timer;
  Timer? _soon;
  Services? _svc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _svc = context.svc;
    // Sync quietly on start, on a timer, when the app comes back to the foreground,
    // and a few seconds after anything is changed here.
    // Workstations sit on the office network, so they check often; phones less so.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
    final every = Services.desktop ? const Duration(seconds: 15) : const Duration(minutes: 1);
    _timer = Timer.periodic(every, (_) => _autoSync());
    _svc!.db.addListener(_onLocalChange);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _svc?.db.removeListener(_onLocalChange);
    _timer?.cancel();
    _soon?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back from 2020 / Explorer: refresh so edited files show "Save changes".
      _svc?.db.changed();
      _autoSync();
    }
  }

  void _onLocalChange() {
    final c = _svc?.client;
    if (c == null || !c.paired || c.syncing) return;
    if (c.pendingChanges() == 0) return; // e.g. the change came from a sync
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 3), _autoSync);
  }

  Future<void> _autoSync() async {
    if (!mounted) return;
    final svc = context.svc;
    final c = svc.client;
    if (c == null || !c.paired || c.syncing) return;
    try {
      await c.sync();
      svc.reloadUser();
    } on SyncException catch (e) {
      // Not on the office network: fine, work offline. Removed on the main PC: back to pairing.
      if (e.unpaired) {
        c.unpair();
        svc.forgetUser();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final svc = ServicesScope.of(context);
    final wide = isWide(context);
    final syncPage = svc.isHub ? const DevicesScreen() : const PhoneSyncScreen();
    final syncLabel = svc.isHub ? 'Devices' : 'Sync';
    // Phones get five short tabs; Sync and Settings live under "More".
    final pages = <(IconData, String, Widget)>[
      (Icons.home_outlined, 'Home', const DashboardScreen()),
      (Icons.work_outline, 'Jobs', const ProjectsScreen()),
      (Icons.calendar_month_outlined, 'Calendar', const CalendarScreen()),
      (Icons.people_outline, 'Customers', const CustomersScreen()),
      if (wide) (svc.isHub ? Icons.devices_other : Icons.sync, syncLabel, syncPage),
      if (wide) (Icons.settings_outlined, 'Settings', const SettingsScreen()),
      if (!wide) (Icons.more_horiz, 'More', _MorePage(syncLabel: syncLabel, syncPage: syncPage)),
    ];
    if (_tab >= pages.length) _tab = 0;
    // Each tab has its own Scaffold; a messenger here stops a toast showing in every tab at once.
    final body = ScaffoldMessenger(child: IndexedStack(index: _tab, children: [for (final p in pages) p.$3]));

    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(children: [
                BusinessLogo(settings: settings(svc.db), height: 36, maxWidth: 72),
                const SizedBox(height: 4),
                SizedBox(
                    width: 72,
                    child: Text(svc.user?.s('name') ?? '',
                        maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11))),
              ]),
            ),
            trailing: svc.isHub
                ? Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: IconButton(
                            tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: svc.signOut),
                      ),
                    ),
                  )
                : null,
            destinations: [
              for (final p in pages) NavigationRailDestination(icon: Icon(p.$1), label: Text(p.$2)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [for (final p in pages) NavigationDestination(icon: Icon(p.$1), label: p.$2)],
      ),
    );
  }
}

/// Phone-only "More" tab: everything that doesn't need its own tab.
class _MorePage extends StatelessWidget {
  const _MorePage({required this.syncLabel, required this.syncPage});
  final String syncLabel;
  final Widget syncPage;

  @override
  Widget build(BuildContext context) {
    final svc = ServicesScope.of(context);
    Widget tile(IconData icon, String title, String subtitle, Widget page) => Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(context, page),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: PageBody(children: [
        Row(children: [
          BusinessLogo(settings: settings(svc.db), height: 40, maxWidth: 120),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(settings(svc.db)['business_name'] ?? '', style: Theme.of(context).textTheme.titleMedium),
              Muted('${svc.user?.s('name') ?? ''} · ${svc.role}'),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        if (svc.prices) tile(Icons.mail_outline, 'Email inbox', 'Measurement emails waiting to be filed', const MailInboxScreen()),
        tile(Icons.sync, syncLabel, svc.isHub ? 'Connected workstations and phones' : 'Sync with the office PC', syncPage),
        tile(Icons.settings_outlined, 'Settings', 'Business details, staff and more', const SettingsScreen()),
        if (svc.isHub)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(onPressed: svc.signOut, icon: const Icon(Icons.logout), label: const Text('Sign out')),
          ),
      ]),
    );
  }
}
