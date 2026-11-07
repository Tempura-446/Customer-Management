import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import '../widgets/files_panel.dart';
import 'measurement_screens.dart';
import 'project_screen.dart';
import 'quote_screens.dart';

const designStatuses = ['draft', 'presented', 'approved', 'superseded'];

class DesignFormScreen extends StatefulWidget {
  const DesignFormScreen({super.key, this.projectId, this.designId, this.measurementId})
      : assert(projectId != null || designId != null);
  final String? projectId, designId, measurementId;
  @override
  State<DesignFormScreen> createState() => _DesignFormScreenState();
}

class _DesignFormScreenState extends State<DesignFormScreen> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  String _status = 'draft';
  String? _measurementId;
  late String _projectId;

  @override
  void initState() {
    super.initState();
    final db = context.db;
    final d = widget.designId == null ? null : db.get('designs', widget.designId);
    _projectId = d?.s('project_id') ?? widget.projectId!;
    _title.text = d?.s('title') ?? '';
    _notes.text = d?.s('notes') ?? '';
    _status = d?.s('status') ?? 'draft';
    _measurementId = d?.ns('measurement_id') ??
        widget.measurementId ??
        (d == null
            ? db.one('SELECT id FROM measurements WHERE project_id=? AND deleted=0 ORDER BY created_at DESC LIMIT 1',
                    [_projectId])
                ?.id
            : null);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = context.db;
    String? id;
    final ok = await attempt(context, () async {
      id = saveDesign(db,
          id: widget.designId,
          projectId: _projectId,
          title: _title.text.trim(),
          measurementId: _measurementId,
          status: _status,
          notes: _notes.text.trim());
    });
    if (!ok || !mounted) return;
    if (widget.designId == null) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => DesignScreen(designId: id!)));
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final meas = db.select('SELECT * FROM measurements WHERE project_id=? AND deleted=0 ORDER BY created_at DESC', [_projectId]);
    final nextVer = widget.designId == null
        ? db.scalar('SELECT COALESCE(MAX(version),0)+1 FROM designs WHERE project_id=? AND deleted=0', [_projectId])
        : db.get('designs', widget.designId)!.i('version');
    final p = projectWithCustomer(db, _projectId)!;
    return Scaffold(
      appBar: AppBar(title: Text(widget.designId == null ? 'New design (v$nextVer)' : 'Edit design v$nextVer')),
      body: PageBody(maxWidth: 800, children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title / description', hintText: 'L-shape with island, white shaker'),
        ),
        const SizedBox(height: 12),
        TwoCol(
          left: DropdownButtonFormField<String?>(
            initialValue: meas.any((m) => m.id == _measurementId) ? _measurementId : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Based on measurements'),
            items: [
              const DropdownMenuItem(value: null, child: Text('(none)')),
              for (final m in meas)
                DropdownMenuItem(
                    value: m.id,
                    child: Row(children: [
                      Icon(sourceIcon(m.s('source')), size: 16, color: sourceColor(m.s('source'))),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text('${m.s('room')} · ${m.ns('taken_on') ?? fmtDate(m.s('created_at'))} · '
                            '${sourceOf(m.s('source')).short}'
                            '${!sourceOf(m.s('source')).needsVerify || m.b('verified') ? '' : ' (not verified)'}',
                            overflow: TextOverflow.ellipsis),
                      ),
                    ])),
            ],
            onChanged: (v) => setState(() => _measurementId = v),
          ),
          right: Padding(
            padding: EdgeInsets.only(top: isWide(context) ? 0 : 12),
            child: DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [for (final s in designStatuses) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) => setState(() => _status = v ?? 'draft'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Notes', hintText: 'Changes from last version, customer feedback, finishes…'),
        ),
        const SizedBox(height: 12),
        WarnBanner(
            'Tip: save the 2020 file as ${p.ns('number') ?? 'J-…'}_${slug(p.s('customer'))}_v$nextVer.kit '
            'so it matches this record. Attach the .kit, PDF drawings and renders on the next screen.',
            serious: false),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _save, child: const Text('Save design'))),
      ]),
    );
  }
}

class DesignScreen extends StatelessWidget {
  const DesignScreen({super.key, required this.designId});
  final String designId;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    return DbBuilder(
      db: db,
      builder: (context) {
        final d = db.get('designs', designId);
        if (d == null) return const DeletedScreen('This design');
        final p = projectWithCustomer(db, d.s('project_id'))!;
        final m = db.get('measurements', d.ns('measurement_id'));
        final quotes = svc.prices
            ? db.select('SELECT * FROM quotes WHERE design_id=? AND deleted=0 ORDER BY created_at', [designId])
            : const [];
        return Scaffold(
          appBar: AppBar(title: Text('Design v${d.i('version')}${d.ns('title') != null ? ' · ${d.s('title')}' : ''}'), actions: [
            IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
                onPressed: () => push(context, DesignFormScreen(designId: designId))),
            PopupMenuButton<String>(
              onSelected: (_) async {
                if (await confirm(context, 'Delete design v${d.i('version')}?', ok: 'Delete', danger: true)) {
                  db.softDelete('designs', designId);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              itemBuilder: (c) => [dangerItem(c, 'd', 'Delete design')],
            ),
          ]),
          body: PageBody(children: [
            InkWell(
              onTap: () => push(context, ProjectScreen(projectId: p.id)),
              child: Crumbs('${p.s('customer')} › ${numberOf(p)} · ${p.s('title')}'),
            ),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusChip(d.s('status')),
              Muted('Created ${fmtDate(d.s('created_at'))}'),
              if (svc.prices)
                FilledButton.icon(
                  onPressed: () {
                    final qid = createQuote(db, p.id, designId: designId);
                    push(context, QuoteEditScreen(quoteId: qid));
                  },
                  icon: const Icon(Icons.request_quote_outlined),
                  label: const Text('Quote this design'),
                ),
            ]),
            const SizedBox(height: 12),
            TwoCol(
              leftFlex: 2,
              left: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FilesPanel(
                    projectId: p.id,
                    entityType: 'design',
                    entityId: designId,
                    category: 'designs',
                    title: '2020 file, drawings & renders'),
                if (d.ns('notes') != null) Section(title: 'Notes', child: SelectableText(d.s('notes'))),
              ]),
              right: Section(
                title: 'Trail',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Muted('Measurements'),
                  if (m == null)
                    const Text('Not linked')
                  else
                    ItemTile(
                      title: m.s('room'),
                      accent: sourceColor(m.s('source')),
                      below: SourceChip(m.s('source'), verified: m.b('verified')),
                      onTap: () => push(context, MeasurementScreen(measurementId: m.id)),
                    ),
                  if (svc.prices) ...[
                    const SizedBox(height: 8),
                    const Muted('Quotes from this design'),
                    if (quotes.isEmpty) const Text('None yet'),
                    for (final q in quotes)
                      ItemTile(
                        title: quoteLabel(q),
                        trailing: StatusChip(q.s('status')),
                        onTap: () => push(context, QuoteScreen(quoteId: q.id)),
                      ),
                  ],
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
