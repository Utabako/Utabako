import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utabako/core/service/vpn_service.dart';
import 'package:utabako/ui/outbounds/outbounds_page.dart';
import 'package:utabako/ui/theme/app_theme.dart';
import 'package:utabako/ui/widgets/latency_label.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.utabako/vpn');
  late List<MethodCall> calls;
  late String outboundsResponse;
  Completer<String>? probe;
  late Map<String, Completer<String>> probes;
  Completer<String>? pendingQuery;
  String? selectionError;
  String? queryError;
  late Completer<void> initialized;

  setUp(() {
    calls = [];
    outboundsResponse = '[]';
    probe = null;
    probes = {};
    pendingQuery = null;
    selectionError = null;
    queryError = null;
    initialized = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getThemeMode') initialized.complete();
          if (call.method == 'urlTest') {
            final tag =
                (call.arguments as Map<Object?, Object?>)['outboundTag']
                    as String;
            final pending = probes[tag] ?? probe;
            return pending == null ? '[]' : await pending.future;
          }
          if (call.method == 'selectOutbound' && selectionError != null) {
            throw PlatformException(
              code: 'SELECT_FAILED',
              message: selectionError,
            );
          }
          if (call.method == 'queryOutbounds' && queryError != null) {
            throw PlatformException(code: 'QUERY_FAILED', message: queryError);
          }
          if (call.method == 'queryOutbounds' && pendingQuery != null) {
            return pendingQuery!.future;
          }
          return switch (call.method) {
            'version' => 'test',
            'listProfiles' => '{"activeId":"","profiles":[]}',
            'getAutostart' => false,
            'getPerAppProxy' => '{"mode":"all","packages":[]}',
            'getState' => 'stopped',
            'getThemeMode' => 'system',
            'queryOutbounds' => outboundsResponse,
            'queryTrafficStats' => '[]',
            'getStartedAt' => null,
            'zerotierStatus' => '[]',
            'readLog' => '',
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> sendNativeState(String state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onStateChanged', state),
          ),
          null,
        );
  }

  Widget page(VpnService vpn, {bool active = true, ProxyFocus? focus}) =>
      ChangeNotifierProvider<VpnService>(
        create: (_) => vpn,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: OutboundsPage(active: active, focus: focus),
        ),
      );

  Future<VpnService> pumpProxy(
    WidgetTester tester, {
    bool started = true,
    bool active = true,
    ProxyFocus? focus,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final vpn = (await tester.runAsync(() async {
      final service = VpnService();
      await initialized.future;
      return service;
    }))!;
    await tester.pumpWidget(page(vpn, active: active, focus: focus));
    await tester.pumpAndSettle();
    if (started) {
      await sendNativeState('started');
      await tester.pumpAndSettle();
    }
    return vpn;
  }

  testWidgets('identical outbound snapshots retain models without notifying', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Manual', [item('Node A', result: result(0)), item('Node B')]),
    ]);
    final vpn = await pumpProxy(tester, started: false);
    await vpn.loadOutbounds();
    final groups = vpn.outboundGroups;
    final firstGroup = groups.single;
    final firstItem = firstGroup.items.first;
    var notifications = 0;
    vpn.addListener(() => notifications++);

    await vpn.loadOutbounds();

    expect(vpn.outboundGroups, same(groups));
    expect(vpn.outboundGroups.single, same(firstGroup));
    expect(vpn.outboundGroups.single.items.first, same(firstItem));
    expect(notifications, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changed snapshots preserve probe fields, selection and order', (
    tester,
  ) async {
    final manual = group('Manual', [item('Node A'), item('Node B')]);
    final backup = group('Backup', [item('Backup node')]);
    outboundsResponse = jsonEncode([manual, backup]);
    final vpn = await pumpProxy(tester, started: false);
    await vpn.loadOutbounds();
    var previous = vpn.outboundGroups;
    var notifications = 0;
    vpn.addListener(() => notifications++);
    var expectedNotifications = 0;

    // Each response changes just one result field, including a completed
    // failure with no error text and successful boundary delays.
    for (final probeResult in [
      {'time': 10, 'delay': 0, 'success': true, 'error': ''},
      {'time': 11, 'delay': 0, 'success': true, 'error': ''},
      {'time': 11, 'delay': 65535, 'success': true, 'error': ''},
      {'time': 11, 'delay': 65535, 'success': false, 'error': ''},
      {'time': 11, 'delay': 65535, 'success': false, 'error': 'timeout'},
    ]) {
      manual['items'] = [item('Node A', result: probeResult), item('Node B')];
      outboundsResponse = jsonEncode([manual, backup]);
      await vpn.loadOutbounds();
      expect(vpn.outboundGroups, isNot(same(previous)));
      final actual = vpn.outboundGroups.first.items.first.urlTestResult!;
      expect(actual.timestampSeconds, probeResult['time']);
      expect(actual.delayMillis, probeResult['delay']);
      expect(actual.success, probeResult['success']);
      expect(actual.error, probeResult['error']);
      expect(vpn.outboundGroups.first.items.last.urlTestResult, isNull);
      expect(notifications, ++expectedNotifications);
      previous = vpn.outboundGroups;
    }

    manual['now'] = 'Node B';
    outboundsResponse = jsonEncode([manual, backup]);
    await vpn.loadOutbounds();
    expect(vpn.outboundGroups.first.now, 'Node B');
    expect(notifications, ++expectedNotifications);

    manual['items'] = [item('Node B'), item('Node A')];
    outboundsResponse = jsonEncode([manual, backup]);
    await vpn.loadOutbounds();
    expect(vpn.outboundGroups.first.items.map((item) => item.tag), [
      'Node B',
      'Node A',
    ]);
    expect(vpn.outboundGroups.first.items.last.urlTestResult, isNull);
    expect(notifications, ++expectedNotifications);

    backup['type'] = 'urltest';
    backup['selectable'] = false;
    outboundsResponse = jsonEncode([backup, manual]);
    await vpn.loadOutbounds();
    expect(vpn.outboundGroups.map((group) => group.tag), ['Backup', 'Manual']);
    expect(vpn.outboundGroups.first.type, 'urltest');
    expect(vpn.outboundGroups.first.selectable, isFalse);
    expect(notifications, ++expectedNotifications);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selection copies the snapshot and old native response resyncs', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Manual', [item('Node A'), item('Node B')]),
      group('Backup', [item('Backup node')]),
    ]);
    final vpn = await pumpProxy(tester, started: false);
    await vpn.loadOutbounds();
    final original = vpn.outboundGroups;
    final originalGroup = original.first;
    var notifications = 0;
    vpn.addListener(() => notifications++);

    expect(await vpn.selectOutbound('Manual', 'Node B'), isNull);
    final selected = vpn.outboundGroups;
    expect(selected, isNot(same(original)));
    expect(original.first, same(originalGroup));
    expect(original.first.now, 'Node A');
    expect(selected.first.now, 'Node B');
    expect(selected.first.items, same(originalGroup.items));
    expect(selected.last, same(original.last));
    expect(notifications, 1);

    await vpn.loadOutbounds();
    expect(vpn.outboundGroups.first.now, 'Node A');
    expect(selected.first.now, 'Node B');
    expect(notifications, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('collapses large groups and preserves search across refreshes', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Manual', List.generate(900, (i) => item('Node $i'))),
      group('Backup', [item('Backup node')]),
    ]);
    final vpn = await pumpProxy(tester);
    expect(find.text('Backup'), findsOneWidget);
    expect(find.byTooltip('测试节点延迟'), findsNothing);
    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('测试节点延迟'), findsWidgets);
    expect(find.byTooltip('测试节点延迟').evaluate().length, lessThan(900));
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'No matching node');
    await tester.pump();
    expect(find.byTooltip('测试节点延迟'), findsNothing);
    expect(find.text('没有符合条件的节点'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('测试节点延迟'), findsWidgets);
    await tester.tap(find.byTooltip('搜索节点'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextField), 'nOdE 899');
    await tester.pump();
    expect(find.byTooltip('测试节点延迟'), findsOneWidget);
    expect(find.text('Node 899'), findsOneWidget);
    await vpn.loadOutbounds();
    await tester.pump();
    expect(find.text('Node 899'), findsOneWidget);
    expect(find.byTooltip('测试节点延迟'), findsOneWidget);
    await tester.tap(find.text('Node 899'));
    await tester.pumpAndSettle();
    expect(
      calls.singleWhere((call) => call.method == 'selectOutbound').arguments,
      {'groupTag': 'Manual', 'outboundTag': 'Node 899'},
    );
    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('测试节点延迟'), findsNothing);
    expect(find.text('Backup'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'collapse keeps content until closed and can reverse without losing search',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', List.generate(900, (i) => item('Node $i'))),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索节点'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Node 899');
      await tester.pump();
      expect(find.byKey(const ValueKey('Manual/Node 899')), findsOneWidget);

      await tester.tap(find.text('Manual'));
      await tester.pump();
      expect(find.byKey(const ValueKey('Manual/Node 899')), findsOneWidget);
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('Manual/Node 899')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Node 899',
      );

      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(find.byType(GridView, skipOffstage: false), findsNothing);
      expect(find.byType(TextField, skipOffstage: false), findsNothing);
      expect(vpn.outboundGroups.single.items, hasLength(900));
      expect(vpn.outboundGroups.single.now, 'Node 0');
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing search from header clears query and resets grid scroll',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', List.generate(900, (i) => item('Node $i'))),
      ]);
      await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索节点'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Node 1');
      await tester.pump();
      expect(find.text('111 个节点'), findsOneWidget);
      await tester.drag(find.byType(GridView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('Manual/Node 1')).hitTestable(),
        findsNothing,
      );

      await tester.tap(find.byTooltip('搜索节点'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('900 个节点'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('Manual/Node 0')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('搜索节点'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'group tests call each node once and publish each completion immediately',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [item('Node A'), item('Node B', result: result(0))]),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pump();
      probes = {'Node A': Completer<String>(), 'Node B': Completer<String>()};
      await tester.tap(find.byTooltip('整组测速'));
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'urlTest')
            .map((call) => call.arguments),
        [
          {'outboundTag': 'Node A'},
          {'outboundTag': 'Node B'},
        ],
      );
      expect(find.text('0 ms'), findsNothing);
      expect(find.text('未测'), findsNothing);
      expect(
        tester
            .widgetList<LatencyLabel>(find.byType(LatencyLabel))
            .every((label) => label.testing),
        isTrue,
      );
      probes['Node A']!.complete(
        jsonEncode([item('Node A', result: result(42))]),
      );
      await tester.pump();
      expect(find.text('42 ms'), findsOneWidget);
      expect(find.text('0 ms'), findsNothing);
      expect(vpn.testingOutbounds, containsAll(['Manual', 'Node B']));
      expect(vpn.testingOutbounds, isNot(contains('Node A')));
      await tester.tap(find.byTooltip('整组测速'));
      await tester.pump();
      expect(calls.where((call) => call.method == 'urlTest'), hasLength(2));
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('42 ms'), findsOneWidget);
      expect(find.text('0 ms'), findsNothing);
      probes['Node B']!.complete(
        jsonEncode([item('Node B', result: result(0))]),
      );
      await tester.pumpAndSettle();
      expect(find.text('42 ms'), findsOneWidget);
      expect(find.text('0 ms'), findsOneWidget);
      expect(vpn.testingOutbounds, isEmpty);
      probes['Node B'] = Completer<String>();
      await tester.tap(find.byTooltip('测试节点延迟').last);
      await tester.pump();
      await tester.tap(find.byTooltip('测试节点延迟').last);
      await tester.pump();
      expect(calls.where((call) => call.method == 'urlTest'), hasLength(3));
      expect(find.text('0 ms'), findsNothing);
      expect(find.text('42 ms'), findsOneWidget);
      probes['Node B']!.complete(
        jsonEncode([item('Node B', result: result(0, success: false))]),
      );
      await tester.pumpAndSettle();
      expect(find.text('失败'), findsOneWidget);
      expect(vpn.outboundGroups.single.now, 'Node A');
      expect(
        calls.where(
          (call) => ['selectOutbound', 'start', 'stop'].contains(call.method),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'overlapping nested groups share pending node calls, not results',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Root', [item('Manual'), item('Backup')]),
        group('Manual', [item('Node A'), item('Node B')]),
        group('Backup', [item('Node A'), item('Node C')]),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Root'));
      await tester.pumpAndSettle();
      probes = {
        for (final tag in ['Node A', 'Node B', 'Node C'])
          tag: Completer<String>(),
      };
      final rootTest = vpn.testOutbound('Root');
      final manualTest = vpn.testOutbound('Manual');
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'urlTest')
            .map((call) => call.arguments),
        [
          {'outboundTag': 'Node A'},
          {'outboundTag': 'Node B'},
          {'outboundTag': 'Node C'},
        ],
      );
      probes['Node A']!.complete(
        jsonEncode([item('Node A', result: result(42))]),
      );
      await tester.pump();
      final manualItem = find.byKey(const ValueKey('Root/Manual'));
      final label = tester.widget<LatencyLabel>(
        find.descendant(of: manualItem, matching: find.byType(LatencyLabel)),
      );
      expect(label.testing, isFalse);
      expect(label.result!.delayMillis, 42);
      expect(
        vpn.testingOutbounds,
        containsAll(['Root', 'Manual', 'Node B', 'Node C']),
      );
      probes['Node B']!.complete(
        jsonEncode([item('Node B', result: result(0, success: false))]),
      );
      await manualTest;
      await tester.pump();
      expect(vpn.testingOutbounds, containsAll(['Root', 'Node C']));
      expect(vpn.testingOutbounds, isNot(contains('Manual')));
      probes['Node C']!.complete(
        jsonEncode([item('Node C', result: result(0))]),
      );
      expect(await rootTest, isNull);
      await tester.pumpAndSettle();
      expect(vpn.testingOutbounds, isEmpty);
      expect(vpn.outboundGroups[1].now, 'Node A');
      expect(vpn.outboundGroups[2].now, 'Node A');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shared nodes keep their pending test across groups and page visibility',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [item('Shared', result: result(123))]),
        group('Backup', [item('Shared', result: result(123))]),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup'));
      await tester.pumpAndSettle();
      probe = Completer<String>();
      await tester.tap(find.byTooltip('测试节点延迟').first);
      await tester.pump();
      expect(find.text('123 ms'), findsNothing);
      expect(
        tester
            .widgetList<LatencyLabel>(find.byType(LatencyLabel))
            .every((label) => label.testing),
        isTrue,
      );
      await tester.pumpWidget(page(vpn, active: false));
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(page(vpn));
      await tester.pump();
      expect(find.text('123 ms'), findsNothing);
      expect(
        tester
            .widgetList<LatencyLabel>(find.byType(LatencyLabel))
            .every((label) => label.testing),
        isTrue,
      );
      probe!.complete(jsonEncode([item('Shared', result: result(123))]));
      await tester.pumpAndSettle();
      expect(find.text('123 ms'), findsNWidgets(2));
      expect(calls.where((call) => call.method == 'urlTest'), hasLength(1));
      expect(
        tester
            .widgetList<LatencyLabel>(find.byType(LatencyLabel))
            .every((label) => !label.testing),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an older snapshot cannot overwrite a completed latency result', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Manual', [item('Node A', result: result(10))]),
    ]);
    final vpn = await pumpProxy(tester);
    pendingQuery = Completer<String>();
    final query = vpn.loadOutbounds();
    await tester.pump();
    probe = Completer<String>();
    final testing = vpn.testOutbound('Node A');
    await tester.pump();
    probe!.complete(jsonEncode([item('Node A', result: result(42))]));
    await testing;
    expect(
      vpn.outboundGroups.single.items.single.urlTestResult!.delayMillis,
      42,
    );
    pendingQuery!.complete(
      jsonEncode([
        group('Manual', [item('Node A', result: result(12))]),
      ]),
    );
    await query;
    expect(
      vpn.outboundGroups.single.items.single.urlTestResult!.delayMillis,
      42,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'previous session calls cannot clear or overwrite a new node test',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [item('Node A'), item('Node B')]),
      ]);
      final vpn = await pumpProxy(tester);
      final oldA = Completer<String>();
      final oldB = Completer<String>();
      probes = {'Node A': oldA, 'Node B': oldB};
      final groupTest = vpn.testOutbound('Manual');
      await tester.pump();
      await sendNativeState('stopped');
      await sendNativeState('started');
      await tester.pump();
      final newA = Completer<String>();
      probes['Node A'] = newA;
      final newTest = vpn.testOutbound('Node A');
      await tester.pump();
      oldA.completeError(
        PlatformException(code: 'ERROR', message: 'context canceled'),
      );
      oldB.complete(jsonEncode([item('Node B', result: result(99))]));
      expect(await groupTest, isNull);
      expect(vpn.testingOutbounds, {'Node A'});
      expect(vpn.outboundGroups.single.items.last.urlTestResult, isNull);
      newA.complete(jsonEncode([item('Node A', result: result(42))]));
      expect(await newTest, isNull);
      expect(vpn.testingOutbounds, isEmpty);
      expect(
        vpn.outboundGroups.single.items.first.urlTestResult!.delayMillis,
        42,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'disconnecting does not report the cancelled probe as a failure',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [item('Node A')]),
      ]);
      final vpn = await pumpProxy(tester);
      probe = Completer<String>();
      final testing = vpn.testOutbound('Node A');
      await tester.pump();
      await vpn.stop();
      expect(vpn.state, VpnState.stopping);
      probe!.completeError(
        PlatformException(code: 'ERROR', message: 'context canceled'),
      );
      expect(await testing, isNull);
      expect(vpn.testingOutbounds, isEmpty);
      expect(vpn.outboundGroups.single.items.single.urlTestResult, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('nested group latency button tests only the displayed leaf', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Root', [item('Manual')]),
      group('Manual', [item('Node A'), item('Node B')]),
    ]);
    final vpn = await pumpProxy(tester);
    await tester.tap(find.text('Root'));
    await tester.pumpAndSettle();
    probe = Completer<String>();
    await tester.tap(find.byTooltip('测试节点延迟'));
    await tester.pump();
    expect(calls.singleWhere((call) => call.method == 'urlTest').arguments, {
      'outboundTag': 'Node A',
    });
    expect(find.text('未测'), findsNothing);
    probe!.complete(jsonEncode([item('Node A', result: result(42))]));
    await tester.pumpAndSettle();
    expect(find.text('42 ms'), findsOneWidget);
    expect(vpn.outboundGroups.last.now, 'Node A');
    expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'global filter hides only explicit failures across groups and retains zero success',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [
          item('Untested'),
          item('Zero latency', result: result(0)),
          item(
            'Failed',
            result: result(0, success: false, error: 'connection refused'),
          ),
          item('Failed without message', result: result(0, success: false)),
        ]),
        group('Backup', [
          item('Backup untested'),
          item('Backup failed', result: result(0, success: false)),
        ]),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pump();
      expect(find.byTooltip('测试节点延迟'), findsNWidgets(4));
      expect(find.text('0 ms'), findsOneWidget);
      expect(find.text('未测'), findsOneWidget);
      expect(find.text('失败'), findsNWidgets(2));
      await tester.tap(find.text('隐藏不可用'));
      await tester.pump();
      expect(find.byTooltip('测试节点延迟'), findsNWidgets(2));
      expect(find.text('Untested'), findsOneWidget);
      expect(find.text('Zero latency'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      expect(find.text('Failed without message'), findsNothing);
      expect(find.text('2 个节点 · 已隐藏 2 个不可用'), findsOneWidget);
      await tester.tap(find.text('Manual'));
      await tester.pump();
      await tester.tap(find.text('Backup'));
      await tester.pump();
      expect(find.byTooltip('测试节点延迟'), findsOneWidget);
      expect(find.text('Backup failed'), findsNothing);
      expect(find.text('1 个节点 · 已隐藏 1 个不可用'), findsOneWidget);
      expect(vpn.outboundGroups.map((group) => group.items.length), [4, 2]);
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      await tester.tap(find.text('隐藏不可用'));
      await tester.pump();
      expect(find.byTooltip('测试节点延迟'), findsNWidgets(2));
      expect(find.text('Backup failed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sort orders displayed results without selecting or modifying subscription order',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [
          item('Failed', result: result(0, success: false)),
          item('Untested'),
          item('Slow', result: result(65535)),
          item('Fast', result: result(0)),
        ]),
      ]);
      final vpn = await pumpProxy(tester);
      await tester.tap(find.text('Manual'));
      await tester.pump();
      List<String> order() => tester
          .widgetList<Material>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Material &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith('Manual/'),
            ),
          )
          .map((widget) => (widget.key! as ValueKey<String>).value)
          .toList();
      expect(order(), [
        'Manual/Failed',
        'Manual/Untested',
        'Manual/Slow',
        'Manual/Fast',
      ]);
      await tester.tap(find.byTooltip('按延迟排序'));
      await tester.pump();
      expect(order(), [
        'Manual/Fast',
        'Manual/Slow',
        'Manual/Untested',
        'Manual/Failed',
      ]);
      expect(find.text('65535 ms'), findsOneWidget);
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      expect(vpn.outboundGroups.single.items.map((item) => item.tag), [
        'Failed',
        'Untested',
        'Slow',
        'Fast',
      ]);
      await tester.tap(find.byTooltip('按延迟排序'));
      await tester.pump();
      expect(order(), [
        'Manual/Failed',
        'Manual/Untested',
        'Manual/Slow',
        'Manual/Fast',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'focus expands and reveals requested group on first load and new serial',
    (tester) async {
      outboundsResponse = jsonEncode(
        List.generate(14, (i) => group('Group $i', [item('Node $i')])),
      );
      final vpn = await pumpProxy(
        tester,
        focus: const ProxyFocus(groupTag: 'Group 12', serial: 1),
      );
      expect(
        find.byKey(const ValueKey('Group 12/Node 12')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Group 12'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('Group 12/Node 12')), findsNothing);
      await vpn.loadOutbounds();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('Group 12/Node 12')), findsNothing);
      await tester.pumpWidget(
        page(vpn, focus: const ProxyFocus(groupTag: 'Group 12', serial: 2)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('Group 12/Node 12')).hitTestable(),
        findsOneWidget,
      );
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('nested group tiles show the selected leaf and its latency', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Exit', [item('Manual')]),
      group('Manual', [item('Backup')]),
      group('Backup', [item('Leaf', result: result(42))]),
    ]);
    await pumpProxy(tester);
    await tester.tap(find.text('Exit'));
    await tester.pump();
    expect(find.text('→ Leaf'), findsOneWidget);
    expect(find.text('42 ms'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('automatic groups resolve leaves but are not listed as cards', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Exit', [item('Auto')]),
      {
        ...group('Auto', [item('Leaf', result: result(42))]),
        'type': 'urltest',
        'selectable': false,
      },
    ]);
    await pumpProxy(tester);
    // Only the collapsed Exit card's current-selection label; no card of its own.
    expect(find.text('Auto'), findsOneWidget);
    await tester.tap(find.text('Exit'));
    await tester.pump();
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('→ Leaf'), findsOneWidget);
    expect(find.text('42 ms'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selection errors stay visible and preserve the current selection',
    (tester) async {
      outboundsResponse = jsonEncode([
        group('Manual', [item('Node A'), item('Node B')]),
      ]);
      final vpn = await pumpProxy(tester);
      selectionError = '无法切换节点';
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node B'));
      await tester.pumpAndSettle();
      expect(find.text('无法切换节点'), findsOneWidget);
      expect(vpn.outboundGroups.single.now, 'Node A');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('query failure remains visible with last groups until recovery', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      group('Manual', [item('Node A')]),
    ]);
    final vpn = await pumpProxy(tester);
    final groups = vpn.outboundGroups;
    var notifications = 0;
    vpn.addListener(() => notifications++);
    queryError = '无法读取策略组';
    await vpn.loadOutbounds();
    await tester.pump();
    expect(find.text('无法读取策略组'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(vpn.outboundGroups, same(groups));
    expect(vpn.outboundError, '无法读取策略组');
    expect(notifications, 1);
    queryError = null;
    await vpn.loadOutbounds();
    await tester.pump();
    expect(find.text('无法读取策略组'), findsNothing);
    expect(find.text('Manual'), findsOneWidget);
    expect(vpn.outboundGroups, same(groups));
    expect(vpn.outboundError, isNull);
    expect(notifications, 2);
    await vpn.loadOutbounds();
    expect(notifications, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'connects from the disconnected state and disables a pending start',
    (tester) async {
      await pumpProxy(tester, started: false);
      expect(find.text('连接后可选择节点'), findsOneWidget);
      expect(find.text('策略组和节点来自运行中的 sing-box 核心。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pump();
      expect(calls.where((call) => call.method == 'start'), hasLength(1));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(find.text('正在连接…'), findsOneWidget);
      await sendNativeState('started');
      await tester.pumpAndSettle();
      expect(find.text('当前配置没有可选择的策略组'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('polls only while active and started', (tester) async {
    final vpn = await pumpProxy(tester, active: false);
    calls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(calls.where((call) => call.method == 'queryOutbounds'), isEmpty);
    await tester.pumpWidget(page(vpn));
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'queryOutbounds'),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(
      calls.where((call) => call.method == 'queryOutbounds'),
      hasLength(2),
    );
    await sendNativeState('stopped');
    await tester.pump();
    calls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(calls.where((call) => call.method == 'queryOutbounds'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Map<String, Object?> item(String tag, {Map<String, Object?>? result}) => {
  'tag': tag,
  'urlTestResult': result,
};
Map<String, Object?> result(
  int delay, {
  bool success = true,
  String error = '',
}) => {'time': 10, 'delay': delay, 'success': success, 'error': error};
Map<String, Object?> group(String tag, List<Map<String, Object?>> items) => {
  'tag': tag,
  'type': 'selector',
  'selectable': true,
  'now': items.first['tag'],
  'items': items,
};
