import 'package:flutter/material.dart';

import '../../core/activity.dart';
import '../../core/db.dart';
import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';

/// "Last changed by Sam, Nov 7, 9:02 AM" under a record's title.
class ChangedByLine extends StatelessWidget {
  const ChangedByLine(this.record, {super.key});
  final Rec record;
  @override
  Widget build(BuildContext context) {
    final t = lastChangedBy(context.db, record);
    if (t == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Muted(t, size: 12));
  }
}

String _initial(String name) => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

/// Job page: who worked on this job, with a link to the full history.
class JobPeopleLine extends StatelessWidget {
  const JobPeopleLine({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final workers = jobWorkers(svc.db, projectId, prices: svc.prices);
    if (workers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Muted(workers.length == 1 ? 'Worked on by' : '${workers.length} people worked on this job:', size: 12),
        for (final w in workers)
          ActionChip(
            avatar: CircleAvatar(child: Text(_initial(w.name), style: const TextStyle(fontSize: 11))),
            label: Text('${w.name} · ${w.changes} change${w.changes == 1 ? '' : 's'}'),
            tooltip: 'Last change ${fmtWhen(w.last)}. Show what ${w.name} did.',
            onPressed: () => push(context, JobHistoryScreen(projectId: projectId, userId: w.userId)),
          ),
        TextButton.icon(
          onPressed: () => push(context, JobHistoryScreen(projectId: projectId)),
          icon: const Icon(Icons.history, size: 18),
          label: const Text('History'),
        ),
      ]),
    );
  }
}

/// Everything changed on a job: who, what and when, optionally for one person.
class JobHistoryScreen extends StatefulWidget {
  const JobHistoryScreen({super.key, required this.projectId, this.userId});
  final String projectId;
  final String? userId;
  @override
  State<JobHistoryScreen> createState() => _JobHistoryScreenState();
}

class _JobHistoryScreenState extends State<JobHistoryScreen> {
  late String? _user = widget.userId;

  static const _verbs = {'added': 'added', 'changed': 'changed', 'deleted': 'deleted', 'restored': 'restored'};

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final db = svc.db;
    final p = projectWithCustomer(db, widget.projectId);
    return Scaffold(
      appBar: AppBar(title: Text('History · ${p == null ? '' : '${p.s('customer')} · ${p.s('title')}'}')),
      body: DbBuilder(
        db: db,
        builder: (context) {
          final workers = jobWorkers(db, widget.projectId, prices: svc.prices);
          final rows = jobActivity(db, widget.projectId, userId: _user, prices: svc.prices);
          final byDay = <String, List<Rec>>{};
          for (final r in rows) {
            final d = DateTime.tryParse(r.s('updated_at'))?.toLocal();
            final key = d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
            (byDay[key] ??= []).add(r);
          }
          return PageBody(maxWidth: 900, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              ChoiceChip(label: const Text('Everyone'), selected: _user == null, onSelected: (_) => setState(() => _user = null)),
              for (final w in workers)
                ChoiceChip(
                  avatar: CircleAvatar(child: Text(_initial(w.name), style: const TextStyle(fontSize: 11))),
                  label: Text('${w.name} (${w.changes})'),
                  selected: _user == w.userId,
                  onSelected: (_) => setState(() => _user = w.userId),
                ),
            ]),
            const SizedBox(height: 8),
            if (workers.length > 1)
              Muted(
                  [
                    for (final w in workers)
                      fmtWhen(w.first) == fmtWhen(w.last)
                          ? '${w.name}: ${fmtWhen(w.last)}'
                          : '${w.name}: ${fmtWhen(w.first)} to ${fmtWhen(w.last)}',
                  ].join(' · '),
                  size: 12),
            const SizedBox(height: 8),
            if (rows.isEmpty) const Muted('No changes recorded yet.'),
            for (final e in byDay.entries)
              Section(
                title: e.key.isEmpty ? 'Earlier' : fmtDate(e.key),
                child: Column(children: [
                  for (final r in e.value)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(radius: 14, child: Text(_initial(r.s('who')), style: const TextStyle(fontSize: 12))),
                      title: Text('${r.s('who')} ${_verbs[r.s('action')] ?? r.s('action')} ${r.s('label')}'),
                      subtitle: r.ns('details') == null ? null : Text(r.s('details')),
                      trailing: Muted(fmtWhen(r.s('updated_at')).split(', ').last, size: 11),
                    ),
                ]),
              ),
            const Muted(
                'Recorded on every computer and phone and shared at the next sync. Quick edits by the same person to the '
                'same thing within 15 minutes show as one line. Automatic changes (QuickBooks, email filing) are in the notes.',
                size: 12),
          ]);
        },
      ),
    );
  }
}
