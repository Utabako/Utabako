import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';
import '../widgets/zerotier_status.dart';

class ZeroTierPage extends StatefulWidget {
  const ZeroTierPage({super.key});

  @override
  State<ZeroTierPage> createState() => _ZeroTierPageState();
}

class _ZeroTierPageState extends State<ZeroTierPage> {
  @override
  void initState() {
    super.initState();
    context.read<VpnService>().refreshZeroTierStatus();
  }

  @override
  Widget build(BuildContext context) {
    final (endpoints, error) = context.select(
      (VpnService vpn) => (vpn.zeroTierEndpoints, vpn.zeroTierError),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('ZeroTier')),
      body: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(error, textAlign: TextAlign.center),
              ),
            )
          : endpoints.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hub_outlined, size: 48),
                  SizedBox(height: 12),
                  Text('ZeroTier 未连接'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final endpoint in endpoints) ...[
                  _EndpointCard(endpoint: endpoint),
                  const SizedBox(height: 12),
                  _RoutesCard(endpoint: endpoint),
                  const SizedBox(height: 12),
                  _PeersCard(endpoint: endpoint),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  final ZeroTierEndpointStatus endpoint;
  const _EndpointCard({required this.endpoint});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  endpoint.tag,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ZeroTierStatusBadge(endpoint: endpoint),
            ],
          ),
          if (endpoint.requiresAuthorization ||
              endpoint.requiresAuthentication) ...[
            const SizedBox(height: 12),
            Text(
              endpoint.requiresAuthorization
                  ? '请在 ZeroTier 控制器中授权下方节点，授权后会自动连接。'
                  : '此网络需要身份认证。请完成控制器要求的认证，完成后会自动连接。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 14),
          _InfoRow('网络 ID', endpoint.networkId, mono: true, copyable: true),
          _InfoRow('网络状态', endpoint.networkStatus),
          _InfoRow('节点 ID', endpoint.nodeId, mono: true, copyable: true),
          _InfoRow(
            '地址',
            endpoint.addresses.isEmpty ? '无' : endpoint.addresses.join('\n'),
            mono: true,
          ),
        ],
      ),
    ),
  );
}

class _RoutesCard extends StatelessWidget {
  final ZeroTierEndpointStatus endpoint;
  const _RoutesCard({required this.endpoint});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('路由', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (endpoint.routes.isEmpty)
            const Text('暂无路由')
          else
            for (final route in endpoint.routes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        route.target,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const Icon(Icons.arrow_forward, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      route.via?.isNotEmpty == true ? route.via! : 'ZeroTier',
                    ),
                  ],
                ),
              ),
        ],
      ),
    ),
  );
}

class _PeersCard extends StatelessWidget {
  final ZeroTierEndpointStatus endpoint;
  const _PeersCard({required this.endpoint});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('对等端', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (endpoint.peers.isEmpty)
            const Text('暂无对等端')
          else
            for (final peer in endpoint.peers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peer.address,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${peer.role} · ${peer.pathCount} 条路径',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${peer.latency} ms',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
        ],
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final bool copyable;
  const _InfoRow(
    this.label,
    this.value, {
    this.mono = false,
    this.copyable = false,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
        if (copyable)
          IconButton(
            tooltip: '复制$label',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('已复制$label')));
            },
          ),
      ],
    ),
  );
}
