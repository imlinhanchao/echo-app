import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Generate high fidelity Echo app icons', () async {
    const size = 1024.0;
    final outDir = Directory(
      '/home/hancel/project/audio_book/echo-app/assets/icon',
    );
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    // 1. 生成完整图标（暖墨黑基底 + 香槟金微光光晕 + 同心声波环与 5 柱音律）
    final fullImage = await _renderIcon(
      size: size,
      includeBackground: true,
      monochrome: false,
    );
    final fullBytes = await fullImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File(
      '${outDir.path}/app_icon.png',
    ).writeAsBytes(fullBytes!.buffer.asUint8List());

    // 2. 生成自适应前景图（透明背景，严格适配 Android Adaptive Icon 安全区）
    final foregroundImage = await _renderIcon(
      size: size,
      includeBackground: false,
      monochrome: false,
    );
    final fgBytes = await foregroundImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File(
      '${outDir.path}/app_icon_foreground.png',
    ).writeAsBytes(fgBytes!.buffer.asUint8List());

    // 3. 生成 Material You 单色图标（纯白前景色，透明底，供 Android 13+ 主题图标使用）
    final monoImage = await _renderIcon(
      size: size,
      includeBackground: false,
      monochrome: true,
    );
    final monoBytes = await monoImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File(
      '${outDir.path}/app_icon_monochrome.png',
    ).writeAsBytes(monoBytes!.buffer.asUint8List());

    // 4. 生成自适应背景图
    final bgImage = await _renderBackgroundOnly(size: size);
    final bgBytes = await bgImage.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${outDir.path}/app_icon_background.png',
    ).writeAsBytes(bgBytes!.buffer.asUint8List());

    // ignore: avoid_print
    print('Icons generated successfully in ${outDir.path}');
  });
}

void _drawWarmObsidianBackground(Canvas canvas, double size) {
  // 暖墨黑斜向渐变基底：契合「极简书房 · 暖墨黑 & 香槟金」主题
  final bgPaint = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(0, 0),
      Offset(size, size),
      const [Color(0xFF1A1816), Color(0xFF111114), Color(0xFF09090B)],
      const [0.0, 0.55, 1.0],
    );
  canvas.drawRect(Rect.fromLTWH(0, 0, size, size), bgPaint);

  // 中心香槟金漫射微光光晕
  final auraCenter = Offset(size * 0.5, size * 0.46);
  final auraRadius = size * 0.44;
  final glowPaint = Paint()
    ..shader = ui.Gradient.radial(
      auraCenter,
      auraRadius,
      const [
        Color(0x24D4AE74),
        Color(0x0CD4AE74),
        Color(0x00000000),
      ],
      const [0.0, 0.52, 1.0],
    );
  canvas.drawCircle(auraCenter, auraRadius, glowPaint);
}

Future<ui.Image> _renderBackgroundOnly({required double size}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
  _drawWarmObsidianBackground(canvas, size);
  final picture = recorder.endRecording();
  return picture.toImage(size.toInt(), size.toInt());
}

Future<ui.Image> _renderIcon({
  required double size,
  required bool includeBackground,
  required bool monochrome,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
  final cx = size * 0.5;
  final cy = size * 0.5;

  if (includeBackground) {
    _drawWarmObsidianBackground(canvas, size);
  }

  // ---- 核心图案：同心回声细环 + 5 根拉丝香槟金垂直音律柱（66% 安全圆内）----
  _drawVoiceBars(
    canvas,
    size: size,
    cx: cx,
    cy: cy,
    monochrome: monochrome,
  );

  final picture = recorder.endRecording();
  return picture.toImage(size.toInt(), size.toInt());
}

void _drawVoiceBars(
  Canvas canvas, {
  required double size,
  required double cx,
  required double cy,
  required bool monochrome,
}) {
  if (!monochrome) {
    final center = Offset(cx, cy);
    canvas.drawCircle(
      center,
      size * 0.285,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = const Color(0x14D4AE74),
    );
    canvas.drawCircle(
      center,
      size * 0.235,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0x24D4AE74),
    );
  }

  // 与 EchoSplashScreen 一致的 5 根垂直圆角音律柱
  const barWidth = 46.0;
  const barGap = 34.0;
  const heights = [156.0, 286.0, 408.0, 286.0, 156.0];
  final totalWidth = heights.length * barWidth + (heights.length - 1) * barGap;
  final startX = cx - totalWidth * 0.5 + barWidth * 0.5;

  for (int i = 0; i < heights.length; i++) {
    final x = startX + i * (barWidth + barGap);
    final h = heights[i];
    final rect = Rect.fromCenter(
      center: Offset(x, cy),
      width: barWidth,
      height: h,
    );
    final radius = const Radius.circular(barWidth * 0.5);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    final paint = Paint()..style = PaintingStyle.fill;
    if (monochrome) {
      paint.color = Colors.white;
    } else {
      final shadowRRect = RRect.fromRectAndRadius(
        rect.shift(const Offset(0, 12)),
        radius,
      );
      final shadowPaint = Paint()
        ..color = const Color(0x4D000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawRRect(shadowRRect, shadowPaint);

      final top = Offset(x, cy - h * 0.5);
      final bottom = Offset(x, cy + h * 0.5);
      if (i == 2) {
        paint.shader = ui.Gradient.linear(
          top,
          bottom,
          const [Color(0xFFF7F0E4), Color(0xFFDEC08F), Color(0xFFBE9558)],
          const [0.0, 0.48, 1.0],
        );
      } else if (i == 1 || i == 3) {
        paint.shader = ui.Gradient.linear(
          top,
          bottom,
          const [Color(0xFFE4C696), Color(0xFFB68D52)],
        );
      } else {
        paint.shader = ui.Gradient.linear(
          top,
          bottom,
          const [Color(0xFFC9A978), Color(0xFF8B693B)],
        );
      }
    }

    canvas.drawRRect(rrect, paint);
  }
}
