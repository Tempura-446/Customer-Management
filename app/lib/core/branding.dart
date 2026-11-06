/// The business logo, printed on every document (quotes, invoices, job packets, purchase orders)
/// and shown in the app. Stored as a shared setting so every PC and phone has it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'db.dart';
import 'logic.dart';

const _key = 'business_logo';

/// Logo as PNG bytes, or null when none is set.
Uint8List? businessLogo(Map<String, String> settings) {
  final b64 = settings[_key];
  if (b64 == null || b64.isEmpty) return null;
  try {
    return base64Decode(b64);
  } catch (_) {
    return null;
  }
}

/// Save a logo from an image file (PNG, JPG, GIF, BMP, WebP…). It is resized to at most
/// 900 x 360 px and stored as PNG (transparency kept). Throws BusinessError if it can't be read.
void setBusinessLogo(AppDb db, Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw BusinessError("That file isn't a picture Cabinet CRM can read. Use a PNG or JPG.");
  var im = decoded;
  if (im.width > 900 || im.height > 360) {
    final scale = [900 / im.width, 360 / im.height].reduce((a, b) => a < b ? a : b);
    im = img.copyResize(im, width: (im.width * scale).round(), height: (im.height * scale).round(),
        interpolation: img.Interpolation.average);
  }
  final png = img.encodePng(im, level: 9);
  setSetting(db, _key, base64Encode(png));
}

void removeBusinessLogo(AppDb db) => setSetting(db, _key, '');
