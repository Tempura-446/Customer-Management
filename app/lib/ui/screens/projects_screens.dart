import 'package:flutter/material.dart';

import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import 'customers_screens.dart';
import 'project_screen.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});
  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  String? _status;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => push(context, const ProjectFormScreen()),
        icon: const Icon(Icons.add),
        label: const Text('New job'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Search job #, customer, phone, address'),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: const Text('All'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
            ),
            for (final s in stages)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                    label: Text(s.label), selected: _status == s.key, onSelected: (_) => setState(() => _status = s.key)),
              ),
          ]),
        ),
        Expanded(
          child: DbBuilder(
            db: db,
            builder: (context) {
              final list = projectsList(db, status: _status, query: _q);
              if (list.isEmpty) return const Center(child: Muted('No jobs.'));
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final p = list[i];
                  return ListTile(
                    title: Text('${p.s('customer')} · ${p.s('title')}'),
                    subtitle: Text([numberOf(p), p.s('site_address'), 'updated ${fmtDate(p.s('updated_at'))}']
                        .where((s) => s.isNotEmpty)
                        .join(' · ')),
                    trailing: StatusChip(p.s('status')),
                    onTap: () => push(context, ProjectScreen(projectId: p.id)),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

class ProjectFormScreen extends StatefulWidget {
  const ProjectFormScreen({super.key, this.customerId, this.projectId});
  final String? customerId, projectId;
  @override
  State<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends State<ProjectFormScreen> {
  final _title = TextEditingController();
  final _site = TextEditingController();
  String? _customerId;

  @override
  void initState() {
    super.initState();
    final db = context.db;
    final p = widget.projectId == null ? null : db.get('projects', widget.projectId);
    _customerId = p?.s('customer_id') ?? widget.customerId;
    _title.text = p?.s('title') ?? '';
    _site.text = p?.s('site_address') ?? (db.get('customers', _customerId)?.s('address') ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _site.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = context.db;
    if (_customerId == null) {
      toast(context, 'Choose a customer.', error: true);
      return;
    }
    String? id = widget.projectId;
    final ok = await attempt(context, () async {
      if (id == null) {
        id = createProject(db, customerId: _customerId!, title: _title.text, siteAddress: _site.text);
      } else {
        db.update('projects', id!, {'title': _title.text.trim(), 'site_address': _site.text.trim()});
      }
    });
    if (!ok || !mounted) return;
    if (widget.projectId == null) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ProjectScreen(projectId: id!)));
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    final customers = customersList(db);
    return Scaffold(
      appBar: AppBar(title: Text(widget.projectId == null ? 'New job' : 'Edit job')),
      body: PageBody(maxWidth: 700, children: [
        if (widget.projectId == null) ...[
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _customerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Customer'),
                items: [for (final c in customers) DropdownMenuItem(value: c.id, child: Text(c.s('name')))],
                onChanged: (v) => setState(() {
                  _customerId = v;
                  if (_site.text.isEmpty) _site.text = db.get('customers', v)?.s('address') ?? '';
                }),
              ),
            ),
            IconButton(
              tooltip: 'New customer',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () async {
                await push(context, const CustomerFormScreen());
                if (mounted) setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _title,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Job title',
            hintText: 'Kitchen remodel, Master bath vanity…',
            suffixIcon: PopupMenuButton<String>(
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (v) => _title.text = v,
              itemBuilder: (_) => [
                for (final t in const ['Kitchen', 'Bathroom vanity', 'Laundry room', 'Closet', 'Built-ins', 'Office'])
                  PopupMenuItem(value: t, child: Text(t)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(controller: _site, decoration: const InputDecoration(labelText: 'Job site address')),
        const SizedBox(height: 8),
        Muted(context.svc.isHub
            ? 'A job number (J-YYYY-###) is assigned automatically. Use it to name the 2020 file and folders.'
            : 'The job number is assigned by the office PC at the next sync. You can keep working offline.'),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _save, child: const Text('Save'))),
      ]),
    );
  }
}
