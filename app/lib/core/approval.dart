/// Customer approval of the job packet: sent (by email or shared), then approved.
///
/// Stored on the job so every device sees it:
///   approval_sent_on / approval_sent_to   when and to whom the packet went
///   approved_on / approved_by             when and who approved (signed)
library;

import 'db.dart';
import 'logic.dart';

void markSentForApproval(AppDb db, String projectId, {String? to, String via = 'email'}) => db.tx(() {
      db.update('projects', projectId, {
        'approval_sent_on': today(),
        'approval_sent_to': (to ?? '').trim().isEmpty ? null : to!.trim(),
        // A new packet replaces any earlier approval: the customer must approve this version.
        'approved_on': null,
        'approved_by': null,
      });
      log(db, projectId, 'Job packet sent for approval${(to ?? '').trim().isEmpty ? '' : ' to ${to!.trim()}'} ($via)',
          kind: 'email');
    });

/// Record that the customer approved (signed) the packet. Optionally accepts a quote too.
void recordApproval(AppDb db, String projectId, {required String by, String? on, String? acceptQuoteId}) => db.tx(() {
      final name = by.trim();
      if (name.isEmpty) throw BusinessError('Enter who approved it.');
      final date = (on ?? '').trim().isEmpty ? today() : on!.trim();
      db.update('projects', projectId, {'approved_on': date, 'approved_by': name});
      log(db, projectId, 'Customer approval recorded: $name on $date');
      if (acceptQuoteId != null) acceptQuote(db, acceptQuoteId);
    });

void clearApproval(AppDb db, String projectId) => db.tx(() {
      db.update('projects', projectId, {'approved_on': null, 'approved_by': null});
      log(db, projectId, 'Customer approval removed');
    });

/// Jobs waiting for the customer's approval for longer than the quote follow-up setting.
List<Rec> approvalsWaiting(AppDb db, {int? olderThanDays}) {
  final days = olderThanDays ?? int.tryParse(settings(db)['quote_followup_days'] ?? '') ?? 7;
  final cutoff = dateOnly(DateTime.now().subtract(Duration(days: days)));
  return db.select('''
    SELECT p.*, c.name AS customer FROM projects p JOIN customers c ON c.id=p.customer_id
    WHERE p.deleted=0 AND p.approval_sent_on IS NOT NULL AND p.approved_on IS NULL
      AND p.approval_sent_on <= ? AND p.status NOT IN ('closed','lost')
    ORDER BY p.approval_sent_on''', [cutoff]);
}

/// The default email the packet goes out with.
(String, String) approvalEmailText(AppDb db, String projectId) {
  final p = projectWithCustomer(db, projectId)!;
  final s = settings(db);
  final business = (s['business_name'] ?? '').trim();
  final first = p.s('customer').split(' ').first;
  final subject = 'Your ${p.s('title').toLowerCase()} project ${numberOf(p)}: please review and approve';
  final body = 'Hi $first,\n\n'
      'Attached is the summary for your ${p.s('title').toLowerCase()} project: selections, measurements, drawings '
      'and price.\n\n'
      'Please look it over. If everything is right, sign the approval page and send it back (a photo of the signed '
      'page is fine), or reply to this email with any changes.\n\n'
      'Thank you,\n${business.isEmpty ? '' : business}'
      '${(s['business_phone'] ?? '').trim().isEmpty ? '' : '\n${s['business_phone']!.trim()}'}';
  return (subject, body);
}
