import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:zmanenu_builder/zmanenu_builder.dart';

final String libraryJson = p.join('..', 'library.json');
final String examples = p.join('..', 'examples');

late Directory temp;

/// A minimal source tree: one book with a heading and two text lines.
String makeSource({Map<String, String> files = const {}}) {
  final root = Directory(p.join(temp.path, 'src'))..createSync();
  final all = {
    'books/קטגוריה/ספר א.txt': '<h1>ספר א</h1>\nשורה ראשונה\nשורה שנייה\n',
    'books/קטגוריה/ספר ב.txt': '<h1>ספר ב</h1>\nפירוש ראשון\n',
    ...files,
  };
  all.forEach((rel, content) {
    final f = File(p.join(root.path, rel))..parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  });
  return root.path;
}

BuildResult run(
  String source, {
  int version = 1,
  String? previous,
  String out = 'out',
  String? library,
  bool release = false,
  bool allowRemovedBooks = false,
}) => build(
  BuildOptions(
    sourceDir: source,
    libraryJson: library ?? libraryJson,
    outDir: p.join(temp.path, out),
    dbVersion: version,
    previousDb: previous,
    release: release,
    allowRemovedBooks: allowRemovedBooks,
  ),
);

/// The error messages of a build that must fail.
List<String> errorsOf(String source, {BuildResult Function()? build}) {
  try {
    (build ?? () => run(source))();
  } on BuildFailed catch (e) {
    return [
      for (final i in e.issues.where((i) => i.isError))
        '${i.where}: ${i.message}',
    ];
  }
  fail('the build was expected to fail');
}

void main() {
  setUp(() => temp = Directory.systemTemp.createTempSync('zmanenu_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  group(
    'examples',
    skip: Directory(examples).existsSync() ? false : 'examples/ was removed',
    () {
      test('build into a database with every table filled', () {
        final result = run(examples);
        final db = sqlite3.open(result.dbPath, mode: OpenMode.readOnly);
        addTearDown(db.close);
        int count(String table) =>
            db.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;
        final meta = {
          for (final r in db.select('SELECT key, value FROM schema_meta'))
            r['key']: r['value'],
        };
        expect(meta['library_id'], 'otzaria.zmanenu');
        expect(meta['library_folder'], 'מחברי זמננו');
        expect(meta['db_version'], '1');
        for (final table in [
          'book',
          'category',
          'line',
          'tocEntry',
          'line_toc',
          'link',
          'link_anchor',
          'link_range',
          'link_coverage',
          'external_link',
          'external_default_commentator',
          'alt_toc_entry',
          'line_alt_toc',
          'book_version',
          'version_line',
          'book_version_link',
          'default_commentator',
          'default_targum',
          'book_acronym',
          'line_dh',
          'line_ref',
          'book_generation',
          'book_author',
        ]) {
          expect(count(table), greaterThan(0), reason: table);
        }
        expect(
          count('book WHERE fileType IS NOT NULL OR filePath IS NOT NULL'),
          0,
        );
        expect(db.select('PRAGMA journal_mode').first.values.first, 'delete');
        final external = db.select(
          'SELECT targetSource, targetTitle, kind, position, b.title AS title '
          'FROM external_default_commentator e '
          'JOIN book b ON b.id = e.commentatorBookId',
        );
        expect(external.map((r) => r.values).toList(), [
          ['official', 'בראשית', 'commentator', 0, 'הערות על בראשית לדוגמה'],
        ]);
      });

      test('every table the app knows exists, even when empty', () {
        final db = sqlite3.open(run(examples).dbPath, mode: OpenMode.readOnly);
        addTearDown(db.close);
        final tables = {
          for (final r in db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          ))
            r['name'] as String,
        };
        expect(
          tables,
          containsAll(kAppKnownTables.difference(kOmittedTables.keys.toSet())),
        );
        expect(tables, contains('external_default_commentator'));
        for (final omitted in kOmittedTables.keys) {
          expect(tables, isNot(contains(omitted)));
        }
      });

      test('a SOURCE link is stored as COMMENTARY from the base book', () {
        final db = sqlite3.open(run(examples).dbPath, mode: OpenMode.readOnly);
        addTearDown(db.close);
        final rows = db.select(
          'SELECT s.title AS s, t.title AS t FROM link l JOIN book s ON s.id = l.sourceBookId '
          'JOIN book t ON t.id = l.targetBookId JOIN connection_type c ON c.id = l.connectionTypeId '
          "WHERE c.name = 'COMMENTARY'",
        );
        expect(rows.map((r) => r['s']).toSet(), {'קיצור הלכות שבת לדוגמה'});
        expect(rows.map((r) => r['t']).toSet(), {
          'ביאור על קיצור הלכות שבת לדוגמה',
        });
      });

      test('two builds of the same source are byte-identical', () {
        final a = File(run(examples, out: 'a').dbPath).readAsBytesSync();
        final b = File(run(examples, out: 'b').dbPath).readAsBytesSync();
        expect(a, b);
      });

      test('the empty source tree builds', () {
        expect(run(p.join('..', 'source')).source.books, isEmpty);
      });
    },
  );

  group('book ids', () {
    test('are kept from the previous database, new books get fresh ids', () {
      final v1 = run(makeSource(), out: 'v1');
      final ids1 = _ids(v1.dbPath);
      final src = p.join(temp.path, 'src');
      File(p.join(src, 'books/קטגוריה/ספר א.txt')).deleteSync();
      File(
        p.join(src, 'books/קטגוריה/אאא חדש.txt'),
      ).writeAsStringSync('טקסט\n');
      final v2 = run(src, version: 2, previous: v1.dbPath, out: 'v2');
      final ids2 = _ids(v2.dbPath);
      expect(ids2['ספר ב'], ids1['ספר ב']);
      // The id of the deleted "ספר א" is never reused.
      expect(ids2['אאא חדש'], 3);
    });

    test('renamedFrom keeps the id of a renamed book', () {
      final v1 = run(makeSource(), out: 'v1');
      final src = p.join(temp.path, 'src');
      File(
        p.join(src, 'books/קטגוריה/ספר א.txt'),
      ).renameSync(p.join(src, 'books/קטגוריה/ספר א מתוקן.txt'));
      File(p.join(src, 'metadata.json')).writeAsStringSync(
        jsonEncode({
          'ספר א מתוקן': {
            'renamedFrom': ['ספר א'],
          },
        }),
      );
      final v2 = run(src, version: 2, previous: v1.dbPath, out: 'v2');
      expect(_ids(v2.dbPath)['ספר א מתוקן'], _ids(v1.dbPath)['ספר א']);
    });
  });

  group('category ids', () {
    test('are kept from the previous database, new ones never reuse ids', () {
      final v1 = run(
        makeSource(files: {'books/תת/ספר ג.txt': 'טקסט\n'}),
        out: 'v1',
      );
      final ids1 = _categoryIds(v1.dbPath);
      final src = p.join(temp.path, 'src');
      Directory(p.join(src, 'books/תת')).deleteSync(recursive: true);
      // Sorts before every existing category.
      File(p.join(src, 'books/אאא/ספר ד.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('טקסט\n');
      final v2 = run(src, version: 2, previous: v1.dbPath, out: 'v2');
      final ids2 = _categoryIds(v2.dbPath);
      expect(ids2['קטגוריה'], ids1['קטגוריה']);
      expect(ids2['אאא'], greaterThan(ids1.values.reduce(max)));
      final v3 = run(src, version: 3, previous: v2.dbPath, out: 'v3');
      expect(_categoryIds(v3.dbPath), ids2);
    });
  });

  group('the previous database', () {
    /// library.json with [changes] applied, written next to the sources.
    String libraryWith(Map<String, Object?> changes) {
      final json =
          jsonDecode(File(libraryJson).readAsStringSync())
              as Map<String, dynamic>;
      json.addAll(changes);
      final file = File(p.join(temp.path, 'library.json'))
        ..writeAsStringSync(jsonEncode(json));
      return file.path;
    }

    for (final (key, value) in [
      ('library_id', 'otzaria.other'),
      ('library_folder', 'תיקייה אחרת'),
      ('update_manifest_url', 'https://example.com/manifest.json'),
      ('update_public_key', base64.encode(List.filled(32, 7))),
    ]) {
      test('rejects a different $key', () {
        final v1 = run(makeSource(), out: 'v1');
        final errors = errorsOf(
          '',
          build: () => run(
            p.join(temp.path, 'src'),
            version: 2,
            previous: v1.dbPath,
            out: 'v2',
            library: libraryWith({key: value}),
          ),
        ).join('\n');
        expect(errors, contains('$key במסד הקודם'));
      });
    }

    test('lists removed and added books', () {
      final v1 = run(makeSource(), out: 'v1');
      final src = p.join(temp.path, 'src');
      File(p.join(src, 'books/קטגוריה/ספר א.txt')).deleteSync();
      File(p.join(src, 'books/קטגוריה/ספר ג.txt')).writeAsStringSync('טקסט\n');
      final v2 = run(src, version: 2, previous: v1.dbPath, out: 'v2');
      final warnings = v2.warnings.join('\n');
      expect(warnings, contains('1 ספרים שהיו במסד הקודם נעלמו: ספר א.'));
      expect(warnings, contains('1 ספרים חדשים: ספר ג.'));
    });

    test('a removed book fails a release unless allowed', () {
      final v1 = run(makeSource(), out: 'v1');
      final src = p.join(temp.path, 'src');
      File(p.join(src, 'books/קטגוריה/ספר א.txt')).deleteSync();
      final errors = errorsOf(
        '',
        build: () =>
            run(src, version: 2, previous: v1.dbPath, out: 'v2', release: true),
      ).join('\n');
      expect(errors, contains('allow_removed_books'));
      final allowed = run(
        src,
        version: 2,
        previous: v1.dbPath,
        out: 'v3',
        release: true,
        allowRemovedBooks: true,
      );
      expect(allowed.warnings.join('\n'), contains('נעלמו: ספר א.'));
    });

    test('a rename with renamedFrom is not a removal', () {
      final v1 = run(makeSource(), out: 'v1');
      final src = p.join(temp.path, 'src');
      File(
        p.join(src, 'books/קטגוריה/ספר א.txt'),
      ).renameSync(p.join(src, 'books/קטגוריה/ספר א מתוקן.txt'));
      File(p.join(src, 'metadata.json')).writeAsStringSync(
        jsonEncode({
          'ספר א מתוקן': {
            'renamedFrom': ['ספר א'],
          },
        }),
      );
      final v2 = run(
        src,
        version: 2,
        previous: v1.dbPath,
        out: 'v2',
        release: true,
      );
      expect(v2.warnings.join('\n'), isNot(contains('נעלמו')));
      // In the next release the old title is gone from the previous database.
      final v3 = run(src, version: 3, previous: v2.dbPath, out: 'v3');
      expect(v3.warnings.join('\n'), contains('כבר הוחל'));
    });

    test('renamedFrom that the previous database does not have', () {
      final v1 = run(makeSource(), out: 'v1');
      final src = p.join(temp.path, 'src');
      File(p.join(src, 'books/קטגוריה/ספר ג.txt')).writeAsStringSync('טקסט\n');
      File(p.join(src, 'metadata.json')).writeAsStringSync(
        jsonEncode({
          'ספר ג': {
            'renamedFrom': ['אין כזה'],
          },
        }),
      );
      final errors = errorsOf(
        '',
        build: () => run(src, version: 2, previous: v1.dbPath, out: 'v2'),
      ).join('\n');
      expect(errors, contains('renamedFrom "אין כזה" לא קיים במסד הקודם'));
    });
  });

  test('a release without books fails', () {
    final root = Directory(p.join(temp.path, 'empty', 'books'))
      ..createSync(recursive: true);
    final errors = errorsOf(
      '',
      build: () => run(root.parent.path, release: true),
    ).join('\n');
    expect(errors, contains('אין אף ספר'));
  });

  group('source errors', () {
    void expectError(Map<String, String> files, String fragment) {
      final errors = errorsOf(makeSource(files: files));
      expect(errors.join('\n'), contains(fragment));
    }

    test('link to a book that does not exist', () {
      expectError({
        'links/ספר א_links.json': jsonEncode([
          {
            'line_index_1': 2,
            'line_index_2': 2,
            'path_2': 'אין כזה.txt',
            'Conection Type': 'commentary',
          },
        ]),
      }, 'ספר היעד "אין כזה" לא קיים');
    });

    test('link line out of range and link to a heading', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'links/ספר א_links.json': jsonEncode([
              {
                'line_index_1': 9,
                'line_index_2': 2,
                'book_2': 'ספר ב',
                'Conection Type': 'commentary',
              },
              {
                'line_index_1': 2,
                'line_index_2': 1,
                'book_2': 'ספר ב',
                'Conection Type': 'commentary',
              },
            ]),
          },
        ),
      ).join('\n');
      expect(errors, contains('מחוץ לטווח'));
      expect(errors, contains('שורת כותרת'));
    });

    test('links file of an unknown book', () {
      expectError({'links/אין כזה_links.json': '[]'}, 'אין ספר בשם "אין כזה"');
    });

    test('external link without a reference', () {
      expectError({
        'links/ספר א_links.json': jsonEncode([
          {
            'line_index_1': 2,
            'book_2': 'בראשית',
            'target_library': 'official',
            'Conection Type': 'source',
          },
        ]),
      }, 'heRef_2');
    });

    test('version of a book that does not exist', () {
      expectError({
        'versions.csv': 'ראשי,גרסה,מקור_ראשי\nבראשית,ספר חסר,רשמי\n',
      }, 'אין ספר בשם "ספר חסר"');
    });

    test('local primary that does not exist', () {
      expectError({
        'versions.csv': 'ראשי,גרסה,מקור_ראשי\nספר חסר,ספר א,מסד זה\n',
      }, 'אין ספר בשם "ספר חסר"');
    });

    test('edition with a different line count', () {
      expectError({
        'editions/ספר א/אחרת.txt': '<h1>ספר א</h1>\nשורה\n',
      }, 'מספר השורות');
    });

    test('duplicate title in two folders', () {
      expectError({'books/אחרת/ספר א.txt': 'טקסט\n'}, 'כותרת כפולה');
    });

    test('metadata of an unknown book, unknown key and unknown generation', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'metadata.json': jsonEncode({
              'אין כזה': {'author': 'x'},
              'ספר א': {'autor': 'x', 'generation': 'דור לא קיים'},
            }),
          },
        ),
      ).join('\n');
      expect(errors, contains('אין ספר בשם "אין כזה"'));
      expect(errors, contains('מפתח לא מוכר "autor"'));
      expect(errors, contains('דור לא מוכר'));
    });

    test('category settings for a missing folder', () {
      expectError({
        'categories.json': jsonEncode({
          'אין/כזו': {'order': 1},
        }),
      }, 'אין תיקייה');
    });

    test('alt-toc node out of range', () {
      expectError({
        'alt_toc/ספר א_alt_toc.json': jsonEncode([
          {
            'key': 'k',
            'nodes': [
              {'heTitle': 'x', 'line': 40},
            ],
          },
        ]),
      }, 'מחוץ לטווח');
    });

    test('default commentator that does not exist', () {
      expectError({
        'default_commentators.json': jsonEncode([
          {
            'book': 'ספר א',
            'commentators': ['אין כזה'],
          },
        ]),
      }, 'אין ספר בשם "אין כזה"');
    });

    test('external default commentator errors', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'default_commentators.json': jsonEncode([
              {
                'book': 'בראשית',
                'target_library': 'official',
                'commentators': ['אין כזה'],
              },
              {
                'book': 'בראשית',
                'target_library': 'otzaria.zmanenu',
                'commentators': ['ספר ב'],
              },
              {
                'book': 'שמות',
                'target_library': 'Bad Id!',
                'commentators': ['ספר ב'],
              },
              {
                'book': 'ויקרא',
                'target_library': 'official',
                'commentators': ['ספר ב'],
                'kind': 'x',
              },
            ]),
          },
        ),
      ).join('\n');
      expect(errors, contains('אין ספר בשם "אין כזה"'));
      expect(errors, contains('target_library הוא המסד הזה'));
      expect(errors, contains('target_library "Bad Id!" לא תקין'));
      expect(errors, contains('מפתח לא מוכר "kind"'));
    });

    test('unknown and missing link types', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'links/ספר א_links.json': jsonEncode([
              {
                'line_index_1': 2,
                'line_index_2': 2,
                'book_2': 'ספר ב',
                'Conection Type': 'comentary',
              },
              {'line_index_1': 3, 'line_index_2': 2, 'book_2': 'ספר ב'},
            ]),
          },
        ),
      ).join('\n');
      expect(errors, contains('סוג קישור לא מוכר "comentary"'));
      expect(errors, contains('חסר "Conection Type"'));
    });

    test('broken JSON reports the line and the column', () {
      expectError({
        'metadata.json': '{\n  "ספר א": {\n    "order": 1,\n  }\n}\n',
      }, 'metadata.json: JSON לא תקין (שורה 4, עמודה 3)');
    });

    test('a value of the wrong type is an error, not a crash', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'metadata.json': jsonEncode({
              'ספר א': {'order': '1', 'heShortDesc': true},
            }),
            'editions/ספר א/מנוקד.txt': '<h1>ספר א</h1>\nשורה\nשורה\n',
            'editions/ספר א/editions.json': jsonEncode({
              'מנוקד': {'priority': 'high'},
            }),
            'categories.json': jsonEncode({
              'קטגוריה': {'order': 1.5},
            }),
          },
        ),
      ).join('\n');
      expect(errors, contains('"order" צריך להיות מספר, לא מחרוזת'));
      expect(
        errors,
        contains('"heShortDesc" צריך להיות מחרוזת, לא true/false'),
      );
      expect(errors, contains('"priority" צריך להיות מספר, לא מחרוזת'));
      expect(errors, contains('"order" צריך להיות מספר שלם, לא שבר'));
    });

    test('a title with " suggests ״', () {
      final errors = errorsOf(
        makeSource(
          files: {
            'books/תנ״ך/ספר ג.txt': 'טקסט\n',
            'books/תנ״ך/פירוש ג״ה.txt': 'טקסט\n',
            'metadata.json': jsonEncode({
              'פירוש ג"ה': {'order': 1},
              'פירוש ד"ה': {'order': 1},
            }),
          },
        ),
      ).join('\n');
      expect(errors, contains('האם התכוונתם ל"פירוש ג״ה"'));
      expect(errors, contains('בכותרות כותבים ״ (גרשיים עבריים)'));
    });

    test('a book that is not a text file', () {
      expectError({'books/קטגוריה/מאמר.pdf': '%PDF'}, 'רק ספרי טקסט');
    });

    test('a non-text file anywhere in the source tree', () {
      final errors = errorsOf(
        makeSource(
          files: {'images/תמונה.png': 'x', 'editions/ספר א/מהדורה.docx': 'x'},
        ),
      ).join('\n');
      expect(errors, contains('images/תמונה.png: קובץ שאינו טקסט'));
      expect(errors, contains('מותרים רק קובצי .txt ו-editions.json'));
    });

    test('a binary .txt file', () {
      expectError({'books/קטגוריה/ספר ג.txt': 'אב\u0000ג\n'}, 'קובץ בינארי');
    });

    test('empty heading', () {
      expectError({'books/קטגוריה/ספר ג.txt': '<h2></h2>\nטקסט\n'}, 'ריקה');
    });
  });

  test('a book directly under books/ has no category', () {
    final result = run(makeSource(files: {'books/ספר ג.txt': 'טקסט\n'}));
    final db = sqlite3.open(result.dbPath, mode: OpenMode.readOnly);
    addTearDown(db.close);
    final row = db
        .select("SELECT categoryId FROM book WHERE title = 'ספר ג'")
        .single;
    expect(row['categoryId'], 0);
    expect(db.select('SELECT 1 FROM category WHERE id = 0'), isEmpty);
    expect(
      db.select(
        "SELECT 1 FROM book_topic t JOIN book b ON b.id = t.bookId "
        "WHERE b.title = 'ספר ג'",
      ),
      isEmpty,
    );
  });

  test('desktop.ini and Thumbs.db are ignored everywhere', () {
    final source = makeSource(
      files: {
        'desktop.ini': '[.ShellClassInfo]',
        'books/קטגוריה/desktop.ini': '[.ShellClassInfo]',
        'books/קטגוריה/Thumbs.db': 'x',
        'links/Thumbs.db': 'x',
      },
    );
    expect(run(source).source.books, hasLength(2));
  });

  test('names that Windows does not allow', () {
    expect(windowsNameProblem('תנ״ך'), isNull);
    expect(windowsNameProblem('ספר א.txt'), isNull);
    expect(windowsNameProblem('תנ"ך'), contains('״'));
    for (final bad in [
      'א:ב',
      'מה?',
      'כוכב*',
      'א<ב',
      'א>ב',
      'א|ב',
      'ספר.',
      'ספר ',
      'CON',
      'con.txt',
      'Lpt1.json',
      'nul .txt',
    ]) {
      expect(windowsNameProblem(bad), isNotNull, reason: bad);
    }
  });

  group('text helpers', () {
    test('visible characters skip tags and count an entity once', () {
      expect(countVisibleChars('<b>אב</b>&amp;ג'), 4);
      expect(countVisibleChars('<b>אב</b>גד', 9), 2);
    });

    test('dibbur hamatchil key', () {
      expect(leadingBoldText('<b>על היין.</b> ושיעור'), 'על היין.');
      expect(dhKey('ד"ה עַל־הַיַּיִן.'), 'דה על היין');
      expect(leadingBoldText('ללא הדגשה'), isNull);
    });

    test('connection types follow the official mapping', () {
      expect(connectionTypeName('Commentary'), 'COMMENTARY');
      expect(connectionTypeName('related passage'), 'RELATED');
      expect(connectionTypeName('other'), 'OTHER');
      expect(connectionTypeName(null), isNull);
      expect(connectionTypeName('linker'), isNull);
      expect(connectionTypeName('comentary'), isNull);
    });

    test('csv with quotes', () {
      expect(parseCsv('a,"b,""c"""\r\nd,e\n'), [
        ['a', 'b,"c"'],
        ['d', 'e'],
      ]);
    });
  });
}

Map<String, int> _ids(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    return {
      for (final r in db.select('SELECT id, title FROM book'))
        r['title'] as String: r['id'] as int,
    };
  } finally {
    db.close();
  }
}

Map<String, int> _categoryIds(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    return {
      for (final r in db.select('SELECT id, title FROM category'))
        r['title'] as String: r['id'] as int,
    };
  } finally {
    db.close();
  }
}
