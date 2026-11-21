import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'issues.dart';
import 'model.dart';
import 'text_utils.dart';

/// Files that Windows and Explorer drop into folders; never part of the source.
bool isIgnoredSystemFile(String name) {
  final lower = name.toLowerCase();
  return lower == 'desktop.ini' || lower == 'thumbs.db';
}

/// Extensions of the text files the source tree may hold. Anything else
/// (PDF, DOCX, images...) is an error: the database holds text books only.
const Set<String> kTextExtensions = {'txt', 'json', 'csv', 'md'};

/// Top-level folders that have their own checks.
const Set<String> _knownDirs = {'books', 'links', 'alt_toc', 'editions'};

const Set<String> _metadataKeys = {
  'heShortDesc',
  'heDesc',
  'author',
  'authors',
  'order',
  'pubDate',
  'pubPlace',
  'generation',
  'acronyms',
  'renamedFrom',
  'topics',
  'dibburHamatchil',
  'isBaseBook',
};

/// Maps a connection type as written in Otzaria links files to the
/// `connection_type.name` the app reads. Port of ConnectionType.fromString.
String? connectionTypeName(String? raw) {
  final v = (raw ?? '').trim().toLowerCase().replaceAll(' ', '_');
  if (v.startsWith('quotation')) return 'QUOTATION';
  if (v.startsWith('ein_mishpat')) return 'EIN_MISHPAT';
  return switch (v) {
    'commentary' => 'COMMENTARY',
    'super_commentary' => 'SUPER_COMMENTARY',
    'targum' => 'TARGUM',
    'reference' => 'REFERENCE',
    'source' => 'SOURCE',
    'midrash' => 'MIDRASH',
    'mesorat_hashas' => 'MESORAT_HASHAS',
    'dibur_hamatchil' => 'DIBUR_HAMATCHIL',
    'parshanut' => 'PARSHANUT',
    'mishnah_in_talmud' => 'MISHNAH_IN_TALMUD',
    'related' || 'related_passage' => 'RELATED',
    'footnote' || 'footnotes' => 'FOOTNOTES',
    'sifrei_mitzvot' => 'SIFREI_MITZVOT',
    'essay' => 'ESSAY',
    'allusion' => 'ALLUSION',
    'liturgy' => 'LITURGY',
    'elucidation' => 'ELUCIDATION',
    'explication' => 'EXPLICATION',
    'law' => 'LAW',
    'summary' => 'SUMMARY',
    'linker' => null,
    _ => 'OTHER',
  };
}

/// Reads and validates the source tree under [root]. Every problem is added
/// to [issues]; the caller stops when [Issues.hasErrors].
LibrarySource readSource(String root, LibraryConfig config, Issues issues) {
  final reader = _Reader(root, config, issues);
  reader.run();
  return reader.out;
}

class _Reader {
  _Reader(this.root, this.config, this.issues);

  final String root;
  final LibraryConfig config;
  final Issues issues;
  final LibrarySource out = LibrarySource();
  final Map<String, BookSource> _byTitle = {};
  final Map<String, CategoryNode> _categories = {};

  String _rel(String path) =>
      p.relative(path, from: root).replaceAll(r'\', '/');

  void run() {
    final booksDir = Directory(p.join(root, 'books'));
    if (!booksDir.existsSync()) {
      issues.error('books/', 'התיקייה חסרה.');
      return;
    }
    _walk(booksDir, const []);
    _scanOtherFiles(Directory(root));
    _readCategoriesJson();
    _readMetadata();
    _readLinks();
    _readAltToc();
    _readVersions();
    _readEditions();
    _readDefaults('default_commentators.json', 'commentators', true);
    _readDefaults('default_targumim.json', 'targumim', false);
  }

  // ---- books/ ------------------------------------------------------------

  void _walk(Directory dir, List<String> path) {
    final entries = dir.listSync()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || isIgnoredSystemFile(name)) continue;
      if (entity is Directory) {
        final childPath = [...path, name.trim()];
        if (name.trim() != name || name.trim().isEmpty) {
          issues.error(_rel(entity.path), 'שם תיקייה עם רווח בהתחלה או בסוף.');
        }
        final node = CategoryNode(childPath);
        _categories[node.key] = node;
        out.categories.add(node);
        _walk(entity, childPath);
      } else if (entity is File) {
        _readBookFile(entity, path);
      }
    }
  }

  void _readBookFile(File file, List<String> categoryPath) {
    final rel = _rel(file.path);
    final name = p.basename(file.path);
    if (name == 'README.md') return;
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    final title = p.basenameWithoutExtension(name).trim();
    if (ext != 'txt') {
      issues.error(
        rel,
        'רק ספרי טקסט (.txt) נתמכים במסד הזה; קובץ ".$ext" אינו ספר טקסט.',
      );
      return;
    }
    if (categoryPath.isEmpty) {
      issues.error(
        rel,
        'ספר ישירות תחת books/ — יש לשים כל ספר בתוך תיקייה (קטגוריה).',
      );
      return;
    }
    if (title.isEmpty) {
      issues.error(rel, 'שם קובץ ריק.');
      return;
    }
    final existing = _byTitle[title];
    if (existing != null) {
      issues.error(
        rel,
        'כותרת כפולה "$title" — כבר קיימת ב-${existing.relPath}. '
        'כותרות חייבות להיות ייחודיות במסד (קישורים, גרסאות ומטא-דאטה נקשרים לפי כותרת).',
      );
      return;
    }
    final book = BookSource(
      title: title,
      categoryPath: categoryPath,
      relPath: rel,
      absPath: file.path,
    );
    _readLines(book, file);
    book.topics = categoryPath.length <= 2
        ? categoryPath
        : categoryPath.sublist(categoryPath.length - 2);
    _byTitle[title] = book;
    out.books.add(book);
  }

  /// Files outside the folders that have their own checks: only text files.
  void _scanOtherFiles(Directory dir) {
    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || isIgnoredSystemFile(name)) continue;
      if (entity is Directory) {
        if (dir.path == root && _knownDirs.contains(name)) continue;
        _scanOtherFiles(entity);
      } else if (entity is File) {
        final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
        if (!kTextExtensions.contains(ext)) {
          issues.error(
            _rel(entity.path),
            'קובץ שאינו טקסט ("$name"). במקור מותרים רק קובצי '
            '${kTextExtensions.map((e) => '.$e').join(', ')}.',
          );
        }
      }
    }
  }

  void _readLines(BookSource book, File file) {
    String text;
    try {
      text = utf8.decode(file.readAsBytesSync());
    } on FormatException {
      issues.error(book.relPath, 'הקובץ אינו UTF-8 תקין.');
      return;
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final lines = text
        .split('\n')
        .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
        .toList();
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (text.contains('\u0000')) {
      issues.error(book.relPath, 'קובץ בינארי, לא טקסט (יש בו תו NUL).');
      return;
    }
    if (lines.every((l) => l.trim().isEmpty)) {
      issues.error(book.relPath, 'קובץ ריק.');
      return;
    }
    final headings = <Heading>[];
    for (var i = 0; i < lines.length; i++) {
      final level = headingLevel(lines[i]);
      if (level == 0) continue;
      final text = tocText(lines[i]);
      if (text.isEmpty) {
        issues.error('${book.relPath}:${i + 1}', 'כותרת <h$level> ריקה.');
        continue;
      }
      headings.add(Heading(i, level, text));
    }
    book.lines = lines;
    book.headings = headings;
    book.headingLines = {for (final h in headings) h.lineIndex};
  }

  // ---- JSON helpers --------------------------------------------------------

  Object? _json(String relPath) {
    final file = File(p.join(root, relPath));
    if (!file.existsSync()) return null;
    try {
      var text = file.readAsStringSync();
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } on FormatException catch (e) {
      issues.error(relPath, 'JSON לא תקין: ${e.message}');
      return null;
    }
  }

  String? _str(Object? v, String where, String key) {
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v.trim();
    if (v is num) return v.toString();
    issues.error(where, '"$key" צריך להיות מחרוזת.');
    return null;
  }

  List<String> _strList(Object? v, String where, String key) {
    if (v == null) return const [];
    if (v is String) return v.trim().isEmpty ? const [] : [v.trim()];
    if (v is List) {
      final result = <String>[];
      for (final item in v) {
        if (item is String && item.trim().isNotEmpty) {
          result.add(item.trim());
        } else {
          issues.error(where, '"$key" צריך להיות רשימת מחרוזות לא ריקות.');
        }
      }
      return result;
    }
    issues.error(where, '"$key" צריך להיות מחרוזת או רשימת מחרוזות.');
    return const [];
  }

  int? _int(Object? v, String where, String key) {
    if (v == null) return null;
    if (v is num && v == v.roundToDouble()) return v.toInt();
    issues.error(where, '"$key" צריך להיות מספר שלם.');
    return null;
  }

  BookSource? _book(String title, String where) {
    final book = _byTitle[title.trim()];
    if (book == null) {
      issues.error(where, 'אין ספר בשם "$title" בתיקיית books/.');
      return null;
    }
    return book;
  }

  // ---- categories.json / metadata.json -------------------------------------

  void _readCategoriesJson() {
    const where = 'categories.json';
    final json = _json(where);
    if (json == null) return;
    if (json is! Map<String, dynamic>) {
      issues.error(where, 'צריך להיות אובייקט: { "נתיב/קטגוריה": {...} }.');
      return;
    }
    json.forEach((key, value) {
      final at = '$where: "$key"';
      final node = _categories[key.trim().replaceAll(r'\', '/')];
      if (node == null) {
        issues.error(at, 'אין תיקייה books/$key.');
        return;
      }
      if (value is! Map<String, dynamic>) {
        issues.error(at, 'צריך להיות אובייקט.');
        return;
      }
      for (final k in value.keys) {
        if (!const {'order', 'heShortDesc', 'heDesc'}.contains(k)) {
          issues.error(at, 'מפתח לא מוכר "$k" (order, heShortDesc, heDesc).');
        }
      }
      node.order = _int(value['order'], at, 'order') ?? 999;
      node.heShortDesc = _str(value['heShortDesc'], at, 'heShortDesc');
      node.heDesc = _str(value['heDesc'], at, 'heDesc');
    });
  }

  void _readMetadata() {
    const where = 'metadata.json';
    final json = _json(where);
    final entries = <String, Map<String, dynamic>>{};
    if (json is Map<String, dynamic>) {
      json.forEach((title, value) {
        if (value is Map<String, dynamic>) {
          entries[title.trim()] = value;
        } else {
          issues.error('$where: "$title"', 'צריך להיות אובייקט.');
        }
      });
    } else if (json is List) {
      for (final value in json) {
        final title = value is Map<String, dynamic> ? value['title'] : null;
        if (title is String && title.trim().isNotEmpty) {
          entries[title.trim()] = value as Map<String, dynamic>;
        } else {
          issues.error(where, 'רשומה בלי "title".');
        }
      }
    } else if (json != null) {
      issues.error(where, 'צריך להיות אובייקט לפי כותרת (או מערך עם "title").');
    }
    final renamedFrom = <String, String>{};
    entries.forEach((title, meta) {
      final at = '$where: "$title"';
      final book = _book(title, at);
      if (book == null) return;
      for (final k in meta.keys) {
        if (k != 'title' && !_metadataKeys.contains(k)) {
          issues.error(at, 'מפתח לא מוכר "$k" (${_metadataKeys.join(', ')}).');
        }
      }
      book.heShortDesc = _str(meta['heShortDesc'], at, 'heShortDesc');
      book.heDesc = _str(meta['heDesc'], at, 'heDesc');
      book.authors = {
        ..._strList(meta['author'], at, 'author'),
        ..._strList(meta['authors'], at, 'authors'),
      }.toList();
      final order = meta['order'];
      if (order is num) {
        book.order = order.round();
      } else if (order != null) {
        issues.error(at, '"order" צריך להיות מספר.');
      }
      book.pubDate = _str(meta['pubDate'], at, 'pubDate');
      book.pubPlace = _str(meta['pubPlace'], at, 'pubPlace');
      book.generations = _strList(meta['generation'], at, 'generation');
      for (final g in book.generations) {
        if (!kKnownGenerations.contains(g)) {
          issues.error(
            at,
            'דור לא מוכר "$g". האפליקציה מקבצת מפרשים רק לפי: ${kKnownGenerations.join(', ')}.',
          );
        }
      }
      book.acronyms = _strList(meta['acronyms'], at, 'acronyms');
      book.renamedFrom = _strList(meta['renamedFrom'], at, 'renamedFrom');
      for (final old in book.renamedFrom) {
        final other = renamedFrom[old];
        if (other != null) {
          issues.error(at, '"$old" מופיע ב-renamedFrom גם של "$other".');
        }
        renamedFrom[old] = title;
      }
      if (meta.containsKey('topics')) {
        book.topics = _strList(meta['topics'], at, 'topics');
      }
      final dh = meta['dibburHamatchil'];
      if (dh is bool) {
        book.dibburHamatchil = dh;
      } else if (dh != null) {
        issues.error(at, '"dibburHamatchil" צריך להיות true/false.');
      }
      final base = meta['isBaseBook'];
      if (base is bool) {
        book.isBaseBook = base;
      } else if (base != null) {
        issues.error(at, '"isBaseBook" צריך להיות true/false.');
      }
    });
    final defaultGeneration = config.defaultGeneration;
    if (defaultGeneration != null) {
      for (final book in out.books) {
        if (book.generations.isEmpty) book.generations = [defaultGeneration];
      }
    }
  }

  // ---- links/ --------------------------------------------------------------

  int? _lineIndex(
    Object? raw,
    BookSource book,
    String at,
    String key, {
    bool allowHeading = false,
  }) {
    final n = _int(raw, at, key);
    if (n == null) return null;
    if (n < 1 || n > book.lines.length) {
      issues.error(
        at,
        '"$key" = $n מחוץ לטווח: ב"${book.title}" יש ${book.lines.length} שורות (ספירה מ-1).',
      );
      return null;
    }
    if (!allowHeading && book.headingLines.contains(n - 1)) {
      issues.error(
        at,
        '"$key" = $n היא שורת כותרת ב"${book.title}"; קישור חייב להצביע על שורת טקסט.',
      );
      return null;
    }
    return n - 1;
  }

  void _readLinks() {
    final dir = Directory(p.join(root, 'links'));
    if (!dir.existsSync()) return;
    final seen = <String>{};
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final name = p.basename(file.path);
      if (name.startsWith('.') ||
          name == 'README.md' ||
          isIgnoredSystemFile(name)) {
        continue;
      }
      final rel = _rel(file.path);
      if (!name.endsWith('_links.json')) {
        issues.error(
          rel,
          'שם קובץ קישורים צריך להיות "<כותרת הספר>_links.json".',
        );
        continue;
      }
      final source = _book(
        name.substring(0, name.length - '_links.json'.length),
        rel,
      );
      final json = _json(rel);
      if (source == null || json == null) continue;
      if (json is! List) {
        issues.error(rel, 'צריך להיות מערך JSON של קישורים.');
        continue;
      }
      for (var i = 0; i < json.length; i++) {
        final entry = json[i];
        final at = '$rel [${i + 1}]';
        if (entry is! Map<String, dynamic>) {
          issues.error(at, 'כל קישור צריך להיות אובייקט.');
          continue;
        }
        _readLink(source, entry, at, seen);
      }
    }
  }

  void _readLink(
    BookSource source,
    Map<String, dynamic> e,
    String at,
    Set<String> seen,
  ) {
    const known = {
      'line_index_1',
      'line_index_2',
      'line_index_1_end',
      'line_index_2_end',
      'heRef_2',
      'path_2',
      'book_2',
      'Conection Type',
      'Connection Type',
      'connection_type',
      'start',
      'end',
      'target_library',
    };
    for (final k in e.keys) {
      if (!known.contains(k)) issues.error(at, 'שדה לא מוכר "$k".');
    }
    final rawType =
        e['Conection Type'] ?? e['Connection Type'] ?? e['connection_type'];
    if (rawType != null && rawType is! String) {
      issues.error(at, '"Conection Type" צריך להיות מחרוזת.');
      return;
    }
    final type = connectionTypeName(rawType as String?);
    if (type == null) {
      issues.error(at, 'סוג קישור "linker" אינו נתמך.');
      return;
    }
    final bookField = _str(e['book_2'], at, 'book_2');
    final pathField = _str(e['path_2'], at, 'path_2');
    final targetTitle =
        bookField ??
        (pathField == null
            ? null
            : p.basenameWithoutExtension(
                pathField.split(RegExp(r'[\\/]')).last,
              ));
    if (targetTitle == null || targetTitle.isEmpty) {
      issues.error(at, 'חסר יעד: "book_2" (כותרת) או "path_2" (נתיב/שם קובץ).');
      return;
    }
    final sourceLine = _lineIndex(
      e['line_index_1'],
      source,
      at,
      'line_index_1',
    );
    if (e['line_index_1'] == null) {
      issues.error(at, 'חסר "line_index_1".');
    }
    final heRef = _str(e['heRef_2'], at, 'heRef_2');
    final library = _str(e['target_library'], at, 'target_library');

    if (library != null) {
      // Link to another database: the target cannot be checked here.
      final String? targetSource;
      if (library == 'official' || library == 'רשמי') {
        targetSource = 'official';
      } else if (library == 'any' || library == 'כל') {
        targetSource = null;
      } else if (library == config.libraryId) {
        issues.error(
          at,
          'target_library הוא המסד הזה — השמיטו את השדה לקישור פנימי.',
        );
        return;
      } else if (isValidLibraryId(library)) {
        targetSource = library;
      } else {
        issues.error(
          at,
          'target_library "$library" לא תקין: official, any, או library_id של מסד אחר.',
        );
        return;
      }
      final targetLine = _int(e['line_index_2'], at, 'line_index_2');
      if (heRef == null && targetLine == null) {
        issues.error(
          at,
          'קישור חיצוני צריך "heRef_2" (מועדף) או "line_index_2".',
        );
        return;
      }
      if (targetLine != null && targetLine < 1) {
        issues.error(at, '"line_index_2" מתחיל מ-1.');
        return;
      }
      for (final k in const [
        'start',
        'end',
        'line_index_1_end',
        'line_index_2_end',
      ]) {
        if (e[k] != null) {
          issues.warn(at, '"$k" נתמך רק בקישור פנימי — מתעלמים ממנו.');
        }
      }
      if (targetTitle.length > 512 || (heRef?.length ?? 0) > 512) {
        issues.error(
          at,
          'כותרת/הפניה ארוכה מ-512 תווים — האפליקציה חותכת אותה.',
        );
        return;
      }
      if (sourceLine == null) return;
      out.externalLinks.add(
        ExternalLink(
          source: source,
          sourceLine: sourceLine,
          targetSource: targetSource,
          targetTitle: targetTitle,
          targetRef: heRef,
          targetLine: targetLine == null ? null : targetLine - 1,
          type: type,
        ),
      );
      return;
    }

    final target = _byTitle[targetTitle];
    if (target == null) {
      issues.error(
        at,
        'ספר היעד "$targetTitle" לא קיים במסד. לקישור לספרייה הרשמית הוסיפו "target_library": "official".',
      );
      return;
    }
    final targetLine = _lineIndex(
      e['line_index_2'],
      target,
      at,
      'line_index_2',
    );
    if (e['line_index_2'] == null) issues.error(at, 'חסר "line_index_2".');
    if (sourceLine == null || targetLine == null) return;
    final sourceEnd = _rangeEnd(
      e['line_index_1_end'],
      source,
      sourceLine,
      at,
      'line_index_1_end',
    );
    final targetEnd = _rangeEnd(
      e['line_index_2_end'],
      target,
      targetLine,
      at,
      'line_index_2_end',
    );

    // SOURCE is declared from the dependant's side; like the official builder,
    // store it as COMMENTARY from the base book to the dependant.
    final flip = type == 'SOURCE';
    final link = flip
        ? InternalLink(
            source: target,
            sourceLine: targetLine,
            target: source,
            targetLine: sourceLine,
            type: 'COMMENTARY',
          )
        : InternalLink(
            source: source,
            sourceLine: sourceLine,
            target: target,
            targetLine: targetLine,
            type: type,
          );
    link.sourceEnd = flip ? targetEnd : sourceEnd;
    link.targetEnd = flip ? sourceEnd : targetEnd;
    final key =
        '${link.source.title}|${link.sourceLine}|${link.target.title}|${link.targetLine}|${link.type}';
    if (!seen.add(key)) {
      issues.warn(at, 'קישור כפול — מדולג.');
      return;
    }
    final start = _int(e['start'], at, 'start');
    final end = _int(e['end'], at, 'end');
    if (start != null) {
      final content = source.lines[sourceLine];
      if (start < 0 || start > content.length) {
        issues.error(
          at,
          '"start" = $start מחוץ לאורך השורה (${content.length}).',
        );
      } else if (flip) {
        issues.warn(
          at,
          'עוגן ("start") על קישור מסוג source נשמט: הוא שייך לצד המקור, שהתהפך.',
        );
      } else {
        link.anchorStart = countVisibleChars(content, start);
        if (end != null) {
          if (end < start || end > content.length) {
            issues.error(at, '"end" = $end לא תקין (בין start לאורך השורה).');
          } else {
            link.anchorEnd = countVisibleChars(content, end);
          }
        }
        link.anchorLabel = _anchorLabel(heRef);
      }
    }
    out.links.add(link);
  }

  int? _rangeEnd(
    Object? raw,
    BookSource book,
    int start,
    String at,
    String key,
  ) {
    if (raw == null) return null;
    final end = _lineIndex(raw, book, at, key);
    if (end == null) return null;
    if (end < start) {
      issues.error(at, '"$key" קודם לתחילת הטווח.');
      return null;
    }
    return end == start ? null : end;
  }

  String? _anchorLabel(String? heRef) {
    if (heRef == null) return null;
    final idx = heRef.lastIndexOf(' אות ');
    if (idx < 0) return null;
    final tail = heRef.substring(idx + 5).trim();
    if (tail.isEmpty || tail.length > 6) return null;
    final ok = tail.runes.every(
      (r) =>
          (r >= 0x05D0 && r <= 0x05EA) ||
          r == 0x22 ||
          r == 0x05F3 ||
          r == 0x05F4,
    );
    return ok ? tail : null;
  }

  // ---- alt_toc/ ------------------------------------------------------------

  void _readAltToc() {
    final dir = Directory(p.join(root, 'alt_toc'));
    if (!dir.existsSync()) return;
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final name = p.basename(file.path);
      if (name.startsWith('.') ||
          name == 'README.md' ||
          isIgnoredSystemFile(name)) {
        continue;
      }
      final rel = _rel(file.path);
      if (!name.endsWith('_alt_toc.json')) {
        issues.error(rel, 'שם קובץ צריך להיות "<כותרת הספר>_alt_toc.json".');
        continue;
      }
      final book = _book(
        name.substring(0, name.length - '_alt_toc.json'.length),
        rel,
      );
      final json = _json(rel);
      if (book == null || json == null) continue;
      if (json is! List) {
        issues.error(rel, 'צריך להיות מערך של מבנים.');
        continue;
      }
      final keys = <String>{};
      for (var i = 0; i < json.length; i++) {
        final s = json[i];
        final at = '$rel [${i + 1}]';
        if (s is! Map<String, dynamic>) {
          issues.error(at, 'מבנה צריך להיות אובייקט.');
          continue;
        }
        final key = _str(s['key'], at, 'key');
        if (key == null) {
          issues.error(at, 'חסר "key".');
          continue;
        }
        if (!keys.add(key)) issues.error(at, '"key" כפול "$key".');
        final nodes = _altNodes(s['nodes'], book, at);
        if (nodes.isEmpty) {
          issues.error(at, 'מבנה בלי צמתים.');
          continue;
        }
        out.altTocs.add(
          AltTocStructure(
            book,
            key,
            _str(s['title'], at, 'title'),
            _str(s['heTitle'], at, 'heTitle'),
            nodes,
          ),
        );
      }
    }
  }

  List<AltTocNode> _altNodes(Object? raw, BookSource book, String at) {
    if (raw == null) return const [];
    if (raw is! List) {
      issues.error(at, '"nodes"/"children" צריך להיות מערך.');
      return const [];
    }
    final result = <AltTocNode>[];
    for (final n in raw) {
      if (n is! Map<String, dynamic>) {
        issues.error(at, 'צומת צריך להיות אובייקט.');
        continue;
      }
      final title = _str(n['heTitle'], at, 'heTitle');
      final where = '$at "${title ?? '?'}"';
      if (title == null) issues.error(at, 'צומת בלי "heTitle".');
      final line = _lineIndex(
        n['line'],
        book,
        where,
        'line',
        allowHeading: true,
      );
      if (n['line'] == null) issues.error(where, 'חסר "line".');
      final children = _altNodes(n['children'], book, where);
      if (title != null && line != null) {
        result.add(AltTocNode(title, line, children));
      }
    }
    return result;
  }

  // ---- versions.csv ----------------------------------------------------------

  void _readVersions() {
    const where = 'versions.csv';
    final file = File(p.join(root, where));
    if (!file.existsSync()) return;
    var text = file.readAsStringSync();
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final rows = parseCsv(text);
    if (rows.isEmpty) return;
    final header = rows.first.map((h) => h.trim()).toList();
    int col(String he, String en) {
      final i = header.indexOf(he);
      return i >= 0 ? i : header.indexOf(en);
    }

    final cPrimary = col('ראשי', 'primary');
    final cVersion = col('גרסה', 'version');
    final cName = col('שם', 'name');
    final cNotes = col('הערות', 'notes');
    final cPriority = col('עדיפות', 'priority');
    final cSource = col('מקור_ראשי', 'primary_source');
    final cCategory = col('קטגוריית_ראשי', 'primary_category');
    if (cPrimary < 0 || cVersion < 0) {
      issues.error(where, 'כותרת הטבלה חייבת לכלול "ראשי" ו"גרסה".');
      return;
    }
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c.trim().isEmpty)) continue;
      final at = '$where:${r + 1}';
      String? cell(int c) =>
          c >= 0 && c < row.length && row[c].trim().isNotEmpty
          ? row[c].trim()
          : null;
      final primary = cell(cPrimary);
      final versionTitle = cell(cVersion);
      if (primary == null || versionTitle == null) {
        issues.error(at, '"ראשי" ו"גרסה" חובה.');
        continue;
      }
      final version = _book(versionTitle, at);
      if (version == null) continue;
      final rawSource = cell(cSource) ?? 'רשמי';
      final String primarySource;
      final lower = rawSource.toLowerCase();
      if (lower == 'רשמי' || lower == 'official') {
        primarySource = 'official';
      } else if (lower == 'אישי' || lower == 'user') {
        primarySource = 'user';
      } else if (lower == 'מסד זה' || lower == 'local') {
        primarySource = 'db:${config.libraryId}';
      } else if (RegExp(r'^(db|מסד):').hasMatch(rawSource)) {
        final id = rawSource.substring(rawSource.indexOf(':') + 1).trim();
        if (!isValidLibraryId(id)) {
          issues.error(at, 'מזהה מסד לא תקין "$id".');
          continue;
        }
        primarySource = 'db:$id';
      } else {
        issues.error(
          at,
          '"מקור_ראשי" "$rawSource" לא מוכר: רשמי, אישי, מסד זה, או db:<library_id>.',
        );
        continue;
      }
      if (primarySource == 'db:${config.libraryId}') {
        final local = _book(primary, at);
        if (local == null) continue;
        if (local == version) {
          issues.error(at, 'ספר אינו יכול להיות גרסה של עצמו.');
          continue;
        }
      }
      final rawPriority = cell(cPriority);
      final priority = rawPriority == null
          ? null
          : double.tryParse(rawPriority);
      if (rawPriority != null && priority == null) {
        issues.error(at, '"עדיפות" צריכה להיות מספר.');
        continue;
      }
      out.versionLinks.add(
        VersionLink(
          version: version,
          primarySource: primarySource,
          primaryTitle: primary,
          primaryCategoryPath: cell(cCategory),
          versionTitle: cell(cName),
          versionNotes: cell(cNotes),
          priority: priority,
        ),
      );
    }
    final seen = <BookSource>{};
    for (final v in out.versionLinks) {
      if (!seen.add(v.version)) {
        issues.error(where, '"${v.version.title}" מוגדר כגרסה יותר מפעם אחת.');
      }
    }
  }

  // ---- editions/ -------------------------------------------------------------

  void _readEditions() {
    final dir = Directory(p.join(root, 'editions'));
    if (!dir.existsSync()) return;
    final bookDirs = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final bookDir in bookDirs) {
      final rel = _rel(bookDir.path);
      final book = _book(p.basename(bookDir.path), rel);
      if (book == null) continue;
      final metaRel = '$rel/editions.json';
      final meta = _json(metaRel);
      if (meta != null && meta is! Map<String, dynamic>) {
        issues.error(metaRel, 'צריך להיות אובייקט לפי שם מהדורה.');
      }
      final metaMap = meta is Map<String, dynamic>
          ? meta
          : const <String, dynamic>{};
      Map<String, dynamic> metaOf(String name) {
        final v = metaMap[name];
        if (v == null) return const {};
        if (v is Map<String, dynamic>) return v;
        issues.error('$metaRel: "$name"', 'צריך להיות אובייקט.');
        return const {};
      }

      final files = <File>[];
      for (final f in bookDir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name.endsWith('.txt')) {
          files.add(f);
        } else if (name != 'editions.json' &&
            name != 'README.md' &&
            !name.startsWith('.') &&
            !isIgnoredSystemFile(name)) {
          issues.error(
            _rel(f.path),
            'בתיקיית מהדורות מותרים רק קובצי .txt ו-editions.json.',
          );
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) {
        issues.error(rel, 'אין קובצי מהדורה (.txt).');
        continue;
      }
      final names = <String>{};
      final editions = <Edition>[];
      for (final f in files) {
        final name = p.basenameWithoutExtension(f.path).trim();
        names.add(name);
        final at = _rel(f.path);
        final edition = BookSource(
          title: name,
          categoryPath: const [],
          relPath: at,
          absPath: f.path,
        );
        _readLines(edition, f);
        if (edition.lines.isEmpty) continue;
        if (edition.lines.length != book.lines.length) {
          issues.error(
            at,
            'מספר השורות (${edition.lines.length}) שונה מהספר "${book.title}" (${book.lines.length}). '
            'מהדורה חייבת להתאים לספר שורה מול שורה.',
          );
          continue;
        }
        final mismatch = book.headingLines
            .where((i) => edition.lines[i] != book.lines[i])
            .toList();
        if (mismatch.isNotEmpty) {
          issues.error(
            at,
            'שורות הכותרת חייבות להיות זהות לספר הראשי (שורה ${mismatch.first + 1}).',
          );
          continue;
        }
        final m = metaOf(name);
        editions.add(
          Edition(
            book: book,
            title: name,
            lines: edition.lines,
            source: _str(m['source'], metaRel, 'source'),
            license: _str(m['license'], metaRel, 'license'),
            notes: _str(m['notes'], metaRel, 'notes'),
            priority: (m['priority'] as num?)?.toDouble(),
          ),
        );
      }
      for (final key in metaMap.keys) {
        if (key != 'base' && !names.contains(key)) {
          issues.error('$metaRel: "$key"', 'אין קובץ מהדורה בשם הזה.');
        }
      }
      if (editions.isEmpty) continue;
      final base = metaOf('base');
      out.editions.add(
        Edition(
          book: book,
          title: _str(base['title'], metaRel, 'title') ?? 'נוסח עיקרי',
          source: _str(base['source'], metaRel, 'source'),
          license: _str(base['license'], metaRel, 'license'),
          notes: _str(base['notes'], metaRel, 'notes'),
          priority: (base['priority'] as num?)?.toDouble() ?? 100,
        ),
      );
      out.editions.addAll(editions);
    }
  }

  // ---- default_commentators.json / default_targumim.json ---------------------

  void _readDefaults(String relPath, String listKey, bool commentators) {
    final json = _json(relPath);
    if (json == null) return;
    if (json is! List) {
      issues.error(
        relPath,
        'צריך להיות מערך של { "book": ..., "$listKey": [...] }.',
      );
      return;
    }
    final seenBooks = <BookSource>{};
    for (var i = 0; i < json.length; i++) {
      final e = json[i];
      final at = '$relPath [${i + 1}]';
      if (e is! Map<String, dynamic> ||
          e['book'] is! String ||
          e[listKey] is! List) {
        issues.error(
          at,
          'צריך { "book": "<כותרת>", "$listKey": ["<כותרת>", ...] }.',
        );
        continue;
      }
      final book = _book(e['book'] as String, at);
      if (book == null) continue;
      if (!seenBooks.add(book)) {
        issues.error(at, '"${book.title}" מופיע פעמיים.');
      }
      final list = e[listKey] as List;
      final seenTargets = <BookSource>{};
      for (var pos = 0; pos < list.length; pos++) {
        final t = list[pos];
        if (t == '-') continue;
        if (t is! String) {
          issues.error(at, 'כל פריט צריך להיות כותרת או "-" (מקום ריק).');
          continue;
        }
        final target = _book(t, '$at "$t"');
        if (target == null) continue;
        if (!seenTargets.add(target)) {
          issues.error(at, '"$t" מופיע פעמיים.');
          continue;
        }
        (commentators ? out.defaultCommentators : out.defaultTargums).add(
          DefaultSlot(book, target, pos),
        );
      }
    }
  }
}

/// Minimal RFC 4180 CSV parser (quoted fields, doubled quotes, CRLF).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
