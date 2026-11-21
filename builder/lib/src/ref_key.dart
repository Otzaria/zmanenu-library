// Port of the line_ref key rules of the Otzaria app (lib/utils/text/ref_key.dart
// and removeVolwels/removeTeamim in lib/utils/text/text_manipulation.dart).
// Any drift produces silent FindRef misses, so test/ref_key_test.dart checks this
// port against the app's own fixture file (test/fixtures/ref_key_fixtures.json).

import 'dart:convert';
import 'dart:typed_data';

const Set<String> _locatorWords = {
  'פרק',
  'פסוק',
  'פסקה',
  'סעיף',
  'סימן',
  'הלכה',
  'משנה',
  'מאמר',
  'דף',
  'עמוד',
  'אות',
};

final RegExp _nonLatin1 = RegExp(r'[Ā-￿]');

/// Maqaf, paseq and `|` become spaces; points and cantillation are removed.
String removeVolwels(String s) {
  if (!_nonLatin1.hasMatch(s)) return s.replaceAll('|', ' ');
  var firstChange = 0;
  while (firstChange < s.length) {
    final c = s.codeUnitAt(firstChange);
    if (c == 0x7C || (c >= 0x0591 && c <= 0x05C7)) break;
    firstChange++;
  }
  if (firstChange == s.length) return s;
  final units = Uint16List(s.length);
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x05BE || c == 0x05C0 || c == 0x7C) {
      units[n++] = 0x20;
    } else if (c < 0x0591 || c > 0x05C7) {
      units[n++] = c;
    }
  }
  return String.fromCharCodes(units, 0, n);
}

bool _isTeamimMark(int c) =>
    (c >= 0x0591 && c <= 0x05AF) || c == 0x05BD || c == 0x05BE || c == 0x05C0;

String removeTeamim(String s) {
  if (!_nonLatin1.hasMatch(s)) return s;
  var firstChange = 0;
  while (firstChange < s.length && !_isTeamimMark(s.codeUnitAt(firstChange))) {
    firstChange++;
  }
  if (firstChange == s.length) return s;
  final units = Uint16List(s.length);
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x05BE) {
      units[n++] = 0x20;
    } else if (c == 0x05C0) {
      final prev = i > 0 ? s.codeUnitAt(i - 1) : 0;
      if (prev == 0x20 || prev == 0x05BE) n--;
    } else if (c != 0x05BD && (c < 0x0591 || c > 0x05AF)) {
      units[n++] = c;
    }
  }
  return String.fromCharCodes(units, 0, n);
}

String _expandDafMarks(String s) => s
    .replaceAllMapped(
      RegExp(r'''(?<![א-ת'"״׳])([א-ת]{1,3})\.(?=[,\s]|$)'''),
      (m) => '${m[1]} א',
    )
    .replaceAllMapped(
      RegExp(r'''(?<![א-ת'"״׳])([א-ת]{1,3}):(?=[,\s]|$)'''),
      (m) => '${m[1]} ב',
    );

final RegExp _trailingRange = RegExp(
  '''(?:^|[\\s,.:])(?:\\d+|[א-ת]{1,3}(?:["'״׳][א-ת]{1,2})?)[.:]?\\s*([-–־])\\s*'''
  '''(?:\\d+|[א-ת]{1,3}(?:["'״׳][א-ת]{1,2})?)[.:]?\\s*\$''',
);

final RegExp _amudA = RegExp('''(?<![א-ת])ע["'״׳]א(?![א-ת])''');
final RegExp _amudB = RegExp('''(?<![א-ת])ע["'״׳]ב(?![א-ת])''');

bool _mayHaveRangeOrDafMark(String ref) =>
    ref.contains('-') ||
    ref.contains('–') ||
    ref.contains('־') ||
    ref.contains('.') ||
    ref.contains(':');

List<String> refKeyTokens(String ref) {
  final marked = _mayHaveRangeOrDafMark(ref);
  final range = marked ? _trailingRange.firstMatch(ref) : null;
  final dash = range == null ? -1 : ref.indexOf(RegExp('[-–־]'), range.start);
  final head = dash > 0 ? ref.substring(0, dash) : ref;

  var cleaned = removeTeamim(
    removeVolwels(marked ? _expandDafMarks(head) : head),
  );
  cleaned = cleaned.replaceAll(_amudA, 'א').replaceAll(_amudB, 'ב');
  cleaned = cleaned
      .replaceAll('"', '')
      .replaceAll("'", '')
      .replaceAll('״', '')
      .replaceAll('׳', '');
  final tokens = <String>[];
  var start = -1;
  for (var i = 0; i <= cleaned.length; i++) {
    if (i < cleaned.length && _isRefKeyChar(cleaned.codeUnitAt(i))) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      final token = cleaned.substring(start, i).toLowerCase();
      if (!_locatorWords.contains(token)) tokens.add(token);
      start = -1;
    }
  }
  return tokens;
}

bool _isRefKeyChar(int c) =>
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0x41 && c <= 0x5A) ||
    _isAsciiDigit(c) ||
    (c >= 0x0590 && c <= 0x05FF);

String? buildRefKey(String ref) {
  final tokens = refKeyTokens(ref);
  return tokens.isEmpty ? null : tokens.join(' ');
}

String? buildLineRefKey(String heRef, Iterable<String> titleAliases) {
  final suffix = _suffixAfterTitleAlias(heRef, titleAliases);
  if (suffix != null) return buildRefKey(suffix);

  final tokens = refKeyTokens(heRef);
  if (tokens.isEmpty) return null;

  List<String>? longestMatch;
  for (final alias in titleAliases) {
    final aliasTokens = refKeyTokens(alias);
    if (aliasTokens.isEmpty || aliasTokens.length > tokens.length) continue;
    var matches = true;
    for (var i = 0; i < aliasTokens.length; i++) {
      if (tokens[i] != aliasTokens[i]) {
        matches = false;
        break;
      }
    }
    if (matches && aliasTokens.length > (longestMatch?.length ?? 0)) {
      longestMatch = aliasTokens;
    }
  }
  if (longestMatch == null) return tokens.join(' ');
  if (longestMatch.length == tokens.length) return null;
  return tokens.sublist(longestMatch.length).join(' ');
}

/// Hashes of the full key and of the partial keys of one line; empty when
/// the line has no key.
List<int> lineRefKeyHashes(String heRef, String bookTitle) => [
  if (buildLineRefKey(heRef, [bookTitle]) case final key?) ...[
    refKeyHash(key),
    for (final partial in partialLineRefKeys(heRef, [bookTitle]))
      refKeyHash(partial),
  ],
];

const String partialRefKeyMarker = '~';

String? buildPartialRefKey(String ref) {
  final key = buildRefKey(ref);
  return key == null ? null : '$partialRefKeyMarker $key';
}

List<String> partialLineRefKeys(String heRef, Iterable<String> titleAliases) {
  final suffix = _suffixAfterTitleAlias(heRef, titleAliases);
  if (suffix == null) return const [];
  final components = suffix
      .split(',')
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  final named = components.indexWhere(_isNumeralComponent);
  if (named <= 0 || components.length - named < 2) return const [];
  for (var i = named + 1; i < components.length; i++) {
    if (!_isNumeralComponent(components[i])) return const [];
  }
  final keys = <String>[];
  for (var omitted = 1; omitted <= named; omitted++) {
    final key = buildPartialRefKey(components.sublist(omitted).join(', '));
    if (key != null && !keys.contains(key)) keys.add(key);
  }
  return keys;
}

const List<int> _numeralValues = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, //
  10, 0, 20, 30, 0, 40, 0, 50, 60, 70, 0, 80, 0, 90, //
  100, 200, 300, 400,
];

bool _isNumeralComponent(String component) {
  final tokens = refKeyTokens(component);
  return tokens.isNotEmpty && tokens.every(_isNumeralToken);
}

bool _isNumeralToken(String token) {
  if (token.isEmpty) return true;
  if (_isAsciiDigit(token.codeUnitAt(0))) {
    for (var i = 1; i < token.length; i++) {
      if (!_isAsciiDigit(token.codeUnitAt(i))) return false;
    }
    return true;
  }
  if (token.length > 6) return false;
  var previous = 400;
  for (var i = 0; i < token.length; i++) {
    final index = token.codeUnitAt(i) - 0x05D0;
    if (index < 0 || index >= _numeralValues.length) return false;
    final value = _numeralValues[index];
    if (value == 0 || value > previous) return false;
    previous = value;
  }
  return true;
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

String? _suffixAfterTitleAlias(String heRef, Iterable<String> titleAliases) {
  String? longestMatch;
  for (final alias in titleAliases) {
    if (alias.trim().isEmpty ||
        alias.length <= (longestMatch?.length ?? 0) ||
        !heRef.startsWith(alias)) {
      continue;
    }
    if (heRef.length > alias.length &&
        _isLetterOrDigit(heRef.codeUnitAt(alias.length))) {
      continue;
    }
    longestMatch = alias;
  }
  return longestMatch == null ? null : heRef.substring(longestMatch.length);
}

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);

bool _isLetterOrDigit(int codeUnit) =>
    _letterOrDigit.hasMatch(String.fromCharCode(codeUnit));

/// FNV-1a 64-bit over the UTF-8 bytes, as a signed value (line_ref.refKeyHash).
int refKeyHash(String refKey) {
  var hash = -3750763034362895579;
  for (final byte in utf8.encode(refKey)) {
    hash = (hash ^ byte) * 1099511628211;
  }
  return hash;
}
