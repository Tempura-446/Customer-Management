import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What this install is:
///  - `hub`:    the main office PC. Holds the master data and files, serves the other devices.
///  - `client`: a workstation, phone or tablet. Keeps a local copy and syncs with the main PC.
///
/// Phones are always clients. A Windows PC asks once on first start.
class DeviceMode {
  static const hub = 'hub';
  static const client = 'client';

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'device_mode.txt'));

  /// Returns null when a desktop has not chosen yet.
  static Future<String?> resolve({required bool desktop}) async {
    switch (Platform.environment['CABINET_CRM_MODE']) {
      case 'phone':
      case 'workstation':
      case 'client':
        return client;
      case 'hub':
        return hub;
    }
    if (!desktop) return client;
    final f = await _file();
    if (await f.exists()) {
      final v = (await f.readAsString()).trim();
      if (v == hub || v == client) return v;
    }
    // Installs from before this choice existed were always the main PC.
    try {
      final base = Platform.environment['CABINET_CRM_DATA'] ??
          p.join((await getApplicationDocumentsDirectory()).path, 'Cabinet CRM');
      if (await File(p.join(base, 'data', 'cabinet_crm.db')).exists()) {
        await save(hub);
        return hub;
      }
    } catch (_) {
      // No Documents folder available: treat as a new install.
    }
    return null;
  }

  static Future<void> save(String mode) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(mode);
  }
}

/// True when [path] is on a network share. The database must never live there:
/// SQLite over SMB/network drives can corrupt when more than one computer uses it.
bool looksLikeNetworkPath(String path) {
  if (path.startsWith(r'\\') || path.startsWith('//')) return true;
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    try {
      final r = Process.runSync('cmd', ['/c', 'net', 'use'], runInShell: false);
      final drive = path.substring(0, 2).toUpperCase();
      return r.stdout.toString().toUpperCase().contains(' $drive ');
    } catch (_) {}
  }
  return false;
}
