// The fixture file is copied as-is from the Otzaria app
// (test/fixtures/ref_key_fixtures.json). Refresh it when the app changes it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zmanenu_builder/zmanenu_builder.dart';

void main() {
  final fixtures =
      jsonDecode(File('test/fixtures/ref_key_fixtures.json').readAsStringSync())
          as Map<String, dynamic>;

  test('refKeys match the app', () {
    for (final f in fixtures['refKeys'] as List) {
      expect(
        buildRefKey(f['input'] as String),
        f['key'],
        reason: '${f['input']}',
      );
      if (f['key'] != null) expect(refKeyHash(f['key'] as String), f['hash']);
    }
  });

  test('lineKeys match the app', () {
    for (final f in fixtures['lineKeys'] as List) {
      final aliases = (f['aliases'] as List).cast<String>();
      expect(
        buildLineRefKey(f['heRef'] as String, aliases),
        f['key'],
        reason: '${f['heRef']}',
      );
    }
  });

  test('partial keys match the app', () {
    for (final f in fixtures['partialLineKeys'] as List) {
      final aliases = (f['aliases'] as List).cast<String>();
      expect(partialLineRefKeys(f['heRef'] as String, aliases), [
        for (final k in f['keys'] as List) k['key'],
      ], reason: '${f['heRef']}');
      for (final k in f['keys'] as List) {
        expect(refKeyHash(k['key'] as String), k['hash']);
      }
    }
    for (final f in fixtures['partialRefKeys'] as List) {
      expect(buildPartialRefKey(f['input'] as String), f['key']);
    }
  });

  test('an Otzaria-style heRef keys to the 1-based line number', () {
    expect(buildLineRefKey('ספר דוגמה 12', ['ספר דוגמה']), '12');
  });
}
