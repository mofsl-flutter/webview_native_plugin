// Runs the Node tests for the chart page's own scripts (tool/js_test/) as part of `flutter test`.
//
// The scripts are plain browser JavaScript with no build step, so the tests load them into a
// `node:vm` context. Node is not a Flutter dependency, so when it is missing the test is skipped
// with that reason rather than failing a Dart-only environment.
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  final ProcessResult probe = _node(<String>["--version"]);
  final bool hasNode = probe.exitCode == 0;

  test(
    "page scripts pass their Node tests",
    () {
      // Explicit files: `node --test <directory>` is not expanded by every Node version.
      final List<String> files = <String>[
        for (final FileSystemEntity e in Directory("tool/js_test").listSync())
          if (e is File && e.path.endsWith(".test.mjs")) e.path,
      ]..sort();
      expect(files, isNotEmpty);
      final ProcessResult r = _node(<String>["--test", ...files]);
      expect(r.exitCode, 0, reason: "${r.stdout}\n${r.stderr}");
    },
    skip: hasNode ? false : "node is not on PATH; run `node --test tool/js_test/*.test.mjs` where it is",
  );
}

ProcessResult _node(List<String> args) {
  try {
    return Process.runSync("node", args);
  } on ProcessException {
    return ProcessResult(0, 127, "", "node not found");
  }
}
