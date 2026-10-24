import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/config/endpoints.dart';
import 'package:ios_webview_plugin_example/src/config/environment.dart';
import 'package:ios_webview_plugin_example/src/regression/production_guard.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario_catalog.dart';
import 'package:ios_webview_plugin_example/src/ui/environment_banner.dart';

const String _prodHost = '6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com';
const String _uatHost = 'tradingapi.motilaloswaluat.com';

/// The defaults are what these assert, so they only make sense when no environment flag was given.
String? get _onlyWithDefaults =>
    (kChartEnvName != 'prod' ||
        kAllowProdWrites ||
        const String.fromEnvironment('CHART_API_ROOT').isNotEmpty ||
        const String.fromEnvironment('CHART_CLIENT_CODE').isNotEmpty)
    ? 'a build flag changes the defaults this checks'
    : null;

void main() {
  group('with no flags the example app is on production', () {
    test('the environment is production', () {
      expect(kChartEnvName, 'prod');
      expect(kChartProd, isTrue);
    }, skip: _onlyWithDefaults);

    test(
      'the page it loads and the API it calls are the same server',
      () {
        expect(Uri.parse(kChartUrl).host, _prodHost);
        expect(Uri.parse(kChartRoot).host, _prodHost);
        expect(
          kChartUrl,
          startsWith(kChartRoot),
          reason: 'the page lives under the API root',
        );
        expect(
          kChartRoot,
          endsWith('/charts/'),
          reason: 'production says /charts/, UAT /chart/',
        );
        expect(kChartApiBase, '${kChartRoot}api');
      },
      skip: _onlyWithDefaults,
    );

    test(
      'the token is for the production test client, not the UAT one',
      () {
        expect(kDefaultClientCode, 'T029342');
      },
      skip: _onlyWithDefaults,
    );
  });

  group('CHART_ENV=uat restores the previous behaviour', () {
    // flutter test --dart-define=CHART_ENV=uat test/environment_test.dart
    test(
      'UAT page, UAT root and the UAT test client',
      () {
        expect(kChartProd, isFalse);
        expect(Uri.parse(kChartUrl).host, _uatHost);
        expect(
          kChartUrl,
          'https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html',
        );
        expect(Uri.parse(kChartRoot).host, _uatHost);
        expect(kDefaultClientCode, 'T06794');
      },
      skip: kChartEnvName == 'uat'
          ? false
          : 'run with --dart-define=CHART_ENV=uat',
    );

    test(
      'every case runs',
      () {
        for (final Scenario s in buildCatalog()) {
          expect(runsInThisEnvironment(s), isTrue, reason: s.id);
        }
      },
      skip: kChartEnvName == 'uat'
          ? false
          : 'run with --dart-define=CHART_ENV=uat',
    );
  });

  group('the production guard', () {
    final List<Scenario> catalog = buildCatalog();
    Scenario byId(String id) => catalog.firstWhere((Scenario s) => s.id == id);

    test(
      'decides by environment, what the case does, and the explicit override',
      () {
        bool runs(String id, {required bool production, bool writes = false}) =>
            caseRunsIn(byId(id), production: production, allowWrites: writes);
        // UAT: everything.
        expect(runs('T0', production: false), isTrue);
        expect(runs('S1', production: false), isTrue);
        // Production: only a case whose every step opens a chart and observes.
        expect(runs('L2', production: true), isTrue);
        expect(runs('T0', production: true), isFalse);
        expect(runs('S1', production: true), isFalse);
        // Production with the override: everything, because the person said so.
        expect(runs('S1', production: true, writes: true), isTrue);
      },
    );

    test(
      'exactly these cases run on production; a new open-only case widens this on purpose',
      () {
        // Each of these opens a chart and observes. Opening still makes the page record the symbol
        // as the account's last-viewed one, so a run on a real account ends with case O1 and
        // CHART_SYMBOL set to what the account had.
        final Set<String> allowed = <String>{
          for (final Scenario s in catalog)
            if (caseRunsIn(s, production: true, allowWrites: false)) s.id,
        };
        expect(allowed, <String>{
          'A1',
          'A5',
          'C7',
          'E3',
          'E4',
          'G2',
          'L1',
          'L2',
          'L3',
          'L4',
          'L5',
          'N1',
          'O1',
          'O2',
          'P1',
          'WC', //
        });
      },
    );

    test('the cases known to change an account do not run on production', () {
      // S1 adds and removes indicators and saves repeatedly, S2 and T0 change intervals and symbols.
      for (final String id in <String>['S1', 'S2', 'T0']) {
        expect(
          caseRunsIn(byId(id), production: true, allowWrites: false),
          isFalse,
          reason: id,
        );
      }
    });

    test('a step that changes what the account has saved is not open-only', () {
      for (final ScenarioStep step in <ScenarioStep>[
        const ChangeSymbol('NSE:SBIN'),
        const Reload(),
        const NavigateAway(),
        const Operate('setResolution'),
        const Operate('setTheme'),
        const Operate(''),
      ]) {
        expect(isOpenOnlyStep(step), isFalse, reason: step.describe);
      }
    });

    test(
      'a step that only observes, or stubs a failure the page undoes, is open-only',
      () {
        for (final ScenarioStep step in <ScenarioStep>[
          const Wait(Duration(seconds: 1)),
          const Probe('x'),
          const TraceApi('x'),
          const CaptureLibUrls(),
          const Operate('networkFailure'),
          const Operate('barCensus'),
          const Operate('appendLiveTick'),
          const FillGap('x'),
        ]) {
          expect(isOpenOnlyStep(step), isTrue, reason: step.describe);
        }
      },
    );

    test('a case that is blocked says why and how to run it', () {
      final String why = blockedReason(byId('S1'));
      expect(why, contains('production'));
      expect(why, contains('S1'));
      expect(why, contains('CHART_ENV=uat'));
      expect(why, contains('ALLOW_PROD_WRITES'));
    });
  });

  group('the banner', () {
    Future<void> show(WidgetTester t, EnvironmentBanner b) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: b)));

    testWidgets('names production, the client and what is hidden', (
      WidgetTester t,
    ) async {
      await show(
        t,
        const EnvironmentBanner(
          production: true,
          clientCode: 'T029342',
          hiddenCases: 35,
        ),
      );
      expect(find.textContaining('PRODUCTION'), findsOneWidget);
      expect(find.textContaining('T029342'), findsOneWidget);
      expect(find.textContaining('35'), findsOneWidget);
    });

    testWidgets('says UAT plainly and mentions no hidden cases', (
      WidgetTester t,
    ) async {
      await show(
        t,
        const EnvironmentBanner(
          production: false,
          clientCode: 'T06794',
          hiddenCases: 0,
        ),
      );
      expect(find.textContaining('UAT'), findsOneWidget);
      expect(find.textContaining('hidden'), findsNothing);
    });
  });
}
