import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'diagnostic_widgets.dart';

class DiagnosticConnection {
  const DiagnosticConnection({
    required this.id,
    required this.host,
    required this.destination,
    required this.source,
    required this.rule,
    required this.outbound,
    required this.chain,
    required this.protocol,
    required this.uploadBytes,
    required this.inbound,
    required this.startedAt,
    required this.uploadRate,
    required this.downloadBytes,
    required this.downloadRate,
    this.process,
    this.closedAt,
  });

  final String id;
  final String host;
  final String destination;
  final String source;
  final String? process;
  final String rule;
  final String outbound;
  final List<String> chain;
  final String protocol;
  final String inbound;
  final DateTime startedAt;
  final DateTime? closedAt;
  final int uploadRate;
  final int uploadBytes;
  final int downloadBytes;
  final int downloadRate;

  Duration durationAt(DateTime now) => (closedAt ?? now).difference(startedAt);

  DiagnosticConnection copyWith({
    DateTime? closedAt,
    int? uploadRate,
    int? downloadRate,
    int? uploadBytes,
    int? downloadBytes,
  }) => DiagnosticConnection(
    id: id,
    host: host,
    destination: destination,
    source: source,
    rule: rule,
    outbound: outbound,
    chain: chain,
    protocol: protocol,
    process: process,
    inbound: inbound,
    startedAt: startedAt,
    closedAt: closedAt ?? this.closedAt,
    uploadRate: uploadRate ?? this.uploadRate,
    downloadRate: downloadRate ?? this.downloadRate,
    uploadBytes: uploadBytes ?? this.uploadBytes,
    downloadBytes: downloadBytes ?? this.downloadBytes,
  );
}

class ConnectionsPanel extends StatefulWidget {
  const ConnectionsPanel({
    super.key,
    required this.active,
    required this.closed,
    required this.onClose,
    required this.onSearchLogs,
  });

  final List<DiagnosticConnection> active;
  final List<DiagnosticConnection> closed;
  final ValueChanged<String> onClose;
  final ValueChanged<String> onSearchLogs;

  @override
  State<ConnectionsPanel> createState() => _ConnectionsPanelState();
}

class _ConnectionsPanelState extends State<ConnectionsPanel> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  bool _showClosed = false;
  String? _outbound;
  String? _protocol;
  _ConnectionSort _sort = _ConnectionSort.started;
  bool _ascending = false;
  DiagnosticConnection? _selection;
  List<DiagnosticConnection>? _heldOrder;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ConnectionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_heldOrder == null && _selection == null) return;
    // Keep final counters and the end time even after the core drops the history entry.
    final closed = {for (final row in widget.closed) row.id: row};
    _heldOrder = _heldOrder?.map((row) => closed[row.id] ?? row).toList();
    if (_selection case final row?) _selection = closed[row.id] ?? row;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  List<DiagnosticConnection> _matchingRows() {
    final query = _search.text.trim().toLowerCase();
    final rows = (_showClosed ? widget.closed : widget.active).where((row) {
      return (_outbound == null || _outbound == row.outbound) &&
          (_protocol == null || _protocol == row.protocol) &&
          (query.isEmpty ||
              [
                row.host,
                row.destination,
                row.source,
                row.rule,
                row.process,
                row.outbound,
              ].any((value) => value?.toLowerCase().contains(query) ?? false));
    }).toList();
    final now = DateTime.now();
    return rows..sort((a, b) {
      final value = _sort.compare(a, b, now: now);
      if (value != 0) return _ascending ? value : -value;
      return b.startedAt.compareTo(a.startedAt);
    });
  }

  void _onScroll() {
    if (_scroll.offset > 0 && _heldOrder == null) {
      setState(() => _heldOrder = _matchingRows());
    }
  }

  void _changeView(VoidCallback change) {
    setState(() {
      change();
      _heldOrder = _selection == null ? null : _matchingRows();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _sortBy(_ConnectionSort sort) => _changeView(() {
    _ascending = sort == _sort ? !_ascending : sort.alphabetic;
    _sort = sort;
  });

  void _select(DiagnosticConnection row) {
    setState(() {
      _heldOrder ??= _matchingRows();
      _selection = row;
    });
  }

  void _closeDetails() {
    setState(() {
      _selection = null;
      if (!_scroll.hasClients || _scroll.offset == 0) _heldOrder = null;
    });
  }

  void _disconnect(DiagnosticConnection row) {
    widget.onClose(row.id);
    if (!_showClosed && _heldOrder != null) {
      setState(() => _heldOrder!.removeWhere((item) => item.id == row.id));
    }
  }

  Widget _disconnectButton(DiagnosticConnection row) => IconButton(
    tooltip: '断开 ${row.host}',
    onPressed: () => _disconnect(row),
    icon: const Icon(Icons.link_off, size: 19),
  );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final colors = NexColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = {for (final row in widget.active) row.id: row};
    final known = {for (final row in widget.closed) row.id: row, ...active};
    final matches = _matchingRows();
    final held = _heldOrder;
    final rows = held == null
        ? matches
        : [for (final row in held) known[row.id] ?? row];
    final shown = rows.map((row) => row.id).toSet();
    final pending = held == null
        ? 0
        : matches.where((row) => !shown.contains(row.id)).length;
    final orderChanged =
        held != null &&
        (rows.length != matches.length ||
            rows.indexed.any((item) => item.$2.id != matches[item.$1].id));
    final filtered =
        _search.text.trim().isNotEmpty ||
        _outbound != null ||
        _protocol != null;
    final down = widget.active.fold(0, (sum, row) => sum + row.downloadRate);
    final up = widget.active.fold(0, (sum, row) => sum + row.uploadRate);
    final selection = _selection;
    final selected = selection == null
        ? null
        : known[selection.id] ?? selection;

    return LayoutBuilder(
      builder: (context, viewport) {
        const detailWidth = 248.0;
        final split = viewport.maxWidth >= 730 + detailWidth + 1;
        final table = viewport.maxWidth >= 650;
        final narrowDetail = selected != null && !split;
        final detail = selected == null
            ? null
            : _ConnectionDetails(
                key: ValueKey(selected.id),
                connection: selected,
                now: now,
                active: active.containsKey(selected.id),
                onBack: _closeDetails,
                onSearchLogs: () => widget.onSearchLogs(selected.host),
                onClose: () => _disconnect(selected),
                fullPage: !split,
              );

        final outboundFilter = _ConnectionFacet(
          label: '出站',
          value: _outbound,
          options: {
            for (final row in known.values) row.outbound,
            ?_outbound,
          }.toList()..sort(),
          onChanged: (value) => _changeView(() => _outbound = value),
          inHeader: table,
        );
        final protocolFilter = _ConnectionFacet(
          label: '协议',
          value: _protocol,
          options: {
            for (final row in known.values) row.protocol,
            ?_protocol,
          }.toList()..sort(),
          onChanged: (value) => _changeView(() => _protocol = value),
          inHeader: table,
        );

        Widget heading(
          String label,
          _ConnectionSort field, {
          Widget? facet,
          bool right = false,
        }) {
          final sorted = _sort == field;
          final direction = _ascending ? '升序' : '降序';
          final color = sorted ? scheme.primary : colors.muted;
          return Row(
            mainAxisAlignment: right
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Tooltip(
                  message: sorted ? '按$label排序 · $direction' : '按$label排序',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => _sortBy(field),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 1,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: color,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (sorted) ...[
                            const SizedBox(width: 3),
                            Icon(
                              _ascending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 13,
                              color: color,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ?facet,
            ],
          );
        }

        final list = Padding(
          padding: EdgeInsets.fromLTRB(
            table ? 20 : 14,
            16,
            table ? 20 : 14,
            12,
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
                        '连接',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      text: '${active.length} 条活跃   ',
                      children: [
                        TextSpan(
                          text: '↓ ${_traffic(down)}/s',
                          style: TextStyle(color: colors.down),
                        ),
                        const TextSpan(text: '   '),
                        TextSpan(
                          text: '↑ ${_traffic(up)}/s',
                          style: TextStyle(color: colors.up),
                        ),
                      ],
                    ),
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, toolbar) {
                  return Wrap(
                    spacing: 9,
                    runSpacing: 7,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 170,
                        child: SegmentedButton<bool>(
                          expandedInsets: EdgeInsets.zero,
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: false, label: Text('进行中')),
                            ButtonSegment(value: true, label: Text('最近关闭')),
                          ],
                          selected: {_showClosed},
                          onSelectionChanged: (values) => _changeView(() {
                            _showClosed = values.single;
                            if (_showClosed) {
                              _sort = switch (_sort) {
                                _ConnectionSort.downloadRate =>
                                  _ConnectionSort.downloadTotal,
                                _ConnectionSort.uploadRate =>
                                  _ConnectionSort.uploadTotal,
                                _ => _sort,
                              };
                            }
                            _selection = null;
                          }),
                        ),
                      ),
                      SizedBox(
                        width: table
                            ? toolbar.maxWidth - 179
                            : toolbar.maxWidth,
                        child: TextField(
                          controller: _search,
                          decoration: InputDecoration(
                            hintText: '搜索目标、进程、规则或出站',
                            prefixIcon: const Icon(Icons.search, size: 18),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空搜索',
                                    onPressed: () => _changeView(_search.clear),
                                    icon: const Icon(Icons.clear, size: 18),
                                  ),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _changeView(() {}),
                        ),
                      ),
                    ],
                  );
                },
              ),
              if (!table)
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    outboundFilter,
                    protocolFilter,
                    PopupMenuButton<_ConnectionSort>(
                      tooltip: '选择排序字段',
                      initialValue: _sort,
                      onSelected: _sortBy,
                      itemBuilder: (context) => [
                        for (final field in _ConnectionSort.values)
                          if (!_showClosed || !field.isRate)
                            CheckedPopupMenuItem(
                              value: field,
                              checked: field == _sort,
                              child: Text(field.label),
                            ),
                      ],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _sort.label,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.primary,
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 15,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: _ascending ? '升序，切换为降序' : '降序，切换为升序',
                      onPressed: () => _sortBy(_sort),
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 15,
                      ),
                      color: scheme.primary,
                    ),
                  ],
                ),
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            if (_outbound case final value?) ...[
                              InputChip(
                                label: Text('出站：$value'),
                                deleteButtonTooltipMessage: '清除出站筛选',
                                onDeleted: () =>
                                    _changeView(() => _outbound = null),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (_protocol case final value?) ...[
                              InputChip(
                                label: Text('协议：$value'),
                                deleteButtonTooltipMessage: '清除协议筛选',
                                onDeleted: () =>
                                    _changeView(() => _protocol = null),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (filtered)
                              Text(
                                '${matches.length} 条匹配',
                                style: TextStyle(
                                  color: colors.muted,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (orderChanged)
                      TextButton(
                        onPressed: () => _changeView(() {}),
                        child: Text(
                          pending > 0 && !_showClosed
                              ? '显示 $pending 条新连接 ↑'
                              : '更新列表',
                        ),
                      )
                    else if (!filtered)
                      Text(
                        held == null ? '实时更新' : '保持列表位置',
                        style: TextStyle(color: colors.muted, fontSize: 11),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, area) {
                    final showStarted = table && area.maxWidth >= 1040;
                    final compactColumns = area.maxWidth < 750;
                    final header = table
                        ? ColoredBox(
                            color: colors.surface2,
                            child: _ConnectionColumns(
                              target: heading('目标', _ConnectionSort.host),
                              process: heading(
                                compactColumns ? '应用' : '应用 / 协议',
                                _ConnectionSort.process,
                                facet: protocolFilter,
                              ),
                              outbound: heading(
                                compactColumns ? '出站' : '出站 / 规则',
                                _ConnectionSort.outbound,
                                facet: outboundFilter,
                              ),
                              downRate: _showClosed
                                  ? null
                                  : heading(
                                      '下载速率',
                                      _ConnectionSort.downloadRate,
                                      right: true,
                                    ),
                              upRate: _showClosed
                                  ? null
                                  : heading(
                                      '上传速率',
                                      _ConnectionSort.uploadRate,
                                      right: true,
                                    ),
                              downTotal: heading(
                                '累计下载',
                                _ConnectionSort.downloadTotal,
                                right: true,
                              ),
                              upTotal: heading(
                                '累计上传',
                                _ConnectionSort.uploadTotal,
                                right: true,
                              ),
                              time: heading(
                                '时长',
                                _ConnectionSort.duration,
                                right: true,
                              ),
                              started: showStarted
                                  ? heading(
                                      '开始时间',
                                      _ConnectionSort.started,
                                      right: true,
                                    )
                                  : null,
                              action: Text(
                                '操作',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                        : null;

                    return Material(
                      color: scheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: colors.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          ?header,
                          Expanded(
                            child: rows.isEmpty
                                ? Center(
                                    child: Text(filtered ? '没有匹配的连接' : '暂无连接'),
                                  )
                                : ListView.builder(
                                    controller: _scroll,
                                    itemCount: rows.length,
                                    itemExtent: table ? 51 : 94,
                                    itemBuilder: (context, index) {
                                      final row = rows[index];
                                      final running = active.containsKey(
                                        row.id,
                                      );
                                      final highlighted =
                                          selected?.id == row.id;
                                      final dimmed = !running && !_showClosed;
                                      final elapsed = _durationLabel(
                                        row.durationAt(now),
                                      );
                                      final downloaded = _traffic(
                                        row.downloadBytes,
                                      );
                                      final uploaded = _traffic(
                                        row.uploadBytes,
                                      );
                                      final downRate =
                                          '${_traffic(row.downloadRate)}/s';
                                      final upRate =
                                          '${_traffic(row.uploadRate)}/s';
                                      final button = running
                                          ? _disconnectButton(row)
                                          : null;
                                      final action = dimmed
                                          ? Text(
                                              '已关闭',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: colors.muted,
                                                fontSize: 11,
                                              ),
                                            )
                                          : button;
                                      return Semantics(
                                        key: ValueKey(row.id),
                                        selected: highlighted,
                                        child: Ink(
                                          decoration: BoxDecoration(
                                            color: highlighted
                                                ? colors.accentSoft
                                                : null,
                                            border: Border(
                                              bottom: BorderSide(
                                                color: colors.border,
                                              ),
                                              left: BorderSide(
                                                width: 2,
                                                color: highlighted
                                                    ? scheme.primary
                                                    : Colors.transparent,
                                              ),
                                            ),
                                          ),
                                          child: InkWell(
                                            onTap: () => _select(row),
                                            child: table
                                                ? _ConnectionColumns(
                                                    target: _ConnectionCell(
                                                      row.host,
                                                      row.destination,
                                                      strong: true,
                                                    ),
                                                    process: _ConnectionCell(
                                                      row.process ?? '未知进程',
                                                      '${row.protocol} · ${row.inbound}',
                                                    ),
                                                    outbound: _ConnectionCell(
                                                      row.outbound,
                                                      row.rule,
                                                      accent: scheme.primary,
                                                    ),
                                                    downRate: _showClosed
                                                        ? null
                                                        : _TrafficText(
                                                            running
                                                                ? downRate
                                                                : '—',
                                                            color: colors.down,
                                                          ),
                                                    upRate: _showClosed
                                                        ? null
                                                        : _TrafficText(
                                                            running
                                                                ? upRate
                                                                : '—',
                                                            color: colors.up,
                                                          ),
                                                    downTotal: _TrafficText(
                                                      downloaded,
                                                    ),
                                                    upTotal: _TrafficText(
                                                      uploaded,
                                                    ),
                                                    time: _TrafficText(
                                                      elapsed,
                                                      color: colors.muted,
                                                    ),
                                                    started: showStarted
                                                        ? _TrafficText(
                                                            row.startedAt
                                                                .toIso8601String()
                                                                .substring(
                                                                  11,
                                                                  19,
                                                                ),
                                                            color: colors.muted,
                                                          )
                                                        : null,
                                                    action: action,
                                                  )
                                                : Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          left: 11,
                                                          right: 4,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        Expanded(
                                                          child: Column(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .center,
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .stretch,
                                                            children: [
                                                              Row(
                                                                children: [
                                                                  Expanded(
                                                                    child: Text(
                                                                      row.host,
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                      style: const TextStyle(
                                                                        fontWeight:
                                                                            FontWeight.w700,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 6,
                                                                  ),
                                                                  DiagnosticBadge(
                                                                    row.outbound,
                                                                    color: scheme
                                                                        .primary,
                                                                  ),
                                                                ],
                                                              ),
                                                              const SizedBox(
                                                                height: 4,
                                                              ),
                                                              Row(
                                                                children: [
                                                                  Expanded(
                                                                    child: Text(
                                                                      row.rule,
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                      style: TextStyle(
                                                                        color: colors
                                                                            .muted,
                                                                        fontSize:
                                                                            11,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 4,
                                                                  ),
                                                                  _TrafficText(
                                                                    elapsed,
                                                                    color: colors
                                                                        .muted,
                                                                    accessibleLabel:
                                                                        '持续时间 $elapsed',
                                                                  ),
                                                                ],
                                                              ),
                                                              const SizedBox(
                                                                height: 3,
                                                              ),
                                                              Row(
                                                                children: [
                                                                  Expanded(
                                                                    child: _TrafficText(
                                                                      running
                                                                          ? '↓ $downRate'
                                                                          : '↓ $downloaded',
                                                                      total:
                                                                          running
                                                                          ? downloaded
                                                                          : null,
                                                                      color: colors
                                                                          .down,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 6,
                                                                  ),
                                                                  Expanded(
                                                                    child: _TrafficText(
                                                                      running
                                                                          ? '↑ $upRate'
                                                                          : '↑ $uploaded',
                                                                      total:
                                                                          running
                                                                          ? uploaded
                                                                          : null,
                                                                      color:
                                                                          colors
                                                                              .up,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                        if (action != null)
                                                          SizedBox(
                                                            width: 46,
                                                            child: action,
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: narrowDetail,
              child: ExcludeFocus(
                excluding: narrowDetail,
                child: Row(
                  children: [
                    Expanded(child: list),
                    if (split && detail != null) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(width: detailWidth, child: detail),
                    ],
                  ],
                ),
              ),
            ),
            if (narrowDetail) detail!,
          ],
        );
      },
    );
  }
}

class _ConnectionColumns extends StatelessWidget {
  const _ConnectionColumns({
    required this.target,
    required this.process,
    required this.outbound,
    required this.downRate,
    required this.upRate,
    required this.downTotal,
    required this.upTotal,
    required this.time,
    required this.started,
    required this.action,
  });

  final Widget target;
  final Widget process;
  final Widget outbound;
  final Widget? downRate;
  final Widget? upRate;
  final Widget downTotal;
  final Widget upTotal;
  final Widget time;
  final Widget? started;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12, right: 6),
    child: Row(
      children: [
        Expanded(flex: 26, child: target),
        const SizedBox(width: 8),
        Expanded(flex: 19, child: process),
        const SizedBox(width: 8),
        Expanded(flex: 23, child: outbound),
        if (downRate case final cell?) ...[
          SizedBox(width: 67, child: cell),
          const SizedBox(width: 6),
        ],
        if (upRate case final cell?) ...[
          SizedBox(width: 67, child: cell),
          const SizedBox(width: 9),
        ],
        SizedBox(width: 67, child: downTotal),
        const SizedBox(width: 6),
        SizedBox(width: 67, child: upTotal),
        const SizedBox(width: 8),
        SizedBox(width: 64, child: time),
        if (started case final cell?) ...[
          const SizedBox(width: 8),
          SizedBox(width: 72, child: cell),
        ],
        const SizedBox(width: 4),
        SizedBox(width: 44, child: action),
      ],
    ),
  );
}

class _TrafficText extends StatelessWidget {
  const _TrafficText(this.text, {this.color, this.total, this.accessibleLabel});

  final String text;
  final Color? color;
  final String? total;
  final String? accessibleLabel;

  @override
  Widget build(BuildContext context) {
    final muted = NexColors.of(context).muted;
    const numbers = [FontFeature.tabularFigures()];
    final value = Text(
      text,
      semanticsLabel: accessibleLabel,
      textAlign: TextAlign.end,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 12, fontFeatures: numbers),
    );
    if (total == null) return value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        value,
        const SizedBox(height: 3),
        Text(
          '累计 $total',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: muted, fontSize: 11, fontFeatures: numbers),
        ),
      ],
    );
  }
}

enum _ConnectionSort {
  started,
  duration,
  host,
  process,
  outbound,
  downloadRate,
  uploadRate,
  downloadTotal,
  uploadTotal;

  bool get alphabetic => this == host || this == process || this == outbound;
  bool get isRate => this == downloadRate || this == uploadRate;

  String get label => switch (this) {
    host => '目标',
    process => '应用',
    outbound => '出站',
    downloadRate => '下载速率',
    uploadRate => '上传速率',
    downloadTotal => '累计下载',
    uploadTotal => '累计上传',
    started => '开始时间',
    duration => '持续时间',
  };

  int compare(
    DiagnosticConnection a,
    DiagnosticConnection b, {
    required DateTime now,
  }) => switch (this) {
    host => a.host.toLowerCase().compareTo(b.host.toLowerCase()),
    process => (a.process ?? '').toLowerCase().compareTo(
      (b.process ?? '').toLowerCase(),
    ),
    outbound => a.outbound.toLowerCase().compareTo(b.outbound.toLowerCase()),
    downloadRate => a.downloadRate.compareTo(b.downloadRate),
    uploadRate => a.uploadRate.compareTo(b.uploadRate),
    downloadTotal => a.downloadBytes.compareTo(b.downloadBytes),
    uploadTotal => a.uploadBytes.compareTo(b.uploadBytes),
    started => a.startedAt.compareTo(b.startedAt),
    duration => a.durationAt(now).compareTo(b.durationAt(now)),
  };
}

class _ConnectionFacet extends StatelessWidget {
  const _ConnectionFacet({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.inHeader,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final bool inHeader;

  @override
  Widget build(BuildContext context) {
    if (inHeader) {
      final color = value == null
          ? NexColors.of(context).muted
          : Theme.of(context).colorScheme.primary;
      return PopupMenuButton<({String? filter})>(
        tooltip: value == null ? '筛选$label' : '筛选$label：$value',
        initialValue: (filter: value),
        position: PopupMenuPosition.under,
        onSelected: (selection) => onChanged(selection.filter),
        icon: Icon(
          value == null ? Icons.filter_alt_outlined : Icons.filter_alt,
          size: 16,
          color: color,
        ),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: const Size(28, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
            value: (filter: null),
            checked: value == null,
            child: Text('全部$label'),
          ),
          for (final option in options)
            CheckedPopupMenuItem(
              value: (filter: option),
              checked: value == option,
              child: Text(option),
            ),
        ],
      );
    }
    return DropdownButton<String>(
      value: value,
      hint: Text('全部$label'),
      style: TextStyle(
        color: value == null
            ? NexColors.of(context).muted
            : Theme.of(context).colorScheme.primary,
        fontSize: 13,
      ),
      items: [
        DropdownMenuItem(value: null, child: Text('全部$label')),
        for (final option in options)
          DropdownMenuItem(value: option, child: Text('$label：$option')),
      ],
      onChanged: onChanged,
    );
  }
}

class _ConnectionCell extends StatelessWidget {
  const _ConnectionCell(
    this.title,
    this.subtitle, {
    this.accent,
    this.strong = false,
  });

  final String title;
  final String subtitle;
  final Color? accent;
  final bool strong;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: accent,
          fontSize: 13,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: NexColors.of(context).muted, fontSize: 11),
      ),
    ],
  );
}

class _ConnectionDetails extends StatelessWidget {
  const _ConnectionDetails({
    super.key,
    required this.connection,
    required this.now,
    required this.active,
    required this.onBack,
    required this.onSearchLogs,
    required this.onClose,
    required this.fullPage,
  });

  final DiagnosticConnection connection;
  final DateTime now;
  final bool active;
  final VoidCallback onBack;
  final VoidCallback onSearchLogs;
  final VoidCallback onClose;
  final bool fullPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NexColors.of(context);
    final secondary = TextStyle(color: colors.muted, fontSize: 12);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                if (fullPage)
                  IconButton(
                    onPressed: onBack,
                    tooltip: '返回连接列表',
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(child: Text('连接详情', style: secondary)),
                if (!fullPage)
                  IconButton(
                    onPressed: onBack,
                    tooltip: '收起连接详情',
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
              children: [
                SelectableText(
                  connection.host,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DiagnosticBadge(
                      active ? '进行中' : '已关闭',
                      color: active ? colors.good : colors.muted,
                    ),
                    Text(
                      [?connection.process, connection.protocol].join(' · '),
                      style: secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),
                Text('命中规则', style: secondary),
                const SizedBox(height: 4),
                SelectableText(
                  connection.rule,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                Text('出站路径', style: secondary),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DiagnosticBadge(connection.inbound, color: colors.conn),
                    for (final hop in connection.chain) ...[
                      Icon(Icons.arrow_forward, size: 13, color: colors.muted),
                      DiagnosticBadge(hop, color: theme.colorScheme.primary),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                for (final (label, value) in [
                  ('来源', connection.source),
                  ('目标', connection.destination),
                  (
                    '开始时间',
                    connection.startedAt.toIso8601String().substring(11, 19),
                  ),
                  ('持续时间', _durationLabel(connection.durationAt(now))),
                  ('累计下载', _traffic(connection.downloadBytes)),
                  ('累计上传', _traffic(connection.uploadBytes)),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 66,
                          child: Text(label, style: secondary),
                        ),
                        Expanded(
                          child: SelectableText(
                            value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onSearchLogs,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('按域名搜日志'),
                ),
                if (active)
                  TextButton(
                    onPressed: onClose,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('断开此连接'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _durationLabel(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  final minutes = seconds ~/ 60;
  final hours = minutes ~/ 60;
  if (hours >= 24) return '${hours ~/ 24}天 ${hours % 24}小时';
  if (hours > 0) return '$hours小时 ${minutes % 60}分';
  if (minutes > 0) return '$minutes分 ${seconds % 60}秒';
  return '$seconds秒';
}

String _traffic(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KiB';
  return '$bytes B';
}
