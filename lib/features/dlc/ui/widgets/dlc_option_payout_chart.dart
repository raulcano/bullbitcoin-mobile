import 'dart:math' as math;

import 'package:bb_mobile/features/dlc/domain/dlc_option_payout_simulation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

/// Wallet payout vs oracle BTC/USD: stepped rounded DLC curve and dashed canonical reference.
class DlcOptionPayoutChart extends StatelessWidget {
  const DlcOptionPayoutChart({
    super.key,
    required this.result,
    required this.strikeUsd,
    required this.outcomeUsd,
  });

  final DlcOptionPayoutSimulationResult result;
  final int strikeUsd;
  final int outcomeUsd;

  @override
  Widget build(BuildContext context) {
    final intervals = result.intervals;
    final canon = result.canonicalPoints;
    if (intervals.isEmpty && canon.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No interval data returned for this scenario.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 228,
          width: double.infinity,
          child: CustomPaint(
            painter: _DlcPayoutChartPainter(
              colorScheme: scheme,
              textScaler: MediaQuery.textScalerOf(context),
              intervals: intervals,
              canonicalPoints: canon,
              outcomeBand: result.outcomeInterval,
              strikeUsd: strikeUsd,
              outcomeUsd: outcomeUsd,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            _LegendChip(
              color: scheme.primary,
              label: 'Actual payout',
              dashed: false,
            ),
            _LegendChip(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
              label: 'Canonical payout',
              dashed: true,
            ),
            _LegendChip(
              color: scheme.tertiary,
              label:
                  'Strike (${NumberFormat.decimalPattern().format(strikeUsd)} USD)',
              dashed: false,
              thin: true,
            ),
            _LegendChip(
              color: scheme.secondary,
              label:
                  'Outcome (${NumberFormat.decimalPattern().format(outcomeUsd)} USD)',
              dashed: false,
              thin: true,
            ),
          ],
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.color,
    required this.label,
    this.dashed = false,
    this.thin = false,
  });

  final Color color;
  final String label;
  final bool dashed;
  final bool thin;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: thin ? 1.5 : 2.5,
          child: dashed
              ? CustomPaint(
                  painter: _MiniDashPainter(color: color),
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _MiniDashPainter extends CustomPainter {
  _MiniDashPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.height.clamp(2.0, 3.0)
      ..strokeCap = StrokeCap.round;
    const dash = 5.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + dash, size.width), size.height / 2),
        paint,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _MiniDashPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DlcPayoutChartPainter extends CustomPainter {
  _DlcPayoutChartPainter({
    required this.colorScheme,
    required this.textScaler,
    required this.intervals,
    required this.canonicalPoints,
    required this.outcomeBand,
    required this.strikeUsd,
    required this.outcomeUsd,
  });

  final ColorScheme colorScheme;
  final TextScaler textScaler;
  final List<DlcPayoutInterval> intervals;
  final List<DlcCanonicalPoint> canonicalPoints;
  final DlcOutcomeIntervalBand? outcomeBand;
  final int strikeUsd;
  final int outcomeUsd;

  static const _leftPad = 52.0;
  static const _bottomPad = 28.0;
  static const _topPad = 14.0;
  static const _rightPad = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTRB(
      _leftPad,
      _topPad,
      size.width - _rightPad,
      size.height - _bottomPad,
    );

    final focusedX = dlcPayoutChartFocusedXExtents(
      strikeUsd: strikeUsd,
      outcomeUsd: outcomeUsd,
      outcomeBand: outcomeBand,
      intervals: intervals,
    );
    var xMin = focusedX.min;
    var xMax = focusedX.max;
    if (xMax <= xMin) {
      xMax = xMin + 1;
    }

    final focusedY = dlcPayoutChartYExtentsForX(
      xMin: xMin,
      xMax: xMax,
      intervals: intervals,
      canonicalPoints: canonicalPoints,
    );
    var yMin = focusedY.min;
    var yMax = focusedY.max;
    if (yMax <= yMin) {
      yMax = yMin + 1;
    }
    final yPad = (yMax - yMin) * 0.08 + 1;
    yMin -= yPad;
    yMax += yPad;

    double tx(double x) =>
        chart.left + (x - xMin) / (xMax - xMin) * chart.width;
    double ty(double y) =>
        chart.bottom - (y - yMin) / (yMax - yMin) * chart.height;

    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.35)
      ..strokeWidth = 1;

    canvas.drawRect(
      chart,
      Paint()
        ..color =
            colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
    );

    // Horizontal grid (4 lines)
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      final yVal = yMin + (yMax - yMin) * t;
      final y = ty(yVal);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      _drawAxisLabel(
        canvas,
        _compactSats(yVal),
        Offset(chart.left - 6, y),
        alignRight: true,
      );
    }

    // Outcome interval band
    if (outcomeBand != null && outcomeBand!.end >= outcomeBand!.start) {
      final rawLeft = tx(outcomeBand!.start.toDouble());
      final rawRight = tx(outcomeBand!.end.toDouble());
      final bandLeft = rawLeft.clamp(chart.left, chart.right);
      final bandRight = rawRight.clamp(chart.left, chart.right);
      final bandRect = Rect.fromLTRB(
        math.min(bandLeft, bandRight),
        chart.top,
        math.max(bandLeft, bandRight),
        chart.bottom,
      );
      canvas.drawRect(
        bandRect,
        Paint()..color = colorScheme.primaryContainer.withValues(alpha: 0.28),
      );
    }

    // Vertical guides: strike & outcome
    _drawVGuide(
      canvas,
      chart,
      tx(strikeUsd.toDouble()),
      colorScheme.tertiary,
      'Strike',
    );
    _drawVGuide(
      canvas,
      chart,
      tx(outcomeUsd.toDouble()),
      colorScheme.secondary,
      'Expiry',
    );

    canvas.save();
    canvas.clipRect(chart);

    // Stepped rounded wallet payout
    if (intervals.isNotEmpty) {
      final stepped = Path();
      final first = intervals.first;
      stepped.moveTo(
        tx(first.start.toDouble()),
        ty(first.walletPayout.toDouble()),
      );
      stepped.lineTo(
        tx(first.end.toDouble()),
        ty(first.walletPayout.toDouble()),
      );
      for (var i = 1; i < intervals.length; i++) {
        final prev = intervals[i - 1];
        final cur = intervals[i];
        final junction = tx(prev.end.toDouble());
        stepped.lineTo(junction, ty(cur.walletPayout.toDouble()));
        stepped.lineTo(tx(cur.start.toDouble()), ty(cur.walletPayout.toDouble()));
        stepped.lineTo(tx(cur.end.toDouble()), ty(cur.walletPayout.toDouble()));
      }

      canvas.drawPath(
        stepped,
        Paint()
          ..color = colorScheme.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Canonical dashed
    if (canonicalPoints.length >= 2) {
      final sorted = [...canonicalPoints]..sort((a, b) => a.x.compareTo(b.x));
      for (var i = 0; i < sorted.length - 1; i++) {
        final a = sorted[i];
        final b = sorted[i + 1];
        _paintDashedLine(
          canvas,
          Offset(tx(a.x.toDouble()), ty(a.walletPayout.toDouble())),
          Offset(tx(b.x.toDouble()), ty(b.walletPayout.toDouble())),
          Paint()
            ..color = colorScheme.onSurfaceVariant.withValues(alpha: 0.75)
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round,
          dashLen: 7,
          gapLen: 5,
        );
      }
    }

    canvas.restore();

    canvas.drawRect(
      chart,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colorScheme.outlineVariant.withValues(alpha: 0.55),
    );

    _drawAxisLabel(
      canvas,
      _compactUsd(xMin),
      Offset(chart.left, chart.bottom + 6),
    );
    _drawAxisLabel(
      canvas,
      _compactUsd(xMax),
      Offset(chart.right, chart.bottom + 6),
      alignRight: true,
    );
    _drawAxisLabel(
      canvas,
      'BTC/USD (oracle)',
      Offset(chart.center.dx, chart.bottom + 6),
      alignCenter: true,
    );
  }

  void _drawVGuide(
    Canvas canvas,
    Rect chart,
    double x,
    Color color,
    String tag,
  ) {
    if (x < chart.left || x > chart.right) return;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), paint);

    final tp = TextPainter(
      text: TextSpan(
        text: tag,
        style: TextStyle(
          color: color.withValues(alpha: 0.95),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: chart.width);
    final ox = ((x - tp.width / 2).clamp(
              chart.left,
              math.max(chart.left, chart.right - tp.width),
            ))
        .toDouble();
    tp.paint(canvas, Offset(ox, chart.top - 2));
  }

  void _drawAxisLabel(
    Canvas canvas,
    String text,
    Offset at, {
    bool alignRight = false,
    bool alignCenter = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (alignCenter) dx -= tp.width / 2;
    tp.paint(canvas, Offset(dx, at.dy));
  }

  String _compactUsd(double v) {
    if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
    return v.round().toString();
  }

  String _compactSats(double v) {
    final r = v.round();
    final abs = r.abs();
    final sign = r < 0 ? '-' : '';
    if (abs >= 1000000000) {
      return '$sign${(abs / 1000000000).toStringAsFixed(2)}B';
    }
    if (abs >= 1000000) return '$sign${(abs / 1000000).toStringAsFixed(2)}M';
    if (abs >= 1000) return '$sign${(abs / 1000).toStringAsFixed(1)}k';
    return '$sign$abs';
  }

  void _paintDashedLine(
    Canvas canvas,
    Offset p1,
    Offset p2,
    Paint paint, {
    required double dashLen,
    required double gapLen,
  }) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return;
    final ux = dx / len;
    final uy = dy / len;
    var pos = 0.0;
    var drawDash = true;
    while (pos < len) {
      final seg = drawDash ? dashLen : gapLen;
      final next = math.min(pos + seg, len);
      if (drawDash) {
        final start = Offset(p1.dx + ux * pos, p1.dy + uy * pos);
        final end = Offset(p1.dx + ux * next, p1.dy + uy * next);
        canvas.drawLine(start, end, paint);
      }
      pos = next;
      drawDash = !drawDash;
    }
  }

  @override
  bool shouldRepaint(covariant _DlcPayoutChartPainter oldDelegate) {
    return oldDelegate.intervals != intervals ||
        oldDelegate.canonicalPoints != canonicalPoints ||
        oldDelegate.outcomeBand != outcomeBand ||
        oldDelegate.strikeUsd != strikeUsd ||
        oldDelegate.outcomeUsd != outcomeUsd ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.textScaler != textScaler;
  }

  @override
  bool shouldRebuildSemantics(covariant _DlcPayoutChartPainter oldDelegate) =>
      shouldRepaint(oldDelegate);
}
