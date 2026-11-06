import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/db.dart';
import 'core/files.dart';
import 'core/logic.dart';
import 'sync/discovery.dart';
import 'sync/hub_server.dart';
import 'sync/sync_client.dart';

/// Everything the screens need, created once at start-up.
///
/// Desktop (Windows/macOS/Linux) = HUB: owns the master data and runs the
/// Wi-Fi sync service. Phones/tablets = CLIENT: local copy + sync.
class Services extends ChangeNotifier {
  Services._(this.db, this.files, {this.hub, this.client, this.advertiser});

  final AppDb db;
  final FileStore files;
  final HubServer? hub;
  final SyncClient? client;
  final HubAdvertiser? advertiser;

  bool get isHub => db.isHub;
  Rec? user;
  String get role => user?.s('role') ?? 'field';
  bool get prices => canSeePrices(role);
  bool get isOwner => canManageUsers(role);

  static bool get desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<Services> start({bool? asHub, String? dataDir}) async {
    // CABINET_CRM_MODE=phone lets a PC run the phone version (for testing).
    final hubMode = asHub ?? (Platform.environment['CABINET_CRM_MODE'] == 'phone' ? false : desktop);
    final root = dataDir ?? Platform.environment['CABINET_CRM_DATA'] ??
        (hubMode
            ? p.join((await getApplicationDocumentsDirectory()).path, 'Cabinet CRM')
            : (await getApplicationSupportDirectory()).path);
    final db = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: hubMode);
    final files = FileStore(db, root);
    if (hubMode) {
      seedSettings(db);
      final hub = HubServer(db, files, hubName: db.meta('hub_name') ?? Platform.localHostname);
      final s = Services._(db, files, hub: hub, advertiser: HubAdvertiser());
      await s.startHub();
      return s;
    }
    final client = SyncClient(db, files, discovery: discoverHub);
    final s = Services._(db, files, client: client);
    final uid = client.userId;
    if (uid != null) s.signIn(uid);
    return s;
  }

  String? hubError;

  Future<void> startHub() async {
    final h = hub;
    if (h == null) return;
    try {
      await h.start(port: int.tryParse(db.meta('sync_port') ?? '') ?? defaultSyncPort);
      await advertiser?.start(h.hubId, h.hubName, h.port!);
      hubError = null;
    } catch (e) {
      hubError = 'Wi-Fi sync is not running: $e';
    }
    notifyListeners();
  }

  /// Desktop: after PIN check. Phone: the paired user.
  void signIn(String userId) {
    user = db.get('users', userId);
    db.currentUserId = userId;
    notifyListeners();
  }

  void signOut() {
    if (!isHub) return;
    user = null;
    db.currentUserId = null;
    notifyListeners();
  }

  /// Phone: after unpairing, return to the pairing screen.
  void forgetUser() {
    user = null;
    db.currentUserId = null;
    notifyListeners();
  }

  /// Refresh the signed-in user after a sync (role may have changed).
  void reloadUser() {
    if (user != null) {
      user = db.get('users', user!.id) ?? user;
      notifyListeners();
    }
  }
}

class ServicesScope extends InheritedNotifier<Services> {
  const ServicesScope({super.key, required Services services, required super.child}) : super(notifier: services);

  static Services of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServicesScope>()!.notifier!;
}

extension ServicesX on BuildContext {
  /// Look up services without subscribing to changes (safe in initState).
  /// Data refreshes come from DbBuilder; sign-in changes rebuild AppGate/AppShell,
  /// which use ServicesScope.of(context).
  Services get svc => getInheritedWidgetOfExactType<ServicesScope>()!.notifier!;
  AppDb get db => svc.db;
}
