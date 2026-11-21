// Text helpers that mirror the official library builder (SeforimLibrary).

/// Heading level (1-6) of a line that starts with `<h1`..`<h6`, else 0.
int headingLevel(String line) {
  if (line.length < 3 || line[0] != '<') return 0;
  final h = line[1];
  if (h != 'h' && h != 'H') return 0;
  final digit = line.codeUnitAt(2) - 0x30;
  return digit >= 1 && digit <= 6 ? digit : 0;
}

final RegExp _tag = RegExp(r'<[^>]*>');
final RegExp _spaces = RegExp(r'\s+');

const Map<String, String> _entities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
};

/// Visible text of an HTML snippet: tags removed, common entities decoded,
/// whitespace collapsed.
String stripHtml(String html) {
  var s = html.replaceAll(_tag, '');
  _entities.forEach((k, v) => s = s.replaceAll(k, v));
  return s.replaceAll(_spaces, ' ').trim();
}

/// TOC entry text, as the official builder stores it: no tags, maqaf as a
/// space, without points and cantillation.
String tocText(String headingHtml) {
  final s = stripHtml(
    headingHtml,
  ).replaceAll('־', ' ').replaceAll(RegExp('[֑-ׇ]'), '');
  return s.replaceAll(_spaces, ' ').trim();
}

/// Visible-char count of `html[0, endExclusive)`: a tag counts 0, an
/// `&...;` entity counts 1. Port of HtmlCharCounter.kt.
int countVisibleChars(String html, [int? endExclusive]) {
  final len = endExclusive == null
      ? html.length
      : (endExclusive < html.length ? endExclusive : html.length);
  if (html.isEmpty || len <= 0) return 0;
  var count = 0;
  var inTag = false;
  var i = 0;
  while (i < len) {
    final c = html[i];
    if (inTag) {
      if (c == '>') inTag = false;
    } else if (c == '<') {
      inTag = true;
    } else if (c == '&') {
      final end = len < i + 10 ? len : i + 10;
      var j = i + 1;
      var terminated = false;
      while (j < end) {
        if (html[j] == ';') {
          terminated = true;
          break;
        }
        j++;
      }
      count++;
      if (terminated) i = j;
    } else {
      count++;
    }
    i++;
  }
  return count;
}

const String _edgePunctuation = '.,:;?!()[]';

/// Canonical dibbur-hamatchil key (`line_dh.dhText`). Port of DhKey.kt.
String? dhKey(String raw) {
  var s = raw.replaceAll('־', ' ').replaceAll('׀', ' ').replaceAll('|', ' ');
  s = s.replaceAll(RegExp('[֑-ׇ]'), '');
  s = s
      .replaceAll('"', '')
      .replaceAll("'", '')
      .replaceAll('״', '')
      .replaceAll('׳', '');
  s = s.replaceAll(_spaces, ' ').trim();
  var start = 0;
  var end = s.length;
  bool trim(String c) => _edgePunctuation.contains(c) || c == ' ';
  while (start < end && trim(s[start])) {
    start++;
  }
  while (end > start && trim(s[end - 1])) {
    end--;
  }
  s = s.substring(start, end);
  return s.length >= 2 ? s : null;
}

final RegExp _leadingBold = RegExp(
  r'^\s*<(b|strong)>(.*?)</\1>',
  caseSensitive: false,
);

/// The bold run at the start of a line (the usual dibbur-hamatchil print
/// convention), as visible text; null when the line does not open in bold.
String? leadingBoldText(String line) {
  final m = _leadingBold.firstMatch(line);
  if (m == null) return null;
  final text = stripHtml(m[2]!);
  return text.isEmpty ? null : text;
}

bool hasNekudot(String s) => RegExp('[ְ-ׇּׁׂ]').hasMatch(s);

bool hasTeamim(String s) => RegExp('[֑-֯]').hasMatch(s);

/// FNV-1a 64-bit over UTF-16 code units, signed. Only needs to be stable for
/// this builder: the app compares a book's value with the one it indexed.
int fnv64(Iterable<String> parts) {
  var hash = -3750763034362895579;
  for (final part in parts) {
    for (var i = 0; i < part.length; i++) {
      final c = part.codeUnitAt(i);
      hash = (hash ^ (c & 0xFF)) * 1099511628211;
      hash = (hash ^ (c >> 8)) * 1099511628211;
    }
    hash = (hash ^ 0x0A) * 1099511628211;
  }
  return hash == 0 ? 1 : hash;
}
