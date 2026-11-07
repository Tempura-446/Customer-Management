import 'package:flutter/material.dart';

import 'core/device_mode.dart';
import 'services.dart';
import 'ui/app_shell.dart';
import 'ui/widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = await DeviceMode.resolve(desktop: Services.desktop);
  if (mode == null) {
    // First start on a computer: main office PC or workstation?
    runApp(_ChooseModeApp(onChosen: (m) async {
      await DeviceMode.save(m);
      await _launch(m);
    }));
    return;
  }
  await _launch(mode);
}

Future<void> _launch(String mode) async {
  final services = await Services.start(asHub: mode == DeviceMode.hub);
  runApp(CrmApp(services: services));
}

ThemeData appTheme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FDE), brightness: b),
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      inputDecorationTheme: InputDecorationTheme(border: const OutlineInputBorder(), isDense: Services.desktop),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    );

class CrmApp extends StatelessWidget {
  const CrmApp({super.key, required this.services});
  final Services services;

  @override
  Widget build(BuildContext context) => ServicesScope(
        services: services,
        child: MaterialApp(
          title: 'Cabinet CRM',
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          home: const AppGate(),
        ),
      );
}

class _ChooseModeApp extends StatefulWidget {
  const _ChooseModeApp({required this.onChosen});
  final Future<void> Function(String mode) onChosen;
  @override
  State<_ChooseModeApp> createState() => _ChooseModeAppState();
}

class _ChooseModeAppState extends State<_ChooseModeApp> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cabinet CRM',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const AppIcon(size: 80),
                    const SizedBox(height: 8),
                    Text('Welcome to Cabinet CRM',
                        textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    const Text('How will this computer be used?', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    if (_busy)
                      const Center(child: CircularProgressIndicator())
                    else
                      Wrap(spacing: 16, runSpacing: 16, alignment: WrapAlignment.center, children: [
                        _Choice(
                          icon: Icons.dns_outlined,
                          title: 'Main office PC',
                          text: 'Stores the master copy of all customers, jobs and files. Other computers and phones '
                              'connect to it.\n\nChoose this on ONE computer only, ideally one that stays on during '
                              'work hours.',
                          onTap: () => _pick(DeviceMode.hub),
                        ),
                        _Choice(
                          icon: Icons.desktop_windows_outlined,
                          title: 'Workstation',
                          text: 'Connects to the main office PC over the office network. Everyone sees the same '
                              'jobs; changes sync within seconds.\n\nKeeps working if the network drops and '
                              'catches up when it is back.',
                          onTap: () => _pick(DeviceMode.client),
                        ),
                      ]),
                    const SizedBox(height: 16),
                    const Text('You can change this later under Settings › This computer.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> _pick(String mode) async {
    setState(() => _busy = true);
    await widget.onChosen(mode);
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.icon, required this.title, required this.text, required this.onTap});
  final IconData icon;
  final String title, text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 330,
        child: Card(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(text),
              ]),
            ),
          ),
        ),
      );
}
