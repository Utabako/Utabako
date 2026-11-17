import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';

class PerAppProxyPage extends StatefulWidget {
  const PerAppProxyPage({super.key});
  @override
  State<PerAppProxyPage> createState() => _PerAppProxyPageState();
}

class _PerAppProxyPageState extends State<PerAppProxyPage> {
  List<AppInfo> _apps = [];
  bool _loading = true;
  bool _saving = false;
  bool _searchOpen = false;
  String _search = '';
  String _mode = 'all';
  final Set<String> _selected = {};
  final _searchController = TextEditingController();

  bool get _invalidInclude => _mode == 'include' && _selected.isEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final vpn = context.read<VpnService>();
    final apps = await vpn.getInstalledApps();
    final config = vpn.perAppProxy;
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _mode = config.mode;
      _selected.addAll(config.packages);
      _loading = false;
    });
  }

  List<AppInfo> get _filtered {
    final query = _search.toLowerCase();
    if (query.isEmpty) return _apps;
    return _apps
        .where(
          (app) =>
              app.label.toLowerCase().contains(query) ||
              app.packageName.toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _save() async {
    if (_loading || _saving || _invalidInclude) return;
    setState(() => _saving = true);
    final error = await context.read<VpnService>().savePerAppProxy(
      PerAppProxyConfig(mode: _mode, packages: _selected.toList()),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? '已保存，重启 VPN 生效')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分应用代理'),
        actions: [
          TextButton(
            onPressed: _loading || _saving || _invalidInclude ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('全部')),
                ButtonSegment(value: 'include', label: Text('仅选中')),
                ButtonSegment(value: 'exclude', label: Text('排除选中')),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) =>
                  setState(() => _mode = selection.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                switch (_mode) {
                  'include' => '仅将已选应用加入 VPN',
                  'exclude' => '所选应用不经过 VPN',
                  _ => '所有应用均通过 VPN',
                },
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          ),
          if (_mode != 'all') ...[
            if (_searchOpen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索应用',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _search = value),
                ),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: '搜索应用',
                  onPressed: () => setState(() => _searchOpen = true),
                  icon: const Icon(Icons.search),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(
                children: [
                  Text('已选 ${_selected.length} 个'),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(_selected.clear),
                    child: const Text('清除全部'),
                  ),
                ],
              ),
            ),
            if (_invalidInclude)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '仅选中模式至少需要选择一个应用',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _mode == 'all'
                ? const Center(child: Text('所有应用均通过代理'))
                : _filtered.isEmpty
                ? const Center(child: Text('没有找到应用'))
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final app = _filtered[index];
                      final selected = _selected.contains(app.packageName);
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            app.label.isEmpty
                                ? '?'
                                : app.label.characters.first,
                          ),
                        ),
                        title: Text(app.label),
                        subtitle: Text(
                          app.packageName,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        trailing: Checkbox(
                          value: selected,
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selected.add(app.packageName);
                            } else {
                              _selected.remove(app.packageName);
                            }
                          }),
                        ),
                        onTap: () => setState(() {
                          if (selected) {
                            _selected.remove(app.packageName);
                          } else {
                            _selected.add(app.packageName);
                          }
                        }),
                      );
                    },
                  ),
          ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
