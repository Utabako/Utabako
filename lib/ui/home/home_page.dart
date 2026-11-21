import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/service/vpn_service.dart';
import '../more/more_page.dart';
import '../more/zerotier_page.dart';
import '../outbounds/outbounds_page.dart';
import '../profiles/profiles_page.dart';
import '../theme/app_theme.dart';
import 'home_dashboard.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  int _focusSerial = 0;
  ProxyFocus? _proxyFocus;
  bool _resumed = true;
  bool _homeCovered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<VpnService>().setForeground(_resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    context.read<VpnService>().setForeground(resumed);
    if (_resumed != resumed) setState(() => _resumed = resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _openProxy(String? groupTag) {
    setState(() {
      if (groupTag != null) {
        _proxyFocus = ProxyFocus(groupTag: groupTag, serial: ++_focusSerial);
      }
      _selectedIndex = 1;
    });
  }

  Future<void> _openZeroTier() async {
    setState(() => _homeCovered = true);
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const ZeroTierPage()));
    if (!mounted) return;
    setState(() => _homeCovered = false);
  }

  @override
  Widget build(BuildContext context) {
    final homeActive = _resumed && _selectedIndex == 0 && !_homeCovered;
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _selectedIndex,
            children: [
              TickerMode(
                enabled: homeActive,
                child: HomeDashboard(
                  active: homeActive,
                  onOpenProxy: _openProxy,
                  onOpenZeroTier: _openZeroTier,
                ),
              ),
              TickerMode(
                enabled: _resumed && _selectedIndex == 1,
                child: OutboundsPage(
                  active: _resumed && _selectedIndex == 1,
                  focus: _proxyFocus,
                ),
              ),
              const ProfilesPage(),
              MorePage(active: _resumed && _selectedIndex == 3),
            ],
          ),
          // Floats over the home list; HomeDashboard reserves bottom padding for it.
          if (_selectedIndex == 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ConnectionBar(
                active: homeActive,
                onOpenZeroTier: _openZeroTier,
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
          NavigationDestination(icon: Icon(Icons.public_outlined), label: '代理'),
          NavigationDestination(icon: Icon(Icons.layers_outlined), label: '配置'),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: '更多',
          ),
        ],
      ),
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  final bool active;
  final VoidCallback onOpenZeroTier;

  const _ConnectionBar({required this.active, required this.onOpenZeroTier});

  @override
  Widget build(BuildContext context) {
    final (state, stage, startedAt, profile, error) = context.select(
      (VpnService vpn) => (
        vpn.state,
        vpn.startupStage,
        vpn.startedAt,
        vpn.profiles
            .where((profile) => profile.id == vpn.activeProfileId)
            .firstOrNull,
        vpn.state == VpnState.error ? vpn.log : null,
      ),
    );
    final vpn = context.read<VpnService>();
    final colors = NexColors.of(context);
    final profileName = profile?.name ?? '没有配置';
    final waitingAuthorization =
        state == VpnState.starting &&
        stage == VpnStartupStage.waitingForZeroTierAuthorization;
    final label = switch (state) {
      VpnState.stopped => '未连接',
      VpnState.starting => switch (stage) {
        VpnStartupStage.waitingForZeroTierAuthorization => '等待 ZeroTier 授权',
        VpnStartupStage.loadingRuleSets => '正在加载规则…',
        null => '正在连接…',
      },
      VpnState.started => '已连接',
      VpnState.stopping => '正在断开…',
      VpnState.error => '错误',
    };
    final dotColor = switch (state) {
      VpnState.started => colors.good,
      VpnState.error => colors.bad,
      VpnState.starting ||
      VpnState.stopping => Theme.of(context).colorScheme.primary,
      VpnState.stopped => colors.faint,
    };
    final subtitle = state == VpnState.started
        ? _ConnectionRuntime(
            active: active,
            startedAt: startedAt,
            profileName: profileName,
          )
        : waitingAuthorization
        ? InkWell(
            onTap: onOpenZeroTier,
            child: Text(
              '查看节点 ID',
              style: TextStyle(color: colors.down, fontSize: 13),
            ),
          )
        : Text(
            state == VpnState.error ? error! : profileName,
            maxLines: state == VpnState.error ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: state == VpnState.error ? colors.bad : colors.muted,
              fontSize: 12,
            ),
          );
    final button = state == VpnState.started || state == VpnState.starting
        ? FilledButton.tonalIcon(
            onPressed: vpn.stop,
            icon: Icon(
              state == VpnState.started
                  ? Icons.power_settings_new
                  : Icons.close,
              size: 18,
            ),
            label: Text(state == VpnState.started ? '断开' : '取消'),
          )
        : FilledButton.icon(
            onPressed: state == VpnState.stopping || profile == null
                ? null
                : vpn.start,
            icon: const Icon(Icons.power_settings_new, size: 18),
            label: const Text('连接'),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          label,
                          key: const Key('connection-status'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    subtitle,
                  ],
                ),
              ),
              const SizedBox(width: 12),
              button,
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionRuntime extends StatefulWidget {
  final bool active;
  final DateTime? startedAt;
  final String profileName;

  const _ConnectionRuntime({
    required this.active,
    required this.startedAt,
    required this.profileName,
  });

  @override
  State<_ConnectionRuntime> createState() => _ConnectionRuntimeState();
}

class _ConnectionRuntimeState extends State<_ConnectionRuntime> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_ConnectionRuntime oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.active) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.startedAt == null
        ? Duration.zero
        : DateTime.now().difference(widget.startedAt!);
    final seconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
    final runtime = [
      seconds ~/ 3600,
      seconds ~/ 60 % 60,
      seconds % 60,
    ].map((value) => '$value'.padLeft(2, '0')).join(':');
    return RepaintBoundary(
      child: Text(
        '$runtime · ${widget.profileName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: NexColors.of(context).muted),
      ),
    );
  }
}
