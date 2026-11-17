import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utabako/core/service/vpn_service.dart';
import 'package:utabako/ui/more/more_page.dart';
import 'package:utabako/ui/profiles/profiles_page.dart';
import 'package:utabako/ui/theme/app_theme.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.utabako/vpn');
  late List<MethodCall> calls;
  late List<String> events;
  late String profilesJson;
  late bool failSetActive;
  late bool failStop;
  late String zeroTierJson;
  late bool failZeroTier;
  String? saveError;
  Completer<void>? pendingSave;
  late bool disableIpv6;
  String? disableIpv6SaveError;
  Completer<void>? initialized;

  setUp(() {
    initialized = null;
    calls = [];
    events = [];
    profilesJson = '{"activeId":"","profiles":[]}';
    failSetActive = false;
    failStop = false;
    zeroTierJson = '[]';
    failZeroTier = false;
    saveError = null;
    pendingSave = null;
    disableIpv6 = false;
    disableIpv6SaveError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getThemeMode') initialized?.complete();
          if (call.method == 'zerotierStatus' && failZeroTier) {
            throw PlatformException(code: 'query', message: 'ZeroTier 读取失败');
          }
          if (call.method == 'stop') {
            events.add('stop');
            if (failStop) {
              throw PlatformException(code: 'stop_failed', message: '停止失败');
            }
          }
          if (call.method == 'setActiveProfile') {
            events.add('setActiveProfile');
            if (failSetActive) {
              throw PlatformException(
                code: 'activation_failed',
                message: '激活配置失败',
              );
            }
          }
          if (call.method == 'getProfile') events.add('getProfile');
          if (call.method == 'start') events.add('start');
          if (call.method == 'setDisableIpv6') {
            if (disableIpv6SaveError != null) {
              throw PlatformException(
                code: 'settings',
                message: disableIpv6SaveError,
              );
            }
            disableIpv6 = call.arguments['disabled'] as bool;
          }
          if (call.method == 'saveProfile') {
            await pendingSave?.future;
            if (saveError != null) {
              throw PlatformException(
                code: 'RULE_SET_PREPARATION',
                message: saveError,
              );
            }
            return 'profile-1';
          }
          return switch (call.method) {
            'version' => 'test',
            'listProfiles' => profilesJson,
            'getAutostart' => false,
            'getDisableIpv6' => disableIpv6,
            'getPerAppProxy' => '{"mode":"all","packages":[]}',
            'getState' => 'stopped',
            'getThemeMode' => 'system',
            'queryOutbounds' => '[]',
            'queryTrafficStats' => '[]',
            'getStartedAt' => null,
            'zerotierStatus' => zeroTierJson,
            'readLog' => '',
            'getInstalledApps' =>
              '[{"packageName":"app.one","label":"App One"}]',
            'getProfile' => '{}',
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> sendNativeState(String state) async {
    if (state == 'stopped') events.add('native:stopped');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          StandardMethodCodec().encodeMethodCall(
            MethodCall('onStateChanged', state),
          ),
          null,
        );
  }

  Future<VpnService> pumpProfiles(
    WidgetTester tester, {
    VpnService? service,
  }) async {
    final vpn = service ?? VpnService();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vpn,
        child: const MaterialApp(home: ProfilesPage()),
      ),
    );
    await tester.pumpAndSettle();
    return vpn;
  }

  Future<VpnService> pumpMore(WidgetTester tester) async {
    final vpn = (await tester.runAsync(() async {
      initialized = Completer<void>();
      final service = VpnService();
      await initialized!.future;
      return service;
    }))!;
    initialized = null;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vpn,
        child: const MaterialApp(home: MorePage(active: true)),
      ),
    );
    await tester.pumpAndSettle();
    return vpn;
  }

  testWidgets('More lists network, diagnostics, and general settings', (
    tester,
  ) async {
    final vpn = await pumpMore(tester);
    for (final label in [
      'ZeroTier',
      '分应用代理',
      '禁用 IPv6',
      '日志',
      '主题模式',
      '开机自启',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('IPv6 setting persists without restarting the active VPN', (
    tester,
  ) async {
    final toggle = find.widgetWithText(SwitchListTile, '禁用 IPv6');
    final vpn = await pumpMore(tester);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    calls.clear();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(disableIpv6, isTrue);
    expect(
      calls.where((call) => call.method == 'start' || call.method == 'stop'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();

    final restored = await pumpMore(tester);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(disableIpv6, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    restored.dispose();
  });

  testWidgets('IPv6 setting keeps its value when persistence fails', (
    tester,
  ) async {
    disableIpv6SaveError = 'Failed to persist IPv6 setting';
    final vpn = await pumpMore(tester);
    final toggle = find.widgetWithText(SwitchListTile, '禁用 IPv6');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(disableIpv6, isFalse);
    expect(find.text(disableIpv6SaveError!), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('More ignores traffic but ZeroTier details stay live', (
    tester,
  ) async {
    final vpn = VpnService();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vpn,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MorePage(active: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await sendNativeState('started');
    await tester.pumpAndSettle();
    final scaffoldBefore = tester.widget<Scaffold>(find.byType(Scaffold));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)),
      same(scaffoldBefore),
    );

    zeroTierJson =
        '[{"tag":"家庭网络","node_id":"abc","network_id":"network","network_status":"OK","online":true,"addresses":["10.1.0.2"],"peers":[],"routes":[]}]';
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('在线 · 10.1.0.2'), findsOneWidget);
    final unchangedSummary = tester.widget<Scaffold>(find.byType(Scaffold));
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)),
      same(unchangedSummary),
    );
    await tester.tap(find.text('ZeroTier'));
    await tester.pumpAndSettle();
    expect(find.text('家庭网络'), findsOneWidget);
    expect(find.text('10.1.0.2'), findsOneWidget);
    failZeroTier = true;
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('ZeroTier 读取失败'), findsOneWidget);
    failZeroTier = false;
    zeroTierJson =
        '[{"tag":"家庭网络","node_id":"abc","network_id":"network","network_status":"OK","online":true,"addresses":["10.1.0.3"],"peers":[],"routes":[]}]';
    await vpn.refreshZeroTierStatus();
    await tester.pump();
    expect(find.text('ZeroTier 读取失败'), findsNothing);
    expect(find.text('10.1.0.3'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('在线 · 10.1.0.3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets(
    'pending authorization exposes identity and updates without restarting VPN',
    (tester) async {
      final clipboardWrites = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardWrites.add(
                (call.arguments as Map<Object?, Object?>)['text']! as String,
              );
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      zeroTierJson =
          '[{"tag":"家庭网络","node_id":"0123456789","network_id":"0123456789abcdef","network_status":"ACCESS_DENIED","online":true,"addresses":[],"peers":[],"routes":[]}]';
      final vpn = VpnService();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vpn,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const MorePage(active: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await sendNativeState('started');
      await tester.pumpAndSettle();
      expect(find.text('待授权 · 点击查看节点 ID'), findsOneWidget);
      expect(vpn.state, VpnState.started);
      await tester.tap(find.text('ZeroTier'));
      await tester.pumpAndSettle();
      expect(find.text('待授权'), findsOneWidget);
      expect(find.text('ACCESS_DENIED'), findsOneWidget);
      expect(find.textContaining('授权后会自动连接'), findsOneWidget);
      await tester.tap(find.byTooltip('复制节点 ID'));
      await tester.pump();
      await tester.tap(find.byTooltip('复制网络 ID'));
      await tester.pump();
      expect(clipboardWrites, ['0123456789', '0123456789abcdef']);

      await tester.pageBack();
      await tester.pumpAndSettle();
      zeroTierJson =
          '[{"tag":"家庭网络","node_id":"0123456789","network_id":"0123456789abcdef","network_status":"AUTHENTICATION_REQUIRED","online":true,"addresses":[],"peers":[],"routes":[]}]';
      await vpn.refreshZeroTierStatus();
      await tester.pump();
      expect(find.text('需认证 · 点击查看网络信息'), findsOneWidget);
      zeroTierJson =
          '[{"tag":"家庭网络","node_id":"0123456789","network_id":"0123456789abcdef","network_status":"OK","online":true,"addresses":["10.1.0.3"],"peers":[],"routes":[]}]';
      await vpn.refreshZeroTierStatus();
      await tester.pump();
      expect(find.text('在线 · 10.1.0.3'), findsOneWidget);
      await tester.tap(find.text('ZeroTier'));
      await tester.pumpAndSettle();
      expect(find.text('在线'), findsOneWidget);
      expect(find.text('10.1.0.3'), findsOneWidget);
      expect(find.textContaining('授权后会自动连接'), findsNothing);
      expect(vpn.state, VpnState.started);
      expect(
        calls.where((call) => call.method == 'start' || call.method == 'stop'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      vpn.dispose();
    },
  );

  testWidgets('theme sheet persists selected theme mode', (tester) async {
    final vpn = VpnService();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vpn,
        child: const MaterialApp(home: MorePage(active: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(
      calls.any(
        (call) =>
            call.method == 'setThemeMode' &&
            (call.arguments as Map)['mode'] == 'dark',
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('profile deletion requires confirmation', (tester) async {
    profilesJson =
        '{"activeId":"other","profiles":[{"id":"profile-1","name":"备用配置","url":null,"updatedAt":null}]}';
    final vpn = await pumpProfiles(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除“备用配置”？'), findsOneWidget);
    expect(calls.where((call) => call.method == 'deleteProfile'), isEmpty);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'deleteProfile'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets(
    'subscription update waits for rule preparation and preserves failures',
    (tester) async {
      profilesJson =
          '{"activeId":"profile-1","profiles":[{"id":"profile-1","name":"日常订阅","url":"https://example.com/config.json","updatedAt":0}]}';
      final vpn = await pumpProfiles(
        tester,
        service: _SubscriptionVpnService('{"route":{"rule_set":[]}}'),
      );
      final originalProfiles = vpn.profiles;
      saveError = 'prepare rule-set reject: HTTP 503';
      pendingSave = Completer<void>();
      await tester.tap(find.text('更新'));
      await tester.pump();
      expect(find.text('更新中'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '更新中'))
            .onPressed,
        isNull,
      );
      expect(find.text('订阅已更新'), findsNothing);
      pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining(saveError!), findsOneWidget);
      expect(vpn.profiles, same(originalProfiles));
      expect(vpn.activeProfileId, 'profile-1');
      expect(vpn.profiles.single.updatedAt, 0);
      expect(find.text('订阅已更新'), findsNothing);
      expect(find.text('更新'), findsOneWidget);
      saveError = null;
      pendingSave = null;
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      expect(find.text('订阅已更新'), findsOneWidget);
      expect(calls.where((call) => call.method == 'saveProfile'), hasLength(2));
      expect(
        calls.where((call) => call.method == 'start' || call.method == 'stop'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      vpn.dispose();
    },
  );

  testWidgets('editor keeps content and reports rule preparation failures', (
    tester,
  ) async {
    profilesJson =
        '{"activeId":"profile-1","profiles":[{"id":"profile-1","name":"日常配置","url":null,"updatedAt":0}]}';
    saveError = 'prepare rule-set reject: invalid rule content';
    final vpn = await pumpProfiles(tester);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining(saveError!), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '{}'))
          .controller!
          .text,
      '{}',
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNotNull,
    );
    expect(vpn.activeProfileId, 'profile-1');
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets(
    'switching profile waits for native stop before activation and restart',
    (tester) async {
      profilesJson =
          '{"activeId":"active","profiles":[{"id":"active","name":"当前","url":null,"updatedAt":null},{"id":"next","name":"下一份","url":null,"updatedAt":null}]}';
      final vpn = await pumpProfiles(tester);
      await sendNativeState('started');
      await tester.pumpAndSettle();
      calls.clear();
      events.clear();

      await tester.tap(find.text('使用'));
      await tester.pumpAndSettle();
      expect(find.text('切换配置需要重新连接，当前连接会短暂中断。'), findsOneWidget);
      await tester.tap(find.text('切换并重连'));
      await tester.pump();
      expect(events, ['stop']);
      expect(calls.where((call) => call.method == 'setActiveProfile'), isEmpty);

      await sendNativeState('stopped');
      await tester.pumpAndSettle();
      expect(events.where((event) => event != 'getProfile').toList(), [
        'stop',
        'native:stopped',
        'setActiveProfile',
        'start',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      vpn.dispose();
    },
  );

  testWidgets('activation failure after stopping does not restart VPN', (
    tester,
  ) async {
    profilesJson =
        '{"activeId":"active","profiles":[{"id":"active","name":"当前","url":null,"updatedAt":null},{"id":"next","name":"下一份","url":null,"updatedAt":null}]}';
    failSetActive = true;
    final vpn = await pumpProfiles(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    calls.clear();
    events.clear();

    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换并重连'));
    await tester.pump();
    await sendNativeState('stopped');
    await tester.pumpAndSettle();

    expect(events, ['stop', 'native:stopped', 'setActiveProfile']);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    expect(find.text('激活配置失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('stop failure leaves profile unchanged and reports the error', (
    tester,
  ) async {
    profilesJson =
        '{"activeId":"active","profiles":[{"id":"active","name":"当前","url":null,"updatedAt":null},{"id":"next","name":"下一份","url":null,"updatedAt":null}]}';
    failStop = true;
    final vpn = await pumpProfiles(tester);
    await sendNativeState('started');
    await tester.pumpAndSettle();
    calls.clear();
    events.clear();

    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换并重连'));
    await tester.pumpAndSettle();

    expect(events, ['stop']);
    expect(calls.where((call) => call.method == 'setActiveProfile'), isEmpty);
    expect(find.text('断开 VPN 失败，配置未切换'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('rejects profile switching while the VPN is starting', (
    tester,
  ) async {
    profilesJson =
        '{"activeId":"active","profiles":[{"id":"active","name":"当前","url":null,"updatedAt":null},{"id":"next","name":"下一份","url":null,"updatedAt":null}]}';
    final vpn = await pumpProfiles(tester);
    await sendNativeState('starting');
    await tester.pumpAndSettle();
    calls.clear();

    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();

    expect(find.text('正在连接，请稍后再切换'), findsOneWidget);
    expect(calls.where((call) => call.method == 'setActiveProfile'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
  });

  testWidgets('rejects an empty include policy before persistence', (
    tester,
  ) async {
    final vpn = VpnService();
    await tester.pumpAndSettle();
    calls.clear();
    await vpn.savePerAppProxy(const PerAppProxyConfig(mode: 'include'));
    expect(calls.where((call) => call.method == 'setPerAppProxy'), isEmpty);
    vpn.dispose();
  });
}

class _SubscriptionVpnService extends VpnService {
  final String subscription;
  _SubscriptionVpnService(this.subscription);

  @override
  Future<String?> fetchSubscription(String url) async => subscription;
}
