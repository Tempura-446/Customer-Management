/// Per-room measurement checklists: what a tech must capture before leaving the site.
///
/// The office edits them in Settings. They are stored in one synced setting
/// (`measure_checklists`, JSON {room: [item, ...]}) so every phone uses the same list.
/// Until someone edits them, the built-in [measurementPresets] are used.
library;

import 'dart:convert';

import 'db.dart';
import 'logic.dart';

const checklistSettingKey = 'measure_checklists';

/// All checklists, room name -> items, in display order.
Map<String, List<String>> measurementChecklists(AppDb db) {
  final raw = settings(db)[checklistSettingKey];
  if (raw != null && raw.trim().isNotEmpty) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, List<String>>{};
      for (final e in m.entries) {
        final items = (e.value as List).map((x) => '$x'.trim()).where((x) => x.isNotEmpty).toList();
        if (e.key.trim().isNotEmpty) out[e.key.trim()] = items;
      }
      return out;
    } catch (_) {
      // A damaged value falls back to the defaults rather than breaking every measurement screen.
    }
  }
  return {for (final e in measurementPresets.entries) e.key: List.of(e.value)};
}

void saveMeasurementChecklists(AppDb db, Map<String, List<String>> lists) {
  final clean = <String, List<String>>{};
  for (final e in lists.entries) {
    final name = e.key.trim();
    if (name.isEmpty) continue;
    clean[name] = e.value.map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
  }
  setSetting(db, checklistSettingKey, jsonEncode(clean));
}

void resetMeasurementChecklists(AppDb db) => setSetting(db, checklistSettingKey, '');

/// The checklist that applies to a measurement set's room name.
/// "Kitchen", "kitchen 2" and "Main kitchen" all use the Kitchen list.
/// Returns null when no checklist matches.
(String, List<String>)? checklistForRoom(AppDb db, String room) {
  final r = room.trim().toLowerCase();
  if (r.isEmpty) return null;
  final lists = measurementChecklists(db);
  for (final e in lists.entries) {
    if (e.key.toLowerCase() == r) return (e.key, e.value);
  }
  // Longest name first, so "Master bathroom" beats "Bathroom" if both exist.
  final byLength = lists.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in byLength) {
    if (RegExp('\\b${RegExp.escape(k.toLowerCase())}\\b').hasMatch(r)) return (k, lists[k]!);
  }
  return null;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Checklist items with no value entered in this measurement set.
List<String> missingMeasurements(AppDb db, String measurementId) {
  final m = db.get('measurements', measurementId);
  if (m == null) return const [];
  final list = checklistForRoom(db, m.s('room'));
  if (list == null) return const [];
  final measured = <String>{
    for (final it in measurementItems(db, measurementId))
      if ((it.ns('value') ?? '').trim().isNotEmpty) _norm(it.s('label')),
  };
  return [for (final item in list.$2) if (!measured.contains(_norm(item))) item];
}
