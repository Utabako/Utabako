import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'diagnostic_widgets.dart';

enum DiagnosticLogLevel { info, warn, error }

class DiagnosticLog {
  const DiagnosticLog(this.time, this.level, this.source, this.message);

  final DateTime time;
  final DiagnosticLogLevel level;
  final String source;
  final String message;

  String get timeLabel => time.toIso8601String().substring(11, 19);
  String get line =>
      '$timeLabel ${level.name.toUpperCase()} [$source] $message';
}

class DiagnosticLogsPanel extends StatefulWidget {
  const DiagnosticLogsPanel({
    super.key,
    required this.logs,
    required this.query,
    this.onReturnToConnection,
    this.connectionQuery,
  });

  final List<DiagnosticLog> logs;
  final TextEditingController query;
  final VoidCallback? onReturnToConnection;

  /// A connection's domain (or IP), matched against event messages.
  final String? connectionQuery;

  @override
  State<DiagnosticLogsPanel> createState() => _DiagnosticLogsPanelState();
}

class _DiagnosticLogsPanelState extends State<DiagnosticLogsPanel> {
  final _scroll = ScrollController();
  final _contextKey = GlobalKey();
  var _connectionKeyword = TextEditingController();
  final _ordinaryFilters = _LogFilters();
  var _connectionFilters = _LogFilters();
  late String _lastQuery;
  bool _following = true;
  DiagnosticLog? _contextLog;

  String get _connectionQuery => widget.connectionQuery?.trim() ?? '';
  bool get _isConnectionSearch => _connectionQuery.isNotEmpty;
  TextEditingController get _keyword =>
      _isConnectionSearch ? _connectionKeyword : widget.query;
  _LogFilters get _filters =>
      _isConnectionSearch ? _connectionFilters : _ordinaryFilters;

  @override
  void initState() {
    super.initState();
    _lastQuery = _keyword.text;
    widget.query.addListener(_refreshQuery);
    _connectionKeyword.addListener(_refreshQuery);
    _scrollToLatest();
  }

  @override
  void didUpdateWidget(DiagnosticLogsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      oldWidget.query.removeListener(_refreshQuery);
      widget.query.addListener(_refreshQuery);
    }
    final connectionChanged =
        (oldWidget.connectionQuery?.trim() ?? '') != _connectionQuery;
    if (oldWidget.query != widget.query || connectionChanged) {
      _contextLog = null;
    }
    if (connectionChanged) {
      _connectionKeyword.dispose();
      _connectionKeyword = TextEditingController()..addListener(_refreshQuery);
      _following = true;
      _connectionFilters = _LogFilters();
    }
    _lastQuery = _keyword.text;
    if (_following &&
        (oldWidget.logs != widget.logs ||
            oldWidget.query != widget.query ||
            connectionChanged)) {
      _scrollToLatest();
    }
  }

  @override
  void dispose() {
    widget.query.removeListener(_refreshQuery);
    _connectionKeyword.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refreshQuery() {
    final text = _keyword.text;
    if (_lastQuery == text) return;
    _lastQuery = text;
    _updateFilters();
  }

  void _toggleContext(DiagnosticLog log) {
    setState(() {
      _contextLog = _contextLog == log ? null : log;
      _following = false;
    });
    if (_contextLog == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _contextKey.currentContext;
      if (context != null && _contextLog == log) {
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  void _updateFilters([VoidCallback? update]) {
    setState(() {
      update?.call();
      _contextLog = null;
    });
    if (_following) _scrollToLatest();
  }

  void _toggleFollowing() {
    setState(() {
      _following = !_following;
      if (_following) _contextLog = null;
    });
    if (_following) _scrollToLatest();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
  }

  void _jumpToLatest() {
    if (!mounted || !_following || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.hasContentDimensions && position.extentAfter > 1) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制日志')));
    }
  }

  Widget _logRow(
    DiagnosticLog log,
    NexColors colors, {
    required bool wide,
    required bool alternate,
    required List<DiagnosticLog> nearby,
  }) {
    final expanded = nearby.isNotEmpty;
    final severity = switch (log.level) {
      DiagnosticLogLevel.info => colors.down,
      DiagnosticLogLevel.warn => colors.warn,
      DiagnosticLogLevel.error => colors.bad,
    };
    final time = Text(
      log.timeLabel,
      style: TextStyle(
        color: colors.muted,
        fontSize: 12,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final level = DiagnosticBadge(
      log.level.name.toUpperCase(),
      color: severity,
    );
    final source = Text(
      log.source,
      style: TextStyle(color: colors.muted, fontSize: 12),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final message = Text(log.message, style: const TextStyle(fontSize: 13));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: expanded
              ? colors.accentSoft
              : log.level == DiagnosticLogLevel.error
              ? colors.bad.withValues(alpha: .07)
              : alternate
              ? colors.background.withValues(alpha: .32)
              : Colors.transparent,
          child: InkWell(
            onTap: () => _toggleContext(log),
            child: Padding(
              padding: EdgeInsets.fromLTRB(wide ? 12 : 10, 3, 4, 3),
              child: Row(
                children: [
                  if (wide) ...[
                    SizedBox(width: 76, child: time),
                    SizedBox(
                      width: 68,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: level,
                      ),
                    ),
                    SizedBox(width: 112, child: source),
                    Expanded(child: message),
                  ] else
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 3,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [time, level, source],
                          ),
                          const SizedBox(height: 2),
                          message,
                        ],
                      ),
                    ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: expanded ? '收起前后文' : '查看前后文',
                    child: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: colors.muted,
                      size: 16,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '复制此行',
                    onPressed: () => _copy(log.line),
                    icon: const Icon(Icons.content_copy, size: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded) _logContext(log, nearby, colors),
      ],
    );
  }

  Widget _logContext(
    DiagnosticLog selected,
    List<DiagnosticLog> nearby,
    NexColors colors,
  ) {
    return Padding(
      key: _contextKey,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(left: BorderSide(color: colors.down, width: 2)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '前后文 · 不受筛选限制',
                      style: TextStyle(color: colors.muted, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '复制前后文',
                    onPressed: () =>
                        _copy(nearby.map((log) => log.line).join('\n')),
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                  ),
                ],
              ),
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final log in nearby)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          log.line,
                          style: TextStyle(
                            fontSize: 12,
                            color: log == selected ? colors.down : colors.muted,
                            fontWeight: log == selected
                                ? FontWeight.w600
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _keyword.text.trim().toLowerCase();
    final connectionQuery = _connectionQuery;
    final domain = connectionQuery.toLowerCase();
    final filters = _filters;
    final logs = widget.logs;
    final sources = {
      for (final log in logs) log.source,
      ?filters.source,
    }.toList()..sort();
    final visible = logs.where((log) {
      return (filters.level == null || log.level == filters.level) &&
          (filters.source == null || log.source == filters.source) &&
          (domain.isEmpty || log.message.toLowerCase().contains(domain)) &&
          (query.isEmpty || log.line.toLowerCase().contains(query));
    }).toList();
    final contextIndex = _contextLog == null ? -1 : logs.indexOf(_contextLog!);
    final nearby = contextIndex < 0
        ? const <DiagnosticLog>[]
        : logs.sublist(
            math.max(0, contextIndex - 2),
            math.min(logs.length, contextIndex + 3),
          );
    final theme = Theme.of(context);
    final colors = NexColors.of(context);
    final headingStyle = TextStyle(
      color: colors.muted,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    Widget filter<T>({
      required String label,
      required T? value,
      required List<DropdownMenuItem<T>> options,
      required ValueChanged<T?> onChanged,
    }) {
      return Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.surface2,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            hint: Text(label),
            style: theme.textTheme.bodySmall,
            isExpanded: true,
            isDense: true,
            items: [
              DropdownMenuItem<T>(child: Text(label)),
              ...options,
            ],
            onChanged: onChanged,
          ),
        ),
      );
    }

    final search = TextField(
      controller: _keyword,
      decoration: InputDecoration(
        hintText: '搜索日志关键词',
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        suffixIcon: _keyword.text.isEmpty
            ? null
            : IconButton(
                onPressed: _keyword.clear,
                tooltip: '清除搜索',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.clear, size: 18),
              ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        isDense: true,
      ),
      style: theme.textTheme.bodyMedium,
    );
    final levelFilter = filter<DiagnosticLogLevel>(
      label: '全部级别',
      value: filters.level,
      options: [
        for (final level in DiagnosticLogLevel.values)
          DropdownMenuItem(value: level, child: Text(level.name.toUpperCase())),
      ],
      onChanged: (level) => _updateFilters(() => filters.level = level),
    );
    final sourceFilter = filter<String>(
      label: '全部来源',
      value: filters.source,
      options: [
        for (final source in sources)
          DropdownMenuItem(
            value: source,
            child: Text(source, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (source) => _updateFilters(() => filters.source = source),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 740;
        final horizontalPadding = wide ? 24.0 : 12.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            wide ? 16 : 8,
            horizontalPadding,
            10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        '日志',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _toggleFollowing,
                    icon: Icon(
                      _following ? Icons.pause : Icons.vertical_align_bottom,
                      size: 17,
                    ),
                    label: Text(_following ? '暂停跟随' : '回到实时'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: visible.isEmpty
                        ? null
                        : () =>
                              _copy(visible.map((log) => log.line).join('\n')),
                    tooltip: '复制筛选结果',
                    icon: const Icon(Icons.copy_all_outlined, size: 19),
                  ),
                ],
              ),
              if (connectionQuery.isNotEmpty) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '按域名搜索：$connectionQuery',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.down,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: widget.onReturnToConnection,
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('返回连接'),
                    ),
                  ],
                ),
              ] else
                const SizedBox(height: 4),
              if (wide)
                Row(
                  children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: search,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(width: 118, child: levelFilter),
                    const SizedBox(width: 8),
                    SizedBox(width: 164, child: sourceFilter),
                  ],
                )
              else ...[
                search,
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: levelFilter),
                    const SizedBox(width: 8),
                    Expanded(child: sourceFilter),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: Material(
                  color: theme.colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: colors.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide)
                        ColoredBox(
                          color: colors.surface2,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: DefaultTextStyle(
                              style: headingStyle,
                              child: const Row(
                                children: [
                                  SizedBox(width: 76, child: Text('时间')),
                                  SizedBox(width: 68, child: Text('级别')),
                                  SizedBox(width: 112, child: Text('来源')),
                                  Expanded(child: Text('事件')),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: visible.isEmpty
                            ? const Center(child: Text('没有匹配的日志'))
                            : NotificationListener<ScrollMetricsNotification>(
                                // A lazy list may refine its extent after a jump.
                                onNotification: (event) {
                                  if (event.depth == 0) _jumpToLatest();
                                  return false;
                                },
                                child:
                                    NotificationListener<
                                      ScrollUpdateNotification
                                    >(
                                      onNotification: (event) {
                                        if (event.depth == 0 &&
                                            _following &&
                                            event.metrics.extentAfter > 1 &&
                                            (event.scrollDelta ?? 0) < 0) {
                                          setState(() => _following = false);
                                        }
                                        return false;
                                      },
                                      child: ListView.builder(
                                        controller: _scroll,
                                        itemCount: visible.length,
                                        itemBuilder: (context, index) {
                                          final log = visible[index];
                                          return _logRow(
                                            log,
                                            colors,
                                            wide: wide,
                                            alternate: index.isOdd,
                                            nearby: log == _contextLog
                                                ? nearby
                                                : const [],
                                          );
                                        },
                                      ),
                                    ),
                              ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${visible.length} / ${logs.length} 条',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Icon(
                              Icons.circle,
                              size: 7,
                              color: _following ? colors.good : colors.warn,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _following ? '实时跟随' : '已暂停跟随 · 继续接收',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.muted,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LogFilters {
  DiagnosticLogLevel? level;
  String? source;
}
