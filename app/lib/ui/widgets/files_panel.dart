import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/db.dart';
import '../../core/files.dart';
import '../../services.dart';
import 'common.dart';

/// Open a stored file with the device's default app (2020 for .kit on the PC).
Future<void> openStoredFile(BuildContext context, Rec f) async {
  final svc = context.svc;
  await attempt(context, () async {
    var path = svc.files.localPath(f.s('sha256'));
    if (path == null) {
      if (svc.client == null) throw Exception('File is missing from this PC.');
      if (context.mounted) toast(context, 'Downloading ${f.s('name')} from the office PC…');
      path = await svc.client!.fetchBlob(f.s('sha256'));
    }
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) throw Exception(r.message);
  });
}

/// Open the project's folder in Explorer / Finder (PC only).
Future<void> openFolder(String path) async {
  Directory(path).createSync(recursive: true);
  if (Platform.isWindows) {
    await Process.run('explorer', [path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

/// List + add files attached to a project or to one record in it.
class FilesPanel extends StatelessWidget {
  const FilesPanel({
    super.key,
    required this.projectId,
    this.entityType,
    this.entityId,
    required this.category,
    this.title = 'Files',
    this.allowCategoryChoice = false,
  });

  final String projectId;
  final String? entityType, entityId;
  final String category;
  final String title;
  final bool allowCategoryChoice;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    return DbBuilder(
      db: svc.db,
      builder: (context) {
        final list = entityType == null
            ? svc.files.projectFiles(projectId, prices: svc.prices)
            : svc.files.filesFor(entityType!, entityId!);
        return Section(
          title: title,
          action: Wrap(spacing: 4, children: [
            if (!Services.desktop)
              IconButton(
                  tooltip: 'Take photo',
                  icon: const Icon(Icons.photo_camera_outlined),
                  onPressed: () => _camera(context, ImageSource.camera)),
            if (!Services.desktop)
              IconButton(
                  tooltip: 'From photos',
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: () => _camera(context, ImageSource.gallery)),
            IconButton(tooltip: 'Attach file', icon: const Icon(Icons.attach_file), onPressed: () => _pick(context)),
            if (svc.isHub)
              IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.folder_open_outlined),
                  onPressed: () => openFolder(svc.files.projectFolder(projectId))),
          ]),
          child: list.isEmpty
              ? const Muted('No files yet.')
              : Column(children: [
                  for (final f in list) _FileRow(f: f, showCategory: entityType == null),
                ]),
        );
      },
    );
  }

  Future<String?> _chooseCategory(BuildContext context) async {
    if (!allowCategoryChoice) return category;
    return showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('File type'),
        children: [
          for (final cat in const ['photos', 'measurements', 'designs', 'quotes', 'invoices', 'other'])
            if (context.svc.prices || (cat != 'quotes' && cat != 'invoices'))
              SimpleDialogOption(onPressed: () => Navigator.pop(c, cat), child: Text(cat)),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final svc = context.svc;
    final picked = await FilePicker.pickFiles(dialogTitle: 'Attach files');
    if (picked.isEmpty || !context.mounted) return;
    final cat = await _chooseCategory(context);
    if (cat == null || !context.mounted) return;
    await attempt(context, () async {
      for (final f in picked) {
        if (f.path == null) continue;
        svc.files.addFile(
            projectId: projectId, sourcePath: f.path!, name: f.name, category: cat,
            entityType: entityType, entityId: entityId);
      }
    }, success: '${picked.length} file(s) added');
  }

  Future<void> _camera(BuildContext context, ImageSource source) async {
    final svc = context.svc;
    final picker = ImagePicker();
    final shots = source == ImageSource.camera
        ? [?await picker.pickImage(source: source, imageQuality: 85, maxWidth: 2400)]
        : await picker.pickMultiImage(imageQuality: 85, maxWidth: 2400);
    if (shots.isEmpty || !context.mounted) return;
    final cat = entityType == null ? 'photos' : category;
    await attempt(context, () async {
      for (final x in shots) {
        svc.files.addBytes(
            projectId: projectId, bytes: await x.readAsBytes(), name: x.name, category: cat,
            entityType: entityType, entityId: entityId);
      }
    }, success: '${shots.length} photo(s) added');
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.f, required this.showCategory});
  final Rec f;
  final bool showCategory;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final local = svc.files.localPath(f.s('sha256'));
    final kb = (f.i('size') / 1024).ceil();
    final isImg = FileStore.isImage(f.s('name'));
    final edited = local != null && svc.files.locallyModified(f.s('sha256'));
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: isImg && local != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(File(local), width: 40, height: 40, fit: BoxFit.cover, cacheWidth: 120))
          : Icon(_icon(f.s('name')), size: 28),
      title: Text(f.s('name'), overflow: TextOverflow.ellipsis),
      subtitle: edited
          ? Text('Edited on this computer, not saved to the job yet',
              style: TextStyle(color: Theme.of(context).colorScheme.error))
          : Text([
              if (showCategory) f.s('category'),
              '$kb KB',
              fmtDate(f.s('created_at')),
              if (local == null) 'on the main PC: tap to download',
            ].join(' · ')),
      onTap: () => openStoredFile(context, f),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (edited)
          FilledButton.tonal(
            onPressed: () => attempt(context, () async {
              svc.files.saveLocalChanges(f.id);
            }, success: svc.isHub ? 'Saved' : 'Saved: it goes to the main PC at the next sync'),
            child: const Text('Save changes'),
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () async {
            if (await confirm(context, 'Remove ${f.s('name')}?', ok: 'Remove', danger: true)) {
              svc.files.deleteFile(f.id);
            }
          },
        ),
      ]),
    );
  }

  static IconData _icon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.kit')) return Icons.architecture;
    if (FileStore.isImage(n)) return Icons.image_outlined;
    return Icons.insert_drive_file_outlined;
  }
}
