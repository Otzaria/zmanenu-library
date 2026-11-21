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
