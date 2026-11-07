/// Sends email from the shared mailbox (Gmail: smtp.gmail.com with the same app password
/// the main office PC already uses to read measurement emails).
library;

import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

class OutgoingMail {
  OutgoingMail({
    required this.fromName,
    required this.fromEmail,
    required this.to,
    required this.subject,
    required this.text,
    this.attachments = const [],
  });
  final String fromName, fromEmail, subject, text;
  final List<String> to;
  final List<(String, Uint8List)> attachments; // (filename, PDF bytes)
}

/// Outgoing server for an incoming one: imap.gmail.com -> smtp.gmail.com, imap.x.com -> smtp.x.com.
String smtpHostFor(String imapHost) {
  final h = imapHost.trim().toLowerCase();
  if (h.startsWith('imap.')) return 'smtp.${h.substring(5)}';
  if (h.startsWith('mail.')) return h;
  return 'smtp.$h';
}

final _emailRe = RegExp(r'^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$');

/// Split "a@x.com, b@y.com; c@z.com" and check each address. Throws with a readable message.
List<String> parseRecipients(String raw) {
  final list = raw.split(RegExp(r'[,;\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (list.isEmpty) throw ArgumentError('Enter the customer\'s email address.');
  for (final e in list) {
    if (!_emailRe.hasMatch(e)) throw ArgumentError('"$e" is not an email address.');
  }
  return list;
}

MimeMessage buildMessage(OutgoingMail m) {
  final b = MessageBuilder.prepareMultipartMixedMessage()
    ..from = [MailAddress(m.fromName.isEmpty ? null : m.fromName, m.fromEmail)]
    ..to = [for (final t in m.to) MailAddress(null, t)]
    ..subject = m.subject
    ..addTextPlain(m.text);
  for (final (name, bytes) in m.attachments) {
    b.addBinary(bytes, MediaSubtype.applicationPdf.mediaType, filename: name);
  }
  return b.buildMimeMessage();
}

typedef MailSender = Future<void> Function(OutgoingMail m,
    {required String host, required int port, required String user, required String password});

/// Real sender: implicit TLS on 465, STARTTLS on 587/25.
Future<void> sendViaSmtp(OutgoingMail m,
    {required String host, required int port, required String user, required String password}) async {
  final client = SmtpClient('casework.local', isLogEnabled: false);
  final implicitTls = port == 465;
  await client.connectToServer(host, port, isSecure: implicitTls, timeout: const Duration(seconds: 20));
  try {
    await client.ehlo();
    if (!implicitTls) {
      await client.startTls();
      await client.ehlo();
    }
    try {
      await client.authenticate(user, password, AuthMechanism.login);
    } on SmtpException catch (e) {
      throw Exception('The mail server refused the sign-in (${e.message}). '
          'For Gmail, use the same app password as for reading measurement emails.');
    }
    await client.sendMessage(buildMessage(m));
  } finally {
    try {
      await client.quit();
    } catch (_) {}
  }
}
