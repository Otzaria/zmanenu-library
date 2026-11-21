/// DDL in the shape of the official seforim.db (schema 7), with two
/// differences that personal databases allow: text stays in `line.content`
/// (no `line_content` split, no zstd dictionary), and `book` carries the
/// `fileType`/`filePath` columns of personal databases, always NULL here.
const List<String> kSchema = [
  '''CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)''',
  '''CREATE TABLE category (
    id INTEGER PRIMARY KEY NOT NULL, parentId INTEGER, title TEXT NOT NULL,
    level INTEGER NOT NULL DEFAULT 0, orderIndex INTEGER NOT NULL DEFAULT 999,
    heShortDesc TEXT DEFAULT NULL, heDesc TEXT DEFAULT NULL)''',
  '''CREATE TABLE category_closure (
    ancestorId INTEGER NOT NULL, descendantId INTEGER NOT NULL,
    PRIMARY KEY (ancestorId, descendantId))''',
  '''CREATE TABLE author (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE topic (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE pub_place (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE pub_date (id INTEGER PRIMARY KEY NOT NULL, date TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE source (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE book (
    id INTEGER PRIMARY KEY NOT NULL, categoryId INTEGER NOT NULL,
    sourceId INTEGER NOT NULL, title TEXT NOT NULL, heRef TEXT,
    heShortDesc TEXT, heDesc TEXT, notesContent TEXT,
    orderIndex INTEGER NOT NULL DEFAULT 999, totalLines INTEGER NOT NULL DEFAULT 0,
    isBaseBook INTEGER NOT NULL DEFAULT 0,
    hasTargumConnection INTEGER NOT NULL DEFAULT 0,
    hasReferenceConnection INTEGER NOT NULL DEFAULT 0,
    hasSourceConnection INTEGER NOT NULL DEFAULT 0,
    hasCommentaryConnection INTEGER NOT NULL DEFAULT 0,
    hasOtherConnection INTEGER NOT NULL DEFAULT 0,
    hasAltStructures INTEGER NOT NULL DEFAULT 0,
    hasTeamim INTEGER NOT NULL DEFAULT 0, hasNekudot INTEGER NOT NULL DEFAULT 0,
    dependenceType TEXT DEFAULT NULL, collectiveTitleHe TEXT DEFAULT NULL,
    collectiveTitleEn TEXT DEFAULT NULL, contentHash INTEGER NOT NULL DEFAULT 0,
    fileType TEXT DEFAULT NULL, filePath TEXT DEFAULT NULL)''',
  '''CREATE TABLE book_pub_place (bookId INTEGER NOT NULL, pubPlaceId INTEGER NOT NULL, PRIMARY KEY (bookId, pubPlaceId))''',
  '''CREATE TABLE book_pub_date (bookId INTEGER NOT NULL, pubDateId INTEGER NOT NULL, PRIMARY KEY (bookId, pubDateId))''',
  '''CREATE TABLE book_topic (bookId INTEGER NOT NULL, topicId INTEGER NOT NULL, PRIMARY KEY (bookId, topicId))''',
  '''CREATE TABLE book_author (bookId INTEGER NOT NULL, authorId INTEGER NOT NULL, PRIMARY KEY (bookId, authorId))''',
  '''CREATE TABLE generation (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE book_generation (bookId INTEGER NOT NULL, generationId INTEGER NOT NULL, PRIMARY KEY (bookId, generationId))''',
  '''CREATE TABLE line (
    id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL,
    lineIndex INTEGER NOT NULL, content TEXT NOT NULL, heRef TEXT,
    tocEntryId INTEGER, charCount INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE line_ref (
    bookId INTEGER NOT NULL, refKeyHash INTEGER NOT NULL, lineIndex INTEGER NOT NULL,
    PRIMARY KEY (bookId, refKeyHash, lineIndex)) WITHOUT ROWID''',
  '''CREATE TABLE line_dh (
    bookId INTEGER NOT NULL, dhText TEXT NOT NULL, lineIndex INTEGER NOT NULL,
    dhDisplay TEXT NOT NULL, PRIMARY KEY (bookId, dhText, lineIndex)) WITHOUT ROWID''',
  '''CREATE TABLE tocText (id INTEGER PRIMARY KEY NOT NULL, text TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE tocEntry (
    id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL, parentId INTEGER,
    textId INTEGER NOT NULL, level INTEGER NOT NULL, lineId INTEGER,
    isLastChild INTEGER NOT NULL DEFAULT 0, hasChildren INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE line_toc (lineId INTEGER PRIMARY KEY, tocEntryId INTEGER NOT NULL)''',
  '''CREATE TABLE connection_type (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE link (
    id INTEGER PRIMARY KEY NOT NULL, sourceBookId INTEGER NOT NULL,
    targetBookId INTEGER NOT NULL, sourceLineId INTEGER NOT NULL,
    targetLineId INTEGER NOT NULL, targetLineIndex INTEGER NOT NULL,
    targetBookOrderIndex INTEGER NOT NULL, connectionTypeId INTEGER NOT NULL,
    baseProvenance INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE link_anchor (
    linkId INTEGER NOT NULL, side INTEGER NOT NULL DEFAULT 0,
    charStart INTEGER NOT NULL, charEnd INTEGER, label TEXT,
    PRIMARY KEY (linkId, side, charStart))''',
  '''CREATE TABLE link_range (
    linkId INTEGER NOT NULL, side INTEGER NOT NULL, endLineId INTEGER NOT NULL,
    endLineIndex INTEGER NOT NULL, PRIMARY KEY (linkId, side))''',
  '''CREATE TABLE link_coverage (
    lineId INTEGER NOT NULL, linkId INTEGER NOT NULL, side INTEGER NOT NULL,
    PRIMARY KEY (lineId, linkId, side))''',
  '''CREATE TABLE book_has_links (
    bookId INTEGER PRIMARY KEY, hasSourceLinks INTEGER NOT NULL DEFAULT 0,
    hasTargetLinks INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE book_version (
    id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL,
    versionTitle TEXT NOT NULL, heVersionTitle TEXT, versionSource TEXT,
    priority REAL, license TEXT, versionNotes TEXT, heVersionNotes TEXT,
    hasContent INTEGER NOT NULL DEFAULT 0, UNIQUE (bookId, versionTitle))''',
  '''CREATE TABLE version_line (
    versionId INTEGER NOT NULL, lineId INTEGER NOT NULL, content TEXT,
    charCount INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (versionId, lineId))''',
  '''CREATE TABLE book_version_link (
    versionBookId INTEGER NOT NULL, primarySource TEXT, primaryTitle TEXT NOT NULL,
    primaryCategoryPath TEXT, versionTitle TEXT, versionNotes TEXT, priority REAL)''',
  '''CREATE TABLE alt_toc_structure (
    id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL, key TEXT NOT NULL,
    title TEXT, heTitle TEXT, UNIQUE (bookId, key))''',
  '''CREATE TABLE alt_toc_entry (
    id INTEGER PRIMARY KEY NOT NULL, structureId INTEGER NOT NULL, parentId INTEGER,
    textId INTEGER NOT NULL, level INTEGER NOT NULL, lineId INTEGER,
    isLastChild INTEGER NOT NULL DEFAULT 0, hasChildren INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE line_alt_toc (
    lineId INTEGER NOT NULL, structureId INTEGER NOT NULL,
    altTocEntryId INTEGER NOT NULL, PRIMARY KEY (lineId, structureId))''',
  '''CREATE TABLE book_acronym (bookId INTEGER NOT NULL, term TEXT NOT NULL, PRIMARY KEY (bookId, term))''',
  '''CREATE TABLE default_commentator (
    bookId INTEGER NOT NULL, commentatorBookId INTEGER NOT NULL,
    position INTEGER NOT NULL, PRIMARY KEY (bookId, commentatorBookId))''',
  '''CREATE TABLE default_targum (
    bookId INTEGER NOT NULL, targumBookId INTEGER NOT NULL,
    position INTEGER NOT NULL, PRIMARY KEY (bookId, targumBookId))''',
  '''CREATE TABLE external_link (
    sourceBookId INTEGER NOT NULL, sourceLineIndex INTEGER NOT NULL,
    targetSource TEXT, targetTitle TEXT NOT NULL, targetRef TEXT,
    targetLineIndex INTEGER, connectionType TEXT)''',
];

const List<String> kIndexes = [
  'CREATE INDEX idx_category_parent ON category(parentId)',
  'CREATE INDEX idx_book_category ON book(categoryId)',
  'CREATE INDEX idx_book_title ON book(title)',
  'CREATE INDEX idx_book_author_author ON book_author(authorId)',
  'CREATE INDEX idx_book_generation_generation ON book_generation(generationId)',
  'CREATE INDEX idx_line_book_index ON line(bookId, lineIndex, id)',
  'CREATE INDEX idx_toc_book ON tocEntry(bookId)',
  'CREATE INDEX idx_toc_parent ON tocEntry(parentId)',
  'CREATE INDEX idx_toc_line ON tocEntry(lineId)',
  'CREATE INDEX idx_toc_text_id ON tocEntry(textId)',
  'CREATE INDEX idx_linetoc_toc ON line_toc(tocEntryId)',
  'CREATE INDEX idx_link_source_book ON link(sourceBookId)',
  'CREATE INDEX idx_link_target_book ON link(targetBookId)',
  'CREATE INDEX idx_link_target_line ON link(targetLineId)',
  'CREATE INDEX idx_link_source_targetorder ON link(sourceLineId, targetBookOrderIndex, targetLineIndex)',
  'CREATE INDEX idx_link_type_target_line ON link(connectionTypeId, targetLineId)',
  'CREATE INDEX idx_link_coverage_link ON link_coverage(linkId)',
  'CREATE INDEX idx_book_version_book ON book_version(bookId)',
  'CREATE INDEX idx_version_line_line ON version_line(lineId)',
  'CREATE INDEX idx_alt_toc_structure_book ON alt_toc_structure(bookId)',
  'CREATE INDEX idx_alt_toc_entry_structure ON alt_toc_entry(structureId)',
  'CREATE INDEX idx_alt_toc_entry_parent ON alt_toc_entry(parentId)',
  'CREATE INDEX idx_line_alt_toc_entry ON line_alt_toc(altTocEntryId)',
  'CREATE INDEX idx_book_acronym_term ON book_acronym(term)',
  'CREATE INDEX idx_default_commentator_book ON default_commentator(bookId)',
  'CREATE INDEX idx_default_targum_book ON default_targum(bookId)',
  'CREATE INDEX idx_external_link_source ON external_link(sourceBookId, sourceLineIndex)',
];

/// `connection_type` rows, with the ids of the official database.
const List<String> kConnectionTypes = [
  'COMMENTARY',
  'SUPER_COMMENTARY',
  'TARGUM',
  'REFERENCE',
  'SOURCE',
  'MIDRASH',
  'QUOTATION',
  'MESORAT_HASHAS',
  'EIN_MISHPAT',
  'DIBUR_HAMATCHIL',
  'PARSHANUT',
  'MISHNAH_IN_TALMUD',
  'RELATED',
  'OTHER',
  'LINKER',
  'SIFREI_MITZVOT',
  'ESSAY',
  'ALLUSION',
  'LITURGY',
  'ELUCIDATION',
  'EXPLICATION',
  'LAW',
  'SUMMARY',
  'FOOTNOTES',
];
