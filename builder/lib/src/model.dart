/// The source tree after reading and validation, ready to be written.
library;

class CategoryNode {
  CategoryNode(this.path);

  /// Folder names from the `books/` root.
  final List<String> path;
  int id = 0;
  int? parentId;
  int order = 999;
  String? heShortDesc;
  String? heDesc;

  String get key => path.join('/');
  String get title => path.last;
  int get level => path.length - 1;
}

class Heading {
  Heading(this.lineIndex, this.level, this.text);

  final int lineIndex;
  final int level;
  final String text;
}

class BookSource {
  BookSource({
    required this.title,
    required this.categoryPath,
    required this.relPath,
    required this.absPath,
  });

  final String title;
  final List<String> categoryPath;

  /// Path of the source file relative to the source root (for messages).
  final String relPath;
  final String absPath;

  List<String> lines = const [];
  List<Heading> headings = const [];
  Set<int> headingLines = const {};

  int id = 0;
  int order = 999;
  String? heShortDesc;
  String? heDesc;
  List<String> authors = const [];
  String? pubDate;
  String? pubPlace;
  List<String> generations = const [];
  List<String> acronyms = const [];
  List<String> renamedFrom = const [];
  List<String> topics = const [];
  bool dibburHamatchil = false;
  bool isBaseBook = false;
  String get categoryKey => categoryPath.join('/');
}

/// A link between two books of this database (`link` table).
class InternalLink {
  InternalLink({
    required this.source,
    required this.sourceLine,
    required this.target,
    required this.targetLine,
    required this.type,
  });

  final BookSource source;
  final int sourceLine;
  final BookSource target;
  final int targetLine;
  final String type;

  /// `link_anchor` on the stored source side, in visible characters.
  int? anchorStart;
  int? anchorEnd;
  String? anchorLabel;

  /// Last line (0-based, inclusive) of a ranged side: 0 = source, 1 = target.
  int? sourceEnd;
  int? targetEnd;
}

/// A link to a book in another database (`external_link`).
class ExternalLink {
  ExternalLink({
    required this.source,
    required this.sourceLine,
    required this.targetSource,
    required this.targetTitle,
    required this.targetRef,
    required this.targetLine,
    required this.type,
  });

  final BookSource source;
  final int sourceLine;
  final String? targetSource;
  final String targetTitle;
  final String? targetRef;
  final int? targetLine;
  final String type;
}

class AltTocNode {
  AltTocNode(this.heTitle, this.lineIndex, this.children);

  final String heTitle;
  final int lineIndex;
  final List<AltTocNode> children;
}

class AltTocStructure {
  AltTocStructure(this.book, this.key, this.title, this.heTitle, this.nodes);

  final BookSource book;
  final String key;
  final String? title;
  final String? heTitle;
  final List<AltTocNode> nodes;
}

/// `book_version_link`: a book of this database as a version of another book.
class VersionLink {
  VersionLink({
    required this.version,
    required this.primarySource,
    required this.primaryTitle,
    this.primaryCategoryPath,
    this.versionTitle,
    this.versionNotes,
    this.priority,
  });

  final BookSource version;
  final String primarySource;
  final String primaryTitle;
  final String? primaryCategoryPath;
  final String? versionTitle;
  final String? versionNotes;
  final double? priority;
}

/// `book_version` + `version_line`: an alternative text of the same book,
/// line by line.
class Edition {
  Edition({
    required this.book,
    required this.title,
    this.lines,
    this.source,
    this.license,
    this.notes,
    this.priority,
  });

  final BookSource book;
  final String title;

  /// null for the metadata-only row of the base text.
  final List<String>? lines;
  final String? source;
  final String? license;
  final String? notes;
  final double? priority;
}

class DefaultSlot {
  DefaultSlot(this.book, this.target, this.position);

  final BookSource book;
  final BookSource target;
  final int position;
}

/// `external_default_commentator`: a book of this database as a default
/// commentator or targum of a book in another database.
class ExternalDefault {
  ExternalDefault({
    required this.targetSource,
    required this.targetTitle,
    required this.book,
    required this.kind,
    required this.position,
  });

  /// 'official', another library_id, or null for any source.
  final String? targetSource;
  final String targetTitle;
  final BookSource book;

  /// 'commentator' or 'targum'.
  final String kind;
  final int position;
}

class LibrarySource {
  final List<CategoryNode> categories = [];
  final List<BookSource> books = [];
  final List<InternalLink> links = [];
  final List<ExternalLink> externalLinks = [];
  final List<AltTocStructure> altTocs = [];
  final List<VersionLink> versionLinks = [];
  final List<Edition> editions = [];
  final List<DefaultSlot> defaultCommentators = [];
  final List<DefaultSlot> defaultTargums = [];
  final List<ExternalDefault> externalDefaults = [];

  /// Stored in schema_meta so ids of deleted books are never reused.
  int nextBookId = 1;

  /// Category ids of the previous release by path ([CategoryNode.key]): the app
  /// keys hidden books and per-book settings by category id.
  final Map<String, int> previousCategoryIds = {};
  int nextCategoryId = 1;
}
