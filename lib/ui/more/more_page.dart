import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';
import '../log/log_page.dart';
import '../settings/per_app_proxy_page.dart';
import '../widgets/zerotier_status.dart';
import 'zerotier_page.dart';
import 'privacy_page.dart';

class MorePage extends StatelessWidget {
  final bool active;
  const MorePage({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    context.select((VpnService vpn) {
      if (!active) return null;
      final endpoint = vpn.zeroTierEndpoints.firstOrNull;
      return (
        online: endpoint?.online ?? false,
        networkStatus: endpoint?.networkStatus,
        address: endpoint?.networkReady == true
            ? endpoint?.addresses.firstOrNull
            : null,
        perAppMode: vpn.perAppProxy.mode,
        perAppCount: vpn.perAppProxy.packages.length,
        theme: vpn.themeMode,
        autostart: vpn.autostart,
        disableIpv6: vpn.disableIpv6,
        version: vpn.coreVersion,
        appVersion: vpn.appVersion,
      );
    });
    final vpn = context.read<VpnService>();
    final endpoint = vpn.zeroTierEndpoints.isEmpty
        ? null
        : vpn.zeroTierEndpoints.first;
    final zeroTierSubtitle = endpoint == null
        ? '未连接'
        : endpoint.requiresAuthorization
        ? '待授权 · 点击查看节点 ID'
        : endpoint.requiresAuthentication
        ? '需认证 · 点击查看网络信息'
        : endpoint.networkReady && endpoint.addresses.isNotEmpty
        ? '在线 · ${endpoint.addresses.first}'
        : endpoint.statusLabel;
    final perApp = vpn.perAppProxy;
    final perAppSubtitle = switch (perApp.mode) {
      'include' => '仅 ${perApp.packages.length} 个应用走代理',
      'exclude' => '${perApp.packages.length} 个应用绕过代理',
      _ => '全部应用走代理',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _Group(
            title: '网络',
            children: [
              _MoreTile(
                icon: Icons.hub_outlined,
                title: 'ZeroTier',
                subtitle: zeroTierSubtitle,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ZeroTierPage()),
                ),
              ),
              _MoreTile(
                icon: Icons.apps_outlined,
                title: '分应用代理',
                subtitle: perAppSubtitle,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PerAppProxyPage()),
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                secondary: const _TileIcon(icon: Icons.block_outlined),
                title: const Text('禁用 IPv6'),
                subtitle: const Text('仅允许 VPN 内的 IPv4 流量，重连后生效'),
                value: vpn.disableIpv6,
                onChanged: (disabled) async {
                  final error = await vpn.setDisableIpv6(disabled);
                  if (!context.mounted || error == null) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error)));
                },
              ),
            ],
          ),
          _Group(
            title: '诊断',
            children: [
              _MoreTile(
                icon: Icons.article_outlined,
                title: '日志',
                subtitle: '查看运行日志并导出',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LogPage()),
                ),
              ),
            ],
          ),
          _Group(
            title: '通用',
            children: [
              _MoreTile(
                icon: Icons.palette_outlined,
                title: '主题模式',
                subtitle: _themeLabel(vpn.themeMode),
                onTap: () =>
                    _showThemeSheet(context, vpn.themeMode, vpn.setThemeMode),
              ),
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                secondary: const _TileIcon(icon: Icons.power_settings_new),
                title: const Text('开机自启'),
                subtitle: const Text('设备重启后自动连接 VPN'),
                value: vpn.autostart,
                onChanged: vpn.setAutostart,
              ),
            ],
          ),
          _Group(
            title: '关于',
            children: [
              _MoreTile(
                icon: Icons.info_outline,
                title: 'Utabako 版本',
                subtitle: vpn.appVersion.isNotEmpty ? vpn.appVersion : '未知',
              ),
              _MoreTile(
                icon: Icons.info_outline,
                title: 'sing-box 版本',
                subtitle: vpn.coreVersion.isNotEmpty ? vpn.coreVersion : '未知',
              ),
              _MoreTile(
                icon: Icons.privacy_tip_outlined,
                title: '隐私说明',
                subtitle: '本地数据、联网与日志',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PrivacyPage()),
                ),
              ),
              _MoreTile(
                icon: Icons.description_outlined,
                title: '开源许可',
                subtitle: 'GPL 与第三方许可',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Utabako',
                  applicationVersion: vpn.appVersion,
                  applicationLegalese:
                      'GPL-3.0-or-later\n非 sing-box 或 ZeroTier 官方应用',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
    _ => '跟随系统',
  };

  static Future<void> _showThemeSheet(
    BuildContext context,
    ThemeMode selected,
    Future<void> Function(ThemeMode) setThemeMode,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('主题模式')),
            for (final entry in const [
              (ThemeMode.system, '跟随系统'),
              (ThemeMode.light, '浅色'),
              (ThemeMode.dark, '深色'),
            ])
              ListTile(
                title: Text(entry.$2),
                trailing: selected == entry.$1
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  setThemeMode(entry.$1);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Group({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  const _MoreTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => ListTile(
    leading: _TileIcon(icon: icon),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _TileIcon extends StatelessWidget {
  final IconData icon;
  const _TileIcon({required this.icon});
  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, size: 19),
  );
}
