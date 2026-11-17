import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';
import 'profile_editor_page.dart';

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  final _updatingProfiles = <String>{};

  @override
  void initState() {
    super.initState();
    context.read<VpnService>().loadProfiles();
  }

  Future<void> _addProfile({
    bool importClipboard = false,
    bool importFile = false,
  }) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileEditorPage(
          importClipboard: importClipboard,
          importFile: importFile,
        ),
      ),
    );
    if (result == true && mounted) context.read<VpnService>().loadProfiles();
  }

  Future<void> _showAddOptions() async {
    final option = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('添加配置')),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('订阅链接'),
              onTap: () => Navigator.pop(context, 'url'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('从剪贴板导入'),
              onTap: () => Navigator.pop(context, 'clipboard'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('从文件导入'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || option == null) return;
    await _addProfile(
      importClipboard: option == 'clipboard',
      importFile: option == 'file',
    );
  }

  Future<void> _editProfile(ConfigProfile profile) async {
    final vpn = context.read<VpnService>();
    final config = await vpn.getProfileConfig(profile.id);
    if (!mounted) return;
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileEditorPage(
          profileId: profile.id,
          initialName: profile.name,
          initialConfig: config,
          initialUrl: profile.url,
        ),
      ),
    );
    if (result == true && mounted) vpn.loadProfiles();
  }

  Future<void> _deleteProfile(ConfigProfile profile) async {
    final vpn = context.read<VpnService>();
    if (profile.id == vpn.activeProfileId && vpn.state != VpnState.stopped) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先断开 VPN，再删除当前配置')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除“${profile.name}”？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await vpn.deleteProfile(profile.id);
  }

  Future<void> _updateSubscription(ConfigProfile profile) async {
    final url = profile.url;
    if (url == null) return;
    final vpn = context.read<VpnService>();
    setState(() => _updatingProfiles.add(profile.id));
    try {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final body = await vpn.fetchSubscription(url);
      if (!mounted) return;
      if (body == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('订阅更新失败')));
        return;
      }
      try {
        jsonDecode(body);
      } on FormatException {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('订阅内容不是有效 JSON')));
        return;
      }
      final error = await vpn.checkConfig(body);
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('订阅配置无效: $error')));
        return;
      }
      await vpn.saveProfile(
        id: profile.id,
        name: profile.name,
        config: body,
        url: url,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('订阅已更新')));
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('订阅更新失败：${error.message ?? error.code}')),
      );
    } finally {
      if (mounted) setState(() => _updatingProfiles.remove(profile.id));
    }
  }

  Future<void> _selectProfile(ConfigProfile profile) async {
    final vpn = context.read<VpnService>();
    if (profile.id == vpn.activeProfileId) return;
    final reconnect = vpn.state == VpnState.started;
    if (vpn.state == VpnState.starting || vpn.state == VpnState.stopping) {
      final message = vpn.state == VpnState.starting
          ? '正在连接，请稍后再切换'
          : '正在断开，请稍后再切换';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (reconnect) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('切换配置'),
          content: const Text('切换配置需要重新连接，当前连接会短暂中断。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('切换并重连'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final terminalState = Completer<VpnState>();
      void listener() {
        final state = vpn.state;
        if (state != VpnState.stopping && !terminalState.isCompleted) {
          terminalState.complete(state);
        }
      }

      vpn.addListener(listener);
      late final VpnState stopState;
      try {
        await vpn.stop();
        stopState = vpn.state == VpnState.stopping
            ? await terminalState.future
            : vpn.state;
      } finally {
        vpn.removeListener(listener);
      }
      if (!mounted) return;
      if (stopState != VpnState.stopped) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('断开 VPN 失败，配置未切换')));
        return;
      }
    }

    final error = await vpn.setActiveProfile(profile.id);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    if (reconnect) await vpn.start();
  }

  @override
  Widget build(BuildContext context) {
    final (profiles, activeProfileId) = context.select(
      (VpnService vpn) => (vpn.profiles, vpn.activeProfileId),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('配置')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddOptions,
        icon: const Icon(Icons.add),
        label: const Text('添加配置'),
      ),
      body: profiles.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 56,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  const Text('暂无配置'),
                  const SizedBox(height: 8),
                  const Text('添加订阅或导入 sing-box 配置'),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              itemCount: profiles.length,
              itemBuilder: (context, index) {
                final profile = profiles[index];
                final active = profile.id == activeProfileId;
                final updating = _updatingProfiles.contains(profile.id);
                final host =
                    Uri.tryParse(profile.url ?? '')?.host ?? profile.url ?? '';
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: active
                        ? BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.5,
                          )
                        : BorderSide.none,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                profile.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (active)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '使用中',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${profile.isSubscription ? '订阅 · $host' : '本地配置'}${profile.updatedAt == null ? '' : ' · ${_formatTime(profile.updatedAt!)}'}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          children: [
                            if (!active)
                              TextButton(
                                onPressed: updating
                                    ? null
                                    : () => _selectProfile(profile),
                                child: const Text('使用'),
                              ),
                            if (profile.isSubscription)
                              TextButton.icon(
                                onPressed: updating
                                    ? null
                                    : () => _updateSubscription(profile),
                                icon: updating
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.refresh, size: 18),
                                label: Text(updating ? '更新中' : '更新'),
                              ),
                            TextButton.icon(
                              onPressed: updating
                                  ? null
                                  : () => _editProfile(profile),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              label: const Text('编辑'),
                            ),
                            TextButton.icon(
                              onPressed: updating
                                  ? null
                                  : () => _deleteProfile(profile),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const Text('删除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _formatTime(int millis) {
    final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    final time =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '今天 $time';
    }
    return '${date.month}月${date.day}日 $time';
  }
}
