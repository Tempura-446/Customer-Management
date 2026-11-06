import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../backup/backup_service.dart';
import '../widgets/common.dart';

/// Settings › Backups (main office PC).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.backup});
  final BackupService backup;
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  BackupService get b => widget.backup;
  late final _keep = TextEditingController(text: '${b.keep}');

  @override
  void dispose() {
    _keep.dispose();
    super.dispose();
  }

  Future<void> _chooseDir() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: 'Choose the backup folder (external drive, NAS…)');
    if (d == null) return;
    b.configure(enabled: true, dir: d, keep: int.tryParse(_keep.text));
  }

  Future<void> _backupNow() async {
    await attempt(context, () async {
      final msg = await b.runBackup();
      if (mounted) toast(context, msg);
    });
  }

  Future<void> _restore(File snap) async {
    final ok = await confirm(
      context,
      'Restore the database from ${p.basename(snap.path)}?\n\n'
      'Everything entered after this backup is replaced by the backup. Your current database is kept as a '
      '"before-restore" copy in the data folder, so this can be undone.\n\n'
      'Phones and workstations will receive the restored data at their next sync.',
      ok: 'Restore',
      danger: true,
    );
    if (!ok || !mounted) return;
    final done = await attempt(context, () => b.scheduleRestore(snap.path));
    if (!done || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => const AlertDialog(
        title: Text('Restart needed'),
        content: Text('Close Cabinet CRM and open it again to finish the restore.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Backups')),
        body: ListenableBuilder(
          listenable: b,
          builder: (context, _) {
            final snaps = b.snapshots();
            return PageBody(maxWidth: 820, children: [
              const Text('Everything lives on this main office PC: the database and the job folders. '
                  'Cabinet CRM copies them to a backup folder once a day while it is open.'),
              const SizedBox(height: 8),
              if (b.restorePending)
                const WarnBanner('A restore is waiting. Close and reopen Cabinet CRM to finish it.'),
              if (b.lastError != null) WarnBanner('Last backup failed: ${b.lastError}'),
              Section(
                title: 'Settings',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: b.enabled,
                    onChanged: (v) => b.configure(enabled: v, keep: int.tryParse(_keep.text)),
                    title: const Text('Back up automatically every day'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(b.dir ?? 'No backup folder chosen'),
                    subtitle: const Text('Best: an external USB drive or a NAS. A network folder is fine for backups.'),
                    trailing: OutlinedButton(onPressed: _chooseDir, child: const Text('Choose…')),
                  ),
                  Row(children: [
                    SizedBox(
                      width: 200,
                      child: TextField(
                        controller: _keep,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Keep this many daily copies'),
                        onSubmitted: (v) => b.configure(enabled: b.enabled, keep: int.tryParse(v)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                        onPressed: () => b.configure(enabled: b.enabled, keep: int.tryParse(_keep.text)),
                        child: const Text('Save')),
                  ]),
                ]),
              ),
              Section(
                title: 'Status',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  KeyValues([
                    ('Last backup', b.last == null ? 'never' : fmtDateTime(b.last!.toIso8601String())),
                    ('Result', b.lastSummary ?? '-'),
                  ]),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: b.running || b.dir == null ? null : _backupNow,
                    icon: b.running
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.backup_outlined),
                    label: Text(b.running ? 'Backing up…' : 'Back up now'),
                  ),
                ]),
              ),
              Section(
                title: 'Restore',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (snaps.isEmpty) const Muted('No backups in the chosen folder yet.'),
                  for (final s in snaps)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.storage_outlined),
                      title: Text(p.basename(s.path)),
                      subtitle: Text('${(s.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB · '
                          '${fmtDateTime(s.lastModifiedSync().toIso8601String())}'),
                      trailing: TextButton(onPressed: () => _restore(s), child: const Text('Restore this…')),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: b.dir == null
                          ? null
                          : () => attempt(context, () async {
                                final n = await b.restoreMissingFiles();
                                if (context.mounted) toast(context, '$n missing file(s) restored');
                              }),
                      icon: const Icon(Icons.restore_page_outlined),
                      label: const Text('Restore missing files from backup'),
                    ),
                  ),
                ]),
              ),
              const Muted('Tip: keep the backup on a different disk from this PC (or take the USB drive home now and '
                  'then), so one failure or theft cannot take both.', size: 12),
            ]);
          },
        ),
      );
}

/// Dashboard warning when backups are not set up, failing, or overdue. Shows nothing otherwise.
class BackupStatusBanner extends StatelessWidget {
  const BackupStatusBanner({super.key, required this.backup});
  final BackupService? backup;

  @override
  Widget build(BuildContext context) {
    final b = backup;
    if (b == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) {
        final String? msg;
        if (!b.enabled || b.dir == null) {
          msg = 'Backups are not set up. All data is on this PC only.';
        } else if (b.lastError != null) {
          msg = 'The last backup failed: ${b.lastError}';
        } else if (b.overdue) {
          msg = b.last == null
              ? 'No backup has been made yet.'
              : 'Last backup was ${DateTime.now().difference(b.last!).inDays} days ago (is the backup drive connected?).';
        } else {
          msg = null;
        }
        if (msg == null) return const SizedBox.shrink();
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: WarnBanner(msg)),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: () => push(context, BackupScreen(backup: b)),
              child: Text(!b.enabled || b.dir == null ? 'Set up backups' : 'Open backups'),
            ),
          ),
        ]);
      },
    );
  }
}
