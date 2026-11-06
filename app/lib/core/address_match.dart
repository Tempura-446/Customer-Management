/// Matches a street address typed in an email subject ("RE: 123 Main Street - measurements")
/// to the addresses stored on jobs and customers ("123 Main St, Springfield").
library;

const _suffixes = {
  'street': 'st', 'str': 'st', 'st': 'st',
  'avenue': 'ave', 'av': 'ave', 'ave': 'ave',
  'road': 'rd', 'rd': 'rd',
  'drive': 'dr', 'dr': 'dr',
  'lane': 'ln', 'ln': 'ln',
  'court': 'ct', 'crt': 'ct', 'ct': 'ct',
  'crescent': 'cres', 'cr': 'cres', 'cres': 'cres',
  'boulevard': 'blvd', 'blvd': 'blvd',
  'place': 'pl', 'pl': 'pl',
  'circle': 'cir', 'cir': 'cir',
  'terrace': 'ter', 'ter': 'ter',
  'highway': 'hwy', 'hwy': 'hwy',
  'parkway': 'pkwy', 'pkwy': 'pkwy',
  'trail': 'trl', 'trl': 'trl',
  'square': 'sq', 'sq': 'sq',
  'way': 'way', 'gate': 'gate', 'grove': 'grv', 'grv': 'grv',
  'heights': 'hts', 'hts': 'hts', 'point': 'pt', 'pt': 'pt',
};
const _directions = {
  'north': 'n', 'south': 's', 'east': 'e', 'west': 'w',
  'northeast': 'ne', 'northwest': 'nw', 'southeast': 'se', 'southwest': 'sw',
  'n': 'n', 's': 's', 'e': 'e', 'w': 'w', 'ne': 'ne', 'nw': 'nw', 'se': 'se', 'sw': 'sw',
};
const _noise = {
  're', 'fw', 'fwd', 'measure', 'measures', 'measurement', 'measurements', 'measured', 'site', 'onsite',
  'unit', 'apt', 'suite', 'ste', 'the', 'for', 'at', 'of', 'and', 'kitchen', 'bath', 'bathroom',
  'pdf', 'photos', 'pics', 'pictures',
};

/// Lower-case tokens with street words standardised.
List<String> addressTokens(String text) {
  final cleaned = text.toLowerCase().replaceAll(RegExp(r"['’]"), '').replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  final out = <String>[];
  for (var t in cleaned.split(' ')) {
    if (t.isEmpty) continue;
    t = _suffixes[t] ?? _directions[t] ?? t;
    // "123rd" style ordinals stay as-is; "2nd" etc. are street names, keep.
    out.add(t);
  }
  return out;
}

class ParsedAddress {
  ParsedAddress(this.number, this.street, this.suffix);

  /// House number, e.g. "123" or "12a".
  final String number;

  /// Street name words without suffix or direction, e.g. ["main"] or ["maple", "ridge"].
  final List<String> street;
  final String? suffix;

  @override
  String toString() => '$number ${street.join(' ')} ${suffix ?? ''}'.trim();
}

/// First "number + street name" found in [text], or null.
ParsedAddress? parseAddress(String text) {
  // "2-123 Main St" (unit-house) and "123-2 Main" both occur; split on hyphens between digits.
  final t = addressTokens(text.replaceAllMapped(RegExp(r'(\d)\s*-\s*(\d)'), (m) => '${m[1]} ${m[2]}'));
  for (var i = 0; i < t.length; i++) {
    if (!RegExp(r'^\d+[a-z]?$').hasMatch(t[i])) continue;
    // Skip a unit number directly followed by the house number.
    if (i + 1 < t.length && RegExp(r'^\d+[a-z]?$').hasMatch(t[i + 1])) continue;
    final street = <String>[];
    String? suffix;
    for (var j = i + 1; j < t.length && street.length < 4; j++) {
      final w = t[j];
      if (_suffixes.containsValue(w) && street.isNotEmpty) {
        suffix = w;
        break;
      }
      if (_directions.containsValue(w)) continue;
      if (RegExp(r'^\d+$').hasMatch(w) && street.isNotEmpty) break;
      if (_noise.contains(w)) {
        if (street.isEmpty) continue;
        break;
      }
      street.add(w);
    }
    if (street.isNotEmpty) return ParsedAddress(t[i], street, suffix);
  }
  return null;
}

/// How well [subject] matches the stored [address]: 0 = no match.
/// Needs the same house number and every street-name word; a matching suffix adds confidence.
int addressScore(String subject, String? address) {
  if (address == null || address.trim().isEmpty) return 0;
  final want = parseAddress(address);
  if (want == null) return 0;
  final subjectTokens = addressTokens(subject.replaceAllMapped(RegExp(r'(\d)\s*-\s*(\d)'), (m) => '${m[1]} ${m[2]}'));
  if (!subjectTokens.contains(want.number)) return 0;
  // The street words must appear right after the number (allowing a direction word).
  final at = subjectTokens.indexOf(want.number);
  final after = subjectTokens.skip(at + 1).where((w) => !_directions.containsValue(w)).take(want.street.length + 2).toList();
  if (!want.street.every(after.contains)) return 0;
  var score = 10 + want.street.length;
  if (want.suffix != null && after.contains(want.suffix)) score += 3;
  return score;
}
