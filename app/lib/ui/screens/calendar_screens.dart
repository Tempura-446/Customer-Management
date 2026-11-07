import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/db.dart';
import '../../core/logic.dart';
import '../../core/schedule.dart';
import '../../services.dart';
import '../widgets/common.dart';
import 'mail_screens.dart';
import 'project_screen.dart';

DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));
String _initials(String name) =>
    name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty && w[0] != '(').take(2).map((w) => w[0].toUpperCase()).join();

// ============================================================================ calendar tab

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _week = _monday(DateTime.now());
  String? _user; // null = everyone, otherwise user id
  String? _kind;

  Future<void> _new() async {
    final pid = await pickJob(context, title: 'Appointment for which job?');
    if (pid == null || !mounted) return;
    push(context, AppointmentFormScreen(projectId: pid));
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final me = context.svc.user?.id;
    final users = activeUsers(db);
    final range = '${DateFormat('MMM d').format(_week)} – ${DateFormat('MMM d, y').format(_week.add(const Duration(days: 6)))}';
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.event_available),
        label: const Text('New appointment'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            IconButton(
                tooltip: 'Previous week',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _week = _week.subtract(const Duration(days: 7)))),
            Text(range, style: Theme.of(context).textTheme.titleMedium),
            IconButton(
                tooltip: 'Next week',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _week = _week.add(const Duration(days: 7)))),
            TextButton(onPressed: () => setState(() => _week = _monday(DateTime.now())), child: const Text('Today')),
            DropdownButton<String?>(
              value: _user,
              hint: const Text('Everyone'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Everyone')),
                if (me != null) DropdownMenuItem(value: me, child: const Text('Me')),
                for (final u in users.where((u) => u.id != me)) DropdownMenuItem(value: u.id, child: Text(u.s('name'))),
              ],
              onChanged: (v) => setState(() => _user = v),
            ),
            DropdownButton<String?>(
              value: _kind,
              hint: const Text('All kinds'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All kinds')),
                for (final k in appointmentKinds) DropdownMenuItem(value: k.key, child: Text(k.label)),
              ],
              onChanged: (v) => setState(() => _kind = v),
            ),
          ]),
        ),
        Expanded(
          child: DbBuilder(
            db: db,
            builder: (context) {
              final list = appointmentsBetween(db, _week, _week.add(const Duration(days: 7)), userId: _user, kind: _kind);
              final days = [for (var i = 0; i < 7; i++) _week.add(Duration(days: i))];
              List<Rec> on(DateTime d) =>
                  list.where((a) => (parseStart(a.s('starts_at'))?.day == d.day) && parseStart(a.s('starts_at'))?.month == d.month).toList();
              return isWide(context) ? _WeekGrid(days: days, on: on) : _Agenda(days: days, on: on);
            },
          ),
        ),
      ]),
    );
  }
}

bool _isToday(DateTime d) {
  final n = DateTime.now();
  return d.year == n.year && d.month == n.month && d.day == n.day;
}

class _WeekGrid extends StatelessWidget {
  const _WeekGrid({required this.days, required this.on});
  final List<DateTime> days;
  final List<Rec> Function(DateTime) on;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 80),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final d in days)
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(3),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _isToday(d) ? cs.primaryContainer.withValues(alpha: 0.5) : cs.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: _isToday(d) ? Border.all(color: cs.primary, width: 1.5) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(DateFormat('EEE d').format(d),
                    style: TextStyle(fontWeight: FontWeight.w700, color: _isToday(d) ? cs.primary : null)),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView(children: [
                    for (final a in on(d)) _ApptCard(a: a, compact: true),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _Agenda extends StatelessWidget {
  const _Agenda({required this.days, required this.on});
  final List<DateTime> days;
  final List<Rec> Function(DateTime) on;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 90), children: [
        for (final d in days) ...[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(DateFormat('EEEE, MMM d').format(d) + (_isToday(d) ? '  · Today' : ''),
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: _isToday(d) ? Theme.of(context).colorScheme.primary : null)),
          ),
          if (on(d).isEmpty) const Muted('Nothing booked', size: 12),
          for (final a in on(d)) _ApptCard(a: a),
        ],
      ]);
}

class _ApptCard extends StatelessWidget {
  const _ApptCard({required this.a, this.compact = false});
  final Rec a;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final k = kindOf(a.s('kind'));
    final start = parseStart(a.s('starts_at'));
    final end = start?.add(Duration(minutes: a.i('duration_min')));
    final time = start == null ? '' : '${fmtTime(start)}–${fmtTime(end!)}';
    final done = a.s('status') == 'done';
    return Opacity(
      opacity: done || a.s('status') == 'cancelled' ? 0.55 : 1,
      child: Card(
        margin: const EdgeInsets.only(bottom: 6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => push(context, AppointmentFormScreen(appointmentId: a.id)),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: Color(k.color), width: 5))),
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text('$time  ${k.label}',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: compact ? 12 : 13, color: tone(Color(k.color), context)))),
                if (a.ns('user_name') != null)
                  Tooltip(
                    message: a.s('user_name'),
                    child: CircleAvatar(radius: 10, child: Text(_initials(a.s('user_name')), style: const TextStyle(fontSize: 9))),
                  ),
              ]),
              Text(a.s('customer'), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${a.ns('pnum') ?? ''} ${a.s('ptitle')}', style: const TextStyle(fontSize: 11)),
              if (a.ns('site_address') != null) Muted(a.s('site_address'), size: 11),
              if (done) const Muted('done', size: 11) else if (!a.b('confirmed')) const Muted('not confirmed', size: 11),
            ]),
          ),
        ),
      ),
    );
  }
}

// ============================================================================ appointment form

class AppointmentFormScreen extends StatefulWidget {
  const AppointmentFormScreen({super.key, this.appointmentId, this.projectId, this.kind})
      : assert(appointmentId != null || projectId != null);
  final String? appointmentId, projectId, kind;
  @override
  State<AppointmentFormScreen> createState() => _AppointmentFormScreenState();
}

const _durations = <int, String>{
  30: '30 min', 60: '1 h', 90: '1.5 h', 120: '2 h', 180: '3 h', 240: '4 h', 360: '6 h', 480: '8 h', 600: 'Full day (10 h)',
};

class _AppointmentFormScreenState extends State<AppointmentFormScreen> {
  late String _projectId;
  late String _kind;
  late DateTime _start;
  int _duration = 60;
  String? _assigned;
  bool _confirmed = false;
  final _notes = TextEditingController();
  Rec? _existing;

  @override
  void initState() {
    super.initState();
    final svc = context.svc;
    final db = svc.db;
    _existing = widget.appointmentId == null ? null : db.get('appointments', widget.appointmentId);
    final a = _existing;
    _projectId = a?.s('project_id') ?? widget.projectId!;
    final p = db.get('projects', _projectId);
    if (a != null) {
      _kind = a.s('kind');
      _start = parseStart(a.s('starts_at')) ?? DateTime.now();
      _duration = a.i('duration_min');
      _assigned = a.ns('assigned_to');
      _confirmed = a.b('confirmed');
      _notes.text = a.s('notes');
    } else {
      final st = normalizeStage(p?.s('status') ?? 'lead');
      _kind = widget.kind ??
          (st == 'lead' ? 'measure' : (atLeast(st, 'approved') ? completingKind(p?.ns('order_type')) : 'measure'));
      final t = DateTime.now().add(const Duration(days: 1));
      _start = DateTime(t.year, t.month, t.day, 9);
      _duration = _kind == 'install' ? 480 : 60;
      _assigned = svc.user?.id;
    }
    if (!_durations.containsKey(_duration)) _duration = 60;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await attempt(context, () async {
      saveAppointment(context.db,
          id: _existing?.id,
          projectId: _projectId,
          kind: _kind,
          start: _start,
          durationMin: _duration,
          assignedTo: _assigned,
          notes: _notes.text.trim(),
          confirmed: _confirmed);
    });
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context, initialDate: _start, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d != null) setState(() => _start = DateTime(d.year, d.month, d.day, _start.hour, _start.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t != null) setState(() => _start = DateTime(_start.year, _start.month, _start.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final p = projectWithCustomer(db, _projectId);
    final users = activeUsers(db);
    final clash = conflicts(db, assignedTo: _assigned, start: _start, durationMin: _duration, excludeId: _existing?.id);
    final a = _existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(a == null ? 'New appointment' : 'Appointment'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: PageBody(maxWidth: 760, children: [
        if (p != null)
          ItemTile(
            title: '${p.s('customer')} · ${p.s('title')}',
            subtitle: [numberOf(p), p.s('site_address'), p.s('phone')].where((x) => x.isNotEmpty).join(' · '),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(context, ProjectScreen(projectId: p.id)),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final k in appointmentKinds)
            ChoiceChip(
              label: Text(k.label),
              selected: _kind == k.key,
              showCheckmark: false,
              selectedColor: Color(k.color),
              labelStyle: TextStyle(color: _kind == k.key ? Colors.white : tone(Color(k.color), context), fontWeight: FontWeight.w600),
              side: BorderSide(color: tone(Color(k.color), context).withValues(alpha: 0.6)),
              backgroundColor: tone(Color(k.color), context).withValues(alpha: 0.08),
              onSelected: (_) => setState(() => _kind = k.key),
            ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(DateFormat('EEE, MMM d, y').format(_start))),
          OutlinedButton.icon(
              onPressed: _pickTime, icon: const Icon(Icons.schedule, size: 18), label: Text(DateFormat('h:mm a').format(_start))),
          DropdownButton<int>(
            value: _duration,
            items: [for (final e in _durations.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _duration = v ?? 60),
          ),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: users.any((u) => u.id == _assigned) ? _assigned : null,
          decoration: const InputDecoration(labelText: 'Assigned to'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Nobody yet')),
            for (final u in users) DropdownMenuItem(value: u.id, child: Text(u.s('name'))),
          ],
          onChanged: (v) => setState(() => _assigned = v),
        ),
        for (final c in clash)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: WarnBanner('Already booked: ${describeAppointment(c)} (${c.s('customer')}).'),
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _confirmed,
          onChanged: (v) => setState(() => _confirmed = v ?? false),
          title: const Text('Customer confirmed'),
        ),
        TextField(
          controller: _notes,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Notes', hintText: 'Gate code, parking, bring the 10ft ladder…'),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(onPressed: _save, child: const Text('Save')),
          if (a != null && a.s('status') == 'scheduled') ...[
            FilledButton.tonalIcon(
              onPressed: () async {
                final k = kindOf(a.s('kind'));
                final msg = k.completes
                    ? 'Mark done? The job will be marked ${completedLabel(p?.ns('order_type')).toLowerCase()}.'
                    : 'Mark this appointment done?';
                if (!await confirm(context, msg, ok: 'Mark done')) return;
                if (!context.mounted) return;
                await attempt(context, () async => markAppointmentDone(context.db, a.id), success: 'Done');
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.check),
              label: const Text('Mark done'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                if (!await confirm(context, 'Cancel this appointment?', ok: 'Cancel appointment', danger: true)) return;
                if (!context.mounted) return;
                cancelAppointment(context.db, a.id);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.event_busy),
              label: const Text('Cancel appointment'),
            ),
          ],
          if (a != null)
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: confirmationText(context.db, a.id)));
                if (context.mounted) toast(context, 'Confirmation copied: paste it into a text or email');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy confirmation'),
            ),
        ]),
        if (a == null) const Padding(padding: EdgeInsets.only(top: 8), child: Muted('Save first to copy a confirmation message.', size: 12)),
      ]),
    );
  }
}

// ============================================================================ job page card

class ProjectAppointmentsCard extends StatelessWidget {
  const ProjectAppointmentsCard({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final list = projectAppointments(context.db, projectId).where((a) => a.s('status') != 'cancelled').toList();
    final now = fmtStart(DateTime.now().subtract(const Duration(hours: 12)));
    final upcoming = list.where((a) => a.s('starts_at').compareTo(now) >= 0).toList().reversed.toList();
    final past = list.where((a) => a.s('starts_at').compareTo(now) < 0).take(5).toList();
    Widget tile(Rec a) {
      final k = kindOf(a.s('kind'));
      final d = parseStart(a.s('starts_at'));
      return ItemTile(
        accent: Color(k.color),
        dim: a.s('status') == 'done',
        title: '${k.label}${d != null ? ' · ${DateFormat('EEE MMM d, h:mm a').format(d)}' : ''}',
        subtitle: [
          if (a.ns('user_name') != null) a.s('user_name'),
          if (a.s('status') == 'done') 'done' else if (!a.b('confirmed')) 'not confirmed' else 'confirmed',
        ].join(' · '),
        onTap: () => push(context, AppointmentFormScreen(appointmentId: a.id)),
      );
    }

    return Section(
      title: 'Appointments',
      action: TextButton.icon(
          onPressed: () => push(context, AppointmentFormScreen(projectId: projectId)),
          icon: const Icon(Icons.event_available, size: 18),
          label: const Text('Book')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (list.isEmpty) const Muted('Nothing booked. Book the site measure, delivery, pickup or installation.'),
        for (final a in upcoming) tile(a),
        if (past.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.only(top: 6, bottom: 4), child: Muted('Earlier', size: 12)),
          for (final a in past) tile(a),
        ],
      ]),
    );
  }
}

// ============================================================================ dashboard "my day"

class MyDayCard extends StatelessWidget {
  const MyDayCard({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.svc;
    final uid = svc.user?.id;
    if (uid == null) return const SizedBox.shrink();
    return DbBuilder(
      db: svc.db,
      builder: (context) {
        final list = todayFor(svc.db, uid);
        if (list.isEmpty) return const SizedBox.shrink();
        return Section(
          title: 'My day',
          child: Column(children: [
            for (final a in list) _MyDayRow(a: a),
          ]),
        );
      },
    );
  }
}

class _MyDayRow extends StatelessWidget {
  const _MyDayRow({required this.a});
  final Rec a;

  @override
  Widget build(BuildContext context) {
    final k = kindOf(a.s('kind'));
    final d = parseStart(a.s('starts_at'));
    final dayLabel = d == null ? '' : (_isToday(d) ? 'Today' : 'Tomorrow');
    final addr = a.ns('site_address');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: Color(k.color), width: 5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$dayLabel ${d == null ? '' : DateFormat('h:mm a').format(d)} · ${k.label}',
            style: TextStyle(fontWeight: FontWeight.w700, color: tone(Color(k.color), context))),
        Text('${a.s('customer')} · ${a.ns('pnum') ?? ''} ${a.s('ptitle')}'),
        if (addr != null) Muted(addr, size: 12),
        Wrap(spacing: 4, children: [
          if (a.ns('phone') != null)
            TextButton.icon(
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: a.s('phone'))),
                icon: const Icon(Icons.phone, size: 16),
                label: const Text('Call')),
          if (addr != null)
            TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('https://maps.google.com/?q=${Uri.encodeComponent(addr)}')),
                icon: const Icon(Icons.map_outlined, size: 16),
                label: const Text('Map')),
          TextButton.icon(
              onPressed: () => push(context, ProjectScreen(projectId: a.s('project_id'))),
              icon: const Icon(Icons.work_outline, size: 16),
              label: const Text('Open job')),
        ]),
      ]),
    );
  }
}
