import 'package:flutter/material.dart';

import '../../core/service/vpn_service.dart';
import '../theme/app_theme.dart';

extension ZeroTierStatusPresentation on ZeroTierEndpointStatus {
  bool get requiresAuthorization => networkStatus == 'ACCESS_DENIED';
  bool get requiresAuthentication => networkStatus == 'AUTHENTICATION_REQUIRED';
  bool get networkReady => online && networkStatus == 'OK';

  String get statusLabel => switch (networkStatus) {
    'ACCESS_DENIED' => '待授权',
    'AUTHENTICATION_REQUIRED' => '需认证',
    'OK' => online ? '在线' : '离线',
    'REQUESTING_CONFIGURATION' => '等待配置',
    '' => online ? '等待配置' : '离线',
    _ => networkStatus,
  };
}

class ZeroTierStatusBadge extends StatelessWidget {
  final ZeroTierEndpointStatus? endpoint;

  const ZeroTierStatusBadge({super.key, required this.endpoint});

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    final ready = endpoint?.networkReady ?? false;
    final needsAuthorization =
        endpoint?.requiresAuthorization == true ||
        endpoint?.requiresAuthentication == true;
    final color = ready
        ? colors.good
        : needsAuthorization
        ? colors.warn
        : colors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ready
            ? colors.goodSoft
            : needsAuthorization
            ? colors.warn.withValues(alpha: .12)
            : colors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        endpoint?.statusLabel ?? '离线',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
