import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class ChartPoint {
  final double value;
  final String label;
  const ChartPoint(this.value, this.label);
}

/// Smooth line + gradient fill, used for bodyweight and strength trends.
class TrendLineChart extends StatelessWidget {
  final List<ChartPoint> points;
  final Color color;
  final String Function(double) formatValue;

  /// When set, draws a dashed horizontal goal line.
  final double? goalValue;
  final String? goalLabel;

  const TrendLineChart({
    super.key,
    required this.points,
    required this.color,
    required this.formatValue,
    this.goalValue,
    this.goalLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: 150,
        child: Center(
          child: Text(
            points.isEmpty
                ? 'No data yet.'
                : 'One entry so far — log another to see a trend.',
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );
    }

    final values = points.map((p) => p.value).toList();
    var minV = values.reduce(math.min);
    var maxV = values.reduce(math.max);
    if (goalValue != null) {
      minV = math.min(minV, goalValue!);
      maxV = math.max(maxV, goalValue!);
    }
    // Pad the range so the line doesn't touch the edges.
    final span = (maxV - minV).abs();
    final pad = span == 0 ? math.max(maxV.abs() * 0.05, 1.0) : span * 0.18;
    minV -= pad;
    maxV += pad;

    final first = points.first.value;
    final last = points.last.value;
    final delta = last - first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              formatValue(last),
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w800,
                fontSize: 26,
                height: 1.1,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${delta >= 0 ? '+' : ''}${formatValue(delta)}',
              style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: delta == 0
                    ? AppColors.textSecondary
                    : (delta > 0 ? AppColors.positive : AppColors.accent),
              ),
            ),
            const Spacer(),
            if (goalLabel != null)
              Text(
                goalLabel!,
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 120,
          child: LayoutBuilder(
            builder: (context, constraints) => CustomPaint(
              size: Size(constraints.maxWidth, 120),
              painter: _LinePainter(
                values: values,
                minV: minV,
                maxV: maxV,
                color: color,
                goalValue: goalValue,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(points.first.label, style: _axisStyle),
            if (points.length > 2)
              Text(points[points.length ~/ 2].label, style: _axisStyle),
            Text(points.last.label, style: _axisStyle),
          ],
        ),
      ],
    );
  }

  static const _axisStyle = TextStyle(
    fontFamily: AppTheme.fontFamily,
    fontWeight: FontWeight.w600,
    fontSize: 10.5,
    color: AppColors.textFaint,
  );
}

class _LinePainter extends CustomPainter {
  final List<double> values;
  final double minV;
  final double maxV;
  final Color color;
  final double? goalValue;

  _LinePainter({
    required this.values,
    required this.minV,
    required this.maxV,
    required this.color,
    this.goalValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);
    double yFor(double v) => size.height - ((v - minV) / range) * size.height;
    double xFor(int i) =>
        values.length == 1 ? size.width / 2 : (i / (values.length - 1)) * size.width;

    // Horizontal guide lines.
    final guide = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guide);
    }

    // Goal line.
    if (goalValue != null) {
      final y = yFor(goalValue!);
      final dash = Paint()
        ..color = AppColors.accent.withValues(alpha: 0.45)
        ..strokeWidth = 1.5;
      const dashW = 5.0, gapW = 4.0;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + dashW, size.width), y), dash);
        x += dashW + gapW;
      }
    }

    final path = Path();
    final fill = Path();
    for (var i = 0; i < values.length; i++) {
      final x = xFor(i);
      final y = yFor(values[i]);
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        // Smooth with a horizontal control point between neighbours.
        final prevX = xFor(i - 1);
        final prevY = yFor(values[i - 1]);
        final cx = (prevX + x) / 2;
        path.cubicTo(cx, prevY, cx, y, x, y);
        fill.cubicTo(cx, prevY, cx, y, x, y);
      }
    }
    fill.lineTo(xFor(values.length - 1), size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Emphasise the latest reading.
    final lastX = xFor(values.length - 1);
    final lastY = yFor(values.last);
    canvas.drawCircle(Offset(lastX, lastY), 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(lastX, lastY), 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.values != values || old.color != color || old.goalValue != goalValue;
}

/// Vertical bars with a target line — used for daily protein.
class TargetBarChart extends StatelessWidget {
  final List<ChartPoint> points;
  final double target;
  final Color color;

  const TargetBarChart({
    super.key,
    required this.points,
    required this.target,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const SizedBox(
        height: 110,
        child: Center(child: Text('No data yet.', style: TrendLineChart._axisStyle)),
      );
    }
    final maxV = math.max(
      target * 1.15,
      points.map((p) => p.value).reduce(math.max) * 1.1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 110,
          child: Stack(
            children: [
              // Target line sits behind the bars.
              Positioned(
                left: 0,
                right: 0,
                bottom: (target / maxV) * 110,
                child: Row(
                  children: [
                    Expanded(child: Container(height: 1.5, color: AppColors.accent.withValues(alpha: 0.35))),
                    const SizedBox(width: 6),
                    Text(
                      '${target.round()}g',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(points.length, (i) {
                  final p = points[i];
                  final hit = p.value >= target;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.5),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            height: math.max(4, (p.value / maxV) * 110),
                            decoration: BoxDecoration(
                              color: hit ? color : color.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(points.length, (i) {
            return Expanded(
              child: Text(
                points[i].label,
                textAlign: TextAlign.center,
                style: TrendLineChart._axisStyle,
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// GitHub-style contribution grid showing which days had a session.
class ConsistencyGrid extends StatelessWidget {
  final Set<DateTime> activeDays;
  final int weeks;

  const ConsistencyGrid({super.key, required this.activeDays, this.weeks = 12});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    // Start on the Monday of the earliest week shown.
    final start = todayDate
        .subtract(Duration(days: (weeks - 1) * 7))
        .subtract(Duration(days: (todayDate.weekday - 1) % 7));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 4.0;
            final cell = (constraints.maxWidth - gap * (weeks - 1)) / weeks;
            return Row(
              children: List.generate(weeks, (w) {
                return Padding(
                  padding: EdgeInsets.only(right: w == weeks - 1 ? 0 : gap),
                  child: Column(
                    children: List.generate(7, (d) {
                      final day = start.add(Duration(days: w * 7 + d));
                      final isFuture = day.isAfter(todayDate);
                      final active = activeDays.contains(day);
                      return Padding(
                        padding: EdgeInsets.only(bottom: d == 6 ? 0 : gap),
                        child: Container(
                          width: cell,
                          height: cell,
                          decoration: BoxDecoration(
                            color: isFuture
                                ? Colors.transparent
                                : active
                                    ? AppColors.accent
                                    : AppColors.track,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      );
                    }),
                  ),
                );
              }),
            );
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('$weeks weeks ago', style: TrendLineChart._axisStyle),
            const Spacer(),
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: AppColors.track,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 4),
            Text('rest', style: TrendLineChart._axisStyle),
            const SizedBox(width: 10),
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 4),
            Text('trained', style: TrendLineChart._axisStyle),
          ],
        ),
      ],
    );
  }
}
