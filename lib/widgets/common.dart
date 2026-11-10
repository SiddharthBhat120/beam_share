// Reusable widgets used by several screens.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/theme.dart';

/// Big gradient card used for "Send" and "Receive" on the home screen.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: gradient.colors.first.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: Colors.white, size: 34),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                        const SizedBox(height: 4),
                        Text(subtitle,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14.5)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular progress ring with a gradient stroke.
class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.value, required this.child, this.size = 220, this.colors});

  final double value;
  final Widget child;
  final double size;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.clamp(0, 1)),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        builder: (context, v, _) => CustomPaint(
          painter: _RingPainter(v, track, colors ?? const [BeamColors.indigo, BeamColors.violet]),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.track, this.colors);
  final double value;
  final Color track;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    canvas.drawArc(
        arcRect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..color = track
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke);
    if (value <= 0) return;
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [...colors, colors.first],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(arcRect, -math.pi / 2, math.pi * 2 * value, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.track != track;
}

/// Pulsing circles: "I'm visible, waiting for someone".
class RadarPulse extends StatefulWidget {
  const RadarPulse({super.key, required this.child, this.color = BeamColors.teal, this.size = 240});
  final Widget child;
  final Color color;
  final double size;

  @override
  State<RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<RadarPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => CustomPaint(painter: _RadarPainter(_c.value, widget.color), child: child),
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      canvas.drawCircle(
        c,
        maxR * (0.3 + 0.7 * p),
        Paint()
          ..color = color.withValues(alpha: (1 - p) * 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawCircle(c, maxR * 0.3, Paint()..color = color.withValues(alpha: 0.15));
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t;
}

/// White card with a QR code (white keeps scanners happy in dark mode).
class QrCard extends StatelessWidget {
  const QrCard({super.key, required this.data, this.size = 240});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: QrImageView(
        data: data,
        size: size,
        backgroundColor: Colors.white,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF1B1B3A)),
        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF1B1B3A)),
      ),
    );
  }
}

/// Small labelled number ("38.2 MB/s" / "Speed").
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          child: Column(
            children: [
              Icon(icon, size: 20, color: cs.primary),
              const SizedBox(height: 6),
              FittedBox(
                child: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon for a platform name.
IconData platformIcon(String platform) => switch (platform) {
      'android' => Icons.android_rounded,
      'ios' => Icons.phone_iphone_rounded,
      'windows' => Icons.desktop_windows_rounded,
      _ => Icons.devices_other_rounded,
    };

/// Rounded message strip for errors / hints.
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.error = false, this.onClose});
  final String text;
  final bool error;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = error ? cs.error : cs.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: cs.onSurface))),
          if (onClose != null)
            IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded), iconSize: 18),
        ],
      ),
    );
  }
}
