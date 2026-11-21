/// A problem found in the source tree. Errors stop the build; warnings do not.
class Issue {
  const Issue(this.isError, this.where, this.message);

  final bool isError;

  /// File (relative to the source root) and, when known, the entry inside it.
  final String where;
  final String message;

  @override
  String toString() => '${isError ? 'שגיאה' : 'אזהרה'}: $where: $message';
}

class Issues {
  final List<Issue> all = [];

  void error(String where, String message) =>
      all.add(Issue(true, where, message));

  void warn(String where, String message) =>
      all.add(Issue(false, where, message));

  bool get hasErrors => all.any((i) => i.isError);

  Iterable<Issue> get errors => all.where((i) => i.isError);
}

/// Thrown when the build cannot continue; carries every issue collected.
class BuildFailed implements Exception {
  BuildFailed(this.issues);

  final List<Issue> issues;

  @override
  String toString() => issues.join('\n');
}

/// Where [offset] falls in [text], as "line L, column C" (both from 1).
String textPosition(String text, int offset) {
  var line = 1;
  var column = 1;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return 'שורה $line, עמודה $column';
}

/// The message of a JSON [FormatException], with the line and column.
String jsonErrorMessage(FormatException e, String text) {
  final offset = e.offset;
  final at = offset == null ? '' : ' (${textPosition(text, offset)})';
  return 'JSON לא תקין$at: ${e.message}';
}
