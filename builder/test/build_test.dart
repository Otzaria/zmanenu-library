import 'dart:convert';
import 'dart:io';

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
}) => build(
  BuildOptions(
    sourceDir: source,
    libraryJson: libraryJson,
    outDir: p.join(temp.path, out),
    dbVersion: version,
    previousDb: previous,
  ),
);

/// The error messages of a build that must fail.
List<String> errorsOf(String source) {
  try {
    run(source);
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
          {'line_index_1': 2, 'book_2': 'בראשית', 'target_library': 'official'},
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

    test('book directly under books/', () {
      expectError({'books/ספר ג.txt': 'טקסט\n'}, 'יש לשים כל ספר בתוך תיקייה');
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
      expect(connectionTypeName(null), 'OTHER');
      expect(connectionTypeName('linker'), isNull);
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
