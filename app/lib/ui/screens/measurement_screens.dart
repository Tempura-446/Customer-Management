import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'design_screens.dart';
import 'project_screen.dart';

class MeasurementFormScreen extends StatefulWidget {
  const MeasurementFormScreen({super.key, this.projectId, this.measurementId})
      : assert(projectId != null || measurementId != null);
  final String? projectId, measurementId;
  @override
  State<MeasurementFormScreen> createState() => _MeasurementFormScreenState();
}

class _Line {
  _Line(String label, String value, this.unit)
      : label = TextEditingController(text: label),
        value = TextEditingController(text: value);
  final TextEditingController label, value;
  String unit;
  bool get empty => label.text.trim().isEmpty && value.text.trim().isEmpty;
  void dispose() {
    label.dispose();
    value.dispose();
  }
}

class _MeasurementFormScreenState extends State<MeasurementFormScreen> {
  final _room = TextEditingController();
  final _takenBy = TextEditingController();
  final _notes = TextEditingController();
  String _source = 'onsite';
  bool _verified = false;
  String? _takenOn = today();
  late String _projectId;
  final _lines = <_Line>[];
  String _unit = 'in';

  @override
  void initState() {
    super.initState();
    final svc = context.svc;
    final m = widget.measurementId == null ? null : svc.db.get('measurements', widget.measurementId);
    _projectId = m?.s('project_id') ?? widget.projectId!;
    if (m != null) {
      _room.text = m.s('room');
      _takenBy.text = m.s('taken_by');
      _notes.text = m.s('notes');
      _source = m.s('source');
      _verified = m.b('verified');
      _takenOn = m.ns('taken_on');
      for (final i in measurementItems(svc.db, m.id)) {
        _lines.add(_Line(i.s('label'), i.s('value'), i.s('unit')));
      }
      if (_lines.isNotEmpty) _unit = _lines.first.unit;
    } else {
      _takenBy.text = svc.user?.s('name') ?? '';
    }
    final blanks = _lines.isEmpty ? 4 : 1;
    for (var i = 0; i < blanks; i++) {
      _lines.add(_Line('', '', _unit));
    }
  }

  @override
  void dispose() {
    for (final c in [_room, _takenBy, _notes]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _preset(String name) {
    setState(() {
      _lines.removeWhere((l) {
        if (l.empty) l.dispose();
        return l.empty;
      });
      for (final label in measurementPresets[name]!) {
        _lines.add(_Line(label, '', _unit));
      }
      if (_room.text.isEmpty) _room.text = name;
    });
  }

  Future<void> _save() async {
    final db = context.db;
    String? id;
    final ok = await attempt(context, () async {
      id = saveMeasurement(db,
          id: widget.measurementId,
          projectId: _projectId,
          room: _room.text,
          source: _source,
          takenBy: _takenBy.text.trim(),
          takenOn: _takenOn,
          verified: _verified,
          notes: _notes.text.trim(),
          lines: [for (final l in _lines) MeasureLine(l.label.text, l.value.text, l.unit)]);
    });
    if (!ok || !mounted) return;
    if (widget.measurementId == null) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MeasurementScreen(measurementId: id!)));
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.measurementId == null ? 'New measurements' : 'Edit measurements'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: PageBody(maxWidth: 900, children: [
        TwoCol(
          left: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _room,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Room / area', hintText: 'Kitchen'),
            ),
          ),
          right: Row(children: [
            Expanded(child: DateField(label: 'Date', value: _takenOn, onChanged: (v) => setState(() => _takenOn = v))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _takenBy, decoration: const InputDecoration(labelText: 'Taken by'))),
          ]),
        ),
        const SizedBox(height: 4),
        Text('Where did these measurements come from?', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final src in measurementSources)
            ChoiceChip(
              avatar: Icon(sourceIcon(src.key), size: 18, color: _source == src.key ? Colors.white : tone(Color(src.color), context)),
              label: Text(src.label),
              selected: _source == src.key,
              showCheckmark: false,
              selectedColor: Color(src.color),
              labelStyle: TextStyle(
                  color: _source == src.key ? Colors.white : tone(Color(src.color), context), fontWeight: FontWeight.w600),
              side: BorderSide(color: tone(Color(src.color), context).withValues(alpha: 0.6)),
              backgroundColor: tone(Color(src.color), context).withValues(alpha: 0.08),
              onSelected: (_) => setState(() => _source = src.key),
            ),
        ]),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: sourceColor(_source).withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: sourceColor(_source), width: 4)),
          ),
          child: Text(sourceOf(_source).hint),
        ),
        if (sourceOf(_source).needsVerify)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _verified,
            onChanged: (v) => setState(() => _verified = v ?? false),
            title: const Text('Verified (checked on site, or signed off by the customer)'),
            subtitle: const Text('Until then these stay flagged, and the job shows "verify before ordering".'),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Text('Dimensions', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          const Muted('Default unit '),
          DropdownButton<String>(
            value: _unit,
            items: [for (final u in units.where((u) => u.isNotEmpty)) DropdownMenuItem(value: u, child: Text(u))],
            onChanged: (v) => setState(() {
              final old = _unit;
              _unit = v ?? 'in';
              for (final l in _lines) {
                if (l.unit == old) l.unit = _unit;
              }
            }),
          ),
        ]),
        Wrap(spacing: 6, children: [
          const Padding(padding: EdgeInsets.only(top: 8), child: Muted('Checklist: ')),
          for (final k in measurementPresets.keys) ActionChip(label: Text(k), onPressed: () => _preset(k)),
        ]),
        const SizedBox(height: 8),
        for (final (i, l) in _lines.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: wide
                ? Row(children: [
                    Expanded(flex: 3, child: TextField(controller: l.label, decoration: const InputDecoration(labelText: 'What'))),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: TextField(controller: l.value, decoration: const InputDecoration(labelText: 'Value'))),
                    const SizedBox(width: 8),
                    _unitBox(l),
                    _remove(i),
                  ])
                : Column(children: [
                    TextField(controller: l.label, decoration: const InputDecoration(labelText: 'What')),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: l.value,
                              decoration: const InputDecoration(labelText: 'Value', hintText: '120 1/2'))),
                      const SizedBox(width: 8),
                      _unitBox(l),
                      _remove(i),
                    ]),
                    const Divider(),
                  ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: () => setState(() => _lines.add(_Line('', '', _unit))),
              icon: const Icon(Icons.add),
              label: const Text('Add row')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _notes,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Notes', hintText: 'Out-of-square walls, obstacles, access, existing conditions…'),
        ),
        const SizedBox(height: 8),
        if (widget.measurementId == null) const Muted('Save first, then add photos and sketches on the next screen.'),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _save, child: const Text('Save measurements'))),
      ]),
    );
  }

  Widget _unitBox(_Line l) => SizedBox(
        width: 96,
        child: DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: units.contains(l.unit) ? l.unit : '',
          items: [for (final u in units) DropdownMenuItem(value: u, child: Text(u.isEmpty ? '-' : u))],
          onChanged: (v) => l.unit = v ?? '',
        ),
      );

  Widget _remove(int i) => IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => setState(() => _lines.removeAt(i).dispose()),
      );
}

class MeasurementScreen extends StatelessWidget {
  const MeasurementScreen({super.key, required this.measurementId});
  final String measurementId;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    return DbBuilder(
      db: db,
      builder: (context) {
        final m = db.get('measurements', measurementId);
        if (m == null) return const Scaffold(body: Center(child: Text('Deleted.')));
        final p = projectWithCustomer(db, m.s('project_id'))!;
        final items = measurementItems(db, measurementId);
        final designs = db.select('SELECT * FROM designs WHERE measurement_id=? AND deleted=0 ORDER BY version', [measurementId]);
        return Scaffold(
          appBar: AppBar(title: Text('${m.s('room')} measurements'), actions: [
            IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
                onPressed: () => push(context, MeasurementFormScreen(measurementId: measurementId))),
            PopupMenuButton<String>(
              onSelected: (_) async {
                if (await confirm(context, 'Delete these measurements?', ok: 'Delete', danger: true)) {
                  db.softDelete('measurements', measurementId);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              itemBuilder: (_) => [const PopupMenuItem(value: 'd', child: Text('Delete'))],
            ),
          ]),
          body: PageBody(children: [
            InkWell(
              onTap: () => push(context, ProjectScreen(projectId: p.id)),
              child: Crumbs('${p.s('customer')} › ${numberOf(p)} · ${p.s('title')}'),
            ),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SourceChip(m.s('source'), verified: m.b('verified'), verifiedOn: m.ns('verified_on'), long: true),
              Text('${m.ns('taken_by') != null ? 'by ${m.s('taken_by')} · ' : ''}${m.ns('taken_on') ?? fmtDate(m.s('created_at'))}'),
              if (!m.b('verified') && sourceOf(m.s('source')).needsVerify)
                FilledButton.tonalIcon(
                    onPressed: () => verifyMeasurement(db, measurementId),
                    icon: const Icon(Icons.check),
                    label: const Text('Mark verified')),
              FilledButton.icon(
                  onPressed: () => push(context, DesignFormScreen(projectId: p.id, measurementId: measurementId)),
                  icon: const Icon(Icons.architecture),
                  label: const Text('Start design from these')),
            ]),
            const SizedBox(height: 12),
            if (sourceOf(m.s('source')).risk >= 2 && !m.b('verified'))
              const WarnBanner('Guessed from photos: use for a ballpark design and price only. Measure on site before ordering.'),
            TwoCol(
              left: Section(
                title: 'Dimensions',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (items.isEmpty) const Muted('No dimensions entered.'),
                  for (final it in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(child: Text(it.s('label'))),
                        if (it.ns('value') == null)
                          const Muted('not measured')
                        else
                          SelectableText('${it.s('value')} ${it.s('unit')}',
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  if (m.ns('notes') != null) ...[
                    const Divider(),
                    Text('Notes', style: Theme.of(context).textTheme.titleSmall),
                    SelectableText(m.s('notes')),
                  ],
                ]),
              ),
              right: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FilesPanel(
                    projectId: p.id,
                    entityType: 'measurement',
                    entityId: measurementId,
                    category: 'measurements',
                    title: 'Photos & sketches'),
                Section(
                  title: 'Used by designs',
                  child: Column(children: [
                    if (designs.isEmpty) const Muted('Not used by a design yet.'),
                    for (final d in designs)
                      ItemTile(
                        title: 'Design v${d.i('version')} ${d.s('title')}',
                        trailing: StatusChip(d.s('status')),
                        onTap: () => push(context, DesignScreen(designId: d.id)),
                      ),
                  ]),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}
