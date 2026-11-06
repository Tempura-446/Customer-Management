import 'package:flutter/material.dart';

import 'services.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await Services.start();
  runApp(CrmApp(services: services));
}

class CrmApp extends StatelessWidget {
  const CrmApp({super.key, required this.services});
  final Services services;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6FDE);
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
          useMaterial3: true,
          visualDensity: VisualDensity.standard,
          inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
          cardTheme: const CardThemeData(margin: EdgeInsets.zero),
        );
    return ServicesScope(
      services: services,
      child: MaterialApp(
        title: 'Cabinet CRM',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const AppGate(),
      ),
    );
  }
}
