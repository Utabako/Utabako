import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A 60-second window. Missing earlier samples remain empty, not zero-filled.
class HistoryChart extends StatelessWidget {
  final List<double> primary;
  final List<double> secondary;
  final Color color;
  final Color? secondaryColor;
  final double ceiling;
  final String Function(double) formatTick;
  final bool connected;
  final bool compact;

  const HistoryChart({
    super.key,
    required this.primary,
    this.secondary = const [],
    required this.color,
    this.secondaryColor,
    required this.ceiling,
    required this.formatTick,
    required this.connected,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = NexColors.of(context);
    return SizedBox(
      height: compact ? 88 : 140,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _HistoryPainter(
                primary: primary,
                secondary: secondary,
                color: color,
                secondaryColor: secondaryColor,
                ceiling: ceiling,
                formatTick: formatTick,
                connected: connected,
                compact: compact,
                gridColor: colors.border,
                labelColor: colors.faint,
                textDirection: Directionality.of(context),
              ),
            ),
          ),
          if (!connected)
            Center(
              child: Text(
                '未连接',
                style: TextStyle(fontSize: 13, color: colors.faint),
              ),
            ),
        ],
      ),
    );
  }
}

double chartCeiling(double value, {bool connections = false}) {
  final steps = connections
      ? const [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
      : const [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0];
  final unit = connections
      ? 1.0
      : value >= 1048576
      ? 1048576.0
      : value >= 1024
      ? 1024.0
      : 1.0;
  final scaled = math.max(value / unit, connections ? 10.0 : 1.0);
  final power = math.pow(10, (math.log(scaled) / math.ln10).floor()).toDouble();
  return steps.firstWhere((step) => step * power >= scaled) * power * unit;
}

class _HistoryPainter extends CustomPainter {
  final List<double> primary;
  final List<double> secondary;
  final Color color;
  final Color? secondaryColor;
  final double ceiling;
  final String Function(double) formatTick;
  final bool connected;
  final bool compact;
  final Color gridColor;
  final Color labelColor;
  final TextDirection textDirection;

  _HistoryPainter({
    required this.primary,
    required this.secondary,
    required this.color,
    required this.secondaryColor,
    required this.ceiling,
    required this.formatTick,
    required this.connected,
    required this.compact,
    required this.gridColor,
    required this.labelColor,
    required this.textDirection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const top = 16.0;
    final bottom = size.height - 1;
    final height = bottom - top;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    void dashed(double y) {
      for (double x = 0; x < size.width; x += 7) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 3, size.width), y),
          grid,
        );
      }
    }

    if (!connected) {
      dashed(bottom);
      return;
    }
    for (final fraction in compact ? const [1.0] : const [1.0, 0.5]) {
      final y = top + height * (1 - fraction);
      dashed(y);
      final text = TextPainter(
        text: TextSpan(
          text: formatTick(ceiling * fraction),
          style: TextStyle(fontSize: 10, color: labelColor),
        ),
        textDirection: textDirection,
      )..layout();
      text.paint(canvas, Offset(0, y - text.height - 2));
    }
    void series(List<double> values, Color seriesColor) {
      if (values.isEmpty) return;
      final samples = values.length > 60
          ? values.sublist(values.length - 60)
          : values;
      final points = [
        for (var i = 0; i < samples.length; i++)
          Offset(
            (60 - samples.length + i) / 59 * size.width,
            bottom - samples[i] / ceiling * height,
          ),
      ];
      final line = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        line.lineTo(point.dx, point.dy);
      }
      final area = Path.from(line)
        ..lineTo(points.last.dx, bottom)
        ..lineTo(points.first.dx, bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              seriesColor.withValues(alpha: 0.26),
              seriesColor.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTRB(0, top, size.width, bottom)),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = seriesColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
      if (points.length == 1) {
        canvas.drawCircle(points.single, 2, Paint()..color = seriesColor);
      }
    }

    series(primary, color);
    if (secondaryColor != null) series(secondary, secondaryColor!);
  }

  @override
  bool shouldRepaint(_HistoryPainter oldDelegate) => true;
}
