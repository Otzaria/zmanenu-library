#!/usr/bin/env bash
# Runs the publisher tools of the Otzaria app from a checkout of Otzaria/otzaria
# (path in $OTZARIA_DIR, after `flutter pub get`).
#
#   scripts/otzaria-tools.sh validate <db>...      tool/validate_personal_db.dart
#   scripts/otzaria-tools.sh update <command> ...   tool/personal_db_update.dart
#
# Paths must be absolute: the tools run from $OTZARIA_DIR.
#
# tool/personal_db_update.dart imports package:flutter/foundation (through
# attached_update_artifact_planner.dart and native_sha256.dart), so `dart run`
# cannot compile it. Until the app fixes that, the default runner executes the
# unchanged tool under `flutter test` through a generated one-test file.
# Set OTZARIA_UPDATE_RUNNER=dart once `dart run tool/personal_db_update.dart`
# works again.
set -euo pipefail

: "${OTZARIA_DIR:?set OTZARIA_DIR to a checkout of Otzaria/otzaria}"
runner="${OTZARIA_UPDATE_RUNNER:-flutter-test}"

command="${1:-}"
shift || true

case "$command" in
  validate)
    cd "$OTZARIA_DIR"
    dart run tool/validate_personal_db.dart "$@"
    ;;
  update)
    cd "$OTZARIA_DIR"
    if [ "$runner" = "dart" ]; then
      dart run tool/personal_db_update.dart "$@"
      exit $?
    fi
    runner_test="test/zz_zmanenu_tool_runner_test.dart"
    cat > "$runner_test" <<'DART'
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/personal_db_update.dart' as update_tool;

void main() {
  test('personal_db_update', () async {
    final args = (jsonDecode(Platform.environment['OTZ_TOOL_ARGS']!) as List)
        .cast<String>();
    exitCode = 0;
    await update_tool.main(args);
    final code = exitCode;
    exitCode = 0;
    expect(code, 0, reason: 'personal_db_update exited with $code');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
DART
    OTZ_TOOL_ARGS="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@")" \
      flutter test "$runner_test" --reporter expanded
    ;;
  *)
    echo "usage: $0 validate <db>... | update <command> ..." >&2
    exit 64
    ;;
esac
