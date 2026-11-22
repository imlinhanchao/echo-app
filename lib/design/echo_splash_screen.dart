import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'echo_ambient.dart';
import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// Echo（回声）特色启动/加载页：
/// 深靛蓝氛围光晕 + 三重扩散声波涟漪（可视化「回声」）+ 呼吸律动 5 柱声纹徽章 + 精致品牌字标。
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
              // 核心视觉：声波涟漪 + 律动声纹徽章
              SizedBox(
                width: 240,
                height: 240,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final t = _controller.value;
                    final breathe = 1.0 + 0.025 * math.sin(t * 2 * math.pi);
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
                            primary: tokens.primary,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: EchoMetrics.space3),

              // 品牌字标：渐变「回 声」
              ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [Colors.white, const Color(0xFFC7D2FE)]
                      : [const Color(0xFF0F172A), tokens.primary],
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

              // 底部状态提示 + 声波脉动点
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

/// 三重同心声波涟漪：错相扩散、柔和淡出，呼应品牌名「回声」。
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

    // 柔和中心光晕
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(alpha: isDark ? 0.24 : 0.16),
          primary.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius * 0.85));
    canvas.drawCircle(center, maxRadius * 0.85, glowPaint);

    // 3 圈错相声波环
    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3.0) % 1.0;
      final eased = Curves.easeOutCubic.transform(phase);
      final radius = minRadius + (maxRadius - minRadius) * eased;
      final opacity = (1.0 - phase) * (isDark ? 0.42 : 0.30);

      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 - 0.8 * phase
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

/// 中心玻璃质感声纹徽章：靛蓝紫渐变圆角矩形 + 5 根错相律动声波柱。
class _BrandWaveformEmblem extends StatelessWidget {
  const _BrandWaveformEmblem({
    required this.progress,
    required this.primary,
    required this.isDark,
  });

  final double progress;
  final Color primary;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary,
            const Color(0xFF8B5CF6),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.28 : 0.45),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: isDark ? 0.45 : 0.32),
            blurRadius: 32,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(44, 38),
          painter: _WaveformBarsPainter(progress: progress),
        ),
      ),
    );
  }
}

class _WaveformBarsPainter extends CustomPainter {
  const _WaveformBarsPainter({required this.progress});

  final double progress;

  static const _baseHeights = <double>[0.36, 0.72, 1.0, 0.68, 0.40];
  static const _phaseOffsets = <double>[0.0, 0.22, 0.45, 0.68, 0.90];

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 5;
    const barWidth = 4.5;
    final totalWidth = size.width;
    final gap = (totalWidth - barCount * barWidth) / (barCount - 1);
    final centerY = size.height / 2;

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.96)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < barCount; i++) {
      final wave = 0.5 +
          0.5 * math.sin((progress * 2 * math.pi * 2) + _phaseOffsets[i] * math.pi);
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
      oldDelegate.progress != progress;
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
        final wave = 0.5 +
            0.5 * math.sin((progress * 2 * math.pi * 2) - i * 0.85);
        final scale = 0.72 + 0.42 * wave;
        final alpha = 0.35 + 0.65 * wave;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 6,
              height: 6,
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
