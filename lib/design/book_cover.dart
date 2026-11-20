import 'package:flutter/material.dart';

import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// 书籍封面组件：优先展示真实 cover_url（书源 CDN），
/// 加载失败或缺失时回退为设计风格占位（暖橙渐变 + 书本图标）。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    this.url,
    this.width = 48,
    this.height = 64,
  });

  final String? url;
  final double width;
  final double height;

  bool get _hasUrl => url != null && url!.startsWith('http');

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
        size: width * 0.42,
      ),
    );

    if (!_hasUrl) return fallback;

    return ClipRRect(
      borderRadius: radius,
      child: Image.network(
        url!,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
