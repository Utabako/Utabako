import 'package:flutter/material.dart';

import '../../core/service/vpn_service.dart';
import '../theme/app_theme.dart';

/// Renders a URL-test result per the kernel contract: `null` = never probed ("未测"),
/// `success == false` = failed ("失败"), otherwise the delay (0 ms and 65535 ms are valid successes).
/// While [testing], only progress is visible; the stored result is not changed.
class LatencyLabel extends StatelessWidget {
  final UrlTestResult? result;
  final bool testing;
  final double fontSize;

  const LatencyLabel({
    super.key,
    required this.result,
    this.testing = false,
    this.fontSize = 12,
  });

  /// Delays below this are shown as good, others as slow.
  static const goodThresholdMillis = 200;

  @override
  Widget build(BuildContext context) {
    final nex = NexColors.of(context);
    if (testing) {
      return SizedBox(
        width: fontSize - 2,
        height: fontSize - 2,
        child: const CircularProgressIndicator(
          strokeWidth: 1.6,
          semanticsLabel: '正在测速',
        ),
      );
    }
    final r = result;
    final (String text, Color color, FontWeight weight) = switch (r) {
      null => ('未测', nex.faint, FontWeight.w500),
      UrlTestResult(success: false) => ('失败', nex.bad, FontWeight.w600),
      UrlTestResult(:final delayMillis) => (
        '$delayMillis ms',
        delayMillis < goodThresholdMillis ? nex.good : nex.warn,
        FontWeight.w600,
      ),
    };
    Widget label = Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: weight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (r != null && !r.success && r.error.isNotEmpty) {
      label = Tooltip(message: r.error, child: label);
    }
    return label;
  }
}
