import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/service/vpn_service.dart';
import '../theme/app_theme.dart';
import '../widgets/latency_label.dart';
import '../widgets/zerotier_status.dart';
import 'history_chart.dart';

class HomeDashboard extends StatefulWidget {
  final bool active;
  final ValueChanged<String?> onOpenProxy;
  final VoidCallback onOpenZeroTier;

  const HomeDashboard({
    super.key,
    required this.active,
    required this.onOpenProxy,
    required this.onOpenZeroTier,
  });

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard>
    with WidgetsBindingObserver {
  VpnService? _vpn;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncTimers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vpn = context.read<VpnService>();
    if (_vpn != vpn) {
      _vpn?.removeListener(_syncTimers);
      _vpn = vpn..addListener(_syncTimers);
    }
    _syncTimers();
  }

  @override
  void didUpdateWidget(HomeDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimers();
  }

  void _syncTimers() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final visible = widget.active && foreground && _vpn!.isRunning;
    if (visible && _poller == null) {
      unawaited(_vpn!.loadOutbounds());
      _poller = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _vpn!.loadOutbounds(),
      );
    } else if (!visible) {
      _poller?.cancel();
      _poller = null;
    }
  }

  Future<void> _testExit(_ExitSelection exit) async {
    final error = await _vpn!.testOutbound(exit.leaf);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vpn?.removeListener(_syncTimers);
    _poller?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.select(
      (VpnService vpn) => widget.active
          ? (vpn.isRunning, vpn.outboundGroups, vpn.outboundError)
          : null,
    );
    context.select(
      (VpnService vpn) => widget.active ? vpn.testingOutbounds : null,
    );
    final vpn = context.read<VpnService>();
    final exit = vpn.isRunning ? _resolveExit(vpn.outboundGroups) : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Utabako')),
      body: ListView(
        // Bottom inset keeps the last tiles scrollable above the floating connection bar.
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
        children: [
          _TrafficCard(active: widget.active),
          const SizedBox(height: 12),
          _ConnectionsCard(active: widget.active),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _exitTile(vpn, exit)),
                const SizedBox(width: 12),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      context.select((VpnService vpn) {
                        if (!widget.active) return null;
                        final endpoint = vpn.isRunning
                            ? vpn.zeroTierEndpoints.firstOrNull
                            : null;
                        return (
                          running: vpn.isRunning,
                          tag: endpoint?.tag,
                          online: endpoint?.online ?? false,
                          networkStatus: endpoint?.networkStatus,
                          address: endpoint?.addresses.firstOrNull,
                          peers: endpoint?.peers.length ?? 0,
                          error: vpn.zeroTierError,
                        );
                      });
                      return _zeroTierTile(context.read<VpnService>());
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _exitTile(VpnService vpn, _ExitSelection? exit) {
    final colors = NexColors.of(context);
    final error = vpn.isRunning ? vpn.outboundError : null;
    return _DashboardTile(
      tileKey: const Key('exit-tile'),
      onTap: () => widget.onOpenProxy(exit?.focusGroupTag),
      title: '出口',
      icon: Icons.output_outlined,
      badge: exit == null
          ? null
          : LatencyLabel(
              result: exit.result,
              testing: vpn.testingOutbounds.contains(exit.leaf),
              fontSize: 12,
            ),
      name: vpn.isRunning ? exit?.leaf ?? '—' : '未连接',
      subtitle: error ?? (exit == null ? '—' : exit.chain.join(' · ')),
      subtitleColor: error == null ? null : colors.bad,
      footer: exit == null
          ? const SizedBox(height: 32)
          : Align(
              alignment: Alignment.centerRight,
              child: IconButton.filledTonal(
                tooltip: '测试出口延迟',
                onPressed: vpn.testingOutbounds.contains(exit.leaf)
                    ? null
                    : () => _testExit(exit),
                icon: const Icon(Icons.bolt, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: colors.surface2,
                  minimumSize: const Size(32, 32),
                  padding: const EdgeInsets.all(7),
                ),
              ),
            ),
    );
  }

  Widget _zeroTierTile(VpnService vpn) {
    final colors = NexColors.of(context);
    final endpoint = vpn.isRunning ? vpn.zeroTierEndpoints.firstOrNull : null;
    final error = vpn.isRunning ? vpn.zeroTierError : null;
    return _DashboardTile(
      onTap: widget.onOpenZeroTier,
      title: 'ZeroTier',
      icon: Icons.hub_outlined,
      badge: ZeroTierStatusBadge(endpoint: endpoint),
      name: endpoint?.tag ?? (vpn.isRunning ? '未配置 ZeroTier' : '未连接'),
      subtitle:
          error ??
          (!vpn.isRunning
              ? '连接后加入'
              : endpoint?.requiresAuthorization == true
              ? '点击查看授权信息'
              : endpoint?.requiresAuthentication == true
              ? '点击查看认证信息'
              : endpoint?.addresses.firstOrNull ?? '—'),
      subtitleColor: error == null ? null : colors.bad,
      footer: Row(
        children: [
          Expanded(
            child: Text(
              endpoint == null ? '' : '${endpoint.peers.length} 个对等端',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surface2,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.chevron_right, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ExitSelection {
  final String leaf;

  /// Last user-selectable group on the path; the proxy page only lists selectable groups.
  final String focusGroupTag;
  final List<String> chain;
  final UrlTestResult? result;

  const _ExitSelection(this.leaf, this.focusGroupTag, this.chain, this.result);
}

_ExitSelection? _resolveExit(List<OutboundGroup> groups) {
  final root = groups.where((group) => group.selectable).firstOrNull;
  if (root == null) return null;
  var group = root;
  var focusGroupTag = root.tag;
  final visited = <String>{};
  final chain = <String>[];
  while (visited.add(group.tag)) {
    if (group.selectable) focusGroupTag = group.tag;
    final next = groups
        .where((candidate) => candidate.tag == group.now)
        .firstOrNull;
    if (next == null) {
      if (group.now.isEmpty) return null;
      final item = group.items
          .where((item) => item.tag == group.now)
          .firstOrNull;
      return _ExitSelection(
        group.now,
        focusGroupTag,
        chain,
        item?.urlTestResult,
      );
    }
    chain.add(next.tag);
    group = next;
  }
  return null;
}

class _DashboardTile extends StatelessWidget {
  final Key? tileKey;
  final VoidCallback onTap;
  final String title;
  final IconData icon;
  final Widget? badge;
  final String name;
  final String subtitle;
  final Color? subtitleColor;
  final Widget footer;

  const _DashboardTile({
    this.tileKey,
    required this.onTap,
    required this.title,
    required this.icon,
    this.badge,
    required this.name,
    required this.subtitle,
    this.subtitleColor,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return Card(
      child: InkWell(
        key: tileKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: colors.muted),
                      const SizedBox(width: 5),
                      Text(
                        title,
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                    ],
                  ),
                  ?badge,
                ],
              ),
              const SizedBox(height: 12),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: subtitleColor ?? colors.muted,
                ),
              ),
              const SizedBox(height: 12),
              const Spacer(),
              footer,
            ],
          ),
        ),
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final bool active;

  const _TrafficCard({required this.active});

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _RateColumn(active: active, upload: false)),
                const SizedBox(width: 12),
                Expanded(child: _RateColumn(active: active, upload: true)),
              ],
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                context.select(
                  (VpnService vpn) => active ? vpn.isRunning : null,
                );
                context.select(
                  (VpnService vpn) => active
                      ? [
                          if (vpn.isRunning)
                            for (final sample in vpn.trafficHistory)
                              (
                                down: sample.downlinkBytesPerSecond,
                                up: sample.uplinkBytesPerSecond,
                              ),
                        ]
                      : null,
                );
                final vpn = context.read<VpnService>();
                final history = vpn.isRunning
                    ? vpn.trafficHistory
                    : const <TrafficStats>[];
                final down = history
                    .map((sample) => sample.downlinkBytesPerSecond.toDouble())
                    .toList();
                final up = history
                    .map((sample) => sample.uplinkBytesPerSecond.toDouble())
                    .toList();
                final max = [...down, ...up].fold(0.0, math.max);
                return RepaintBoundary(
                  child: HistoryChart(
                    primary: down,
                    secondary: up,
                    color: colors.down,
                    secondaryColor: colors.up,
                    ceiling: chartCeiling(max),
                    formatTick: (value) => _rate(value).join(' '),
                    connected: vpn.isRunning,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '60 秒前',
                  style: TextStyle(fontSize: 11, color: colors.faint),
                ),
                Text('现在', style: TextStyle(fontSize: 11, color: colors.faint)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RateColumn extends StatelessWidget {
  final bool active;
  final bool upload;

  const _RateColumn({required this.active, required this.upload});

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Legend(
          label: upload ? '上传' : '下载',
          color: upload ? colors.up : colors.down,
        ),
        const SizedBox(height: 6),
        Selector<VpnService, (bool, int, int)?>(
          selector: (_, vpn) => active
              ? (
                  vpn.isRunning,
                  upload
                      ? vpn.trafficStats.uplinkBytesPerSecond
                      : vpn.trafficStats.downlinkBytesPerSecond,
                  upload
                      ? vpn.trafficStats.uplinkTotalBytes
                      : vpn.trafficStats.downlinkTotalBytes,
                )
              : null,
          builder: (context, _, _) {
            final vpn = context.read<VpnService>();
            final stats = vpn.isRunning
                ? vpn.trafficStats
                : const TrafficStats();
            final rate = upload
                ? stats.uplinkBytesPerSecond
                : stats.downlinkBytesPerSecond;
            final total = upload
                ? stats.uplinkTotalBytes
                : stats.downlinkTotalBytes;
            final formatted = _rate(rate.toDouble());
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: formatted[0],
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                    children: [
                      TextSpan(
                        text: ' ${formatted[1]}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '本次 ${_bytes(total)}',
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ConnectionsCard extends StatelessWidget {
  final bool active;

  const _ConnectionsCard({required this.active});

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Legend(label: '活跃连接', color: colors.conn),
                      const SizedBox(height: 6),
                      Builder(
                        builder: (context) {
                          context.select(
                            (VpnService vpn) => active
                                ? (
                                    vpn.isRunning,
                                    vpn.trafficStats.connectionsIn,
                                  )
                                : null,
                          );
                          final vpn = context.read<VpnService>();
                          final current = vpn.isRunning
                              ? vpn.trafficStats.connectionsIn
                              : 0;
                          return Text.rich(
                            TextSpan(
                              text: '$current',
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                height: 1.1,
                              ),
                              children: [
                                TextSpan(
                                  text: ' 个',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: colors.muted,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (context) {
                    int peak(VpnService vpn) => vpn.isRunning
                        ? vpn.trafficHistory.fold(
                            0,
                            (value, sample) =>
                                math.max(value, sample.connectionsIn),
                          )
                        : 0;
                    context.select(
                      (VpnService vpn) => active ? peak(vpn) : null,
                    );
                    return Text(
                      '60 秒峰值 ${peak(context.read<VpnService>())}',
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                context.select(
                  (VpnService vpn) => active ? vpn.isRunning : null,
                );
                context.select(
                  (VpnService vpn) => active
                      ? [
                          if (vpn.isRunning)
                            for (final sample in vpn.trafficHistory)
                              sample.connectionsIn,
                        ]
                      : null,
                );
                final vpn = context.read<VpnService>();
                final samples = vpn.isRunning
                    ? vpn.trafficHistory
                          .map((sample) => sample.connectionsIn.toDouble())
                          .toList()
                    : <double>[];
                final peak = samples.fold(0.0, math.max);
                return RepaintBoundary(
                  child: HistoryChart(
                    primary: samples,
                    color: colors.conn,
                    ceiling: chartCeiling(peak, connections: true),
                    formatTick: (value) => value.round().toString(),
                    connected: vpn.isRunning,
                    compact: true,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final String label;
  final Color color;

  const _Legend({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(fontSize: 13, color: NexColors.of(context).muted),
      ),
    ],
  );
}

List<String> _rate(double bytes) => bytes >= 1048576
    ? [(bytes / 1048576).toStringAsFixed(1), 'MB/s']
    : bytes >= 1024
    ? [(bytes / 1024).round().toString(), 'KB/s']
    : [bytes.round().toString(), 'B/s'];

String _bytes(int bytes) => bytes >= 1073741824
    ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
    : bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).round()} KB';
