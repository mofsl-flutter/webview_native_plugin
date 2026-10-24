// The script `ChartSession.fillMissingCandles` injects, run for real in Node against a stand-in for
// the page's `window`. Node is not a Flutter dependency, so without it the tests are skipped.
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:ios_webview_plugin/chart_session.dart";

const String _runner = r'''
const script = JSON.parse(process.argv[1]);
const withFunction = process.argv[2] === "with";
const calls = [];
const window = withFunction
  ? { FillMissingCandles: function () { calls.push(Array.from(arguments)); return Promise.resolve([]); } }
  : {};
try {
  const result = new Function("window", script)(window);
  console.log(JSON.stringify({ calls, returnedPromise: typeof result.then === "function" }));
} catch (e) {
  console.log(JSON.stringify({ threw: String(e.message) }));
}
''';

Map<String, Object?> _run(String script, {required bool pageHasFunction}) {
  final ProcessResult r = Process.runSync(
    "node",
    <String>["-e", _runner, jsonEncode(script), pageHasFunction ? "with" : "without"],
  );
  expect(r.exitCode, 0, reason: "${r.stdout}\n${r.stderr}");
  return jsonDecode((r.stdout as String).trim()) as Map<String, Object?>;
}

void main() {
  final bool hasNode = Process.runSync("node", <String>["--version"]).exitCode == 0;
  final String? skip = hasNode ? null : "node is not on PATH";

  test("it calls the page with the symbol, exactly, and hands back the page's promise", () {
    final Map<String, Object?> out =
        _run(ChartSession.fillMissingCandlesScript("0:22"), pageHasFunction: true);
    expect(out["calls"], <Object?>[
      <Object?>["0:22"],
    ]);
    expect(out["returnedPromise"], isTrue, reason: "runOperation waits on a returned promise");
  }, skip: skip);

  test("a symbol with quotes and backslashes survives", () {
    const String awkward = r'A"B\'
        "'C\n</script>";
    final Map<String, Object?> out =
        _run(ChartSession.fillMissingCandlesScript(awkward), pageHasFunction: true);
    expect(out["calls"], <Object?>[
      <Object?>[awkward],
    ]);
  }, skip: skip);

  test("with no symbol the page is asked to fill every chart", () {
    final Map<String, Object?> out =
        _run(ChartSession.fillMissingCandlesScript(null), pageHasFunction: true);
    expect(out["calls"], <Object?>[<Object?>[]], reason: "no argument at all, not null or empty");
  }, skip: skip);

  test("a page without the function is reported, not silently ignored", () {
    final Map<String, Object?> out =
        _run(ChartSession.fillMissingCandlesScript("0:22"), pageHasFunction: false);
    expect(out["threw"], allOf(contains("cannot fill missing candles"), contains("bundled")));
  }, skip: skip);
}
