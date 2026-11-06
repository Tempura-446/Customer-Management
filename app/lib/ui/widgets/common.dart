import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/branding.dart';
import '../../core/logic.dart';

final _money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
String fmtMoney(num v) => _money.format(v);
String fmtQty(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String fmtDate(String? iso) => (iso == null || iso.length < 10) ? '-' : iso.substring(0, 10);
String fmtDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return '-';
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? iso : DateFormat('yyyy-MM-dd HH:mm').format(d);
}

/// Wide layout (desktop / tablet landscape) vs. phone.
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;

Future<T?> push<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

void toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
  ));
}

/// Run an action; show BusinessError / other errors as a message instead of crashing.
Future<bool> attempt(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) toast(context, success);
    return true;
  } on BusinessError catch (e) {
    if (context.mounted) toast(context, e.message, error: true);
  } catch (e) {
    if (context.mounted) toast(context, '$e', error: true);
  }
  return false;
}

Future<bool> confirm(BuildContext context, String message, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Coloured pill for statuses (project stages, quote/invoice/design states).
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});
  final String status;
  final String? label;

  static (Color, Color) colors(String s, ColorScheme cs) {
    switch (s) {
      case 'accepted':
      case 'paid':
      case 'completed':
      case 'approved':
      case 'verified':
        return (const Color(0xFFE5F6EC), const Color(0xFF1F7A45));
      case 'draft':
      case 'not verified':
      case 'pending':
        return (const Color(0xFFFDF3E1), const Color(0xFF8A5A12));
      case 'sent':
      case 'presented':
      case 'quoted':
      case 'invoiced':
      case 'ordered':
      case 'received':
        return (const Color(0xFFE8EFFC), const Color(0xFF2357B8));
      case 'declined':
      case 'void':
      case 'lost':
        return (const Color(0xFFFDECEC), const Color(0xFFB02A2A));
      default:
        return (cs.surfaceContainerHighest, cs.onSurfaceVariant);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = colors(status, Theme.of(context).colorScheme);
    final text = label ?? (stageKeys.contains(status) ? stageLabel(status) : status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(text[0].toUpperCase() + text.substring(1),
          style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// A titled card section with an optional action button.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, this.action, required this.child, this.number, this.padding});
  final String title;
  final Widget? action;
  final Widget child;
  final int? number;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (number != null) ...[
                CircleAvatar(
                    radius: 11,
                    backgroundColor: cs.primary,
                    child: Text('$number', style: TextStyle(fontSize: 12, color: cs.onPrimary))),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?action,
            ]),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.size});
  final String text;
  final double? size;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: size));
}

/// Yellow (serious) or blue (info) banner.
class WarnBanner extends StatelessWidget {
  const WarnBanner(this.text, {super.key, this.serious = true});
  final String text;
  final bool serious;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: serious ? const Color(0xFFFDF3E1) : const Color(0xFFE8EFFC),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(serious ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 18, color: serious ? const Color(0xFF8A5A12) : const Color(0xFF2357B8)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF3A3A3A)))),
        ]),
      );
}

/// Label/value rows.
class KeyValues extends StatelessWidget {
  const KeyValues(this.items, {super.key});
  final List<(String, String)> items;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final (k, v) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 130, child: Muted(k)),
                Expanded(child: SelectableText(v)),
              ]),
            ),
        ],
      );
}

/// Tappable record row used inside sections.
class ItemTile extends StatelessWidget {
  const ItemTile(
      {super.key, required this.title, this.subtitle, this.trailing, this.onTap, this.dim = false, this.accent, this.below});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dim;

  /// Coloured stripe on the left (e.g. measurement source colour).
  final Color? accent;

  /// Extra widget under the subtitle (e.g. a badge).
  final Widget? below;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: dim ? 0.55 : 1,
        child: Card(
          margin: const EdgeInsets.only(bottom: 6),
          elevation: 0,
          shape: RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: accent == null
                ? null
                : BoxDecoration(border: Border(left: BorderSide(color: accent!, width: 5))),
            child: ListTile(
              dense: true,
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: subtitle == null && below == null
                  ? null
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (subtitle != null) Text(subtitle!),
                      if (below != null) Padding(padding: const EdgeInsets.only(top: 4), child: below!),
                    ]),
              trailing: trailing,
              onTap: onTap,
            ),
          ),
        ),
      );
}

/// Rebuilds whenever the database changes (local edit or sync).
class DbBuilder extends StatelessWidget {
  const DbBuilder({super.key, required this.db, required this.builder});
  final Listenable db;
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: db, builder: (c, _) => builder(c));
}

/// Simple date picker field storing yyyy-MM-dd.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final init = DateTime.tryParse(value ?? '') ?? DateTime.now();
          final d = await showDatePicker(
              context: context, initialDate: init, firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (d != null) onChanged(dateOnly(d));
        },
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_today, size: 18)),
          child: Text(value ?? '-'),
        ),
      );
}

/// Responsive two-column layout (stacks on phones).
class TwoCol extends StatelessWidget {
  const TwoCol({super.key, required this.left, required this.right, this.leftFlex = 1});
  final Widget left, right;
  final int leftFlex;
  @override
  Widget build(BuildContext context) => isWide(context)
      ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: leftFlex, child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ])
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, right]);
}

/// Page body with max width and padding, scrollable.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1200});
  final List<Widget> children;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: EdgeInsets.all(isWide(context) ? 20 : 12),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      );
}

/// Breadcrumb line: Customer › Job.
class Crumbs extends StatelessWidget {
  const Crumbs(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Muted(text, size: 12));
}

// ============================================================================ measurement sources

const _sourceIcons = <String, IconData>{
  'onsite': Icons.straighten,
  'customer': Icons.person_outline,
  'photo': Icons.photo_camera_outlined,
  'plans': Icons.architecture,
  'contractor': Icons.engineering_outlined,
  'previous': Icons.history,
  'other': Icons.help_outline,
};

IconData sourceIcon(String? key) => _sourceIcons[key] ?? Icons.help_outline;
Color sourceColor(String? key) => Color(sourceOf(key).color);

/// Colour-coded badge: where the measurements came from, and whether they've been verified on site.
class SourceChip extends StatelessWidget {
  const SourceChip(this.source, {super.key, this.verified = false, this.verifiedOn, this.long = false});
  final String? source;
  final bool verified;
  final String? verifiedOn;
  final bool long;

  @override
  Widget build(BuildContext context) {
    final src = sourceOf(source);
    final c = Color(src.color);
    final checked = src.needsVerify && verified;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(sourceIcon(src.key), size: 14, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(long ? src.label : src.short,
              overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
        if (src.needsVerify) ...[
          const SizedBox(width: 6),
          Icon(checked ? Icons.verified : Icons.error_outline, size: 14,
              color: checked ? const Color(0xFF1F7A45) : const Color(0xFFB02A2A)),
          if (long || !checked)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(checked ? 'verified${verifiedOn != null ? ' $verifiedOn' : ''}' : 'not verified',
                  style: TextStyle(
                      fontSize: 11, color: checked ? const Color(0xFF1F7A45) : const Color(0xFFB02A2A))),
            ),
        ],
      ]),
    );
  }
}

/// Small legend of all measurement sources and their colours.
class SourceLegend extends StatelessWidget {
  const SourceLegend({super.key});
  @override
  Widget build(BuildContext context) => Wrap(spacing: 10, runSpacing: 4, children: [
        for (final s in measurementSources)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: Color(s.color), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(s.short, style: const TextStyle(fontSize: 11)),
          ]),
      ]);
}

// ============================================================================ order types

const _orderIcons = <String, IconData>{
  'pickup': Icons.storefront_outlined,
  'shipping': Icons.local_shipping_outlined,
  'install': Icons.handyman_outlined,
};

IconData orderTypeIcon(String? key) => _orderIcons[key] ?? Icons.help_outline;
Color orderTypeColor(String? key) => Color(orderTypeOf(key)?.color ?? 0xFF6B7385);

/// Colour-coded badge for the job's order type (pickup / shipping / installation).
class OrderTypeChip extends StatelessWidget {
  const OrderTypeChip(this.orderType, {super.key, this.long = false});
  final String? orderType;
  final bool long;

  @override
  Widget build(BuildContext context) {
    final ot = orderTypeOf(orderType);
    final c = orderTypeColor(orderType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(orderTypeIcon(orderType), size: 14, color: c),
        const SizedBox(width: 4),
        Text(ot == null ? 'Order type?' : (long ? ot.label : ot.short),
            style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// Choice chips to pick the order type (or "not decided").
class OrderTypePicker extends StatelessWidget {
  const OrderTypePicker({super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String? key, String label, Color c, IconData icon) => ChoiceChip(
          avatar: Icon(icon, size: 18, color: value == key ? Colors.white : c),
          label: Text(label),
          selected: value == key,
          showCheckmark: false,
          selectedColor: c,
          labelStyle: TextStyle(color: value == key ? Colors.white : c, fontWeight: FontWeight.w600),
          side: BorderSide(color: c.withValues(alpha: 0.6)),
          backgroundColor: c.withValues(alpha: 0.08),
          onSelected: (_) => onChanged(key),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final o in orderTypes) chip(o.key, o.label, Color(o.color), orderTypeIcon(o.key)),
        chip(null, 'Not decided yet', const Color(0xFF6B7385), Icons.help_outline),
      ]),
      if (orderTypeOf(value) case final ot?)
        Padding(padding: const EdgeInsets.only(top: 6), child: Muted(ot.hint, size: 12)),
    ]);
  }
}

// ============================================================================ logo

/// The business logo from Settings (or a cabinet icon when none is set).
class BusinessLogo extends StatelessWidget {
  const BusinessLogo({super.key, required this.settings, this.height = 40, this.maxWidth = 160});
  final Map<String, String> settings;
  final double height, maxWidth;

  @override
  Widget build(BuildContext context) {
    final logo = businessLogo(settings);
    if (logo == null) return Icon(Icons.kitchen, size: height);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height, maxWidth: maxWidth),
      child: Image.memory(logo, fit: BoxFit.contain, gaplessPlayback: true,
          errorBuilder: (_, _, _) => Icon(Icons.kitchen, size: height)),
    );
  }
}
