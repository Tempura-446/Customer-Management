import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logic.dart';
import '../../services.dart';
import '../widgets/common.dart';
import 'project_screen.dart';
import 'projects_screens.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => push(context, const CustomerFormScreen()),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('New customer'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, phone, email, address'),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: DbBuilder(
            db: db,
            builder: (context) {
              final list = customersList(db, query: _q);
              if (list.isEmpty) return const Center(child: Muted('No customers yet. Add your first one.'));
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final cu = list[i];
                  return ListTile(
                    leading: CircleAvatar(child: Text(cu.s('name').isEmpty ? '?' : cu.s('name')[0].toUpperCase())),
                    title: Text(cu.s('name')),
                    subtitle: Text([cu.s('phone'), cu.s('address')].where((s) => s.isNotEmpty).join(' · ')),
                    trailing: Muted('${cu.i('n_projects')} job${cu.i('n_projects') == 1 ? '' : 's'}'),
                    onTap: () => push(context, CustomerDetailScreen(customerId: cu.id)),
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

class CustomerFormScreen extends StatefulWidget {
  const CustomerFormScreen({super.key, this.customerId});
  final String? customerId;
  @override
  State<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends State<CustomerFormScreen> {
  final _f = <String, TextEditingController>{
    for (final k in ['name', 'phone', 'email', 'address', 'source', 'notes']) k: TextEditingController(),
  };
  bool _createJob = true;

  @override
  void initState() {
    super.initState();
    final c = widget.customerId == null ? null : context.db.get('customers', widget.customerId);
    if (c != null) {
      _f.forEach((k, ctl) => ctl.text = c.s(k));
    }
  }

  @override
  void dispose() {
    for (final c in _f.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final db = context.db;
    String? id;
    final ok = await attempt(context, () async {
      id = saveCustomer(db, {for (final e in _f.entries) e.key: e.value.text.trim()}, id: widget.customerId);
    });
    if (!ok || !mounted) return;
    if (widget.customerId == null && _createJob) {
      Navigator.pop(context);
      push(context, ProjectFormScreen(customerId: id));
    } else if (widget.customerId == null) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CustomerDetailScreen(customerId: id!)));
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String k, String label, {TextInputType? type, int lines = 1}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _f[k],
            keyboardType: type,
            maxLines: lines,
            textCapitalization: k == 'email' ? TextCapitalization.none : TextCapitalization.words,
            decoration: InputDecoration(labelText: label),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(widget.customerId == null ? 'New customer' : 'Edit customer')),
      body: PageBody(maxWidth: 700, children: [
        field('name', 'Name *'),
        TwoCol(
          left: field('phone', 'Phone', type: TextInputType.phone),
          right: field('email', 'Email', type: TextInputType.emailAddress),
        ),
        field('address', 'Address'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _f['source'],
            decoration: InputDecoration(
              labelText: 'Lead source',
              suffixIcon: PopupMenuButton<String>(
                icon: const Icon(Icons.arrow_drop_down),
                onSelected: (v) => _f['source']!.text = v,
                itemBuilder: (_) => [
                  for (final o in const ['Referral', 'Website', 'Showroom walk-in', 'Contractor', 'Repeat customer'])
                    PopupMenuItem(value: o, child: Text(o)),
                ],
              ),
            ),
          ),
        ),
        field('notes', 'Notes', lines: 3),
        if (widget.customerId == null)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _createJob,
            onChanged: (v) => setState(() => _createJob = v ?? true),
            title: const Text('Create a job for this customer next'),
          ),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _save, child: const Text('Save'))),
      ]),
    );
  }
}

class CustomerDetailScreen extends StatelessWidget {
  const CustomerDetailScreen({super.key, required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context) {
    final db = context.db;
    return DbBuilder(
      db: db,
      builder: (context) {
        final c = db.get('customers', customerId);
        if (c == null) return const Scaffold(body: Center(child: Text('Customer was deleted.')));
        final jobs = projectsList(db, customerId: customerId);
        return Scaffold(
          appBar: AppBar(title: Text(c.s('name')), actions: [
            IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => push(context, CustomerFormScreen(customerId: customerId))),
            PopupMenuButton<String>(
              onSelected: (_) async {
                if (await confirm(context, 'Delete ${c.s('name')} and ALL their jobs, quotes and invoices?',
                    ok: 'Delete', danger: true)) {
                  deleteCustomer(db, customerId);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              itemBuilder: (_) => [const PopupMenuItem(value: 'delete', child: Text('Delete customer'))],
            ),
          ]),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => push(context, ProjectFormScreen(customerId: customerId)),
            icon: const Icon(Icons.add),
            label: const Text('New job'),
          ),
          body: PageBody(children: [
            TwoCol(
              left: Section(
                title: 'Contact',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (c.ns('phone') != null)
                    _Link(Icons.phone_outlined, c.s('phone'), Uri(scheme: 'tel', path: c.s('phone'))),
                  if (c.ns('email') != null)
                    _Link(Icons.email_outlined, c.s('email'), Uri(scheme: 'mailto', path: c.s('email'))),
                  if (c.ns('address') != null)
                    _Link(Icons.place_outlined, c.s('address'),
                        Uri.parse('https://maps.google.com/?q=${Uri.encodeComponent(c.s('address'))}')),
                  const SizedBox(height: 6),
                  KeyValues([
                    if (c.ns('source') != null) ('Source', c.s('source')),
                    ('Since', fmtDate(c.s('created_at'))),
                  ]),
                  if (c.ns('notes') != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(c.s('notes'))),
                ]),
              ),
              right: Section(
                title: 'Jobs',
                child: jobs.isEmpty
                    ? const Muted('No jobs yet.')
                    : Column(children: [
                        for (final p in jobs)
                          ItemTile(
                            title: '${numberOf(p)} · ${p.s('title')}',
                            subtitle: p.ns('site_address'),
                            trailing: StatusChip(p.s('status')),
                            onTap: () => push(context, ProjectScreen(projectId: p.id)),
                          ),
                      ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.icon, this.text, this.uri);
  final IconData icon;
  final String text;
  final Uri uri;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => launchUrl(uri),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.primary))),
          ]),
        ),
      );
}
