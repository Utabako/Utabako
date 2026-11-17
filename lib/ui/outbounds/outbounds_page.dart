import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/service/vpn_service.dart';
import '../theme/app_theme.dart';
import '../widgets/latency_label.dart';

/// Request from another tab to expand [groupTag] and scroll it into view.
@immutable
class ProxyFocus {
  final String groupTag;
  final int serial;

  const ProxyFocus({required this.groupTag, required this.serial});
}

class OutboundsPage extends StatefulWidget {
  final bool active;
  final ProxyFocus? focus;

  const OutboundsPage({super.key, required this.active, this.focus});

  @override
  State<OutboundsPage> createState() => _OutboundsPageState();
}

class _OutboundsPageState extends State<OutboundsPage> {
  Timer? _timer;
  VpnService? _vpn;
  bool _hideUnavailable = false;
  bool _sortByLatency = false;
  final _expanded = <String>{};
  final _groupKeys = <String, GlobalKey>{};
  int? _appliedFocusSerial;
  bool _focusScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vpn = context.read<VpnService>();
    if (_vpn != vpn) {
      _vpn?.removeListener(_syncPolling);
      _vpn = vpn;
      vpn.addListener(_syncPolling);
      _syncPolling();
    }
  }

  @override
  void didUpdateWidget(OutboundsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncPolling();
  }

  void _syncPolling() {
    if (widget.active && _vpn!.isRunning) {
      if (_timer != null) return;
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
      _refresh();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _refresh() async {
    if (!mounted || !widget.active || !_vpn!.isRunning) return;
    await _vpn!.loadOutbounds();
  }

  void _focusGroup(List<OutboundGroup> groups) {
    final focus = widget.focus;
    if (!widget.active ||
        focus == null ||
        focus.serial == _appliedFocusSerial ||
        _focusScheduled ||
        !groups.any((group) => group.tag == focus.groupTag)) {
      return;
    }
    _focusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScheduled = false;
      if (!mounted || !widget.active || widget.focus != focus) return;
      setState(() {
        _appliedFocusSerial = focus.serial;
        _expanded.add(focus.groupTag);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active) return;
        final target = _groupKeys[focus.groupTag]?.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 250),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _vpn?.removeListener(_syncPolling);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.select(
      (VpnService vpn) => (
        vpn.state,
        vpn.outboundGroups,
        vpn.outboundError,
        vpn.state == VpnState.error ? vpn.log : null,
      ),
    );
    final testingOutbounds = context.select(
      (VpnService vpn) => vpn.testingOutbounds,
    );
    final vpn = context.read<VpnService>();
    final nex = NexColors.of(context);
    final allGroups = vpn.outboundGroups;
    final groups = allGroups.where((group) => group.selectable).toList();
    if (vpn.isRunning) _focusGroup(groups);
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理'),
        actions: [
          FilterChip(
            label: const Text('隐藏不可用'),
            selected: _hideUnavailable,
            showCheckmark: false,
            avatar: Icon(
              _hideUnavailable
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
            ),
            onSelected: (value) => setState(() => _hideUnavailable = value),
          ),
          IconButton(
            tooltip: '按延迟排序',
            isSelected: _sortByLatency,
            style: IconButton.styleFrom(
              backgroundColor: _sortByLatency ? nex.accentSoft : null,
              foregroundColor: _sortByLatency
                  ? Theme.of(context).colorScheme.primary
                  : nex.muted,
            ),
            icon: const Icon(Icons.sort),
            onPressed: () => setState(() => _sortByLatency = !_sortByLatency),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !vpn.isRunning
          ? _disconnected(vpn)
          : groups.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  vpn.outboundError ?? '当前配置没有可选择的策略组',
                  style: TextStyle(
                    color: vpn.outboundError == null ? nex.muted : nex.bad,
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Column(
                  children: [
                    if (vpn.outboundError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          vpn.outboundError!,
                          style: TextStyle(color: nex.bad),
                        ),
                      ),
                    for (final group in groups)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _GroupCard(
                          key: _groupKeys.putIfAbsent(group.tag, GlobalKey.new),
                          group: group,
                          groups: {
                            for (final group in allGroups) group.tag: group,
                          },
                          expanded: _expanded.contains(group.tag),
                          testingOutbounds: testingOutbounds,
                          onToggle: () => setState(() {
                            if (!_expanded.add(group.tag)) {
                              _expanded.remove(group.tag);
                            }
                          }),
                          hideUnavailable: _hideUnavailable,
                          sortByLatency: _sortByLatency,
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _disconnected(VpnService vpn) {
    final nex = NexColors.of(context);
    final starting = vpn.state == VpnState.starting;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public, size: 48, color: nex.faint),
            const SizedBox(height: 16),
            const Text(
              '连接后可选择节点',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '策略组和节点来自运行中的 sing-box 核心。',
              textAlign: TextAlign.center,
              style: TextStyle(color: nex.muted),
            ),
            if (vpn.state == VpnState.error) ...[
              const SizedBox(height: 12),
              Text(vpn.log, style: TextStyle(color: nex.bad)),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: starting || vpn.state == VpnState.stopping
                  ? null
                  : vpn.start,
              icon: const Icon(Icons.power_settings_new),
              label: Text(starting ? '正在连接…' : '连接'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  final OutboundGroup group;
  final Map<String, OutboundGroup> groups;
  final bool expanded;
  final Set<String> testingOutbounds;
  final VoidCallback onToggle;
  final bool hideUnavailable;
  final bool sortByLatency;

  const _GroupCard({
    super.key,
    required this.group,
    required this.groups,
    required this.expanded,
    required this.onToggle,
    required this.testingOutbounds,
    required this.hideUnavailable,
    required this.sortByLatency,
  });

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  final _searchController = TextEditingController();
  final _nodesScrollController = ScrollController();
  bool _searchOpen = false;
  final _headerStates = WidgetStatesController();
  final _expansionController = ExpansibleController();

  @override
  void initState() {
    super.initState();
    if (widget.expanded) _expansionController.expand();
  }

  @override
  void didUpdateWidget(_GroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      if (widget.expanded) {
        _expansionController.expand();
      } else {
        _expansionController.collapse();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nodesScrollController.dispose();
    _headerStates.dispose();
    _expansionController.dispose();
    super.dispose();
  }

  Future<void> _testOutbound(String tag) async {
    final error = await context.read<VpnService>().testOutbound(tag);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _resetScroll() {
    if (_nodesScrollController.hasClients) _nodesScrollController.jumpTo(0);
  }

  void _closeSearch() {
    _searchController.clear();
    _resetScroll();
    setState(() => _searchOpen = false);
  }

  OutboundItem _resolve(OutboundItem item) {
    var current = item;
    final visited = <String>{};
    while (widget.groups.containsKey(current.tag) && visited.add(current.tag)) {
      final group = widget.groups[current.tag]!;
      final selected = group.items
          .where((item) => item.tag == group.now)
          .firstOrNull;
      if (selected == null) return OutboundItem(tag: group.now);
      current = selected;
    }
    return current;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nex = NexColors.of(context);
    final group = widget.group;
    final expanded = widget.expanded;
    final baseColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    return ValueListenableBuilder<Set<WidgetState>>(
      valueListenable: _headerStates,
      builder: (context, states, child) {
        final overlay = states.contains(WidgetState.pressed)
            ? theme.highlightColor
            : states.contains(WidgetState.focused)
            ? theme.focusColor
            : states.contains(WidgetState.hovered)
            ? theme.hoverColor
            : Colors.transparent;
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: Color.alphaBlend(overlay, baseColor)),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (context, color, child) => Card(color: color, child: child),
          child: child,
        );
      },
      child: Expansible(
        controller: _expansionController,
        maintainState: false,
        animationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
        ),
        headerBuilder: (context, animation) => InkWell(
          statesController: _headerStates,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.tag,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        expanded
                            ? '当前：${group.now}'
                            : '${group.items.length} 项',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: nex.muted),
                      ),
                    ],
                  ),
                ),
                if (expanded) ...[
                  IconButton(
                    tooltip: '搜索节点',
                    isSelected: _searchOpen,
                    icon: const Icon(Icons.search, size: 20),
                    color: _searchOpen ? theme.colorScheme.primary : nex.muted,
                    onPressed: () {
                      if (_searchOpen) {
                        _closeSearch();
                      } else {
                        setState(() => _searchOpen = true);
                      }
                    },
                  ),
                  IconButton(
                    tooltip: '整组测速',
                    onPressed: () {
                      if (!widget.testingOutbounds.contains(group.tag)) {
                        _testOutbound(group.tag);
                      }
                    },
                    icon: widget.testingOutbounds.contains(group.tag)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.bolt, size: 20, color: nex.muted),
                  ),
                ] else ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      group.now,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: nex.muted),
                    ),
                  ),
                ],
                RotationTransition(
                  turns: animation.drive(
                    Tween<double>(
                      begin: 0,
                      end: 0.5,
                    ).chain(CurveTween(curve: Curves.easeInOutCubic)),
                  ),
                  child: Icon(Icons.expand_more, color: nex.faint, size: 20),
                ),
              ],
            ),
          ),
        ),
        bodyBuilder: (context, animation) => !expanded && animation.isDismissed
            ? const SizedBox.shrink()
            : _buildOptions(context),
      ),
    );
  }

  Widget _buildOptions(BuildContext context) {
    final nex = NexColors.of(context);
    final group = widget.group;
    final query = _searchController.text.trim().toLowerCase();
    final matching = group.items
        .where((item) => item.tag.toLowerCase().contains(query))
        .toList();
    final options = matching
        .where(
          (item) =>
              !widget.hideUnavailable || item.urlTestResult?.success != false,
        )
        .toList();
    final hidden = matching.length - options.length;
    if (widget.sortByLatency) {
      final originalOrder = {
        for (var i = 0; i < group.items.length; i++) group.items[i].tag: i,
      };
      int rank(UrlTestResult? result) => result == null
          ? 1
          : result.success
          ? 0
          : 2;
      options.sort((a, b) {
        final ar = _resolve(a).urlTestResult;
        final br = _resolve(b).urlTestResult;
        final category = rank(ar).compareTo(rank(br));
        if (category != 0) return category;
        if (ar?.success == true && br?.success == true) {
          final delay = ar!.delayMillis.compareTo(br!.delayMillis);
          if (delay != 0) return delay;
        }
        return originalOrder[a.tag]!.compareTo(originalOrder[b.tag]!);
      });
    }
    final tileHeight = 84.0 * MediaQuery.textScalerOf(context).scale(1);
    final rows = (options.length / 2).ceil();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索 ${group.items.length} 个节点',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  fillColor: nex.surface2,
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: '关闭搜索',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _closeSearch,
                  ),
                ),
                onChanged: (_) {
                  _resetScroll();
                  setState(() {});
                },
              ),
            ),
          if (options.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('没有符合条件的节点', style: TextStyle(color: nex.muted)),
            )
          else
            SizedBox(
              height: math.min(
                rows * tileHeight + (rows - 1) * 8,
                MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: Scrollbar(
                controller: _nodesScrollController,
                child: GridView.builder(
                  controller: _nodesScrollController,
                  primary: false,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisExtent: tileHeight,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: options.length,
                  itemBuilder: (context, index) =>
                      _buildOption(context, options[index]),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '${options.length} 个节点${hidden > 0 ? ' · 已隐藏 $hidden 个不可用' : ''}',
              style: TextStyle(fontSize: 12, color: nex.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOption(BuildContext context, OutboundItem item) {
    final theme = Theme.of(context);
    final nex = NexColors.of(context);
    final group = widget.group;
    final selected = item.tag == group.now;
    final leaf = _resolve(item);
    final testing = widget.testingOutbounds.contains(leaf.tag);
    return Material(
      key: ValueKey('${group.tag}/${item.tag}'),
      color: selected ? nex.accentSoft : nex.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final error = await context.read<VpnService>().selectOutbound(
            group.tag,
            item.tag,
          );
          if (!context.mounted) return;
          if (error != null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(error)));
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.tag,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: widget.groups.containsKey(item.tag)
                        ? Text(
                            '→ ${leaf.tag}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: nex.muted),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Tooltip(
                    message: '测试节点延迟',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        if (!testing) _testOutbound(leaf.tag);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: LatencyLabel(
                          result: leaf.urlTestResult,
                          testing: testing,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
