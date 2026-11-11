// Guard for kuhy's textgate rule: nothing painted on any screen holds a word.
//
// Every RichText (Text builds one, Icon builds one with a private-use glyph)
// is read back from the tree. Content is stripped first: package names (the
// policy's own data) and the unit symbols that sit next to a number. Anything
// with two or more letters left over is chrome and fails the test.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/debug_log_page.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/main.dart';
import 'package:focus_owner/policy.dart';

part 'text_free_fixtures.dart';

final RegExp _packageName = RegExp(r'\b[a-z][a-z0-9_]*(\.[a-z0-9_]+)+\b');
final RegExp _unit = RegExp(r'\b(km|min)\b');
final RegExp _word = RegExp('[A-Za-z]{2,}');

/// Every painted string on screen that still carries a word.
List<String> _wordsOnScreen(WidgetTester tester) =>
    [
          for (final element in find.byType(RichText).evaluate())
            (element.widget as RichText).text.toPlainText(),
        ]
        .where(
          (s) => _word.hasMatch(
            s.replaceAll(_packageName, '').replaceAll(_unit, ''),
          ),
        )
        .toList();

void _expectNoWords(WidgetTester tester, String screen) {
  expect(_wordsOnScreen(tester), isEmpty, reason: screen);
}

Future<void> _pumpPage(
  WidgetTester tester,
  Map<String, Object?> stubs, {
  Future<FocusPolicy> Function() loadPolicy = _policy,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: StatusPage(
        policy: DevicePolicy(_channel(stubs)),
        loadFocusPolicy: loadPolicy,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAndCheck(
  WidgetTester tester,
  Finder target,
  String screen,
) async {
  await tester.tap(target);
  await tester.pumpAndSettle();
  _expectNoWords(tester, screen);
}

/// Pops the open sheet; a scroll-controlled sheet leaves no barrier to tap.
Future<void> _closeSheet(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(BottomSheet))).pop();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('not provisioned, no pass yet', (tester) async {
    await _pumpPage(tester, {
      'status': _status(owner: false),
      'hasHomeLocation': false,
      'readEnforcementLog': <String>[],
    });
    _expectNoWords(tester, 'main, empty');
  });

  testWidgets('not provisioned, failed pass (live shot state)', (tester) async {
    await _pumpPage(tester, {
      'status': _status(owner: false),
      'hasHomeLocation': false,
      'readEnforcementLog': [
        jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'reason': 'UNKNOWN',
          'failure': 'not device owner or profile owner',
          'counts': {'to_hide': 0, 'to_show': 0},
        }),
      ],
    });
    _expectNoWords(tester, 'main, failure');
  });

  for (final reason in [
    'AWAY',
    'AT_HOME',
    'CURFEW',
    'WORKOUT',
    'WORKDAY_LOCKDOWN',
    'LOCATION_UNKNOWN',
    'NEW_STATE',
  ]) {
    testWidgets('owner, $reason pass, every sheet and dialog', (tester) async {
      await _pumpPage(tester, {
        'status': _status(owner: true),
        'hasHomeLocation': true,
        'readEnforcementLog': [
          jsonEncode({
            'ts': DateTime.now().millisecondsSinceEpoch,
            'reason': 'LOCKDOWN_EXTENDED',
            'lockdown': {'through': '2026-11-12'},
          }),
          _record(reason: reason, accuracy: 900, ageMinutes: 45),
        ],
        'runEnforcementNow': false,
        'setVpnConfigBlocked': false,
        'releaseDeviceOwner': false,
        'setHomeToCurrentLocation': 'no location fix available',
      });
      _expectNoWords(tester, 'main, $reason');

      await _openAndCheck(
        tester,
        find.byKey(const Key('hidden-list')),
        'hidden sheet',
      );
      await _closeSheet(tester);

      await _openAndCheck(
        tester,
        find.byKey(const Key('details-toggle')),
        'details sheet',
      );
      await _closeSheet(tester);

      await _openAndCheck(
        tester,
        find.byKey(const Key('lock-vpn')),
        'vpn dialog',
      );
      await _openAndCheck(
        tester,
        find.byKey(const Key('vpn-confirm')),
        'vpn snack',
      );

      await _openAndCheck(
        tester,
        find.byKey(const Key('release-owner')),
        'release dialog',
      );
      await _openAndCheck(
        tester,
        find.byKey(const Key('release-confirm')),
        'release snack',
      );

      await _openAndCheck(
        tester,
        find.byKey(const Key('set-home')),
        'set-home snack',
      );
      await _openAndCheck(
        tester,
        find.byKey(const Key('run-enforcement')),
        'run snack',
      );
    });
  }

  testWidgets('home missing pass', (tester) async {
    await _pumpPage(tester, {
      'status': _status(owner: true),
      'hasHomeLocation': false,
      'readEnforcementLog': [
        _record(homeConfigured: false, accuracy: null, withHidden: false),
      ],
    });
    _expectNoWords(tester, 'main, home missing');
  });

  testWidgets('status read fails', (tester) async {
    await _pumpPage(tester, {});
    _expectNoWords(tester, 'main, error');
  });

  testWidgets('policy asset broken', (tester) async {
    await _pumpPage(tester, {
      'status': _status(owner: true),
      'hasHomeLocation': true,
      'readEnforcementLog': <String>[],
    }, loadPolicy: _brokenPolicy);
    _expectNoWords(tester, 'main, policy error');
    await _openAndCheck(
      tester,
      find.byKey(const Key('details-toggle')),
      'details sheet, policy error',
    );
  });

  testWidgets('debug log, empty and expanded', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DebugLogPage(records: [])));
    _expectNoWords(tester, 'log, empty');

    final records = EnforcementRecord.parseLines([
      _record(failure: 'not device owner or profile owner'),
      _record(reason: 'LOCATION_UNKNOWN', homeConfigured: null),
    ]);
    await tester.pumpWidget(MaterialApp(home: DebugLogPage(records: records)));
    for (final tile in find.byType(ExpansionTile).evaluate().toList()) {
      await tester.tap(find.byWidget(tile.widget));
      await tester.pumpAndSettle();
    }
    _expectNoWords(tester, 'log, expanded');
  });
}
