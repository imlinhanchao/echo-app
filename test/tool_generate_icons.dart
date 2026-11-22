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

    // 1. 生成完整图标（含深邃星空底色 + 发光光晕 + 书本与声波）
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

Future<ui.Image> _renderBackgroundOnly({required double size}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));

  // 背景渐变：从深邃靛青到暗黑曜石
  final bgPaint = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(0, 0),
      Offset(size, size),
      const [Color(0xFF14182B), Color(0xFF0F111E), Color(0xFF0A0B14)],
      [0.0, 0.55, 1.0],
    );
  canvas.drawRect(Rect.fromLTWH(0, 0, size, size), bgPaint);

  // 顶部中心柔和微光光晕
  final glowPaint = Paint()
    ..shader = ui.Gradient.radial(
      Offset(size * 0.5, size * 0.42),
      size * 0.45,
      [
        const Color(0x356366F1),
        const Color(0x158B5CF6),
        const Color(0x00000000),
      ],
      [0.0, 0.5, 1.0],
    );
  canvas.drawCircle(Offset(size * 0.5, size * 0.42), size * 0.45, glowPaint);

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
  final cy = size * 0.5; // 居中对称

  if (includeBackground) {
    // 绘制深邃黑曜石渐变底色
    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(size, size),
        const [Color(0xFF13172B), Color(0xFF0E111E), Color(0xFF07080F)],
        const [0.0, 0.52, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, size, size), bgPaint);

    // 中心音频脉冲放射光晕
    final glowPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(cx, cy),
        size * 0.46,
        [
          const Color(0x556366F1),
          const Color(0x258B5CF6),
          const Color(0x00000000),
        ],
        const [0.0, 0.50, 1.0],
      );
    canvas.drawCircle(Offset(cx, cy), size * 0.46, glowPaint);
  }

  // ---- 核心图案：纯粹极简的高质感音频律动脉冲（严格契合 66% 安全圆）----
  _drawVoiceBars(canvas, cx: cx, cy: cy, monochrome: monochrome);

  final picture = recorder.endRecording();
  return picture.toImage(size.toInt(), size.toInt());
}

void _drawVoiceBars(
  Canvas canvas, {
  required double cx,
  required double cy,
  required bool monochrome,
}) {
  // 7 根垂直对称的高品质圆角声波柱，音律起伏和谐，在桌面启动器上极具辨识度
  const barWidth = 36.0;
  const barGap = 26.0;
  const heights = [140.0, 240.0, 360.0, 460.0, 360.0, 240.0, 140.0];
  final totalWidth = 7 * barWidth + 6 * barGap;
  final startX = cx - totalWidth * 0.5 + barWidth * 0.5;

  for (int i = 0; i < 7; i++) {
    final x = startX + i * (barWidth + barGap);
    final h = heights[i];
    final rect = Rect.fromCenter(
      center: Offset(x, cy),
      width: barWidth,
      height: h,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(barWidth * 0.5),
    );

    final paint = Paint()..style = PaintingStyle.fill;

    if (monochrome) {
      paint.color = Colors.white;
    } else {
      if (i == 3) {
        // 中间核心主波柱：紫光 → 靛青 → 晨光暖金 → 温暖落日珊瑚橙
        paint.shader = ui.Gradient.linear(
          Offset(x, cy - h * 0.5),
          Offset(x, cy + h * 0.5),
          const [
            Color(0xFFC084FC),
            Color(0xFF818CF8),
            Color(0xFFF59E0B),
            Color(0xFFEA580C),
          ],
          const [0.0, 0.38, 0.76, 1.0],
        );
      } else {
        // 两侧辅波柱：优雅深浅紫蓝层次渐变
        final t = (i - 3).abs() / 3.0; // 0..1
        final topColor = Color.lerp(
          const Color(0xFFDDD6FE),
          const Color(0xFFA5B4FC),
          t,
        )!;
        final bottomColor = Color.lerp(
          const Color(0xFF6366F1),
          const Color(0xFF3730A3),
          t,
        )!;

        paint.shader = ui.Gradient.linear(
          Offset(x, cy - h * 0.5),
          Offset(x, cy + h * 0.5),
          [topColor, bottomColor],
        );
      }
    }

    // 绘制霓虹辉光
    if (!monochrome) {
      final shadowPaint = Paint()
        ..color = (i == 3 ? const Color(0xFF8B5CF6) : const Color(0xFF6366F1))
            .withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      canvas.drawRRect(rrect, shadowPaint);
    }

    canvas.drawRRect(rrect, paint);
  }
}
