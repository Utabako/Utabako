import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

enum VpnState { stopped, starting, started, stopping, error }

enum VpnStartupStage { waitingForZeroTierAuthorization, loadingRuleSets }

class UrlTestResult {
  final int timestampSeconds;
  final int delayMillis;
  final bool success;
  final String error;

  const UrlTestResult({
    required this.timestampSeconds,
    required this.delayMillis,
    required this.success,
    required this.error,
  });

  factory UrlTestResult.fromJson(Map<String, dynamic> json) => UrlTestResult(
    timestampSeconds: json['time'] as int,
    delayMillis: json['delay'] as int,
    success: json['success'] as bool,
    error: json['error'] as String,
  );
}

class OutboundItem {
  final String tag;
  final UrlTestResult? urlTestResult;

  const OutboundItem({required this.tag, this.urlTestResult});

  factory OutboundItem.fromJson(Map<String, dynamic> json) {
    final result = json['urlTestResult'] as Map<String, dynamic>?;
    return OutboundItem(
      tag: json['tag'] as String,
      urlTestResult: result == null ? null : UrlTestResult.fromJson(result),
    );
  }
}

class OutboundGroup {
  final String tag;
  final String type;
  final String now;

  /// Whether the user may pick `now` (selector groups); automatic groups such as urltest are not selectable.
  final bool selectable;
  final List<OutboundItem> items;

  OutboundGroup({
    required this.tag,
    required this.type,
    required this.now,
    required this.selectable,
    required this.items,
  });

  factory OutboundGroup.fromJson(Map<String, dynamic> json) => OutboundGroup(
    tag: json['tag'] as String,
    type: json['type'] as String,
    now: json['now'] as String,
    selectable: json['selectable'] as bool,
    items: (json['items'] as List<dynamic>)
        .map((item) => OutboundItem.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class TrafficStats {
  final int uplinkBytesPerSecond;
  final int downlinkBytesPerSecond;
  final int uplinkTotalBytes;
  final int downlinkTotalBytes;

  /// Connections tracked by the core traffic manager (the active connection list).
  final int connectionsIn;

  /// Outbound connections currently held by the core connection manager.
  final int connectionsOut;

  const TrafficStats({
    this.uplinkBytesPerSecond = 0,
    this.downlinkBytesPerSecond = 0,
    this.uplinkTotalBytes = 0,
    this.downlinkTotalBytes = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
  });

  factory TrafficStats.fromJson(Map<String, dynamic> json) {
    return TrafficStats(
      uplinkBytesPerSecond: (json['uplink'] as num).toInt(),
      downlinkBytesPerSecond: (json['downlink'] as num).toInt(),
      uplinkTotalBytes: (json['uplinkTotal'] as num).toInt(),
      downlinkTotalBytes: (json['downlinkTotal'] as num).toInt(),
      connectionsIn: (json['connectionsIn'] as num).toInt(),
      connectionsOut: (json['connectionsOut'] as num).toInt(),
    );
  }
}

/// One ZeroTier endpoint as reported by libbox `getZeroTierStatus` (sing-box protocol/zerotier StatusInfo).
class ZeroTierEndpointStatus {
  final String tag;
  final String nodeId;
  final bool online;
  final String networkId;
  final String networkStatus;
  final List<String> addresses;
  final List<ZeroTierPeer> peers;
  final List<ZeroTierRoute> routes;

  const ZeroTierEndpointStatus({
    required this.tag,
    required this.nodeId,
    required this.online,
    required this.networkId,
    required this.networkStatus,
    required this.addresses,
    required this.peers,
    required this.routes,
  });

  factory ZeroTierEndpointStatus.fromJson(Map<String, dynamic> json) =>
      ZeroTierEndpointStatus(
        tag: json['tag'] as String,
        nodeId: json['node_id'] as String,
        online: json['online'] as bool,
        networkId: json['network_id'] as String,
        networkStatus: json['network_status'] as String,
        addresses: (json['addresses'] as List<dynamic>? ?? const [])
            .cast<String>(),
        peers: (json['peers'] as List<dynamic>? ?? const [])
            .map((e) => ZeroTierPeer.fromJson(e as Map<String, dynamic>))
            .toList(),
        routes: (json['routes'] as List<dynamic>? ?? const [])
            .map((e) => ZeroTierRoute.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ZeroTierPeer {
  final String address;
  final String role;
  final int latency;
  final String version;
  final int pathCount;

  const ZeroTierPeer({
    required this.address,
    required this.role,
    required this.latency,
    required this.version,
    required this.pathCount,
  });

  factory ZeroTierPeer.fromJson(Map<String, dynamic> json) => ZeroTierPeer(
    address: json['address'] as String,
    role: json['role'] as String,
    latency: json['latency'] as int,
    version: json['version'] as String,
    pathCount: json['path_count'] as int,
  );
}

class ZeroTierRoute {
  final String target;
  final String? via;

  const ZeroTierRoute({required this.target, this.via});

  factory ZeroTierRoute.fromJson(Map<String, dynamic> json) => ZeroTierRoute(
    target: json['target'] as String,
    via: json['via'] as String?,
  );
}

class AppInfo {
  final String packageName;
  final String label;

  const AppInfo({required this.packageName, required this.label});

  factory AppInfo.fromJson(Map<String, dynamic> json) {
    return AppInfo(
      packageName: json['packageName'] as String,
      label: json['label'] as String,
    );
  }
}

class PerAppProxyConfig {
  final String mode; // "all" | "include" | "exclude"
  final List<String> packages;

  const PerAppProxyConfig({this.mode = 'all', this.packages = const []});

  factory PerAppProxyConfig.fromJson(Map<String, dynamic> json) {
    return PerAppProxyConfig(
      mode: json['mode'] as String? ?? 'all',
      packages: (json['packages'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {'mode': mode, 'packages': packages};
}

class ConfigProfile {
  final String id;
  String name;
  String? url;
  int? updatedAt;

  ConfigProfile({
    required this.id,
    required this.name,
    this.url,
    this.updatedAt,
  });

  factory ConfigProfile.fromJson(Map<String, dynamic> json) {
    return ConfigProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String?,
      updatedAt: json['updatedAt'] as int?,
    );
  }

  bool get isSubscription => url != null && url!.isNotEmpty;
}

class VpnService extends ChangeNotifier {
  static const _channel = MethodChannel('io.github.utabako/vpn');

  VpnState _state = VpnState.stopped;
  VpnStartupStage? _startupStage;
  String? _configJson;
  String _log = '';
  String _coreVersion = '';
  String _appVersion = '';
  ThemeMode _themeMode = ThemeMode.system;

  List<ConfigProfile> _profiles = [];
  String? _activeProfileId;
  List<OutboundGroup> _outboundGroups = [];
  String? _outboundsResponse;
  String? _outboundError;
  final _pendingOutboundTests = <String, Completer<String?>>{};
  int _outboundSnapshotRevision = 0;
  bool _autostart = false;
  bool _disableIpv6 = false;
  PerAppProxyConfig _perAppProxy = const PerAppProxyConfig();
  DateTime? _startedAt;
  List<TrafficStats> _trafficHistory = const [];
  List<ZeroTierEndpointStatus> _zeroTierEndpoints = const [];
  String? _zeroTierError;
  bool _foreground = true;
  Timer? _sampler;
  int _samplerTicks = 0;
  bool _sampling = false;

  VpnState get state => _state;
  VpnStartupStage? get startupStage => _startupStage;
  String? get configJson => _configJson;
  String get log => _log;
  String get coreVersion => _coreVersion;
  String get appVersion => _appVersion;
  bool get isRunning => _state == VpnState.started;
  List<ConfigProfile> get profiles => _profiles;
  String? get activeProfileId => _activeProfileId;
  ThemeMode get themeMode => _themeMode;
  List<OutboundGroup> get outboundGroups => _outboundGroups;

  Set<String> get testingOutbounds => _pendingOutboundTests.keys.toSet();

  /// Error from the most recent [loadOutbounds]; null when it succeeded. Last groups are kept on failure.
  String? get outboundError => _outboundError;
  TrafficStats get trafficStats =>
      _trafficHistory.isEmpty ? const TrafficStats() : _trafficHistory.last;
  bool get autostart => _autostart;
  bool get disableIpv6 => _disableIpv6;
  PerAppProxyConfig get perAppProxy => _perAppProxy;

  /// When the native service entered `started` (owned by the native layer, survives app restarts).
  DateTime? get startedAt => _startedAt;

  /// Native VPN session's latest 60 real status samples, oldest first.
  /// The last read immutable snapshot is retained while Flutter is in the background.
  List<TrafficStats> get trafficHistory => _trafficHistory;

  /// Last successfully read ZeroTier endpoints; refreshed every 2 s while sampling.
  List<ZeroTierEndpointStatus> get zeroTierEndpoints => _zeroTierEndpoints;

  /// Error from the most recent ZeroTier status read, null when it succeeded.
  String? get zeroTierError => _zeroTierError;

  VpnService() {
    _channel.setMethodCallHandler(_handleNativeCall);
    _setup();
  }

  Future<void> _setup() async {
    try {
      await _channel.invokeMethod('setup');
      _coreVersion = await _channel.invokeMethod('version') ?? '';
      _appVersion = await _channel.invokeMethod<String>('appVersion') ?? '';
      _configJson = await rootBundle.loadString('assets/default_config.json');
      await loadProfiles();
      await loadAutostart();
      _disableIpv6 =
          await _channel.invokeMethod<bool>('getDisableIpv6') ?? false;
      await loadPerAppProxy();
      try {
        final state =
            await _channel.invokeMethod<String>('getState') ?? 'stopped';
        _applyNativeState(state, notify: false);
      } on PlatformException catch (_) {}
      // Load saved theme preference
      try {
        final mode =
            await _channel.invokeMethod<String>('getThemeMode') ?? 'system';
        _themeMode = _parseThemeMode(mode);
      } on PlatformException catch (_) {}
      notifyListeners();
    } on PlatformException catch (e) {
      _state = VpnState.error;
      _log = 'Setup failed: ${e.message}';
      notifyListeners();
    }
  }

  ThemeMode _parseThemeMode(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final s = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
        ? 'dark'
        : 'system';
    try {
      await _channel.invokeMethod('setThemeMode', {'mode': s});
      _themeMode = mode;
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onStateChanged') {
      _applyNativeState(call.arguments as String);
    }
  }

  void _applyNativeState(String state, {bool notify = true}) {
    final wasStarted = _state == VpnState.started;
    switch (state) {
      case 'stopped':
        _state = VpnState.stopped;
      case 'starting':
        _state = VpnState.starting;
      case 'started':
        _state = VpnState.started;
      case 'stopping':
        _state = VpnState.stopping;
      default:
        _state = VpnState.error;
        _log = state.startsWith('error:')
            ? state.substring('error:'.length)
            : 'Unknown VPN state: $state';
    }
    if (_state != VpnState.starting) _startupStage = null;
    if (_state == VpnState.started && !wasStarted) {
      _loadStartedAt();
    } else if (_state != VpnState.started) {
      _pendingOutboundTests.clear();
      _outboundSnapshotRevision++;
      _startedAt = null;
      if (_state != VpnState.starting) {
        _zeroTierEndpoints = const [];
        _zeroTierError = null;
      }
    }
    _syncSampler();
    if (notify) notifyListeners();
  }

  Future<void> _loadStartedAt() async {
    try {
      final millis = await _channel.invokeMethod<int>('getStartedAt');
      _startedAt = millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis);
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  /// The UI shell reports app foreground state; sampling pauses in the background.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _syncSampler();
  }

  void _syncSampler() {
    if (_state != VpnState.started) _trafficHistory = const [];
    final shouldRun =
        _foreground &&
        (_state == VpnState.starting || _state == VpnState.started);
    if (shouldRun == (_sampler != null)) return;
    if (shouldRun) {
      _samplerTicks = 0;
      _sampler = Timer.periodic(const Duration(seconds: 1), _sampleTick);
      _sampleTick(_sampler!);
    } else {
      _sampler?.cancel();
      _sampler = null;
    }
  }

  Future<void> _sampleTick(Timer sampler) async {
    if (_sampling) return;
    _sampling = true;
    try {
      if (_state == VpnState.starting) {
        final stage = await _queryStartupStage();
        if (_sampler != sampler || _state != VpnState.starting) return;
        _startupStage = stage;
        await _fetchZeroTierStatus();
      } else {
        final history = await _queryTrafficStats();
        if (_sampler != sampler || _state != VpnState.started) return;
        if (history != null) _trafficHistory = history;
        if (_samplerTicks++ % 2 == 0) await _fetchZeroTierStatus();
      }
      if (_sampler == sampler) notifyListeners();
    } finally {
      _sampling = false;
    }
  }

  @override
  void dispose() {
    _sampler?.cancel();
    _sampler = null;
    _pendingOutboundTests.clear();
    super.dispose();
  }

  Future<String?> checkConfig(String json) async {
    try {
      await _channel.invokeMethod('checkConfig', {'config': json});
      return null;
    } on PlatformException catch (e) {
      return e.message;
    }
  }

  Future<void> start() async {
    if (_state != VpnState.stopped && _state != VpnState.error) return;

    // Load active profile's config if available
    if (_activeProfileId != null && _activeProfileId!.isNotEmpty) {
      final config = await getProfileConfig(_activeProfileId!);
      if (config != null) _configJson = config;
    }

    if (_configJson == null) return;

    _state = VpnState.starting;
    _log = '';
    _syncSampler();
    notifyListeners();

    try {
      await _channel.invokeMethod('start', {'config': _configJson});
    } on PlatformException catch (e) {
      if (_state == VpnState.starting) {
        _applyNativeState('error:Start failed: ${e.message}');
      }
    }
  }

  Future<void> stop() async {
    final previous = _state;
    if (previous != VpnState.started && previous != VpnState.starting) return;
    _state = VpnState.stopping;
    _syncSampler();
    notifyListeners();

    try {
      await _channel.invokeMethod('stop');
    } on PlatformException catch (e) {
      if (_state == VpnState.stopping) {
        _log = 'Stop failed: ${e.message}';
        _state = previous;
        _syncSampler();
        notifyListeners();
      }
    }
  }

  Future<void> toggle() async {
    if (_state == VpnState.stopped || _state == VpnState.error) {
      await start();
    } else if (_state == VpnState.started) {
      await stop();
    }
  }

  Future<String> readLog() async {
    try {
      return await _channel.invokeMethod<String>('readLog') ?? '';
    } on PlatformException {
      return '';
    }
  }

  Future<void> clearLog() async {
    try {
      await _channel.invokeMethod('clearLog');
    } on PlatformException catch (_) {}
  }

  Future<String?> exportLog() async {
    try {
      return await _channel.invokeMethod<String>('exportLog');
    } on PlatformException {
      return null;
    }
  }

  // Profile management

  Future<void> loadProfiles() async {
    try {
      final raw = await _channel.invokeMethod<String>('listProfiles');
      if (raw != null) {
        final meta = jsonDecode(raw) as Map<String, dynamic>;
        _activeProfileId = meta['activeId'] as String?;
        final list = meta['profiles'] as List<dynamic>;
        _profiles = list
            .map((e) => ConfigProfile.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } on PlatformException catch (_) {}
    notifyListeners();
  }

  Future<String?> getProfileConfig(String id) async {
    try {
      return await _channel.invokeMethod<String>('getProfile', {'id': id});
    } on PlatformException catch (_) {
      return null;
    }
  }

  Future<String> saveProfile({
    String? id,
    required String name,
    required String config,
    String? url,
  }) async {
    final result = await _channel.invokeMethod<String>('saveProfile', {
      'id': ?id,
      'name': name,
      'config': config,
      'url': ?url,
    });
    await loadProfiles();
    return result!;
  }

  Future<void> deleteProfile(String id) async {
    try {
      await _channel.invokeMethod('deleteProfile', {'id': id});
      await loadProfiles();
    } on PlatformException catch (_) {}
  }

  /// Activates [id] natively and loads its config for the next start. Returns an error message when
  /// either step fails; callers must not start the VPN after a failure.
  Future<String?> setActiveProfile(String id) async {
    try {
      await _channel.invokeMethod('setActiveProfile', {'id': id});
      _activeProfileId = id;
      _configJson = await _channel.invokeMethod<String>('getProfile', {
        'id': id,
      });
      return null;
    } on PlatformException catch (error) {
      return error.message ?? '切换配置失败';
    } finally {
      notifyListeners();
    }
  }

  Future<String?> fetchSubscription(String url) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Utabako/0.1');
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response
            .transform(const SystemEncoding().decoder)
            .join();
        client.close();
        return body;
      }
      client.close();
      return null;
    } catch (_) {
      return null;
    }
  }

  // Outbound management

  Future<void> loadOutbounds() async {
    final revision = _outboundSnapshotRevision;
    try {
      final raw = await _channel.invokeMethod<String>('queryOutbounds') ?? '[]';
      if (revision != _outboundSnapshotRevision) return;
      if (raw == _outboundsResponse) {
        if (_outboundError != null) {
          _outboundError = null;
          notifyListeners();
        }
        return;
      }
      final list = jsonDecode(raw) as List<dynamic>;
      _outboundGroups = list
          .map((e) => OutboundGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      _outboundsResponse = raw;
      _outboundError = null;
    } on PlatformException catch (error) {
      if (revision != _outboundSnapshotRevision) return;
      _outboundError = error.message ?? '读取策略组失败';
    }
    notifyListeners();
  }

  Future<String?> selectOutbound(String groupTag, String outboundTag) async {
    try {
      await _channel.invokeMethod('selectOutbound', {
        'groupTag': groupTag,
        'outboundTag': outboundTag,
      });
      final index = _outboundGroups.indexWhere(
        (group) => group.tag == groupTag,
      );
      if (index != -1) {
        final group = _outboundGroups[index];
        final groups = List<OutboundGroup>.of(_outboundGroups);
        groups[index] = OutboundGroup(
          tag: group.tag,
          type: group.type,
          now: outboundTag,
          selectable: group.selectable,
          items: group.items,
        );
        _outboundGroups = groups;
        // The next native snapshot must reconcile the optimistic selection,
        // even when it matches the response from before the selection.
        _outboundsResponse = null;
        notifyListeners();
      }
      return null;
    } on PlatformException catch (error) {
      return error.message ?? '出口切换失败';
    }
  }

  Future<String?> testOutbound(String outboundTag) {
    final existing = _pendingOutboundTests[outboundTag];
    if (existing != null) return existing.future;
    final completion = Completer<String?>();
    _pendingOutboundTests[outboundTag] = completion;
    _runOutboundTest(
      outboundTag,
      completion,
    ).then(completion.complete, onError: completion.completeError);
    notifyListeners();
    return completion.future;
  }

  Future<String?> _runOutboundTest(
    String outboundTag,
    Completer<String?> completion,
  ) async {
    try {
      final groups = {for (final group in _outboundGroups) group.tag: group};
      if (groups.containsKey(outboundTag)) {
        final visited = <String>{};
        final leaves = <String>[];
        void visit(String tag) {
          if (!visited.add(tag)) return;
          final group = groups[tag];
          if (group == null) {
            leaves.add(tag);
          } else {
            for (final item in group.items) {
              visit(item.tag);
            }
          }
        }

        visit(outboundTag);
        final errors = await Future.wait(leaves.map(testOutbound));
        if (!isRunning ||
            !identical(_pendingOutboundTests[outboundTag], completion)) {
          return null;
        }
        final failures = [
          for (var i = 0; i < leaves.length; i++)
            if (errors[i] != null) '${leaves[i]}: ${errors[i]}',
        ];
        return failures.isEmpty ? null : failures.join('\n');
      }

      final raw = await _channel.invokeMethod<String>('urlTest', {
        'outboundTag': outboundTag,
      });
      if (!isRunning ||
          !identical(_pendingOutboundTests[outboundTag], completion)) {
        return null;
      }
      final items = (jsonDecode(raw!) as List<dynamic>).map(
        (value) => OutboundItem.fromJson(value as Map<String, dynamic>),
      );
      final results = {for (final item in items) item.tag: item};
      _outboundSnapshotRevision++;
      _outboundGroups = [
        for (final group in _outboundGroups)
          OutboundGroup(
            tag: group.tag,
            type: group.type,
            now: group.now,
            selectable: group.selectable,
            items: [for (final item in group.items) results[item.tag] ?? item],
          ),
      ];
      return null;
    } on PlatformException catch (error) {
      if (!isRunning ||
          !identical(_pendingOutboundTests[outboundTag], completion)) {
        return null;
      }
      return error.message ?? '延迟测试请求失败';
    } finally {
      if (identical(_pendingOutboundTests[outboundTag], completion)) {
        _pendingOutboundTests.remove(outboundTag);
        notifyListeners();
      }
    }
  }

  // Traffic stats

  Future<List<TrafficStats>?> _queryTrafficStats() async {
    try {
      final raw = await _channel.invokeMethod<String>('queryTrafficStats');
      return List.unmodifiable(
        (jsonDecode(raw!) as List<dynamic>).map(
          (sample) => TrafficStats.fromJson(sample as Map<String, dynamic>),
        ),
      );
    } on PlatformException catch (_) {
      return null;
    }
  }

  Future<VpnStartupStage?> _queryStartupStage() async {
    try {
      final stage = await _channel.invokeMethod<String>('getStartupStage');
      return switch (stage) {
        'waiting-zerotier-authorization' =>
          VpnStartupStage.waitingForZeroTierAuthorization,
        'loading-rule-sets' => VpnStartupStage.loadingRuleSets,
        _ => null,
      };
    } on PlatformException {
      return null;
    }
  }

  Future<void> _fetchZeroTierStatus() async {
    final sampler = _sampler;
    try {
      final raw = await _channel.invokeMethod<String>('zerotierStatus');
      if (sampler != _sampler) return;
      _zeroTierEndpoints = (jsonDecode(raw!) as List<dynamic>)
          .map(
            (e) => ZeroTierEndpointStatus.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      _zeroTierError = null;
    } on PlatformException catch (e) {
      if (sampler != _sampler) return;
      _zeroTierError = e.message ?? 'ZeroTier 状态读取失败';
    }
  }

  /// Immediate ZeroTier refresh for pages that need it outside the 2 s sampler cadence.
  Future<void> refreshZeroTierStatus() async {
    await _fetchZeroTierStatus();
    notifyListeners();
  }

  // Per-app proxy

  Future<List<AppInfo>> getInstalledApps() async {
    try {
      final raw =
          await _channel.invokeMethod<String>('getInstalledApps') ?? '[]';
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AppInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } on PlatformException catch (_) {
      return [];
    }
  }

  Future<void> loadPerAppProxy() async {
    try {
      final raw = await _channel.invokeMethod<String>('getPerAppProxy') ?? '{}';
      _perAppProxy = PerAppProxyConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  Future<String?> savePerAppProxy(PerAppProxyConfig config) async {
    if (config.mode == 'include' && config.packages.isEmpty) {
      return '仅选中模式至少需要一个应用';
    }
    try {
      await _channel.invokeMethod('setPerAppProxy', {
        'config': jsonEncode(config.toJson()),
      });
      _perAppProxy = config;
      notifyListeners();
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '保存分应用代理设置失败';
    }
  }

  Future<String?> setDisableIpv6(bool disabled) async {
    try {
      await _channel.invokeMethod('setDisableIpv6', {'disabled': disabled});
      _disableIpv6 = disabled;
      notifyListeners();
      return null;
    } on PlatformException catch (error) {
      return error.message ?? '保存 IPv6 设置失败';
    }
  }

  // Autostart

  Future<void> loadAutostart() async {
    try {
      final v = await _channel.invokeMethod<bool>('getAutostart') ?? false;
      _autostart = v;
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  Future<void> setAutostart(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutostart', {'enabled': enabled});
      _autostart = enabled;
      notifyListeners();
    } on PlatformException catch (_) {}
  }
}
