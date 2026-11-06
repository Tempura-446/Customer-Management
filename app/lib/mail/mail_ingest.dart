/// Files measurement emails (PDFs + photos sent to the shared mailbox) into the right job.
///
/// The main office PC reads the mailbox (see imap_fetcher.dart) and calls [ingestEmail]
/// for every new message. The subject is expected to contain the site address. When exactly
/// one job matches, the email becomes a measurement record on that job with the attachments.
/// Otherwise it waits in the Email inbox for someone to file it by hand.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/address_match.dart';
import '../core/db.dart';
import '../core/files.dart';
import '../core/logic.dart';

class MailAttachment {
  MailAttachment(this.name, this.bytes, {this.mime, this.inline = false});
  final String name;
  final Uint8List bytes;
  final String? mime;
  final bool inline;
}

class MailEnvelope {
  MailEnvelope({
    required this.messageId,
    required this.subject,
    required this.from,
    required this.date,
    this.text = '',
    this.attachments = const [],
  });
  final String messageId, subject, from;
  final DateTime date;
  final String text;
  final List<MailAttachment> attachments;
}

class MatchResult {
  MatchResult(this.projectId, this.note, {this.candidates = const []});
  final String? projectId;
  final String note;
  final List<String> candidates; // project ids worth suggesting
}

const _closed = {'closed', 'lost'};

/// Which job does this subject line refer to?
MatchResult matchProject(AppDb db, String subject) {
  final parsed = parseAddress(subject);
  if (parsed == null) return MatchResult(null, 'No street address found in the subject.');
  final scored = <(Rec, int)>[];
  for (final p in db.select('''SELECT p.*, c.name AS customer, c.address AS customer_address
                               FROM projects p JOIN customers c ON c.id=p.customer_id
                               WHERE p.deleted=0 AND c.deleted=0''')) {
    final s = [addressScore(subject, p.ns('site_address')), addressScore(subject, p.ns('customer_address'))]
        .reduce((a, b) => a > b ? a : b);
    if (s > 0) scored.add((p, s));
  }
  if (scored.isEmpty) {
    return MatchResult(null, 'No job found at "$parsed".');
  }
  final best = scored.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
  var top = scored.where((e) => e.$2 == best).map((e) => e.$1).toList();
  final open = top.where((p) => !_closed.contains(p.s('status'))).toList();
  if (open.isNotEmpty) top = open;
  final candidates = scored.map((e) => e.$1.id).toList();
  if (top.length == 1) {
    final p = top.first;
    return MatchResult(p.id, 'Matched "$parsed" to ${numberOf(p)} ${p.s('customer')}.', candidates: candidates);
  }
  // Same customer with several open jobs at that address: use the most recently active one.
  final customers = top.map((p) => p.s('customer_id')).toSet();
  if (customers.length == 1) {
    top.sort((a, b) => b.s('updated_at').compareTo(a.s('updated_at')));
    final p = top.first;
    return MatchResult(p.id, 'Matched "$parsed" to the most recent job ${numberOf(p)} ${p.s('customer')}.',
        candidates: candidates);
  }
  return MatchResult(null, '${top.length} different customers have a job at "$parsed". Choose one.',
      candidates: candidates);
}

bool _wanted(MailAttachment a) {
  final n = a.name.toLowerCase();
  final isPdf = n.endsWith('.pdf') || a.mime == 'application/pdf';
  final isImage = FileStore.isImage(n) || (a.mime ?? '').startsWith('image/');
  if (!isPdf && !isImage) return false;
  // Skip e-mail signature logos and similar tiny inline pictures.
  if (isImage && a.inline && a.bytes.length < 20 * 1024) return false;
  return a.bytes.isNotEmpty;
}

String _senderName(String from) {
  final m = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(from);
  return (m?.group(1) ?? from).trim();
}

List<Map<String, dynamic>> mailAttachments(Rec item) =>
    ((jsonDecode(item.ns('attachments') ?? '[]') as List).cast<Map<String, dynamic>>());

/// Store one email (main office PC). Returns the inbox row id, or null if it was skipped
/// (already seen, or no PDF/photo attached).
String? ingestEmail(AppDb db, FileStore files, MailEnvelope env) {
  if (db.one('SELECT 1 FROM mail_inbox WHERE message_id=?', [env.messageId]) != null) return null;
  final keep = env.attachments.where(_wanted).toList();
  if (keep.isEmpty) return null;
  final folder = '${dateOnly(env.date)} ${slug(env.subject)}';
  final atts = [
    for (final a in keep)
      {
        'name': a.name,
        'sha256': files.storeLoose(a.bytes, a.name, folder),
        'size': a.bytes.length,
        'mime': a.mime,
      }
  ];
  final match = matchProject(db, env.subject);
  return db.tx(() {
    final id = db.insert('mail_inbox', {
      'message_id': env.messageId,
      'subject': env.subject,
      'sender': env.from,
      'received_at': env.date.toUtc().toIso8601String(),
      'body': env.text.length > 4000 ? '${env.text.substring(0, 4000)}…' : env.text,
      'attachments': jsonEncode(atts),
      'status': 'unmatched',
      'note': match.note,
    });
    if (match.projectId != null) fileMailItem(db, files, id, match.projectId!, auto: true);
    return id;
  });
}

/// File an inbox email into [projectId] as a measurement with its attachments.
String fileMailItem(AppDb db, FileStore files, String itemId, String projectId, {bool auto = false}) {
  final item = db.get('mail_inbox', itemId)!;
  final p = projectWithCustomer(db, projectId)!;
  return db.tx(() {
    final received = DateTime.tryParse(item.s('received_at'))?.toLocal() ?? DateTime.now();
    final body = item.s('body').trim();
    final mid = saveMeasurement(db,
        projectId: projectId,
        room: 'Site measure (email)',
        source: 'onsite',
        takenBy: _senderName(item.s('sender')),
        takenOn: dateOnly(received),
        notes: 'From email: ${item.s('subject')}${body.isEmpty ? '' : '\n\n$body'}',
        lines: const []);
    for (final a in mailAttachments(item)) {
      final fid = db.insert('files', {
        'project_id': projectId, 'entity_type': 'measurement', 'entity_id': mid,
        'category': FileStore.isImage(a['name'] as String) ? 'photos' : 'measurements',
        'name': a['name'], 'size': a['size'], 'sha256': a['sha256'], 'mime': a['mime'],
      });
      if (db.isHub) files.copyIntoProject(fid);
    }
    db.update('mail_inbox', itemId, {
      'status': 'filed',
      'project_id': projectId,
      'measurement_id': mid,
      'note': auto ? item.s('note') : 'Filed by hand to ${numberOf(p)} ${p.s('customer')}.',
    });
    log(db, projectId,
        'Measurement email filed${auto ? ' automatically' : ''}: "${item.s('subject')}" from ${_senderName(item.s('sender'))}');
    return mid;
  });
}

/// Undo a filing (wrong job) and put the email back in the inbox, or straight into another job.
void unfileMailItem(AppDb db, String itemId, {String? note}) {
  final item = db.get('mail_inbox', itemId)!;
  final mid = item.ns('measurement_id');
  db.tx(() {
    if (mid != null) {
      for (final f in db.select("SELECT id FROM files WHERE entity_type='measurement' AND entity_id=? AND deleted=0", [mid])) {
        db.softDelete('files', f.id);
      }
      db.softDelete('measurements', mid);
      if (item.ns('project_id') != null) log(db, item.s('project_id'), 'Measurement email moved out: "${item.s('subject')}"');
    }
    db.update('mail_inbox', itemId,
        {'status': 'unmatched', 'project_id': null, 'measurement_id': null, 'note': note ?? 'Put back in the inbox.'});
  });
}

void moveMailItem(AppDb db, FileStore files, String itemId, String projectId) => db.tx(() {
      unfileMailItem(db, itemId);
      fileMailItem(db, files, itemId, projectId);
    });

void ignoreMailItem(AppDb db, String itemId) =>
    db.update('mail_inbox', itemId, {'status': 'ignored', 'note': 'Ignored.'});

/// No job yet for this address: create the customer + job from the email and file it there.
/// The address found in an inbox email's subject, tidied up ("230 Cedar Cres").
String mailAddress(Rec item) => _titleCase(parseAddress(item.s('subject'))?.toString() ?? item.s('subject'));

String createJobFromMail(AppDb db, FileStore files, String itemId,
    {required String customerName, String? phone, String title = 'Kitchen', String? address}) {
  final item = db.get('mail_inbox', itemId)!;
  final addr = (address ?? '').trim().isEmpty ? mailAddress(item) : address!.trim();
  return db.tx(() {
    final cid = saveCustomer(db, {'name': customerName, 'phone': phone, 'address': addr, 'source': 'Measurement email'});
    final pid = createProject(db, customerId: cid, title: title, siteAddress: addr);
    fileMailItem(db, files, itemId, pid);
    return pid;
  });
}

String _titleCase(String s) => s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

int unmatchedMailCount(AppDb db) =>
    db.scalar("SELECT COUNT(*) FROM mail_inbox WHERE status='unmatched' AND deleted=0") as int;
