import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utabako/core/service/vpn_service.dart';
import 'package:utabako/ui/app.dart';
import 'package:utabako/ui/home/home_dashboard.dart';
import 'package:utabako/ui/more/more_page.dart';
import 'package:utabako/ui/home/history_chart.dart';
import 'package:utabako/ui/outbounds/outbounds_page.dart';
import 'package:provider/provider.dart';
import 'package:utabako/ui/profiles/profiles_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.github.utabako/vpn');
  late List<MethodCall> calls;
  late String outboundsResponse;
  late String profilesResponse;
  late int? startedAt;
  late String zeroTierResponse;
  late bool outboundFailure;
  late bool zeroTierFailure;
  late String trafficResponse;
  late String initialState;
  late bool trafficFailure;
  Completer<String>? pendingTraffic;
  Completer<String>? pendingProbe;

  setUp(() {
    // A cached asset future can retain an earlier test's fake-async zone.
    rootBundle.evict('assets/default_config.json');
    calls = [];
    outboundsResponse = '[]';
    profilesResponse = '{"activeId":"","profiles":[]}';
    startedAt = null;
    zeroTierResponse = '[]';
    outboundFailure = false;
    zeroTierFailure = false;
    initialState = 'stopped';
    trafficFailure = false;
    pendingTraffic = null;
    pendingProbe = null;
    trafficResponse =
        '[{"uplink":2048,"downlink":1048576,"uplinkTotal":4096,"downlinkTotal":2097152,"connectionsIn":12,"connectionsOut":4}]';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'urlTest') {
            return pendingProbe == null ? '[]' : await pendingProbe!.future;
          }
          if (call.method == 'queryOutbounds' && outboundFailure) {
            throw PlatformException(code: 'query', message: '出口状态读取失败');
          }
          if (call.method == 'zerotierStatus' && zeroTierFailure) {
            throw PlatformException(code: 'query', message: 'ZeroTier 状态读取失败');
          }
          if (call.method == 'queryTrafficStats') {
            if (trafficFailure) {
              throw PlatformException(code: 'query', message: '流量读取失败');
            }
            if (pendingTraffic != null) return pendingTraffic!.future;
          }
          return switch (call.method) {
            'version' => 'test',
            'listProfiles' => profilesResponse,
            'getAutostart' => false,
            'getPerAppProxy' => '{"mode":"all","packages":[]}',
            'getState' => initialState,
            'getThemeMode' => 'system',
            'queryOutbounds' => outboundsResponse,
            'queryTrafficStats' => trafficResponse,
            'getStartedAt' => startedAt,
            'zerotierStatus' => zeroTierResponse,
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

  Future<void> closeApp(WidgetTester tester, VpnService vpn) async {
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  }

  Future<VpnService> pumpStartedApp(WidgetTester tester) async {
    final vpn = await _pumpApp(tester);
    expect(vpn.state, VpnState.started, reason: calls.toString());
    return vpn;
  }

  Future<void> revealExit(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('exit-tile')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('renders the disconnected home screen', (tester) async {
    final vpn = await _pumpApp(tester);
    expect(find.text('Utabako'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('connection-status'))).data,
      '未连接',
    );
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);
    expect(find.text('活跃连接'), findsOneWidget);
    expect(find.text('60 秒峰值 0'), findsOneWidget);
    await revealExit(tester);
    expect(find.text('连接后加入'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '连接'))
          .onPressed,
      isNull,
    );
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('代理'), findsOneWidget);
    expect(find.text('配置'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    await closeApp(tester, vpn);
  });

  testWidgets('disconnects without mutating state during build', (
    tester,
  ) async {
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('connection-status'))).data,
      '已连接',
    );
    expect(find.text('断开'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('断开'));
    await tester.pump();
    expect(calls.any((call) => call.method == 'stop'), isTrue);
    await sendNativeState('stopped');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<Text>(find.byKey(const Key('connection-status'))).data,
      '未连接',
    );
    expect(find.text('60 秒峰值 0'), findsOneWidget);
    await closeApp(tester, vpn);
  });

  testWidgets('does not poll hidden tabs', (tester) async {
    final vpn = await _pumpApp(tester);
    calls.clear();
    await tester.pump(const Duration(seconds: 6));
    const pollingMethods = {
      'queryOutbounds',
      'queryTrafficStats',
      'zerotierStatus',
      'readLog',
    };
    expect(
      calls.where((call) => pollingMethods.contains(call.method)),
      isEmpty,
    );
    await closeApp(tester, vpn);
  });

  testWidgets('service notifications rebuild only dependent visible content', (
    tester,
  ) async {
    outboundsResponse = _nestedGroups();
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    final statusFinder = find.byKey(const Key('connection-status'));
    final statusBefore = tester.widget<Text>(statusFinder);
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(tester.widget<Text>(statusFinder), same(statusBefore));
    await tester.tap(find.text('代理'));
    await tester.pumpAndSettle();
    final chartFinder = find.byType(HistoryChart, skipOffstage: false);
    final hiddenCharts = tester.widgetList<HistoryChart>(chartFinder).toList();
    final proxyScaffold = find.descendant(
      of: find.byType(OutboundsPage),
      matching: find.byType(Scaffold),
    );
    final profileScaffold = find.descendant(
      of: find.byType(ProfilesPage, skipOffstage: false),
      matching: find.byType(Scaffold, skipOffstage: false),
      skipOffstage: false,
    );
    final proxyBefore = tester.widget<Scaffold>(proxyScaffold);
    final profileBefore = tester.widget<Scaffold>(profileScaffold);
    trafficResponse =
        '[{"uplink":512,"downlink":5500,"uplinkTotal":4608,"downlinkTotal":6524,"connectionsIn":7,"connectionsOut":80}]';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(vpn.trafficStats.downlinkBytesPerSecond, 5500);
    expect(tester.widget<Scaffold>(proxyScaffold), same(proxyBefore));
    expect(tester.widget<Scaffold>(profileScaffold), same(profileBefore));
    final chartsAfter = tester.widgetList<HistoryChart>(chartFinder).toList();
    for (var i = 0; i < hiddenCharts.length; i++) {
      expect(chartsAfter[i], same(hiddenCharts[i]));
    }
    profilesResponse =
        '{"activeId":"p","profiles":[{"id":"p","name":"更新配置","type":"local","updatedAt":0}]}';
    await vpn.loadProfiles();
    await tester.pump();
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.text('更新配置'), findsOneWidget);
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    final visibleCharts = tester.widgetList<HistoryChart>(
      find.byType(HistoryChart),
    );
    expect(
      visibleCharts.singleWhere((chart) => !chart.compact).primary.last,
      5500,
    );
    expect(visibleCharts.singleWhere((chart) => chart.compact).primary.last, 7);
    expect(find.textContaining('更新配置'), findsOneWidget);
    await closeApp(tester, vpn);
  });

  testWidgets('home samples update values without rebuilding static content', (
    tester,
  ) async {
    outboundsResponse = _nestedGroups();
    profilesResponse =
        '{"activeId":"p","profiles":[{"id":"p","name":"测试配置","type":"local"}]}';
    zeroTierResponse =
        '[{"tag":"家庭网络","node_id":"abc","network_id":"network","network_status":"OK","online":true,"addresses":["10.1.0.2"],"peers":[],"routes":[]}]';
    startedAt = DateTime.now().millisecondsSinceEpoch - 1000;
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    final homeScaffold = find.descendant(
      of: find.byType(HomeDashboard),
      matching: find.byType(Scaffold),
    );
    final moreScaffold = find.descendant(
      of: find.byType(MorePage, skipOffstage: false),
      matching: find.byType(Scaffold, skipOffstage: false),
      skipOffstage: false,
    );
    final homeBefore = tester.widget<Scaffold>(homeScaffold);
    final moreBefore = tester.widget<Scaffold>(moreScaffold);
    final statusBefore = tester.widget<Text>(
      find.byKey(const Key('connection-status')),
    );
    final legendBefore = tester.widget<Text>(find.text('下载'));
    final stopBefore = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '断开'),
    );
    final runtimeBefore = tester.widget<Text>(find.textContaining(' · 测试配置'));
    trafficResponse =
        '[{"uplink":512,"downlink":5500,"uplinkTotal":4608,"downlinkTotal":6524,"connectionsIn":7,"connectionsOut":80}]';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.widget<Scaffold>(homeScaffold), same(homeBefore));
    expect(tester.widget<Text>(find.text('下载')), same(legendBefore));
    expect(
      tester.widget<Text>(find.byKey(const Key('connection-status'))),
      same(statusBefore),
    );
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '断开')),
      same(stopBefore),
    );
    expect(
      tester.widget<Text>(find.textContaining(' · 测试配置')),
      isNot(same(runtimeBefore)),
    );
    final charts = tester
        .widgetList<HistoryChart>(find.byType(HistoryChart))
        .toList();
    expect(charts.singleWhere((chart) => !chart.compact).primary, [5500]);
    expect(charts.singleWhere((chart) => chart.compact).primary, [7]);
    expect(find.text('60 秒峰值 7'), findsOneWidget);

    await revealExit(tester);
    expect(find.text('10.1.0.2'), findsOneWidget);
    final chartsBeforeStatus = tester
        .widgetList<HistoryChart>(find.byType(HistoryChart))
        .toList();
    zeroTierResponse =
        '[{"tag":"家庭网络","node_id":"abc","network_id":"network","network_status":"OK","online":true,"addresses":["10.1.0.3"],"peers":[],"routes":[]}]';
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(tester.widget<Scaffold>(homeScaffold), same(homeBefore));
    expect(tester.widget<Scaffold>(moreScaffold), same(moreBefore));
    final chartsAfterStatus = tester
        .widgetList<HistoryChart>(find.byType(HistoryChart))
        .toList();
    expect(chartsAfterStatus, hasLength(chartsBeforeStatus.length));
    for (var i = 0; i < chartsBeforeStatus.length; i++) {
      expect(chartsAfterStatus[i], same(chartsBeforeStatus[i]));
    }
    expect(find.text('10.1.0.3'), findsOneWidget);
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.text('在线 · 10.1.0.3'), findsOneWidget);
    await closeApp(tester, vpn);
  });

  testWidgets('charts rebuild only when their plotted series changes', (
    tester,
  ) async {
    final history = [
      for (var i = 1; i <= 60; i++)
        {
          'uplink': 1024,
          'downlink': 2048,
          'uplinkTotal': i * 1024,
          'downlinkTotal': i * 2048,
          'connectionsIn': 5,
          'connectionsOut': 9,
        },
    ];
    trafficResponse = jsonEncode(history);
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    HistoryChart chart(bool compact) => tester
        .widgetList<HistoryChart>(find.byType(HistoryChart))
        .singleWhere((chart) => chart.compact == compact);
    final trafficBefore = chart(false);
    final connectionsBefore = chart(true);

    history.removeAt(0);
    history.add({
      'uplink': 1024,
      'downlink': 2048,
      'uplinkTotal': 61 * 1024,
      'downlinkTotal': 61 * 2048,
      'connectionsIn': 5,
      'connectionsOut': 20,
    });
    trafficResponse = jsonEncode(history);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(vpn.trafficStats.connectionsOut, 20);
    expect(chart(false), same(trafficBefore));
    expect(chart(true), same(connectionsBefore));

    history.removeAt(0);
    history.add({
      'uplink': 1024,
      'downlink': 2048,
      'uplinkTotal': 62 * 1024,
      'downlinkTotal': 62 * 2048,
      'connectionsIn': 9,
      'connectionsOut': 20,
    });
    trafficResponse = jsonEncode(history);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(chart(false), same(trafficBefore));
    expect(chart(true), isNot(same(connectionsBefore)));
    expect(chart(true).primary.last, 9);

    history.removeAt(0);
    history.add({
      'uplink': 4096,
      'downlink': 2048,
      'uplinkTotal': 66 * 1024,
      'downlinkTotal': 63 * 2048,
      'connectionsIn': 9,
      'connectionsOut': 20,
    });
    trafficResponse = jsonEncode(history);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(chart(false), isNot(same(trafficBefore)));
    expect(chart(false).primary.last, 2048);
    expect(chart(false).secondary.last, 4096);
    await closeApp(tester, vpn);
  });

  testWidgets('exit follows nested groups and opens the last proxy group', (
    tester,
  ) async {
    outboundsResponse = _nestedGroups();
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    await revealExit(tester);
    expect(find.text('叶节点'), findsOneWidget);
    expect(find.text('主备切换 · 手动切换'), findsOneWidget);
    expect(find.text('0 ms'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exit-tile')));
    await tester.pumpAndSettle();
    final page = tester.widget<OutboundsPage>(find.byType(OutboundsPage));
    expect(page.active, isTrue);
    expect(page.focus?.groupTag, '手动切换');
    expect(find.byKey(const Key('connection-status')), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    await closeApp(tester, vpn);
  });

  testWidgets('exit resolves through automatic groups to the real node', (
    tester,
  ) async {
    outboundsResponse = jsonEncode([
      {
        'tag': '节点选择',
        'type': 'selector',
        'selectable': true,
        'now': '自动选择',
        'items': [
          {'tag': '自动选择', 'urlTestResult': null},
        ],
      },
      {
        'tag': '自动选择',
        'type': 'urltest',
        'selectable': false,
        'now': '香港 01',
        'items': [
          {
            'tag': '香港 01',
            'urlTestResult': {
              'time': 10,
              'delay': 88,
              'success': true,
              'error': '',
            },
          },
        ],
      },
    ]);
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    await revealExit(tester);
    expect(find.text('香港 01'), findsOneWidget);
    expect(find.text('88 ms'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exit-tile')));
    await tester.pumpAndSettle();
    final page = tester.widget<OutboundsPage>(find.byType(OutboundsPage));
    expect(page.focus?.groupTag, '节点选择');
    await closeApp(tester, vpn);
  });

  testWidgets(
    'exit latency waits for completion and hides results without selecting',
    (tester) async {
      outboundsResponse = _nestedGroups();
      final vpn = await _pumpApp(tester);
      await sendNativeState('started');
      await tester.pumpAndSettle();
      await revealExit(tester);
      pendingProbe = Completer<String>();
      await tester.tap(find.byTooltip('测试出口延迟'));
      await tester.pump();
      expect(calls.singleWhere((call) => call.method == 'urlTest').arguments, {
        'outboundTag': '叶节点',
      });
      expect(find.text('0 ms'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      outboundsResponse = _nestedGroups(timestamp: 11, delay: 65535);
      await vpn.loadOutbounds();
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('65535 ms'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final completedResult = jsonEncode([
        {
          'tag': '叶节点',
          'urlTestResult': {
            'time': 11,
            'delay': 65535,
            'success': true,
            'error': '',
          },
        },
      ]);
      pendingProbe!.complete(completedResult);
      await tester.pumpAndSettle();
      expect(find.text('65535 ms'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(vpn.outboundGroups.last.now, '叶节点');
      pendingProbe = Completer<String>();
      await tester.tap(find.byTooltip('测试出口延迟'));
      await tester.pump();
      expect(find.text('65535 ms'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pendingProbe!.complete(completedResult);
      await tester.pumpAndSettle();
      expect(find.text('65535 ms'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      await closeApp(tester, vpn);
    },
  );

  testWidgets(
    'pending exit test survives tabs background and details without hidden animation',
    (tester) async {
      outboundsResponse = _nestedGroups();
      final vpn = await _pumpApp(tester);
      await sendNativeState('started');
      await tester.pumpAndSettle();
      await revealExit(tester);
      pendingProbe = Completer<String>();
      await tester.tap(find.byTooltip('测试出口延迟'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('配置'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.tap(find.text('首页'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('0 ms'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.ensureVisible(find.text('ZeroTier'));
      await tester.tap(find.text('ZeroTier'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(calls.where((call) => call.method == 'urlTest'), hasLength(1));
      pendingProbe!.complete(
        jsonEncode([
          {
            'tag': '叶节点',
            'urlTestResult': {
              'time': 10,
              'delay': 0,
              'success': true,
              'error': '',
            },
          },
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 ms'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(calls.where((call) => call.method == 'selectOutbound'), isEmpty);
      await closeApp(tester, vpn);
    },
  );

  testWidgets('home polling pauses in the background and resumes when visible', (
    tester,
  ) async {
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'queryOutbounds'), isTrue);
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    calls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(calls.where((call) => call.method == 'queryOutbounds'), isEmpty);
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'queryOutbounds'), isTrue);
    final historyBeforePause = vpn.trafficHistory;
    expect(historyBeforePause, isNotEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    calls.clear();
    trafficResponse =
        '[{"uplink":2048,"downlink":1048576,"uplinkTotal":4096,"downlinkTotal":2097152,"connectionsIn":12,"connectionsOut":4},'
        '{"uplink":3072,"downlink":2048,"uplinkTotal":7168,"downlinkTotal":2099200,"connectionsIn":3,"connectionsOut":99}]';
    await tester.pump(const Duration(seconds: 6));
    expect(
      calls.where(
        (call) => {
          'queryOutbounds',
          'queryTrafficStats',
          'zerotierStatus',
          'readLog',
        }.contains(call.method),
      ),
      isEmpty,
    );
    expect(vpn.trafficHistory, same(historyBeforePause));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'queryOutbounds'), isTrue);
    expect(_trafficValues(vpn.trafficHistory), [
      [2048, 1048576, 4096, 2097152, 12, 4],
      [3072, 2048, 7168, 2099200, 3, 99],
    ]);
    expect(vpn.trafficStats, same(vpn.trafficHistory.last));
    await closeApp(tester, vpn);
  });

  testWidgets('first foreground read loads the existing native history window', (
    tester,
  ) async {
    initialState = 'started';
    trafficResponse =
        '[{"uplink":1,"downlink":2,"uplinkTotal":4294967297,"downlinkTotal":4294967298,"connectionsIn":5,"connectionsOut":60},'
        '{"uplink":7,"downlink":8,"uplinkTotal":4294967304,"downlinkTotal":4294967306,"connectionsIn":9,"connectionsOut":100}]';
    final vpn = await pumpStartedApp(tester);
    expect(_trafficValues(vpn.trafficHistory), [
      [1, 2, 4294967297, 4294967298, 5, 60],
      [7, 8, 4294967304, 4294967306, 9, 100],
    ]);
    final snapshot = vpn.trafficHistory;
    expect(vpn.trafficHistory, same(snapshot));
    expect(() => snapshot.add(const TrafficStats()), throwsUnsupportedError);
    expect(vpn.trafficStats, same(snapshot.last));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(_trafficValues(vpn.trafficHistory), _trafficValues(snapshot));
    expect(vpn.trafficHistory, hasLength(2));

    trafficFailure = true;
    final beforeFailure = vpn.trafficHistory;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(vpn.trafficHistory, same(beforeFailure));
    expect(vpn.trafficStats, same(beforeFailure.last));
    await closeApp(tester, vpn);
  });

  for (final terminalState in ['stopped', 'error:core stopped']) {
    testWidgets('$terminalState clears history before a new VPN session', (
      tester,
    ) async {
      initialState = 'started';
      final vpn = await pumpStartedApp(tester);
      expect(vpn.trafficHistory, isNotEmpty);
      await sendNativeState(terminalState);
      await tester.pump();
      expect(vpn.trafficHistory, isEmpty);
      expect(_trafficValues([vpn.trafficStats]), [
        [0, 0, 0, 0, 0, 0],
      ]);
      calls.clear();
      await tester.pump(const Duration(seconds: 2));
      expect(
        calls.where((call) => call.method == 'queryTrafficStats'),
        isEmpty,
      );

      trafficResponse = '[]';
      await sendNativeState('starting');
      await sendNativeState('started');
      await tester.pump();
      expect(vpn.trafficHistory, isEmpty);
      expect(_trafficValues([vpn.trafficStats]), [
        [0, 0, 0, 0, 0, 0],
      ]);
      trafficResponse =
          '[{"uplink":11,"downlink":12,"uplinkTotal":11,"downlinkTotal":12,"connectionsIn":13,"connectionsOut":14}]';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_trafficValues(vpn.trafficHistory), [
        [11, 12, 11, 12, 13, 14],
      ]);
      await closeApp(tester, vpn);
    });
  }

  testWidgets(
    'in-flight traffic from an ended session cannot replace new history',
    (tester) async {
      initialState = 'started';
      final vpn = await pumpStartedApp(tester);
      final oldResponse = trafficResponse;
      final pending = pendingTraffic = Completer<String>();
      calls.clear();
      await tester.pump(const Duration(seconds: 1));
      expect(
        calls.where((call) => call.method == 'queryTrafficStats'),
        hasLength(1),
      );
      await sendNativeState('stopped');
      trafficResponse =
          '[{"uplink":21,"downlink":22,"uplinkTotal":21,"downlinkTotal":22,"connectionsIn":23,"connectionsOut":24}]';
      await sendNativeState('starting');
      await sendNativeState('started');
      await tester.pump();
      pendingTraffic = null;
      pending.complete(oldResponse);
      await tester.pump();
      expect(vpn.trafficHistory, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_trafficValues(vpn.trafficHistory), [
        [21, 22, 21, 22, 23, 24],
      ]);
      await closeApp(tester, vpn);
    },
  );

  testWidgets(
    'shows native runtime and visible query errors without dropping the exit',
    (tester) async {
      startedAt = DateTime.now()
          .subtract(const Duration(hours: 1, minutes: 2, seconds: 3))
          .millisecondsSinceEpoch;
      profilesResponse =
          '{"activeId":"p","profiles":[{"id":"p","name":"日常配置","type":"local","updatedAt":0}]}';
      outboundsResponse = _nestedGroups();
      final vpn = await _pumpApp(tester);
      await sendNativeState('started');
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'01:02:\d{2} · 日常配置')),
        findsOneWidget,
      );
      outboundFailure = true;
      await vpn.loadOutbounds();
      await tester.pump();
      await revealExit(tester);
      expect(find.text('出口状态读取失败'), findsOneWidget);
      expect(find.text('叶节点'), findsOneWidget);
      await sendNativeState('error:配置检查失败');
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('connection-status'))).data,
        '错误',
      );
      expect(find.text('配置检查失败'), findsOneWidget);
      await closeApp(tester, vpn);
    },
  );

  testWidgets('ZeroTier tile shows reported endpoint facts and query errors', (
    tester,
  ) async {
    zeroTierResponse = jsonEncode([
      {
        'tag': '家庭网络',
        'node_id': 'abc',
        'online': true,
        'network_id': 'network',
        'network_status': 'OK',
        'addresses': ['10.1.0.2', 'fd00::2'],
        'peers': [
          {
            'address': 'peer',
            'role': 'LEAF',
            'latency': 3,
            'version': '1.0',
            'path_count': 1,
          },
        ],
        'routes': [],
      },
    ]);
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    await revealExit(tester);
    expect(find.text('家庭网络'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('10.1.0.2'), findsOneWidget);
    expect(find.text('fd00::2'), findsNothing);
    expect(find.text('1 个对等端'), findsOneWidget);
    final endpoint =
        (jsonDecode(zeroTierResponse) as List<dynamic>).single
            as Map<String, dynamic>;
    endpoint['network_status'] = 'ACCESS_DENIED';
    zeroTierResponse = jsonEncode([endpoint]);
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('待授权'), findsOneWidget);
    expect(find.text('点击查看授权信息'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
    expect(vpn.state, VpnState.started);
    endpoint['network_status'] = 'OK';
    zeroTierResponse = jsonEncode([endpoint]);
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('待授权'), findsNothing);
    zeroTierFailure = true;
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('ZeroTier 状态读取失败'), findsOneWidget);
    expect(find.text('家庭网络'), findsOneWidget);
    await closeApp(tester, vpn);
  });

  testWidgets('charts use actual unpadded traffic series and incoming connections', (
    tester,
  ) async {
    trafficResponse =
        '[{"uplink":4096,"downlink":1024,"uplinkTotal":4096,"downlinkTotal":1024,"connectionsIn":2,"connectionsOut":90}]';
    final vpn = await _pumpApp(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    trafficResponse =
        '[{"uplink":4096,"downlink":1024,"uplinkTotal":4096,"downlinkTotal":1024,"connectionsIn":2,"connectionsOut":90},'
        '{"uplink":512,"downlink":5500,"uplinkTotal":4608,"downlinkTotal":6524,"connectionsIn":7,"connectionsOut":80}]';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    trafficResponse =
        '[{"uplink":4096,"downlink":1024,"uplinkTotal":4096,"downlinkTotal":1024,"connectionsIn":2,"connectionsOut":90},'
        '{"uplink":512,"downlink":5500,"uplinkTotal":4608,"downlinkTotal":6524,"connectionsIn":7,"connectionsOut":80},'
        '{"uplink":3072,"downlink":2048,"uplinkTotal":7680,"downlinkTotal":8572,"connectionsIn":4,"connectionsOut":100}]';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final charts = tester
        .widgetList<HistoryChart>(find.byType(HistoryChart))
        .toList();
    expect(charts, hasLength(2));
    final traffic = charts.singleWhere((chart) => !chart.compact);
    expect(traffic.primary, [1024, 5500, 2048]);
    expect(traffic.secondary, [4096, 512, 3072]);
    expect(traffic.ceiling, 6144);
    final connections = charts.singleWhere((chart) => chart.compact);
    expect(connections.primary, [2, 7, 4]);
    expect(connections.secondary, isEmpty);
    expect(connections.ceiling, 10);
    expect(find.text('60 秒峰值 7'), findsOneWidget);
    await closeApp(tester, vpn);
  });
}

List<List<int>> _trafficValues(List<TrafficStats> samples) => [
  for (final sample in samples)
    [
      sample.uplinkBytesPerSecond,
      sample.downlinkBytesPerSecond,
      sample.uplinkTotalBytes,
      sample.downlinkTotalBytes,
      sample.connectionsIn,
      sample.connectionsOut,
    ],
];

String _nestedGroups({int timestamp = 10, int delay = 0}) => jsonEncode([
  {
    'tag': '默认',
    'type': 'selector',
    'selectable': true,
    'now': '主备切换',
    'items': [
      {'tag': '主备切换', 'urlTestResult': null},
      {
        'tag': '叶节点',
        'urlTestResult': {'time': 9, 'delay': 42, 'success': true, 'error': ''},
      },
    ],
  },
  {
    'tag': '主备切换',
    'type': 'selector',
    'selectable': true,
    'now': '手动切换',
    'items': [
      {'tag': '手动切换', 'urlTestResult': null},
    ],
  },
  {
    'tag': '手动切换',
    'type': 'selector',
    'selectable': true,
    'now': '叶节点',
    'items': [
      {
        'tag': '叶节点',
        'urlTestResult': {
          'time': timestamp,
          'delay': delay,
          'success': true,
          'error': '',
        },
      },
    ],
  },
]);

Future<VpnService> _pumpApp(WidgetTester tester) async {
  final vpn = VpnService();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: vpn, child: const UtabakoApp()),
  );
  await tester.pumpAndSettle();
  return vpn;
}
