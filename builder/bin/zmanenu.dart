// בונה את מסד "מחברי זמננו" מעץ המקור.
//
//   dart run bin/zmanenu.dart build --source <dir> --out <dir> --db-version <n>
//       [--library <library.json>] [--previous-db <old.db>]
//       [--official-db <seforim.db>] [--manifest-url <https://...>]
//       [--release] [--allow-removed-books]
//
// קוד יציאה: 0 הצלחה, 1 שגיאות במקור, 64 שימוש שגוי.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zmanenu_builder/zmanenu_builder.dart';

const _usage = '''
Usage: dart run bin/zmanenu.dart build --source <dir> --out <dir> --db-version <n>
         [--library <library.json>] [--previous-db <old.db>]
         [--official-db <seforim.db>] [--manifest-url <https://...>]
         [--release] [--allow-removed-books]

  --source       source root (books/, metadata.json, links/ ...)
  --library      library.json (default: <source>/../library.json)
  --previous-db  last published database; book ids are carried over from it
  --official-db  official seforim.db, to check external link targets
  --release      a build to publish: no books, or a book of --previous-db that
                 is gone without renamedFrom, is an error
  --allow-removed-books  with --release: a gone book is only a warning
''';

const _flags = {'release', 'allow-removed-books'};

void main(List<String> args) {
  if (args.isEmpty || args.first != 'build') {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  final values = <String, String>{};
  final flags = <String>{};
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--') && _flags.contains(arg.substring(2))) {
      flags.add(arg.substring(2));
      continue;
    }
    if (!arg.startsWith('--') || i + 1 >= args.length) {
      stderr.write(_usage);
      exitCode = 64;
      return;
    }
    values[arg.substring(2)] = args[++i];
  }
  final sourceDir = values['source'];
  final outDir = values['out'];
  final rawVersion = values['db-version'];
  final version = int.tryParse(rawVersion ?? '');
  if (rawVersion != null && version == null) {
    stderr.writeln('--db-version "$rawVersion" אינו מספר שלם.');
    exitCode = 64;
    return;
  }
  if (sourceDir == null || outDir == null || version == null) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  try {
    final result = build(
      BuildOptions(
        sourceDir: sourceDir,
        libraryJson:
            values['library'] ?? p.join(sourceDir, '..', 'library.json'),
        outDir: outDir,
        dbVersion: version,
        previousDb: values['previous-db'],
        officialDb: values['official-db'],
        manifestUrlOverride: values['manifest-url'],
        release: flags.contains('release'),
        allowRemovedBooks: flags.contains('allow-removed-books'),
      ),
    );
    for (final w in result.warnings) {
      stderr.writeln(w);
    }
    final s = result.source;
    stdout.writeln(
      'OK: ${result.dbPath} (db_version $version): ${s.books.length} ספרים, '
      '${s.categories.length} קטגוריות, ${s.links.length} קישורים פנימיים, '
      '${s.externalLinks.length} קישורים חיצוניים.',
    );
  } on BuildFailed catch (e) {
    final errors = e.issues.where((i) => i.isError).length;
    for (final issue in e.issues) {
      stderr.writeln(issue);
    }
    stderr.writeln('הבנייה נכשלה: $errors שגיאות.');
    exitCode = 1;
  }
}
