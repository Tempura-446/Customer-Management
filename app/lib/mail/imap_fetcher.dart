/// Reads the shared measurement mailbox over IMAP (Gmail: imap.gmail.com, app password).
///
/// Messages are fetched with BODY.PEEK so nothing changes in the mailbox: emails stay
/// unread/read exactly as people left them.
library;

import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import 'mail_ingest.dart';

class MailConfig {
  MailConfig({required this.host, required this.port, required this.user, required this.password, this.folder = 'INBOX'});
  final String host, user, password, folder;
  final int port;
}

class FetchResult {
  FetchResult(this.messages, this.lastUid, this.uidValidity);
  final List<MailEnvelope> messages;
  final int? lastUid, uidValidity;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Fetch messages newer than [afterUid] (same [uidValidity]); on the first run,
/// messages received in the last [sinceDays] days.
Future<FetchResult> fetchNewMail(MailConfig c, {int? afterUid, int? uidValidity, int sinceDays = 14, int max = 200}) async {
  final client = ImapClient(isLogEnabled: false, defaultResponseTimeout: const Duration(seconds: 60));
  await client.connectToServer(c.host, c.port, isSecure: true, timeout: const Duration(seconds: 20));
  try {
    await client.login(c.user, c.password);
    final box = await client.selectMailboxByPath(c.folder);
    final sameBox = uidValidity != null && box.uidValidity == uidValidity && afterUid != null;
    String criteria;
    if (sameBox) {
      criteria = 'UID ${afterUid + 1}:*';
    } else {
      final d = DateTime.now().subtract(Duration(days: sinceDays));
      criteria = 'SINCE ${d.day}-${_months[d.month - 1]}-${d.year}';
    }
    final found = await client.uidSearchMessages(searchCriteria: criteria);
    var uids = (found.matchingSequence?.toList() ?? <int>[])..sort();
    if (sameBox) uids = uids.where((u) => u > afterUid).toList(); // "n:*" always returns the newest one
    if (uids.length > max) uids = uids.sublist(0, max); // oldest first; the rest next poll
    final out = <MailEnvelope>[];
    var last = sameBox ? afterUid : (uids.isEmpty ? (box.uidNext ?? 1) - 1 : null);
    for (var i = 0; i < uids.length; i += 10) {
      final chunk = uids.sublist(i, i + 10 > uids.length ? uids.length : i + 10);
      final res = await client.uidFetchMessages(MessageSequence.fromIds(chunk, isUid: true), 'BODY.PEEK[]');
      for (final m in res.messages) {
        out.add(envelopeFrom(m));
        if (m.uid != null && (last == null || m.uid! > last)) last = m.uid;
      }
    }
    return FetchResult(out, last, box.uidValidity);
  } finally {
    try {
      await client.logout();
    } catch (_) {}
  }
}

/// Check the sign-in works. Returns null when OK, otherwise a readable error.
Future<String?> testMailConnection(MailConfig c) async {
  final client = ImapClient(isLogEnabled: false);
  try {
    await client.connectToServer(c.host, c.port, isSecure: true, timeout: const Duration(seconds: 15));
    await client.login(c.user, c.password);
    await client.selectMailboxByPath(c.folder);
    return null;
  } on ImapException catch (e) {
    final msg = '${e.message ?? e}';
    if (msg.toLowerCase().contains('authenticat') || msg.toLowerCase().contains('credentials')) {
      return 'Gmail refused the sign-in. Use an app password (not the normal Gmail password) '
          'and make sure IMAP is allowed for this account.';
    }
    return msg;
  } catch (e) {
    return "Couldn't connect to ${c.host}: $e";
  } finally {
    try {
      await client.logout();
    } catch (_) {}
  }
}

/// Turn a parsed email into what the ingest step needs.
MailEnvelope envelopeFrom(MimeMessage m) {
  final from = m.from?.isNotEmpty == true
      ? (m.from!.first.personalName?.isNotEmpty == true
          ? '${m.from!.first.personalName} <${m.from!.first.email}>'
          : m.from!.first.email)
      : (m.getHeaderValue('from') ?? '');
  final date = m.decodeDate() ?? DateTime.now();
  final messageId = m.getHeaderValue('message-id')?.trim() ??
      'uid-${m.uid}-${date.millisecondsSinceEpoch}-${(m.decodeSubject() ?? '').hashCode}';
  var text = m.decodeTextPlainPart() ?? '';
  if (text.trim().isEmpty) {
    text = (m.decodeTextHtmlPart() ?? '')
        .replaceAll(RegExp(r'<(br|p|div)[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }
  final atts = <MailAttachment>[];
  final seen = <String>{};
  for (final (disposition, inline) in [(ContentDisposition.attachment, false), (ContentDisposition.inline, true)]) {
    for (final info in m.findContentInfo(disposition: disposition)) {
      if (!seen.add(info.fetchId)) continue;
      final part = m.getPart(info.fetchId);
      final Uint8List? bytes = part?.decodeContentBinary();
      if (bytes == null) continue;
      final mime = info.contentType?.mediaType.text;
      if (mime != null && mime.startsWith('text/') && info.fileName == null) continue;
      atts.add(MailAttachment(info.fileName ?? 'attachment-${atts.length + 1}${_ext(mime)}', bytes,
          mime: mime, inline: inline));
    }
  }
  return MailEnvelope(
    messageId: messageId,
    subject: m.decodeSubject() ?? '',
    from: from,
    date: date,
    text: text.trim(),
    attachments: atts,
  );
}

String _ext(String? mime) => switch (mime) {
      'application/pdf' => '.pdf',
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/heic' => '.heic',
      _ => '',
    };
