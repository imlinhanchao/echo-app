import 'dart:io' show File;

import 'package:flutter/material.dart';

import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// 书籍封面组件：优先展示真实 cover_url（远端 CDN 或本地文件），
/// 加载失败或缺失时回退为设计风格占位（暖橙渐变 + 书本图标）。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    this.url,
    this.width = 48,
    this.height = 64,
    this.semanticLabel,
  });

  final String? url;
  final double width;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final radius = BorderRadius.circular(EchoMetrics.radiusControl);

    final fallback = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tokens.accent.withValues(alpha: 0.85),
            tokens.accent.withValues(alpha: 0.45),
          ],
        ),
      ),
      child: Icon(
        Icons.menu_book_outlined,
        color: tokens.textOnPrimary,
        size: width.isFinite ? width * 0.42 : 48.0,
      ),
    );

    Widget imageWidget;
    final coverUrl = url;
    if (coverUrl != null &&
        (coverUrl.startsWith('http://') || coverUrl.startsWith('https://'))) {
      imageWidget = Image.network(
        coverUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (coverUrl != null &&
        (coverUrl.startsWith('file://') || coverUrl.startsWith('/'))) {
      final path = coverUrl.startsWith('file://')
          ? Uri.parse(coverUrl).toFilePath()
          : coverUrl;
      imageWidget = Image.file(
        File(path),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    } else {
      imageWidget = fallback;
    }

    final widget = ClipRRect(borderRadius: radius, child: imageWidget);

    return semanticLabel != null
        ? Semantics(image: true, label: semanticLabel, child: widget)
        : ExcludeSemantics(child: widget);
  }
}
