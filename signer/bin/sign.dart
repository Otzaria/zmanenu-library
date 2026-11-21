// חותם את manifest.json של העדכונים ב-ed25519 וכותב לידו manifest.json.sig.
//
//   ZMANENU_SIGNING_KEY=<base64> dart run bin/sign.dart <manifest.json>
//       --public-key <base64> [--library-id <id>] [--db-version <n>]
//
// המפתח הפרטי (זרע של 32 בתים ב-base64) נקרא רק ממשתנה הסביבה ואינו מודפס לעולם.
// הפורמט זהה ל-AttachedUpdateSignature באפליקציה: קובץ החתימה הוא base64 של 64
// בתים ושורה חדשה, על הבתים המדויקים של המניפסט.
//
// קוד יציאה: 0 הצלחה, 1 כשל, 64 שימוש שגוי.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pinenacl/ed25519.dart' as ed;

const _usage = '''
Usage: ZMANENU_SIGNING_KEY=<base64> dart run bin/sign.dart <manifest.json>
         --public-key <base64> [--library-id <id>] [--db-version <n>]
''';

const _keyVariable = 'ZMANENU_SIGNING_KEY';

void main(List<String> args) {
  final positional = <String>[];
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      positional.add(arg);
    } else if (i + 1 < args.length) {
      options[arg.substring(2)] = args[++i];
    } else {
      positional.clear();
      break;
    }
  }
  final publicKey = options['public-key'];
  if (positional.length != 1 || publicKey == null) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  try {
    final path = sign(
      manifestPath: positional.single,
      privateKey: Platform.environment[_keyVariable],
      publicKey: publicKey,
      libraryId: options['library-id'],
      dbVersion: options['db-version'],
    );
    stdout.writeln('Signature written to $path');
  } on SignException catch (e) {
    stderr.writeln('ERROR: ${e.message}');
    exitCode = 1;
  }
}

class SignException implements Exception {
  const SignException(this.message);

  final String message;
}

/// Signs [manifestPath] and returns the path of the signature file.
String sign({
  required String manifestPath,
  required String? privateKey,
  required String publicKey,
  String? libraryId,
  String? dbVersion,
}) {
  final seed = _decode(privateKey?.trim() ?? '', 32);
  if (seed == null) {
    // The value itself is never printed, not even in part.
    throw const SignException(
      '$_keyVariable is missing or is not a 32-byte base64 key.',
    );
  }
  final signingKey = ed.SigningKey.fromSeed(seed);
  final derived = base64.encode(signingKey.verifyKey.asTypedList);
  if (derived != publicKey.trim()) {
    throw SignException(
      'The signing key belongs to public key $derived, not to the '
      'update_public_key $publicKey.',
    );
  }

  final file = File(manifestPath);
  if (!file.existsSync()) throw SignException('No file $manifestPath.');
  final bytes = file.readAsBytesSync();
  _checkManifest(bytes, libraryId, dbVersion);

  final signature = signingKey.sign(bytes).signature.asTypedList;
  if (!signingKey.verifyKey.verify(
    signature: ed.Signature(signature),
    message: bytes,
  )) {
    throw const SignException('The new signature does not verify.');
  }
  final path = '$manifestPath.sig';
  File(path).writeAsStringSync('${base64.encode(signature)}\n');
  return path;
}

void _checkManifest(Uint8List bytes, String? libraryId, String? dbVersion) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw SignException('The manifest is not valid JSON: ${e.message}');
  }
  if (json is! Map<String, dynamic> ||
      json['format'] is! int ||
      json['full'] is! Map) {
    throw const SignException('The manifest is not an update manifest.');
  }
  if (libraryId != null && json['library_id'] != libraryId) {
    throw SignException(
      'The manifest library_id is "${json['library_id']}", not "$libraryId".',
    );
  }
  if (dbVersion != null && '${json['db_version']}' != dbVersion) {
    throw SignException(
      'The manifest db_version is ${json['db_version']}, not $dbVersion.',
    );
  }
}

Uint8List? _decode(String text, int length) {
  try {
    final bytes = base64.decode(text);
    return bytes.length == length ? bytes : null;
  } on FormatException {
    return null;
  }
}
