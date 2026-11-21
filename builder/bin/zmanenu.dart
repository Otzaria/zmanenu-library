// בונה את מסד "מחברי זמנינו" מעץ המקור.
//
//   dart run bin/zmanenu.dart build --source <dir> --out <dir> --db-version <n>
//       [--library <library.json>] [--previous-db <old.db>]
//       [--official-db <seforim.db>] [--manifest-url <https://...>]
//
// קוד יציאה: 0 הצלחה, 1 שגיאות במקור, 64 שימוש שגוי.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zmanenu_builder/zmanenu_builder.dart';

const _usage = '''
Usage: dart run bin/zmanenu.dart build --source <dir> --out <dir> --db-version <n>
         [--library <library.json>] [--previous-db <old.db>]
         [--official-db <seforim.db>] [--manifest-url <https://...>]

  --source       source root (books/, metadata.json, links/ ...)
  --library      library.json (default: <source>/../library.json)
  --previous-db  last published database; book ids are carried over from it
  --official-db  official seforim.db, to check external link targets
''';

void main(List<String> args) {
  if (args.isEmpty || args.first != 'build') {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  final values = <String, String>{};
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--') || i + 1 >= args.length) {
      stderr.write(_usage);
      exitCode = 64;
      return;
    }
    values[arg.substring(2)] = args[++i];
  }
  final sourceDir = values['source'];
  final outDir = values['out'];
  final version = int.tryParse(values['db-version'] ?? '');
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
