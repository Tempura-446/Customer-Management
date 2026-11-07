/// Optional helper: ZPDF (the PDF-Manager toolkit, `pdfm`) for stronger PDF work.
///
/// When it is installed on a computer, Casework uses it to merge the original
/// drawing and measurement PDFs into job packets (crisp vector pages instead of
/// pictures), add bookmarks and page numbers across the whole packet, and to
/// open PDFs in ZPDF's reader for annotating and signing. Without it, everything
/// still works with Casework's built-in PDF code.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ZPdfException implements Exception {
  ZPdfException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ZPdf {
  ZPdf(this.executable, [this.prefix = const []]);

  /// Program to run (pdfm, or ZPDF's own python.exe) and any arguments before the command.
  final String executable;
  final List<String> prefix;

  String get display => [executable, ...prefix].join(' ');

  /// Where the Windows installer ("Install ZPDF.cmd") puts it.
  static String? _windowsAppDir() {
    final local = Platform.environment['LOCALAPPDATA'];
    return local == null ? null : p.join(local, 'PDF Manager', 'app');
  }

  /// Find ZPDF. [override] is a path the user chose in Settings (pdfm / pdfm.exe / python.exe).
  static ZPdf? detect({String? override}) {
    ZPdf? from(String path) {
      if (!File(path).existsSync()) return null;
      final name = p.basenameWithoutExtension(path).toLowerCase();
      // ZPDF's python runs the toolkit as a module.
      if (name.startsWith('python')) return ZPdf(path, ['-I', '-m', 'pdfmanager']);
      return ZPdf(path);
    }

    for (final c in [override, Platform.environment['CABINET_CRM_PDFM']]) {
      if (c != null && c.trim().isNotEmpty) {
        final z = from(c.trim());
        if (z != null) return z;
      }
    }
    final app = _windowsAppDir();
    if (Platform.isWindows && app != null) {
      for (final exe in ['pdfm.exe', 'python.exe']) {
        final z = from(p.join(app, 'venv', 'Scripts', exe));
        if (z != null) return z;
      }
    }
    // On the PATH (pip install), any platform.
    final pathVar = Platform.environment['PATH'] ?? '';
    for (final dir in pathVar.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final z = from(p.join(dir, Platform.isWindows ? 'pdfm.exe' : 'pdfm'));
      if (z != null) return z;
    }
    return null;
  }

  Future<String> _run(List<String> args, {Duration timeout = const Duration(minutes: 3)}) async {
    final r = await Process.run(executable, [...prefix, ...args], stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(timeout, onTimeout: () => throw ZPdfException('ZPDF took too long (${args.first}).'));
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim().isEmpty ? '${r.stdout}'.trim() : '${r.stderr}'.trim();
      throw ZPdfException('ZPDF ${args.first} failed: ${err.split('\n').last}');
    }
    return '${r.stdout}'.trim();
  }

  /// e.g. "pdfm 0.10.0"
  Future<String> version() => _run(['--version'], timeout: const Duration(seconds: 30));

  /// Combine PDFs. Each file gets a bookmark named after its file name.
  Future<void> merge(List<String> inputs, String output, {bool bookmarks = true}) =>
      _run(['merge', ...inputs, '-o', output, if (!bookmarks) '--no-bookmarks']);

  Future<void> numberPages(String input, String output,
          {String format = 'Page {n} of {total}', String position = 'bottom-right', double fontSize = 8}) =>
      _run(['number', input, '-o', output, '--format', format, '--position', position, '--font-size', '$fontSize']);

  Future<void> compress(String input, String output, {String level = 'medium'}) =>
      _run(['compress', input, '-o', output, '-l', level]);

  /// Open PDFs in ZPDF's reader (annotate, sign, edit text). Does not wait.
  Future<void> view(List<String> files) async {
    await Process.start(executable, [...prefix, 'view', ...files], mode: ProcessStartMode.detached);
  }
}
