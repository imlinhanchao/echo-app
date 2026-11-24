import 'dart:io' show File;

import 'package:flutter/material.dart';

/// 书籍封面组件：优先展示真实 cover_url（远端 CDN 或本地文件），
/// 缺失或加载失败时使用沉稳优雅的布面装帧封面占位（带书脊压痕光影与精致版心文字）。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    this.url,
    this.title,
    this.author,
    this.width = 48,
    this.height = 68,
    this.borderRadius,
    this.semanticLabel,
  });

  final String? url;
  final String? title;
  final String? author;
  final double width;
  final double height;
  final double? borderRadius;
  final String? semanticLabel;

  static const List<({Color top, Color bottom, Color foil})> _clothPalettes = [
    (
      top: Color(0xFF2B231E),
      bottom: Color(0xFF1D1714),
      foil: Color(0xFFE2C8A0),
    ), // Espresso
    (
      top: Color(0xFF1E2A27),
      bottom: Color(0xFF141D1B),
      foil: Color(0xFFD5CEBD),
    ), // Forest Slate
    (
      top: Color(0xFF202530),
      bottom: Color(0xFF151922),
      foil: Color(0xFFD8CCB8),
    ), // Midnight Ink
    (
      top: Color(0xFF302126),
      bottom: Color(0xFF21161A),
      foil: Color(0xFFE4C9AE),
    ), // Antique Plum
    (
      top: Color(0xFF282B21),
      bottom: Color(0xFF1B1E16),
      foil: Color(0xFFDCD3BA),
    ), // Warm Olive
    (
      top: Color(0xFF342B22),
      bottom: Color(0xFF231D16),
      foil: Color(0xFFE6CEAB),
    ), // Sandstone
  ];

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = borderRadius ?? (width >= 96 ? 12.0 : 8.0);
    final radius = BorderRadius.circular(effectiveRadius);

    final fallback = _ClothCoverPlaceholder(
      seed: (title?.isNotEmpty == true ? title! : (url ?? 'echo')).hashCode,
      title: title,
      author: author,
      width: width,
      height: height,
      radius: radius,
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

    final framed = ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            imageWidget,
            // 左侧微妙书脊压痕高光
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: (width * 0.08).clamp(3.0, 10.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.20),
                      Colors.white.withValues(alpha: 0.09),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.35, 1.0],
                  ),
                ),
              ),
            ),
            // 极细书籍边缘描边
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.11),
                  width: 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return semanticLabel != null
        ? Semantics(image: true, label: semanticLabel, child: framed)
        : ExcludeSemantics(child: framed);
  }
}

class _ClothCoverPlaceholder extends StatelessWidget {
  const _ClothCoverPlaceholder({
    required this.seed,
    required this.title,
    required this.author,
    required this.width,
    required this.height,
    required this.radius,
  });

  final int seed;
  final String? title;
  final String? author;
  final double width;
  final double height;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final palette =
        BookCover._clothPalettes[seed.abs() % BookCover._clothPalettes.length];
    final cleanTitle = (title ?? '').trim();
    final cleanAuthor = (author ?? '').trim();
    final isLarge = width >= 72 && height >= 96;
    final isMedium = width >= 44 && height >= 56;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.top, palette.bottom],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isLarge)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all((width * 0.08).clamp(6.0, 12.0)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: palette.foil.withValues(alpha: 0.18),
                      width: 0.6,
                    ),
                  ),
                ),
              ),
            ),
          if (isLarge && cleanTitle.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                (width * 0.14).clamp(10.0, 18.0),
                (height * 0.14).clamp(12.0, 22.0),
                (width * 0.12).clamp(8.0, 16.0),
                (height * 0.12).clamp(10.0, 18.0),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 16,
                        height: 1.5,
                        color: palette.foil.withValues(alpha: 0.65),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        cleanTitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: (width * 0.11).clamp(12.0, 16.5),
                          height: 1.28,
                          fontWeight: FontWeight.w600,
                          color: palette.foil,
                          fontFamily: 'serif',
                        ),
                      ),
                    ],
                  ),
                  if (cleanAuthor.isNotEmpty)
                    Text(
                      cleanAuthor,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: (width * 0.08).clamp(9.5, 11.5),
                        color: palette.foil.withValues(alpha: 0.62),
                      ),
                    ),
                ],
              ),
            )
          else if (isMedium && cleanTitle.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  cleanTitle.characters.first,
                  style: TextStyle(
                    fontSize: (width * 0.42).clamp(14.0, 22.0),
                    fontWeight: FontWeight.w600,
                    color: palette.foil.withValues(alpha: 0.90),
                    fontFamily: 'serif',
                  ),
                ),
              ),
            )
          else
            Center(
              child: Icon(
                Icons.menu_book_outlined,
                color: palette.foil.withValues(alpha: 0.88),
                size: width.isFinite ? (width * 0.40).clamp(14.0, 30.0) : 24.0,
              ),
            ),
        ],
      ),
    );
  }
}
