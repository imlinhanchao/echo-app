import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'echo_ambient.dart';
import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// Echo（回声）特色启动/加载页（极简书房 Editorial Minimalism）：
/// 温润暖墨黑底色 + 细腻香槟金三重扩散声波涟漪 + 律动 5 柱声纹徽章 + 精致品牌字标。
class EchoSplashScreen extends StatefulWidget {
  const EchoSplashScreen({
    super.key,
    this.statusText = '正在唤醒你的书架…',
  });

  final String statusText;

  @override
  State<EchoSplashScreen> createState() => _EchoSplashScreenState();
}

class _EchoSplashScreenState extends State<EchoSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      _controller.stop();
      _controller.value = 0.35;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      key: const Key('echo_splash_screen'),
      backgroundColor: tokens.surfaceBase,
      body: EchoAmbientBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 5),
              SizedBox(
                width: 240,
                height: 240,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final t = _controller.value;
                    final breathe = 1.0 + 0.02 * math.sin(t * 2 * math.pi);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size(240, 240),
                          painter: _EchoRipplePainter(
                            progress: t,
                            primary: tokens.primary,
                            isDark: isDark,
                          ),
                        ),
                        Transform.scale(
                          scale: breathe,
                          child: _BrandWaveformEmblem(
                            progress: t,
                            tokens: tokens,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: EchoMetrics.space3),

              // 品牌字标：象牙米白与温润香槟金过渡「回 声」
              ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [tokens.textPrimary, tokens.primary]
                      : [tokens.textPrimary, tokens.primary],
                ).createShader(bounds),
                child: Text(
                  '回 声',
                  style: textTheme.displaySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 8,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'ECHO · 听看一体有声书',
                style: textTheme.labelMedium?.copyWith(
                  color: tokens.textSecondary.withValues(alpha: 0.85),
                  letterSpacing: 2.8,
                  fontWeight: FontWeight.w500,
                ),
              ),

              const Spacer(flex: 6),

              Semantics(
                container: true,
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: EchoMetrics.space4),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PulseDots(
                            progress: _controller.value,
                            color: tokens.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            widget.statusText,
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 三重同心声波涟漪：错相扩散、柔和淡出。
class _EchoRipplePainter extends CustomPainter {
  const _EchoRipplePainter({
    required this.progress,
    required this.primary,
    required this.isDark,
  });

  final double progress;
  final Color primary;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    const minRadius = 44.0;

    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(alpha: isDark ? 0.14 : 0.10),
          primary.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius * 0.8));
    canvas.drawCircle(center, maxRadius * 0.8, glowPaint);

    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3.0) % 1.0;
      final eased = Curves.easeOutCubic.transform(phase);
      final radius = minRadius + (maxRadius - minRadius) * eased;
      final opacity = (1.0 - phase) * (isDark ? 0.34 : 0.25);

      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 - 0.7 * phase
        ..color = primary.withValues(alpha: opacity.clamp(0.0, 1.0));
      canvas.drawCircle(center, radius, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_EchoRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.primary != primary ||
      oldDelegate.isDark != isDark;
}

/// 中心沉稳香槟金声纹徽章。
class _BrandWaveformEmblem extends StatelessWidget {
  const _BrandWaveformEmblem({
    required this.progress,
    required this.tokens,
    required this.isDark,
  });

  final double progress;
  final EchoTokens tokens;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.primary, tokens.primaryActive],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.35),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.16),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(42, 36),
          painter: _WaveformBarsPainter(
            progress: progress,
            barColor: tokens.textOnPrimary,
          ),
        ),
      ),
    );
  }
}

class _WaveformBarsPainter extends CustomPainter {
  const _WaveformBarsPainter({
    required this.progress,
    required this.barColor,
  });

  final double progress;
  final Color barColor;

  static const _baseHeights = <double>[0.36, 0.72, 1.0, 0.68, 0.40];
  static const _phaseOffsets = <double>[0.0, 0.22, 0.45, 0.68, 0.90];

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 5;
    const barWidth = 4.2;
    final totalWidth = size.width;
    final gap = (totalWidth - barCount * barWidth) / (barCount - 1);
    final centerY = size.height / 2;

    final paint = Paint()
      ..color = barColor.withValues(alpha: 0.95)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < barCount; i++) {
      final wave =
          0.5 +
          0.5 *
              math.sin((progress * 2 * math.pi * 2) + _phaseOffsets[i] * math.pi);
      final ratio = (_baseHeights[i] * (0.48 + 0.52 * wave)).clamp(0.24, 1.0);
      final h = size.height * ratio;
      final left = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, centerY - h / 2, barWidth, h),
        const Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformBarsPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.barColor != barColor;
}

class _PulseDots extends StatelessWidget {
  const _PulseDots({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final wave =
            0.5 + 0.5 * math.sin((progress * 2 * math.pi * 2) - i * 0.85);
        final scale = 0.72 + 0.42 * wave;
        final alpha = 0.35 + 0.65 * wave;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: alpha),
              ),
            ),
          ),
        );
      }),
    );
  }
}
