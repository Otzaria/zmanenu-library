import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'config.dart';
import 'issues.dart';
import 'model.dart';
import 'ref_key.dart';
import 'schema.dart';
import 'source_reader.dart';
import 'text_utils.dart';

/// schema_meta key that remembers the next free book id, so the id of a
/// deleted book is never given to a new one.
const String kNextBookIdKey = 'zmanenu_next_book_id';

class BuildOptions {
  BuildOptions({
    required this.sourceDir,
    required this.libraryJson,
    required this.outDir,
    required this.dbVersion,
    this.previousDb,
    this.officialDb,
    this.manifestUrlOverride,
  });

  final String sourceDir;
  final String libraryJson;

  /// The database and the files folder are written here.
  final String outDir;
  final int dbVersion;

  /// The last published database: book ids are reused from it by title.
  final String? previousDb;

  /// Optional official seforim.db, to check that external link targets exist.
  final String? officialDb;
  final String? manifestUrlOverride;
}

class BuildResult {
  BuildResult(this.dbPath, this.source, this.warnings);

  final String dbPath;
  final LibrarySource source;
  final List<Issue> warnings;
}

/// Reads [BuildOptions.sourceDir], validates it and writes the database.
/// Throws [BuildFailed] with every error found.
BuildResult build(BuildOptions options) {
  final issues = Issues();
  if (options.dbVersion < 1) {
    issues.error('--db-version', 'חייב להיות מספר שלם חיובי.');
    throw BuildFailed(issues.all);
  }
  final config = LibraryConfig.load(options.libraryJson, issues);
  final source = readSource(options.sourceDir, config, issues);
  if (options.officialDb != null) {
    _checkOfficialTargets(source, options.officialDb!, issues);
  }
  if (!issues.hasErrors) _assignIds(source, options.previousDb, config, issues);
  if (issues.hasErrors) throw BuildFailed(issues.all);

  Directory(options.outDir).createSync(recursive: true);
  final dbPath = p.join(options.outDir, config.dbFileName);
  for (final suffix in ['', '-journal', '-wal', '-shm']) {
    final f = File('$dbPath$suffix');
    if (f.existsSync()) f.deleteSync();
  }
  final filesRoot = Directory(p.join(options.outDir, config.filesDir));
  if (filesRoot.existsSync()) filesRoot.deleteSync(recursive: true);

  final manifestUrl = options.manifestUrlOverride ?? config.updateManifestUrl;
  _write(dbPath, config, source, options.dbVersion, manifestUrl);

  for (final book in source.books.where((b) => !b.isText)) {
    final target = File(p.join(options.outDir, book.storedFilePath!));
    target.parent.createSync(recursive: true);
    File(book.absPath).copySync(target.path);
  }
  return BuildResult(
    dbPath,
    source,
    issues.all.where((i) => !i.isError).toList(),
  );
}

void _checkOfficialTargets(
  LibrarySource source,
  String officialDb,
  Issues issues,
) {
  final db = sqlite3.open(officialDb, mode: OpenMode.readOnly);
  try {
    final titles = {
      for (final row in db.select('SELECT title FROM book'))
        row['title'] as String,
    };
    for (final link in source.externalLinks) {
      if (link.targetSource == 'official' &&
          !titles.contains(link.targetTitle)) {
        issues.error(
          'links/${link.source.title}_links.json',
          'הספר "${link.targetTitle}" לא נמצא בספרייה הרשמית ($officialDb).',
        );
      }
    }
  } finally {
    db.close();
  }
}

/// Book ids are the identity of a book in the app (search index, bookmarks,
/// plugin bookUid), so they are carried over from the previous release.
void _assignIds(
  LibrarySource source,
  String? previousDb,
  LibraryConfig config,
  Issues issues,
) {
  final previous = <String, int>{};
  var next = 1;
  if (previousDb != null) {
    if (!File(previousDb).existsSync()) {
      issues.error('--previous-db', 'הקובץ $previousDb לא קיים.');
      return;
    }
    final db = sqlite3.open(previousDb, mode: OpenMode.readOnly);
    try {
      final meta = {
        for (final row in db.select('SELECT key, value FROM schema_meta'))
          row['key'] as String: row['value'] as String,
      };
      if (meta['library_id'] != config.libraryId) {
        issues.error(
          '--previous-db',
          'library_id במסד הקודם הוא "${meta['library_id']}", לא "${config.libraryId}".',
        );
        return;
      }
      for (final row in db.select('SELECT id, title FROM book')) {
        previous[row['title'] as String] = row['id'] as int;
        if ((row['id'] as int) >= next) next = (row['id'] as int) + 1;
      }
      final stored = int.tryParse(meta[kNextBookIdKey] ?? '');
      if (stored != null && stored > next) next = stored;
    } finally {
      db.close();
    }
  }
  final used = <int, BookSource>{};
  final fresh = <BookSource>[];
  for (final book in source.books) {
    final id =
        previous[book.title] ??
        book.renamedFrom.map((t) => previous[t]).whereType<int>().firstOrNull;
    if (id == null) {
      fresh.add(book);
      continue;
    }
    final other = used[id];
    if (other != null) {
      issues.error(
        'metadata.json',
        '"${book.title}" ו"${other.title}" מקבלים שניהם את המזהה $id מהמסד הקודם (בדקו renamedFrom).',
      );
      continue;
    }
    book.id = id;
    used[id] = book;
  }
  fresh.sort((a, b) => a.relPath.compareTo(b.relPath));
  for (final book in fresh) {
    book.id = next++;
  }
  source.nextBookId = next;
}

void _write(
  String dbPath,
  LibraryConfig config,
  LibrarySource source,
  int dbVersion,
  String? manifestUrl,
) {
  final db = sqlite3.open(dbPath);
  try {
    db.execute('PRAGMA page_size = 4096');
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute('BEGIN');
    for (final ddl in kSchema) {
      db.execute(ddl);
    }
    _Writer(db, config, source).write(dbVersion, manifestUrl);
    for (final ddl in kIndexes) {
      db.execute(ddl);
    }
    db.execute('COMMIT');
    db.execute('VACUUM');
  } finally {
    db.close();
  }
}

class _Writer {
  _Writer(this.db, this.config, this.source);

  final Database db;
  final LibraryConfig config;
  final LibrarySource source;
  final Map<String, int> _tocTexts = {};
  final Map<BookSource, List<int>> _lineIds = {};
  final Map<String, int> _categoryIds = {};

  void _insert(String table, Map<String, Object?> row) {
    final cols = row.keys.join(', ');
    final marks = List.filled(row.length, '?').join(', ');
    db.execute(
      'INSERT INTO $table ($cols) VALUES ($marks)',
      row.values.toList(),
    );
  }

  int _tocText(String text) => _tocTexts.putIfAbsent(text, () {
    db.execute('INSERT INTO tocText (id, text) VALUES (?, ?)', [
      _tocTexts.length + 1,
      text,
    ]);
    return _tocTexts.length + 1;
  });

  void write(int dbVersion, String? manifestUrl) {
    _meta(dbVersion, manifestUrl);
    db.execute('INSERT INTO source (id, name) VALUES (1, ?)', [
      config.libraryName,
    ]);
    for (var i = 0; i < kConnectionTypes.length; i++) {
      db.execute('INSERT INTO connection_type (id, name) VALUES (?, ?)', [
        i + 1,
        kConnectionTypes[i],
      ]);
    }
    _categories();
    final books = [...source.books]..sort((a, b) => a.id.compareTo(b.id));
    for (final book in books) {
      _book(book);
    }
    _lookups(books);
    for (final book in books.where((b) => b.isText)) {
      _lines(book);
    }
    _links(books);
    _externalLinks();
    _altTocs();
    _editions();
    _versionLinks();
    _defaults();
  }

  void _meta(int dbVersion, String? manifestUrl) {
    final meta = <String, String?>{
      'library_id': config.libraryId,
      'library_name': config.libraryName,
      'library_folder': config.libraryFolder,
      'db_version': '$dbVersion',
      'update_manifest_url': manifestUrl,
      'update_public_key': config.updatePublicKey,
      'description': config.description,
      'author': config.author,
      kNextBookIdKey: '${source.nextBookId}',
    };
    meta.forEach((k, v) {
      if (v != null) {
        db.execute('INSERT INTO schema_meta (key, value) VALUES (?, ?)', [
          k,
          v,
        ]);
      }
    });
  }

  void _categories() {
    final nodes = [...source.categories]
      ..sort((a, b) => a.key.compareTo(b.key));
    var id = 0;
    for (final node in nodes) {
      node.id = ++id;
      _categoryIds[node.key] = node.id;
    }
    for (final node in nodes) {
      final parentKey = node.path.length > 1
          ? node.path.sublist(0, node.path.length - 1).join('/')
          : null;
      node.parentId = parentKey == null ? null : _categoryIds[parentKey];
      _insert('category', {
        'id': node.id,
        'parentId': node.parentId,
        'title': node.title,
        'level': node.level,
        'orderIndex': node.order,
        'heShortDesc': node.heShortDesc,
        'heDesc': node.heDesc,
      });
      for (var depth = 1; depth <= node.path.length; depth++) {
        db.execute('INSERT INTO category_closure VALUES (?, ?)', [
          _categoryIds[node.path.sublist(0, depth).join('/')],
          node.id,
        ]);
      }
    }
  }

  void _book(BookSource book) {
    final all = book.lines.join('\n');
    _insert('book', {
      'id': book.id,
      'categoryId': _categoryIds[book.categoryKey],
      'sourceId': 1,
      'title': book.title,
      'heRef': book.title,
      'heShortDesc': book.heShortDesc,
      'heDesc': book.heDesc,
      'orderIndex': book.order,
      'totalLines': book.lines.length,
      'isBaseBook': book.isBaseBook ? 1 : 0,
      'hasAltStructures': source.altTocs.any((s) => s.book == book) ? 1 : 0,
      'hasTeamim': hasTeamim(all) ? 1 : 0,
      'hasNekudot': hasNekudot(all) ? 1 : 0,
      'contentHash': book.isText ? fnv64([book.title, ...book.lines]) : 0,
      'fileType': book.fileExt,
      'filePath': book.storedFilePath,
    });
    for (final term in book.acronyms.toSet()) {
      db.execute('INSERT INTO book_acronym (bookId, term) VALUES (?, ?)', [
        book.id,
        term,
      ]);
    }
  }

  void _lookups(List<BookSource> books) {
    void table(
      String name,
      String column,
      String join,
      String fk,
      Iterable<String> Function(BookSource) values,
    ) {
      final ids = <String, int>{};
      for (final book in books) {
        for (final value in values(book).toSet()) {
          final id = ids.putIfAbsent(value, () {
            db.execute('INSERT INTO $name (id, $column) VALUES (?, ?)', [
              ids.length + 1,
              value,
            ]);
            return ids.length + 1;
          });
          db.execute('INSERT INTO $join (bookId, $fk) VALUES (?, ?)', [
            book.id,
            id,
          ]);
        }
      }
    }

    table('author', 'name', 'book_author', 'authorId', (b) => b.authors);
    table('topic', 'name', 'book_topic', 'topicId', (b) => b.topics);
    table(
      'pub_place',
      'name',
      'book_pub_place',
      'pubPlaceId',
      (b) => [?b.pubPlace],
    );
    table(
      'pub_date',
      'date',
      'book_pub_date',
      'pubDateId',
      (b) => [?b.pubDate],
    );
    table(
      'generation',
      'name',
      'book_generation',
      'generationId',
      (b) => b.generations,
    );
  }

  int _nextLineId = 1;
  int _nextTocId = 1;

  void _lines(BookSource book) {
    final ids = List<int>.generate(book.lines.length, (_) => _nextLineId++);
    _lineIds[book] = ids;

    // TOC: a heading closes every open heading of its level or deeper.
    final entryOfLine = <int, int>{};
    final stack = <(int level, int id)>[];
    final children = <int?, List<int>>{};
    for (final h in book.headings) {
      while (stack.isNotEmpty && stack.last.$1 >= h.level) {
        stack.removeLast();
      }
      final parent = stack.isEmpty ? null : stack.last.$2;
      final id = _nextTocId++;
      _insert('tocEntry', {
        'id': id,
        'bookId': book.id,
        'parentId': parent,
        'textId': _tocText(h.text),
        'level': h.level,
        'lineId': ids[h.lineIndex],
      });
      children.putIfAbsent(parent, () => []).add(id);
      entryOfLine[h.lineIndex] = id;
      stack.add((h.level, id));
    }
    for (final MapEntry(key: parent, value: list) in children.entries) {
      db.execute('UPDATE tocEntry SET isLastChild = 1 WHERE id = ?', [
        list.last,
      ]);
      if (parent != null) {
        db.execute('UPDATE tocEntry SET hasChildren = 1 WHERE id = ?', [
          parent,
        ]);
      }
    }

    final insertLine = db.prepare(
      'INSERT INTO line (id, bookId, lineIndex, content, heRef, tocEntryId, charCount) VALUES (?, ?, ?, ?, ?, ?, ?)',
    );
    final insertLineToc = db.prepare(
      'INSERT INTO line_toc (lineId, tocEntryId) VALUES (?, ?)',
    );
    final insertRef = db.prepare(
      'INSERT OR IGNORE INTO line_ref (bookId, refKeyHash, lineIndex) VALUES (?, ?, ?)',
    );
    final insertDh = db.prepare(
      'INSERT OR IGNORE INTO line_dh (bookId, dhText, lineIndex, dhDisplay) VALUES (?, ?, ?, ?)',
    );
    try {
      int? current;
      for (var i = 0; i < book.lines.length; i++) {
        current = entryOfLine[i] ?? current;
        final content = book.lines[i];
        final isHeading = book.headingLines.contains(i);
        // Like the official builder: "<title> <n>" (1-based) on text lines only.
        final heRef = isHeading ? null : '${book.title} ${i + 1}';
        insertLine.execute([
          ids[i],
          book.id,
          i,
          content,
          heRef,
          current,
          countVisibleChars(content),
        ]);
        if (current != null) insertLineToc.execute([ids[i], current]);
        if (heRef != null) {
          for (final hash in lineRefKeyHashes(heRef, book.title)) {
            insertRef.execute([book.id, hash, i]);
          }
        }
        if (book.dibburHamatchil && !isHeading) {
          final display = leadingBoldText(content);
          final key = display == null ? null : dhKey(display);
          if (key != null) insertDh.execute([book.id, key, i, display]);
        }
      }
    } finally {
      insertLine.close();
      insertLineToc.close();
      insertRef.close();
      insertDh.close();
    }
  }

  void _links(List<BookSource> books) {
    final typeIds = {
      for (var i = 0; i < kConnectionTypes.length; i++)
        kConnectionTypes[i]: i + 1,
    };
    final links = [...source.links]
      ..sort((a, b) {
        final c = a.source.id.compareTo(b.source.id);
        if (c != 0) return c;
        final d = a.sourceLine.compareTo(b.sourceLine);
        return d != 0 ? d : a.target.id.compareTo(b.target.id);
      });
    final flags = <BookSource, Set<String>>{};
    final hasSource = <BookSource>{};
    final hasTarget = <BookSource>{};
    var id = 0;
    for (final link in links) {
      id++;
      _insert('link', {
        'id': id,
        'sourceBookId': link.source.id,
        'targetBookId': link.target.id,
        'sourceLineId': _lineIds[link.source]![link.sourceLine],
        'targetLineId': _lineIds[link.target]![link.targetLine],
        'targetLineIndex': link.targetLine,
        'targetBookOrderIndex': link.target.order,
        'connectionTypeId': typeIds[link.type],
      });
      if (link.anchorStart != null) {
        _insert('link_anchor', {
          'linkId': id,
          'side': 0,
          'charStart': link.anchorStart,
          'charEnd': link.anchorEnd,
          'label': link.anchorLabel,
        });
      }
      _range(id, 0, link.source, link.sourceLine, link.sourceEnd);
      _range(id, 1, link.target, link.targetLine, link.targetEnd);
      flags.putIfAbsent(link.source, () => {}).add(link.type);
      hasSource.add(link.source);
      hasTarget.add(link.target);
    }
    for (final book in books) {
      final types = flags[book] ?? const <String>{};
      bool any(Set<String> set) => types.any(set.contains);
      final commentary = any(const {'COMMENTARY', 'SUPER_COMMENTARY'});
      db.execute(
        'UPDATE book SET hasCommentaryConnection = ?, hasTargumConnection = ?, '
        'hasReferenceConnection = ?, hasSourceConnection = ?, hasOtherConnection = ?, '
        'isBaseBook = MAX(isBaseBook, ?) WHERE id = ?',
        [
          commentary ? 1 : 0,
          any(const {'TARGUM'}) ? 1 : 0,
          any(const {'REFERENCE'}) ? 1 : 0,
          any(const {'SOURCE'}) ? 1 : 0,
          types.any(
                (t) => !const {
                  'COMMENTARY',
                  'SUPER_COMMENTARY',
                  'TARGUM',
                  'REFERENCE',
                  'SOURCE',
                }.contains(t),
              )
              ? 1
              : 0,
          commentary ? 1 : 0,
          book.id,
        ],
      );
      if (hasSource.contains(book) || hasTarget.contains(book)) {
        db.execute('INSERT INTO book_has_links VALUES (?, ?, ?)', [
          book.id,
          hasSource.contains(book) ? 1 : 0,
          hasTarget.contains(book) ? 1 : 0,
        ]);
      }
    }
  }

  void _range(int linkId, int side, BookSource book, int start, int? end) {
    if (end == null) return;
    final ids = _lineIds[book]!;
    _insert('link_range', {
      'linkId': linkId,
      'side': side,
      'endLineId': ids[end],
      'endLineIndex': end,
    });
    for (var i = start + 1; i <= end; i++) {
      if (book.headingLines.contains(i)) continue;
      db.execute(
        'INSERT INTO link_coverage (lineId, linkId, side) VALUES (?, ?, ?)',
        [ids[i], linkId, side],
      );
    }
  }

  void _externalLinks() {
    for (final link in source.externalLinks) {
      _insert('external_link', {
        'sourceBookId': link.source.id,
        'sourceLineIndex': link.sourceLine,
        'targetSource': link.targetSource,
        'targetTitle': link.targetTitle,
        'targetRef': link.targetRef,
        'targetLineIndex': link.targetLine,
        'connectionType': link.type,
      });
    }
  }

  void _altTocs() {
    var structureId = 0;
    var entryId = 0;
    for (final s in source.altTocs) {
      final sid = ++structureId;
      _insert('alt_toc_structure', {
        'id': sid,
        'bookId': s.book.id,
        'key': s.key,
        'title': s.title,
        'heTitle': s.heTitle,
      });
      final ids = _lineIds[s.book]!;
      final anchors = <int, int>{};

      void add(List<AltTocNode> nodes, int level, int? parent) {
        for (var i = 0; i < nodes.length; i++) {
          final node = nodes[i];
          final id = ++entryId;
          _insert('alt_toc_entry', {
            'id': id,
            'structureId': sid,
            'parentId': parent,
            'textId': _tocText(node.heTitle),
            'level': level,
            'lineId': ids[node.lineIndex],
            'isLastChild': i == nodes.length - 1 ? 1 : 0,
            'hasChildren': node.children.isEmpty ? 0 : 1,
          });
          anchors[node.lineIndex] = id;
          add(node.children, level + 1, id);
        }
      }

      add(s.nodes, 0, null);
      final sorted = anchors.keys.toList()..sort();
      var a = 0;
      int? current;
      for (var line = 0; line < s.book.lines.length; line++) {
        while (a < sorted.length && sorted[a] <= line) {
          current = anchors[sorted[a++]];
        }
        if (current != null) {
          db.execute('INSERT INTO line_alt_toc VALUES (?, ?, ?)', [
            ids[line],
            sid,
            current,
          ]);
        }
      }
    }
  }

  void _editions() {
    var id = 0;
    for (final e in source.editions) {
      final vid = ++id;
      _insert('book_version', {
        'id': vid,
        'bookId': e.book.id,
        'versionTitle': e.title,
        'heVersionTitle': e.title,
        'versionSource': e.source,
        'priority': e.priority,
        'license': e.license,
        'heVersionNotes': e.notes,
        'hasContent': e.lines == null ? 0 : 1,
      });
      final lines = e.lines;
      if (lines == null) continue;
      final ids = _lineIds[e.book]!;
      for (var i = 0; i < lines.length; i++) {
        if (e.book.headingLines.contains(i)) continue;
        db.execute('INSERT INTO version_line VALUES (?, ?, ?, ?)', [
          vid,
          ids[i],
          lines[i],
          countVisibleChars(lines[i]),
        ]);
      }
    }
  }

  void _versionLinks() {
    for (final v in source.versionLinks) {
      _insert('book_version_link', {
        'versionBookId': v.version.id,
        'primarySource': v.primarySource,
        'primaryTitle': v.primaryTitle,
        'primaryCategoryPath': v.primaryCategoryPath,
        'versionTitle': v.versionTitle,
        'versionNotes': v.versionNotes,
        'priority': v.priority,
      });
    }
  }

  void _defaults() {
    for (final s in source.defaultCommentators) {
      db.execute('INSERT INTO default_commentator VALUES (?, ?, ?)', [
        s.book.id,
        s.target.id,
        s.position,
      ]);
    }
    for (final s in source.defaultTargums) {
      db.execute('INSERT INTO default_targum VALUES (?, ?, ?)', [
        s.book.id,
        s.target.id,
        s.position,
      ]);
    }
  }
}
