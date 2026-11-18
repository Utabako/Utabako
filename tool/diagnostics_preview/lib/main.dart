import 'dart:async';

import 'package:flutter/material.dart';
import 'package:utabako/ui/diagnostics/connections_panel.dart';
import 'package:utabako/ui/diagnostics/diagnostic_logs_panel.dart';
import 'package:utabako/ui/theme/app_theme.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'Utabako · 诊断预览',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const _Preview(),
    ),
  );
}

const _connections = [
  (
    'api.example.net',
    '203.0.113.42:443',
    'Firefox',
    'domain_suffix: example.net',
    '日本 01',
    ['手动选择', '日本 01'],
    'TCP',
    'tun-in',
    420,
    32,
  ),
  (
    'updates.example.org',
    '198.51.100.71:443',
    '系统更新',
    'rule_set: domestic',
    '直连',
    ['直连'],
    'TCP',
    'tun-in',
    180,
    12,
  ),
  (
    '10.42.0.8',
    '10.42.0.8:443',
    'Firefox',
    'ip_cidr: 10.42.0.0/16',
    'ZeroTier',
    ['ZeroTier'],
    'TCP',
    'tun-in',
    95,
    5,
  ),
  (
    'media.example.com',
    '192.0.2.61:443',
    'Firefox',
    'rule_set: streaming',
    '新加坡 02',
    ['流媒体', '新加坡 02'],
    'UDP',
    'tun-in',
    3241,
    47,
  ),
  (
    'git.example.org',
    '198.51.100.22:443',
    'Git',
    'domain: git.example.org',
    '香港 03',
    ['开发服务', '香港 03'],
    'TCP',
    'tun-in',
    45,
    9,
  ),
  (
    'cdn.example.net',
    '203.0.113.38:443',
    'Chromium',
    'domain_suffix: example.net',
    '日本 01',
    ['手动选择', '日本 01'],
    'UDP',
    'tun-in',
    762,
    68,
  ),
  (
    'files.home.arpa',
    '10.42.0.12:445',
    '文件管理器',
    'ip_cidr: 10.42.0.0/16',
    'ZeroTier',
    ['ZeroTier'],
    'TCP',
    'tun-in',
    572,
    224,
  ),
  (
    'chat.example.com',
    '192.0.2.48:443',
    '聊天客户端',
    'rule_set: messaging',
    '新加坡 02',
    ['通讯', '新加坡 02'],
    'TCP',
    'tun-in',
    11,
    4,
  ),
  (
    'registry.example.org',
    '198.51.100.12:443',
    'Podman',
    'domain: registry.example.org',
    '香港 03',
    ['开发服务', '香港 03'],
    'TCP',
    'tun-in',
    1024,
    17,
  ),
  (
    'time.example.net',
    '203.0.113.5:123',
    null,
    'port: 123',
    '直连',
    ['直连'],
    'UDP',
    'tun-in',
    0,
    0,
  ),
  (
    'docs.example.com',
    '192.0.2.8:443',
    'Chromium',
    'final',
    '日本 01',
    ['手动选择', '日本 01'],
    'TCP',
    'mixed-in',
    271,
    15,
  ),
];

const _messages = [
  (DiagnosticLogLevel.info, 'tun/inbound', 'tun-in 就绪，IPv4 与 IPv6 路由已加载'),
  (DiagnosticLogLevel.info, 'zerotier', '对端 10.42.0.8 已连通，使用直连路径'),
  (DiagnosticLogLevel.info, 'dns', 'api.example.net A → 203.0.113.42（18 ms）'),
  (
    DiagnosticLogLevel.info,
    'router',
    'api.example.net:443 命中 domain_suffix: example.net → 手动选择 → 日本 01',
  ),
  (
    DiagnosticLogLevel.info,
    'router',
    'updates.example.org:443 命中 rule_set: domestic → 直连',
  ),
  (
    DiagnosticLogLevel.error,
    'outbound',
    '日本 01：连接 api.example.net:443 超时（5 s）',
  ),
  (DiagnosticLogLevel.warn, 'dns', 'updates.example.org 查询超时，切换备用 DNS'),
  (
    DiagnosticLogLevel.info,
    'dns',
    'updates.example.org A → 198.51.100.71（42 ms）',
  ),
  (
    DiagnosticLogLevel.info,
    'router',
    'files.home.arpa:445 命中 ip_cidr: 10.42.0.0/16 → ZeroTier',
  ),
  (
    DiagnosticLogLevel.info,
    'outbound',
    '新加坡 02：QUIC 会话已建立（media.example.com:443）',
  ),
  (
    DiagnosticLogLevel.info,
    'outbound',
    '日本 01：已建立 api.example.net:443 连接（TLS，126 ms）',
  ),
  (
    DiagnosticLogLevel.warn,
    'outbound',
    '香港 03：registry.example.org:443 握手耗时 1.4 s',
  ),
  (
    DiagnosticLogLevel.info,
    'tun/inbound',
    'status.example.com:443 已关闭，下载 16 KiB',
  ),
  (DiagnosticLogLevel.info, 'dns', 'cdn.example.net 命中 DNS 缓存'),
  (
    DiagnosticLogLevel.info,
    'router',
    'cdn.example.net:443 命中 domain_suffix: example.net → 手动选择 → 日本 01',
  ),
];

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final _query = TextEditingController();
  final _active = <DiagnosticConnection>[];
  final _closed = <DiagnosticConnection>[];
  late List<DiagnosticLog> _logs;
  late final Timer _timer;
  int _page = 0;
  int _tick = 0;
  String? _connectionQuery;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    for (final (i, sample) in _connections.indexed) {
      final (
        host,
        destination,
        process,
        rule,
        outbound,
        chain,
        protocol,
        inbound,
        down,
        up,
      ) = sample;
      _active.add(
        DiagnosticConnection(
          id: 'sample-$i',
          host: host,
          destination: destination,
          source: '172.19.0.2:${51020 + i}',
          process: process,
          rule: rule,
          outbound: outbound,
          chain: chain,
          protocol: protocol,
          inbound: inbound,
          startedAt: now.subtract(Duration(seconds: 24 + i * 19)),
          uploadRate: up * 1024,
          downloadRate: down * 1024,
          uploadBytes: up * 1024 * 12,
          downloadBytes: down * 1024 * 16,
        ),
      );
    }
    for (final (i, (host, destination, process, rule, outbound)) in [
      (
        'mail.example.org',
        '192.0.2.41:993',
        '邮件',
        'rule_set: messaging',
        '新加坡 02',
      ),
      ('time.example.org', '198.51.100.55:123', null, 'port: 123', '直连'),
      (
        'calendar.example.net',
        '203.0.113.63:443',
        '日历',
        'domain_suffix: example.net',
        '日本 01',
      ),
      (
        'git.internal',
        '10.42.0.21:22',
        'Git',
        'ip_cidr: 10.42.0.0/16',
        'ZeroTier',
      ),
      ('metrics.example.com', '192.0.2.73:443', null, 'final', '直连'),
      (
        'images.example.net',
        '203.0.113.82:443',
        'Firefox',
        'domain_suffix: example.net',
        '日本 01',
      ),
    ].indexed) {
      _active.add(
        DiagnosticConnection(
          id: 'extra-$i',
          host: host,
          destination: destination,
          source: '172.19.0.2:${51120 + i}',
          process: process,
          rule: rule,
          outbound: outbound,
          chain: [outbound],
          protocol: i == 1 ? 'UDP' : 'TCP',
          inbound: 'tun-in',
          startedAt: now.subtract(Duration(seconds: 240 + i * 15)),
          uploadRate: (i + 1) * 1024,
          downloadRate: (i + 2) * 14 * 1024,
          uploadBytes: (i + 1) * 61 * 1024,
          downloadBytes: (i + 2) * 1024 * 1024,
        ),
      );
    }
    _logs = [
      for (final (i, (level, source, message)) in _messages.indexed)
        DiagnosticLog(
          now.subtract(Duration(seconds: (_messages.length - i) * 2)),
          level,
          source,
          message,
        ),
    ];
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _advance());
  }

  void _advance() {
    setState(() {
      final (level, source, message) =
          _messages[2 + _tick % (_messages.length - 2)];
      _logs = [
        ..._logs.skip(_logs.length >= 200 ? 1 : 0),
        DiagnosticLog(DateTime.now(), level, source, message),
      ];
      for (var index = 0; index < _active.length; index++) {
        final row = _active[index];
        final delta = index == 0 ? (_tick.isEven ? 1 : -1) : 0;
        final download = (row.downloadRate + delta * 24 * 1024).clamp(
          0,
          1 << 30,
        );
        final upload = (row.uploadRate + delta * 3 * 1024).clamp(0, 1 << 30);
        _active[index] = row.copyWith(
          uploadRate: upload,
          downloadRate: download,
          uploadBytes: row.uploadBytes + upload * 2,
          downloadBytes: row.downloadBytes + download * 2,
        );
      }
      _active.add(
        DiagnosticConnection(
          id: 'poll-$_tick',
          host: _tick.isEven ? 'status.example.com' : 'edge.example.net',
          destination: '192.0.2.12:443',
          source: '172.19.0.2:${52000 + _tick}',
          rule: _tick.isEven ? '默认' : 'domain_suffix: example.net',
          outbound: _tick.isEven ? '直连' : '日本 01',
          chain: _tick.isEven ? const ['直连'] : const ['手动选择', '日本 01'],
          protocol: 'TCP',
          inbound: 'tun-in',
          startedAt: DateTime.now(),
          uploadRate: 1024,
          uploadBytes: 1152,
          downloadBytes: 16 * 1024,
          downloadRate: 8 * 1024,
        ),
      );
      if (_tick >= 4) _moveToClosed('poll-${_tick - 4}');
      _tick++;
    });
  }

  void _moveToClosed(String id) {
    final i = _active.indexWhere((item) => item.id == id);
    if (i < 0) return;
    _closed.insert(0, _active.removeAt(i).copyWith(closedAt: DateTime.now()));
    if (_closed.length > 24) _closed.removeLast();
  }

  void _navigate(int index) {
    setState(() {
      _page = index;
      _connectionQuery = null;
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return LayoutBuilder(
      builder: (context, viewport) {
        final wide = viewport.maxWidth >= 820;
        final panel = IndexedStack(
          index: _page,
          children: [
            ConnectionsPanel(
              active: _active,
              closed: _closed,
              onClose: (id) => setState(() => _moveToClosed(id)),
              onSearchLogs: (host) => setState(() {
                _connectionQuery = host;
                _page = 1;
              }),
            ),
            DiagnosticLogsPanel(
              logs: _logs,
              query: _query,
              connectionQuery: _connectionQuery,
              onReturnToConnection: _connectionQuery == null
                  ? null
                  : () => _navigate(0),
            ),
          ],
        );
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                if (wide) ...[
                  Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: .5),
                    width: 132,
                    padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: colors.accentSoft,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.graphic_eq,
                                size: 19,
                                color: colors.down,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Utabako',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        Padding(
                          padding: const EdgeInsets.only(left: 10, bottom: 8),
                          child: Text(
                            '诊断工作台',
                            style: TextStyle(color: colors.muted, fontSize: 11),
                          ),
                        ),
                        for (final (index, icon, label) in [
                          (0, Icons.swap_horiz, '连接'),
                          (1, Icons.article_outlined, '日志'),
                        ])
                          ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            dense: true,
                            leading: Icon(icon, size: 18),
                            minLeadingWidth: 18,
                            title: Text(label),
                            selected: _page == index,
                            selectedTileColor: colors.accentSoft,
                            onTap: () => _navigate(index),
                          ),
                        const Spacer(),
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
                          child: Text(
                            '样例流量',
                            style: TextStyle(color: colors.muted, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: panel),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  height: 58,
                  selectedIndex: _page,
                  onDestinationSelected: _navigate,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.swap_horiz),
                      label: '连接',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.article_outlined),
                      label: '日志',
                    ),
                  ],
                ),
        );
      },
    );
  }
}
