import 'dart:convert';
import 'dart:io';

import 'issues.dart';

/// The generations the app groups commentators by
/// (`_eraCategories` in lib/utils/text/text_manipulation.dart).
const Set<String> kKnownGenerations = {
  'תורה שבכתב',
  'חז"ל',
  'ראשונים',
  'אחרונים',
  'מחברי זמננו',
};

final RegExp _slug = RegExp(r'^[\p{Ll}\p{Lo}\p{N}._-]{1,64}$', unicode: true);

/// Same rule as `BookSource.isValidSlug` after the app's sanitising: letters
/// (lower-case or Hebrew), digits, `.`, `_`, `-`, at most 64 characters.
bool isValidLibraryId(String id) =>
    _slug.hasMatch(id) &&
    id.runes.length <= 64 &&
    !id.startsWith('.') &&
    !id.startsWith('-') &&
    !id.endsWith('.') &&
    !id.endsWith('-');

/// `library.json`: the identity of the database. These values go to
/// `schema_meta`; `library_id`, the manifest URL and the key must never change.
class LibraryConfig {
  LibraryConfig({
    required this.libraryId,
    required this.libraryName,
    required this.libraryFolder,
    required this.updateManifestUrl,
    required this.updatePublicKey,
    required this.defaultGeneration,
    required this.dbFileName,
    this.description,
    this.author,
  });

  final String libraryId;
  final String libraryName;
  final String? libraryFolder;
  final String? updateManifestUrl;
  final String? updatePublicKey;
  final String? defaultGeneration;
  final String dbFileName;
  final String? description;
  final String? author;

  static const _keys = {
    'library_id',
    'library_name',
    'library_folder',
    'update_manifest_url',
    'update_public_key',
    'default_generation',
    'db_file_name',
    'description',
    'author',
  };

  static LibraryConfig load(String path, Issues issues) {
    final where = 'library.json';
    final file = File(path);
    if (!file.existsSync()) {
      issues.error(where, 'הקובץ חסר ($path).');
      throw BuildFailed(issues.all);
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      issues.error(where, 'JSON לא תקין: ${e.message}');
      throw BuildFailed(issues.all);
    }
    if (json is! Map<String, dynamic>) {
      issues.error(where, 'צריך להיות אובייקט JSON.');
      throw BuildFailed(issues.all);
    }
    final map = json;
    for (final key in map.keys) {
      if (!_keys.contains(key)) issues.warn(where, 'מפתח לא מוכר "$key".');
    }
    String? str(String key) {
      final v = map[key];
      if (v == null) return null;
      if (v is! String) {
        issues.error(where, '"$key" צריך להיות מחרוזת.');
        return null;
      }
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    final id = str('library_id');
    if (id == null || !isValidLibraryId(id)) {
      issues.error(
        where,
        '"library_id" חסר או לא תקין: אותיות קטנות/עבריות, ספרות, "." "_" "-", עד 64 תווים.',
      );
    }
    final name = str('library_name');
    if (name == null) issues.error(where, '"library_name" חסר.');
    final folder = str('library_folder');
    if (folder != null &&
        (folder.contains('/') ||
            folder.contains('\\') ||
            folder.runes.length > 64 ||
            folder == 'ספרים אישיים')) {
      issues.error(
        where,
        '"library_folder" לא תקין: בלי / או \\, עד 64 תווים, ולא "ספרים אישיים" '
        '(האפליקציה מתעלמת מערך כזה).',
      );
    }
    final url = str('update_manifest_url');
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        issues.error(where, '"update_manifest_url" חייב להיות כתובת https.');
      }
    }
    final key = str('update_public_key');
    if (key != null) {
      List<int>? bytes;
      try {
        bytes = base64.decode(key);
      } on FormatException {
        bytes = null;
      }
      if (bytes == null || bytes.length != 32) {
        issues.error(
          where,
          '"update_public_key" חייב להיות מפתח ed25519 ציבורי ב-base64 (32 בתים).',
        );
      }
    }
    if ((url == null) != (key == null)) {
      issues.warn(
        where,
        'רק אחד מ-"update_manifest_url"/"update_public_key" מוגדר: המסד לא יתעדכן.',
      );
    }
    final generation = str('default_generation');
    if (generation != null && !kKnownGenerations.contains(generation)) {
      issues.error(
        where,
        '"default_generation" "$generation" אינו דור מוכר: ${kKnownGenerations.join(', ')}.',
      );
    }
    final dbFileName = str('db_file_name') ?? 'library.db';
    if (!dbFileName.endsWith('.db') ||
        dbFileName.contains('/') ||
        dbFileName.contains('\\')) {
      issues.error(where, '"db_file_name" צריך להיות שם קובץ שמסתיים ב-.db.');
    }
    if (issues.hasErrors) throw BuildFailed(issues.all);
    return LibraryConfig(
      libraryId: id!,
      libraryName: name!,
      libraryFolder: folder,
      updateManifestUrl: url,
      updatePublicKey: key,
      defaultGeneration: generation,
      dbFileName: dbFileName,
      description: str('description'),
      author: str('author'),
    );
  }
}
