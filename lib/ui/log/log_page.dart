import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _timer;
  String _logContent = '';
  String _filter = '';
  String _level = '全部';
  bool _searchOpen = false;
  bool _loading = false;
  static const _levels = ['全部', 'INFO', 'WARN', 'ERROR'];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    final log = await context.read<VpnService>().readLog();
    if (!mounted) return;
    if (log != _logContent) {
      setState(() => _logContent = log);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
    _loading = false;
  }

  List<String> get _filteredLines => _logContent.split('\n').where((line) {
    if (_filter.isNotEmpty &&
        !line.toLowerCase().contains(_filter.toLowerCase())) {
      return false;
    }
    if (_level != '全部' &&
        !line.contains(' $_level ') &&
        !line.startsWith(_level)) {
      return false;
    }
    return true;
  }).toList();

  Future<void> _export() async {
    final path = await context.read<VpnService>().exportLog();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path == null ? '日志导出失败' : '已导出: $path')),
    );
  }

  Future<void> _clear() async {
    final vpn = context.read<VpnService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除日志'),
        content: const Text('确定清除所有日志？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await vpn.clearLog();
    if (!mounted) return;
    setState(() => _logContent = '');
  }

  @override
  Widget build(BuildContext context) {
    final lines = _filteredLines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) {
                _filter = '';
                _searchController.clear();
              }
            }),
          ),
          TextButton(onPressed: _export, child: const Text('导出')),
          IconButton(
            tooltip: '清除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索日志',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _filter = value),
              ),
            ),
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              children: [
                for (final level in _levels)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(level),
                      selected: _level == level,
                      onSelected: (_) => setState(() => _level = level),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _logContent.isEmpty
                ? Center(
                    child: Text(
                      '暂无日志',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                    itemCount: lines.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        lines[index],
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: _lineColor(lines[index], Theme.of(context)),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Color _lineColor(String line, ThemeData theme) {
    if (line.contains('ERROR')) return theme.colorScheme.error;
    if (line.contains('WARN')) return Colors.orange;
    if (line.contains('INFO')) return theme.colorScheme.primary;
    return theme.colorScheme.onSurface;
  }
}
