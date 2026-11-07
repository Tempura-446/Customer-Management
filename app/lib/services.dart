import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/db.dart';
import 'core/device_mode.dart';
import 'core/files.dart';
import 'core/logic.dart';
import 'backup/backup_service.dart';
import 'mail/mail_poller.dart';
import 'notify/reminder_service.dart';
import 'pdf/zpdf.dart';
import 'qb/qb_sync.dart';
import 'qb/qbwc_server.dart';
import 'sync/discovery.dart';
import 'sync/hub_server.dart';
import 'sync/sync_client.dart';

/// Everything the screens need, created once at start-up.
///
/// HUB = the main office PC: owns the master data and runs the sync service.
/// CLIENT = other office workstations, phones and tablets: local copy + sync
/// with the hub over the office network. See DeviceMode.
class Services extends ChangeNotifier {
  Services._(this.db, this.files, {this.hub, this.client, this.advertiser, this.mail, this.backup});

  final AppDb db;
  final FileStore files;
  final HubServer? hub;
  final SyncClient? client;
  final HubAdvertiser? advertiser;

  /// Main office PC only: reads the shared measurement mailbox.
  final MailPoller? mail;

  /// Main office PC only: daily backups.
  final BackupService? backup;

  bool get isHub => db.isHub;
  Rec? user;
  String get role => user?.s('role') ?? 'field';
  bool get prices => canSeePrices(role);
  bool get isOwner => canManageUsers(role);

  static bool get desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// True for an office workstation (a desktop that connects to the main PC).
  bool get isWorkstation => !isHub && desktop;

  /// Appointment reminders and the morning summary as system notifications.
  late final ReminderService reminders = ReminderService(this);

  /// Main office PC only: QuickBooks Web Connector service.
  QbwcService? qbwc;

  /// ZPDF (PDF-Manager) if installed on this computer: sharper job packets, annotate/sign PDFs.
  ZPdf? zpdf;

  /// Look for ZPDF again (after installing it, or changing the path in Settings).
  void detectZpdf() {
    zpdf = desktop ? ZPdf.detect(override: db.meta('zpdf_path')) : null;
    notifyListeners();
  }

  /// Set when the data folder is on a network drive (see [looksLikeNetworkPath]).
  String? storageWarning;

  static Future<Services> start({required bool asHub, String? dataDir}) async {
    final hubMode = asHub;
    final root = dataDir ?? Platform.environment['CABINET_CRM_DATA'] ??
        (hubMode
            ? p.join((await getApplicationDocumentsDirectory()).path, 'Cabinet CRM')
            : (await getApplicationSupportDirectory()).path);
    if (hubMode) BackupService.applyPendingRestore(root);
    final db = AppDb.open(p.join(root, 'data', 'cabinet_crm.db'), isHub: hubMode);
    final files = FileStore(db, root);
    final warning = looksLikeNetworkPath(root)
        ? 'The data folder ($root) is on a network drive. Keep the database on this PC\'s own disk: '
            'a database file shared over the network can get corrupted. Other computers should connect '
            'as workstations instead (Devices → Add a phone or computer).'
        : null;
    if (hubMode) {
      seedSettings(db);
      migrateStages(db);
      migrateSettingIds(db);
      final hub = HubServer(db, files, hubName: db.meta('hub_name') ?? Platform.localHostname);
      final qbwc = QbwcService(db, QbSync(db));
      hub.qbwc = qbwc;
      final s = Services._(db, files, hub: hub, advertiser: HubAdvertiser(), mail: MailPoller(db, files), backup: BackupService(db, files))
        ..storageWarning = warning
        ..qbwc = qbwc;
      await s.startHub();
      s.mail!.start();
      s.backup!.start();
      s.detectZpdf();
      s.reminders.start();
      return s;
    }
    final client = SyncClient(db, files, discovery: discoverHub);
    final s = Services._(db, files, client: client)..storageWarning = warning;
    s.detectZpdf();
    final uid = client.userId;
    if (uid != null && !client.shared) s.signIn(uid);
    s.reminders.start();
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
      hubError = 'Network sync is not running: $e';
    }
    notifyListeners();
  }

  /// Desktop: after PIN check. Phone: the paired user.
  void signIn(String userId) {
    user = db.get('users', userId);
    db.currentUserId = userId;
    notifyListeners();
  }

  /// An office computer anyone signs in to with their PIN (see SyncClient.shared).
  bool get sharedWorkstation => client?.shared ?? false;

  /// Main PC or a shared office computer: people sign in and out with their PIN.
  bool get signsIn => isHub || sharedWorkstation;

  void signOut() {
    if (!signsIn) return;
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
