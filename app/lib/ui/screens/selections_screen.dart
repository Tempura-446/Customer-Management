import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';

/// Edit the customer's selections for a job (door style, finish, hardware, countertop…).
class SelectionsScreen extends StatefulWidget {
  const SelectionsScreen({super.key, required this.projectId});
  final String projectId;
  @override
  State<SelectionsScreen> createState() => _SelectionsScreenState();
}

class _Row {
  _Row(String cat, String item, String choice, String notes)
      : category = TextEditingController(text: cat),
        item = TextEditingController(text: item),
        choice = TextEditingController(text: choice),
        notes = TextEditingController(text: notes);
  final TextEditingController category, item, choice, notes;
  void dispose() {
    for (final c in [category, item, choice, notes]) {
      c.dispose();
    }
  }
}

class _SelectionsScreenState extends State<SelectionsScreen> {
  final _rows = <_Row>[];

  @override
  void initState() {
    super.initState();
    for (final r in selectionsFor(context.db, widget.projectId)) {
      _rows.add(_Row(r.s('category'), r.s('item'), r.s('choice'), r.s('notes')));
    }
    if (_rows.isEmpty) _loadChecklist();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _loadChecklist() {
    final have = _rows.map((r) => '${r.category.text}|${r.item.text}'.toLowerCase()).toSet();
    selectionChecklist.forEach((cat, items) {
      for (final it in items) {
        if (!have.contains('$cat|$it'.toLowerCase())) _rows.add(_Row(cat, it, '', ''));
      }
    });
    _sort();
  }

  void _sort() {
    final order = selectionChecklist.keys.toList();
    int rank(String c) {
      final i = order.indexOf(c);
      return i < 0 ? order.length : i;
    }

    // Stable sort by category order, keeping item order within a category.
    final indexed = _rows.indexed.toList()
      ..sort((a, b) {
        final c = rank(a.$2.category.text).compareTo(rank(b.$2.category.text));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    _rows
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }

  Future<void> _save() async {
    final ok = await attempt(context, () async {
      saveSelections(context.db, widget.projectId, [
        for (final r in _rows) SelectionLine(r.category.text, r.item.text, r.choice.text, r.notes.text),
      ]);
    });
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final cats = <String, List<_Row>>{};
    for (final r in _rows) {
      (cats[r.category.text.trim().isEmpty ? 'Other' : r.category.text.trim()] ??= []).add(r);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Selections'), actions: [TextButton(onPressed: _save, child: const Text('Save'))]),
      body: PageBody(maxWidth: 1000, children: [
        const Muted('Fill in what the customer chose. Empty lines are not saved. These print on the job packet.'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => setState(_loadChecklist),
              icon: const Icon(Icons.checklist),
              label: const Text('Add missing checklist items')),
          OutlinedButton.icon(
              onPressed: () => setState(() => _rows.add(_Row('Other', '', '', ''))),
              icon: const Icon(Icons.add),
              label: const Text('Add line')),
        ]),
        const SizedBox(height: 12),
        for (final MapEntry(key: cat, value: rows) in cats.entries)
          Section(
            title: cat,
            child: Column(children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: wide
                      ? Row(children: [
                          SizedBox(width: 200, child: TextField(controller: r.item, decoration: const InputDecoration(labelText: 'Item'))),
                          const SizedBox(width: 8),
                          Expanded(flex: 3, child: TextField(controller: r.choice, decoration: const InputDecoration(labelText: 'Selection'))),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: TextField(controller: r.notes, decoration: const InputDecoration(labelText: 'Notes'))),
                          _remove(r),
                        ])
                      : Column(children: [
                          Row(children: [
                            Expanded(child: TextField(controller: r.item, decoration: const InputDecoration(labelText: 'Item'))),
                            _remove(r),
                          ]),
                          const SizedBox(height: 4),
                          TextField(controller: r.choice, decoration: const InputDecoration(labelText: 'Selection')),
                          const SizedBox(height: 4),
                          TextField(controller: r.notes, decoration: const InputDecoration(labelText: 'Notes')),
                          const Divider(),
                        ]),
                ),
              Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: () => setState(() => _rows.add(_Row(cat, '', '', ''))),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add line')),
                ),
            ]),
          ),
        Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _save, child: const Text('Save selections'))),
      ]),
    );
  }

  Widget _remove(_Row r) => IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => setState(() {
          _rows.remove(r);
          r.dispose();
        }),
      );
}
